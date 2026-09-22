using Microsoft.Data.SqlClient;
using PIM.Automation;
using PIM.Operations;

/*
  F11 — enotni model opravil (migracija 237) nad živo razvojno bazo.

  Dokazuje življenjski cikel zagona, ki ga je uporabnik zahteval 2026-09-21:
    1. odvisen posel, katerega predhodnik ni uspel, je Blocked z razlogom in se NE izvede;
    2. ista ovira drugič ne podvaja vrstice (Occurrences);
    3. uspeh predhodnika sproži odvisnega (NextDueUtc = zdaj, TriggeredBy = Dependency) in vrata se odprejo;
    4. padel zagon odpre alarm JobFailed, naslednji uspeh ga zapre;
    5. Running brez utripa je za bralca Abandoned (EffectiveStatus) in ga ops.AbandonStaleJobRuns zapre;
    6. zahteva za ustavitev pride do izvajalca ob utripu;
    7. intranet.SaveJobSchedule zavrne neveljaven razmik.

  Testna posla TEST_JOB_A/B sta izklopljena in ju katalog kode ne pozna, zato ju gostitelj (če teče)
  preskoči; vse vrstice se ob koncu pobrišejo.
*/

var connectionString = Environment.GetEnvironmentVariable("PIM_CONNECTION_STRING");
if (string.IsNullOrWhiteSpace(connectionString))
{
  Console.WriteLine("F11 avtomatizacija: preskočeno, PIM_CONNECTION_STRING ni nastavljen.");
  return 0;
}
if (!string.Equals(new SqlConnectionStringBuilder(connectionString).InitialCatalog, "PIM", StringComparison.OrdinalIgnoreCase))
  throw new InvalidOperationException("Ta test je dovoljen samo v razvojni bazi PIM.");

const string FazniVir = "F11_FAZE_TEST";
const string SveziVir = "F11_SVEZINA_TEST";
const string A = "TEST_JOB_A";
const string B = "TEST_JOB_B";
var store = new AutomationStore(connectionString);
var host = "F11";
var owner = "F11:test";

await CleanupAsync();
try
{
  await store.EnsureDefinitionsAsync(
  [
    // A je vklopljen (izklopljen predhodnik bi blokiral z drugim razlogom); katalog kode ga ne pozna, zato ga gostitelj preskoči.
    new(A, "Test A (predhodnik)", "F11", JobFlows.System, false, 900, WorkerJobReach.Internal, null, 60, null, 120, null, true, [], [], [], []),
    new(B, "Test B (odvisen)", "F11", JobFlows.System, false, 901, WorkerJobReach.Internal, null, 60, null, 120, null, false,
      [new(A, true, 3600, true, "F11 vrata in sprožilec")], [], [], []),
  ], CancellationToken.None);

  // 1. B je blokiran, ker A še nikoli ni uspel.
  var claimB = await store.ClaimAsync(B, DateTime.UtcNow.AddMinutes(1), owner, host, owner, null, force: true, CancellationToken.None);
  Check(!claimB.Claimed && claimB.Reason == $"Blocked:{A}", $"B mora biti blokiran zaradi A, dobil {claimB.Reason}.");
  var b = await JobAsync(B);
  Check(b.LastStatus == JobRunStatus.Blocked && b.LastBlockedByJobKey == A && b.LastError!.Contains("nikoli", StringComparison.Ordinal), "Blokada je zapisana z razlogom in predhodnikom.");
  var blockedRun = (await store.GetRunsAsync(5, B, null, null)).Single();
  Check(blockedRun.Status == "Blocked" && blockedRun.BlockedByJobKey == A && blockedRun.Occurrences == 1, "Blokiran zagon je vrstica v ops.JobRun.");

  // 2. Ista ovira drugič ne podvaja vrstice.
  claimB = await store.ClaimAsync(B, DateTime.UtcNow.AddMinutes(1), owner, host, owner, null, force: true, CancellationToken.None);
  var blockedRuns = await store.GetRunsAsync(5, B, null, null);
  Check(blockedRuns.Count == 1 && blockedRuns[0].Occurrences == 2, $"Ista blokada šteje ponovitve ({blockedRuns.Count} vrstic, {blockedRuns[0].Occurrences}×).");

  // 3. A uspe: B je sprožen in vrata se odprejo.
  var claimA = await store.ClaimAsync(A, DateTime.UtcNow.AddMinutes(1), owner, host, owner, null, force: true, CancellationToken.None);
  Check(claimA.Claimed && claimA.TriggeredBy == "Scheduler", $"A se prevzame ({claimA.Reason}).");
  var (cancelRequested, _) = await store.HeartbeatAsync(claimA.JobRunId!.Value, "korak 1", CancellationToken.None);
  Check(!cancelRequested, "Brez zahteve utrip ne zahteva ustavitve.");
  await store.RecordStepAsync(claimA.JobRunId.Value, 1, "korak 1", null, "test", DateTime.UtcNow, DateTime.UtcNow, 0, JobStepStatus.Succeeded, null, CancellationToken.None);
  await store.CompleteAsync(claimA.JobRunId.Value, new(JobRunStatus.Succeeded, 0, 1, 0, 0, 0, "F11 uspeh"), owner, CancellationToken.None);
  var a = await JobAsync(A);
  Check(a.LastStatus == JobRunStatus.Succeeded && a.LastSucceededUtc is not null && a.RunningJobRunId is null, "A je uspešen in ne teče več.");
  // B je izklopljen, zato ga sprožilec ne postavi na vrsto (ne sme zagnati izklopljenega posla) — vklopimo ga in ponovimo.
  await store.SaveScheduleAsync(B, true, 60, null, null, "F11", CancellationToken.None);
  claimA = await store.ClaimAsync(A, DateTime.UtcNow.AddMinutes(1), owner, host, owner, null, force: true, CancellationToken.None);
  await store.CompleteAsync(claimA.JobRunId!.Value, new(JobRunStatus.Succeeded, 0, 0, 0, 0, 0, "F11 uspeh 2"), owner, CancellationToken.None);
  b = await JobAsync(B);
  Check(b.NextDueUtc is { } due && due <= DateTime.UtcNow.AddSeconds(5) && b.TriggerSource == $"Dependency:{A}", $"Uspeh A postavi B na vrsto ({b.NextDueUtc}, {b.TriggerSource}).");
  claimB = await store.ClaimAsync(B, DateTime.UtcNow.AddMinutes(1), owner, host, owner, null, force: false, CancellationToken.None);
  Check(claimB.Claimed && claimB.TriggeredBy == "Dependency", $"B se po uspehu A prevzame kot Dependency ({claimB.Reason}, {claimB.TriggeredBy}).");

  // 4. Padec odpre alarm, uspeh ga zapre.
  await store.CompleteAsync(claimB.JobRunId!.Value, new(JobRunStatus.Failed, 1, 1, 1, 0, 2, "F11 namerni padec"), owner, CancellationToken.None);
  await store.EvaluateAlertsAsync("F11", CancellationToken.None);
  Check(await CountAsync($"SELECT COUNT(*) FROM ops.Alert WHERE AlertKind = N'JobFailed' AND Pipeline = N'OPRAVILO:{B}' AND ResolvedUtc IS NULL") == 1, "Padel zagon odpre alarm JobFailed.");
  claimB = await store.ClaimAsync(B, DateTime.UtcNow.AddMinutes(1), owner, host, owner, null, force: true, CancellationToken.None);
  Check(claimB.Claimed, "B se po padcu spet prevzame.");
  await store.CompleteAsync(claimB.JobRunId!.Value, new(JobRunStatus.Succeeded, 0, 1, 0, 0, 0, "F11 uspeh"), owner, CancellationToken.None);
  Check(await CountAsync($"SELECT COUNT(*) FROM ops.Alert WHERE AlertKind = N'JobFailed' AND Pipeline = N'OPRAVILO:{B}' AND ResolvedUtc IS NULL") == 0, "Uspeh zapre alarm JobFailed.");
  Check(await CountAsync($"SELECT COUNT(*) FROM ops.DataCheckpoint WHERE CheckpointKey = N'{B}' AND OrganizationId = 0") == 1, "Uspeh zapiše kontrolno točko.");

  // 5. Running brez utripa je Abandoned.
  claimA = await store.ClaimAsync(A, DateTime.UtcNow.AddMinutes(1), owner, host, owner, null, force: true, CancellationToken.None);
  await ExecuteAsync($"UPDATE ops.JobRun SET HeartbeatUtc = DATEADD(minute, -20, SYSUTCDATETIME()) WHERE JobRunId = {claimA.JobRunId}");
  var stale = (await store.GetRunsAsync(5, A, null, null)).First();
  Check(stale.Status == JobRunStatus.Running && stale.EffectiveStatus == JobRunStatus.Abandoned, "Bralec vidi Running brez utripa kot Abandoned, še preden ga kdo zapre.");
  var closed = await store.AbandonStaleAsync("F11", 10, null, CancellationToken.None);
  Check(closed >= 1, $"AbandonStaleJobRuns zapre zagon brez utripa (zaprtih {closed}).");
  a = await JobAsync(A);
  Check(a.LastStatus == JobRunStatus.Abandoned && a.RunningJobRunId is null, "Posel po zapuščenem zagonu ni več v teku.");
  await store.CompleteAsync(claimA.JobRunId!.Value, new(JobRunStatus.Succeeded, 0, 0, 0, 0, 0, "prepozno"), owner, CancellationToken.None);
  Check((await JobAsync(A)).LastStatus == JobRunStatus.Abandoned, "Pozen zaključek zapuščenega zagona ne prepiše stanja.");

  // 6. Ustavitev je zahteva, ki jo izvajalec izve ob utripu.
  claimA = await store.ClaimAsync(A, DateTime.UtcNow.AddMinutes(1), owner, host, owner, null, force: true, CancellationToken.None);
  await store.RequestCancelAsync(claimA.JobRunId!.Value, "F11 skrbnik", CancellationToken.None);
  var (requested, by) = await store.HeartbeatAsync(claimA.JobRunId.Value, null, CancellationToken.None);
  Check(requested && by == "F11 skrbnik", "Utrip pove, da je ustavitev zahtevana in kdo jo je zahteval.");
  await store.CompleteAsync(claimA.JobRunId.Value, new(JobRunStatus.Cancelled, -1, 0, 0, 0, 0, "Ustavil: F11 skrbnik."), owner, CancellationToken.None);
  Check((await JobAsync(A)).LastStatus == JobRunStatus.Cancelled, "Ustavljen zagon konča kot Cancelled.");

  // 7. Ročna zahteva in neveljaven urnik.
  await store.RequestRunAsync(A, "F11 skrbnik", CancellationToken.None);
  a = await JobAsync(A);
  Check(a.IsRequested && a.RequestedBy == "F11 skrbnik", "Zahteva za zagon je zapisana na poslu.");
  claimA = await store.ClaimAsync(A, DateTime.UtcNow.AddMinutes(1), owner, host, owner, null, force: false, CancellationToken.None);
  Check(claimA.Claimed && claimA.TriggeredBy == "Human", "Izklopljen posel z ročno zahtevo se prevzame kot Human.");
  await store.CompleteAsync(claimA.JobRunId!.Value, new(JobRunStatus.Succeeded, 0, 0, 0, 0, 0, "F11"), owner, CancellationToken.None);
  var rejected = false;
  try { await store.SaveScheduleAsync(A, true, 30, null, null, "F11", CancellationToken.None); }
  catch (SqlException exception) when (exception.Number == 52371) { rejected = true; }
  Check(rejected, "Razmik pod 60 s je zavrnjen.");

  var runs = await store.GetRunsAsync(50, null, null, 1);
  Check(runs.Count(r => r.JobKey is A or B) >= 6 && runs.All(r => JobRunStatus.IsFinal(r.EffectiveStatus) || r.Status == "Running"), "Zgodovina zagonov je popolna in vsak zagon ima končno stanje.");
  var steps = await store.GetStepsAsync(runs.First(r => r.JobKey == A && r.Summary == "F11 uspeh").JobRunId);
  Check(steps.Count == 1 && steps[0].Status == JobStepStatus.Succeeded, "Korak zagona je zapisan.");

  // 8. Faze znotraj koraka (migracija 255, blok 2 prenove nadzora).
  //
  // Zakaj tu in ne v logičnih testih: prav vez med workerjem in bazo je tisto, česar doslej ni bilo.
  // Preverja se pravilo, ki ga je zahteval uporabnik: »preskočeno« ne sme izpasti kot »uspelo«,
  // faza brez konca pa ne sme ostati večno odprta.
  var faze = PhaseLog.FromEnvironment(connectionString, "F11", _ => { });
  Check(faze.WritesToDatabase, "Pisec faz s povezavo mora pisati v bazo.");

  var uspesna = await faze.BeginAsync(PhaseCodes.Read, FazniVir, organizationId: 2, pipeline: "STOCK_FILE");
  await uspesna.SucceededAsync(itemsIn: 1389, itemsOut: 1389, hasNewData: true, message: "F11 uspeh");
  var vrstica = await RowAsync($"SELECT TOP 1 CONCAT(Status, N'|', CONVERT(int, HasNewData), N'|', ItemsOut, N'|', CASE WHEN EndedUtc IS NULL THEN N'odprta' ELSE N'zaprta' END, N'|', PhaseCode) FROM ops.JobPhaseRun WHERE SourceCode = N'{FazniVir}' AND PhaseCode = N'{PhaseCodes.Read}' ORDER BY JobPhaseRunId DESC");
  Check(vrstica == $"Succeeded|1|1389|zaprta|{PhaseCodes.Read}", "Uspešna faza z novimi podatki je zapisana s števili: " + vrstica);

  var preskocena = await faze.BeginAsync(PhaseCodes.Fetch, FazniVir, organizationId: 2, pipeline: "SOURCE_FETCH");
  await preskocena.SkippedAsync("dobavitelj dovoli prenos na 3 h");
  var preskok = await RowAsync($"SELECT TOP 1 CONCAT(Status, N'|', CONVERT(int, HasNewData), N'|', Message) FROM ops.JobPhaseRun WHERE SourceCode = N'{FazniVir}' AND PhaseCode = N'{PhaseCodes.Fetch}' ORDER BY JobPhaseRunId DESC");
  Check(preskok == "Skipped|0|dobavitelj dovoli prenos na 3 h", "Preskočena faza ne sme veljati za uspeh: " + preskok);

  // Faza, ki se ne konča sama (padec procesa sredi dela), mora obveljati za padlo.
  await using (await faze.BeginAsync(PhaseCodes.Map, FazniVir, organizationId: 2, pipeline: "STOCK_FILE")) { }
  var padla = await RowAsync($"SELECT TOP 1 CONCAT(Status, N'|', CASE WHEN EndedUtc IS NULL THEN N'odprta' ELSE N'zaprta' END) FROM ops.JobPhaseRun WHERE SourceCode = N'{FazniVir}' AND PhaseCode = N'{PhaseCodes.Map}' ORDER BY JobPhaseRunId DESC");
  Check(padla == "Failed|zaprta", "Nezaprta faza je padla faza: " + padla);

  // Neznan tek posla (ročni zagon workerja) ne sme podreti poročanja o fazah.
  Environment.SetEnvironmentVariable(PhaseLog.JobRunVariable, "999999999");
  try
  {
    var brezTeka = PhaseLog.FromEnvironment(connectionString, "F11", _ => { });
    Check(brezTeka.JobRunId == 999999999, "Tek posla se prebere iz okolja.");
    var sirota = await brezTeka.BeginAsync(PhaseCodes.Land, FazniVir, organizationId: 2, pipeline: "STOCK_FILE");
    await sirota.SucceededAsync(itemsOut: 0, hasNewData: false, message: "F11 brez teka");
    var brez = await CountAsync($"SELECT COUNT(*) FROM ops.JobPhaseRun WHERE SourceCode = N'{FazniVir}' AND PhaseCode = N'{PhaseCodes.Land}' AND JobRunId IS NULL AND Status = N'Succeeded' AND HasNewData = 0");
    Check(brez == 1, "Neznan tek posla se shrani kot prazen, faza pa ostane zapisana.");
  }
  finally { Environment.SetEnvironmentVariable(PhaseLog.JobRunVariable, null); }

  // Svežina vira: bere se zadnja faza z NOVIMI podatki, ne zadnji uspešen zagon.
  var svezina = await RowAsync($"SELECT TOP 1 CONCAT(CASE WHEN LastNewDataUtc IS NULL THEN N'brez' ELSE N'ima' END, N'|', CASE WHEN LastCheckedUtc IS NULL THEN N'brez' ELSE N'ima' END) FROM (SELECT LastNewDataUtc = MAX(CASE WHEN Status = N'Succeeded' AND HasNewData = 1 THEN COALESCE(EndedUtc, StartedUtc) END), LastCheckedUtc = MAX(COALESCE(EndedUtc, StartedUtc)) FROM ops.JobPhaseRun WHERE SourceCode = N'{FazniVir}' AND Pipeline = N'STOCK_FILE') s");
  Check(svezina == "ima|ima", "Svežina vira mora poznati zadnje nove podatke: " + svezina);
  var samoPreskok = await RowAsync($"SELECT TOP 1 CASE WHEN MAX(CASE WHEN Status = N'Succeeded' AND HasNewData = 1 THEN COALESCE(EndedUtc, StartedUtc) END) IS NULL THEN N'brez' ELSE N'ima' END FROM ops.JobPhaseRun WHERE SourceCode = N'{FazniVir}' AND Pipeline = N'SOURCE_FETCH'");
  Check(samoPreskok == "brez", "Vir, ki je bil samo preskočen, nima svežih podatkov: " + samoPreskok);

  // 9. Viri poslov in svežina (migracija 256): zastarel vir odpre SourceStale, sveži podatki ga zaprejo.
  // Svoj vir, da faze iz 8. točke ne štejejo kot sveži podatki.
  await ExecuteAsync($"""
    UPDATE ops.JobDefinition SET IsEnabled = 1, UpdatedBy = N'F11' WHERE JobKey = N'{A}';
    EXEC ops.EnsureJobSource N'{A}', N'{SveziVir}', N'STOCK_FILE', N'F11 vir', 600, 0, 1, 1, N'F11';
    UPDATE ops.JobSource SET CreatedUtc = DATEADD(hour, -2, SYSUTCDATETIME()) WHERE JobKey = N'{A}' AND SourceCode = N'{SveziVir}';
    """);
  var stanje = await RowAsync($"SELECT State FROM ops.JobSourceState() WHERE JobKey = N'{A}' AND SourceCode = N'{SveziVir}'");
  Check(stanje == "Stale", "Vir brez podatkov, star dlje od meje, je zastarel: " + stanje);
  await store.EvaluateAlertsAsync("F11", CancellationToken.None);
  Check(await CountAsync($"SELECT COUNT(*) FROM ops.Alert WHERE AlertKind = N'SourceStale' AND Pipeline = N'OPRAVILO:{A}' AND ResolvedUtc IS NULL") == 1,
    "Zastarel vir odpre alarm SourceStale.");

  var svezi = await faze.BeginAsync(PhaseCodes.Land, SveziVir, organizationId: 2, pipeline: "STOCK_FILE");
  await svezi.SucceededAsync(itemsOut: 5, hasNewData: true, message: "F11 sveži podatki");
  stanje = await RowAsync($"SELECT State FROM ops.JobSourceState() WHERE JobKey = N'{A}' AND SourceCode = N'{SveziVir}'");
  Check(stanje == "Fresh", "Faza z novimi podatki naredi vir svež: " + stanje);
  await store.EvaluateAlertsAsync("F11", CancellationToken.None);
  Check(await CountAsync($"SELECT COUNT(*) FROM ops.Alert WHERE AlertKind = N'SourceStale' AND Pipeline = N'OPRAVILO:{A}' AND ResolvedUtc IS NULL") == 0,
    "Sveži podatki zaprejo alarm SourceStale.");

  var padec = await faze.BeginAsync(PhaseCodes.Land, SveziVir, organizationId: 2, pipeline: "STOCK_FILE");
  await padec.FailedAsync("F11 namerni padec");
  stanje = await RowAsync($"SELECT State FROM ops.JobSourceState() WHERE JobKey = N'{A}' AND SourceCode = N'{SveziVir}'");
  Check(stanje == "Failed", "Padla faza za zadnjim uspehom pomeni Failed: " + stanje);

  // Vir, ki ga koda ne našteje več, se izklopi in ne šteje več.
  await ExecuteAsync($"EXEC ops.RetireJobSources N'{A}', N'', N'F11'");
  Check(await CountAsync($"SELECT COUNT(*) FROM ops.JobSourceState() WHERE JobKey = N'{A}'") == 0, "Izklopljen vir izgine iz stanja.");

  Console.WriteLine("F11 avtomatizacija (enotni model opravil) PASS.");
  return 0;
}
finally
{
  await CleanupAsync();
}

async Task<JobDefinitionRow> JobAsync(string key) => (await store.GetDefinitionsAsync()).Jobs.Single(job => job.JobKey == key);

async Task CleanupAsync()
{
  await ExecuteAsync($"""
    DELETE FROM ops.JobStepRun WHERE JobRunId IN (SELECT JobRunId FROM ops.JobRun WHERE JobKey IN (N'{A}', N'{B}'));
    DELETE FROM ops.JobRun WHERE JobKey IN (N'{A}', N'{B}');
    DELETE FROM ops.JobDependency WHERE JobKey IN (N'{A}', N'{B}') OR DependsOnJobKey IN (N'{A}', N'{B}');
    DELETE FROM ops.DataCheckpoint WHERE JobKey IN (N'{A}', N'{B}');
    DELETE FROM ops.Artifact WHERE JobKey IN (N'{A}', N'{B}');
    DELETE FROM ops.Alert WHERE Pipeline IN (N'OPRAVILO:{A}', N'OPRAVILO:{B}');
    DELETE FROM ops.JobSource WHERE JobKey IN (N'{A}', N'{B}');
    DELETE FROM ops.JobDefinition WHERE JobKey IN (N'{A}', N'{B}');
    DELETE FROM ops.JobPhaseRun WHERE SourceCode IN (N'{FazniVir}', N'{SveziVir}');
    """);
}

async Task ExecuteAsync(string sql)
{
  await using var connection = new SqlConnection(connectionString);
  await connection.OpenAsync();
  await using var command = new SqlCommand(sql, connection);
  await command.ExecuteNonQueryAsync();
}

async Task<string?> RowAsync(string sql)
{
  await using var connection = new SqlConnection(connectionString);
  await connection.OpenAsync();
  await using var command = new SqlCommand(sql, connection);
  return await command.ExecuteScalarAsync() as string;
}

async Task<long> CountAsync(string sql)
{
  await using var connection = new SqlConnection(connectionString);
  await connection.OpenAsync();
  await using var command = new SqlCommand(sql, connection);
  return Convert.ToInt64(await command.ExecuteScalarAsync());
}

static void Check(bool condition, string message)
{
  if (condition) return;
  Console.Error.WriteLine("NAPAKA: " + message);
  Environment.Exit(1);
}
