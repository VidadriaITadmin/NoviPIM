using System.Text.RegularExpressions;
using Microsoft.Data.SqlClient;
using PIM.Operations;
using Xunit;

namespace PIM.ChangeTracking.Integration;

/// <summary>
/// #7: pregled »Spremembe iz XML« (zgodovina polj, ki jo je zapisal zajem dobaviteljevega XML) in
/// predlagana kategorija kandidata. Pogodbeni del bere izvorne datoteke (brez baze), integracijski
/// del izvede ISTI SQL, ki je v storitvi (prebran iz izvorne datoteke), nad razvojno bazo — tako
/// test ne more preverjati kopije, ki bi se od storitve oddaljila.
/// </summary>
public sealed class SupplierXmlChangesTests
{
  static readonly string Root = FindRoot();
  static string Read(params string[] parts) => File.ReadAllText(Path.Combine([Root, .. parts]));
  static string Page => Read("src", "PIM.Intranet", "Components", "Pages", "IngestCandidates.razor");
  static string Changes => Read("src", "PIM.Intranet", "Components", "Pages", "SupplierXmlChanges.razor");
  static string ReadService => Read("src", "PIM.Intranet", "Services", "SupplierCandidateReadService.cs");
  static string SaopService => Read("src", "PIM.Intranet", "Services", "SupplierCandidateSaopService.cs");

  [Fact]
  public void Changes_view_is_a_tab_of_the_candidates_page_with_state_in_the_url()
  {
    Assert.Contains("pogled=spremembe", Page);
    Assert.Contains("<SupplierXmlChanges", Page);
    Assert.Contains("aria-current=", Page);
    // Filtri gredo v naslov (deljiva povezava, Nazaj deluje), ne v stanje komponente.
    Assert.Contains("Navigation.NavigateTo(Href(", Changes);
    foreach (var key in new[] { "\"podjetje\"", "\"vir\"", "\"vrsta\"", "\"isci\"", "\"dni\"", "\"razvrsti\"", "\"stran\"" })
      Assert.Contains(key, Changes);
  }

  [Fact]
  public void Changes_view_uses_shared_components_and_accessibility_contract()
  {
    foreach (var component in new[] { "<PimState", "<PimTable", "<PimPager", "<PimChip" })
      Assert.Contains(component, Changes);
    Assert.Contains("Caption=\"@Caption\"", Changes);
    Assert.Contains("role=\"search\"", Changes);
    Assert.Contains("role=\"status\"", Changes);
    Assert.Contains("Počisti filtre", Changes);
    // Brez Bootstrapa: razred kot samostojna beseda (»ui-card« je naš, »card« ni).
    Assert.DoesNotMatch(new Regex("class=\"(?:[^\"]*\\s)?(btn|row|col-\\w+|card|form-control)(?:\\s[^\"]*)?\""), Changes);
    // Šifra je glavni ključ in vodi na kartico; EAN ni prikazan kot ključ.
    Assert.Contains("href=\"izdelki/@row.ProductId\"", Changes);
    Assert.DoesNotContain("row.Ean", Changes);
    // Odrezana vrednost (400 znakov v zgodovini) ne sme izgledati kot celo besedilo.
    Assert.Contains("skrajšano", Changes);
  }

  [Fact]
  public void Supplier_changes_are_separated_from_saop_mapping_and_filtered_by_row_organization()
  {
    // XML_FEED nosi tudi preslikava SAOP (PIM.XmlMapping:SAOP_*): dobavitelj = vir FILE_XML po ChangedBy.
    Assert.Contains("ConnectorType = N'FILE_XML'", ReadService);
    Assert.Contains("paket.ChangedBy = N'PIM.XmlMapping:' + vir.SourceCode", ReadService);
    // Paket XML nima podjetja; filter podjetja mora biti na vrstici zgodovine.
    Assert.Contains("h.OrganizationId = @OrganizationId", ReadService);
    Assert.DoesNotContain("paket.OrganizationId", ReadService);
    // Strežniško listanje in štetje.
    Assert.Contains("OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY", ReadService);
  }

  [Fact]
  public void Saop_approval_from_candidates_page_goes_through_the_guarded_service()
  {
    Assert.DoesNotContain("Data.ApproveItemAsync", Page);
    Assert.Contains("Saop.ApproveAsync(", Page);
    Assert.Matches(new Regex(@"ApproveAsync\([^)]*\)\s*\{\s*await guard\.RequireAsync\(PimPolicies\.SaopWrite\);", RegexOptions.Singleline), SaopService);
    Assert.Matches(new Regex(@"QueueAsync\(.*?await guard\.RequireAsync\(PimPolicies\.SaopWrite\);", RegexOptions.Singleline), SaopService);
    Assert.Matches(new Regex(@"SendNowAsync\([^)]*\)\s*\{\s*await guard\.RequireAsync\(PimPolicies\.SaopWrite\);", RegexOptions.Singleline), SaopService);
    // Brez pravice gumb ni aktiven (videz); servis zgoraj je varovalka.
    Assert.Contains("!CanSaop", Page);
    Assert.Contains("Samo za branje", Page);
  }

  [Fact]
  public void Candidate_category_uses_the_same_path_key_as_resolve_product_categories()
  {
    Assert.Contains("CategoryCell(row)", Page);
    Assert.Contains("Kategorija dobavitelja nima preslikave", Page);
    var sql = Constant("CategoryPredictionSql");
    Assert.Contains("map.CategoryPathMap", sql);
    Assert.Contains("N'___' + REPLACE(pot.Level2, N' ', N'_')", sql);
    Assert.Contains("LOWER(CONCAT(", sql);
    Assert.Contains("slovar.IsActive = 1", sql);
  }

  [RequiresPimConnectionFact]
  public async Task Changes_query_counts_the_same_rows_as_a_direct_select()
  {
    await using var connection = new SqlConnection(LocalSettings.ConnectionString()!);
    await connection.OpenAsync();
    // Isti izbor paketov kot storitev, nato število vrstic za podjetje 2 — primerjava z neposrednim
    // SELECT iz načrta preverjanja (#7: ChangedBy dobaviteljev, podjetje v vrstici zgodovine).
    // Razvojno bazo hkrati polnijo druga vrata (zajem XML v testih F5), zato štetje ponovimo, če se
    // med obema poizvedbama spremeni; obe bereta brez deljenih zaklepov (kot storitev), da nista žrtvi zastoja.
    long viaService = -1, direct = -2;
    for (var poskus = 0; poskus < 5 && viaService != direct; poskus++)
    {
      if (poskus > 0) await Task.Delay(TimeSpan.FromSeconds(2));
      viaService = await ScalarAsync<long>(connection, Constant("SupplierXmlBatchesSql") + """

        SELECT COUNT_BIG(*) FROM pim.ProductFieldHistory h
        INNER JOIN @Paket paket ON paket.ChangeBatchId = h.ChangeBatchId
        WHERE h.OrganizationId = 2;
        """, ("@SourceCode", DBNull.Value));
      direct = await ScalarAsync<long>(connection, """
        SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
        SELECT COUNT_BIG(*) FROM pim.ProductFieldHistory h
        INNER JOIN pim.ProductChangeBatch b ON b.ChangeBatchId = h.ChangeBatchId
        WHERE b.ChangeSource = N'XML_FEED'
          AND b.ChangedBy IN (SELECT N'PIM.XmlMapping:' + SourceCode FROM map.SourceConnector WHERE ConnectorType = N'FILE_XML')
          AND h.OrganizationId = 2;
        """);
    }
    Assert.Equal(direct, viaService);

    var saopRows = await ScalarAsync<long>(connection, Constant("SupplierXmlBatchesSql") + """

      SELECT COUNT_BIG(*) FROM @Paket paket
      INNER JOIN pim.ProductChangeBatch b ON b.ChangeBatchId = paket.ChangeBatchId
      WHERE b.ChangedBy LIKE N'PIM.XmlMapping:SAOP%';
      """, ("@SourceCode", DBNull.Value));
    Assert.Equal(0, saopRows);
  }

  [RequiresPimConnectionFact]
  public async Task Category_prediction_runs_for_a_candidate_from_the_latest_classification_record()
  {
    await using var connection = new SqlConnection(LocalSettings.ConnectionString()!);
    await connection.OpenAsync();
    await using var transaction = (SqlTransaction)await connection.BeginTransactionAsync();
    try
    {
      // Kandidat iz obstoječega zapisa zajema (šifra = EAN, kot pri NW/BT); vse se na koncu povrne.
      await using var insert = new SqlCommand("""
        DECLARE @Nov TABLE (Id bigint);
        INSERT map.SupplierProductCandidate (OrganizationId, SourceCode, ItemID, EAN, InboxId, RecordOrdinal, Status, IsActive, ItemIdFromEan)
        OUTPUT inserted.SupplierProductCandidateId INTO @Nov
        SELECT TOP (1) inbox.OrganizationId, inbox.SourceCode, CONVERT(nvarchar(100), kljuc.Value), CONVERT(nvarchar(100), kljuc.Value),
          inbox.InboxId, kljuc.RecordOrdinal, N'PENDING', 1, 1
        FROM raw.Inbox inbox
        INNER JOIN map.ExtractedValue kljuc ON kljuc.InboxId = inbox.InboxId AND kljuc.TargetFieldCode = N'Product.EAN'
        WHERE inbox.SourceCode IN (N'NW_XML', N'BT_XML') AND inbox.EntityType = N'Classification'
          AND EXISTS (SELECT 1 FROM map.ExtractedValue raven WHERE raven.InboxId = kljuc.InboxId AND raven.RecordOrdinal = kljuc.RecordOrdinal
                      AND raven.TargetFieldCode = N'ProductCategory.SourceLevel1')
          AND NOT EXISTS (SELECT 1 FROM map.SupplierProductCandidate obstojec
                          WHERE obstojec.OrganizationId = inbox.OrganizationId AND obstojec.ItemID = CONVERT(nvarchar(100), kljuc.Value))
        ORDER BY kljuc.ExtractedValueId DESC;
        SELECT TOP (1) Id FROM @Nov;
        """, connection, transaction) { CommandTimeout = 120 };
      var created = await insert.ExecuteScalarAsync();
      if (created is null or DBNull) return; // razvojna baza nima zajema z dobaviteljevo kategorijo — ni česa preveriti

      await using var predict = new SqlCommand(Constant("CategoryPredictionSql"), connection, transaction) { CommandTimeout = 120 };
      predict.Parameters.AddWithValue("@Ids", $"[{created}]");
      var rows = 0;
      await using (var reader = await predict.ExecuteReaderAsync())
        while (await reader.ReadAsync())
        {
          rows++;
          Assert.Equal(Convert.ToInt64(created), reader.GetInt64(reader.GetOrdinal("SupplierProductCandidateId")));
          Assert.False(reader.IsDBNull(reader.GetOrdinal("Level1")));
          Assert.False(string.IsNullOrWhiteSpace(reader.GetString(reader.GetOrdinal("SourcePathKey"))));
        }
      // Ena vrstica na dejavno drevo (preslikana ali ne).
      var trees = await ScalarAsync<int>(connection, """
        SELECT COUNT(DISTINCT spletisce.CategoryTreeCode) FROM canon.WebSite spletisce
        WHERE spletisce.IsActive = 1
          AND EXISTS (SELECT 1 FROM canon.Category kategorija WHERE kategorija.CategoryTreeCode = spletisce.CategoryTreeCode AND kategorija.IsActive = 1);
        """, transaction);
      Assert.Equal(trees, rows);
    }
    finally
    {
      await transaction.RollbackAsync();
    }
  }

  static string Constant(string name)
  {
    var match = Regex.Match(ReadService, name + @" = """"""(.*?)"""""";", RegexOptions.Singleline);
    Assert.True(match.Success, "V storitvi ni SQL konstante " + name + ".");
    return match.Groups[1].Value;
  }

  static Task<T> ScalarAsync<T>(SqlConnection connection, string sql, params (string Name, object Value)[] parameters) =>
    ScalarAsync<T>(connection, sql, null, parameters);

  static Task<T> ScalarAsync<T>(SqlConnection connection, string sql, SqlTransaction? transaction) =>
    ScalarAsync<T>(connection, sql, transaction, []);

  static async Task<T> ScalarAsync<T>(SqlConnection connection, string sql, SqlTransaction? transaction, (string Name, object Value)[] parameters)
  {
    await using var command = new SqlCommand(sql, connection, transaction) { CommandTimeout = 120 };
    foreach (var (name, value) in parameters) command.Parameters.AddWithValue(name, value);
    return (T)Convert.ChangeType((await command.ExecuteScalarAsync())!, typeof(T));
  }

  static string FindRoot()
  {
    var current = new DirectoryInfo(AppContext.BaseDirectory);
    while (current is not null)
    {
      if (Directory.Exists(Path.Combine(current.FullName, "sql", "migrations")) && Directory.Exists(Path.Combine(current.FullName, "src")))
        return current.FullName;
      current = current.Parent;
    }
    throw new InvalidOperationException("PIM_Solution ni najden.");
  }
}
