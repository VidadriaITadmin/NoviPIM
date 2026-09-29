using System.Data;
using System.Globalization;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using PIM.Operations;
using static PIM.Intranet.Services.PimDb;

namespace PIM.Intranet.Services;

/*
  Neskladja med podjetji (migracija 290, stran /splet/neskladja): ista šifra v podjetjih, ki skupaj sestavljajo
  katalog.csv (out.CatalogSource, 285), z manjkajočo kartico ali različnimi kljukicami spletišč. Samo bere
  (intranet.GetOrganizationMismatches); popravki se naredijo na kartici artikla ali v ERP.
*/

/// <summary>Vrste neskladij: koda iz procedure, vidno ime, ton čipa, posledica in kaj narediti.</summary>
public static class OrganizationMismatchKinds
{
  public const string MissingPrimary = "MANJKA_GLAVNA";
  public const string MissingOther = "MANJKA_DRUGA";
  public const string DifferentFlags = "RAZLICNE_KLJUKICE";

  public sealed record Kind(string Code, string Label, string? Tone, string Effect, string Action);

  /// <param name="primary">Ime glavnega podjetja (vsebina kataloga), npr. IQLighting.</param>
  /// <param name="other">Ime drugega podjetja, npr. Vidadria.</param>
  public static IReadOnlyList<Kind> All(string primary, string other) =>
  [
    new(MissingPrimary, $"Manjka v {primary}", "bad",
      $"Kljukica v {other} za spletišče, ki ga vodi {primary} — artikel tja ne gre.",
      $"Odpri artikel v {primary} (ERP) ali odstrani kljukico v {other}."),
    new(MissingOther, $"Manjka v {other}", "warn",
      $"Na spletu je (prispeva {primary}), v {other} pa artikla ni ali je neaktiven.",
      $"Odpri artikel v {other} (ERP), če mora biti v obeh podjetjih."),
    new(DifferentFlags, "Različne kljukice", null,
      "Obe kartici sta aktivni, kljukice pa se razlikujejo. V katalogu je unija.",
      "Preveri, ali je tako prav, in poenoti kljukice."),
  ];

  public static Kind Find(IReadOnlyList<Kind> kinds, string? code) => kinds.FirstOrDefault(kind => kind.Code == code) ?? kinds[^1];
}

public sealed record OrganizationMismatchFilter(
  string? Search = null, string? Kind = null, string? Prefix = null, string? Sort = null, bool Descending = false,
  int Skip = 0, int Take = 50);

/// <summary>Ista imena parametrov v naslovu strani in v izvozu: povezavo se da deliti, izvoz = zaslon.</summary>
public static class OrganizationMismatchQuery
{
  static readonly string[] Kinds = [OrganizationMismatchKinds.MissingPrimary, OrganizationMismatchKinds.MissingOther, OrganizationMismatchKinds.DifferentFlags];
  static readonly string[] Sorts = ["sifra", "naziv", "vrsta", "predpona"];

  public static OrganizationMismatchFilter FromQuery(Func<string, string?> read) => new(
    Search: string.IsNullOrWhiteSpace(read("isci")) ? null : read("isci")!.Trim(),
    Kind: Kinds.Contains(read("vrsta")) ? read("vrsta") : null,
    Prefix: string.IsNullOrWhiteSpace(read("predpona")) ? null : read("predpona")!.Trim(),
    Sort: Sorts.Contains(read("razvrsti")) ? read("razvrsti") : null,
    Descending: read("smer") == "pad",
    Skip: int.TryParse(read("stran"), out var page) && page > 1 ? (page - 1) * 50 : 0);

  public static string ToQueryString(OrganizationMismatchFilter filter, int page = 1)
  {
    var parts = new List<string>();
    void Add(string name, string? value) { if (!string.IsNullOrWhiteSpace(value)) parts.Add($"{name}={Uri.EscapeDataString(value)}"); }
    Add("isci", filter.Search);
    Add("vrsta", filter.Kind);
    Add("predpona", filter.Prefix);
    Add("razvrsti", filter.Sort);
    if (filter.Descending) Add("smer", "pad");
    if (page > 1) Add("stran", page.ToString(CultureInfo.InvariantCulture));
    return string.Join("&", parts);
  }
}

public sealed record OrganizationMismatchRow(
  string ItemId, string? Name, string Kind, string Prefix, int OtherOrganizationId,
  bool PrimaryCard, bool PrimaryActive, long? PrimaryPimProductId, string? PrimaryFlags,
  bool OtherCard, bool OtherActive, long? OtherPimProductId, string? OtherFlags,
  string? CatalogSites, string? LostSites);

public sealed record OrganizationMismatchSource(int OrganizationId, string Name, bool IsPrimary, string? AllowedSites);

public sealed record OrganizationMismatchPage(
  IReadOnlyList<OrganizationMismatchRow> Rows, long Total, IReadOnlyDictionary<string, int> KindCounts,
  IReadOnlyList<(string Prefix, int Items)> Prefixes, IReadOnlyList<OrganizationMismatchSource> Sources)
{
  public OrganizationMismatchSource? Primary => Sources.FirstOrDefault(source => source.IsPrimary);
  public string PrimaryName => Primary?.Name ?? "glavno podjetje";
  public string OtherName(int organizationId) =>
    Sources.FirstOrDefault(source => source.OrganizationId == organizationId)?.Name ?? $"podjetje {organizationId}";
  /// <summary>Ime drugega podjetja za besedila vrst; pri več drugih podjetjih splošno.</summary>
  public string OthersName => Sources.Count(source => !source.IsPrimary) == 1 ? Sources.First(source => !source.IsPrimary).Name : "drugo podjetje";
  public IReadOnlyList<OrganizationMismatchKinds.Kind> Kinds => OrganizationMismatchKinds.All(PrimaryName, OthersName);
}

public sealed class OrganizationMismatchService(IConfiguration configuration)
{
  string ConnectionString => ConnectionStringResolver.Resolve(configuration) ?? throw new InvalidOperationException("Povezava PIM ni nastavljena.");

  /// <summary>Katalog, katerega vire primerjamo (out.CatalogSource.CatalogOrganizationId). En katalog: IQ Lighting.</summary>
  public const int CatalogOrganizationId = 2;

  public async Task<OrganizationMismatchPage> GetAsync(OrganizationMismatchFilter filter, IReadOnlyCollection<string>? itemIds = null, CancellationToken ct = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(ct);
    await using var command = new SqlCommand("intranet.GetOrganizationMismatches", connection)
    {
      CommandType = CommandType.StoredProcedure,
      CommandTimeout = 120,
    };
    command.Parameters.Add("@CatalogOrganizationId", SqlDbType.Int).Value = CatalogOrganizationId;
    command.Parameters.Add("@Kind", SqlDbType.NVarChar, 30).Value = (object?)filter.Kind ?? DBNull.Value;
    command.Parameters.Add("@Search", SqlDbType.NVarChar, 200).Value = (object?)filter.Search ?? DBNull.Value;
    command.Parameters.Add("@Prefix", SqlDbType.NVarChar, 50).Value = (object?)filter.Prefix ?? DBNull.Value;
    command.Parameters.Add("@Sort", SqlDbType.NVarChar, 20).Value = (object?)filter.Sort ?? DBNull.Value;
    command.Parameters.Add("@Descending", SqlDbType.Bit).Value = filter.Descending;
    command.Parameters.Add("@Skip", SqlDbType.Int).Value = filter.Skip;
    command.Parameters.Add("@Take", SqlDbType.Int).Value = filter.Take;
    command.Parameters.Add("@ItemIdsJson", SqlDbType.NVarChar, -1).Value = itemIds is null ? DBNull.Value : JsonSerializer.Serialize(itemIds);
    await using var r = await command.ExecuteReaderAsync(ct);

    var rows = new List<OrganizationMismatchRow>();
    while (await r.ReadAsync(ct))
      rows.Add(new(TextOrEmpty(r, "ItemID"), Text(r, "Name"), TextOrEmpty(r, "Kind"), TextOrEmpty(r, "Prefix"), Int32(r, "OtherOrganizationId"),
        Bool(r, "PrimaryCard"), Bool(r, "PrimaryActive"), NullableInt64(r, "PrimaryPimProductId"), Text(r, "PrimaryFlags"),
        Bool(r, "OtherCard"), Bool(r, "OtherActive"), NullableInt64(r, "OtherPimProductId"), Text(r, "OtherFlags"),
        Text(r, "CatalogSites"), Text(r, "LostSites")));
    long total = 0;
    if (await r.NextResultAsync(ct) && await r.ReadAsync(ct)) total = Int64(r, "Total");
    var counts = new Dictionary<string, int>(StringComparer.Ordinal);
    if (await r.NextResultAsync(ct)) while (await r.ReadAsync(ct)) counts[TextOrEmpty(r, "Kind")] = Int32(r, "Items");
    var prefixes = new List<(string, int)>();
    if (await r.NextResultAsync(ct)) while (await r.ReadAsync(ct)) prefixes.Add((TextOrEmpty(r, "Prefix"), Int32(r, "Items")));
    var sources = new List<OrganizationMismatchSource>();
    if (await r.NextResultAsync(ct))
      while (await r.ReadAsync(ct))
        sources.Add(new(Int32(r, "OrganizationId"), Text(r, "Name") ?? $"podjetje {Int32(r, "OrganizationId")}", Bool(r, "IsPrimary"), Text(r, "Allowed")));
    return new(rows, total, counts, prefixes, sources);
  }

  public async Task<byte[]> BuildWorkbookAsync(OrganizationMismatchFilter filter, IReadOnlyCollection<string>? itemIds, CancellationToken ct = default)
  {
    var page = await GetAsync(filter with { Skip = 0, Take = WorkbookWriter.MaxRows }, itemIds, ct);
    var kinds = page.Kinds;
    WorkbookColumn Text(string header, double width = 14, string? group = null) => new(header, WorkbookCellKind.Text, width, group);
    IReadOnlyList<WorkbookColumn> columns =
    [
      Text("Šifra", 18, "Artikel"), Text("Naziv", 44, "Artikel"), Text("Predpona", 10, "Artikel"),
      Text("Neskladje", 20, "Neskladje"), Text("Posledica", 50, "Neskladje"), Text("Kaj narediti", 44, "Neskladje"),
      Text($"Kartica {page.PrimaryName}", 16, page.PrimaryName), Text($"Kljukice {page.PrimaryName}", 20, page.PrimaryName),
      Text("Drugo podjetje", 14, "Drugo podjetje"), Text("Kartica", 16, "Drugo podjetje"), Text("Kljukice", 20, "Drugo podjetje"),
      Text("V katalogu po kljukicah", 22, "Katalog"), Text("Ne gre na", 16, "Katalog"),
    ];
    static string Card(bool exists, bool active) => !exists ? "ni kartice" : active ? "aktivna" : "neaktivna";
    var rows = page.Rows.Select(row =>
    {
      var kind = OrganizationMismatchKinds.Find(kinds, row.Kind);
      return (IReadOnlyList<object?>)
      [
        row.ItemId, row.Name, row.Prefix, kind.Label, kind.Effect, kind.Action,
        Card(row.PrimaryCard, row.PrimaryActive), row.PrimaryFlags,
        page.OtherName(row.OtherOrganizationId), Card(row.OtherCard, row.OtherActive), row.OtherFlags,
        row.CatalogSites, row.LostSites,
      ];
    });
    var notes = new List<string>
    {
      $"Izvoženo {DateTime.Now:dd.MM.yyyy HH:mm}; vrstic {page.Rows.Count:N0}" + (page.Total > page.Rows.Count ? $" od {page.Total:N0} (meja {WorkbookWriter.MaxRows:N0})." : "."),
      "»V katalogu po kljukicah« upošteva samo kljukice in pravilo virov kataloga; kategorija in validacija lahko artikel še zadržita (PIM, Izhod na splet → Umaknjeni s spleta).",
    };
    return WorkbookWriter.Write("Neskladja med podjetji", columns, rows, notes);
  }
}
