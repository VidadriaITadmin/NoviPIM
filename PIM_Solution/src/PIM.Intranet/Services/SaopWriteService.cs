using System.Data;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using PIM.Operations;
using PIM.Outbound;

namespace PIM.Intranet.Services;

/// <summary>
/// Izid poskusa takojšnjega pošiljanja po kliku "Odobri" — glej <see cref="SaopWriteService.TrySendArticleAsync"/>.
/// </summary>
/// <param name="Documents">Koliko dokumentov je bilo dejansko obdelanih (0, kadar ni bilo česa poslati).</param>
/// <param name="Notes">Ena vrstica na dokument — enaka oblika kot pri worker CLI, npr. "NW.12603: PATCH uspešno".</param>
/// <param name="NotConfigured">Poverilnice SAOP (razdelek "Saop" v appsettings.Local.json ali PIM_SAOP_* v okolju) niso nastavljene; ni bilo poskušeno nič.</param>
public sealed record SaopSendBatchResult(int Documents, int Sent, int Failed, IReadOnlyList<string> Notes, bool NotConfigured);

/// <param name="ValueFormat"><c>text</c>, <c>decimal4</c>, <c>decimal8</c> ali <c>bool</c>.</param>
public sealed record WritableFieldRow(
  string FieldKey, string ElementName, string Section, string ValueFormat,
  string? TrueValue, string? FalseValue, bool IsAddMandatory, int SortOrder);

/// <param name="Status"><c>Queued</c>, <c>Duplicate</c> ali <c>Rejected</c>.</param>
public sealed record BulkChangeResultRow(int Ordinal, string? ItemId, string? FieldKey, string Status, string? Reason, long? OutboxMessageId);

public sealed record BulkChangeOutcome(long OutboundBatchId, IReadOnlyList<BulkChangeResultRow> Rows)
{
  public int Queued => Rows.Count(row => row.Status == "Queued");
  public int Duplicates => Rows.Count(row => row.Status == "Duplicate");
  public int Rejected => Rows.Count(row => row.Status == "Rejected");
}

/// <param name="Status">Stanje odhodnega sporočila; nad kanonično vrednostjo se pokaže kot »čaka potrditev«.</param>
public sealed record PendingOverlayRow(
  string EntityKey, string FieldKey, string? Value, string Status, long OutboxMessageId,
  long? OutboundBatchId, DateTime CreatedUtc, DateTime? SentUtc, string? LastError, string? SaopErrorKind);

public sealed record OutboundEventRow(
  long OutboundEventId, long? OutboundBatchId, string EntityType, string EntityKey, string Step, string Severity,
  string Title, string? Detail, string? FieldName, DateTime CreatedUtc, DateTime? AcknowledgedUtc,
  string? AcknowledgedBy, DateTime? EscalatedUtc);

public sealed record OutboundEventCounts(int Errors, int Warnings, int Escalated, int QuietToday);

public sealed record OutboundBatchRow(
  long OutboundBatchId, string Source, string? Note, string CreatedBy, DateTime CreatedUtc, DateTime? ClosedUtc,
  int Items, int Messages, int PendingApproval, int Queued, int Sent, int Failed);

/// <summary>
/// Zapisovalna pot v SAOP z vidika vmesnika: katera polja se sme urejati, kako se naroči
/// množična sprememba, kaj čaka potrditev in kaj se je zgodilo.
///
/// Ločena od <see cref="IntranetDataService"/> namenoma: ta bere stanje sistema, ta storitev pa
/// spreminja to, kar bo šlo v ERP. Mešanje obojega v en razred je hitro pripeljalo do tega, da
/// je bralna stran nehote dobila zapisovalne poti.
///
/// Poslovne varovalke — lastništvo polja, pripadnost dokumentu, dedup, odobritev — odloči baza;
/// ta storitev samo pokaže izid. Edino, česar baza ne ve, je **kdo** zapis naroča, zato se vloga
/// preveri tu (ugotovitev A1, pregled 2026-09-08): <c>@Actor</c> je bil doslej samo revizijski
/// podatek in ne pogoj.
/// </summary>
public sealed class SaopWriteService(IConfiguration configuration, PimWriteGuard guard, ILogger<SaopWriteService> logger)
{
  const string TargetKind = "SAOP_PRODUCT";

  // Prek resolverja in ne naravnost iz konfiguracije: ta storitev je edina hodila mimo njega,
  // zato je kot edina spregledala PIM_CONNECTION_STRING in v produkciji vzela prazno vrednost.
  string ConnectionString => ConnectionStringResolver.Resolve(configuration)
    ?? throw new InvalidOperationException("Povezava na bazo PIM ni nastavljena.");

  /* --- kaj se sme urejati ---------------------------------------------- */

  public async Task<IReadOnlyList<WritableFieldRow>> GetWritableFieldsAsync(int organizationId, CancellationToken cancellationToken = default)
  {
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand("EXEC intranet.GetWritableSaopFields @OrganizationId, @TargetKind;", connection);
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@TargetKind", SqlDbType.NVarChar, 100).Value = TargetKind;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    var rows = new List<WritableFieldRow>();
    while (await reader.ReadAsync(cancellationToken))
      rows.Add(new(
        reader.GetString(reader.GetOrdinal("FieldKey")),
        reader.GetString(reader.GetOrdinal("ElementName")),
        reader.GetString(reader.GetOrdinal("Section")),
        reader.GetString(reader.GetOrdinal("ValueFormat")),
        Text(reader, "TrueValue"), Text(reader, "FalseValue"),
        reader.GetBoolean(reader.GetOrdinal("IsAddMandatory")),
        reader.GetInt32(reader.GetOrdinal("SortOrder"))));
    return rows;
  }

  /* --- množično naročilo ------------------------------------------------ */

  /// <param name="changes">Trojice artikel/polje/vrednost; prazna vrednost pomeni izpraznitev polja.</param>
  public async Task<BulkChangeOutcome> EnqueueAsync(
    int organizationId, IEnumerable<(string ItemId, string FieldKey, string? Value)> changes,
    string actor, string source, string? note, CancellationToken cancellationToken = default)
  {
    await guard.RequireAsync(PimPolicies.SaopWrite);
    var payload = JsonSerializer.Serialize(changes.Select(change => new
    {
      itemId = change.ItemId,
      fieldKey = change.FieldKey,
      value = change.Value ?? string.Empty
    }));

    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand(
      "EXEC out.EnqueueSaopItemChanges @OrganizationId, @ChangesJson, @Actor, @Source, @Note, @OutboundBatchId OUTPUT;", connection);
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@ChangesJson", SqlDbType.NVarChar, -1).Value = payload;
    command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = actor;
    command.Parameters.Add("@Source", SqlDbType.NVarChar, 30).Value = source;
    command.Parameters.Add("@Note", SqlDbType.NVarChar, 400).Value = (object?)note ?? DBNull.Value;
    var batch = command.Parameters.Add("@OutboundBatchId", SqlDbType.BigInt);
    batch.Direction = ParameterDirection.InputOutput;
    batch.Value = DBNull.Value;

    var rows = new List<BulkChangeResultRow>();
    await using (var reader = await command.ExecuteReaderAsync(cancellationToken))
      while (await reader.ReadAsync(cancellationToken))
        rows.Add(new(
          reader.GetInt32(0), Text(reader, "ItemID"), Text(reader, "FieldKey"),
          reader.GetString(reader.GetOrdinal("Status")), Text(reader, "Reason"),
          reader.IsDBNull(reader.GetOrdinal("OutboxMessageId")) ? null : reader.GetInt64(reader.GetOrdinal("OutboxMessageId"))));

    return new(batch.Value is DBNull ? 0 : Convert.ToInt64(batch.Value), rows);
  }

  public async Task<int> ApproveBatchAsync(long batchId, string actor, CancellationToken cancellationToken = default) =>
    await GuardedScalarIntAsync("EXEC out.ApproveOutboundBatch @Batch, @Actor;", batchId, actor, cancellationToken);

  public async Task<int> CancelBatchAsync(long batchId, string actor, CancellationToken cancellationToken = default) =>
    await GuardedScalarIntAsync("EXEC out.CancelOutboundBatch @Batch, @Actor;", batchId, actor, cancellationToken);

  public async Task<int> RequeueMessageAsync(long messageId, string actor, CancellationToken cancellationToken = default) =>
    await GuardedScalarIntAsync("EXEC out.RequeueOutboxMessage @Batch, @Actor;", messageId, actor, cancellationToken);

  public async Task<int> RequeueBatchAsync(long batchId, string actor, CancellationToken cancellationToken = default) =>
    await GuardedScalarIntAsync("EXEC out.RequeueOutboundBatch @Batch, @Actor;", batchId, actor, cancellationToken);

  /* --- takojsnje posiljanje po odobritvi --------------------------------- */

  /// <summary>
  /// Poskusi TAKOJ poslati TOČNO EN, DOLOČEN artikel v SAOP — namesto da uporabnik po kliku na
  /// "Odobri" čaka na naslednji zagon workerja `PIM.OutboxDispatcher`. Uporabnik je izrecno
  /// zahteval, da se pošlje artikel, ki ga je označil, ne najstarejši v vrsti — zato
  /// <see cref="SaopDocumentRunner.SendOneAsync"/> prevzame prek `out.ClaimItemDocumentByKey`
  /// (migracija 193, po šifri), ne prek `out.ClaimItemDocument` (po vrstnem redu, za worker).
  /// Sicer ista pot gradnje dokumenta, POST/PATCH odločitve (<see cref="SaopIntentResolver"/>)
  /// in zaključka (`out.CompleteItemDocument`) kot worker. Kar se ne pošlje (ni poverilnic,
  /// časovna omejitev, zavrnitev), NE izgine — ostane v vrsti za naslednji poskus.
  ///
  /// Bere isto mesto kot že obstoječi zajem iz SAOP (razdelek "Saop" v `appsettings.Local.json`,
  /// polja BaseUrl/Username/Password/AcceptUntrustedCertificate — glej `appsettings.Local.example.json`
  /// in `PIM.KatalogWorker.SaopWorkerConfiguration`), z istima okoljskima spremenljivkama
  /// (`PIM_SAOP_USERNAME`, `PIM_SAOP_PASSWORD`, `PIM_SAOP_BASE_URL`) kot prednostnim virom. En sam
  /// vir poverilnic za ves SAOP promet, namesto da bi si vsak klicatelj izmislil svoje ime. Brez
  /// njih se ne poskusi nič in to ni napaka: artikel preprosto čaka na worker, tako kot je čakal doslej.
  /// </summary>
  public async Task<SaopSendBatchResult> TrySendArticleAsync(int organizationId, string entityKey, CancellationToken cancellationToken = default)
  {
    var (baseUrl, username, password, acceptUntrusted) = ReadSaopCredentials();
    if (string.IsNullOrWhiteSpace(username) || string.IsNullOrWhiteSpace(password))
    {
      logger.LogInformation(
        "SAOP posiljanje: preskoceno za artikel {Artikel} (organizacija {Organizacija}) — razdelek Saop v appsettings.Local.json (ali PIM_SAOP_USERNAME/PIM_SAOP_PASSWORD v okolju) nima uporabnika/gesla.",
        entityKey, organizationId);
      return new(0, 0, 0, [], NotConfigured: true);
    }

    await guard.RequireAsync(PimPolicies.SaopWrite);

    // BaseUrl pride dejansko iz dbo.IntegrationProfile te organizacije (SaopDocumentRunner ga
    // bere ob prevzemu); nastavitev tu je samo varnostna mreza, ce profil naslova nima.
    var connection = new SaopConnection(baseUrl ?? string.Empty, username, password,
      TimeoutSeconds: 20, AcceptUntrustedCertificate: acceptUntrusted);

    using var sender = new SaopDocumentSender(connection);
    var workerId = $"intranet:{Environment.MachineName}:{Environment.ProcessId}";
    var options = new SaopDocumentRunOptions(TargetKind, DryRun: false, OutputDirectory: null, MaxDocuments: 1, OrganizationId: organizationId);
    var runner = new SaopDocumentRunner(ConnectionString, workerId, options, sender);

    logger.LogInformation(
      "SAOP posiljanje: zacenjam za artikel {Artikel} (organizacija {Organizacija}, worker {WorkerId}).",
      entityKey, organizationId, workerId);

    // Krajsa omejitev kot pri worker CLI (privzeto 120s): to tece znotraj klika v Blazorju in ne
    // sme predolgo zamrzniti seje uporabnika, ce je SAOP pocasen ali ne odgovarja.
    using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
    timeout.CancelAfter(TimeSpan.FromSeconds(25));
    try
    {
      var result = await runner.SendOneAsync(organizationId, entityKey, timeout.Token);
      logger.LogInformation(
        "SAOP posiljanje: konec za artikel {Artikel} — poslanih {Poslanih}, neuspesnih {Neuspesnih}. {Podrobnosti}",
        entityKey, result.Sent, result.Failed, string.Join(" | ", result.Notes));
      return new(result.Documents, result.Sent, result.Failed, result.Notes, NotConfigured: false);
    }
    catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
    {
      logger.LogWarning("SAOP posiljanje: casovna omejitev za artikel {Artikel} (organizacija {Organizacija}).", entityKey, organizationId);
      return new(0, 0, 0, ["SAOP se ni odzval pravočasno; poskus bo ponovil naslednji zagon workerja."], NotConfigured: false);
    }
    catch (Exception exception)
    {
      logger.LogError(exception, "SAOP posiljanje: nepricakovana napaka za artikel {Artikel} (organizacija {Organizacija}).", entityKey, organizationId);
      return new(0, 0, 0, [$"Nepričakovana napaka: {exception.Message}"], NotConfigured: false);
    }
  }

  /// <summary>
  /// Isti razdelek "Saop" (appsettings.Local.json) in ista okoljska imena (PIM_SAOP_*), ki jih
  /// bere <c>PIM.KatalogWorker.SaopWorkerConfiguration</c> za zajem IZ SAOP — gre za isti SAOP
  /// racun, zato je prav, da je mesto nastavitve eno samo. Okolje ima prednost pred datoteko.
  /// </summary>
  internal static (string? BaseUrl, string? Username, string? Password, bool AcceptUntrustedCertificate) ReadSaopCredentials()
  {
    var saop = LocalSettings.Section("Saop");
    string? Text(string name) =>
      saop is { } section && section.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
        ? value.GetString() : null;
    bool Flag(string name) =>
      saop is { } section && section.TryGetProperty(name, out var value) && value.ValueKind is JsonValueKind.True or JsonValueKind.False
        && value.GetBoolean();
    static string? Env(string name)
    {
      var value = Environment.GetEnvironmentVariable(name);
      return string.IsNullOrWhiteSpace(value) ? null : value;
    }

    return (
      Env("PIM_SAOP_BASE_URL") ?? Text("BaseUrl"),
      Env("PIM_SAOP_USERNAME") ?? Text("Username"),
      Env("PIM_SAOP_PASSWORD") ?? Text("Password"),
      Flag("AcceptUntrustedCertificate"));
  }

  /// <summary>Zapisovalna razlicica: najprej vloga, sele nato baza.</summary>
  async Task<int> GuardedScalarIntAsync(string sql, long batchId, string actor, CancellationToken cancellationToken)
  {
    await guard.RequireAsync(PimPolicies.SaopWrite);
    return await ScalarIntAsync(sql, batchId, actor, cancellationToken);
  }

  async Task<int> ScalarIntAsync(string sql, long batchId, string actor, CancellationToken cancellationToken)
  {
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand(sql, connection);
    command.Parameters.Add("@Batch", SqlDbType.BigInt).Value = batchId;
    command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = actor;
    var value = await command.ExecuteScalarAsync(cancellationToken);
    return value is null or DBNull ? 0 : Convert.ToInt32(value);
  }

  public async Task<IReadOnlyList<OutboundBatchRow>> GetBatchesAsync(int organizationId, CancellationToken cancellationToken = default)
  {
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand("EXEC intranet.GetOutboundBatches @OrganizationId, @Top;", connection);
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@Top", SqlDbType.Int).Value = 50;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    var rows = new List<OutboundBatchRow>();
    while (await reader.ReadAsync(cancellationToken))
      rows.Add(new(
        reader.GetInt64(reader.GetOrdinal("OutboundBatchId")),
        reader.GetString(reader.GetOrdinal("Source")), Text(reader, "Note"),
        reader.GetString(reader.GetOrdinal("CreatedBy")),
        reader.GetDateTime(reader.GetOrdinal("CreatedUtc")),
        reader.IsDBNull(reader.GetOrdinal("ClosedUtc")) ? null : reader.GetDateTime(reader.GetOrdinal("ClosedUtc")),
        reader.GetInt32(reader.GetOrdinal("Artiklov")), reader.GetInt32(reader.GetOrdinal("Sporocil")),
        Int(reader, "CakaOdobritev"), Int(reader, "VVrsti"), Int(reader, "Poslanih"), Int(reader, "Napak")));
    return rows;
  }

  /* --- prekrivka -------------------------------------------------------- */

  public async Task<IReadOnlyList<PendingOverlayRow>> GetPendingOverlayAsync(
    int organizationId, IEnumerable<string>? itemIds = null, CancellationToken cancellationToken = default)
  {
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand("EXEC intranet.GetPendingOverlay @OrganizationId, @ItemIdsJson, @TargetKind;", connection);
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@ItemIdsJson", SqlDbType.NVarChar, -1).Value =
      itemIds is null ? DBNull.Value : JsonSerializer.Serialize(itemIds);
    command.Parameters.Add("@TargetKind", SqlDbType.NVarChar, 100).Value = TargetKind;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    var rows = new List<PendingOverlayRow>();
    while (await reader.ReadAsync(cancellationToken))
      rows.Add(new(
        reader.GetString(reader.GetOrdinal("EntityKey")),
        reader.GetString(reader.GetOrdinal("FieldKey")),
        Text(reader, "Value"),
        reader.GetString(reader.GetOrdinal("Status")),
        reader.GetInt64(reader.GetOrdinal("OutboxMessageId")),
        reader.IsDBNull(reader.GetOrdinal("OutboundBatchId")) ? null : reader.GetInt64(reader.GetOrdinal("OutboundBatchId")),
        reader.GetDateTime(reader.GetOrdinal("CreatedUtc")),
        reader.IsDBNull(reader.GetOrdinal("SentUtc")) ? null : reader.GetDateTime(reader.GetOrdinal("SentUtc")),
        Text(reader, "LastError"), Text(reader, "SaopErrorKind")));
    return rows;
  }

  /* --- obvestila -------------------------------------------------------- */

  public async Task<IReadOnlyList<OutboundEventRow>> GetEventsAsync(
    int organizationId, bool onlyOpen, CancellationToken cancellationToken = default)
  {
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand("EXEC intranet.GetOutboundEvents @OrganizationId, @OnlyOpen, @Top;", connection);
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@OnlyOpen", SqlDbType.Bit).Value = onlyOpen;
    command.Parameters.Add("@Top", SqlDbType.Int).Value = 200;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    var rows = new List<OutboundEventRow>();
    while (await reader.ReadAsync(cancellationToken))
      rows.Add(new(
        reader.GetInt64(reader.GetOrdinal("OutboundEventId")),
        reader.IsDBNull(reader.GetOrdinal("OutboundBatchId")) ? null : reader.GetInt64(reader.GetOrdinal("OutboundBatchId")),
        reader.GetString(reader.GetOrdinal("EntityType")),
        reader.GetString(reader.GetOrdinal("EntityKey")),
        reader.GetString(reader.GetOrdinal("Step")),
        reader.GetString(reader.GetOrdinal("Severity")),
        reader.GetString(reader.GetOrdinal("Title")),
        Text(reader, "Detail"), Text(reader, "FieldName"),
        reader.GetDateTime(reader.GetOrdinal("CreatedUtc")),
        reader.IsDBNull(reader.GetOrdinal("AcknowledgedUtc")) ? null : reader.GetDateTime(reader.GetOrdinal("AcknowledgedUtc")),
        Text(reader, "AcknowledgedBy"),
        reader.IsDBNull(reader.GetOrdinal("EscalatedUtc")) ? null : reader.GetDateTime(reader.GetOrdinal("EscalatedUtc"))));
    return rows;
  }

  public async Task<OutboundEventCounts> GetEventCountsAsync(int organizationId, CancellationToken cancellationToken = default)
  {
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand("EXEC intranet.GetOutboundEventCounts @OrganizationId;", connection);
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    if (!await reader.ReadAsync(cancellationToken)) return new(0, 0, 0, 0);
    return new(Int(reader, "Napak"), Int(reader, "Opozoril"), Int(reader, "Stopnjevanih"), Int(reader, "TihihDanes"));
  }

  public async Task AcknowledgeAsync(long eventId, string actor, CancellationToken cancellationToken = default)
  {
    await guard.RequireAsync(PimPolicies.SaopWrite);
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand("EXEC intranet.AcknowledgeOutboundEvent @Id, @Actor;", connection);
    command.Parameters.Add("@Id", SqlDbType.BigInt).Value = eventId;
    command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = actor;
    await command.ExecuteNonQueryAsync(cancellationToken);
  }

  public async Task<int> AcknowledgeBatchAsync(long batchId, string actor, CancellationToken cancellationToken = default) =>
    await GuardedScalarIntAsync("EXEC intranet.AcknowledgeOutboundBatchEvents @Batch, @Actor;", batchId, actor, cancellationToken);

  /* --- uvoz iz zvezka --------------------------------------------------- */

  /// <summary>
  /// Prebere zvezek in ga preslika na pisljiva polja. Ničesar ne naroči — vrne, kaj bi naredil,
  /// da uporabnik to vidi pred potrditvijo.
  ///
  /// Sama preslikava je v <see cref="WorkbookChangeMapper"/>, ker je čista logika: tako jo je
  /// mogoče preizkusiti brez baze in brez spletnega projekta. Slovenski naslov (glej
  /// <see cref="SaopFieldLabels"/>) doda ta stran, ker je edina, ki bazo za ta klic sploh sme
  /// videti — tako je prepoznan tudi delovni list s strani Izdelki, ki piše ta naslov namesto
  /// imena elementa SAOP.
  ///
  /// <see cref="ProductWorkbookContract.HeaderHints"/> je nujen: delovni list iz Izdelkov ima
  /// DVE naslovni vrstici (skupine — »Ključ«, »ERP …« — nato pravi naslovi), ker ima vsaj en
  /// stolpec Group (glej WorkbookWriter). Brez namiga bi bralnik za naslovno vrstico vzel prvo
  /// vrstico s katerima koli dvema nepraznima celicama — to je vrstica skupin, ne stolpcev — in
  /// uvoz bi javil, da manjka stolpec »Šifra artikla«/»ItemID«, čeprav je v datoteki, samo v
  /// drugi vrstici. Ista predloga s te strani (brez skupin) s hintom deluje enako kot brez njega.
  /// </summary>
  public WorkbookImportPreview PreviewWorkbook(Stream stream, IReadOnlyList<WritableFieldRow> writable)
  {
    var sheet = WorkbookTable.Read(stream, headerHints: ProductWorkbookContract.HeaderHints);
    return WorkbookChangeMapper.Map(sheet, writable
      .Select(polje => new WritableField(polje.FieldKey, polje.ElementName, SaopFieldLabels.For(polje.ElementName)))
      .ToArray());
  }

  async Task<SqlConnection> OpenAsync(CancellationToken cancellationToken)
  {
    var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    return connection;
  }

  static string? Text(SqlDataReader reader, string column)
  {
    var ordinal = reader.GetOrdinal(column);
    return reader.IsDBNull(ordinal) ? null : reader.GetString(ordinal);
  }

  static int Int(SqlDataReader reader, string column)
  {
    var ordinal = reader.GetOrdinal(column);
    return reader.IsDBNull(ordinal) ? 0 : Convert.ToInt32(reader.GetValue(ordinal));
  }
}
