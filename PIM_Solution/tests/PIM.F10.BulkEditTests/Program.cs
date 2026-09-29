using System.Text.RegularExpressions;
using PIM.Intranet.Components.Shared;
using PIM.Intranet.Services;
using PIM.Operations;

// #10: paketno urejanje na seznamu izdelkov (/izdelki).
//
// Kaj pogodba varuje (CLAUDE.md §2, PIM_DOBRE_PRAKSE §9.3–9.6):
//   - izbira ima tri načine (stran, vse po filtru, nič) in skupni gradnik (PimRowSelection + PimBulkBar);
//   - množična sprememba pokaže število in obseg ter prej → potem, preden kaj zapiše;
//   - zapis gre skozi uvoz delovnega lista (preverjanje, zgodovina ops.ImportRun, povratek na /uvozi);
//   - polj SAOP paketno urejanje ne ponuja in ne pošilja (rdeča črta: nič samodejno v SAOP);
//   - pravico preveri servis (CatalogWrite), ne samo skrit gumb.
// Brez baze: DB del uvoza (ProductWorkbookTests) se tu ne zaganja.

var failures = 0;
void Check(bool condition, string message)
{
  if (condition) return;
  failures++;
  Console.Error.WriteLine("NAPAKA: " + message);
}

var root = FindRoot();
string Source(params string[] parts) => File.ReadAllText(Path.Combine([root, "src", "PIM.Intranet", .. parts]));
var page = Source("Components", "Pages", "Products.razor");
var bar = Source("Components", "Shared", "PimBulkBar.razor");
var helper = Source("Services", "ProductBulkEdit.cs");
var barCss = Source("Components", "Shared", "PimBulkBar.razor.css");

// --- 1. Skupni gradnik izbire in vrstica množičnih dejanj ------------------------------------
Check(page.Contains("PimRowSelection<SelectedItem>", StringComparison.Ordinal), "Seznam mora uporabiti skupni model izbire PimRowSelection.");
Check(page.Contains("<PimBulkBar", StringComparison.Ordinal), "Seznam mora uporabiti skupno vrstico množičnih dejanj PimBulkBar.");
Check(!page.Contains("Dictionary<string, SelectedItem> Selected", StringComparison.Ordinal), "Stari lastni slovar izbire ne sme ostati poleg skupnega modela.");
Check(page.Contains("record SelectedItem(int OrganizationId, string OrganizationName, string ItemId)", StringComparison.Ordinal),
  "Izbrana vrstica mora nositi podjetje (šifra je enolična samo znotraj podjetja).");
Check(Regex.IsMatch(page, "aria-label=\"Izberi izdelek @row.ItemId\""), "Vsaka kljukica mora povedati, kateri izdelek izbira.");
Check(bar.Contains("aria-label=\"Označi vse na tej strani\"", StringComparison.Ordinal), "»Označi vse na strani« mora imeti aria-label.");
Check(bar.Contains("ustrezajo filtru", StringComparison.Ordinal), "Vrstica mora ponuditi »vse, ki ustrezajo filtru (N)«.");
Check(bar.Contains("Izbranih", StringComparison.Ordinal) && Regex.IsMatch(bar, "role=\"status\""), "Število izbranih mora biti vidno in razglašeno (role=status).");
Check(bar.Contains("Počisti izbiro", StringComparison.Ordinal), "Izbiro mora biti mogoče počistiti.");
Check(Regex.IsMatch(bar, "role=\"region\"[^>]*aria-label="), "Vrstica množičnih dejanj je poimenovana regija.");
Check(barCss.Contains(":focus-visible", StringComparison.Ordinal), "Vrstica mora imeti viden fokus.");
Check(!Regex.IsMatch(barCss, "#[0-9a-fA-F]{3,6}\\b"), "Slog vrstice uporablja žetone --pim-*, ne trdih barv.");
Check(page.Contains("Selection.UpdateFilter(Href(page: 1)", StringComparison.Ordinal),
  "»Vse po filtru« se mora ob drugem filtru sprostiti (podpis filtra brez strani).");

// --- 2. Potrditev s številom in obsegom, prej → potem ----------------------------------------
Check(page.Contains("Nastaviti <strong>", StringComparison.Ordinal) && page.Contains("v podjetju", StringComparison.Ordinal),
  "Potrditev mora povedati polje, vrednost, število in podjetje (§9.6).");
Check(page.Contains("Potrdi in zapiši (@summary.Products", StringComparison.Ordinal), "Gumb potrditve mora nositi število izdelkov.");
Check(page.Contains("Prej → potem", StringComparison.Ordinal) && Regex.IsMatch(page, "<caption>Prej"), "Predogled prej → potem mora biti tabela z napisom.");
Check(page.Contains("LosingWebSite", StringComparison.Ordinal), "Predogled mora opozoriti na izdelke, ki izgubijo spletišče (251).");
Check(page.Contains("uvozi/{historyId}", StringComparison.Ordinal), "Izid mora voditi na zapis v zgodovini uvozov (povratek).");
Check(page.Contains("Gate.Imports", StringComparison.Ordinal), "Predogled in zapis gresta skozi vrata za uvoze (HeavyWorkGate).");
Check(page.Contains("CancelEdit", StringComparison.Ordinal), "Predogled se mora dati preklicati.");
Check(Regex.IsMatch(page, "@if \\(CanEditCatalog\\)\\s*\\{\\s*<button[^>]*OpenEditAsync"), "»Nastavi polje« vidi samo urednik kataloga ali skrbnik.");
Check(page.Contains("CanEditCatalog = user.IsInRole(\"ADMIN\") || user.IsInRole(\"CATALOG_EDITOR\");", StringComparison.Ordinal),
  "Komerciala ne sme videti »Nastavi polje« (samo S-popust).");

// --- 3. Zapis skozi uvoz, zgodovino in pravico; nič v SAOP ----------------------------------
Check(helper.Contains("workbook.PreviewAsync(", StringComparison.Ordinal), "Predogled mora iti skozi ProductWorkbookService.PreviewAsync.");
Check(helper.Contains("workbook.ApplyAsync(", StringComparison.Ordinal), "Zapis mora iti skozi ProductWorkbookService.ApplyAsync.");
Check(helper.Contains("history.RecordAsync(ImportKinds.Products", StringComparison.Ordinal), "Zapis mora pustiti zgodovino uvoza (ops.ImportRun).");
Check(helper.Contains("guard.RequireAsync(PimPolicies.CatalogWrite)", StringComparison.Ordinal), "Pravico mora preveriti servis (CatalogWrite).");
Check(helper.Contains("AfterChangeByItemsAsync", StringComparison.Ordinal), "Po zapisu mora teči preverjanje umika s spleta (251).");
foreach (var source in new[] { page, helper })
  foreach (var forbidden in new[] { "SaopWriteService", "EnqueueAsync", "ApproveBatchAsync", "PimWriteGuard.Trusted" })
    Check(!source.Contains(forbidden, StringComparison.Ordinal), "Paketno urejanje ne sme pisati v SAOP ali mimo pravic: " + forbidden);

// --- 4. Logika: katera polja so na voljo ----------------------------------------------------
var sites = new List<WorkbookWebSite>
{
  new("svetila_si", "Svetila.si", "svetila_si"),
  new("svetila_si_en", "Svetila.si (ANG)", "svetila_si"),
  new("videlektro", "Videlektro", "videlektro"),
};
var definition = ProductWorkbookContract.Build(new(
  [new SaopWritableField("Product.UoM", "UoM", "Enota mere", "text")],
  sites, ["WEB_TITLE", "DESCRIPTION"], ["sl", "en"],
  [new WorkbookAttribute("COLOR_TEMP", "Barva svetlobe", InSet: true)],
  [new WorkbookFlag("PACK_ORDER", "Pakirno naročanje")]));
var editable = ProductBulkEdit.EditableColumns(definition, sites);
var keys = editable.Select(column => column.FieldKey).ToHashSet(StringComparer.Ordinal);
Check(!keys.Contains("Product.UoM"), "Polje SAOP (Enota mere) ne sme biti v izbiri paketnega urejanja (PRIVZETO ZA NOČ).");
Check(editable.All(column => column.Target == ProductWorkbookTarget.Pim), "V izbiri so samo podatki PIM.");
Check(!keys.Contains(ProductWorkbookContract.PackagingCodeField), "S-popust ima svoje dejanje (BusinessWrite), ne »Nastavi polje«.");
Check(!keys.Contains(ProductWorkbookContract.ImagesField) && !keys.Contains(ProductWorkbookContract.DocumentsField),
  "Slike in dokumenti niso v paketnem polju (seznam izdelka v vrstnem redu).");
Check(keys.Contains("ProductText.WEB_TITLE.sl"), "Spletni naziv mora biti na voljo.");
Check(keys.Contains("ProductAttribute.COLOR_TEMP"), "Atribut mora biti na voljo.");
Check(keys.Contains("ProductFlag.PACK_ORDER"), "Oznaka mora biti na voljo.");
Check(keys.Contains(ProductWorkbookContract.WebSitesField), "Spletišča morajo biti na voljo.");
Check(keys.Contains(ProductWorkbookContract.CategoryFieldKey("svetila_si")), "Kategorija primarne strani mora biti na voljo.");
Check(!keys.Contains(ProductWorkbookContract.CategoryFieldKey("svetila_si_en")), "Kategorija jezikovne različice se ne ponudi (prevzame primarno).");
Check(ProductBulkEdit.CategorySite(editable.First(column => column.FieldKey == ProductWorkbookContract.CategoryFieldKey("videlektro")), sites)?.Code == "videlektro",
  "Stolpec kategorije mora vedeti, katero spletišče piše.");

// --- 5. Logika: zvezek, ki ga uvoz prebere nazaj -------------------------------------------
var attribute = editable.First(column => column.FieldKey == "ProductAttribute.COLOR_TEMP");
var targets = new List<ProductBulkEdit.Target>
{
  new(2, "IQ Lighting", "0001"), new(2, "IQ Lighting", "0002"), new(2, "IQ Lighting", "0001"), new(3, "Vidadria", "0001"),
};
using (var file = new MemoryStream(ProductBulkEdit.BuildWorkbook(attribute, targets, "3000 K")))
{
  var sheet = WorkbookTable.ReadMatchingSheets(file, ProductWorkbookContract.HeaderHints, out _);
  var matches = ProductWorkbookContract.Match(sheet.Headers, definition);
  Check(matches.Any(match => match.Column?.FieldKey == ProductWorkbookContract.ItemIdField), "Zvezek mora imeti stolpec šifre, ki ga uvoz prepozna.");
  Check(matches.Any(match => match.Column?.FieldKey == ProductWorkbookContract.OrganizationField), "Zvezek mora imeti stolpec podjetja.");
  Check(matches.Any(match => match.Column?.FieldKey == attribute.FieldKey), "Izbrano polje mora uvoz prepoznati kot isto polje.");
  Check(sheet.Rows.Count == 3, $"Dvojnik (isto podjetje + šifra) gre v zvezek enkrat; vrstic je {sheet.Rows.Count}, pričakovane 3.");
  Check(sheet.Rows.All(row => row.Contains("3000 K")), "Vsaka vrstica nosi novo vrednost.");
  Check(sheet.Rows.Any(row => row.Contains("0001") && row.Contains("3")), "Podjetje gre v zvezek kot številka (enolično).");
}

// --- 6. Logika: »Dodaj« k seznamu, povzetek in umik s spleta -------------------------------
var sitesField = ProductWorkbookContract.WebSitesField;
var preview = new ProductWorkbookPreview(
  [
    Row(1, "A", sitesField, "videlektro", "svetila_si"),
    Row(2, "B", sitesField, "videlektro", "svetila_si|videlektro"),
    Row(3, "C", sitesField, "videlektro", null),
  ], [], [], []);
var merged = ProductBulkEdit.MergeAdd(preview, sitesField);
Check(merged.Rows.Count == 2, "»Dodaj«: izdelek, ki ima spletišče že zapisano, odpade.");
Check(merged.Rows.First(row => row.ItemId == "A").PimValues[sitesField] == "svetila_si | videlektro", "»Dodaj«: prej ∪ novo, v tem vrstnem redu.");
Check(merged.Rows.First(row => row.ItemId == "C").PimValues[sitesField] == "videlektro", "»Dodaj« k praznemu: samo novo.");

var replaced = ProductBulkEdit.Summarize(preview, sitesField, selected: 5);
Check(replaced.Products == 3 && replaced.Unchanged == 2, "Povzetek šteje spremenjene in nespremenjene izdelke.");
Check(replaced.LosingWebSite == 2, $"»Zamenjaj« z videlektro: A in B izgubita svetila_si; štetih {replaced.LosingWebSite}.");
Check(ProductBulkEdit.Summarize(merged, sitesField, 3).LosingWebSite == 0, "»Dodaj« nobenemu ne vzame spletišča.");
Check(replaced.ByOrganization.Single().Organization == "IQ Lighting", "Povzetek razdeli po podjetjih.");
Check(replaced.Samples.First().Before == "svetila_si" && replaced.Samples.First().After == "videlektro", "Vzorec pokaže prej → potem.");

Check(ProductBulkEdit.Shown(null, false) == "(prazno)", "Prazno se pokaže kot (prazno).");
Check(ProductBulkEdit.Shown(ProductWorkbookContract.ClearToken, false) == "(izprazni)", "»-« se pokaže kot (izprazni).");
Check(ProductBulkEdit.Shown("1", true) == "Da" && ProductBulkEdit.Shown("0", true) == "Ne", "D/N polje se pokaže kot Da/Ne.");

// --- 7. Model izbire -----------------------------------------------------------------------
var selection = new PimRowSelection<string>();
var pageRows = new[] { new KeyValuePair<string, string>("2|A", "A"), new KeyValuePair<string, string>("2|B", "B") };
selection.UpdateFilter("izdelki?podjetje=2", 340);
Check(selection.IsEmpty && !selection.AllMatching, "Na začetku ni nič izbrano.");
selection.SetPage(pageRows, true);
Check(selection.Count == 2 && selection.AllSelected(pageRows.Select(row => row.Key)), "»Označi vse na strani« izbere vrstice strani.");
selection.SelectAllMatching();
Check(selection.AllMatching && selection.Count == 340 && selection.Items.Count == 0, "»Vse po filtru« je filter (število zadetkov), ne seznam ključev.");
Check(selection.Contains("2|Z"), "Pri »vse po filtru« je izbrana tudi vrstica, ki je ni na strani.");
selection.Toggle("2|A", "A", false, pageRows);
Check(!selection.AllMatching && selection.Count == 1 && selection.Contains("2|B"), "Odkljukana vrstica konča »vse po filtru« in pusti ostale na strani.");
selection.SelectAllMatching();
selection.UpdateFilter("izdelki?podjetje=2&stran=2", 340);
Check(!selection.AllMatching, "Drug filter sprosti »vse po filtru«.");
selection.Toggle("3|X", "X", true);
selection.UpdateFilter("izdelki?podjetje=3", 10);
Check(selection.Contains("3|X"), "Posamezne kljukice živijo čez filtre.");
selection.Clear();
Check(selection.IsEmpty, "Počisti izbiro.");
var empty = new PimRowSelection<string>();
empty.UpdateFilter("izdelki", 0);
empty.SelectAllMatching();
Check(!empty.AllMatching, "Prazen filter ne more biti »vse po filtru«.");

if (failures > 0)
{
  Console.Error.WriteLine($"PIM.F10.BulkEditTests: {failures} napak.");
  return 1;
}
Console.WriteLine("PIM.F10.BulkEditTests: vse trditve drzijo.");
return 0;

static ProductWorkbookRowChange Row(int number, string itemId, string field, string after, string? before) =>
  new(number, 2, "IQ Lighting", itemId,
    new Dictionary<string, string> { [field] = after },
    new Dictionary<string, string>(),
    new Dictionary<string, string?> { [field] = before });

static string FindRoot()
{
  var directory = new DirectoryInfo(AppContext.BaseDirectory);
  while (directory is not null && !File.Exists(Path.Combine(directory.FullName, "PIM.sln")))
    directory = directory.Parent;
  return directory?.FullName ?? throw new InvalidOperationException("PIM.sln ni najden.");
}
