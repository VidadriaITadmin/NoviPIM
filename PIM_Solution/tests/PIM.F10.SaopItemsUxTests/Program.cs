using System.Text.RegularExpressions;

// Pogodbeni test strani za vnos artiklov v SAOP (/saop/artikli) in njene storitve.
//
// Kaj ta test varuje in zakaj:
//
// 1. ADD in PATCH sta ena stran. Stari sistem (..\PIM_test) je imel dve — /export/saop-item-new
//    in /export/saop-item-edit — in izbira med njima je bila rocna. V stari vrsti je 118 od 130
//    napak natanko ta ena rocna odlocitev. Zato tu ne sme biti nobenega preklopnika metode:
//    metodo izpelje SaopIntentResolver iz tega, ali artikel obstaja v kanonicnem modelu.
//
// 2. Predogled mora sestaviti ISTI dokument kot posiljatelj. Predogled z lastnim gradnikom bi
//    lagal, zato storitev uporablja SaopDocumentBuilder in pogodbo iz out.GetSaopXmlContract.
//
// 3. Predogled ne sme prevzemati. out.ClaimItemDocument poveca stevilo poskusov in postavi
//    lease; vsak pogled bi porabil en poskus (past, ki jo opisuje migracija 086).
//
// 4. Prazna celica pomeni "tega polja se ne dotakni", ne "izprazni ga".
//
// 5. Naročilo gre skozi varovano pot (out.EnqueueSaopItemChanges prek SaopWriteService), ne
//    mimo nje s svojim SQL.
//
// Test ne zahteva nobene nove poizvedbe in nobene nove zapisovalne poti.

var root = FindRoot();
var pages = Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages");
var services = Path.Combine(root, "src", "PIM.Intranet", "Services");

var razorPath = Path.Combine(pages, "SaopItems.razor");
var cssPath = Path.Combine(pages, "SaopItems.razor.css");
var servicePath = Path.Combine(services, "SaopItemWriteService.cs");
var labelsPath = Path.Combine(services, "SaopFieldLabels.cs");

foreach (var path in new[] { razorPath, cssPath, servicePath, labelsPath })
  Assert(File.Exists(path), "Manjka zahtevan artefakt: " + path);

var markup = File.ReadAllText(razorPath);
var css = File.ReadAllText(cssPath);
var service = File.ReadAllText(servicePath);
var labels = File.ReadAllText(labelsPath);

// --- 1. Pot, zascita, nacin izrisa ----------------------------------------
Assert(markup.Contains("@page \"/saop/artikli\"", StringComparison.Ordinal), "Pot strani mora biti /saop/artikli.");
Assert(markup.Contains("@attribute [Authorize(Roles = \"ADMIN,CATALOG_EDITOR\")]", StringComparison.Ordinal),
  "Zapisovanje v SAOP mora biti omejeno na ADMIN in CATALOG_EDITOR — enako kot ostale zapisovalne strani SAOP.");
Assert(markup.Contains("@rendermode InteractiveServer", StringComparison.Ordinal), "Stran je obrazec in mora biti interaktivna.");

// --- 2. Skupni PIM gradniki, brez Bootstrapa ------------------------------
foreach (var component in new[] { "<PimPage", "<PimTabs", "<PimState", "<PimChip", "<PimTable" })
  Assert(markup.Contains(component, StringComparison.Ordinal), "Stran mora uporabljati skupni gradnik " + component + ".");
foreach (var bootstrapClass in new[] { "row", "col", "card", "form-control", "form-select", "form-check", "btn", "table" })
  Assert(!HasCssClass(markup, bootstrapClass), "Stran ne sme uporabljati Bootstrap razreda " + bootstrapClass + ".");
Assert(css.Contains("--pim-", StringComparison.Ordinal), "Slog strani mora uporabljati barve iz vizualnega sistema, ne svojih.");

// --- 3. ADD in PATCH sta ena pot ------------------------------------------
Assert(!Regex.IsMatch(markup, "Način vnosa|Nacin vnosa", RegexOptions.IgnoreCase),
  "Preklopnika nacina vnosa ne sme biti: nov artikel in sprememba sta ista pot.");
Assert(!Regex.IsMatch(markup, "_mode|SetMode\\(", RegexOptions.None),
  "Stran ne sme voditi rocnega stanja nacina (ADD/PATCH); metoda je izpeljana.");
Assert(markup.Contains("NOV — POST", StringComparison.Ordinal) && markup.Contains("SPREMEMBA — PATCH", StringComparison.Ordinal),
  "Vsaka vrstica mora povedati, s katero metodo bo poslana.");
Assert(markup.Contains("plan.Reason", StringComparison.Ordinal),
  "Ob metodi mora biti viden razlog izbire; brez njega je izbira spet ugibanje.");

// --- 4. Predogled je isti gradnik kot posiljatelj -------------------------
// Pravila nacrta so v domeni (PIM.Outbound), ker so cista logika in morajo biti preverljiva
// brez baze in brez spletnega projekta — ista locitev kot pri WorkbookChangeMapper.
var plannerPath = Path.Combine(root, "src", "PIM.Outbound", "SaopItemPlanner.cs");
Assert(File.Exists(plannerPath), "Manjka nacrt dokumenta v domeni: " + plannerPath);
var planner = File.ReadAllText(plannerPath);

Assert(service.Contains("SaopItemPlanner.Plan(", StringComparison.Ordinal),
  "Storitev mora nacrt prepustiti domeni, ne graditi svojega.");
Assert(planner.Contains("SaopIntentResolver.Resolve", StringComparison.Ordinal),
  "Metodo mora izbrati SaopIntentResolver, ne stran in ne uporabnik.");
Assert(planner.Contains("new SaopDocumentBuilder(", StringComparison.Ordinal),
  "Dokument mora sestaviti SaopDocumentBuilder — isti gradnik kot pri posiljanju.");
Assert(planner.Contains("SuggestCodeElement is not null", StringComparison.Ordinal),
  "Predogled mora glede SuggestFirstFreeCode ravnati enako kot posiljatelj, sicer kaze drug dokument.");
Assert(service.Contains("out.GetSaopXmlContract", StringComparison.Ordinal),
  "Pogodba dokumenta mora priti iz registra, ne iz vpisanega seznama.");
Assert(service.Contains("out.GetSaopItemWriteState", StringComparison.Ordinal),
  "Stanje artikla mora priti iz baze, ne iz ugibanja.");
Assert(service.Contains("intranet.GetWritableSaopFields", StringComparison.Ordinal),
  "Vmesnik sme ponuditi samo polja, ki jih baza dovoli; sicer jih zavrne z 51010.");

// --- 5. Predogled ne sme prevzemati --------------------------------------
// Trditev je vezana na KLIC, ne na omembo: prevzem je v komentarju opisan prav zato, da se ve,
// zakaj ga tu ni. Prepoved omembe bi silila k brisanju razlage.
foreach (var forbidden in new[] { "out.ClaimItemDocument", "out.ClaimMessage", "out.CompleteAttempt" })
  Assert(!Regex.IsMatch(service, "EXEC\\s+" + Regex.Escape(forbidden)),
    "Predogled ne sme klicati " + forbidden + ": prevzem poveca stevilo poskusov in postavi lease.");

// --- 6. Prazna celica ne pomeni izpraznitve -------------------------------
Assert(planner.Contains("string.IsNullOrWhiteSpace(value)", StringComparison.Ordinal),
  "Gradnja dokumenta mora prazne vrednosti izpustiti.");
Assert(markup.Contains("!string.IsNullOrWhiteSpace(pair.Value)", StringComparison.Ordinal),
  "V vrsto se ne sme uvrstiti prazna vrednost — to bi v SAOP izbrisalo podatek.");
Assert(Regex.IsMatch(markup, "prazna celica|Prazna celica", RegexOptions.IgnoreCase),
  "Pravilo o prazni celici mora biti napisano tudi uporabniku.");

// --- 7. Narocilo gre skozi varovano pot -----------------------------------
Assert(markup.Contains("Write.EnqueueAsync", StringComparison.Ordinal),
  "Uvrstitev v vrsto mora iti skozi SaopWriteService (out.EnqueueSaopItemChanges).");
foreach (var forbidden in new[] { "INSERT ", "SqlCommand" })
  Assert(!markup.Contains(forbidden, StringComparison.Ordinal), "Stran ne sme pisati v bazo mimo storitve (" + forbidden + ").");
Assert(markup.Contains("Write.ApproveBatchAsync", StringComparison.Ordinal) && markup.Contains("Write.CancelBatchAsync", StringComparison.Ordinal),
  "Skupino mora biti mogoce odobriti in preklicati z iste strani.");

// --- 8. Stanje kanala je povedano vnaprej ---------------------------------
Assert(service.Contains("dbo.IntegrationProfile", StringComparison.Ordinal),
  "Stran mora vedeti, ali je kanal sploh odprt; brez profila baza zavrne vsako sporocilo z 51001.");
Assert(markup.Contains("51001", StringComparison.Ordinal),
  "Kadar profila ni, mora stran povedati, kaj se bo zgodilo, in ne pustiti uporabnika v temo.");

// --- 9. Dnevnik: kaj se je zgodilo ----------------------------------------
Assert(service.Contains("ILogger<SaopItemWriteService>", StringComparison.Ordinal),
  "Storitev mora pisati v dnevnik streznika.");
Assert(Regex.IsMatch(service, "logger\\.Log(Information|Warning|Error)"), "Storitev mora dejansko zapisati dogodke, ne le imeti dnevnika.");
Assert(markup.Contains("Dnevnik seje", StringComparison.Ordinal), "Stran mora imeti viden dnevnik dejanj.");
Assert(markup.Contains("Log.LogInformation", StringComparison.Ordinal) && markup.Contains("Log.LogError", StringComparison.Ordinal),
  "Dejanja in napake strani morajo iti tudi v dnevnik streznika.");
Assert(Regex.Matches(markup, "Note\\(").Count >= 10, "Dnevnik mora zabelezti vsa pomembna dejanja, ne le enega.");

// --- 10. Dostopnost obrazca ----------------------------------------------
foreach (var control in new[] { "saop-items-org", "saop-items-codes", "saop-items-file" })
  Assert(Regex.IsMatch(markup, "<label[^>]*for=\"" + control + "\""), "Kontrola " + control + " nima povezane oznake <label for>.");
Assert(Regex.Matches(markup, "aria-label=").Count >= 5, "Vrsticne kontrole tabele morajo imeti svoje oznake.");
Assert(markup.Contains("<caption>", StringComparison.Ordinal) || markup.Contains("<caption>", StringComparison.Ordinal),
  "Tabela vrednosti mora imeti napis.");

// --- 11. Slovenske oznake polj -------------------------------------------
foreach (var element in new[] { "ItemTitle1", "ItemGroup", "SupplierID", "ItemEANCode", "IsActive", "VATRateID" })
  Assert(labels.Contains("[\"" + element + "\"]", StringComparison.Ordinal), "Manjka slovenska oznaka za element " + element + ".");

// --- 12. Stran je dosegljiva iz razdelilne strani SAOP --------------------
var saopPage = File.ReadAllText(Path.Combine(pages, "Saop.razor"));
Assert(saopPage.Contains("saop/artikli", StringComparison.Ordinal),
  "Do vnosa artiklov mora biti mogoce priti z razdelilne strani SAOP.");

// --- 13. Voden in razumljiv delovni potek ---------------------------------
Assert(markup.Contains("aria-label=\"Napredek priprave za SAOP\"", StringComparison.Ordinal),
  "Uporabnik mora ves cas videti, v katerem koraku priprave je.");
foreach (var step in new[] { "Izberi artikle", "Določi spremembe", "Preveri pripravljenost", "Oddaj v čakalno vrsto" })
  Assert(markup.Contains(step, StringComparison.Ordinal), "V napredku manjka uporabnisko poimenovan korak: " + step + ".");
Assert(markup.Contains("saop-items-entry-card", StringComparison.Ordinal)
  && markup.Contains("Ročni vnos", StringComparison.Ordinal)
  && markup.Contains("Uvoz iz Excela", StringComparison.Ordinal),
  "Rocni vnos in Excel morata biti predstavljena kot dve jasni vstopni poti.");

Assert(markup.Contains("id=\"saop-items-field-search\"", StringComparison.Ordinal)
  && markup.Contains("@bind:event=\"oninput\"", StringComparison.Ordinal),
  "Dolg seznam polj potrebuje sprotno iskanje.");
Assert(markup.Contains("ShowLockedFields", StringComparison.Ordinal)
  && markup.Contains("Pokaži tudi polja, ki jih upravlja SAOP", StringComparison.Ordinal),
  "Nepisljiva polja ne smejo ustvarjati hrupa, morajo pa ostati dosegljiva na zahtevo.");
Assert(markup.Contains("Izbranih polj:", StringComparison.Ordinal),
  "Uporabnik mora videti obseg tabele, preden se odpre siroka mreza.");

Assert(markup.Contains("Ta gumb še ne pošlje v SAOP", StringComparison.Ordinal),
  "Glavno dejanje mora neposredno povedati, da gre najprej samo v cakalno vrsto.");
Assert(markup.Contains("<details class=\"saop-items-session-details\"", StringComparison.Ordinal),
  "Dnevnik seje mora ostati dosegljiv, vendar ne sme prevladati v osnovnem poteku.");
Assert(markup.Contains("Tehnični predogled XML", StringComparison.Ordinal),
  "XML mora biti jasno oznacen kot tehnicna podrobnost, ne kot uporabnikov naslednji korak.");

Assert(css.Contains(".saop-items-progress", StringComparison.Ordinal)
  && css.Contains(".saop-items-entry-grid", StringComparison.Ordinal)
  && css.Contains("@media (max-width: 760px)", StringComparison.Ordinal),
  "Novi potek potrebuje lastno odzivno postavitev za napredek in vstopni poti.");

Console.WriteLine("F10 SAOP artikli contract PASS.");

static void Assert(bool condition, string message)
{
  if (!condition) throw new InvalidOperationException(message);
}

static bool HasCssClass(string markup, string cssClass)
{
  foreach (Match match in Regex.Matches(markup, "class=\"([^\"]*)\""))
    if (match.Groups[1].Value.Split(' ', StringSplitOptions.RemoveEmptyEntries).Contains(cssClass, StringComparer.Ordinal)) return true;
  return false;
}

static string FindRoot()
{
  var current = new DirectoryInfo(Directory.GetCurrentDirectory());
  while (current is not null)
  {
    if (Directory.Exists(Path.Combine(current.FullName, "sql", "migrations"))) return current.FullName;
    current = current.Parent;
  }

  throw new InvalidOperationException("PIM_Solution ni najden.");
}
