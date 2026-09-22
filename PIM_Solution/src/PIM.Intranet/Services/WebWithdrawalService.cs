using System.Data;
using System.Text.Json;
using Microsoft.Data.SqlClient;

namespace PIM.Intranet.Services;

/// <summary>
/// Kljukica spletišča, ki jo je PIM sam odstranil, ker artikel na to spletišče ne sme več (251,
/// <c>pim.WebShopWithdrawal</c>). Razlog je zapisan ob umiku: po odkljukanju spletni profil artikla ne
/// validira več (182/248), zato napak za splet na kartici ni več videti.
/// </summary>
/// <param name="WithdrawalId">null pri predogledu (nič še ni umaknjeno).</param>
/// <param name="MissingFields">Kode polj z odprto blokirajočo napako ob umiku, ločene z |.</param>
/// <param name="IsCheckedNow">Ali ima artikel kljukico tega spletišča zdaj (ponovno označen).</param>
public sealed record WebShopWithdrawalRow(
  long? WithdrawalId, int OrganizationId, long ProductId, string ItemId, string WebShopCode, string ShopLabel,
  string ProductName, bool WasInactive, bool HadCategory, string? InvalidProfiles, string? MissingFields,
  string? TriggerSource = null, string? TriggeredBy = null, DateTime? WithdrawnUtc = null,
  DateTime? ReviewedUtc = null, string? ReviewedBy = null, DateTime? RestoredUtc = null, string? RestoredBy = null,
  bool IsCheckedNow = false)
{
  /// <summary>Zakaj — v besedah uporabnika, npr. »manjka: Slika za splet, Spletni naziv (sl)«.</summary>
  public string ReasonText => WebWithdrawalText.Reason(WasInactive, HadCategory, ShopLabel, MissingFields, InvalidProfiles);
}

/// <summary>Nova kljukica, ki je kartica ni obdržala (251, drugi nabor <c>pim.SaveProductWebShops</c>).</summary>
public sealed record WebShopRejection(
  string WebShopCode, string ShopLabel, bool IsActive, bool HasCategory, string? InvalidProfiles, string? MissingFields)
{
  public string ReasonText => WebWithdrawalText.Reason(!IsActive, HasCategory, ShopLabel, MissingFields, InvalidProfiles);
}

/// <param name="PublishedCount">Koliko spletišč ima artikel po zapisu.</param>
/// <param name="Rejected">Nove kljukice, ki jih artikel ni dobil, ker na spletišče ne sme.</param>
public sealed record WebShopSaveOutcome(int PublishedCount, IReadOnlyList<WebShopRejection> Rejected);

/// <summary>Nastavitev podjetja (<c>pim.WebPublicationPolicy</c>) in stanje objave iz <c>out.WebPublication</c>.</summary>
/// <param name="PublishedCount">Artikli, ki so bili v zadnjem izvozu objavljeni.</param>
/// <param name="WithdrawalRowCount">Artikli, ki gredo zdaj v katalog.csv kot odjavna vrstica (prazne »Spletne strani«).</param>
public sealed record WebPublicationPolicy(
  int OrganizationId, bool AutoWithdrawEnabled, int WithdrawalRowDays, DateTime? UpdatedUtc, string? UpdatedBy,
  long OpenWithdrawalCount, long PublishedCount, long WithdrawalRowCount, DateTime? LastExportedUtc);

/// <summary>Besedila za umik — ista na kartici, v seznamu umikov in v sporočilu po shranjevanju.</summary>
public static class WebWithdrawalText
{
  /// <summary>Polja, ki jih splošni seznam imen (<see cref="ProductFieldLabels"/>) ne pozna v spletni obliki.</summary>
  static string FieldLabel(string code) => code switch
  {
    "ProductMedia.Url" => "slika za splet",
    "ProductCategory.CategoryPath" => "kategorija",
    "ProductPrice.Gross" => "cena",
    "ProductPrice.VatRate" => "davčna stopnja cene",
    _ => ProductFieldLabels.For(code),
  };

  public static string Reason(bool wasInactive, bool hadCategory, string shopLabel, string? missingFields, string? invalidProfiles)
  {
    var parts = new List<string>();
    if (wasInactive) parts.Add("artikel ni aktiven v ERP");
    if (!hadCategory) parts.Add($"nima kategorije na spletišču {shopLabel}");
    var fields = (missingFields ?? "")
      .Split('|', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
      // »Brez kategorije« je že povedano zgoraj.
      .Where(code => hadCategory || !code.StartsWith("ProductCategory.", StringComparison.Ordinal))
      .Select(FieldLabel)
      .Distinct(StringComparer.OrdinalIgnoreCase)
      .ToList();
    if (fields.Count > 0) parts.Add("manjka: " + string.Join(", ", fields));
    if (parts.Count == 0)
      parts.Add(string.IsNullOrWhiteSpace(invalidProfiles) ? "ni veljaven za splet" : $"ni veljaven v profilu {invalidProfiles}");
    return string.Join("; ", parts);
  }

  /// <summary>
  /// En stavek za artikel (brez končne pike): »Artikel X je umaknjen s spletišč svetila, videlektro — manjka: slika za splet«.
  /// Razlog je po spletišču lahko različen; pove se vsak različen razlog enkrat.
  /// </summary>
  public static IReadOnlyList<string> PerProduct(IEnumerable<WebShopWithdrawalRow> rows) =>
    rows.GroupBy(row => (row.ProductId, row.ItemId))
      .Select(product =>
      {
        var shops = string.Join(", ", product.Select(row => row.ShopLabel).Distinct(StringComparer.OrdinalIgnoreCase));
        var reasons = string.Join(" · ", product.Select(row => row.ReasonText).Distinct(StringComparer.Ordinal));
        return $"Artikel {product.Key.ItemId} je umaknjen s spletišč {shops} — {reasons}";
      })
      .ToList();

  public static string Source(string? triggerSource) => triggerSource switch
  {
    "KARTICA" => "kartica artikla",
    "KATEGORIJE" => "kategorije artikla",
    "DELOVNI_LIST" => "uvoz delovnega lista",
    "PREVERI" => "Preveri zdaj",
    "VALIDACIJA" => "urna validacija",
    "IZVOZ" => "izvoz katalog.csv",
    "ROCNO" => "ročni umik",
    null or "" => "—",
    _ => triggerSource,
  };
}

/// <summary>
/// Samodejni umik s spleta (251). Procedure so v migraciji; tu so samo klici in preslikava.
///
/// Pravilo: kljukica spletišča ostane samo, dokler artikel na to spletišče sme — aktiven, s kategorijo
/// na tem spletišču in veljaven v profilih, ki blokirajo splet. Ko ne sme več (npr. uvoz pobriše sliko),
/// PIM kljukico odstrani, razlog zapiše in skrbnikom odpre opozorilo v zvoncu. Umik teče samo pri podjetju,
/// ki ga je skrbnik vklopil (<see cref="SetPolicyAsync"/>); dotlej je na voljo predogled.
/// </summary>
public sealed class WebWithdrawalService(IConfiguration configuration, PimWriteGuard guard)
{
  string ConnectionString => ConnectionStringResolver.Resolve(configuration)
    ?? throw new InvalidOperationException("Povezava PIM ni nastavljena.");

  /// <summary>
  /// Umik po spremembi, ki jo je naredil uporabnik (kartica, kategorije, uvoz, »Preveri zdaj«). Vrne umaknjene
  /// kljukice; prazno, kadar ni kaj umakniti ali umik v podjetju ni vklopljen. Napaka umika ne sme podreti
  /// shranjevanja, ki je že uspelo — zato jo vrne kot prazen seznam (umik ponovi naslednja validacija ali izvoz).
  /// </summary>
  /// <param name="revalidate">true, kadar klicatelj artikla ni pravkar validiral (kategorije, uvoz).</param>
  public async Task<IReadOnlyList<WebShopWithdrawalRow>> AfterChangeAsync(
    IReadOnlyCollection<long> productIds, string source, string? actor, bool revalidate,
    CancellationToken cancellationToken = default)
  {
    if (productIds.Count == 0) return [];
    try
    {
      return await RunAsync(null, productIds, source, actor, revalidate, "AUTO", 600, cancellationToken);
    }
    catch (SqlException)
    {
      return [];
    }
  }

  /// <summary>Isto kot <see cref="AfterChangeAsync"/>, za artikle po šifri (stran kategorij in uvoz poznata šifre).</summary>
  public async Task<IReadOnlyList<WebShopWithdrawalRow>> AfterChangeByItemsAsync(
    int organizationId, IReadOnlyCollection<string> itemIds, string source, string? actor, bool revalidate,
    CancellationToken cancellationToken = default)
  {
    if (itemIds.Count == 0) return [];
    try
    {
      var productIds = await ResolveProductIdsAsync(organizationId, itemIds, cancellationToken);
      return await AfterChangeAsync(productIds, source, actor, revalidate, cancellationToken);
    }
    catch (SqlException)
    {
      return [];
    }
  }

  /// <summary>Kaj bi samodejni umik zdaj odkljukal — nič ne spremeni.</summary>
  public Task<IReadOnlyList<WebShopWithdrawalRow>> PreviewAsync(int organizationId, CancellationToken cancellationToken = default) =>
    RunAsync(organizationId, null, "ROCNO", null, false, "PREVIEW", 300, cancellationToken);

  /// <summary>Skrbnik umakne zdaj, ne glede na vklop (npr. prvi pregledani umik pred vklopom).</summary>
  public async Task<IReadOnlyList<WebShopWithdrawalRow>> WithdrawNowAsync(int organizationId, string actor, CancellationToken cancellationToken = default)
  {
    await guard.RequireAsync(PimPolicies.WebPublicationSettings);
    return await RunAsync(organizationId, null, "ROCNO", actor, true, "FORCE", 1800, cancellationToken);
  }

  public async Task<IReadOnlyList<WebShopWithdrawalRow>> GetWithdrawalsAsync(
    int organizationId, bool onlyOpen, string? search, int take = 500, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.GetWebShopWithdrawals", connection)
      { CommandType = CommandType.StoredProcedure, CommandTimeout = 60 };
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@State", SqlDbType.NVarChar, 10).Value = onlyOpen ? "OPEN" : "ALL";
    command.Parameters.Add("@Search", SqlDbType.NVarChar, 200).Value = string.IsNullOrWhiteSpace(search) ? DBNull.Value : search.Trim();
    command.Parameters.Add("@Take", SqlDbType.Int).Value = take;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    return await ReadRowsAsync(reader, full: true, cancellationToken);
  }

  /// <summary>Umiki artikla, ki jih uporabnik še ni popravil (kljukica ni ponovno sprejeta) — pasica na kartici.</summary>
  public async Task<IReadOnlyList<WebShopWithdrawalRow>> GetForProductAsync(long productId, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.GetProductWebShopWithdrawals", connection)
      { CommandType = CommandType.StoredProcedure, CommandTimeout = 30 };
    command.Parameters.Add("@ProductId", SqlDbType.BigInt).Value = productId;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    return await ReadRowsAsync(reader, full: true, cancellationToken);
  }

  /// <summary>Označi umike kot pregledane (vsi odprti podjetja, če <paramref name="withdrawalIds"/> ni podan); zapre opozorilo.</summary>
  public async Task<int> ReviewAsync(int organizationId, IReadOnlyCollection<long>? withdrawalIds, string actor, CancellationToken cancellationToken = default)
  {
    await guard.RequireAsync(PimPolicies.CatalogWrite);
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("pim.ReviewWebShopWithdrawals", connection)
      { CommandType = CommandType.StoredProcedure, CommandTimeout = 60 };
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@WithdrawalIdsJson", SqlDbType.NVarChar, -1).Value =
      withdrawalIds is null ? DBNull.Value : JsonSerializer.Serialize(withdrawalIds);
    command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = actor;
    return Convert.ToInt32(await command.ExecuteScalarAsync(cancellationToken));
  }

  public async Task<WebPublicationPolicy> GetPolicyAsync(int organizationId, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.GetWebPublicationPolicy", connection)
      { CommandType = CommandType.StoredProcedure, CommandTimeout = 30 };
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    return await reader.ReadAsync(cancellationToken)
      ? ReadPolicy(reader)
      : new(organizationId, false, 14, null, null, 0, 0, 0, null);
  }

  public async Task<WebPublicationPolicy> SetPolicyAsync(
    int organizationId, bool autoWithdrawEnabled, int withdrawalRowDays, string actor, CancellationToken cancellationToken = default)
  {
    await guard.RequireAsync(PimPolicies.WebPublicationSettings);
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.SetWebPublicationPolicy", connection)
      { CommandType = CommandType.StoredProcedure, CommandTimeout = 30 };
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@AutoWithdrawEnabled", SqlDbType.Bit).Value = autoWithdrawEnabled;
    command.Parameters.Add("@WithdrawalRowDays", SqlDbType.Int).Value = withdrawalRowDays;
    command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = actor;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    return await reader.ReadAsync(cancellationToken)
      ? ReadPolicy(reader)
      : throw new InvalidOperationException("Nastavitev objave na splet ni bila zapisana.");
  }

  async Task<IReadOnlyList<WebShopWithdrawalRow>> RunAsync(
    int? organizationId, IReadOnlyCollection<long>? productIds, string source, string? actor, bool revalidate,
    string mode, int timeoutSeconds, CancellationToken cancellationToken)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("pim.WithdrawIneligibleWebShops", connection)
      { CommandType = CommandType.StoredProcedure, CommandTimeout = timeoutSeconds };
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = (object?)organizationId ?? DBNull.Value;
    command.Parameters.Add("@ProductIdsJson", SqlDbType.NVarChar, -1).Value =
      productIds is null ? DBNull.Value : JsonSerializer.Serialize(productIds);
    command.Parameters.Add("@TriggerSource", SqlDbType.NVarChar, 50).Value = source;
    command.Parameters.Add("@TriggeredBy", SqlDbType.NVarChar, 200).Value = (object?)actor ?? DBNull.Value;
    command.Parameters.Add("@Revalidate", SqlDbType.Bit).Value = revalidate;
    command.Parameters.Add("@Mode", SqlDbType.NVarChar, 10).Value = mode;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    return await ReadRowsAsync(reader, full: false, cancellationToken);
  }

  async Task<IReadOnlyList<long>> ResolveProductIdsAsync(int organizationId, IReadOnlyCollection<string> itemIds, CancellationToken cancellationToken)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("""
      SELECT product.ProductId
      FROM canon.Product AS product
      WHERE product.OrganizationId = @OrganizationId
        AND product.ItemID IN (SELECT value FROM OPENJSON(@ItemIdsJson));
      """, connection) { CommandTimeout = 60 };
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@ItemIdsJson", SqlDbType.NVarChar, -1).Value = JsonSerializer.Serialize(itemIds.Distinct());
    var ids = new List<long>();
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    while (await reader.ReadAsync(cancellationToken)) ids.Add(reader.GetInt64(0));
    return ids;
  }

  static async Task<IReadOnlyList<WebShopWithdrawalRow>> ReadRowsAsync(SqlDataReader reader, bool full, CancellationToken cancellationToken)
  {
    var rows = new List<WebShopWithdrawalRow>();
    while (await reader.ReadAsync(cancellationToken))
    {
      var row = new WebShopWithdrawalRow(
        PimDb.NullableInt64(reader, "WebShopWithdrawalId"), PimDb.Int32(reader, "OrganizationId"), PimDb.Int64(reader, "ProductId"),
        PimDb.TextOrEmpty(reader, "ItemID"), PimDb.TextOrEmpty(reader, "WebShopCode"), PimDb.TextOrEmpty(reader, "ShopLabel"),
        PimDb.TextOrEmpty(reader, "ProductName"), PimDb.Bool(reader, "WasInactive"), PimDb.Bool(reader, "HadCategory"),
        PimDb.Text(reader, "InvalidProfiles"), PimDb.Text(reader, "MissingFields"),
        WithdrawnUtc: PimDb.NullableDateTime(reader, "WithdrawnUtc"));
      if (full)
        row = row with
        {
          TriggerSource = PimDb.Text(reader, "TriggerSource"), TriggeredBy = PimDb.Text(reader, "TriggeredBy"),
          ReviewedUtc = PimDb.NullableDateTime(reader, "ReviewedUtc"), ReviewedBy = PimDb.Text(reader, "ReviewedBy"),
          RestoredUtc = PimDb.NullableDateTime(reader, "RestoredUtc"), RestoredBy = PimDb.Text(reader, "RestoredBy"),
          IsCheckedNow = PimDb.Bool(reader, "IsCheckedNow"),
        };
      rows.Add(row);
    }
    return rows;
  }

  static WebPublicationPolicy ReadPolicy(SqlDataReader reader) => new(
    PimDb.Int32(reader, "OrganizationId"), PimDb.Bool(reader, "AutoWithdrawEnabled"), PimDb.Int32(reader, "WithdrawalRowDays"),
    PimDb.NullableDateTime(reader, "UpdatedUtc"), PimDb.Text(reader, "UpdatedBy"),
    PimDb.Int64(reader, "OpenWithdrawalCount"), PimDb.Int64(reader, "PublishedCount"), PimDb.Int64(reader, "WithdrawalRowCount"),
    PimDb.NullableDateTime(reader, "LastExportedUtc"));
}
