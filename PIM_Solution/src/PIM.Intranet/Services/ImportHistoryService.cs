using System.Data;
using System.Globalization;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using PIM.Operations;

namespace PIM.Intranet.Services;

/// <summary>
/// Ena spremenjena celica uvoza (280): vrstica, polje, prej → potem in kam je šla.
/// </summary>
/// <param name="RowKey">Šifra artikla, ključ stranke ali »cenik|šifra«.</param>
/// <param name="Target">PIM ali SAOP (gre v odhodno vrsto, čaka odobritev).</param>
/// <param name="ValueKind">TEXT, BOOL (1/0) ali NUMBER (s piko).</param>
/// <param name="OldValue">Vrednost tik pred uvozom; null = prazno.</param>
public sealed record ImportChange(
  int OrganizationId, string? OrganizationName, string RowKey, string? RowLabel, string FieldKey, string? FieldLabel,
  string Target, string ValueKind, string? OldValue, string? NewValue);

/// <param name="Snapshot">Stranke: vrstice seznama strank tik pred uvozom (JSON) — iz njih nastane povratek.</param>
public sealed record ImportRunDetail(ImportRunRow Run, IReadOnlyList<ImportChange> Changes, string? Snapshot);

/// <summary>Povratek strank: predogled s prejšnjimi vrednostmi in kar se ne povrne.</summary>
public sealed record CustomerUndoPlan(CustomerWorkbookPreview Preview, IReadOnlyList<string> Skipped);

/// <summary>Povratek izdelkov: predogled, ki vrne »prej«, in kar se ne povrne (spor, prazno v SAOP, artikla ni).</summary>
public sealed record ProductUndoPlan(ProductWorkbookPreview Preview, IReadOnlyList<string> Skipped, int Conflicts, int AlreadyReverted);

/// <summary>
/// Zgodovina uvozov in povratek (migracija 280). Uporabnik 2026-09-24: »mišljeno je, da ko se spremenijo artikli,
/// da se povrne — pri uvozih artiklov, cen, strank in SAOP«. Vsak uveljavljen uvoz zapiše, katere celice je
/// spremenil (prej → potem). Povratek iz tega sestavi nov uvoz s prejšnjimi vrednostmi in ga pošlje skozi isto
/// stran uvoza (predogled, potrditev, isti zapis); kar gre v SAOP, čaka odobritev v vrsti, nikoli samodejno.
///
/// Zapis zgodovine uvoza ne sme podreti: če ne uspe, uvoz ostane uveljavljen, stran pa pove, da zgodovine ni.
/// </summary>
public sealed class ImportHistoryService(IConfiguration configuration, PimWriteGuard guard)
{
  string ConnectionString => ConnectionStringResolver.Resolve(configuration)
    ?? throw new InvalidOperationException("Povezava PIM ni nastavljena.");

  /// <returns>Številka zapisa ali null, če zgodovine ni bilo mogoče zapisati (npr. baza pred 280).</returns>
  public async Task<long?> RecordAsync(
    string kind, string title, string? note, string actor, int rowCount, int saopCount,
    IEnumerable<long>? outboundBatchIds, IEnumerable<string>? problems, long? undoOf,
    IReadOnlyList<ImportChange> changes, string? snapshot = null, CancellationToken cancellationToken = default)
  {
    if (changes.Count == 0) return null;
    try
    {
      await using var connection = new SqlConnection(ConnectionString);
      await connection.OpenAsync(cancellationToken);
      await using var command = new SqlCommand("ops.RecordImportRun", connection) { CommandType = CommandType.StoredProcedure, CommandTimeout = 300 };
      command.Parameters.Add("@Kind", SqlDbType.NVarChar, 20).Value = kind;
      command.Parameters.Add("@Title", SqlDbType.NVarChar, 400).Value = string.IsNullOrWhiteSpace(title) ? ImportKinds.Label(kind) : title.Trim();
      command.Parameters.Add("@Note", SqlDbType.NVarChar, 1000).Value = string.IsNullOrWhiteSpace(note) ? DBNull.Value : note.Trim();
      command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = actor;
      command.Parameters.Add("@RowCount", SqlDbType.Int).Value = rowCount;
      command.Parameters.Add("@SaopCount", SqlDbType.Int).Value = saopCount;
      var batches = outboundBatchIds is null ? "" : string.Join(", ", outboundBatchIds.Distinct());
      command.Parameters.Add("@OutboundBatchIds", SqlDbType.NVarChar, 1000).Value = batches.Length == 0 ? DBNull.Value : batches;
      var problemText = problems is null ? "" : string.Join("\n", problems.Take(200));
      command.Parameters.Add("@Problems", SqlDbType.NVarChar, -1).Value = problemText.Length == 0 ? DBNull.Value : problemText;
      command.Parameters.Add("@UndoOfImportRunId", SqlDbType.BigInt).Value = (object?)undoOf ?? DBNull.Value;
      command.Parameters.Add("@Snapshot", SqlDbType.NVarChar, -1).Value = (object?)snapshot ?? DBNull.Value;
      command.Parameters.Add("@ChangesJson", SqlDbType.NVarChar, -1).Value = ChangesJson(changes);
      return await command.ExecuteScalarAsync(cancellationToken) is { } id and not DBNull ? Convert.ToInt64(id, CultureInfo.InvariantCulture) : null;
    }
    catch (SqlException exception)
    {
      Console.Error.WriteLine($"Opozorilo: zgodovine uvoza ni bilo mogoče zapisati ({exception.Number}: {exception.Message}).");
      return null;
    }
  }

  public async Task<IReadOnlyList<ImportRunRow>> GetRunsAsync(string? kind = null, int take = 100, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.GetImportRuns", connection) { CommandType = CommandType.StoredProcedure, CommandTimeout = 30 };
    command.Parameters.Add("@Kind", SqlDbType.NVarChar, 20).Value = (object?)kind ?? DBNull.Value;
    command.Parameters.Add("@Take", SqlDbType.Int).Value = take;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    var rows = new List<ImportRunRow>();
    while (await reader.ReadAsync(cancellationToken)) rows.Add(ReadRun(reader, withProblems: false));
    return rows;
  }

  public async Task<ImportRunDetail?> GetRunAsync(long importRunId, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.GetImportRun", connection) { CommandType = CommandType.StoredProcedure, CommandTimeout = 60 };
    command.Parameters.Add("@ImportRunId", SqlDbType.BigInt).Value = importRunId;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    if (!await reader.ReadAsync(cancellationToken)) return null;
    var run = ReadRun(reader, withProblems: true);
    var snapshot = PimDb.Text(reader, "Snapshot");
    await reader.NextResultAsync(cancellationToken);
    var changes = new List<ImportChange>();
    while (await reader.ReadAsync(cancellationToken))
      changes.Add(new(
        PimDb.Int32(reader, "OrganizationId"), PimDb.Text(reader, "OrganizationName"), PimDb.TextOrEmpty(reader, "RowKey"),
        PimDb.Text(reader, "RowLabel"), PimDb.TextOrEmpty(reader, "FieldKey"), PimDb.Text(reader, "FieldLabel"),
        PimDb.TextOrEmpty(reader, "Target"), PimDb.TextOrEmpty(reader, "ValueKind"), PimDb.Text(reader, "OldValue"),
        PimDb.Text(reader, "NewValue")));
    return new(run, changes, snapshot);
  }

  /// <summary>Stanje uvoza v vrsti za SAOP, šteto po zapisih (cena, artikel), ne po sporočilih po polju (#66).</summary>
  public async Task<ImportQueueState> GetQueueStateAsync(IReadOnlyCollection<long> batchIds, CancellationToken cancellationToken = default)
  {
    if (batchIds.Count == 0) return new(0, 0, 0);
    var states = await QueueStatesAsync(batchIds.Select(batch => (0L, batch)), cancellationToken);
    return states.TryGetValue(0, out var state) ? state : new(0, 0, 0);
  }

  /// <summary>
  /// Stanje v vrsti za vse prikazane uvoze naenkrat (seznam /uvozi, do 200 vrstic): ena poizvedba, nikoli poizvedba
  /// na vrstico. Uvozi brez skupin v vrsti v slovarju niso.
  /// </summary>
  public async Task<IReadOnlyDictionary<long, ImportQueueState>> GetQueueStatesAsync(IEnumerable<ImportRunRow> runs, CancellationToken cancellationToken = default)
  {
    var pairs = runs.SelectMany(run => BatchIds(run.OutboundBatchIds).Select(batch => (run.ImportRunId, batch))).ToList();
    return pairs.Count == 0 ? new Dictionary<long, ImportQueueState>() : await QueueStatesAsync(pairs, cancellationToken);
  }

  /// <remarks>
  /// Zapis = organizacija + vrsta + ključ sporočila (»B2C|šifra« za ceno, šifra za artikel). Zapis šteje v prvo stanje,
  /// ki velja za katerokoli njegovo sporočilo: čaka → v SAOP → neuspelo → preklicano; tako se nobena cena ne šteje dvakrat.
  /// </remarks>
  async Task<Dictionary<long, ImportQueueState>> QueueStatesAsync(IEnumerable<(long Run, long Batch)> pairs, CancellationToken cancellationToken)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("""
      WITH pairs AS (
        SELECT DISTINCT RunId, BatchId FROM OPENJSON(@Pairs) WITH (RunId bigint '$.r', BatchId bigint '$.b')
      ), entries AS (
        SELECT pairs.RunId,
          W = MAX(CASE WHEN message.Status IN (N'PendingApproval', N'Pending', N'Retry', N'Error') THEN 1 ELSE 0 END),
          S = MAX(CASE WHEN message.Status IN (N'Sending', N'Sent', N'Verified', N'Drift') THEN 1 ELSE 0 END),
          F = MAX(CASE WHEN message.Status = N'Dead' THEN 1 ELSE 0 END),
          C = MAX(CASE WHEN message.Status IN (N'Cancelled', N'Superseded') THEN 1 ELSE 0 END)
        FROM pairs
        JOIN out.OutboxMessage AS message ON message.OutboundBatchId = pairs.BatchId
        GROUP BY pairs.RunId, message.OrganizationId, message.EntityType, message.EntityKey
      )
      SELECT RunId,
        Waiting = SUM(W),
        Sent = SUM(CASE WHEN W = 0 AND S = 1 THEN 1 ELSE 0 END),
        Cancelled = SUM(CASE WHEN W = 0 AND S = 0 AND F = 0 AND C = 1 THEN 1 ELSE 0 END),
        Failed = SUM(CASE WHEN W = 0 AND S = 0 AND F = 1 THEN 1 ELSE 0 END)
      FROM entries
      GROUP BY RunId;
      """, connection) { CommandTimeout = 60 };
    command.Parameters.Add("@Pairs", SqlDbType.NVarChar, -1).Value =
      JsonSerializer.Serialize(pairs.Select(pair => new { r = pair.Run, b = pair.Batch }));
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    var states = new Dictionary<long, ImportQueueState>();
    while (await reader.ReadAsync(cancellationToken))
      states[reader.GetInt64(0)] = new(reader.GetInt32(1), reader.GetInt32(2), reader.GetInt32(3), reader.GetInt32(4));
    return states;
  }

  /// <summary>
  /// Prekliče sporočila uvoza, ki v SAOP še niso šla (out.CancelOutboundBatch). To je pravi povratek za del uvoza,
  /// ki SAOP-a še ni dosegel: nič se ne pošlje, ničesar ni treba vračati.
  /// </summary>
  public async Task<int> CancelWaitingAsync(IReadOnlyCollection<long> batchIds, string actor, CancellationToken cancellationToken = default)
  {
    await guard.RequireAsync(PimPolicies.SaopWrite);
    var cancelled = 0;
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    foreach (var batchId in batchIds)
    {
      await using var command = new SqlCommand("EXEC out.CancelOutboundBatch @Batch, @Actor;", connection) { CommandTimeout = 120 };
      command.Parameters.Add("@Batch", SqlDbType.BigInt).Value = batchId;
      command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = actor;
      var value = await command.ExecuteScalarAsync(cancellationToken);
      cancelled += value is null or DBNull ? 0 : Convert.ToInt32(value, CultureInfo.InvariantCulture);
    }
    return cancelled;
  }

  public static IReadOnlyList<long> BatchIds(string? text) => (text ?? "")
    .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
    .Select(part => long.TryParse(part, NumberStyles.Integer, CultureInfo.InvariantCulture, out var id) ? id : 0)
    .Where(id => id > 0).Distinct().ToList();

  /* --- stranke ------------------------------------------------------------------------------ */

  static readonly JsonSerializerOptions SnapshotJson = new() { WriteIndented = false };

  /// <summary>Stranke: vsaka sprememba predogleda (naslov, prej, potem) je ena celica; vrstica je ključ stranke.</summary>
  public static IReadOnlyList<ImportChange> FromCustomers(CustomerWorkbookPreview preview)
  {
    var changes = new List<ImportChange>();
    foreach (var row in preview.Rows)
      foreach (var change in row.Changes)
        changes.Add(new(row.Current.OrganizationId, row.Current.OrganizationName, row.Current.CustomerKey, row.Current.Name,
          change.Label, change.Label, "PIM", "TEXT", change.OldValue, change.NewValue));
    foreach (var rule in preview.TypeRules ?? [])
      changes.Add(new(rule.OrganizationId, rule.OrganizationName, "S po tipih strank", null, $"Pravilo (vrstica {rule.RowNumber})",
        TypeRuleLabel, "PIM", "TEXT", null, rule.Description));
    return changes;
  }

  const string TypeRuleLabel = "S po tipu stranke";

  /// <summary>Vrstice seznama strank pred uvozom — samo spremenjene stranke.</summary>
  public static string CustomerSnapshot(CustomerWorkbookPreview preview) =>
    JsonSerializer.Serialize(preview.Rows.Select(row => row.Current).ToList(), SnapshotJson);

  /// <summary>
  /// Povratek uvoza strank. Iz vrstic pred uvozom se sestavi delovni list strank (isti stolpci kot izvoz s strani
  /// Stranke), a samo s celicami, ki jih je uvoz spremenil: prejšnja vrednost, ali »-«, če je bilo prej prazno;
  /// vse ostale celice so prazne (»ne spreminjaj«), zato povratek ne povozi ničesar, česar uvoz ni. List se
  /// prebere z istim predogledom kot vsak uvoz. Stranka, pri kateri je vrednost po uvozu že drugačna, je spor.
  /// Zaznamkov, pravil »S po tipih strank« in ustvarjenega B2B profila povratek ne vzame nazaj; to se pove.
  /// </summary>
  public static async Task<CustomerUndoPlan> PlanCustomerUndoAsync(
    CustomerWorkbookService workbook, ImportRunDetail detail, CancellationToken cancellationToken = default)
  {
    var skipped = new List<string>();
    var before = string.IsNullOrWhiteSpace(detail.Snapshot) ? [] : JsonSerializer.Deserialize<List<CustomerListRow>>(detail.Snapshot, SnapshotJson) ?? [];
    if (before.Count == 0)
      return new(new([], 0, 0, ["Uvoz nima shranjenih vrednosti pred uvozom — povratek ni mogoč."], [], [], []), skipped);

    var imported = detail.Changes
      .GroupBy(change => (change.OrganizationId, change.RowKey))
      .ToDictionary(group => group.Key, group => group.GroupBy(change => change.FieldKey, StringComparer.Ordinal)
        .ToDictionary(field => field.Key, field => field.Last(), StringComparer.Ordinal));

    // Vrednosti pred uvozom v obliki lista (isti zapis kot izvoz), nato samo spremenjene celice.
    var full = await workbook.BuildAsync(before, null, cancellationToken);
    WorkbookSheet sheet;
    using (var stream = new MemoryStream(full)) sheet = WorkbookTable.Read(stream, CustomerWorkbookService.SheetName, ["Šifra stranke"]);
    var index = sheet.Headers.Select((header, position) => (header, position))
      .GroupBy(pair => WorkbookHeader.Normalize(pair.header)).ToDictionary(group => group.Key, group => group.First().position);
    string Cell(IReadOnlyList<string> row, string header) =>
      index.TryGetValue(WorkbookHeader.Normalize(header), out var at) && at < row.Count ? row[at] ?? "" : "";

    var rows = new List<IReadOnlyList<object?>>();
    foreach (var row in sheet.Rows)
    {
      var customer = before.FirstOrDefault(candidate => candidate.CustomerKey == Cell(row, "Šifra stranke")
        && WorkbookHeader.Same(candidate.OrganizationName, Cell(row, "Podjetje")));
      if (customer is null || !imported.TryGetValue((customer.OrganizationId, customer.CustomerKey), out var fields)) continue;
      var headers = fields.Keys.SelectMany(CustomerHeaders).ToHashSet(StringComparer.Ordinal);
      rows.Add(CustomerWorkbookService.Columns.Select(column =>
        (object?)(column.Group == CustomerWorkbookService.Columns[0].Group ? Cell(row, column.Header)
          : column.Editable && headers.Contains(column.Header) && column.Key != "ADD_NOTE"
            ? (Cell(row, column.Header) is { Length: > 0 } value ? value : CustomerWorkbookService.ClearToken)
            : null)).ToList());
    }
    var undoBytes = WorkbookWriter.Write(CustomerWorkbookService.SheetName,
      CustomerWorkbookService.Columns.Select(column => new WorkbookColumn(column.Header, WorkbookCellKind.Text, column.Width, column.Group)).ToList(), rows);
    CustomerWorkbookPreview preview;
    using (var stream = new MemoryStream(undoBytes)) preview = await workbook.PreviewAsync(stream, null, cancellationToken);

    var kept = new List<CustomerWorkbookRowChange>();
    foreach (var row in preview.Rows)
    {
      var where = $"{row.Current.OrganizationName} {row.Current.CustomerKey} {row.Current.Name}";
      if (!imported.TryGetValue((row.Current.OrganizationId, row.Current.CustomerKey), out var fields)) continue;
      var conflict = row.Changes.FirstOrDefault(change =>
        !fields.TryGetValue(change.Label, out var importedChange) || !string.Equals(importedChange.NewValue ?? "", change.OldValue ?? "", StringComparison.Ordinal));
      if (conflict is not null)
      {
        skipped.Add($"{where}, {conflict.Label}: po uvozu spremenjeno (zdaj »{conflict.OldValue ?? "prazno"}«) — stranke ne povrnem, preveri ročno.");
        continue;
      }
      kept.Add(row);
    }
    foreach (var change in detail.Changes)
    {
      if (change.FieldLabel == TypeRuleLabel || change.FieldKey == "Nova opomba")
        skipped.Add($"{change.OrganizationName} {change.RowKey}: {change.FieldLabel} — zaznamkov in pravil S po tipih povratek ne vzame nazaj; uredi ročno.");
      else if (change.FieldKey == "B2B profil")
        skipped.Add($"{change.OrganizationName} {change.RowKey}: B2B profil je ustvaril uvoz — povratek ga ne izbriše (vrne samo nastavitve); po potrebi ga izklopi na kartici.");
    }

    return new(preview with { Rows = kept, TypeRules = [] }, skipped.Concat(preview.Problems).ToList());
  }

  /// <summary>Naslov spremembe v predogledu strank → stolpci delovnega lista, ki jo nosijo.</summary>
  static IEnumerable<string> CustomerHeaders(string label) => label switch
  {
    "Skupinski popusti" => ["Skupinski popusti stranke"],
    "Posebni S" => ["Posebni S po izdelku (katalog.csv)"],
    "Dodatni popust (P2)" => ["Dodatni popust po skupinah (P2)"],
    ['P', 'r', 'a', 'g', ' ', var tier] => [$"Prag {tier} (€ brez DDV)", $"Rabat {tier} (%)"],
    _ => [label],
  };

  /// <summary>Spremembe predogleda izdelkov: »prej« je zajel predogled (OldValues), »potem« je vrednost uvoza.</summary>
  public static IReadOnlyList<ImportChange> FromProducts(ProductWorkbookPreview preview, IReadOnlyDictionary<(int, string), string>? names = null)
  {
    var changes = new List<ImportChange>();
    foreach (var row in preview.Rows)
    {
      var label = names is not null && names.TryGetValue((row.OrganizationId, row.ItemId), out var name) ? name : null;
      foreach (var (values, target) in new[] { (row.PimValues, "PIM"), (row.SaopValues, "SAOP") })
        foreach (var (field, value) in values)
          changes.Add(new(row.OrganizationId, row.OrganizationName, row.ItemId, label, field,
            preview.FieldLabels is not null && preview.FieldLabels.TryGetValue(field, out var header) ? header : field,
            target,
            preview.BoolFields?.Contains(field) == true || field == ProductWorkbookContract.WebPublishField ? "BOOL"
              : preview.NumberFields?.Contains(field) == true ? "NUMBER" : "TEXT",
            row.OldValues is not null && row.OldValues.TryGetValue(field, out var old) ? old : null,
            string.IsNullOrEmpty(value) || value == ProductWorkbookContract.ClearToken ? null : value));
    }
    return changes;
  }

  /// <summary>Cene: vsaka spremenjena lastnost cene (neto, DDV, velja od, aktivna) je ena celica; cilj je SAOP.</summary>
  public static IReadOnlyList<ImportChange> FromPrices(PriceImportPreview preview)
  {
    var changes = new List<ImportChange>();
    foreach (var row in preview.Rows)
    {
      var key = $"{row.PriceList}|{row.ItemId}";
      Add("NET", "Neto cena", "NUMBER", Number(row.OldNet), Number(row.NewNet));
      if (row.NewVat is not null && row.NewVat != row.OldVat) Add("VAT", "DDV %", "NUMBER", Number(row.OldVat), Number(row.NewVat));
      if (row.ValidFrom is not null && row.ValidFrom != row.OldValidFrom) Add("FROM", "Velja od", "TEXT", Date(row.OldValidFrom), Date(row.ValidFrom));
      if (row.Active is not null && row.Active != row.OldActive) Add("ACTIVE", "Aktivna", "BOOL", Bool(row.OldActive), Bool(row.Active));

      void Add(string field, string label, string kind, string? oldValue, string? newValue)
      {
        if (field == "NET" && oldValue == newValue) return;
        changes.Add(new(row.OrganizationId, row.OrganizationName, key, null, field, label, "SAOP", kind, oldValue, newValue));
      }
    }
    return changes;
  }

  public static string? Number(decimal? value) => value?.ToString("0.####", CultureInfo.InvariantCulture);
  public static string? Date(DateTime? value) => value is { Year: > 1900 } date ? date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture) : null;
  public static string? Bool(bool? value) => value is null ? null : value.Value ? "1" : "0";

  /// <summary>Vrednost za prikaz: logično D/N, število z vejico, prazno kot »prazno«.</summary>
  public static string Display(ImportChange change, string? value)
  {
    if (value is null) return "prazno";
    if (change.ValueKind == "BOOL") return ProductWorkbookContract.ParseYesNo(value) is { } flag ? (flag ? "D" : "N") : value;
    if (change.ValueKind == "NUMBER" && decimal.TryParse(value, NumberStyles.Number, CultureInfo.InvariantCulture, out var number))
      return number.ToString("0.####", CultureInfo.GetCultureInfo("sl-SI"));
    return value.Length > 200 ? value[..200] + " …" : value;
  }

  static string ChangesJson(IReadOnlyList<ImportChange> changes)
  {
    using var buffer = new MemoryStream();
    using (var json = new Utf8JsonWriter(buffer))
    {
      json.WriteStartArray();
      foreach (var change in changes)
      {
        json.WriteStartObject();
        json.WriteNumber("org", change.OrganizationId);
        Write("orgName", change.OrganizationName);
        Write("row", change.RowKey);
        Write("label", change.RowLabel);
        Write("field", change.FieldKey);
        Write("fieldLabel", change.FieldLabel);
        Write("target", change.Target);
        Write("kind", change.ValueKind);
        Write("old", change.OldValue);
        Write("new", change.NewValue);
        json.WriteEndObject();

        void Write(string name, string? value)
        {
          if (value is null) json.WriteNull(name); else json.WriteString(name, value);
        }
      }
      json.WriteEndArray();
    }
    return System.Text.Encoding.UTF8.GetString(buffer.ToArray());
  }

  static ImportRunRow ReadRun(SqlDataReader reader, bool withProblems) => new(
    PimDb.Int64(reader, "ImportRunId"), PimDb.TextOrEmpty(reader, "Kind"), PimDb.TextOrEmpty(reader, "Title"), PimDb.Text(reader, "Note"),
    PimDb.TextOrEmpty(reader, "Actor"), PimDb.DateTimeValue(reader, "AppliedUtc"), PimDb.Int32(reader, "RowCountValue"),
    PimDb.Int32(reader, "ChangeCount"), PimDb.Int32(reader, "SaopCount"), PimDb.Text(reader, "OutboundBatchIds"),
    PimDb.NullableInt64(reader, "UndoOfImportRunId"), PimDb.NullableInt64(reader, "UndoneByImportRunId"),
    PimDb.NullableDateTime(reader, "UndoneUtc"), PimDb.Text(reader, "UndoneBy"), PimDb.Text(reader, "Organizations"),
    withProblems ? PimDb.Text(reader, "Problems") : null);
}
