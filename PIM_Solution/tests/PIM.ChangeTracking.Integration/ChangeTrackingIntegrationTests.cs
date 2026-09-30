using Microsoft.Data.SqlClient;
using PIM.KatalogWorker;
using Xunit;
using PIM.Operations;

namespace PIM.ChangeTracking.Integration;

public sealed class ChangeTrackingIntegrationTests
{
  private const int OrganizationId = 2;
  private readonly string _connectionString = LocalSettings.ConnectionString()
    ?? throw new InvalidOperationException("Povezava mora biti na voljo, kadar se integracijski primer izvede.");

  // Poizvedbe po zgodovini so omejene na podjetje in artikel testa (indeks
  // IX_PimProductFieldHistory_Product). Brez tega berejo vseh 2,7 mio vrstic in cakajo na vsako
  // tujo odprto transakcijo, ki pise zgodovino (vrata drugih nalog, avtomatika) — #43.
  [RequiresPimConnectionFact]
  public async Task FieldUndo_restores_pim_owned_value_and_creates_history()
  {
    await TestScope.RunAsync(_connectionString, async scope =>
    {
      var changeId = await scope.CreateTrackedFieldChangeAsync();

      await scope.ExecuteAsync("EXEC pim.UndoProductField @OrganizationId,@ChangeId,N'PIM.ChangeTracking.Integration';",
        ("@OrganizationId", OrganizationId), ("@ChangeId", changeId));

      Assert.False(await scope.ScalarAsync<bool>("SELECT WebPublish FROM canon.Product WHERE ProductId=@ProductId;", ("@ProductId", scope.ProductId)));
      Assert.Equal(1, await scope.ScalarAsync<int>("SELECT COUNT(*) FROM pim.ProductFieldHistory WHERE OrganizationId=@OrganizationId AND ProductId=@ProductId AND UndoOfChangeId=@ChangeId;", ("@OrganizationId", OrganizationId), ("@ProductId", scope.ProductId), ("@ChangeId", changeId)));
      Assert.Equal(0, await scope.ScalarAsync<int>("SELECT COUNT(*) WHERE SESSION_CONTEXT(N'ChangeSource') IS NOT NULL OR SESSION_CONTEXT(N'ChangedBy') IS NOT NULL OR SESSION_CONTEXT(N'ChangeBatchId') IS NOT NULL;"));
    });
  }

  [RequiresPimConnectionFact]
  public async Task FieldUndo_rejects_redo_and_conflicting_current_value()
  {
    await TestScope.RunAsync(_connectionString, async scope =>
    {
      var changeId = await scope.CreateTrackedFieldChangeAsync();
      await scope.ExecuteAsync("EXEC pim.UndoProductField @OrganizationId,@ChangeId,N'PIM.ChangeTracking.Integration';", ("@OrganizationId", OrganizationId), ("@ChangeId", changeId));
      await scope.ExpectSqlErrorAsync(51222, "EXEC pim.UndoProductField @OrganizationId,@ChangeId,N'PIM.ChangeTracking.Integration';", ("@OrganizationId", OrganizationId), ("@ChangeId", changeId));

      var secondChangeId = await scope.CreateTrackedFieldChangeAsync();
      await scope.ExecuteAsync("UPDATE canon.Product SET WebPublish=0 WHERE ProductId=@ProductId;", ("@ProductId", scope.ProductId));
      await scope.ExpectSqlErrorAsync(51225, "EXEC pim.UndoProductField @OrganizationId,@ChangeId,N'PIM.ChangeTracking.Integration';", ("@OrganizationId", OrganizationId), ("@ChangeId", secondChangeId));
      Assert.Equal(0, await scope.ScalarAsync<int>("SELECT COUNT(*) WHERE SESSION_CONTEXT(N'ChangeSource') IS NOT NULL OR SESSION_CONTEXT(N'ChangedBy') IS NOT NULL OR SESSION_CONTEXT(N'ChangeBatchId') IS NOT NULL;"));
    });
  }

  [RequiresPimConnectionFact]
  public async Task BatchUndo_restores_all_supported_fields_in_one_undo_batch()
  {
    await TestScope.RunAsync(_connectionString, async scope =>
    {
      var batchId = await scope.CreateTrackedProductChangeAsync(includeIsActive: true);
      await scope.ExecuteAsync("EXEC pim.UndoProductBatch @OrganizationId,@ChangeBatchId,N'PIM.ChangeTracking.Integration';", ("@OrganizationId", OrganizationId), ("@ChangeBatchId", batchId));

      Assert.False(await scope.ScalarAsync<bool>("SELECT WebPublish FROM canon.Product WHERE ProductId=@ProductId;", ("@ProductId", scope.ProductId)));
      Assert.False(await scope.ScalarAsync<bool>("SELECT IsActive FROM canon.Product WHERE ProductId=@ProductId;", ("@ProductId", scope.ProductId)));
      Assert.Equal(1, await scope.ScalarAsync<int>("SELECT COUNT(DISTINCT ChangeBatchId) FROM pim.ProductFieldHistory WHERE OrganizationId=@OrganizationId AND ProductId=@ProductId AND UndoOfChangeId IN (SELECT ChangeId FROM pim.ProductFieldHistory WHERE ChangeBatchId=@ChangeBatchId);", ("@OrganizationId", OrganizationId), ("@ProductId", scope.ProductId), ("@ChangeBatchId", batchId)));
    });
  }

  [RequiresPimConnectionTheory]
  [InlineData("SHARED")]
  [InlineData("SAOP")]
  public async Task FieldUndo_rejects_non_pim_owned_field(string owner)
  {
    await TestScope.RunAsync(_connectionString, async scope =>
    {
      await scope.ExecuteAsync("UPDATE pim.FieldOwnership SET Owner=@Owner WHERE FieldKey=N'Product.WebPublish';", ("@Owner", owner));
      var changeId = await scope.CreateTrackedFieldChangeAsync();
      await scope.ExpectSqlErrorAsync(51223, "EXEC pim.UndoProductField @OrganizationId,@ChangeId,N'PIM.ChangeTracking.Integration';", ("@OrganizationId", OrganizationId), ("@ChangeId", changeId));
    });
  }

  [RequiresPimConnectionFact]
  public async Task BatchUndo_rejects_empty_batch()
  {
    await TestScope.RunAsync(_connectionString, async scope =>
    {
      var batchId = await scope.ScalarAsync<long>("INSERT pim.ProductChangeBatch(BatchId,OrganizationId,ChangeSource,ChangedBy,ChangedAtUtc) VALUES(NEWID(),@OrganizationId,N'INTEGRATION_TEST',N'PIM.ChangeTracking.Integration',SYSUTCDATETIME()); SELECT CONVERT(bigint,SCOPE_IDENTITY());", ("@OrganizationId", OrganizationId));
      await scope.ExpectSqlErrorAsync(51236, "EXEC pim.UndoProductBatch @OrganizationId,@ChangeBatchId,N'PIM.ChangeTracking.Integration';", ("@OrganizationId", OrganizationId), ("@ChangeBatchId", batchId));
      Assert.Equal(0, await scope.ScalarAsync<int>("SELECT COUNT(*) WHERE SESSION_CONTEXT(N'ChangeSource') IS NOT NULL OR SESSION_CONTEXT(N'ChangedBy') IS NOT NULL OR SESSION_CONTEXT(N'ChangeBatchId') IS NOT NULL;"));
    });
  }

  /// <summary>
  /// Ovoj okoli ene preizkusne seje. Vse tece v transakciji, ki se ob koncu povrne — a to
  /// samo po sebi ni dovolj:
  ///
  /// <c>ExpectSqlErrorAsync</c> namenoma sprozi napako v proceduri, ki tece s
  /// <c>SET XACT_ABORT ON</c>. Taka napaka povrne objemno transakcijo <em>takoj</em>, zato
  /// vse, kar test naredi za tem, tece v samopotrditvenem nacinu in ostane zapisano.
  /// Ob povrnitvi na koncu ni vec kaj povrniti.
  ///
  /// Posledica, izmerjena 2026-08-21: v razvojni bazi se je nabralo 38 artiklov
  /// <c>CHANGE-TRACKING-*</c> v podjetju 2, priblizno stirje na vsak polni zagon paketa.
  /// Niso samo smet — sedijo med pravimi artikli IQLighting in kvarijo vsako stetje.
  ///
  /// Zato <c>ExpectSqlErrorAsync</c> po pricakovani napaki takoj odpre novo transakcijo (#43), da
  /// se nic ne potrdi samo od sebe. Za vsak primer si seja se vedno zapomni vsak artikel, ki ga je
  /// ustvarila, in ga ob koncu pobrise, ce je preziveel; ob zacetku pa pobrise ostanke prejsnjih
  /// zagonov istega testa. Brise se izkljucno to, kar je ustvaril ta test (AGENTS.md #4.1).
  ///
  /// Brisanje artikla je drago: tuji kljuc iz <c>pim.ProductFieldHistory</c> (2,7 mio vrstic) nima
  /// indeksa, ki bi se zacel s ProductId, zato preverjanje prebere ves indeks in caka na vsako tujo
  /// odprto transakcijo, ki pise zgodovino (vrata drugih nalog). Zato se brisanje izvede samo, ce
  /// ostanki res obstajajo.
  /// </summary>
  private sealed class TestScope : IAsyncDisposable
  {
    private readonly SqlConnection _connection;
    private readonly List<long> _createdProductIds = [];
    private bool _disposed;
    public long ProductId { get; private set; }

    private TestScope(SqlConnection connection) => _connection = connection;

    private const int DeadlockVictim = 1205;
    private const int CommandTimeout = -2;
    private const int MaxAttempts = 3;

    /// <summary>
    /// Zastoj (1205) ali potek casa ukaza (-2) zaradi tuje odprte transakcije. Oboje je posledica
    /// sočasnega dela na skupni razvojni bazi (vrata drugih nalog, avtomatika), ne napaka razveljavitve.
    /// Potek casa je mozen, ker pim.UndoProductField isce po UndoOfChangeId brez indeksa (#43 opomba).
    /// </summary>
    private static bool IsContention(SqlException error) => error.Number is DeadlockVictim or CommandTimeout;

    /// <summary>
    /// Pozene telo testa v sveži seji in ga ob zastoju ali poteku casa ponovi v celoti — transakcija je po
    /// zastoju ze povrnjena, zato ponovitev samo zadnjega ukaza ne bi imela smisla. Zastoj lahko
    /// sprozi tudi avtomatika, ki pise v canon.Product, zato zaklep (<see cref="IntegrationDbLock"/>) sam ni dovolj.
    /// </summary>
    public static async Task RunAsync(string connectionString, Func<TestScope, Task> body)
    {
      for (var attempt = 1; ; attempt++)
      {
        try
        {
          await using var scope = await OpenAsync(connectionString);
          await body(scope);
          return;
        }
        catch (SqlException error) when (IsContention(error) && attempt < MaxAttempts)
        {
          await Task.Delay(TimeSpan.FromMilliseconds(500 * attempt));
        }
      }
    }

    private static async Task<TestScope> OpenAsync(string connectionString)
    {
      var connection = new SqlConnection(connectionString);
      await connection.OpenAsync();
      try
      {
        await IntegrationDbLock.AcquireAsync(connection);

        // Pred transakcijo, sicer bi bilo pospravljanje povrnjeno skupaj z vsem ostalim.
        await using (var sweep = new SqlCommand(SweepSql, connection) { CommandTimeout = 120 })
        {
          sweep.Parameters.AddWithValue("@OrganizationId", OrganizationId);
          await sweep.ExecuteNonQueryAsync();
        }

        await using (var begin = new SqlCommand("BEGIN TRANSACTION;", connection))
          await begin.ExecuteNonQueryAsync();
        return new TestScope(connection);
      }
      catch
      {
        await IntegrationDbLock.ReleaseAsync(connection);
        await connection.DisposeAsync();
        throw;
      }
    }

    /// <summary>Pobrise artikle tega testa in vse, kar visi na njih, po vrsti tujih kljucev.</summary>
    private const string SweepSql = """
      DECLARE @Mine TABLE(ProductId bigint PRIMARY KEY);
      INSERT @Mine(ProductId)
      -- READPAST: nezakljucene vrstice drugih testov (druga vrata) niso nase in jih ne cakamo.
      -- Drug zagon tega projekta med nami ne more imeti odprte transakcije (IntegrationDbLock).
      SELECT ProductId FROM canon.Product WITH (READPAST)
      WHERE OrganizationId = @OrganizationId AND ItemID LIKE N'CHANGE-TRACKING-%';

      DECLARE @Batches TABLE(ChangeBatchId bigint PRIMARY KEY);
      INSERT @Batches(ChangeBatchId)
      SELECT DISTINCT ChangeBatchId FROM pim.ProductFieldHistory WHERE OrganizationId = @OrganizationId AND ProductId IN (SELECT ProductId FROM @Mine);

      IF NOT EXISTS(SELECT 1 FROM @Mine) RETURN;

      DELETE FROM val.ProductIssue           WHERE ProductId IN (SELECT ProductId FROM @Mine);
      DELETE FROM val.ProductValidationState WHERE ProductId IN (SELECT ProductId FROM @Mine);
      DELETE FROM stock.Position             WHERE MatchedProductId IN (SELECT ProductId FROM @Mine);
      DELETE FROM canon.ProductCommercial    WHERE ProductId IN (SELECT ProductId FROM @Mine);
      DELETE FROM canon.ProductPrice         WHERE ProductId IN (SELECT ProductId FROM @Mine);
      DELETE FROM canon.ProductMedia         WHERE ProductId IN (SELECT ProductId FROM @Mine);
      DELETE FROM canon.ProductCategory      WHERE ProductId IN (SELECT ProductId FROM @Mine);
      DELETE FROM canon.ProductAttribute     WHERE ProductId IN (SELECT ProductId FROM @Mine);
      DELETE FROM canon.ProductText          WHERE ProductId IN (SELECT ProductId FROM @Mine);
      DELETE FROM pim.ProductFieldHistory    WHERE OrganizationId = @OrganizationId AND ProductId IN (SELECT ProductId FROM @Mine);
      DELETE FROM pim.ProductChangeBatch     WHERE ChangeBatchId IN (SELECT ChangeBatchId FROM @Batches)
        AND NOT EXISTS(SELECT 1 FROM pim.ProductFieldHistory history WHERE history.ChangeBatchId = pim.ProductChangeBatch.ChangeBatchId);
      DELETE FROM canon.Product              WHERE ProductId IN (SELECT ProductId FROM @Mine);
      """;

    public async Task<long> CreateTrackedProductChangeAsync(bool includeIsActive = false)
    {
      ProductId = await ScalarAsync<long>("INSERT canon.Product(OrganizationId,ItemID,WebPublish,IsActive) VALUES(@OrganizationId,CONCAT(N'CHANGE-TRACKING-',NEWID()),0,0); SELECT CONVERT(bigint,SCOPE_IDENTITY());", ("@OrganizationId", OrganizationId));
      _createdProductIds.Add(ProductId);
      var batchGuid = Guid.NewGuid();
      await ExecuteAsync(includeIsActive
        ? "EXEC pim.SetChangeContext @ChangeSource=N'INTEGRATION_TEST',@ChangedBy=N'PIM.ChangeTracking.Integration',@BatchId=@BatchId; UPDATE canon.Product SET WebPublish=1,IsActive=1 WHERE ProductId=@ProductId; EXEC pim.ClearChangeContext;"
        : "EXEC pim.SetChangeContext @ChangeSource=N'INTEGRATION_TEST',@ChangedBy=N'PIM.ChangeTracking.Integration',@BatchId=@BatchId; UPDATE canon.Product SET WebPublish=1 WHERE ProductId=@ProductId; EXEC pim.ClearChangeContext;",
        ("@BatchId", batchGuid), ("@ProductId", ProductId));
      return await ScalarAsync<long>("SELECT ChangeBatchId FROM pim.ProductChangeBatch WHERE BatchId=@BatchId;", ("@BatchId", batchGuid));
    }

    public async Task<long> CreateTrackedFieldChangeAsync()
    {
      var batchId = await CreateTrackedProductChangeAsync();
      return await ScalarAsync<long>("SELECT ChangeId FROM pim.ProductFieldHistory WHERE ChangeBatchId=@ChangeBatchId AND ProductId=@ProductId AND FieldKey=N'Product.WebPublish';", ("@ChangeBatchId", batchId), ("@ProductId", ProductId));
    }

    public async Task ExecuteAsync(string sql, params (string Name, object Value)[] values)
    {
      await using var command = Command(sql, values);
      await command.ExecuteNonQueryAsync();
    }
    public async Task<T> ScalarAsync<T>(string sql, params (string Name, object Value)[] values)
    {
      await using var command = Command(sql, values);
      var value = await command.ExecuteScalarAsync() ?? throw new InvalidOperationException("Poizvedba ni vrnila vrednosti.");
      return (T)Convert.ChangeType(value, typeof(T));
    }
    public async Task ExpectSqlErrorAsync(int number, string sql, params (string Name, object Value)[] values)
    {
      var error = await Assert.ThrowsAsync<SqlException>(() => ExecuteAsync(sql, values));
      // Zastoj ali potek casa ni pricakovana napaka procedure: naj ga RunAsync ponovi, ne pa javi kot napacno stevilko.
      if (IsContention(error)) throw error;
      Assert.Equal(number, error.Number);
      // XACT_ABORT je transakcijo ze povrnil; brez nove bi se vse naslednje potrdilo samo od sebe.
      await ExecuteAsync("IF XACT_STATE() = -1 ROLLBACK TRANSACTION; IF @@TRANCOUNT = 0 BEGIN TRANSACTION;");
    }
    private SqlCommand Command(string sql, params (string Name, object Value)[] values)
    {
      var command = new SqlCommand(sql, _connection) { CommandTimeout = 120 };
      foreach (var value in values) command.Parameters.AddWithValue(value.Name, value.Value);
      return command;
    }
    public async ValueTask DisposeAsync()
    {
      if (_disposed) return;
      _disposed = true;
      try
      {
        await using (var state = new SqlCommand("IF XACT_STATE()<>0 ROLLBACK TRANSACTION; EXEC pim.ClearChangeContext;", _connection))
        {
          await state.ExecuteNonQueryAsync();
        }

        // Povrnitev je pobrisala vse, kar je bilo v transakciji. Kar je nastalo po napaki s
        // XACT_ABORT, pa je bilo samopotrjeno in je se tu — to pospravimo zdaj, po id-jih.
        if (_createdProductIds.Count > 0)
        {
          await using var cleanup = new SqlCommand(SweepSql, _connection) { CommandTimeout = 120 };
          cleanup.Parameters.AddWithValue("@OrganizationId", OrganizationId);
          await cleanup.ExecuteNonQueryAsync();
        }
      }
      finally
      {
        await IntegrationDbLock.ReleaseAsync(_connection);
        await _connection.DisposeAsync();
      }
    }
  }
}
