using System.Data;
using System.Globalization;
using Microsoft.Data.SqlClient;
using PIM.Operations;
using static PIM.Intranet.Services.PimDb;

namespace PIM.Intranet.Services;

/*
  Napačni naslovi slik (naloga #9, migracija 312, stran /mediji/napacni-naslovi). Samo bere
  (intranet.GetMediaUrlChecks); izide piše samo posel MEDIA_URL_CHECK (PIM.SourceFetchWorker --preveri-slike).
  Popravek naslova je delo vira (XML dobavitelja, uvoz) ali kartice izdelka — stran pove, kje.
*/

public sealed record MediaCheckRow(
  long ProductId, string ItemId, int OrganizationId, string? OrganizationName, string Role, int SortOrder, string Url, string? Host,
  string State, int? HttpStatus, string? ContentType, string? ErrorCode, string? ErrorText, DateTime? LastCheckedUtc,
  DateTime? FirstFailedUtc, int FailureCount, bool HasWorkingImage);

public sealed record MediaCheckSummary(long Addresses, long Checked, DateTime? LastCheckedUtc, long ProductsWithoutWorkingImage);

public sealed record MediaCheckPage(
  IReadOnlyList<MediaCheckRow> Rows, long Total, IReadOnlyDictionary<string, (long Items, long Products)> StateCounts,
  IReadOnlyList<(string Host, long Items)> Hosts, IReadOnlyList<(string Code, long Items)> Errors, MediaCheckSummary Summary)
{
  public long Count(string state) => StateCounts.TryGetValue(state, out var value) ? value.Items : 0;
  public long AllCount => StateCounts.Values.Sum(value => value.Items);
}

public sealed class MediaCheckReadService(IConfiguration configuration)
{
  string ConnectionString => ConnectionStringResolver.Resolve(configuration) ?? throw new InvalidOperationException("Povezava PIM ni nastavljena.");

  public async Task<MediaCheckPage> GetAsync(MediaCheckFilter filter, CancellationToken ct = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(ct);
    await using var command = new SqlCommand("intranet.GetMediaUrlChecks", connection) { CommandType = CommandType.StoredProcedure, CommandTimeout = 120 };
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = (object?)filter.OrganizationId ?? DBNull.Value;
    command.Parameters.Add("@Search", SqlDbType.NVarChar, 200).Value = (object?)filter.Search ?? DBNull.Value;
    command.Parameters.Add("@State", SqlDbType.NVarChar, 20).Value = (object?)filter.State ?? DBNull.Value;
    command.Parameters.Add("@Host", SqlDbType.NVarChar, 255).Value = (object?)filter.Host ?? DBNull.Value;
    command.Parameters.Add("@ErrorCode", SqlDbType.NVarChar, 40).Value = (object?)filter.ErrorCode ?? DBNull.Value;
    command.Parameters.Add("@Sort", SqlDbType.NVarChar, 20).Value = (object?)filter.Sort ?? DBNull.Value;
    command.Parameters.Add("@Descending", SqlDbType.Bit).Value = MediaCheckQuery.IsDescending(filter);
    command.Parameters.Add("@Skip", SqlDbType.Int).Value = filter.Skip;
    command.Parameters.Add("@Take", SqlDbType.Int).Value = filter.Take;
    await using var r = await command.ExecuteReaderAsync(ct);

    var rows = new List<MediaCheckRow>();
    while (await r.ReadAsync(ct))
      rows.Add(new(Int64(r, "ProductId"), TextOrEmpty(r, "ItemID"), Int32(r, "OrganizationId"), Text(r, "OrganizationName"),
        TextOrEmpty(r, "Role"), Int32(r, "SortOrder"), TextOrEmpty(r, "Url"), Text(r, "Host"), TextOrEmpty(r, "State"),
        r.IsDBNull(r.GetOrdinal("LastHttpStatus")) ? null : Int32(r, "LastHttpStatus"), Text(r, "LastContentType"),
        Text(r, "LastErrorCode"), Text(r, "LastErrorText"), NullableDateTime(r, "LastCheckedUtc"), NullableDateTime(r, "FirstFailedUtc"),
        Int32(r, "FailureCount"), Bool(r, "HasWorkingImage")));
    long total = 0;
    if (await r.NextResultAsync(ct) && await r.ReadAsync(ct)) total = Int64(r, "Total");
    var states = new Dictionary<string, (long, long)>(StringComparer.Ordinal);
    if (await r.NextResultAsync(ct)) while (await r.ReadAsync(ct)) states[TextOrEmpty(r, "State")] = (Int64(r, "Items"), Int64(r, "Products"));
    var hosts = new List<(string, long)>();
    if (await r.NextResultAsync(ct)) while (await r.ReadAsync(ct)) hosts.Add((TextOrEmpty(r, "Host"), Int64(r, "Items")));
    var errors = new List<(string, long)>();
    if (await r.NextResultAsync(ct)) while (await r.ReadAsync(ct)) errors.Add((TextOrEmpty(r, "ErrorCode"), Int64(r, "Items")));
    var summary = new MediaCheckSummary(0, 0, null, 0);
    if (await r.NextResultAsync(ct) && await r.ReadAsync(ct))
      summary = new(Int64(r, "Addresses"), Int64(r, "Checked"), NullableDateTime(r, "LastCheckedUtc"), Int64(r, "ProductsWithoutWorkingImage"));
    return new(rows, total, states, hosts, errors, summary);
  }

  public async Task<byte[]> BuildWorkbookAsync(MediaCheckFilter filter, CancellationToken ct = default)
  {
    var page = await GetAsync(filter with { Skip = 0, Take = WorkbookWriter.MaxRows }, ct);
    WorkbookColumn Text(string header, double width = 14, string? group = null) => new(header, WorkbookCellKind.Text, width, group);
    IReadOnlyList<WorkbookColumn> columns =
    [
      Text("Šifra", 16, "Artikel"), Text("Podjetje", 14, "Artikel"), Text("Vloga slike", 12, "Slika"), new("Vrstni red", WorkbookCellKind.Number, 10, "Slika"),
      Text("Naslov (URL)", 70, "Slika"), Text("Strežnik", 22, "Slika"),
      Text("Stanje", 20, "Preverjanje"), Text("Napaka", 50, "Preverjanje"), new("HTTP status", WorkbookCellKind.Number, 10, "Preverjanje"),
      Text("Vrsta vsebine", 20, "Preverjanje"), new("Neuspehov", WorkbookCellKind.Number, 10, "Preverjanje"),
      new("Prvič neuspešno", WorkbookCellKind.DateTime, 18, "Preverjanje"), new("Nazadnje preverjeno", WorkbookCellKind.DateTime, 18, "Preverjanje"),
      Text("Ima delujočo sliko", 14, "Posledica"),
    ];
    var rows = page.Rows.Select(row => (IReadOnlyList<object?>)
    [
      row.ItemId, row.OrganizationName, row.Role, row.SortOrder, row.Url, row.Host,
      MediaCheckStates.Find(row.State).Label, row.ErrorText ?? MediaCheckErrors.Label(row.ErrorCode), row.HttpStatus, row.ContentType, row.FailureCount,
      row.FirstFailedUtc?.ToPimLocal(), row.LastCheckedUtc?.ToPimLocal(), row.HasWorkingImage ? "da" : "ne",
    ]);
    var notes = new List<string>
    {
      $"Izvoženo {DateTime.UtcNow.ToPimLocal():dd.MM.yyyy HH:mm}; vrstic {page.Rows.Count:N0}" + (page.Total > page.Rows.Count ? $" od {page.Total:N0} (meja {WorkbookWriter.MaxRows:N0})." : "."),
      "Pokvarjena = dvakrat v razmiku 24 ur se ni odprla; taka slika ne gre v katalog.csv. Izdelek brez delujoče slike ima napako validacije za splet.",
      "Naslov se popravi v viru (XML dobavitelja, uvoz iz Excela) ali na kartici izdelka; posel ga ob naslednjem teku preveri znova.",
    };
    return WorkbookWriter.Write("Napačni naslovi slik", columns, rows, notes);
  }
}
