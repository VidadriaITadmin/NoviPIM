using System.Diagnostics;
using System.Globalization;
using System.Text;
using Microsoft.Data.SqlClient;

// Nočni samotest celote.
//
// Zakaj obstaja
// -------------
// Vsak kos sistema ima svoj zeleni test, celota nima nobenega. Zato se na vprašanje "ali PIM
// zdaj deluje" ni dalo odgovoriti drugače kot z odpiranjem šestih strani in ugibanjem. Ta test
// enkrat na noč prehodi celotno verigo — vhod, katalog, kakovost, izhodna datoteka, odhodna
// vrsta in nadzor — in vsakemu koraku IZMERI ČAS. Brez trajanj ni odgovora na "kako hitro
// deluje" in podvojitev iz treh sekund v tri minute ostane nevidna, dokler nekaj ne odpove.
//
// Kaj ta test namenoma NI
// -----------------------
// Ni nadomestek za scripts\run_tests.ps1. Tisti dokazuje, da je koda pravilna; ta dokazuje, da
// nameščen sistem trenutno dela. Ne kliče SAOP-a, ne pošilja ničesar navzven in ne spreminja
// podatkov — edini zapis je njegov lastni rezultat v ops.SelfTestRun, edina datoteka pa začasni
// CSV, ki ga na koncu pobriše. Zato se sme izvajati tudi v produkciji.
//
// Kaj pomenijo izidi
// ------------------
//   Passed   korak je dokazal, kar je trdil
//   Warning  stanje ni napačno, je pa vredno pogledati (mrtva sporočila, karantena)
//   Failed   sistem tega dela ne opravlja
//   Skipped  koraka ni bilo mogoče izvesti in to ni dokaz ničesar

var connectionString = Environment.GetEnvironmentVariable("PIM_CONNECTION_STRING");
if (string.IsNullOrWhiteSpace(connectionString))
{
  Console.Error.WriteLine("Manjka PIM_CONNECTION_STRING.");
  return 2;
}

var testCode = Environment.GetEnvironmentVariable("PIM_SELFTEST_CODE") ?? "NIGHTLY_SYSTEM";
var triggeredBy = Environment.GetEnvironmentVariable("PIM_TRIGGERED_BY") ?? "Human";
var exportProfile = Environment.GetEnvironmentVariable("PIM_SELFTEST_PROFILE") ?? "MAGENTO_STOCK_PRICES";
var exportOrganization = int.TryParse(Environment.GetEnvironmentVariable("PIM_SELFTEST_ORG"), out var org) ? org : 2;

await using var connection = new SqlConnection(connectionString);
try
{
  await connection.OpenAsync();
}
catch (SqlException exception)
{
  // Brez baze ni ne testa ne mesta, kamor bi se rezultat zapisal. To je edini izhod brez sledi.
  Console.Error.WriteLine($"Povezava z bazo ni uspela: {exception.Message}");
  return 2;
}

var runKey = await BeginAsync(connection, testCode, triggeredBy);
var koraki = new List<(string Code, string Status, long Ms, string Detail)>();
var ordinal = 0;

Console.WriteLine($"Samotest {testCode} ({runKey})");
Console.WriteLine(new string('─', 78));

// ── 1. Baza je dosegljiva in shema je uporabljena ─────────────────────────────
await StepAsync("DB", "Baza je dosegljiva in migracije so uporabljene", async () =>
{
  var migracij = await ScalarLongAsync(connection, "SELECT COUNT_BIG(*) FROM dbo.SchemaMigration;");
  return migracij > 0
    ? Ok($"{migracij} uporabljenih migracij", migracij, "migracij")
    : Fail("V dbo.SchemaMigration ni nobene vrstice: to ni baza PIM.");
});

// ── 2. Ključni objekti obstajajo ──────────────────────────────────────────────
await StepAsync("SCHEMA", "Ključne procedure obstajajo", async () =>
{
  string[] zahtevani =
  [
    "ops.BeginRun", "ops.CompleteRun", "ops.RunWatchdog", "out.GetExportRows",
    "intranet.GetAdminPulse", "intranet.GetUserActivityTrail", "intranet.GetSchedules",
  ];

  var manjkajo = new List<string>();
  foreach (var ime in zahtevani)
    if (await ScalarLongAsync(connection, "SELECT COUNT_BIG(*) FROM sys.objects WHERE object_id = OBJECT_ID(@Ime);",
          ("@Ime", ime)) == 0)
      manjkajo.Add(ime);

  return manjkajo.Count == 0
    ? Ok($"{zahtevani.Length} objektov je na mestu", zahtevani.Length, "objektov")
    : Fail($"Manjka: {string.Join(", ", manjkajo)}");
});

// ── 3. Kaj sme sploh teči ─────────────────────────────────────────────────────
await StepAsync("SCHEDULES", "Razporedi so vklopljeni", async () =>
{
  var vklopljenih = await ScalarLongAsync(connection, "SELECT COUNT_BIG(*) FROM ops.ScheduleProfile WHERE IsEnabled = 1;");
  var vseh = await ScalarLongAsync(connection, "SELECT COUNT_BIG(*) FROM ops.ScheduleProfile;");

  // Nič vklopljenih ni tiho stanje mirovanja, ampak sistem, ki se nikoli ne bo zagnal sam.
  return vklopljenih == 0
    ? Fail($"Noben od {vseh} razporedov ni vklopljen; nič se ne bo izvedlo samo od sebe.")
    : Ok($"{vklopljenih} od {vseh} vklopljenih", vklopljenih, "razporedov");
});

// ── 4. Ali se postopki oglašajo ───────────────────────────────────────────────
await StepAsync("HEARTBEAT", "Vklopljeni postopki imajo svež srčni utrip", async () =>
{
  var molcijo = await ListAsync(connection, """
    SELECT CONCAT(razpored.Pipeline, N' (org ', razpored.OrganizationId, N')') AS Opis
      FROM ops.ScheduleProfile razpored
      LEFT JOIN ops.IntegrationHealth zdravje
             ON zdravje.OrganizationId = razpored.OrganizationId AND zdravje.Pipeline = razpored.Pipeline
     WHERE razpored.IsEnabled = 1
       AND (zdravje.LastHeartbeatUtc IS NULL
            OR DATEDIFF(second, zdravje.LastHeartbeatUtc, SYSUTCDATETIME()) > razpored.StaleAfterSeconds)
     ORDER BY razpored.Pipeline, razpored.OrganizationId;
    """);

  return molcijo.Count == 0
    ? Ok("noben vklopljen postopek ne molči", 0, "molči")
    : Fail($"Molčijo: {Skrajsaj(string.Join(", ", molcijo))}", molcijo.Count, "molči");
});

// ── 5. Ali so se postopki v zadnjem dnevu sploh izvedli ───────────────────────
await StepAsync("RUNS_24H", "Vsak vklopljen postopek je v 24 h vsaj enkrat tekel", async () =>
{
  var brezTeka = await ListAsync(connection, """
    SELECT CONCAT(razpored.Pipeline, N' (org ', razpored.OrganizationId, N')') AS Opis
      FROM ops.ScheduleProfile razpored
     WHERE razpored.IsEnabled = 1
       AND NOT EXISTS (SELECT 1 FROM ops.PipelineRun tek
                        WHERE tek.OrganizationId = razpored.OrganizationId
                          AND tek.Pipeline = razpored.Pipeline
                          AND tek.StartedUtc >= DATEADD(hour, -24, SYSUTCDATETIME()))
     ORDER BY razpored.Pipeline, razpored.OrganizationId;
    """);

  var tekov = await ScalarLongAsync(connection,
    "SELECT COUNT_BIG(*) FROM ops.PipelineRun WHERE StartedUtc >= DATEADD(hour, -24, SYSUTCDATETIME());");

  return brezTeka.Count == 0
    ? Ok($"{tekov} zagonov v 24 h", tekov, "zagonov")
    : Fail($"Brez zagona v 24 h: {Skrajsaj(string.Join(", ", brezTeka))}", brezTeka.Count, "postopkov");
});

// ── 6. Katalog ni izginil ─────────────────────────────────────────────────────
await StepAsync("CATALOG", "Katalog ima pričakovan obseg", async () =>
{
  var izdelkov = await ScalarLongAsync(connection, "SELECT COUNT_BIG(*) FROM canon.Product;");
  if (izdelkov == 0) return Fail("V canon.Product ni nobenega izdelka.");

  // Prejšnji zagon je edino merilo, ki ga ni treba vzdrževati na roke. Padec kataloga za več
  // kot desetino čez noč je vedno napaka, tudi kadar vsak posamezni postopek poroča uspeh.
  var prej = await ScalarNullableDecimalAsync(connection, """
    SELECT TOP (1) korak.Measure
      FROM ops.SelfTestStep korak
      JOIN ops.SelfTestRun test ON test.SelfTestRunId = korak.SelfTestRunId
     WHERE korak.StepCode = N'CATALOG' AND korak.Measure IS NOT NULL AND test.RunKey <> @RunKey
     ORDER BY test.StartedUtc DESC;
    """, ("@RunKey", runKey));

  if (prej is null) return Ok($"{izdelkov:N0} izdelkov (prvi zagon, ni primerjave)", izdelkov, "izdelkov");

  var razlika = (decimal)izdelkov - prej.Value;
  var delez = prej.Value == 0 ? 0 : razlika / prej.Value * 100m;

  return delez < -10m
    ? Fail($"Katalog je padel z {prej.Value:N0} na {izdelkov:N0} ({delez:0.#} %).", izdelkov, "izdelkov")
    : Ok($"{izdelkov:N0} izdelkov ({(razlika >= 0 ? "+" : "")}{razlika:N0} od prejšnjega zagona)", izdelkov, "izdelkov");
});

// ── 7. Svežina zaloge po viru ─────────────────────────────────────────────────
await StepAsync("STOCK_FRESHNESS", "Zaloga je sveža po vsakem viru posebej", async () =>
{
  // Zelen postopek ni dokaz svežih podatkov. STOCK_FILE je lahko zelen, ker mu datoteka
  // priteče po javnem internetu, medtem ko SAOP_STOCK pada, ker do ERP ni povezave — takrat
  // je pol zaloge sveže, pol pa nekaj dni stare, na spletu pa je videti kot ena zaloga.
  var zastareli = await ListAsync(connection, """
    SELECT CONCAT(vir.Source, N' (org ', vir.OrganizationId, N'): ',
                  DATEDIFF(hour, vir.NewestSnapshotUtc, SYSUTCDATETIME()), N' h') AS Opis
      FROM (
        SELECT CASE WHEN posnetek.Endpoint LIKE '/iCenterAPI%' OR posnetek.Endpoint LIKE 'api/registeredviews%'
                      THEN N'SAOP' ELSE N'datoteka' END AS Source,
               posnetek.OrganizationId,
               MAX(posnetek.SnapshotUtc) AS NewestSnapshotUtc
          FROM stock.Snapshot posnetek
         WHERE posnetek.IsActive = 1
         GROUP BY CASE WHEN posnetek.Endpoint LIKE '/iCenterAPI%' OR posnetek.Endpoint LIKE 'api/registeredviews%'
                         THEN N'SAOP' ELSE N'datoteka' END, posnetek.OrganizationId
      ) vir
     WHERE DATEDIFF(hour, vir.NewestSnapshotUtc, SYSUTCDATETIME()) >= 24
     ORDER BY vir.Source, vir.OrganizationId;
    """);

  var najstarejsi = await ScalarNullableLongAsync(connection, """
    SELECT MAX(DATEDIFF(hour, x.NewestSnapshotUtc, SYSUTCDATETIME()))
      FROM (SELECT MAX(SnapshotUtc) AS NewestSnapshotUtc FROM stock.Snapshot
             WHERE IsActive = 1 GROUP BY OrganizationId, Endpoint) x;
    """);

  return zastareli.Count == 0
    ? Ok($"vsi viri mlajši od 24 h (najstarejši {najstarejsi ?? 0} h)", najstarejsi ?? 0, "h")
    : Fail($"Zastarela zaloga: {Skrajsaj(string.Join(", ", zastareli))}", najstarejsi ?? 0, "h");
});

// ── 8. Karantena ──────────────────────────────────────────────────────────────
await StepAsync("QUARANTINE", "Vhodni zapisi niso obtičali v karanteni", async () =>
{
  var karantena = await ScalarLongAsync(connection, "SELECT COUNT_BIG(*) FROM raw.Inbox WHERE Status = N'Quarantined';");
  return karantena == 0
    ? Ok("karantena je prazna", 0, "zapisov")
    : Warn($"{karantena:N0} zapisov čaka v karanteni.", karantena, "zapisov");
});

// ── 8. Kakovost ───────────────────────────────────────────────────────────────
await StepAsync("QUALITY", "Objavljeni izdelki nimajo odprtih blokad", async () =>
{
  // EXISTS namesto COUNT(DISTINCT ...) z JOIN: izmerjeno 17 s namesto 59 s pri 196.559
  // izdelkih. Tudi 17 s je veliko — to je cena pregleda celotnega kataloga in je hkrati
  // koristen podatek: trajanje tega koraka pove, kdaj bo katalog prerasel svoje indekse.
  var blokiranih = await ScalarLongAsync(connection, """
    SELECT COUNT_BIG(*)
      FROM canon.Product izdelek
     WHERE izdelek.WebPublish = 1 AND izdelek.IsActive = 1
       AND EXISTS (SELECT 1 FROM val.ProductIssue tezava WHERE tezava.ProductId = izdelek.ProductId);
    """);

  return blokiranih == 0
    ? Ok("noben objavljen izdelek nima odprte zahteve", 0, "izdelkov")
    : Warn($"{blokiranih:N0} objavljenih izdelkov ima odprto zahtevo.", blokiranih, "izdelkov");
});

// ── 9. Izhodna datoteka nastane — pravi dokaz izhoda ──────────────────────────
await StepAsync("WEB_CSV", $"Spletni CSV za {exportProfile} dejansko nastane", async () =>
{
  var profileId = await ScalarNullableLongAsync(connection,
    "SELECT ExportProfileId FROM out.ExportProfile WHERE ProfileCode = @Koda AND IsActive = 1;",
    ("@Koda", exportProfile));

  if (profileId is null) return Skip($"Profil {exportProfile} ne obstaja ali ni aktiven.");

  var pot = Path.Combine(Path.GetTempPath(), $"pim-samotest-{Guid.NewGuid():N}.csv");
  try
  {
    long vrstic = 0;
    int stolpcev;

    await using (var command = new SqlCommand("out.GetExportRows", connection)
                 { CommandType = System.Data.CommandType.StoredProcedure, CommandTimeout = 600 })
    {
      command.Parameters.AddWithValue("@OrganizationId", exportOrganization);
      command.Parameters.AddWithValue("@ExportProfileId", (int)profileId.Value);
      command.Parameters.AddWithValue("@WebSite", DBNull.Value);
      command.Parameters.AddWithValue("@OnlyPublished", true);
      command.Parameters.AddWithValue("@Search", DBNull.Value);
      command.Parameters.AddWithValue("@Skip", 0);
      command.Parameters.AddWithValue("@Take", 0);
      command.Parameters.Add("@TotalCount", System.Data.SqlDbType.Int).Direction = System.Data.ParameterDirection.Output;

      await using var reader = await command.ExecuteReaderAsync(System.Data.CommandBehavior.SequentialAccess);
      stolpcev = reader.FieldCount;
      if (stolpcev == 0) return Fail("Izvoz je vrnil nič stolpcev; register profila je prazen.");

      await using var writer = new StreamWriter(pot, false, new UTF8Encoding(true));
      await writer.WriteLineAsync(string.Join(';', Enumerable.Range(0, stolpcev).Select(i => Escape(reader.GetName(i)))));

      while (await reader.ReadAsync())
      {
        var celice = new string[stolpcev];
        for (var i = 0; i < stolpcev; i++)
          celice[i] = Escape(reader.IsDBNull(i) ? null : Convert.ToString(reader.GetValue(i), CultureInfo.InvariantCulture));
        await writer.WriteLineAsync(string.Join(';', celice));
        vrstic++;
      }
    }

    if (vrstic == 0) return Fail($"Izvoz {exportProfile} za podjetje {exportOrganization} je vrnil nič vrstic.");

    var velikost = new FileInfo(pot).Length;
    return Ok($"{vrstic:N0} vrstic × {stolpcev} stolpcev, {velikost / 1024:N0} kB", vrstic, "vrstic");
  }
  finally
  {
    // Samotest za sabo ne pušča datotek; edini smisel te je bil dokazati, da nastane.
    if (File.Exists(pot)) File.Delete(pot);
  }
});

// ── 10. Odhodna vrsta ─────────────────────────────────────────────────────────
await StepAsync("OUTBOX", "Odhodna vrsta ni zamašena", async () =>
{
  var mrtvih = await ScalarLongAsync(connection, "SELECT COUNT_BIG(*) FROM out.OutboxMessage WHERE Status = N'Dead';");
  var caka = await ScalarLongAsync(connection, "SELECT COUNT_BIG(*) FROM out.OutboxMessage WHERE Status = N'PendingApproval';");

  return mrtvih == 0
    ? Ok($"{caka:N0} čaka odobritve, nič mrtvih", caka, "čaka")
    : Warn($"{mrtvih:N0} mrtvih sporočil, {caka:N0} čaka odobritve.", mrtvih, "mrtvih");
});

// ── 11. Potrditev zapisanega v ERP ────────────────────────────────────────────
await StepAsync("ECHO", "Poslane spremembe se ujemajo z ERP", async () =>
{
  var odkloni = await ScalarLongAsync(connection,
    "SELECT COUNT_BIG(*) FROM out.OutboxMessage WHERE DriftDetail IS NOT NULL AND Status <> N'Verified';");

  return odkloni == 0
    ? Ok("ni nepojasnjenih odklonov", 0, "odklonov")
    : Warn($"{odkloni:N0} sporočil ima odklon med poslanim in prebranim.", odkloni, "odklonov");
});

// ── 12. Svežina izvozov ───────────────────────────────────────────────────────
await StepAsync("EXPORT_FRESHNESS", "Izvozi so tekli v zadnjem dnevu", async () =>
{
  var vseh = await ScalarLongAsync(connection, "SELECT COUNT_BIG(*) FROM out.ExportRun;");
  if (vseh == 0) return Skip("Zgodovina izvozov je prazna; polni se od migracije 172 naprej.");

  var svezih = await ScalarLongAsync(connection, """
    SELECT COUNT_BIG(*) FROM out.ExportRun
     WHERE Status = N'Succeeded' AND StartedUtc >= DATEADD(hour, -24, SYSUTCDATETIME());
    """);

  return svezih > 0
    ? Ok($"{svezih:N0} uspešnih izvozov v 24 h", svezih, "izvozov")
    : Fail("V zadnjih 24 urah ni bilo nobenega uspešnega izvoza.");
});

// ── Zaključek ─────────────────────────────────────────────────────────────────
var padlih = koraki.Count(k => k.Status == "Failed");
var opozoril = koraki.Count(k => k.Status == "Warning");
var skupaj = koraki.Sum(k => k.Ms);

await CompleteAsync(connection, runKey,
  $"{koraki.Count - padlih - opozoril} uspešnih, {opozoril} z opozorilom, {padlih} padlih; skupaj {skupaj} ms.");

Console.WriteLine(new string('─', 78));
Console.WriteLine($"REZULTAT: {(padlih > 0 ? "PADEL" : opozoril > 0 ? "Z OPOZORILI" : "USPEL")} — {koraki.Count} korakov, {skupaj} ms");

// Opozorilo ni napaka: nočno opravilo ne sme vsako jutro javljati okvare zaradi karantene.
return padlih > 0 ? 1 : 0;

// ── Ogrodje ───────────────────────────────────────────────────────────────────

async Task StepAsync(string code, string label, Func<Task<(string Status, string Detail, decimal? Measure, string? Unit)>> body)
{
  ordinal++;
  var ura = Stopwatch.StartNew();
  string status, detail;
  decimal? measure = null;
  string? unit = null;

  try
  {
    (status, detail, measure, unit) = await body();
  }
  catch (Exception exception)
  {
    // Izjema v koraku ne sme podreti celotnega testa: preostali koraki so še vedno dokaz.
    status = "Failed";
    detail = $"{exception.GetType().Name}: {Skrajsaj(exception.Message, 300)}";
  }

  ura.Stop();
  var ms = ura.ElapsedMilliseconds;
  koraki.Add((code, status, ms, detail));
  await RecordAsync(connection, runKey, ordinal, code, label, status, (int)Math.Min(ms, int.MaxValue), measure, unit, detail);
  Console.WriteLine($"{code,-18} {Oznaka(status),-12} {ms,7} ms  {detail}");
}

static (string, string, decimal?, string?) Ok(string detail, decimal? measure = null, string? unit = null) => ("Passed", detail, measure, unit);
static (string, string, decimal?, string?) Warn(string detail, decimal? measure = null, string? unit = null) => ("Warning", detail, measure, unit);
static (string, string, decimal?, string?) Fail(string detail, decimal? measure = null, string? unit = null) => ("Failed", detail, measure, unit);
static (string, string, decimal?, string?) Skip(string detail) => ("Skipped", detail, null, null);

static string Oznaka(string status) => status switch
{
  "Passed" => "USPEL", "Warning" => "OPOZORILO", "Failed" => "PADEL", _ => "PRESKOČEN",
};

static string Skrajsaj(string value, int length = 400)
  => value.Length <= length ? value : value[..length] + " …";

static string Escape(string? value)
{
  if (string.IsNullOrEmpty(value)) return "";
  var potrebuje = value.Contains('"') || value.Contains(';') || value.Contains('\n') || value.Contains('\r');
  var ocisceno = value.Replace("\"", "\"\"");
  return potrebuje ? $"\"{ocisceno}\"" : ocisceno;
}

static async Task<Guid> BeginAsync(SqlConnection connection, string testCode, string triggeredBy)
{
  await using var command = new SqlCommand("ops.BeginSelfTest", connection) { CommandType = System.Data.CommandType.StoredProcedure };
  command.Parameters.AddWithValue("@TestCode", testCode);
  command.Parameters.AddWithValue("@TriggeredBy", triggeredBy);
  var key = command.Parameters.Add("@RunKey", System.Data.SqlDbType.UniqueIdentifier);
  key.Direction = System.Data.ParameterDirection.Output;
  await command.ExecuteNonQueryAsync();
  return (Guid)key.Value;
}

static async Task RecordAsync(SqlConnection connection, Guid runKey, int ordinal, string code, string label,
  string status, int durationMs, decimal? measure, string? unit, string detail)
{
  await using var command = new SqlCommand("ops.RecordSelfTestStep", connection) { CommandType = System.Data.CommandType.StoredProcedure };
  command.Parameters.AddWithValue("@RunKey", runKey);
  command.Parameters.AddWithValue("@Ordinal", ordinal);
  command.Parameters.AddWithValue("@StepCode", code);
  command.Parameters.AddWithValue("@Label", label);
  command.Parameters.AddWithValue("@Status", status);
  command.Parameters.AddWithValue("@DurationMs", durationMs);
  command.Parameters.AddWithValue("@Measure", measure is null ? DBNull.Value : measure.Value);
  command.Parameters.AddWithValue("@MeasureUnit", unit is null ? DBNull.Value : unit);
  command.Parameters.AddWithValue("@DetailRedacted", Skrajsaj(detail, 1000));
  await command.ExecuteNonQueryAsync();
}

static async Task CompleteAsync(SqlConnection connection, Guid runKey, string detail)
{
  await using var command = new SqlCommand("ops.CompleteSelfTest", connection) { CommandType = System.Data.CommandType.StoredProcedure };
  command.Parameters.AddWithValue("@RunKey", runKey);
  command.Parameters.AddWithValue("@DetailRedacted", Skrajsaj(detail, 2000));
  await command.ExecuteNonQueryAsync();
}

static async Task<long> ScalarLongAsync(SqlConnection connection, string sql, params (string Name, object Value)[] parameters)
  => await ScalarNullableLongAsync(connection, sql, parameters) ?? 0;

static async Task<long?> ScalarNullableLongAsync(SqlConnection connection, string sql, params (string Name, object Value)[] parameters)
{
  await using var command = new SqlCommand(sql, connection) { CommandTimeout = 300 };
  foreach (var (name, value) in parameters) command.Parameters.AddWithValue(name, value);
  var result = await command.ExecuteScalarAsync();
  return result is null or DBNull ? null : Convert.ToInt64(result);
}

static async Task<decimal?> ScalarNullableDecimalAsync(SqlConnection connection, string sql, params (string Name, object Value)[] parameters)
{
  await using var command = new SqlCommand(sql, connection) { CommandTimeout = 300 };
  foreach (var (name, value) in parameters) command.Parameters.AddWithValue(name, value);
  var result = await command.ExecuteScalarAsync();
  return result is null or DBNull ? null : Convert.ToDecimal(result);
}

static async Task<List<string>> ListAsync(SqlConnection connection, string sql, params (string Name, object Value)[] parameters)
{
  await using var command = new SqlCommand(sql, connection) { CommandTimeout = 300 };
  foreach (var (name, value) in parameters) command.Parameters.AddWithValue(name, value);
  await using var reader = await command.ExecuteReaderAsync();
  var rows = new List<string>();
  while (await reader.ReadAsync()) rows.Add(reader.GetString(0));
  return rows;
}
