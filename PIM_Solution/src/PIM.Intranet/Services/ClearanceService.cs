using System.Data;
using System.Globalization;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using PIM.Operations;

namespace PIM.Intranet.Services;

/// <param name="ProductId"><c>null</c> pomeni, da šifra ne ustreza nobenemu artiklu tega podjetja.</param>
public sealed record ClearanceImportRow(
  int RowNumber, string Sifra, long? ProductId,
  decimal? Kolicina, decimal? RednaCena, decimal? PopustOdstotek, decimal? OdprodajnaCena,
  bool? Razstavni = null, decimal? Zaloga = null)
{
  /// <summary>Način, ki ga bo vrstica dobila ob uvozu (297): primerjava količine z zalogo v glavnem skladišču.</summary>
  public string Nacin => ClearanceStock.ModeOf(Zaloga, Kolicina);
}

/// <summary>
/// Zaloga v glavnem skladišču ob odprodaji (297). <see cref="Nacin"/> se določi ob vpisu količine:
/// CELA = vsa zaloga je za odprodajo, DEL = del redne zaloge, PREMALO = zaloge manj kot vpisano (napaka),
/// NEZNANA = zaloge ni v PIM.
/// </summary>
/// <param name="Zaloga">Trenutna zaloga v glavnem skladišču.</param>
/// <param name="ZalogaSveza">Posnetek zaloge je mlajši od 30 minut; samo takrat zaloga omeji količino na spletu.</param>
public sealed record ClearanceStock(decimal? Zaloga, bool ZalogaSveza, decimal? ZalogaObVpisu, DateTime? ZalogaObVpisuUtc, string Nacin)
{
  public const string Cela = "CELA", Del = "DEL", Premalo = "PREMALO", Neznana = "NEZNANA";

  public static string ModeOf(decimal? zaloga, decimal? kolicina) =>
    zaloga is not { } stock || kolicina is not { } qty ? Neznana : stock == qty ? Cela : stock > qty ? Del : Premalo;

  public static string Label(string nacin) => nacin switch
  {
    Cela => "vsa zaloga za odprodajo",
    Del => "del redne zaloge",
    Premalo => "zaloge premalo",
    _ => "zaloga ni znana",
  };

  public static string Tone(string nacin) => nacin switch { Cela => "good", Del => "", Premalo => "bad", _ => "warn" };

  internal static ClearanceStock Read(SqlDataReader reader) => new(
    PimDb.NullableDecimal(reader, "Zaloga"), PimDb.Bool(reader, "ZalogaSveza"),
    PimDb.NullableDecimal(reader, "ZalogaObVpisu"), PimDb.NullableDateTime(reader, "ZalogaObVpisuUtc"),
    PimDb.Text(reader, "Nacin") ?? Neznana);
}

/// <param name="HasShowcaseColumn">Datoteka ima stolpec »Razstavni eksponat«; brez njega uvoz oznake ne spreminja.</param>
public sealed record ClearanceImportPreview(
  int OrganizationId, string Vir, string? IzvornaDatoteka,
  IReadOnlyList<ClearanceImportRow> Rows, IReadOnlyList<string> Problems, bool HasShowcaseColumn = false)
{
  public int MatchedCount => Rows.Count(row => row.ProductId is not null);
  public int UnmatchedCount => Rows.Count(row => row.ProductId is null);
}

/// <param name="NeujemajoceSifre">Šifre brez ujemajočega artikla v tem podjetju; uvoz jih je preskočil.</param>
public sealed record ClearanceImportOutcome(
  int RequestedCount, int MatchedCount, int UnmatchedCount, IReadOnlyList<string> NeujemajoceSifre);

/// <summary>Vrstica odprodaje na kartici izdelka (296, intranet.GetClearanceItemsForProduct).</summary>
/// <param name="Kolicina">Preostanek po naročilih kupcev (288); ta gre v katalog.csv.</param>
/// <param name="ZacetnaKolicina">Vpisana količina.</param>
/// <param name="Prodano">Naročeno pri kupcih od vpisa količine.</param>
/// <param name="Narocila">Naročila, ki so zmanjšala količino.</param>
public sealed record ClearanceItemRow(
  long ClearanceItemId, string Vir, string Sifra,
  decimal? Kolicina, decimal? ZacetnaKolicina, decimal Prodano, string? Narocila,
  decimal? RednaCena, decimal? PopustOdstotek, decimal? OdprodajnaCena,
  string? IzvornaDatoteka, DateTime ImportiranoUtc, bool IsActive, DateTime? EndedUtc, string? EndedBy,
  ClearanceStock? Stock = null);

/// <summary>Vrstica strani /izdelki/odprodaja (275, intranet.GetClearanceOverview).</summary>
/// <param name="ClearanceItemId"><c>null</c>: artikel je razstavni eksponat brez aktivne odprodaje.</param>
/// <param name="SpletneStrani">Obkljukane spletne strani, npr. <c>svetila|videlektro</c>; <c>null</c> = nobena.</param>
/// <param name="Kolicina">Preostanek (288): vpisana količina manj naročila kupcev iz SAOP od začetka štetja.</param>
/// <param name="ZacetnaKolicina">Vpisana količina (uvoz ali ročni vnos).</param>
/// <param name="Prodano">Naročeno pri kupcih od vpisa količine (stornirana naročila ne štejejo).</param>
/// <param name="Narocila">Naročila, ki so zmanjšala količino, npr. <c>2026/VNK/3495 (1.00)</c>.</param>
/// <param name="VKatalogu">Artikel gre v katalog.csv z Odprodaja = DA: najnovejša aktivna vrstica, preostanek &gt; 0,
/// aktiven artikel z obkljukano spletno stranjo.</param>
public sealed record ClearanceOverviewRow(
  long? ClearanceItemId, long ProductId, string ItemId, string? Naziv, string? Vir,
  decimal? Kolicina, decimal? ZacetnaKolicina, decimal Prodano, string? Narocila,
  decimal? PopustOdstotek, decimal? RednaCena, decimal? OdprodajnaCena,
  bool Razstavni, string? SpletneStrani, bool VKatalogu,
  DateTime? ImportiranoUtc, bool IsActive, DateTime? EndedUtc, string? EndedBy, string? IzvornaDatoteka,
  ClearanceStock? Stock = null);

/// <summary>
/// Odprodaja artiklov (232): ročni uvoz dobaviteljevega odprodajnega seznama (npr. Azzardo) po
/// šifri artikla, in branje/zaključevanje za kartico izdelka.
///
/// Bere zvezek z <see cref="WorkbookTable"/> (isti bralnik brez ClosedXML/EPPlus kot
/// <see cref="ProductWorkbookService"/>) — za razliko od tistega servisa gre tu za poljubno
/// dobaviteljevo obliko, ne za PIM-ov lastni delovni list, zato ni pogodbe s fiksnim naborom
/// stolpcev: uvoz prepozna naslove Šifra, Količina, Cena, Popust in Razstavni eksponat, ostale prezre.
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
    var razstavniIndex = FindColumn(sheet.Headers, "Razstavni eksponat");

    if (sifraIndex < 0)
    {
      problems.Add("Datoteka nima stolpca 'Šifra'.");
      return new(organizationId, vir, izvornaDatoteka, [], problems);
    }

    // Razstavni eksponat: 1/da/x = DA, prazno ali 0/ne = NE. Datoteka je za svoj vir celotno stanje,
    // zato prazna celica oznako tudi odstrani. Brez stolpca uvoz oznake ne spreminja (null).
    var parsed = new List<(string Sifra, decimal? Kolicina, decimal? RednaCena, decimal? Popust, bool? Razstavni)>();
    foreach (var raw in sheet.Rows)
    {
      var sifra = Cell(raw, sifraIndex)?.Trim();
      if (string.IsNullOrEmpty(sifra)) continue;
      bool? razstavni = razstavniIndex < 0 ? null : ProductWorkbookContract.ParseYesNo(Cell(raw, razstavniIndex)) ?? false;
      parsed.Add((sifra, ParseDecimal(Cell(raw, kolicinaIndex)), ParseDecimal(Cell(raw, cenaIndex)), ParseDecimal(Cell(raw, popustIndex)), razstavni));
    }

    var sifre = parsed.Select(row => row.Sifra).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
    var matched = await LookupProductIdsAsync(organizationId, sifre, cancellationToken);

    var rows = parsed.Select((row, index) =>
    {
      decimal? odprodajnaCena = row.RednaCena is { } redna && row.Popust is { } popust
        ? Math.Round(redna * (1 - popust / 100m), 2)
        : null;
      var found = matched.TryGetValue(row.Sifra, out var hit) ? hit : ((long ProductId, decimal? Zaloga)?)null;
      return new ClearanceImportRow(index + 2, row.Sifra, found?.ProductId, row.Kolicina, row.RednaCena, row.Popust, odprodajnaCena,
        row.Razstavni, found?.Zaloga);
    }).ToList();

    // Ista šifra večkrat: uvoz (276) upošteva prvo vrstico, zato jo predogled pokaže in ostale izpusti.
    var dvojniki = rows.GroupBy(row => row.Sifra, StringComparer.OrdinalIgnoreCase).Where(group => group.Count() > 1)
      .Select(group => $"{group.Key} (vrstice {string.Join(", ", group.Select(row => row.RowNumber))})").ToList();
    if (dvojniki.Count > 0)
    {
      problems.Add($"Šifra je v datoteki večkrat — upoštevana bo prva vrstica: {string.Join("; ", dvojniki.Take(20))}{(dvojniki.Count > 20 ? " …" : "")}.");
      rows = rows.DistinctBy(row => row.Sifra, StringComparer.OrdinalIgnoreCase).ToList();
    }

    var izvenMeja = rows.Where(row => row.PopustOdstotek is < 0 or > 100)
      .Select(row => $"{row.Sifra} ({row.PopustOdstotek:0.##})").ToList();
    if (izvenMeja.Count > 0)
      problems.Add($"Popust mora biti med 0 in 100 — uvoz se ne bo izvedel, dokler tega ne popraviš: {string.Join(", ", izvenMeja.Take(20))}{(izvenMeja.Count > 20 ? " …" : "")}.");

    // Datoteka je celotno stanje vira: kar je aktivno pod tem virom v tem podjetju in ga v datoteki
    // ni, se zaključi. Napačna datoteka ali podjetje bi tiho zaključila cel seznam, zato to pove vnaprej.
    var zakljucene = await ItemsToEndAsync(organizationId, vir,
      rows.Where(row => row.ProductId is not null).Select(row => row.ProductId!.Value).Distinct().ToList(), cancellationToken);
    if (zakljucene.Count > 0)
      problems.Add($"Uvoz bo zaključil {zakljucene.Count:N0} aktivnih odprodaj vira »{vir}«, ki jih v datoteki ni: {string.Join(", ", zakljucene.Take(20))}{(zakljucene.Count > 20 ? " …" : "")}.");

    var brezPopusta = rows.Where(row => row.PopustOdstotek is null).Select(row => row.Sifra).ToList();
    if (brezPopusta.Count > 0)
      problems.Add($"Brez popusta — na spletu bo popust 0 %: {string.Join(", ", brezPopusta.Take(20))}{(brezPopusta.Count > 20 ? " …" : "")}.");
    var brezKolicine = rows.Where(row => row.Kolicina is not > 0).Select(row => row.Sifra).ToList();
    // 297: primerjava z zalogo v glavnem skladišču. Zaloga manjša od vpisane je napaka v seznamu: na spletu
    // bo ponujenih največ toliko kosov, kolikor jih je na zalogi.
    var matchedRows = rows.Where(row => row.ProductId is not null).ToList();
    var premalo = matchedRows.Where(row => row.Nacin == ClearanceStock.Premalo)
      .Select(row => $"{row.Sifra} ({row.Kolicina:0.##} v datoteki, {row.Zaloga:0.##} na zalogi)").ToList();
    if (premalo.Count > 0)
      problems.Add($"Zaloge je manj, kot piše v datoteki — na spletu bo največ toliko, kolikor je na zalogi; preveri seznam: {string.Join(", ", premalo.Take(20))}{(premalo.Count > 20 ? " …" : "")}.");
    var neznana = matchedRows.Where(row => row.Nacin == ClearanceStock.Neznana).Select(row => row.Sifra).ToList();
    if (neznana.Count > 0)
      problems.Add($"Zaloga v PIM ni znana — velja vpisana količina minus naročila: {string.Join(", ", neznana.Take(20))}{(neznana.Count > 20 ? " …" : "")}.");
    if (brezKolicine.Count > 0)
      problems.Add($"Količina 0 ali prazna — na spletu ne bodo v odprodaji: {string.Join(", ", brezKolicine.Take(20))}{(brezKolicine.Count > 20 ? " …" : "")}.");

    return new ClearanceImportPreview(organizationId, vir, izvornaDatoteka, rows, problems, razstavniIndex >= 0);
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
      razstavni = row.Razstavni,
    });

    return await RetryOnDeadlockAsync(async () =>
    {
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
    }, cancellationToken);
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
        PimDb.NullableDecimal(reader, "Kolicina"), PimDb.NullableDecimal(reader, "ZacetnaKolicina"),
        PimDb.NullableDecimal(reader, "Prodano") ?? 0, PimDb.Text(reader, "Narocila"),
        PimDb.NullableDecimal(reader, "RednaCena"),
        PimDb.NullableDecimal(reader, "PopustOdstotek"), PimDb.NullableDecimal(reader, "OdprodajnaCena"),
        PimDb.Text(reader, "IzvornaDatoteka"), PimDb.DateTimeValue(reader, "ImportiranoUtc"),
        PimDb.Bool(reader, "IsActive"), PimDb.NullableDateTime(reader, "EndedUtc"), PimDb.Text(reader, "EndedBy"),
        ClearanceStock.Read(reader)));
    return rows;
  }

  public async Task<IReadOnlyList<ClearanceOverviewRow>> GetOverviewAsync(
    int organizationId, bool includeEnded, CancellationToken cancellationToken = default)
  {
    var rows = new List<ClearanceOverviewRow>();
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.GetClearanceOverview", connection)
    {
      CommandType = CommandType.StoredProcedure,
      CommandTimeout = 120,
    };
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@IncludeEnded", SqlDbType.Bit).Value = includeEnded;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    while (await reader.ReadAsync(cancellationToken))
      rows.Add(new(
        PimDb.NullableInt64(reader, "ClearanceItemId"), PimDb.Int64(reader, "ProductId"), PimDb.TextOrEmpty(reader, "ItemID"),
        PimDb.Text(reader, "Naziv"), PimDb.Text(reader, "Vir"),
        PimDb.NullableDecimal(reader, "Kolicina"), PimDb.NullableDecimal(reader, "ZacetnaKolicina"),
        PimDb.NullableDecimal(reader, "Prodano") ?? 0, PimDb.Text(reader, "Narocila"),
        PimDb.NullableDecimal(reader, "PopustOdstotek"),
        PimDb.NullableDecimal(reader, "RednaCena"), PimDb.NullableDecimal(reader, "OdprodajnaCena"),
        PimDb.Bool(reader, "Razstavni"), PimDb.Text(reader, "SpletneStrani"), PimDb.Bool(reader, "VKatalogu"),
        PimDb.NullableDateTime(reader, "ImportiranoUtc"), PimDb.Bool(reader, "IsActive"),
        PimDb.NullableDateTime(reader, "EndedUtc"), PimDb.Text(reader, "EndedBy"), PimDb.Text(reader, "IzvornaDatoteka"),
        reader.IsDBNull(reader.GetOrdinal("ClearanceItemId")) ? null : ClearanceStock.Read(reader)));
    return rows;
  }

  /// <summary>
  /// En artikel v odprodajo ali popravek obstoječe vrstice istega vira (275, pim.SaveClearanceItem).
  /// <paramref name="razstavni"/> <c>null</c> pomeni: oznake razstavni eksponat ne spreminjaj.
  /// Napake baze (neznana šifra, popust izven 0–100) pridejo kot <see cref="SqlException"/> z
  /// berljivim sporočilom.
  /// </summary>
  public async Task SaveItemAsync(
    int organizationId, string itemId, string vir, decimal kolicina, decimal popustOdstotek, bool? razstavni,
    string actor, CancellationToken cancellationToken = default) =>
    await RetryOnDeadlockAsync(async () =>
    {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("pim.SaveClearanceItem", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@ItemID", SqlDbType.NVarChar, 100).Value = itemId;
    command.Parameters.Add("@Vir", SqlDbType.NVarChar, 100).Value = vir;
    command.Parameters.Add(new SqlParameter("@Kolicina", SqlDbType.Decimal) { Precision = 10, Scale = 2, Value = kolicina });
    command.Parameters.Add(new SqlParameter("@PopustOdstotek", SqlDbType.Decimal) { Precision = 5, Scale = 2, Value = popustOdstotek });
    command.Parameters.Add("@Razstavni", SqlDbType.Bit).Value = (object?)razstavni ?? DBNull.Value;
    command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = actor;
    await command.ExecuteNonQueryAsync(cancellationToken);
    return true;
    }, cancellationToken);

  public async Task EndAsync(long clearanceItemId, string actor, CancellationToken cancellationToken = default) =>
    await RetryOnDeadlockAsync(async () =>
    {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("pim.EndClearanceItem", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.Add("@ClearanceItemId", SqlDbType.BigInt).Value = clearanceItemId;
    command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = actor;
    await command.ExecuteNonQueryAsync(cancellationToken);
    return true;
    }, cancellationToken);

  /// <summary>
  /// Zapis odprodaje trči z zajemom iz SAOP (2026-09-28 na DEV: uvoz Azzardo je bil žrtev zastoja,
  /// Msg 1205, z map.ProcessPlanningInbox). Postopki so atomarni, zato je ponovitev varna: do trije
  /// poskusi z naraščajočim in naključnim počitkom (isti vzorec kot AutomationStore.ExecuteSqlStepAsync).
  /// </summary>
  static async Task<T> RetryOnDeadlockAsync<T>(Func<Task<T>> work, CancellationToken cancellationToken)
  {
    const int attempts = 3;
    for (var attempt = 1; ; attempt++)
    {
      try { return await work(); }
      catch (SqlException exception) when (exception.Number == 1205 && attempt < attempts)
      {
        await Task.Delay(TimeSpan.FromMilliseconds(500 * attempt + Random.Shared.Next(500)), cancellationToken);
      }
    }
  }

  /// <summary>Artikel po šifri in njegova zaloga v glavnem skladišču (out.CatalogStock, 297).</summary>
  async Task<IReadOnlyDictionary<string, (long ProductId, decimal? Zaloga)>> LookupProductIdsAsync(int organizationId, IReadOnlyCollection<string> sifre, CancellationToken cancellationToken)
  {
    var result = new Dictionary<string, (long ProductId, decimal? Zaloga)>(StringComparer.OrdinalIgnoreCase);
    if (sifre.Count == 0) return result;

    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("""
      SELECT parsed.value AS Sifra, product.ProductId,
             CASE WHEN stock.OwnObserved > 0 THEN stock.OwnAvailable END AS Zaloga
      FROM OPENJSON(@SifreJson) parsed
      JOIN canon.Product product ON product.OrganizationId = @OrganizationId AND product.ItemID = parsed.value
      LEFT JOIN out.CatalogStock stock ON stock.OrganizationId = product.OrganizationId AND stock.ItemID = product.ItemID;
      """, connection);
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@SifreJson", SqlDbType.NVarChar, -1).Value = JsonSerializer.Serialize(sifre);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    while (await reader.ReadAsync(cancellationToken))
      result[PimDb.TextOrEmpty(reader, "Sifra")] = (PimDb.Int64(reader, "ProductId"), PimDb.NullableDecimal(reader, "Zaloga"));
    return result;
  }

  async Task<IReadOnlyList<string>> ItemsToEndAsync(int organizationId, string vir, IReadOnlyCollection<long> keptProductIds, CancellationToken cancellationToken)
  {
    var result = new List<string>();
    if (string.IsNullOrWhiteSpace(vir)) return result;

    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.GetClearanceItemsToEnd", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@Vir", SqlDbType.NVarChar, 100).Value = vir.Trim();
    command.Parameters.Add("@ProductIdsJson", SqlDbType.NVarChar, -1).Value = JsonSerializer.Serialize(keptProductIds);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    while (await reader.ReadAsync(cancellationToken))
      result.Add(PimDb.TextOrEmpty(reader, "Sifra"));
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
    // NumberStyles.Any dovoli ločilo tisočic — InvariantCulture bi "29,78" prebral kot 2978, ne 29,78.
    // Enak vzorec (najprej InvariantCulture, nato sl-SI) kot ProductWorkbookService.SameValue (35bea94).
    if (decimal.TryParse(trimmed, NumberStyles.Float, CultureInfo.InvariantCulture, out var value)) return value;
    return decimal.TryParse(trimmed, NumberStyles.Float, CultureInfo.GetCultureInfo("sl-SI"), out value) ? value : null;
  }
}
