using System.Globalization;
using System.Text;
using Microsoft.Data.SqlClient;
using PIM.StockMapping;

namespace PIM.SaopStockWorker;

/// <summary>Kaj je profil povedal in kaj je iz njega prišlo.</summary>
public sealed record SaopStockOutcome(
  string ProfileCode, string ProviderKind, int Warehouses, int RecordsRead, int Applied, int Quarantined, Guid RunId);

/// <summary>
/// Zaloga iz SAOP: profil iz baze → zahteva → XML → <c>stock.*</c>. Ločeno od <c>Program.cs</c>,
/// da se da pognati proti lokalnemu strežniku brez živega SAOP — enak vzorec kot pri F8.
/// </summary>
public sealed class SaopStockRunner(string connectionString, HttpClient http, Uri baseUrl)
{
  // GetStocks vrne <ArrayOfStockItem><StockItem><ItemID/><Qty/>. Sifra in kolicina sta vse, kar
  // ta vmesnik ponuja; EAN, datum razpolozljivosti in prihajajoca kolicina so pri dobaviteljih,
  // ne tu, zato ostanejo prazni in normalizacija jih ne zahteva.
  static readonly XmlStockSchema Schema = new("//StockItem", new Dictionary<string, FieldSelector>
  {
    ["SourceItemId"] = new(SelectorKind.XPath, "ItemID/text()"),
    ["Quantity"] = new(SelectorKind.XPath, "Qty/text()")
  });

  static readonly SaopStockProviderRegistry Registry = SaopStockProviderRegistry.CreateDefault();

  public async Task<SaopStockOutcome> RunAsync(int organizationId, int? pageSize = null, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(connectionString);
    await connection.OpenAsync(cancellationToken);

    var profile = await ReadProfileAsync(connection, organizationId, cancellationToken)
      ?? throw new InvalidOperationException(
        $"Podjetje {organizationId} nima vklopljenega profila v stock.SaopProviderProfile.");

    var warehouses = profile.SelectionMode == "List"
      ? ParseWarehouseList(profile.WarehouseIdsJson)
      : await ReadActiveWarehousesAsync(connection, organizationId, cancellationToken);

    var request = Registry.CreateRequest(
      new(profile.ProviderKind, profile.RegisteredViewId, warehouses, pageSize), baseUrl);

    // Brez glave OrganisationId vrne SAOP podatke napacnega podjetja ali 401 — enako kot pri
    // katalogu (PIM.KatalogWorker.SaopApiClient). Glava sodi na zahtevo, ne na odjemalca, ker
    // isti odjemalec obdela vec podjetij zapored.
    request.Headers.Remove("OrganisationId");
    request.Headers.Add("OrganisationId", organizationId.ToString(CultureInfo.InvariantCulture));

    using var response = await http.SendAsync(request, cancellationToken);
    var payload = await response.Content.ReadAsStringAsync(cancellationToken);
    if (!response.IsSuccessStatusCode)
      throw new InvalidOperationException(
        $"SAOP je vrnil {(int)response.StatusCode}: {payload[..Math.Min(payload.Length, 300)]}");

    var records = new StockMappingExtractor().ExtractXml(payload, Schema);
    var hash = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes(payload))).ToLowerInvariant();

    // Posnetek je trenutek klica: zaloga velja za takrat, ne za trenutek zapisa v bazo.
    var snapshotUtc = DateTime.UtcNow;
    var sourceCode = await ReadStockSourceCodeAsync(connection, organizationId, cancellationToken);
    var (runId, applied, quarantined) = await new StockLandingWriter(connectionString).PersistAsync(
      organizationId, sourceCode, "SAOP", request.RequestUri!.PathAndQuery, snapshotUtc, hash, records,
      "yyyy-MM-dd", cancellationToken: cancellationToken);

    await MarkSuccessAsync(connection, profile.ProfileId, cancellationToken);
    return new(profile.ProfileCode, profile.ProviderKind, warehouses.Count, records.Count, applied, quarantined, runId);
  }

  sealed record Profile(int ProfileId, string ProfileCode, string ProviderKind, string? RegisteredViewId, string? SelectionMode, string? WarehouseIdsJson);

  static async Task<Profile?> ReadProfileAsync(SqlConnection connection, int organizationId, CancellationToken cancellationToken)
  {
    // Najnizja Priority zmaga: registrirani pogled je pri Vidadrii pred GetStocks, kadar je vklopljen.
    await using var command = new SqlCommand("""
      SELECT TOP(1) SaopProviderProfileId, ProfileCode, ProviderKind, RegisteredViewId, WarehouseSelectionMode, WarehouseIdsJson
      FROM stock.SaopProviderProfile
      WHERE OrganizationId=@OrganizationId AND Enabled=1
      ORDER BY Priority, SaopProviderProfileId;
      """, connection);
    command.Parameters.AddWithValue("@OrganizationId", organizationId);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    if (!await reader.ReadAsync(cancellationToken)) return null;
    return new(reader.GetInt32(0), reader.GetString(1), reader.GetString(2),
      reader.IsDBNull(3) ? null : reader.GetString(3),
      reader.IsDBNull(4) ? null : reader.GetString(4),
      reader.IsDBNull(5) ? null : reader.GetString(5));
  }

  static async Task<IReadOnlyList<int>> ReadActiveWarehousesAsync(SqlConnection connection, int organizationId, CancellationToken cancellationToken)
  {
    // Sifra skladisca je pri SAOP niz z vodilnimi niclami ("0000016"), endpoint pa hoce stevilko.
    // Ime skladisca je v registru zaradi prikaza; v zahtevo gre samo sifra.
    await using var command = new SqlCommand("""
      SELECT WarehouseCode FROM canon.Warehouse
      WHERE OrganizationId=@OrganizationId AND IsActive=1
      ORDER BY WarehouseCode;
      """, connection);
    command.Parameters.AddWithValue("@OrganizationId", organizationId);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    var ids = new List<int>();
    while (await reader.ReadAsync(cancellationToken))
    {
      if (int.TryParse(reader.GetString(0), NumberStyles.Integer, CultureInfo.InvariantCulture, out var id)) ids.Add(id);
    }
    if (ids.Count == 0)
      throw new InvalidOperationException(
        $"Podjetje {organizationId} nima aktivnih skladisc v canon.Warehouse; zajemi sifrant Warehouses.");
    return ids;
  }

  static IReadOnlyList<int> ParseWarehouseList(string? json)
  {
    if (string.IsNullOrWhiteSpace(json)) throw new InvalidOperationException("Nacin 'List' brez WarehouseIdsJson.");
    using var document = System.Text.Json.JsonDocument.Parse(json);
    var ids = document.RootElement.EnumerateArray()
      .Select(element => element.ValueKind == System.Text.Json.JsonValueKind.Number
        ? element.GetInt32()
        : int.Parse(element.GetString() ?? "0", CultureInfo.InvariantCulture))
      .Where(id => id > 0)
      .ToArray();
    if (ids.Length == 0) throw new InvalidOperationException("WarehouseIdsJson ne vsebuje nobene sifre.");
    return ids;
  }

  static async Task<string> ReadStockSourceCodeAsync(SqlConnection connection, int organizationId, CancellationToken cancellationToken)
  {
    await using var command = new SqlCommand("""
      SELECT TOP(1) SourceCode FROM map.SourceConnector
      WHERE OrganizationId=@OrganizationId AND SourceCode LIKE N'SAOP%[_]STOCK' AND IsActive=1
      ORDER BY SourceConnectorId;
      """, connection);
    command.Parameters.AddWithValue("@OrganizationId", organizationId);
    var value = await command.ExecuteScalarAsync(cancellationToken) as string;
    return value ?? throw new InvalidOperationException(
      $"Podjetje {organizationId} nima konektorja za zalogo iz SAOP (migracija 066).");
  }

  static async Task MarkSuccessAsync(SqlConnection connection, int profileId, CancellationToken cancellationToken)
  {
    await using var command = new SqlCommand(
      "UPDATE stock.SaopProviderProfile SET LastSuccessUtc=SYSUTCDATETIME() WHERE SaopProviderProfileId=@Id;", connection);
    command.Parameters.AddWithValue("@Id", profileId);
    await command.ExecuteNonQueryAsync(cancellationToken);
  }
}
