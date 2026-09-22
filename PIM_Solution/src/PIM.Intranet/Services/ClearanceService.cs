using System.Data;
using System.Globalization;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using PIM.Operations;

namespace PIM.Intranet.Services;

/// <param name="ProductId"><c>null</c> pomeni, da šifra ne ustreza nobenemu artiklu tega podjetja.</param>
public sealed record ClearanceImportRow(
  int RowNumber, string Sifra, long? ProductId,
  decimal? Kolicina, decimal? RednaCena, decimal? PopustOdstotek, decimal? OdprodajnaCena);

public sealed record ClearanceImportPreview(
  int OrganizationId, string Vir, string? IzvornaDatoteka,
  IReadOnlyList<ClearanceImportRow> Rows, IReadOnlyList<string> Problems)
{
  public int MatchedCount => Rows.Count(row => row.ProductId is not null);
  public int UnmatchedCount => Rows.Count(row => row.ProductId is null);
}

/// <param name="NeujemajoceSifre">Šifre brez ujemajočega artikla v tem podjetju; uvoz jih je preskočil.</param>
public sealed record ClearanceImportOutcome(
  int RequestedCount, int MatchedCount, int UnmatchedCount, IReadOnlyList<string> NeujemajoceSifre);

public sealed record ClearanceItemRow(
  long ClearanceItemId, string Vir, string Sifra,
  decimal? Kolicina, decimal? RednaCena, decimal? PopustOdstotek, decimal? OdprodajnaCena,
  string? IzvornaDatoteka, DateTime ImportiranoUtc, bool IsActive, DateTime? EndedUtc, string? EndedBy);

/// <summary>
/// Odprodaja artiklov (232): ročni uvoz dobaviteljevega odprodajnega seznama (npr. Azzardo) po
/// šifri artikla, in branje/zaključevanje za kartico izdelka.
///
/// Bere zvezek z <see cref="WorkbookTable"/> (isti bralnik brez ClosedXML/EPPlus kot
/// <see cref="ProductWorkbookService"/>) — za razliko od tistega servisa gre tu za poljubno
/// dobaviteljevo obliko, ne za PIM-ov lastni delovni list, zato ni pogodbe s fiksnim naborom
/// stolpcev: uvoz prepozna samo štiri naslove (Šifra, Količina, Cena, Popust), ostale prezre.
/// </summary>
public sealed class ClearanceService(IConfiguration configuration)
{
  static readonly string[] HeaderHints = ["Šifra", "Količina", "Cena", "Popust"];

  string ConnectionString => ConnectionStringResolver.Resolve(configuration)
    ?? throw new InvalidOperationException("Povezava PIM ni nastavljena.");

  public async Task<ClearanceImportPreview> PreviewAsync(
    Stream file, int organizationId, string vir, string? izvornaDatoteka, CancellationToken cancellationToken = default)
  {
    var problems = new List<string>();
    var sheet = WorkbookTable.Read(file, sheetName: null, headerHints: HeaderHints);

    var sifraIndex = FindColumn(sheet.Headers, "Šifra");
    var kolicinaIndex = FindColumn(sheet.Headers, "Količina");
    var cenaIndex = FindColumn(sheet.Headers, "Cena");
    var popustIndex = FindColumn(sheet.Headers, "Popust");

    if (sifraIndex < 0)
    {
      problems.Add("Datoteka nima stolpca 'Šifra'.");
      return new(organizationId, vir, izvornaDatoteka, [], problems);
    }

    var parsed = new List<(string Sifra, decimal? Kolicina, decimal? RednaCena, decimal? Popust)>();
    foreach (var raw in sheet.Rows)
    {
      var sifra = Cell(raw, sifraIndex)?.Trim();
      if (string.IsNullOrEmpty(sifra)) continue;
      parsed.Add((sifra, ParseDecimal(Cell(raw, kolicinaIndex)), ParseDecimal(Cell(raw, cenaIndex)), ParseDecimal(Cell(raw, popustIndex))));
    }

    var sifre = parsed.Select(row => row.Sifra).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
    var matched = await LookupProductIdsAsync(organizationId, sifre, cancellationToken);

    var rows = parsed.Select((row, index) =>
    {
      decimal? odprodajnaCena = row.RednaCena is { } redna && row.Popust is { } popust
        ? Math.Round(redna * (1 - popust / 100m), 2)
        : null;
      var productId = matched.TryGetValue(row.Sifra, out var id) ? id : (long?)null;
      return new ClearanceImportRow(index + 2, row.Sifra, productId, row.Kolicina, row.RednaCena, row.Popust, odprodajnaCena);
    }).ToList();

    return new ClearanceImportPreview(organizationId, vir, izvornaDatoteka, rows, problems);
  }

  public async Task<ClearanceImportOutcome> ApplyAsync(ClearanceImportPreview preview, string actor, CancellationToken cancellationToken = default)
  {
    var items = preview.Rows.Select(row => new
    {
      sifra = row.Sifra,
      kolicina = row.Kolicina,
      rednaCena = row.RednaCena,
      popustOdstotek = row.PopustOdstotek,
      odprodajnaCena = row.OdprodajnaCena,
    });

    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("pim.SaveClearanceItems", connection)
    {
      CommandType = CommandType.StoredProcedure,
      CommandTimeout = 300,
    };
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = preview.OrganizationId;
    command.Parameters.Add("@Vir", SqlDbType.NVarChar, 100).Value = preview.Vir;
    command.Parameters.Add("@ItemsJson", SqlDbType.NVarChar, -1).Value = JsonSerializer.Serialize(items);
    command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = actor;
    command.Parameters.Add("@IzvornaDatoteka", SqlDbType.NVarChar, 260).Value = (object?)preview.IzvornaDatoteka ?? DBNull.Value;

    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    if (!await reader.ReadAsync(cancellationToken)) return new(0, 0, 0, []);
    var outcome = new ClearanceImportOutcome(
      (int)PimDb.Int64(reader, "RequestedCount"), (int)PimDb.Int64(reader, "MatchedCount"),
      (int)PimDb.Int64(reader, "UnmatchedCount"), []);

    var unmatched = new List<string>();
    if (await reader.NextResultAsync(cancellationToken))
      while (await reader.ReadAsync(cancellationToken))
        unmatched.Add(PimDb.TextOrEmpty(reader, "NeujemajocaSifra"));
    return outcome with { NeujemajoceSifre = unmatched };
  }

  public async Task<IReadOnlyList<ClearanceItemRow>> GetForProductAsync(long productId, CancellationToken cancellationToken = default)
  {
    var rows = new List<ClearanceItemRow>();
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.GetClearanceItemsForProduct", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.Add("@ProductId", SqlDbType.BigInt).Value = productId;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    while (await reader.ReadAsync(cancellationToken))
      rows.Add(new(
        PimDb.Int64(reader, "ClearanceItemId"), PimDb.TextOrEmpty(reader, "Vir"), PimDb.TextOrEmpty(reader, "Sifra"),
        PimDb.NullableDecimal(reader, "Kolicina"), PimDb.NullableDecimal(reader, "RednaCena"),
        PimDb.NullableDecimal(reader, "PopustOdstotek"), PimDb.NullableDecimal(reader, "OdprodajnaCena"),
        PimDb.Text(reader, "IzvornaDatoteka"), PimDb.DateTimeValue(reader, "ImportiranoUtc"),
        PimDb.Bool(reader, "IsActive"), PimDb.NullableDateTime(reader, "EndedUtc"), PimDb.Text(reader, "EndedBy")));
    return rows;
  }

  public async Task EndAsync(long clearanceItemId, string actor, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("pim.EndClearanceItem", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.Add("@ClearanceItemId", SqlDbType.BigInt).Value = clearanceItemId;
    command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = actor;
    await command.ExecuteNonQueryAsync(cancellationToken);
  }

  async Task<IReadOnlyDictionary<string, long>> LookupProductIdsAsync(int organizationId, IReadOnlyCollection<string> sifre, CancellationToken cancellationToken)
  {
    var result = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
    if (sifre.Count == 0) return result;

    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("""
      SELECT parsed.value AS Sifra, product.ProductId
      FROM OPENJSON(@SifreJson) parsed
      JOIN canon.Product product ON product.OrganizationId = @OrganizationId AND product.ItemID = parsed.value;
      """, connection);
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@SifreJson", SqlDbType.NVarChar, -1).Value = JsonSerializer.Serialize(sifre);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    while (await reader.ReadAsync(cancellationToken))
      result[PimDb.TextOrEmpty(reader, "Sifra")] = PimDb.Int64(reader, "ProductId");
    return result;
  }

  static int FindColumn(IReadOnlyList<string> headers, string wanted)
  {
    for (var index = 0; index < headers.Count; index++)
      if (WorkbookHeader.Same(headers[index], wanted))
        return index;
    return -1;
  }

  static string? Cell(IReadOnlyList<string> row, int index) => index >= 0 && index < row.Count ? row[index] : null;

  static decimal? ParseDecimal(string? text)
  {
    if (string.IsNullOrWhiteSpace(text)) return null;
    var trimmed = text.Trim().TrimEnd('%', ' ');
    if (decimal.TryParse(trimmed, NumberStyles.Any, CultureInfo.InvariantCulture, out var value)) return value;
    return decimal.TryParse(trimmed.Replace(',', '.'), NumberStyles.Any, CultureInfo.InvariantCulture, out value) ? value : null;
  }
}
