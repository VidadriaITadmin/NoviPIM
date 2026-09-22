using System.Data;
using System.Globalization;
using Microsoft.Data.SqlClient;

namespace PIM.Operations;

/// <summary>
/// Šifre faz. Faza je najmanjši košček dela, ki ga uporabnik hoče videti: »prenos je uspel,
/// branje je prebralo 1.389 zapisov, zapisanih je bilo 0, ker je posnetek že v bazi«.
/// Ista beseda gre v <c>ops.JobPhaseRun.PhaseCode</c> in v dnevnik, zato je tu na enem mestu.
/// </summary>
public static class PhaseCodes
{
  /// <summary>Prenos datoteke od dobavitelja ali klic vira (FTP, HTTPS, SAOP).</summary>
  public const string Fetch = "PRENOS";
  /// <summary>Branje in razčlenitev datoteke ali odgovora v zapise.</summary>
  public const string Read = "BRANJE";
  /// <summary>Zapis zapisov v vhodno tabelo (raw.Inbox, stock.LandingRecord ...).</summary>
  public const string Land = "ZAPIS";
  /// <summary>Ujemanje zapisov z artikli (stock.Position, neujeti zapisi).</summary>
  public const string Match = "UJEMANJE";
  /// <summary>Preslikava iz vhodne tabele v katalog (map.ProcessRawInbox in sorodne).</summary>
  public const string Map = "PRESLIKAVA";
  /// <summary>Premik vodnega žiga vira.</summary>
  public const string Watermark = "MEJNIK";
  /// <summary>Izdelava izhodne datoteke.</summary>
  public const string File = "DATOTEKA";
  /// <summary>Izračun ali obdelava v bazi (validacija, objava).</summary>
  public const string Compute = "IZRACUN";
  /// <summary>Pošiljanje navzven (e-pošta, webhook, SAOP).</summary>
  public const string Send = "POSILJANJE";

  /// <summary>Vrstni red faz v prikazu; kar ni na seznamu, gre na konec po vrstnem redu zapisa.</summary>
  public static IReadOnlyList<string> Order { get; } =
    [Fetch, Read, Land, Match, Map, Watermark, Compute, File, Send];

  public static string Label(string code) => code switch
  {
    Fetch => "Prenos",
    Read => "Branje",
    Land => "Zapis",
    Match => "Ujemanje",
    Map => "Preslikava",
    Watermark => "Mejnik",
    File => "Datoteka",
    Compute => "Izračun",
    Send => "Pošiljanje",
    _ => code,
  };
}

/// <summary>Izid faze; »preskočeno« namenoma ni uspeh.</summary>
public enum PhaseOutcome
{
  Running,
  /// <summary>Faza je opravila delo. Ali je prinesla nove podatke, pove <c>HasNewData</c>.</summary>
  Succeeded,
  /// <summary>Dela ni bilo ali ga ni bilo dovoljeno opraviti (omejitev vira, nespremenjena datoteka). Vedno z razlogom.</summary>
  Skipped,
  Failed,
}

/// <summary>
/// Pisec faz za workerje (migracija 255).
///
/// Zakaj: doslej je bil najmanjši viden korak cel zagon workerja z izhodno kodo. Uporabnik
/// 2026-09-22: »moram videti, da se je XML prenesel, da se je dal prebrati in da so se podatki
/// vnesli v tabele«. Prenos Braytrona se pet dni ni zgodil, koraki pa so bili zeleni, ker je
/// worker vsakič uspešno prebral isto staro datoteko.
///
/// Pravila:
///   1. Poročanje nikoli ne sme podreti zajema. Vsaka napaka pri pisanju v bazo se pogoltne in
///      izpiše v dnevnik; faza brez povezave do baze samo izpisuje vrstice.
///   2. Ista vrstica gre v bazo in v dnevnik, da se izpis in stran ne razhajata.
///   3. Faza, ki se ne konča sama (izjema, padec procesa), velja za padlo.
///
/// Kdo jo poveže s tekom posla: gostitelj (PIM.AutomationHost) poda otroškemu procesu okoljski
/// spremenljivki <c>PIM_JOB_RUN_ID</c> in <c>PIM_JOB_STEP_ORDER</c>. Ročni zagon iz ukazne vrstice
/// ju nima; takrat se faze zapišejo brez teka posla in so vidne pod svežino vira.
/// </summary>
public sealed class PhaseLog
{
  public const string JobRunVariable = "PIM_JOB_RUN_ID";
  public const string StepOrderVariable = "PIM_JOB_STEP_ORDER";

  readonly string? connectionString;
  readonly Action<string> log;
  int order;

  PhaseLog(string? connectionString, string? workerId, long? jobRunId, int? stepOrder, Action<string>? log)
  {
    this.connectionString = string.IsNullOrWhiteSpace(connectionString) ? null : connectionString;
    this.log = log ?? Console.WriteLine;
    WorkerId = workerId;
    JobRunId = jobRunId;
    StepOrder = stepOrder;
  }

  public string? WorkerId { get; }
  public long? JobRunId { get; }
  public int? StepOrder { get; }

  /// <summary>Ali se faze sploh zapisujejo v bazo; brez povezave ostane samo izpis.</summary>
  public bool WritesToDatabase => connectionString is not null;

  /// <summary>
  /// Pisec iz okolja: tek posla in korak prevzame od gostitelja, če ju je podal.
  /// </summary>
  public static PhaseLog FromEnvironment(string? connectionString, string? workerId = null, Action<string>? log = null)
  {
    var jobRunId = long.TryParse(Environment.GetEnvironmentVariable(JobRunVariable), NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsedRun) && parsedRun > 0
      ? parsedRun
      : (long?)null;
    var stepOrder = int.TryParse(Environment.GetEnvironmentVariable(StepOrderVariable), NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsedStep) && parsedStep > 0
      ? parsedStep
      : (int?)null;
    return new PhaseLog(connectionString, workerId, jobRunId, stepOrder, log);
  }

  /// <summary>
  /// Pisec za delo, ki ga gostitelj opravi sam, brez otroškega procesa (SQL koraki validacije in objave
  /// v JobRunner): tek in korak pozna iz lastnega stanja, ne iz okolja. Neveljavni številki (0 ali manj)
  /// pomenita »brez vezi«, enako kot pokvarjena spremenljivka okolja pri <see cref="FromEnvironment"/>.
  /// </summary>
  public static PhaseLog ForJob(string? connectionString, string? workerId, long? jobRunId, int? stepOrder, Action<string>? log = null) =>
    new(connectionString, workerId, jobRunId is > 0 ? jobRunId : null, stepOrder is > 0 ? stepOrder : null, log);

  /// <summary>Pisec brez baze (preizkusi, <c>--samo-preberi</c>, manjkajoča povezava).</summary>
  public static PhaseLog Disabled(Action<string>? log = null) => new(null, null, null, null, log);

  /// <summary>
  /// Odpre fazo. Vrnjeni predmet je treba zapreti (<c>SucceededAsync</c>, <c>SkippedAsync</c>,
  /// <c>FailedAsync</c>); <c>await using</c> poskrbi, da nezaprta faza obvelja za padlo.
  /// </summary>
  public async Task<Phase> BeginAsync(
    string phaseCode, string? sourceCode = null, int? organizationId = null, string? pipeline = null,
    Guid? runId = null, string? message = null, CancellationToken cancellationToken = default)
  {
    var phaseOrder = Interlocked.Increment(ref order);
    var phase = new Phase(this, phaseCode, phaseOrder, sourceCode, organizationId, pipeline, runId);
    Write($"{Prefix(phaseCode, sourceCode, organizationId)} se je začela{(message is { Length: > 0 } ? $": {message}" : "")}.");

    if (connectionString is null) return phase;

    try
    {
      await using var connection = new SqlConnection(connectionString);
      await connection.OpenAsync(cancellationToken);
      await using var command = new SqlCommand("ops.BeginJobPhase", connection) { CommandType = CommandType.StoredProcedure };
      command.Parameters.Add("@PhaseCode", SqlDbType.NVarChar, 40).Value = phaseCode;
      command.Parameters.Add("@PhaseOrder", SqlDbType.Int).Value = phaseOrder;
      command.Parameters.Add("@JobRunId", SqlDbType.BigInt).Value = (object?)JobRunId ?? DBNull.Value;
      command.Parameters.Add("@StepOrder", SqlDbType.Int).Value = (object?)StepOrder ?? DBNull.Value;
      command.Parameters.Add("@RunId", SqlDbType.UniqueIdentifier).Value = (object?)runId ?? DBNull.Value;
      command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = (object?)organizationId ?? DBNull.Value;
      command.Parameters.Add("@Pipeline", SqlDbType.NVarChar, 100).Value = (object?)pipeline ?? DBNull.Value;
      command.Parameters.Add("@SourceCode", SqlDbType.NVarChar, 100).Value = (object?)sourceCode ?? DBNull.Value;
      command.Parameters.Add("@WorkerId", SqlDbType.NVarChar, 200).Value = (object?)WorkerId ?? DBNull.Value;
      command.Parameters.Add("@Message", SqlDbType.NVarChar, 1000).Value = (object?)Trim(message) ?? DBNull.Value;
      var id = command.Parameters.Add("@JobPhaseRunId", SqlDbType.BigInt);
      id.Direction = ParameterDirection.Output;
      await command.ExecuteNonQueryAsync(cancellationToken);
      if (id.Value is long value) phase.Id = value;
    }
    catch (Exception exception) when (exception is SqlException or InvalidOperationException)
    {
      Swallow("odprtja", exception);
    }

    return phase;
  }

  /// <summary>Faza, ki je že znana kot končana (na primer preskok pred vsakim delom).</summary>
  public async Task RecordAsync(
    string phaseCode, PhaseOutcome outcome, string? sourceCode = null, int? organizationId = null,
    string? pipeline = null, Guid? runId = null, string? message = null, bool hasNewData = false,
    long? itemsIn = null, long? itemsOut = null, long? itemsRejected = null, long? byteCount = null,
    CancellationToken cancellationToken = default)
  {
    var phase = await BeginAsync(phaseCode, sourceCode, organizationId, pipeline, runId, cancellationToken: cancellationToken);
    await phase.CompleteAsync(outcome, hasNewData, itemsIn, itemsOut, itemsRejected, byteCount, message, cancellationToken);
  }

  internal async Task CompleteAsync(
    Phase phase, PhaseOutcome outcome, bool hasNewData, long? itemsIn, long? itemsOut, long? itemsRejected,
    long? byteCount, string? message, CancellationToken cancellationToken)
  {
    Write(Describe(phase, outcome, hasNewData, itemsIn, itemsOut, itemsRejected, byteCount, message));

    if (connectionString is null || phase.Id is not { } id) return;

    try
    {
      await using var connection = new SqlConnection(connectionString);
      await connection.OpenAsync(cancellationToken);
      await using var command = new SqlCommand("ops.CompleteJobPhase", connection) { CommandType = CommandType.StoredProcedure };
      command.Parameters.Add("@JobPhaseRunId", SqlDbType.BigInt).Value = id;
      command.Parameters.Add("@Status", SqlDbType.NVarChar, 20).Value = outcome switch
      {
        PhaseOutcome.Succeeded => "Succeeded",
        PhaseOutcome.Skipped => "Skipped",
        _ => "Failed",
      };
      command.Parameters.Add("@HasNewData", SqlDbType.Bit).Value = hasNewData && outcome == PhaseOutcome.Succeeded;
      command.Parameters.Add("@ItemsIn", SqlDbType.BigInt).Value = (object?)itemsIn ?? DBNull.Value;
      command.Parameters.Add("@ItemsOut", SqlDbType.BigInt).Value = (object?)itemsOut ?? DBNull.Value;
      command.Parameters.Add("@ItemsRejected", SqlDbType.BigInt).Value = (object?)itemsRejected ?? DBNull.Value;
      command.Parameters.Add("@ByteCount", SqlDbType.BigInt).Value = (object?)byteCount ?? DBNull.Value;
      command.Parameters.Add("@Message", SqlDbType.NVarChar, 1000).Value = (object?)Trim(message) ?? DBNull.Value;
      command.Parameters.Add("@RunId", SqlDbType.UniqueIdentifier).Value = (object?)phase.RunId ?? DBNull.Value;
      await command.ExecuteNonQueryAsync(cancellationToken);
    }
    catch (Exception exception) when (exception is SqlException or InvalidOperationException)
    {
      Swallow("zapiranja", exception);
    }
  }

  /// <summary>
  /// Vrstica za dnevnik. Ista oblika kot v bazi, da se izpis in stran Nadzor ne razhajata;
  /// čista funkcija, da jo je mogoče preveriti brez baze in procesa.
  /// </summary>
  public static string Describe(
    string phaseCode, string? sourceCode, int? organizationId, PhaseOutcome outcome, bool hasNewData,
    long? itemsIn, long? itemsOut, long? itemsRejected, long? byteCount, string? message)
  {
    var stanje = outcome switch
    {
      PhaseOutcome.Succeeded => hasNewData ? "uspelo" : "uspelo, brez novih podatkov",
      PhaseOutcome.Skipped => "preskočeno",
      PhaseOutcome.Failed => "NAPAKA",
      _ => "teče",
    };

    var deli = new List<string>();
    if (itemsIn is { } vhod) deli.Add($"prebrano {Number(vhod)}");
    if (itemsOut is { } izhod) deli.Add($"zapisano {Number(izhod)}");
    if (itemsRejected is { } zavrnjeno && zavrnjeno > 0) deli.Add($"zavrnjeno {Number(zavrnjeno)}");
    if (byteCount is { } bajti) deli.Add(Size(bajti));

    var vrstica = $"{Prefix(phaseCode, sourceCode, organizationId)} {stanje}";
    if (deli.Count > 0) vrstica += $" — {string.Join(", ", deli)}";
    if (Trim(message) is { Length: > 0 } opomba) vrstica += $"; {opomba}";
    return vrstica + ".";
  }

  static string Describe(Phase phase, PhaseOutcome outcome, bool hasNewData, long? itemsIn, long? itemsOut,
    long? itemsRejected, long? byteCount, string? message) =>
    Describe(phase.PhaseCode, phase.SourceCode, phase.OrganizationId, outcome, hasNewData, itemsIn, itemsOut, itemsRejected, byteCount, message);

  static string Prefix(string phaseCode, string? sourceCode, int? organizationId)
  {
    var predmet = sourceCode is { Length: > 0 } ? $" {sourceCode}" : "";
    var podjetje = organizationId is { } org ? $" (podjetje {org.ToString(CultureInfo.InvariantCulture)})" : "";
    return $"[FAZA] {PhaseCodes.Label(phaseCode)}{predmet}{podjetje}:";
  }

  static string Number(long value) => value.ToString("N0", CultureInfo.GetCultureInfo("sl-SI"));

  static string Size(long bytes) => bytes switch
  {
    < 1024 => $"{bytes} B",
    < 1024 * 1024 => $"{(bytes / 1024.0).ToString("N1", CultureInfo.GetCultureInfo("sl-SI"))} kB",
    _ => $"{(bytes / (1024.0 * 1024)).ToString("N1", CultureInfo.GetCultureInfo("sl-SI"))} MB",
  };

  static string? Trim(string? value)
  {
    if (string.IsNullOrWhiteSpace(value)) return null;
    var single = value.Replace('\r', ' ').Replace('\n', ' ').Trim();
    return single.Length <= 1000 ? single : single[..1000];
  }

  void Write(string line)
  {
    try { log(line); }
    catch (IOException) { }
  }

  void Swallow(string kaj, Exception exception) =>
    Write($"[FAZA] opozorilo: zapisa {kaj} faze ni bilo mogoče shraniti ({exception.GetType().Name}); delo se nadaljuje.");

  /// <summary>Ena odprta faza.</summary>
  public sealed class Phase : IAsyncDisposable
  {
    readonly PhaseLog owner;
    bool completed;

    internal Phase(PhaseLog owner, string phaseCode, int phaseOrder, string? sourceCode, int? organizationId, string? pipeline, Guid? runId)
    {
      this.owner = owner;
      PhaseCode = phaseCode;
      PhaseOrder = phaseOrder;
      SourceCode = sourceCode;
      OrganizationId = organizationId;
      Pipeline = pipeline;
      RunId = runId;
    }

    public string PhaseCode { get; }
    public int PhaseOrder { get; }
    public string? SourceCode { get; }
    public int? OrganizationId { get; }
    public string? Pipeline { get; }
    public Guid? RunId { get; private set; }
    internal long? Id { get; set; }

    /// <summary>Tek postopka, ki ga je worker odprl šele po začetku faze (ops.BeginRun).</summary>
    public void Attach(Guid runId) => RunId = runId;

    public Task SucceededAsync(long? itemsIn = null, long? itemsOut = null, long? itemsRejected = null,
      long? byteCount = null, bool hasNewData = true, string? message = null, CancellationToken cancellationToken = default) =>
      CompleteAsync(PhaseOutcome.Succeeded, hasNewData, itemsIn, itemsOut, itemsRejected, byteCount, message, cancellationToken);

    /// <summary>Dela ni bilo; razlog je obvezen, ker je prav to tisto, česar doslej ni bilo videti.</summary>
    public Task SkippedAsync(string reason, long? itemsIn = null, CancellationToken cancellationToken = default) =>
      CompleteAsync(PhaseOutcome.Skipped, false, itemsIn, null, null, null, reason, cancellationToken);

    public Task FailedAsync(string error, long? itemsIn = null, long? itemsRejected = null, CancellationToken cancellationToken = default) =>
      CompleteAsync(PhaseOutcome.Failed, false, itemsIn, null, itemsRejected, null, error, cancellationToken);

    public async Task CompleteAsync(PhaseOutcome outcome, bool hasNewData = false, long? itemsIn = null, long? itemsOut = null,
      long? itemsRejected = null, long? byteCount = null, string? message = null, CancellationToken cancellationToken = default)
    {
      if (completed) return;
      completed = true;
      await owner.CompleteAsync(this, outcome, hasNewData, itemsIn, itemsOut, itemsRejected, byteCount, message, cancellationToken);
    }

    /// <summary>Nezaprta faza je padla faza: proces je umrl ali je izjema preskočila zapiranje.</summary>
    public async ValueTask DisposeAsync()
    {
      if (completed) return;
      await CompleteAsync(PhaseOutcome.Failed, message: "Faza se ni končala; izvajanje je bilo prekinjeno.");
    }
  }
}
