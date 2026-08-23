using System.Data;
using System.Xml;
using System.Xml.XPath;
using Microsoft.Data.SqlClient;

namespace PIM.XmlMapping;

public sealed class SqlMappingPipeline(string connectionString, XPathMappingExtractor? extractor = null)
{
  private readonly XPathMappingExtractor extractor = extractor ?? new XPathMappingExtractor();

  /// <summary>Meja za en klic apply postopka; prek PIM_MAPPING_TIMEOUT_SECONDS, privzeto 900.</summary>
  private static int ApplyCommandTimeoutSeconds =>
    int.TryParse(Environment.GetEnvironmentVariable("PIM_MAPPING_TIMEOUT_SECONDS"), out var parsed) && parsed > 0
      ? parsed
      : 900;

  public async Task ExtractAndApplyAsync(
    Guid runId,
    int organizationId,
    string sourceCode,
    CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(connectionString);
    await connection.OpenAsync(cancellationToken);
    await SetChangeContextAsync(connection, runId, sourceCode, cancellationToken);
    try
    {
      var inboxes = await ReadInboxesAsync(connection, runId, organizationId, sourceCode, cancellationToken);

      foreach (var inbox in inboxes)
      {
        try
        {
          var values = extractor.Extract(inbox.PayloadXml, inbox.RecordXPath, inbox.Mappings);
          await WriteValuesAsync(connection, inbox.InboxId, values, cancellationToken);
        }
        catch (XmlException exception)
        {
          await QuarantineAsync(connection, inbox.InboxId, exception.Message, cancellationToken);
        }
        catch (XPathException exception)
        {
          await QuarantineAsync(connection, inbox.InboxId, exception.Message, cancellationToken);
        }
      }

      // Pretvorbe (map.FieldTransform) in slovar vrednosti (map.ValueLookup) tečejo med
      // izluščanjem in prenosom v katalog: izluščena vrednost je še surova, ProcessRawInbox
      // pa naprej dobi že poenoteno. Postopek je množičen in nad zapisom brez pretvorb ne
      // naredi ničesar, zato ga kličemo brezpogojno.
      await using (var transform = new SqlCommand(
        "EXEC map.ApplyValueTransforms @RunId,@OrganizationId,@SourceCode;",
        connection)
      {
        CommandTimeout = ApplyCommandTimeoutSeconds
      })
      {
        transform.Parameters.Add("@RunId", SqlDbType.UniqueIdentifier).Value = runId;
        transform.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
        transform.Parameters.Add("@SourceCode", SqlDbType.NVarChar, 100).Value = sourceCode;
        await transform.ExecuteNonQueryAsync(cancellationToken);
      }

      // map.ProcessRawInbox gre čez zapise s kurzorjem in na vsakem izvede pet MERGE stavkov.
      // Ena zajeta stran nosi do tisoč zapisov, zato en klic redno preseže privzetih 30 sekund;
      // to ni znak blokade, ampak obseg dela. Meja ostane nastavljiva, da se ne izgubi zaznava
      // pravega zastoja.
      await using var apply = new SqlCommand(
        "EXEC map.ProcessRawInbox @RunId,@OrganizationId,@SourceCode;",
        connection)
      {
        CommandTimeout = ApplyCommandTimeoutSeconds
      };
      apply.Parameters.Add("@RunId", SqlDbType.UniqueIdentifier).Value = runId;
      apply.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
      apply.Parameters.Add("@SourceCode", SqlDbType.NVarChar, 100).Value = sourceCode;
      await apply.ExecuteNonQueryAsync(cancellationToken);

      // Sifranti niso izdelki in imajo svoj postopek (od migracije 064). map.ProcessRawInbox jih
      // preskoci po map.EntityMapping.TargetDomain, tu pa se obdelajo. Nad virom brez sifrantov
      // postopek ne naredi nicesar.
      await using (var warehouses = new SqlCommand(
        "EXEC map.ProcessWarehouseInbox @RunId,@OrganizationId,@SourceCode;",
        connection)
      {
        CommandTimeout = ApplyCommandTimeoutSeconds
      })
      {
        warehouses.Parameters.Add("@RunId", SqlDbType.UniqueIdentifier).Value = runId;
        warehouses.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
        warehouses.Parameters.Add("@SourceCode", SqlDbType.NVarChar, 100).Value = sourceCode;
        await warehouses.ExecuteNonQueryAsync(cancellationToken);
      }

      // Sifrant jezikov mora biti obdelan pred nazivi: naziv brez kode jezika nima kam.
      // Oba postopka nad virom brez teh entitet ne naredita nicesar (migracija 072).
      // Vrstni red ni nakljucen: sifrant jezikov pred nazivi (naziv brez kode jezika nima kam),
      // sifrant skladisc pa je ze tekel zgoraj. Vsak postopek nad virom brez svoje entitete ne
      // naredi nicesar, zato jih klicemo brezpogojno.
      foreach (var procedura in new[]
      {
        "map.ProcessLanguageInbox",
        "map.ProcessProductTextInbox",
        "map.ProcessAttributePairInbox",
        "map.ProcessStockPolicyInbox"
      })
      {
        await using var command = new SqlCommand(
          $"EXEC {procedura} @RunId,@OrganizationId,@SourceCode;", connection)
        {
          CommandTimeout = ApplyCommandTimeoutSeconds
        };
        command.Parameters.Add("@RunId", SqlDbType.UniqueIdentifier).Value = runId;
        command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
        command.Parameters.Add("@SourceCode", SqlDbType.NVarChar, 100).Value = sourceCode;
        await command.ExecuteNonQueryAsync(cancellationToken);
      }

      // Kategorija dobavitelja ni nasa kategorija. Ko so izdelki najdeni oziroma ustvarjeni,
      // se dobaviteljeva pot prevede v nase drevo (map.CategoryPathMap); cesar slovar ne
      // pozna, gre v map.MissingCategoryMap in ostane vidno. Postopek nad virom brez
      // kategorij ne naredi nicesar.
      await using var categories = new SqlCommand(
        "EXEC map.ResolveProductCategories @RunId,@OrganizationId,@SourceCode;",
        connection)
      {
        CommandTimeout = ApplyCommandTimeoutSeconds
      };
      categories.Parameters.Add("@RunId", SqlDbType.UniqueIdentifier).Value = runId;
      categories.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
      categories.Parameters.Add("@SourceCode", SqlDbType.NVarChar, 100).Value = sourceCode;
      await categories.ExecuteNonQueryAsync(cancellationToken);
    }
    finally
    {
      await ClearChangeContextAsync(connection, cancellationToken);
    }
  }

  private static async Task SetChangeContextAsync(SqlConnection connection, Guid runId, string sourceCode, CancellationToken cancellationToken)
  {
    await using var command = new SqlCommand("pim.SetChangeContext", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.Add("@ChangeSource", SqlDbType.NVarChar, 32).Value = "XML_FEED";
    command.Parameters.Add("@ChangedBy", SqlDbType.NVarChar, 128).Value = $"PIM.XmlMapping:{sourceCode}";
    command.Parameters.Add("@BatchId", SqlDbType.UniqueIdentifier).Value = runId;
    command.Parameters.Add("@Note", SqlDbType.NVarChar, 400).Value = $"Raw mapping run {runId}";
    await command.ExecuteNonQueryAsync(cancellationToken);
  }

  private static async Task ClearChangeContextAsync(SqlConnection connection, CancellationToken cancellationToken)
  {
    await using var command = new SqlCommand("pim.ClearChangeContext", connection) { CommandType = CommandType.StoredProcedure };
    await command.ExecuteNonQueryAsync(cancellationToken);
  }

  private static async Task<IReadOnlyList<InboxMapping>> ReadInboxesAsync(
    SqlConnection connection,
    Guid runId,
    int organizationId,
    string sourceCode,
    CancellationToken cancellationToken)
  {
    // Strani in preslikave se bereta z dvema poizvedbama, ne z enim JOIN-om. Prej je bil JOIN
    // raw.Inbox × map.FieldMapping in vsaka vrstica je nosila cel PayloadXml — pri dobaviteljevi
    // datoteki (37 MB na stran) in 112 preslikavah je to 4 GB po zici za eno samo stran.
    // Vsebina strani je zdaj prenesena enkrat, preslikave pa so majhne in se preberejo posebej.
    var mappingsByEntity = await ReadMappingsAsync(connection, organizationId, sourceCode, cancellationToken);

    const string pagesSql = """
      SELECT inbox.InboxId,inbox.EntityType,inbox.PayloadXml,entityMapping.RecordXPath
      FROM raw.Inbox inbox
      INNER JOIN map.SourceConnector connector
        ON connector.SourceCode=inbox.SourceCode AND connector.OrganizationId=inbox.OrganizationId AND connector.IsActive=1
      INNER JOIN map.EntityMapping entityMapping
        ON entityMapping.SourceConnectorId=connector.SourceConnectorId AND entityMapping.EntityType=inbox.EntityType AND entityMapping.IsActive=1
      WHERE inbox.RunId=@RunId AND inbox.OrganizationId=@OrganizationId AND inbox.SourceCode=@SourceCode
        AND inbox.Status=N'Pending'
      ORDER BY inbox.InboxId;
      """;
    await using var command = new SqlCommand(pagesSql, connection);
    command.Parameters.Add("@RunId", SqlDbType.UniqueIdentifier).Value = runId;
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@SourceCode", SqlDbType.NVarChar, 100).Value = sourceCode;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    var pages = new List<InboxMapping>();
    while (await reader.ReadAsync(cancellationToken))
    {
      var entityType = reader.GetString(1);
      // Stran entitete brez aktivnih preslikav se preskoci in ostane Pending — enako kot prej,
      // ko je INNER JOIN tako vrstico izpustil. Podatek zato pocaka na preslikavo, ne izgine.
      if (!mappingsByEntity.TryGetValue(entityType, out var mappings) || mappings.Count == 0) continue;
      pages.Add(new InboxMapping(reader.GetInt64(0), reader.GetString(2), reader.GetString(3), mappings));
    }
    return pages;
  }

  private static async Task<Dictionary<string, List<FieldMapping>>> ReadMappingsAsync(
    SqlConnection connection,
    int organizationId,
    string sourceCode,
    CancellationToken cancellationToken)
  {
    const string sql = """
      SELECT fieldMapping.EntityType,fieldMapping.FieldMappingId,fieldMapping.MappingVersion,
        fieldMapping.SourceElement,fieldMapping.TargetFieldCode,fieldMapping.IsRequired
      FROM map.FieldMapping fieldMapping
      INNER JOIN map.SourceConnector connector
        ON connector.SourceConnectorId=fieldMapping.SourceConnectorId AND connector.IsActive=1
      WHERE connector.SourceCode=@SourceCode AND connector.OrganizationId=@OrganizationId
        AND fieldMapping.IsActive=1
      ORDER BY fieldMapping.EntityType,fieldMapping.FieldMappingId;
      """;
    await using var command = new SqlCommand(sql, connection);
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@SourceCode", SqlDbType.NVarChar, 100).Value = sourceCode;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    var grouped = new Dictionary<string, List<FieldMapping>>(StringComparer.Ordinal);
    while (await reader.ReadAsync(cancellationToken))
    {
      var entityType = reader.GetString(0);
      if (!grouped.TryGetValue(entityType, out var mappings))
      {
        mappings = [];
        grouped.Add(entityType, mappings);
      }
      mappings.Add(new FieldMapping(
        reader.GetInt32(1),
        reader.GetInt32(2),
        reader.GetString(3),
        reader.GetString(4),
        reader.GetBoolean(5)));
    }
    return grouped;
  }

  private static async Task WriteValuesAsync(
    SqlConnection connection,
    long inboxId,
    IReadOnlyList<ExtractedValue> values,
    CancellationToken cancellationToken)
  {
    if (values.Count == 0) return;

    // Prej je vsaka izluscena vrednost pomenila svoj obhod do streznika (IF NOT EXISTS + INSERT).
    // Ena stran dobaviteljeve datoteke jih ima 293.000, kar je 293.000 obhodov. Zdaj gredo
    // vrednosti mnozicno v zacasno tabelo, vstavi pa jih en stavek, ki ohrani isto pravilo
    // "kar ze obstaja, se ne vstavi znova" (enolicnost UQ_ExtractedValue_Trace).
    await using var transaction = (SqlTransaction)await connection.BeginTransactionAsync(cancellationToken);
    await using (var create = new SqlCommand("""
      CREATE TABLE #ExtractedValueStage
      (
        InboxId bigint NOT NULL,
        FieldMappingId int NOT NULL,
        MappingVersion int NOT NULL,
        RecordOrdinal int NOT NULL,
        TargetFieldCode nvarchar(400) NOT NULL,
        Value nvarchar(max) NULL
      );
      """, connection, transaction))
    {
      await create.ExecuteNonQueryAsync(cancellationToken);
    }

    using (var table = new DataTable())
    {
      table.Columns.Add("InboxId", typeof(long));
      table.Columns.Add("FieldMappingId", typeof(int));
      table.Columns.Add("MappingVersion", typeof(int));
      table.Columns.Add("RecordOrdinal", typeof(int));
      table.Columns.Add("TargetFieldCode", typeof(string));
      table.Columns.Add("Value", typeof(string));
      foreach (var value in values)
      {
        table.Rows.Add(inboxId, value.FieldMappingId, value.MappingVersion, value.RecordOrdinal,
          value.TargetFieldCode, (object?)value.Value ?? DBNull.Value);
      }
      using var bulk = new SqlBulkCopy(connection, SqlBulkCopyOptions.Default, transaction)
      {
        DestinationTableName = "#ExtractedValueStage",
        BulkCopyTimeout = ApplyCommandTimeoutSeconds,
        BatchSize = 10000
      };
      foreach (DataColumn column in table.Columns) bulk.ColumnMappings.Add(column.ColumnName, column.ColumnName);
      await bulk.WriteToServerAsync(table, cancellationToken);
    }

    await using (var insert = new SqlCommand("""
      INSERT map.ExtractedValue(InboxId,FieldMappingId,MappingVersion,RecordOrdinal,TargetFieldCode,Value)
      SELECT stage.InboxId,stage.FieldMappingId,stage.MappingVersion,stage.RecordOrdinal,stage.TargetFieldCode,stage.Value
      FROM #ExtractedValueStage stage
      WHERE NOT EXISTS
      (
        SELECT 1 FROM map.ExtractedValue existing
        WHERE existing.InboxId=stage.InboxId AND existing.FieldMappingId=stage.FieldMappingId
          AND existing.MappingVersion=stage.MappingVersion AND existing.RecordOrdinal=stage.RecordOrdinal
      );
      DROP TABLE #ExtractedValueStage;
      """, connection, transaction)
    {
      CommandTimeout = ApplyCommandTimeoutSeconds
    })
    {
      await insert.ExecuteNonQueryAsync(cancellationToken);
    }

    await transaction.CommitAsync(cancellationToken);
  }

  private static async Task QuarantineAsync(
    SqlConnection connection,
    long inboxId,
    string reason,
    CancellationToken cancellationToken)
  {
    await using var command = new SqlCommand("""
      UPDATE raw.Inbox SET Status=N'Quarantined',ProcessedUtc=SYSUTCDATETIME(),FailureReason=LEFT(@Reason,2000)
      WHERE InboxId=@InboxId AND Status=N'Pending';
      """, connection);
    command.Parameters.Add("@InboxId", SqlDbType.BigInt).Value = inboxId;
    command.Parameters.Add("@Reason", SqlDbType.NVarChar, 2000).Value = reason;
    await command.ExecuteNonQueryAsync(cancellationToken);
  }

  private sealed record InboxMapping(
    long InboxId,
    string PayloadXml,
    string RecordXPath,
    List<FieldMapping> Mappings);
}
