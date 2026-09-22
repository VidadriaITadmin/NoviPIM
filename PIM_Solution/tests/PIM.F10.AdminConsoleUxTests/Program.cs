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
// Blok 7 prenove nadzora (2026-09-22): Nadzor (Monitor.razor) in stran posla (MonitorJob.razor) sta
// nadomestila stari pregled in njegove podstrani. Njune pogodbe so v razdelku 13 na koncu, da
// preostanek testa pove svoje tudi, dokler novi strani še nastajata. Tu ostaneta samotest in sled,
// ki nista posel.
foreach (var (file, route) in new[]
{
  ("AdminActivity.razor", "/sistem/sled"),
  ("AdminSelfTest.razor", "/sistem/samotest"),
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

// ── 2. Stare strani nadzora so odstranjene, ne skrite ────────────────────────
// Uporabnik: »jaz moram vsaki korak imeti pod nadzorom … naredi pregledno in uporabno«. Sedem strani
// je isti posel kazalo razdrobljeno (urnik na Opravilih, koraki na Zagonih, alarm na Integracijah);
// zdaj je posel ena vrstica na Nadzoru in ena stran s koraki, fazami in izpisom.
foreach (var odstranjena in new[]
{
  "System.razor", "System.razor.css", "SystemJobs.razor", "SystemJobs.razor.css",
  "SystemJobRuns.razor", "SystemJobRuns.razor.css", "SystemIntegrations.razor", "SystemIntegrations.razor.css",
  "SystemErrors.razor", "SystemErrors.razor.css", "AdminPerformance.razor", "AdminPerformance.razor.css",
  "AdminExports.razor", "AdminExports.razor.css",
})
  Assert(!File.Exists(Path.Combine(pages, odstranjena)), "Stara stran nadzora se ne sme vrniti: " + odstranjena);
Assert(!Directory.Exists(Path.Combine(root, "tests", "PIM.F10.SystemIntegrationsUxTests")),
  "Pogodbeni test odstranjene strani /sistem/integracije ne sme ostati.");
Assert(!Read(Path.Combine(root, "PIM.sln")).Contains("PIM.F10.SystemIntegrationsUxTests", StringComparison.Ordinal),
  "PIM.sln ne sme več graditi testa odstranjene strani /sistem/integracije.");

// Nobena stran, storitev ali skript v intranetu ne sme voditi na odstranjeno pot (prazna stran 404).
// Iščemo naslov v narekovajih (href, niz v kodi, $"…"), ne omembe v komentarju. Velja tudi za postavitev
// (povezava »Odpri vsa obvestila« v zvoncu vodi na /sistem).
var odstranjenePoti = new[] { "sistem/opravila", "sistem/zagoni", "sistem/integracije", "system/integracije", "sistem/napake", "sistem/zmogljivost", "sistem/izvozi", "sistem?pogled=" };
foreach (var file in Directory.EnumerateFiles(Path.Combine(root, "src", "PIM.Intranet"), "*.*", SearchOption.AllDirectories))
{
  if (!file.EndsWith(".razor", StringComparison.OrdinalIgnoreCase) && !file.EndsWith(".cs", StringComparison.OrdinalIgnoreCase)
      && !file.EndsWith(".js", StringComparison.OrdinalIgnoreCase)) continue;
  if (file.Contains($"{Path.DirectorySeparatorChar}bin{Path.DirectorySeparatorChar}", StringComparison.Ordinal)) continue;
  if (file.Contains($"{Path.DirectorySeparatorChar}obj{Path.DirectorySeparatorChar}", StringComparison.Ordinal)) continue;
  var text = File.ReadAllText(file);
  foreach (var pot in odstranjenePoti)
    foreach (var povezava in new[] { $"\"{pot}", $"\"/{pot}" })
      Assert(!text.Contains(povezava, StringComparison.Ordinal),
        $"{Path.GetFileName(file)} vodi na odstranjeno stran /{pot} ({povezava}).");
}

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
// Blok 7: klik na obvestilo odpre stran, kjer je težava vidna in rešljiva. Alarm posla
// (Pipeline "OPRAVILO:<KEY>") odpre stran tega posla, gostitelj in postopki Nadzor, zavrnjen izvoz
// stran spletnega izhoda. Nobena pot preslikave ne sme voditi na odstranjeno stran.
var alertHrefStart = layout.IndexOf("static string AlertHref", StringComparison.Ordinal);
Assert(alertHrefStart >= 0, "Postavitev mora imeti preslikavo obvestila na stran (AlertHref).");
var alertHref = layout[alertHrefStart..layout.IndexOf("};", alertHrefStart, StringComparison.Ordinal)];
foreach (var pogodba in new[] { "\"OPRAVILO:\"", "\"sistem/posel/\"", "\"GOSTITELJ\"", "\"ExportRejected\" => \"splet\"", "_ => \"sistem\"" })
  Assert(alertHref.Contains(pogodba, StringComparison.Ordinal), "Preslikava obvestila nima pogodbe: " + pogodba);
foreach (var pot in odstranjenePoti.Append("teki-obdelave"))
  Assert(!alertHref.Contains("\"" + pot, StringComparison.Ordinal), "Obvestilo ne sme voditi na " + pot + ".");

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
Assert(paths.Contains("@page \"/administracija/mape\"", StringComparison.Ordinal) && !paths.Contains("@page \"/sistem/mape\"", StringComparison.Ordinal), "Mesta shranjevanja imajo eno pot: /administracija/mape.");
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
var selfTestPage = Read(Path.Combine(pages, "AdminSelfTest.razor"));
foreach (var (page, active) in new[] { (activity, "sled"), (selfTestPage, "samotest") })
{
  Assert(page.Contains("<PimTabs", StringComparison.Ordinal) && page.Contains("NadzorTabs.Tabs", StringComparison.Ordinal),
    "Vsaka stran nadzora mora prikazati skupni zavihek NadzorTabs.");
  Assert(page.Contains($"<PimTabs Active=\"{active}\"", StringComparison.Ordinal),
    $"Stran nadzora mora označiti svoj zavihek »{active}«.");
}

var users = Read(Path.Combine(pages, "SystemUsers.razor"));
var roles = Read(Path.Combine(pages, "SystemRoles.razor"));
foreach (var page in new[] { users, roles, paths })
  Assert(page.Contains("<PimTabs", StringComparison.Ordinal) && page.Contains("SistemskeZadeveTabs.Tabs", StringComparison.Ordinal),
    "Uporabniki, vloge in mesta shranjevanja morajo prikazati skupni zavihek SistemskeZadeveTabs.");

// Koraki zadnjega samotesta (prej cela tabela na pregledu, "oblacki") so se preselili na svojo stran.
Assert(selfTestPage.Contains("SelfTestSteps", StringComparison.Ordinal),
  "Koraki zadnjega zagona morajo biti na strani /sistem/samotest.");

// Blok 7: Nadzor ima natanko tri zavihke — Nadzor, Samotest in Sled sprememb. Opravila, Zagoni,
// Alarmi in Izvozi so del strani posla, ne zavihki.
var nadzorTabsStart = pimTab.IndexOf("class NadzorTabs", StringComparison.Ordinal);
var nadzorTabs = pimTab[nadzorTabsStart..pimTab.IndexOf("];", nadzorTabsStart, StringComparison.Ordinal)];
foreach (var zavihek in new[] { "new(\"nadzor\", \"Nadzor\", \"sistem\"", "new(\"samotest\", \"Samotest\", \"sistem/samotest\"", "new(\"sled\", \"Sled sprememb\", \"sistem/sled\"" })
  Assert(nadzorTabs.Contains(zavihek, StringComparison.Ordinal), "Zavihkom nadzora manjka: " + zavihek);
Assert(nadzorTabs.Split("new(", StringSplitOptions.None).Length - 1 == 3, "Nadzor ima natanko tri zavihke.");
foreach (var odstranjen in new[] { "\"opravila\"", "\"zagoni\"", "\"alarmi\"", "\"izvozi\"", "\"pregled\"", "\"sistem/opravila\"", "\"sistem/zagoni\"", "\"sistem/integracije\"" })
  Assert(!nadzorTabs.Contains(odstranjen, StringComparison.Ordinal), "Odstranjen zavihek nadzora se ne sme vrniti: " + odstranjen);

var accessCatalog = Read(Path.Combine(services, "PimAccessCatalog.cs"));
Assert(accessCatalog.Contains("\"sistem/posel/\"", StringComparison.Ordinal),
  "Stran posla (sistem/posel/<KEY>) mora imeti pravico v katalogu, sicer jo varovalo poti zapre.");
foreach (var kljuc in new[] { "tab.system.jobs", "tab.system.runs", "tab.system.schedules", "tab.system.alerts", "view.system.exports", "view.system.performance", "view.system.errors" })
  Assert(!accessCatalog.Contains("\"" + kljuc + "\"", StringComparison.Ordinal), "Katalog pravic še vsebuje ključ odstranjene strani: " + kljuc);

// ── 11. En motor avtomatike (migracija 254): Workerji in Urniki sta odpadla ──────
// Ročni zagon mimo gostitelja (/sistem/workerji, 2026-09-15) in razporejevalnik ciklov v intranetu
// (/sistem/urniki, 2026-09-17) sta tekla vzporedno s PIM.AutomationHost; posle zdaj poganja samo
// gostitelj (ops.Job*). Pogodbe strani Workerji so se prek Opravil in Zagonov (237) v bloku 7
// preselile na Nadzor in stran posla (razdelek 13 jih preveri: sled, ustavitev, drugi klik):
//   ročni zagon                  → Nadzor/stran posla: zahteva gostitelju (RequestRunAsync) s sledjo JOB_RUN_REQUEST;
//   izpis dnevnika zagona        → stran posla: bralnik dnevnikov (ReadLog oziroma LogTail);
//   urnik in vklop posla s sledjo → stran posla prek MonitorService.
foreach (var odpisana in new[] { "SystemWorkers.razor", "SystemWorkers.razor.css", "SystemSchedules.razor", "SystemSchedules.razor.css" })
  Assert(!File.Exists(Path.Combine(pages, odpisana)), "Stran starega motorja se ne sme vrniti: " + odpisana);
foreach (var odpisan in new[] { "WorkerSchedulerService.cs", "WorkerCycleRunner.cs", "WorkerSchedulerStore.cs" })
  Assert(!File.Exists(Path.Combine(services, odpisan)), "Razporejevalnik ciklov v intranetu se ne sme vrniti: " + odpisan);
Assert(!pimTab.Contains("sistem/workerji", StringComparison.Ordinal) && !pimTab.Contains("Izvajalniki", StringComparison.Ordinal),
  "Workerji (Izvajalniki) niso več zavihek nadzora; posel kaže njegova stran.");

// ── 12. Enotni model opravil (237): gostitelj avtomatike ────────────────────────
// Uporabnik 2026-09-21: IIS je nadzorna konzola, ne motor avtomatike; ročni zagon je zahteva, ki jo
// prevzame gostitelj; izvoz ne validira; naročila so ločena od kataloga. Strani Opravila in Zagoni
// (237) je blok 7 nadomestil z Nadzorom in stranjo posla (razdelek 13).
Assert(!pimTab.Contains("\"sistem?pogled=postopki\"", StringComparison.Ordinal), "Tehnični razporedi postopkov niso več zavihek (dvojno razporejanje).");

var catalog = Read(Path.Combine(root, "src", "PIM.Automation", "JobCatalog.cs"));
Assert(!catalog.Contains("--osvezi-validacijo", StringComparison.Ordinal), "Izvoz v enotnem modelu ne sme validirati (--osvezi-validacijo).");
Assert(!catalog.Contains("--po-urniku", StringComparison.Ordinal), "Posel ima en urnik — gostitelja; --po-urniku je dvojno razporejanje.");
var hostProgram = Read(Path.Combine(root, "workers", "PIM.AutomationHost", "Program.cs"));
Assert(hostProgram.Contains("AddWindowsService", StringComparison.Ordinal) && hostProgram.Contains("--preveri", StringComparison.Ordinal),
  "Gostitelj mora teči kot Windows storitev in imeti zunanji nadzor (--preveri).");
var migration237 = Read(Path.Combine(root, "sql", "migrations", "237_EnotniModelOpravil.sql"));
foreach (var objekt in new[]
{
  "ops.JobDefinition", "ops.JobDependency", "ops.JobRun", "ops.JobStepRun", "ops.DataCheckpoint", "ops.Artifact",
  "ops.ClaimJobRun", "ops.HeartbeatJobRun", "ops.CompleteJobRun", "ops.AbandonStaleJobRuns", "ops.EvaluateJobAlerts",
  "ops.RequestJobRun", "ops.RequestJobCancel", "intranet.GetJobDefinitions", "intranet.GetJobRuns", "intranet.GetAutomationHost", "intranet.SaveJobSchedule",
  "AutomationHostDown", "Priority",
})
  Assert(migration237.Contains(objekt, StringComparison.Ordinal), "Migracija 237 ne ustvari " + objekt + ".");
Assert(File.Exists(Path.Combine(root, "deploy", "Install-AutomationHost.ps1")), "Manjka deploy/Install-AutomationHost.ps1.");
Assert(File.Exists(Path.Combine(repositoryRoot, "scripts", "Namesti-nadzor-avtomatike.ps1")), "Manjka scripts/Namesti-nadzor-avtomatike.ps1.");
var installer = Read(Path.Combine(root, "deploy", "Install-AutomationHost.ps1"));
Assert(installer.Contains("New-Service", StringComparison.Ordinal) && installer.Contains("sc.exe", StringComparison.Ordinal) && installer.Contains("failure", StringComparison.Ordinal),
  "Namestitev gostitelja mora nastaviti samodejni ponovni zagon storitve (sc.exe failure).");
Assert(Read(Path.Combine(repositoryRoot, "scripts", "Namesti-nadzor-avtomatike.ps1")).Contains("--preveri", StringComparison.Ordinal),
  "Zunanji nadzor mora klicati PIM.AutomationHost --preveri.");

if (!string.IsNullOrWhiteSpace(connectionString))
{
  await using var connection = new SqlConnection(connectionString);
  await connection.OpenAsync();
  foreach (var objekt in new[] { "ops.JobDefinition", "ops.JobRun", "ops.JobStepRun", "ops.JobDependency", "ops.DataCheckpoint", "ops.Artifact", "ops.ClaimJobRun", "ops.EvaluateJobAlerts", "intranet.GetJobDefinitions", "intranet.GetAutomationHost" })
  {
    await using var command = new SqlCommand("SELECT COUNT_BIG(*) FROM sys.objects WHERE object_id = OBJECT_ID(@Ime);", connection);
    command.Parameters.AddWithValue("@Ime", objekt);
    Assert(Convert.ToInt64(await command.ExecuteScalarAsync()) == 1, "V bazi manjka " + objekt + "; uporabi migracijo 237.");
  }
  await using (var definitions = new SqlCommand("intranet.GetJobDefinitions", connection) { CommandType = System.Data.CommandType.StoredProcedure })
  {
    await using var reader = await definitions.ExecuteReaderAsync();
    var naborov = 1;
    while (await reader.NextResultAsync()) naborov++;
    Assert(naborov == 3, $"intranet.GetJobDefinitions mora vrniti 3 nabore, vrnil je {naborov}.");
  }
}

// ── 13. Nadzor in stran posla (bloki 5–7 prenove nadzora, 2026-09-22) ───────────
// Uporabnik: »jaz moram vsaki korak imeti pod nadzorom in videti da se vse izvede«. Nadzor ima eno
// vrstico na posel (zelena / siva / rdeča, rumene ni), stran posla pa korake, faze s števili in
// izpis. Razdelek je zadnji, da preostale pogodbe povedo svoje, tudi dokler strani še nastajata.
var monitor = Read(Path.Combine(pages, "Monitor.razor"));
var monitorJob = Read(Path.Combine(pages, "MonitorJob.razor"));
foreach (var (file, markup, route) in new[]
{
  ("Monitor.razor", monitor, "@page \"/sistem\""),
  ("MonitorJob.razor", monitorJob, "@page \"/sistem/posel/"),
})
{
  Assert(markup.Contains(route, StringComparison.Ordinal), $"{file} mora biti na poti {route}.");
  Assert(markup.Contains("[Authorize(Roles = \"ADMIN\")]", StringComparison.Ordinal), $"{file} mora biti dostopna samo vlogi ADMIN.");
  Assert(markup.Contains("PimTime.", StringComparison.Ordinal), $"{file} mora čas kazati prek PimTime.");
  Assert(markup.Contains("MonitorService", StringComparison.Ordinal), $"{file} mora brati prek MonitorService.");
  // Rumene ni: stanje je zelena (good), siva (brez tona) ali rdeča (bad).
  Assert(!markup.Contains("\"warn\"", StringComparison.Ordinal), $"{file} ne sme uporabljati rumenega tona »warn«.");
  var css = Path.Combine(pages, Path.GetFileNameWithoutExtension(file) + ".razor.css");
  Assert(File.Exists(css), "Manjka izoliran slog: " + css);
  var cssText = File.ReadAllText(css);
  Assert(!cssText.Contains("::deep", StringComparison.Ordinal), "Izoliran slog ne sme uhajati z ::deep: " + css);
  Assert(!cssText.Contains("--pim-warn", StringComparison.Ordinal) && !cssText.Contains(".warn", StringComparison.Ordinal),
    "Slog nadzora ne sme imeti rumenega stanja: " + css);
}
Assert(monitor.Contains("<PimTabs Active=\"nadzor\"", StringComparison.Ordinal) && monitor.Contains("NadzorTabs.Tabs", StringComparison.Ordinal),
  "Nadzor mora prikazati skupni zavihek NadzorTabs z aktivnim zavihkom »nadzor«.");
foreach (var pogodba in new[] { "GetOverviewAsync", "RequestRunAsync", "sistem/posel/", "Vse teče", "sistem/samotest", "sistem/sled" })
  Assert(monitor.Contains(pogodba, StringComparison.Ordinal), "Nadzor nima pogodbe: " + pogodba);
Assert(!monitor.Contains("SelfTestSteps", StringComparison.Ordinal), "Koraki samotesta ne smejo biti na Nadzoru; so na /sistem/samotest.");
foreach (var pogodba in new[] { "GetJobAsync", "PhaseCodes.Label" })
  Assert(monitorJob.Contains(pogodba, StringComparison.Ordinal), "Stran posla nima pogodbe: " + pogodba);
Assert(monitorJob.Contains("ReadLog", StringComparison.Ordinal) || monitorJob.Contains("LogTail", StringComparison.Ordinal),
  "Stran posla mora pokazati izpis teka iz dnevnika (ReadLog ali LogTail).");

// Nadzor in ročni zagon (preseljeno iz razdelka 11, prej SystemJobs/SystemJobRuns): sled vsakega dejanja,
// ustavitev teka in drugi klik pred zagonom posla, ki kliče SAOP ali dobavitelja.
var monitorService = Read(Path.Combine(services, "MonitorService.cs"));
foreach (var pogodba in new[] { "\"JOB_RUN_REQUEST\"", "\"JOB_CANCEL_REQUEST\"", "LogActivityAsync", "RequestCancelAsync", "RequireAdminAsync" })
  Assert(monitorService.Contains(pogodba, StringComparison.Ordinal), "MonitorService nima pogodbe (sled ali varovalo dejanja): " + pogodba);
foreach (var (file, markup) in new[] { ("Monitor.razor", monitor), ("MonitorJob.razor", monitorJob) })
  Assert(markup.Contains("Potrdi zagon", StringComparison.Ordinal) && markup.Contains("Reach != \"Internal\"", StringComparison.Ordinal),
    $"{file}: zagon posla, ki kliče SAOP ali dobavitelja, zahteva drugi klik (»Potrdi zagon«).");
Assert(monitorJob.Contains("RequestCancelAsync", StringComparison.Ordinal), "Stran posla mora omogočiti ustavitev teka (RequestCancelAsync).");
Assert(monitor.Contains("MarkAlertsSeenAsync", StringComparison.Ordinal), "Nadzor mora ob odprtju označiti obvestila kot videna (zvonec).");

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
