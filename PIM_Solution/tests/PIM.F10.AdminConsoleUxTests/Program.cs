using Microsoft.Data.SqlClient;

// Pogodbeni test skrbniške konzole (/sistem in podstrani, migracija 172).
//
// Kaj ta pogodba varuje:
//
//   1. Konzola odgovori na "ali kaj ne dela" PREJ, kot je treba karkoli klikniti. Zato je
//      seznam stvari za pozornost prvi razdelek in ima svoje prazno stanje — razlika med
//      "nič ni narobe" in "podatka ni" mora biti vidna.
//   2. Vsi časi so v naši uri prek PimTime. ToLocalTime() je prepovedan povsod v intranetu:
//      vrne čas STREŽNIKA, kar je na razvojnem računalniku slučajno pravilno, na IIS strežniku
//      v UTC pa dve uri narobe — in to se pokaže šele po objavi.
//   3. Obvestila so skrbnikova. Zvonec, ki ga vidi vsakdo, a vodi na stran samo za ADMIN, ni
//      obvestilo, ampak slepa ulica.
//   4. Nočni samotest ne sme teči v regresijskem zagonu: pade, kadar delavec molči ali je SAOP
//      nedosegljiv, in to sta operativni stanji, ne napaki v kodi.

var root = FindRoot();
var pages = Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages");
var services = Path.Combine(root, "src", "PIM.Intranet", "Services");

// ── 1. Strani obstajajo in so skrbniške ──────────────────────────────────────
var console = Read(Path.Combine(pages, "System.razor"));
var consoleCss = Path.Combine(pages, "System.razor.css");
Assert(File.Exists(consoleCss), "Manjka izoliran slog nadzorne plošče: " + consoleCss);

foreach (var (file, route) in new[]
{
  ("System.razor", "/sistem"),
  ("AdminActivity.razor", "/sistem/sled"),
  ("AdminExports.razor", "/sistem/izvozi"),
  ("AdminPerformance.razor", "/sistem/zmogljivost"),
  ("AdminSelfTest.razor", "/sistem/samotest"),
  ("SystemWorkers.razor", "/sistem/workerji"),
})
{
  var markup = Read(Path.Combine(pages, file));
  Assert(markup.Contains($"@page \"{route}\"", StringComparison.Ordinal), $"{file} mora biti na poti {route}.");
  Assert(markup.Contains("[Authorize(Roles = \"ADMIN\")]", StringComparison.Ordinal),
    $"{file} mora biti dostopna samo vlogi ADMIN.");
  Assert(markup.Contains("PimTime.", StringComparison.Ordinal), $"{file} mora čas kazati prek PimTime.");

  // UX pravilo te aplikacije: vsaka stran ima svoj izoliran slog in ne dopisuje v app.css.
  var css = Path.Combine(pages, Path.GetFileNameWithoutExtension(file) + ".razor.css");
  Assert(File.Exists(css), "Manjka izoliran slog: " + css);
  Assert(!File.ReadAllText(css).Contains("::deep", StringComparison.Ordinal),
    "Izoliran slog ne sme uhajati z ::deep: " + css);
}

// ── 2. Konzola pove, kaj je narobe, in ponudi krmiljenje ─────────────────────
foreach (var pogodba in new[]
{
  "Potrebuje pozornost",     // seznam težav
  "Vse teče",                // prazno stanje istega seznama
  "attention-list",
  "GetPulseAsync",           // podatek iz baze, ne iz ocene
  "MarkAlertsSeenAsync",     // odprtje konzole umiri zvonec
  "SaveScheduleAsync",       // vklop/izklop in razmik sta tu
  "LogActivityAsync",        // sprememba urnika pusti sled
  "Samodejno vsako minuto",
  "sistem/izvozi", "sistem/zmogljivost", "sistem/samotest",
})
  Assert(console.Contains(pogodba, StringComparison.Ordinal), "Nadzorna plošča nima pogodbe: " + pogodba);

Assert(console.Contains("Izklopi", StringComparison.Ordinal) && console.Contains("Vklopi", StringComparison.Ordinal),
  "Skrbnik mora postopek vklopiti in izklopiti s konzole.");
Assert(console.Contains("Shrani razmik", StringComparison.Ordinal),
  "Skrbnik mora s konzole spremeniti razmik izvajanja.");

// Katalog (zdaj zavihek Zaloga) in izvozi (poln pregled je zavihek Izvozi, tu samo kljucna
// stevilka s povezavo) morata biti dosegljiva iz konzole.
Assert(console.Contains("Artikli po podjetjih", StringComparison.Ordinal), "Konzola mora pokazati pregled artiklov.");
Assert(console.Contains("Href=\"sistem/izvozi\"", StringComparison.Ordinal), "Pregled mora povezati na poln seznam zagonov izvozov.");

// ── 3. Naša ura, nikjer čas strežnika ────────────────────────────────────────
var timeService = Read(Path.Combine(services, "PimTime.cs"));
Assert(timeService.Contains("Central European Standard Time", StringComparison.Ordinal),
  "PimTime mora imeti izrecen časovni pas, ne podedovanega od strežnika.");
Assert(timeService.Contains("ToPimLocal", StringComparison.Ordinal),
  "PimTime mora ponuditi razširitev ToPimLocal, sicer zamenjava na obstoječih straneh ni mehanska.");

var uporabnikiUre = new List<string>();
foreach (var file in Directory.EnumerateFiles(Path.Combine(root, "src", "PIM.Intranet"), "*.*", SearchOption.AllDirectories))
{
  if (!file.EndsWith(".razor", StringComparison.OrdinalIgnoreCase) && !file.EndsWith(".cs", StringComparison.OrdinalIgnoreCase)) continue;
  if (file.Contains($"{Path.DirectorySeparatorChar}bin{Path.DirectorySeparatorChar}", StringComparison.Ordinal)) continue;
  if (file.Contains($"{Path.DirectorySeparatorChar}obj{Path.DirectorySeparatorChar}", StringComparison.Ordinal)) continue;
  if (Path.GetFileName(file) is "PimTime.cs") continue;

  // Iščemo klic, ne omembe: razlaga v komentarju, zakaj ToLocalTime() ni pravi odgovor,
  // je koristna in ne sme podreti testa.
  if (File.ReadAllText(file).Contains(".ToLocalTime()", StringComparison.Ordinal))
    uporabnikiUre.Add(Path.GetFileName(file));
}

Assert(uporabnikiUre.Count == 0,
  "Čas strežnika (.ToLocalTime()) ni dovoljen; uporabi PimTime oziroma .ToPimLocal(). Kršitve: "
  + string.Join(", ", uporabnikiUre));

// ── 4. Zvonec je skrbnikov ───────────────────────────────────────────────────
var layout = Read(Path.Combine(root, "src", "PIM.Intranet", "Components", "Layout", "MainLayout.razor"));
Assert(layout.Contains("if (IsAdmin)", StringComparison.Ordinal),
  "Zvonec mora biti viden samo vlogi ADMIN; sicer vodi na stran, ki je uporabnik ne sme odpreti.");
Assert(layout.Contains("GetAttentionAsync", StringComparison.Ordinal),
  "Števec zvonca mora šteti molčeče postopke in alarme, ne samo alarmov izbranega podjetja.");
Assert(layout.Contains("sistem/integracije", StringComparison.Ordinal), "Zvonec mora voditi na pregled alarmov.");

// ── 5. Samotest in njegov razpored ───────────────────────────────────────────
var repositoryRoot = Path.GetDirectoryName(root)!;
var selfTest = Path.Combine(root, "tests", "PIM.SelfTest.Nightly", "Program.cs");
Assert(File.Exists(selfTest), "Manjka nočni samotest: " + selfTest);

var selfTestBody = Read(selfTest);
foreach (var korak in new[] { "DB", "SCHEMA", "SCHEDULES", "HEARTBEAT", "RUNS_24H", "CATALOG", "WEB_CSV", "OUTBOX", "ECHO" })
  Assert(selfTestBody.Contains($"\"{korak}\"", StringComparison.Ordinal), "Samotestu manjka korak " + korak + ".");
Assert(selfTestBody.Contains("ops.BeginSelfTest", StringComparison.Ordinal)
    && selfTestBody.Contains("ops.RecordSelfTestStep", StringComparison.Ordinal)
    && selfTestBody.Contains("ops.CompleteSelfTest", StringComparison.Ordinal),
  "Samotest mora izid in trajanja zapisati v bazo, sicer jih vidi samo tisti, ki gleda konzolo.");
Assert(selfTestBody.Contains("out.GetExportRows", StringComparison.Ordinal),
  "Korak WEB_CSV mora uporabiti isto proceduro kot produkcijski izvoz, sicer ne dokazuje izhoda.");

var runner = Read(Path.Combine(repositoryRoot, "scripts", "run_tests.ps1"));
Assert(runner.Contains("PIM.SelfTest.Nightly", StringComparison.Ordinal) && runner.Contains("izkljuceni", StringComparison.Ordinal),
  "Nočni samotest mora biti izključen iz regresijskega zagona.");

foreach (var skripta in new[] { "Nocni-samotest.ps1", "Namesti-samotest.ps1" })
  Assert(File.Exists(Path.Combine(repositoryRoot, "scripts", skripta)), "Manjka skripta scripts/" + skripta);

// ── 6. Migracija nosi, kar strani berejo ─────────────────────────────────────
var migration = Read(Path.Combine(root, "sql", "migrations", "172_AdminConsole.sql"));
foreach (var objekt in new[]
{
  "ops.SelfTestRun", "ops.SelfTestStep", "out.ExportRun", "ops.UserActivity", "ops.AlertSeen",
  "ops.BeginSelfTest", "ops.RecordSelfTestStep", "ops.CompleteSelfTest",
  "out.BeginExportRun", "out.CompleteExportRun", "ops.LogUserActivity",
  "intranet.GetAdminPulse", "intranet.GetWorkerPerformance", "intranet.GetUserActivityTrail",
  "intranet.GetExportRuns", "intranet.GetSelfTestHistory", "intranet.MarkAlertsSeen",
})
  Assert(migration.Contains(objekt, StringComparison.Ordinal), "Migracija 172 ne ustvari " + objekt + ".");

// Sled mora zajeti vse vire, sicer je "kdo je kaj naredil" spet odvisen od poznavanja sheme.
foreach (var vir in new[]
{
  "pim.ProductFieldHistory", "ops.UserActivity", "ops.Alert", "out.OutboxMessage",
  "ops.ScheduleProfile", "b2b.AuditLog",
})
  Assert(migration.Contains(vir, StringComparison.Ordinal), "Sled sprememb ne bere vira " + vir + ".");

// ── 7. Izvozi puščajo sled ───────────────────────────────────────────────────
var exportCommand = Read(Path.Combine(root, "workers", "PIM.B2bWorker", "MagentoExportCommand.cs"));
Assert(exportCommand.Contains("ExportRunLog.BeginAsync", StringComparison.Ordinal)
    && exportCommand.Contains("ExportRunLog.CompleteAsync", StringComparison.Ordinal),
  "Izvoz v workerju mora zabeležiti zagon; sicer po izvozu ne ostane nič.");

var program = Read(Path.Combine(root, "src", "PIM.Intranet", "Program.cs"));
Assert(program.Contains("BeginExportRunAsync", StringComparison.Ordinal),
  "Izvoz na zahtevo iz intraneta mora pustiti enako sled kot nočni.");
Assert(program.Contains("PimTime.Configure", StringComparison.Ordinal),
  "Časovni pas mora biti izbran ob zagonu, ne podedovan od strežnika.");

// ── 8. Baza, kadar je na voljo ───────────────────────────────────────────────
var connectionString = Environment.GetEnvironmentVariable("PIM_CONNECTION_STRING");
if (string.IsNullOrWhiteSpace(connectionString))
{
  Console.WriteLine("Preverjanje baze je preskočeno: PIM_CONNECTION_STRING ni nastavljen.");
}
else
{
  var settings = new SqlConnectionStringBuilder(connectionString);
  if (!string.Equals(settings.InitialCatalog, "PIM", StringComparison.OrdinalIgnoreCase))
    throw new InvalidOperationException("Ta test je dovoljen samo v razvojni bazi PIM.");

  await using var connection = new SqlConnection(connectionString);
  await connection.OpenAsync();

  foreach (var objekt in new[]
  {
    "ops.SelfTestRun", "ops.SelfTestStep", "out.ExportRun", "ops.UserActivity", "ops.AlertSeen",
    "intranet.GetAdminPulse", "intranet.GetWorkerPerformance", "intranet.GetUserActivityTrail",
    "intranet.GetExportRuns", "intranet.GetSelfTestHistory",
  })
  {
    await using var command = new SqlCommand("SELECT COUNT_BIG(*) FROM sys.objects WHERE object_id = OBJECT_ID(@Ime);", connection);
    command.Parameters.AddWithValue("@Ime", objekt);
    Assert(Convert.ToInt64(await command.ExecuteScalarAsync()) == 1, "V bazi manjka " + objekt + "; uporabi migracijo 172.");
  }

  // Utrip mora vrniti natanko sedem naborov; stran jih bere po vrsti in osmi bi tiho odpadel.
  await using (var pulse = new SqlCommand("intranet.GetAdminPulse", connection)
               { CommandType = System.Data.CommandType.StoredProcedure, CommandTimeout = 120 })
  {
    pulse.Parameters.AddWithValue("@UserKey", "pogodbeni-test");
    await using var reader = await pulse.ExecuteReaderAsync();
    var naborov = 1;
    while (await reader.NextResultAsync()) naborov++;
    Assert(naborov == 7, $"intranet.GetAdminPulse mora vrniti 7 naborov, vrnil je {naborov}.");
  }

  // Sled ne sme vrniti vrstice brez časa ali brez akterja: taka vrstica ne odgovori na nobeno
  // od obeh vprašanj, zaradi katerih obstaja.
  await using (var trail = new SqlCommand("intranet.GetUserActivityTrail", connection)
               { CommandType = System.Data.CommandType.StoredProcedure, CommandTimeout = 120 })
  {
    trail.Parameters.AddWithValue("@Days", 30);
    trail.Parameters.AddWithValue("@Take", 50);
    await using var reader = await trail.ExecuteReaderAsync();
    var vrstic = 0;
    while (await reader.ReadAsync())
    {
      vrstic++;
      Assert(!reader.IsDBNull(reader.GetOrdinal("OccurredUtc")), "Vrstica sledi brez časa.");
      Assert(!reader.IsDBNull(reader.GetOrdinal("Actor")), "Vrstica sledi brez akterja.");
    }

    Console.WriteLine($"Sled sprememb: {vrstic} vrstic v zadnjih 30 dneh.");
  }
}

// ── 9. Mesta shranjevanja: preverba pisanja, ne obstoja ──────────────────────
// Pod IIS mapa praviloma obstaja in je vidna, aplikacijski bazen pa vanjo ne sme pisati.
// Nastavitev, ki tega ne preveri, izgleda kot da deluje, datoteke pa ne nastanejo.
var paths = Read(Path.Combine(pages, "AdminPaths.razor"));
Assert(paths.Contains("@page \"/sistem/mape\"", StringComparison.Ordinal), "Manjka stran /sistem/mape.");
Assert(paths.Contains("[Authorize(Roles = \"ADMIN\")]", StringComparison.Ordinal), "Mesta shranjevanja so samo za ADMIN.");
Assert(paths.Contains("SystemPaths.Identiteta", StringComparison.Ordinal),
  "Stran mora povedati, pod katerim računom intranet teče; brez tega preverba pisanja ni razumljiva.");
Assert(File.Exists(Path.Combine(pages, "AdminPaths.razor.css")), "Manjka izoliran slog strani mest shranjevanja.");

Assert(!PIM.Operations.SystemPaths.Check("prevzem\\bt").Writable, "Relativna pot ne sme biti sprejeta.");
Assert(!PIM.Operations.SystemPaths.Check("").Writable, "Prazna pot ne sme biti sprejeta.");
Assert(!PIM.Operations.SystemPaths.Check(@"\\\\ni-tega-streznika-2026\\delitev").Writable,
  "Nedosegljiva delitev ne sme biti sprejeta.");

var zacasna = Path.Combine(Path.GetTempPath(), "pim-pot-" + Guid.NewGuid().ToString("N")[..8]);
try
{
  var izid = PIM.Operations.SystemPaths.Check(zacasna);
  Assert(izid.Writable, "Pišljiva mapa mora biti sprejeta: " + izid.Message);
  Assert(izid.Message.Contains(PIM.Operations.SystemPaths.Identiteta(), StringComparison.Ordinal),
    "Izid preverbe mora povedati, za kateri račun velja.");
  Assert(Directory.GetFiles(zacasna).Length == 0, "Preverba mora za sabo pobrisati preizkusno datoteko.");
}
finally
{
  try { Directory.Delete(zacasna, recursive: true); } catch (IOException) { }
}

var migration173 = Read(Path.Combine(root, "sql", "migrations", "173_SystemPaths.sql"));
foreach (var objekt in new[] { "ops.SystemPath", "ops.SetSystemPath", "ops.ClearSystemPath", "ops.ResolveSystemPath", "intranet.GetSystemPaths" })
  Assert(migration173.Contains(objekt, StringComparison.Ordinal), "Migracija 173 ne ustvari " + objekt + ".");

var fetchProgram = Read(Path.Combine(root, "workers", "PIM.SourceFetchWorker", "Program.cs"));
Assert(fetchProgram.Contains("SystemPaths.ResolveAsync", StringComparison.Ordinal)
    && fetchProgram.IndexOf("PIM_FETCH_ROOT", StringComparison.Ordinal) < fetchProgram.IndexOf("SystemPaths.ResolveAsync", StringComparison.Ordinal),
  "Prevzemnik mora brati register, a šele za argumentom in okoljsko spremenljivko.");

/* ─── 10. Prenova zavihkov nadzora, 2026-09-10 ────────────────────────────────
   Uporabnik: /sistem je bila ena dolga stran z desetimi karticami-gumbi na dnu, seznam
   "Potrebuje pozornost" je podvajal vrstice iz tabel spodaj, samotest pa je na pregled vlekel
   celotno tabelo korakov. Zahteva: isti vzorec kot na /kakovost in /saop — skupen zavihek-trak
   (NadzorTabs, PimTab.cs) na vsaki strani podrocja, Postopki in Zaloga sta pogled znotraj
   /sistem (isti Pulse), preostali zavihki obstojece podstrani. Uporabniki/vloge/mape niso
   vprasanje "ali sistem dela" in so zato loceni v svoj hub "Sistemske zadeve"
   (SistemskeZadeveTabs, route /administracija — locen prostor poti, da se ne prekriva z
   /sistem v predpono-ujemanju stranske navigacije). */
var shared = Path.Combine(root, "src", "PIM.Intranet", "Components", "Shared");
var pimTab = Read(Path.Combine(shared, "PimTab.cs"));
Assert(pimTab.Contains("class NadzorTabs", StringComparison.Ordinal),
  "Zavihki nadzora morajo biti en sam skupen seznam, enako kot QualityTabs/SaopTabs.");
Assert(pimTab.Contains("class SistemskeZadeveTabs", StringComparison.Ordinal),
  "Uporabniki/vloge/mape morajo imeti svoj locen seznam zavihkov, locen od nadzora.");

var activity = Read(Path.Combine(pages, "AdminActivity.razor"));
var exports = Read(Path.Combine(pages, "AdminExports.razor"));
var selfTestPage = Read(Path.Combine(pages, "AdminSelfTest.razor"));
var integrations = Read(Path.Combine(pages, "SystemIntegrations.razor"));
foreach (var page in new[] { console, activity, exports, selfTestPage, integrations, Read(Path.Combine(pages, "SystemWorkers.razor")) })
  Assert(page.Contains("<PimTabs", StringComparison.Ordinal) && page.Contains("NadzorTabs.Tabs", StringComparison.Ordinal),
    "Vsaka stran nadzora mora prikazati skupni zavihek NadzorTabs.");

var users = Read(Path.Combine(pages, "SystemUsers.razor"));
var roles = Read(Path.Combine(pages, "SystemRoles.razor"));
foreach (var page in new[] { users, roles, paths })
  Assert(page.Contains("<PimTabs", StringComparison.Ordinal) && page.Contains("SistemskeZadeveTabs.Tabs", StringComparison.Ordinal),
    "Uporabniki, vloge in mesta shranjevanja morajo prikazati skupni zavihek SistemskeZadeveTabs.");

Assert(!console.Contains("hub-grid", StringComparison.Ordinal) && !console.Contains("PimHubCard", StringComparison.Ordinal),
  "Kartice-gumbi na dnu /sistem so odstranjene — poti so zdaj zavihki.");
Assert(!console.Contains("Zadnji izvoz po profilu", StringComparison.Ordinal),
  "Polna tabela zadnjih izvozov na pregledu je odstranjena; polni pregled nosi zavihek Izvozi.");

// Koraki zadnjega samotesta (prej cela tabela na pregledu, "oblacki") so se preselili na svojo stran.
Assert(!console.Contains("SelfTestSteps", StringComparison.Ordinal),
  "Koraki samotesta ne smejo biti vec na pregledni strani /sistem.");
Assert(selfTestPage.Contains("SelfTestSteps", StringComparison.Ordinal),
  "Koraki zadnjega zagona morajo biti na strani /sistem/samotest.");

// ── 11. Workerji (2026-09-15): rocni zagon, izpis v zivo in dnevniki ──────────
var workersPage = Read(Path.Combine(pages, "SystemWorkers.razor"));
foreach (var pogodba in new[] { "Konzola.Start", "Konzola.Cancel", "Potrdi zagon", "Samo napake", "Namesti-opravila.ps1", "GetScheduledTasksAsync", "SaveScheduleAsync", "LogActivityAsync", "WORKER_RUN", "ReadLog" })
  Assert(workersPage.Contains(pogodba, StringComparison.Ordinal), "Stran Workerji nima pogodbe: " + pogodba);
Assert(!workersPage.Contains("pwsh -File", StringComparison.Ordinal), "Ukaz za registracijo mora biti powershell; pwsh ni nujno namescen.");
Assert(pimTab.Contains("\"sistem/workerji\"", StringComparison.Ordinal), "Workerji morajo biti zavihek nadzora.");

Console.WriteLine("F10 admin console UX contract PASS.");

static string Read(string path)
{
  Assert(File.Exists(path), "Manjka datoteka: " + path);
  return File.ReadAllText(path);
}

static void Assert(bool condition, string message)
{
  if (!condition) throw new InvalidOperationException(message);
}

// Koren se poisce iz delovne mape in iz mape sestave, da je test neodvisen od nacina zagona.
static string FindRoot()
{
  foreach (var start in new[] { Directory.GetCurrentDirectory(), AppContext.BaseDirectory })
  {
    var current = new DirectoryInfo(start);
    while (current is not null)
    {
      if (File.Exists(Path.Combine(current.FullName, "PIM.sln"))) return current.FullName;
      current = current.Parent;
    }
  }

  throw new InvalidOperationException("PIM_Solution ni najden.");
}
