using PIM.Intranet.Services;

// Pogodba strani medijev, 2026-08-27.
//
// Zakaj obstaja: stran je prikazovala samo slike, stevilke medijev je nosila v stirih velikih
// karticah nad seznamom, predogledi pa so bili sestavljeni prek RenderTreeBuilder in zato brez
// oznake za obsegno CSS (`b-...`). Slika je zato zrasla v naravno velikost in razbila tabelo.
// Ta test drzi vse tri odlocitve: vrsta medija je izpeljana enotno, stevilke so filtri in ne
// okras, predogled pa je pravi razclenjevalni izpis, ki ga obsegni CSS lahko omeji.

var root = FindRoot();
var pages = Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages");
var services = Path.Combine(root, "src", "PIM.Intranet", "Services");
var page = Read(Path.Combine(pages, "Media.razor"));
var pageCss = Read(Path.Combine(pages, "Media.razor.css"));
var catalog = Read(Path.Combine(services, "CatalogReadService.cs"));

// ─── 1. Vrsta medija: ena sama razvrstitev za C# in za SQL ──────────────────
Assert(MediaKindPolicy.Classify("https://primer.si/slika.jpg", "PRIMARY") == MediaKindPolicy.ImageCode, "Koncnica .jpg je slika.");
Assert(MediaKindPolicy.Classify("https://primer.si/film.mp4", "PRIMARY") == MediaKindPolicy.VideoCode, "Koncnica .mp4 je video.");
Assert(MediaKindPolicy.Classify("https://www.youtube.com/watch?v=abcdefghijk", "PRIMARY") == MediaKindPolicy.VideoCode, "YouTube naslov je video tudi brez koncnice.");
Assert(MediaKindPolicy.Classify("https://primer.si/navodila.pdf", "PRIMARY") == MediaKindPolicy.DocumentCode, "Koncnica .pdf je dokument.");
Assert(MediaKindPolicy.Classify("https://primer.si/slika.jpg?w=800", "PRIMARY") == MediaKindPolicy.ImageCode, "Poizvedbeni niz ne sme skriti koncnice.");
Assert(MediaKindPolicy.Classify("https://primer.si/brez-koncnice", "VIDEO") == MediaKindPolicy.VideoCode, "Vloga pove vrsto, kadar koncnice ni.");
Assert(MediaKindPolicy.Classify("https://primer.si/brez-koncnice", "NAVODILA") == MediaKindPolicy.DocumentCode, "Vloga navodil je dokument.");
Assert(MediaKindPolicy.Classify("https://primer.si/brez-koncnice", "MAIN") == MediaKindPolicy.ImageCode, "Glavna vloga brez koncnice ostane slika.");
Assert(MediaKindPolicy.Classify("https://primer.si/karkoli", "XY") == MediaKindPolicy.OtherCode, "Nerazpoznaven medij pade v DRUGO.");
Assert(MediaKindPolicy.Classify(null, null) == MediaKindPolicy.OtherCode, "Prazen naslov ne sme vreci izjeme.");
// Dobavitelji posiljajo tudi tehnicne priloge; brez teh dveh je 1.234 zapisov padlo v DRUGO.
Assert(MediaKindPolicy.Classify("https://cdn.primer.si/3dfiles/BH85-XXXX1.rar", "3D datoteka") == MediaKindPolicy.DocumentCode, "Arhiv s 3D datoteko je dokument.");
Assert(MediaKindPolicy.Classify("https://cdn.primer.si/datasheet/BA07.html", "Podatkovni list") == MediaKindPolicy.DocumentCode, "Slovenska vloga »Podatkovni list« je dokument.");

Assert(MediaKindPolicy.VideoPoster("https://www.youtube.com/watch?v=abcdefghijk") is not null, "YouTube video mora dobiti sliko predogleda.");
Assert(MediaKindPolicy.VideoPoster("https://primer.si/film.mp4") is null, "Navadna datoteka nima izpeljanega predogleda.");
Assert(MediaKindPolicy.FileName("https://primer.si/pot/slika.jpg?w=1") == "slika.jpg", "Ime datoteke je berljiva oznaka ploscice.");
Assert(MediaKindPolicy.Extension("https://primer.si/pot/NAVODILA.PDF") == ".pdf", "Koncnica se bere neobcutljivo na velikost crk.");

var sql = MediaKindPolicy.SqlKindExpression("media.Url", "media.Role");
foreach (var code in new[] { MediaKindPolicy.ImageCode, MediaKindPolicy.VideoCode, MediaKindPolicy.DocumentCode, MediaKindPolicy.OtherCode })
  Assert(sql.Contains("N'" + code + "'", StringComparison.Ordinal), "SQL izraz mora vrniti vrsto " + code + ".");
Assert(sql.Contains(".mp4", StringComparison.Ordinal) && sql.Contains(".pdf", StringComparison.Ordinal) && sql.Contains("youtube", StringComparison.Ordinal),
  "SQL izraz mora nastati iz istih seznamov kot razvrstitev v C#, sicer se filter in ploscica razideta.");

// ─── 2. Stevilke niso vec okras nad seznamom ───────────────────────────────
Assert(!page.Contains("class=\"kpi-grid\"", StringComparison.Ordinal),
  "Stiri velike stevilcne kartice nad seznamom morajo izginiti — uporabnik jih je zavrnil.");
Assert(page.Contains("media-meta", StringComparison.Ordinal), "Stevilke morajo dobiti drobno mesto v glavi strani.");
// 2026-09-22: »pogled=BREZ_SLIKE« seznam izdelkov ne pozna in ga je tiho odprl brez filtra.
Assert(page.Contains("izdelki?slika=NO&aktivnost=ACTIVE", StringComparison.Ordinal), "Stevilo izdelkov brez slike mora ostati delovna povezava.");
var productsPage = Read(Path.Combine(pages, "Products.razor"));
Assert(productsPage.Contains("Name = \"slika\"", StringComparison.Ordinal) && productsPage.Contains("Name = \"aktivnost\"", StringComparison.Ordinal),
  "Seznam izdelkov mora brati filtra, na katera kaze povezava z medijev.");

// ─── 3. Slike IN dokumenti: en predal, dve tabeli ──────────────────────────
Assert(catalog.Contains("canon.ProductDocument", StringComparison.Ordinal) && catalog.Contains("UNION ALL", StringComparison.Ordinal),
  "Stran mora brati tudi canon.ProductDocument — sicer dokumentov ni videti nikjer.");
Assert(catalog.Contains("N'DOKUMENT'", StringComparison.Ordinal) && catalog.Contains("N'MEDIJ'", StringComparison.Ordinal),
  "Vsak zapis mora povedati, iz katere tabele je prisel.");
Assert(catalog.Contains("public string Key =>", StringComparison.Ordinal),
  "ProductMediaId in ProductDocumentId trcita — vrstica potrebuje enolicen kljuc cez oba vira.");
Assert(page.Contains("row.Title", StringComparison.Ordinal), "Naziv dokumenta je edini berljiv opis zapisa in mora biti viden.");

// ─── 4. Vrste medijev so vidni filtri s svojimi stevci ─────────────────────
Assert(page.Contains("KindCounts", StringComparison.Ordinal), "Stevci po vrsti medija morajo priti iz baze.");
Assert(catalog.Contains("GetMediaKindCountsAsync", StringComparison.Ordinal), "Bralni model mora znati presteti medije po vrsti.");
Assert(catalog.Contains("MediaKindPolicy.SqlKindExpression", StringComparison.Ordinal), "Poizvedba mora uporabiti skupni izraz vrste, ne svojega.");
// Stran se na vrsto sklicuje prek konstant razvrscevalnika, ne prek prepisane besede: prepisan
// niz bi se lahko razsel s SQL izrazom, ki filtrira in steje.
foreach (var name in new[] { "MediaKindPolicy.VideoCode", "MediaKindPolicy.DocumentCode" })
  Assert(page.Contains(name, StringComparison.Ordinal), "Stran mora ponuditi vrsto prek " + name + " — ne samo slik.");
Assert(page.Contains("Name = \"vrsta\"", StringComparison.Ordinal), "Izbrana vrsta mora biti deljiva prek naslova.");

// ─── 5. Pametno iskanje ────────────────────────────────────────────────────
Assert(catalog.Contains("SearchTerms", StringComparison.Ordinal), "Iskanje mora razbiti vnos na besede in zahtevati vse.");
Assert(catalog.Contains("LikeSafe", StringComparison.Ordinal), "Vzorec LIKE nastane v kodi, zato morajo nadomestni znaki iz vnosa ostati navadni znaki.");
Assert(page.Contains("Task.Delay", StringComparison.Ordinal), "Iskanje se mora sprozati samo od sebe, z zamikom.");
Assert(!page.Contains("Uporabi filtre", StringComparison.Ordinal), "Gumb za potrditev filtrov ni vec potreben, ce se filtri uveljavijo sami.");
Assert(page.Contains("Počisti", StringComparison.Ordinal), "Uporabnik mora imeti en klik do praznih filtrov.");

// ─── 6. Predogled mora biti pravi izpis, ki ga obsegni CSS lahko omeji ─────
Assert(!page.Contains("builder.OpenElement", StringComparison.Ordinal),
  "Predogledi ne smejo nastajati prek RenderTreeBuilder: taki elementi nimajo oznake obsegnega CSS in slika zraste cez stran.");
Assert(pageCss.Contains("aspect-ratio", StringComparison.Ordinal) && pageCss.Contains("object-fit", StringComparison.Ordinal),
  "Ploscica mora imeti fiksno razmerje in omejeno sliko.");
Assert(page.Contains("loading=\"lazy\"", StringComparison.Ordinal), "Slike se nalagajo lenobno.");
Assert(page.Contains("media-lightbox", StringComparison.Ordinal), "Klik na sliko mora ponuditi povecan predogled.");

// PDF: prva stran se izrise v povecanem predogledu, brez novega zavihka. Vgrajevanje je odvisno
// od tujega streznika, zato mora imeti <object> nadomestno vsebino s povezavo na izvirnik.
Assert(MediaKindPolicy.IsInlineViewable("https://primer.si/navodila.pdf"), "PDF zna brskalnik pokazati kar v strani.");
Assert(!MediaKindPolicy.IsInlineViewable("https://primer.si/model.rar"), "Arhiva ne zna prikazati noben brskalnik.");
Assert(MediaKindPolicy.InlineViewerHref("https://primer.si/a.pdf").Contains("toolbar=0", StringComparison.Ordinal),
  "Orodna vrstica bralnika v majhnem oknu samo jemlje prostor.");
Assert(page.Contains("<object", StringComparison.Ordinal) && page.Contains("application/pdf", StringComparison.Ordinal),
  "Prva stran PDF se mora izrisati v samem oknu predogleda.");
var objectStart = page.IndexOf("<object", StringComparison.Ordinal);
var objectEnd = page.IndexOf("</object>", StringComparison.Ordinal);
Assert(objectStart > 0 && objectEnd > objectStart
  && page[objectStart..objectEnd].Contains("Odpri izvirnik", StringComparison.Ordinal),
  "Ce streznik dobavitelja vgrajevanje zavrne, mora znotraj <object> ostati povezava na izvirnik.");
Assert(page.Contains("[Authorize", StringComparison.Ordinal), "Stran medijev zahteva prijavo.");

// ─── Popravki medijev 2026-08-28 ──────────────────────────────────────────────────────────

// E1: dokument pokaze prvo stran, ne ikone in napisa PDF. Prve strani ne rise streznik —
// vgrajen je izvirni dokument, prikaz prevzame brskalnik, nadomestna vsebina ostane ikona.
Assert(page.Contains("class=\"preview-document\"", StringComparison.Ordinal),
  "Dokument v mrezi mora pokazati prvo stran, ne ikone.");
Assert(page.Contains("MediaKindPolicy.InlineViewerHref(url.Href)", StringComparison.Ordinal),
  "Predogled dokumenta mora uporabiti isti naslov kot lightbox.");
Assert(page.Contains("type=\"application/pdf\"", StringComparison.Ordinal),
  "Predogled mora povedati vrsto vsebine, sicer brskalnik ne ve, kaj rise.");
Assert(pageCss.Contains(".preview-document", StringComparison.Ordinal), "Manjka slog predogleda dokumenta.");
Assert(pageCss.Contains("pointer-events: none", StringComparison.Ordinal),
  "Klik na predogled mora odpreti lightbox, ne notranjega bralnika PDF.");

// E2: kontrola »Stanje naslova« odpade — uporabnik je povedal, da ne pove nicesar uporabnega.
Assert(!page.Contains("id=\"media-address\"", StringComparison.Ordinal),
  "Filtra stanja naslova na zaslonu ni vec.");
Assert(!page.Contains("Vsa stanja naslovov", StringComparison.Ordinal), "Napis »Vsa stanja naslovov« je odpisan.");

// E3: »Dodan https:« je sled popravka, ne tezava; na zaslon ne sodi.
Assert(!page.Contains("naslovov brez sheme", StringComparison.Ordinal),
  "Stevec naslovov brez sheme je odpisan: uporabnika ne zanima, da smo dodali shemo.");
// Namig ob prehodu z misko (title) sme nositi celo opombo; izpisana vsebina ne.
foreach (var raw in new[] { ">@url.Note<", ">@selectedUrl.Note<" })
  Assert(!page.Contains(raw, StringComparison.Ordinal),
    "Opomba naslova se ne izpisuje surovo; skozi MediaUrlPolicy.VisibleNote gre: " + raw);
Assert(System.Text.RegularExpressions.Regex.Matches(page, @"MediaUrlPolicy\.VisibleNote\(").Count >= 4,
  "Vsa mesta, ki izpisujejo opombo naslova, morajo iti skozi VisibleNote.");

var urlPolicy = Read(Path.Combine(root, "src", "PIM.Intranet", "Services", "MediaUrlPolicy.cs"));
Assert(urlPolicy.Contains("public static string? VisibleNote(MediaUrl url)", StringComparison.Ordinal),
  "Politika mora imeti eno mesto, ki odloci, katera opomba gre na zaslon.");
Assert(urlPolicy.Contains("AddedHttpsNote", StringComparison.Ordinal) && urlPolicy.Contains("MediaUrl.Note", StringComparison.Ordinal),
  "Opomba mora ostati v modelu za filtriranje, tudi ce se ne izpise.");


/* ─── Nedosegljiva slika ni isto kot manjkajoca (A9, pregled 2026-09-08) ──────
   Slicice so bile bele in nic ni povedalo, zakaj; videti je bilo, kot da izdelek medija nima. */
var mediaPage = File.ReadAllText(Path.Combine(pages, "Media.razor"));
Assert(mediaPage.Contains("Failed.Contains(row.Key)", StringComparison.Ordinal)
    && mediaPage.Contains("preview-broken", StringComparison.Ordinal),
  "Medij, ki se ni nalozil, mora imeti svoj prikaz in ne sme pasti v isto vejo kot medij brez naslova.");
Assert(mediaPage.Contains("HostOf(", StringComparison.Ordinal),
  "Nedosegljiva slika mora povedati, kateri streznik ne odgovarja.");
var mediaCss = File.ReadAllText(Path.Combine(pages, "Media.razor.css"));
Assert(mediaCss.Contains(".preview-fallback.preview-broken", StringComparison.Ordinal),
  "Nedosegljiv medij mora biti viden tudi brez besedila; bela slicica je bila past.");


/* ─── Paketno urejanje medijev (naloga #32) ───────────────────────────────────
   Izbira vrstic + odstrani / na prvo mesto / dodaj sliko ali dokument za izdelke izbranih vrstic. Zapis gre
   skozi uvoz delovnega lista (ops.ImportRun, pim.SaveProductMediaBulk 245, »Povrni« na /uvozi), pravica
   CatalogWrite v servisu. PRIVZETO ZA NOČ: dodajanje obstoječe ohrani, največ 5.000 izdelkov. */
var bulk = Read(Path.Combine(services, "MediaBulkEdit.cs"));
var productBulk = Read(Path.Combine(services, "ProductBulkEdit.cs"));
var contract = Read(Path.Combine(root, "src", "PIM.Operations", "ProductWorkbookContract.cs"));
Assert(mediaPage.Contains("<PimBulkBar", StringComparison.Ordinal) && mediaPage.Contains("PimRowSelection<MediaRow>", StringComparison.Ordinal),
  "Mediji uporabljajo skupni gradnik izbire (PimBulkBar + PimRowSelection), ne svojega.");
Assert(mediaPage.Contains("aria-label=\"Izberi medij", StringComparison.Ordinal) && mediaPage.Contains("new(\"Izbira\")", StringComparison.Ordinal),
  "Vsaka vrstica in ploscica ima potrditveno polje z oznako; tabela ima stolpec izbire.");
Assert(mediaPage.Contains("Guard.AllowsAsync(PimPolicies.CatalogWrite)", StringComparison.Ordinal) && mediaPage.Contains("Samo za branje", StringComparison.Ordinal),
  "Brez pravice so dejanja skrita in stran pove »Samo za branje«.");
Assert(bulk.Contains("guard.RequireAsync(PimPolicies.CatalogWrite)", StringComparison.Ordinal)
    && productBulk.Contains("await guard.RequireAsync(PimPolicies.CatalogWrite);", StringComparison.Ordinal),
  "Pravico preveri servis (predogled in zapis), skrit gumb je samo videz.");
Assert(bulk.Contains("ProductBulkEdit.ApplyAsync(", StringComparison.Ordinal) && bulk.Contains("HistoryTitle", StringComparison.Ordinal)
    && productBulk.Contains("title ?? HistoryTitle", StringComparison.Ordinal),
  "Zapis gre skozi isto pot kot paketno urejanje izdelkov (zgodovina najprej, paketi, povratek) s svojim naslovom na /uvozi.");
Assert(mediaPage.Contains("Pozor: če dobavitelj ta naslov še pošilja", StringComparison.Ordinal),
  "Pred odstranitvijo stran pove, da jo zajem dobavitelja lahko vrne.");
Assert(mediaPage.Contains("uvozi/{historyId}", StringComparison.Ordinal) && mediaPage.Contains("V SAOP se nič ne pošlje", StringComparison.Ordinal),
  "Po zapisu povezava na zapis uvoza (Povrni); stran pove, da nic ne gre v SAOP.");
Assert(contract.Contains($"\"{MediaBulkEdit.ImagesHeader}\", ImagesField", StringComparison.Ordinal)
    && contract.Contains($"\"{MediaBulkEdit.DocumentsHeader}\", DocumentsField", StringComparison.Ordinal),
  "Naslova stolpcev navideznega zvezka se ujemata s pogodbo delovnega lista.");

// Preracun seznama izdelka (vrstni red je pomen: prva slika je glavna).
const string a = "https://x.si/a.jpg", b = "https://x.si/b.jpg", c = "https://x.si/c.jpg";
var abc = new[] { a, b, c };
Assert(MediaBulkEdit.Apply(MediaBulkEdit.Operation.Remove, abc, [b]).SequenceEqual([a, c]), "Odstrani vzame samo izbrani naslov.");
Assert(MediaBulkEdit.Apply(MediaBulkEdit.Operation.Remove, abc, ["HTTPS://X.SI/B.JPG"]).SequenceEqual([a, c]), "Primerjava naslovov je brez razlike v velikosti crk (kot zapis).");
Assert(MediaBulkEdit.Apply(MediaBulkEdit.Operation.MoveFirst, abc, [c, b]).SequenceEqual([b, c, a]), "Na prvo mesto: izbrane v dosedanjem vrstnem redu naprej.");
Assert(MediaBulkEdit.Apply(MediaBulkEdit.Operation.AddDocument, abc, ["https://x.si/n.pdf"]).SequenceEqual([a, b, c, "https://x.si/n.pdf"]), "Dodaj ohrani obstojece in doda na konec.");
Assert(MediaBulkEdit.NewCell(MediaBulkEdit.Operation.AddImage, $"{a} | {b}", [b]) is null, "Ze dodan naslov ni sprememba (izdelek odpade).");
Assert(MediaBulkEdit.NewCell(MediaBulkEdit.Operation.Remove, a, [a]) == "-", "Odstranitev zadnjega naslova izprazni seznam (»-«), ne pusti celice prazne (prazna = ne dotikaj se).");
Assert(MediaBulkEdit.NewCell(MediaBulkEdit.Operation.Remove, null, [a]) is null, "Izdelek brez seznama se ne spremeni.");
Assert(MediaBulkEdit.NewCell(MediaBulkEdit.Operation.MoveFirst, $"{a} | {b}", [a]) is null, "Ze prva slika ni sprememba.");
Assert(MediaBulkEdit.ValidateUrl("https://x.si/navodila.pdf") is null && MediaBulkEdit.ValidateUrl("x.si/a.pdf") is not null
    && MediaBulkEdit.ValidateUrl("ftp://x.si/a.pdf") is not null && MediaBulkEdit.ValidateUrl("https://x.si/a|b.pdf") is not null
    && MediaBulkEdit.ValidateUrl("") is not null && MediaBulkEdit.ValidateUrl("https://x.si/" + new string('a', 1000)) is not null,
  "Naslov mora biti celoten http(s) naslov brez »|« in ne predolg.");
Assert(MediaBulkEdit.Fields(MediaBulkEdit.Operation.Remove).Count == 2 && MediaBulkEdit.Fields(MediaBulkEdit.Operation.AddDocument).Single() == PIM.Operations.ProductWorkbookContract.DocumentsField,
  "Odstrani bere oba seznama, dodaj dokument samo dokumente.");

// Izdelki: vsak enkrat po podjetju (sifra je enolicna samo v podjetju), meja 5.000.
var items = new[]
{
  new MediaBulkEdit.Item(2, "IQ", "A1", a, MediaKindPolicy.ImageCode),
  new MediaBulkEdit.Item(2, "IQ", "a1", b, MediaKindPolicy.ImageCode),
  new MediaBulkEdit.Item(3, "ViD", "A1", c, MediaKindPolicy.ImageCode),
};
Assert(MediaBulkEdit.Products(items).Count == 2, "Isti izdelek z dvema izbranima medijema je en izdelek; ista sifra v drugem podjetju je drug izdelek.");
Assert(MediaBulkEdit.MaxProducts == 5_000, "Meja izdelkov na potrditev je 5.000 (PRIVZETO ZA NOC).");
var tooMany = Enumerable.Range(0, MediaBulkEdit.MaxProducts + 1).Select(index => new MediaBulkEdit.Product(2, "IQ", "X" + index)).ToList();
var refused = false;
try { MediaBulkEdit.BuildWorkbook(MediaBulkEdit.Operation.Remove, tooMany); } catch (InvalidOperationException) { refused = true; }
Assert(refused, "Vec kot 5.000 izdelkov se zavrne z jasnim sporocilom.");
Assert(MediaBulkEdit.BuildWorkbook(MediaBulkEdit.Operation.AddImage, MediaBulkEdit.Products(items), "https://x.si/n.jpg").Length > 0, "Navidezni zvezek nastane; pri dodajanju je v celici dodani naslov (izdelek brez seznama je tudi sprememba).");

// Preracun predogleda: polje brez spremembe odpade, izdelek brez spremembe odpade, SAOP nikoli.
var imagesField = PIM.Operations.ProductWorkbookContract.ImagesField;
var documentsField = PIM.Operations.ProductWorkbookContract.DocumentsField;
var rawPreview = new ProductWorkbookPreview(
[
  new(2, 2, "IQ", "A1", new Dictionary<string, string> { [imagesField] = "-", [documentsField] = "-" }, new Dictionary<string, string>(),
    new Dictionary<string, string?> { [imagesField] = $"{a} | {b}", [documentsField] = null }),
  new(3, 3, "ViD", "A1", new Dictionary<string, string> { [imagesField] = "-", [documentsField] = "-" }, new Dictionary<string, string> { ["X"] = "1" },
    new Dictionary<string, string?> { [imagesField] = a, [documentsField] = null }),
], [], [], []);
var transformed = MediaBulkEdit.Transform(rawPreview, MediaBulkEdit.Operation.Remove,
  (organization, item, field) => organization == 2 ? [b] : ["https://x.si/ni.jpg"]);
Assert(transformed.Rows.Count == 1 && transformed.Rows[0].PimValues.Count == 1 && transformed.Rows[0].PimValues[imagesField] == a
    && transformed.Rows[0].SaopValues.Count == 0,
  "Odstrani: ostane samo izdelek, ki se mu seznam res spremeni, samo spremenjeno polje, brez SAOP.");
var summary = MediaBulkEdit.Summarize(transformed, 2);
Assert(summary.Products == 1 && summary.Unchanged == 1 && summary.Removed == 1 && summary.Added == 0, "Potrditev pove koliko izdelkov in naslovov.");


/* ─── Izbirnik podjetja na medijih (U1, P2-10) ────────────────────────────────
   Napis je govoril o »izbrani organizaciji«, izbrati je ni bilo mogoce. */
Assert(mediaPage.Contains("id=\"media-organization\"", StringComparison.Ordinal),
  "Mediji morajo imeti izbirnik podjetja.");
Assert(!mediaPage.Contains("Mediji izdelkov v izbrani organizaciji", StringComparison.Ordinal),
  "Napis ne sme govoriti o izbiri, ki je ni bilo mogoce narediti.");


/* ─── Vsa aktivna podjetja, cas vnosa, stabilno listanje (2026-09-22) ─────────
   Stran je privzeto odprla DEMO; 82 slik Vidadrie, uvozenih isti dan, se ni dalo najti. */
Assert(mediaPage.Contains("<option value=\"\">Vsa podjetja</option>", StringComparison.Ordinal),
  "Izbirnik podjetja mora ponuditi vsa podjetja.");
Assert(!mediaPage.Contains("GetCurrentOrganizationAsync", StringComparison.Ordinal),
  "Obseg ne sme priti iz GetCurrentOrganizationAsync — ta vedno vrne prvo podjetje po sifri (DEMO).");
// Pogodba je natancen niz: ce se SQL obsega v CatalogReadService.cs preoblikuje, je treba tu posodobiti trditev
// (naloga #111: vrata #94 so tekla na veji, kjer je bila trditev se stara »@OrganizationId IS NULL OR« iz casa pred 264).
// 264 je izraz obsega zapisala kot »@OrganizationId IS NULL AND ... IN (aktivna podjetja) OR = @OrganizationId«; pomen je isti.
Assert(catalog.Contains("organization.IsActive = 1", StringComparison.Ordinal)
    && catalog.Contains("@OrganizationId IS NULL AND product.OrganizationId IN (SELECT aktivno.OrganizationId FROM dbo.OrganizationConfig aktivno WHERE aktivno.IsActive = 1)", StringComparison.Ordinal)
    && catalog.Contains("OR product.OrganizationId = @OrganizationId", StringComparison.Ordinal),
  "Obseg medijev so aktivna podjetja iz dbo.OrganizationConfig, izbira enega je neobvezna.");
Assert(catalog.Contains("media.CreatedUtc", StringComparison.Ordinal) && catalog.Contains("document.CreatedUtc", StringComparison.Ordinal),
  "Slike in dokumenti morajo nositi cas vnosa (migracija 249).");
Assert(catalog.Contains("\"CreatedUtc DESC, ", StringComparison.Ordinal), "Privzeti vrstni red je najnovejsi najprej.");
var orderStart = catalog.IndexOf("static string MediaOrderBy", StringComparison.Ordinal);
var orderEnd = catalog.IndexOf("};", orderStart, StringComparison.Ordinal);
var orderLines = catalog[orderStart..orderEnd].Split('\n').Where(line => line.Contains("=> \"", StringComparison.Ordinal)).ToArray();
// Enolicen kljuc zapisa je (Source, SourceId): oba morata biti v vsakem vrstnem redu, SourceId na koncu.
Assert(orderLines.Length >= 6 && orderLines.All(line => line.Contains("Source", StringComparison.Ordinal)
    && line.TrimEnd().TrimEnd(',').EndsWith("SourceId\"", StringComparison.Ordinal)),
  "Vsak vrstni red se mora koncati z enolicnim kljucem, sicer listanje podvoji ali izpusti zapise.");
Assert(!catalog[orderStart..orderEnd].Contains("_ => \"CreatedUtc DESC, ItemID, OrganizationId, Kind", StringComparison.Ordinal),
  "Privzeti vrstni red ne sme vsebovati izracunane vrste — baza bi jo morala izracunati za vse zapise.");
Assert(mediaPage.Contains("LoadVersion", StringComparison.Ordinal),
  "Star, pocasnejsi odgovor ne sme prepisati rezultatov novega filtra.");
foreach (var id in new[] { "media-host", "media-added", "media-activity" })
  Assert(mediaPage.Contains($"id=\"{id}\"", StringComparison.Ordinal), "Manjka filter " + id + ".");
var migration249 = Read(Path.Combine(root, "sql", "migrations", "249_MedijiCasVnosa.sql"));
Assert(migration249.Contains("history.OldValue IS NULL", StringComparison.Ordinal) && migration249.Contains("BeforeChangeId", StringComparison.Ordinal),
  "Polnitev casa slik mora slediti prepisom naslovov (220) nazaj do pravega vnosa.");

/* ─── Napacni naslovi slik (naloga #9, migracija 312) ─────────────────────────
   Lastnik (#18): pokvarjena je slika sele po 2 neuspehih v razmiku 24 ur; napaka za splet samo brez druge
   delujoce slike; pokvarjene slike ne gredo v katalog.csv. Stran samo bere, filtri v naslovu, listanje v bazi. */
var checksPage = Read(Path.Combine(pages, "MediaUrlChecks.razor"));
var checksService = Read(Path.Combine(root, "src", "PIM.Intranet", "Services", "MediaCheckReadService.cs"));
var migration312 = Read(Path.Combine(root, "sql", "migrations", "312_PreverjanjeSlik.sql"));
Assert(checksPage.Contains("@page \"/mediji/napacni-naslovi\"", StringComparison.Ordinal), "Stran napacnih naslovov slik mora obstajati.");
Assert(page.Contains("mediji/napacni-naslovi", StringComparison.Ordinal), "Mediji morajo voditi na napacne naslove slik.");
foreach (var name in new[] { "podjetje", "isci", "stanje", "streznik", "napaka", "razvrsti", "smer", "stran" })
  Assert(checksPage.Contains($"SupplyParameterFromQuery(Name = \"{name}\")", StringComparison.Ordinal), "Filter mora ziveti v naslovu: " + name);
Assert(checksPage.Contains("<PimPager", StringComparison.Ordinal) && checksPage.Contains("<caption", StringComparison.Ordinal)
    && checksPage.Contains("Počisti filtre", StringComparison.Ordinal) && checksPage.Contains("role=\"status\"", StringComparison.Ordinal),
  "Seznam: strezniško listanje, napis tabele, Pocisti filtre in stevec zadetkov.");
Assert(checksPage.Contains("href=\"izdelki/@row.ProductId\"", StringComparison.Ordinal), "Sifra odpre kartico izdelka.");
Assert(checksPage.Contains("BuildWorkbookAsync(filter)", StringComparison.Ordinal) && checksService.Contains("Take = WorkbookWriter.MaxRows", StringComparison.Ordinal),
  "Izvoz v Excel je natanko ta pogled (isti filter), do meje zvezka.");
Assert(!checksPage.Contains("<form", StringComparison.Ordinal) && !checksService.Contains("ExecuteNonQuery", StringComparison.Ordinal),
  "Stran napacnih naslovov samo bere.");
Assert(migration312.Contains("FailureCount >= 2 AND LastFailedUtc >= DATEADD(HOUR, 24, FirstFailedUtc)", StringComparison.Ordinal),
  "Pokvarjena je slika sele po dveh neuspehih v razmiku 24 ur.");
Assert(migration312.Contains("ELSE mediaCheck.FailureCount END", StringComparison.Ordinal),
  "NI_ODZIVA (429, 5xx, casovna meja) ne sme povecati stevca neuspehov.");
Assert(migration312.Contains("(N'ProductMedia.DelujocaSlika', N'ERROR'), (N'ProductMedia.VseSlikeDelujejo', N'WARNING')", StringComparison.Ordinal),
  "Brez delujoce slike = napaka, ena pokvarjena od vec = opozorilo.");
Assert(migration312.Contains("UrlHash", StringComparison.Ordinal) && !migration312.Contains("ProductMediaId bigint NOT NULL", StringComparison.Ordinal),
  "Izid je vezan na naslov, ne na vrstico slike (zajem XML vrstice zamenja).");
Assert(migration312.Contains("PreverjanjeSlik312", StringComparison.Ordinal) && migration312.Contains("OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows'))", StringComparison.Ordinal),
  "Izpust iz katalog.csv je zamenjava zive definicije GetExportRows (bloki 302-306 ostanejo).");
Assert(MediaCheckQuery.FromQuery(name => name switch { "stanje" => "POKVARJENA", "stran" => "3", "podjetje" => "2", _ => null }) is { State: "POKVARJENA", Skip: 100, OrganizationId: 2 }
    && MediaCheckQuery.FromQuery(name => name == "stanje" ? "IZMISLJENO" : null).State is null,
  "Naslov strani se prebere v filter; neznano stanje se zavrne.");
Assert(MediaCheckQuery.ToQueryString(new MediaCheckFilter(State: "SUMLJIVA", Host: "pim.nowodvorski.com"), 2) == "stanje=SUMLJIVA&streznik=pim.nowodvorski.com&stran=2",
  "Filter se zapise v naslov (deljiva povezava).");
Assert(MediaCheckQuery.IsDescending(new MediaCheckFilter()) && !MediaCheckQuery.IsDescending(new MediaCheckFilter(Sort: "sifra"))
    && MediaCheckQuery.IsDescending(new MediaCheckFilter(Sort: "sifra", Reverse: true)),
  "Privzeto najnovejse preverjanje najprej; sifra narascajoce, obrnjeno zamenja smer.");
Assert(ProductFieldLabels.For("ProductMedia.DelujocaSlika").Contains("Delujoča", StringComparison.Ordinal)
    && QualityFieldPolicy.FixTarget("ProductMedia.DelujocaSlika").Href == "mediji/napacni-naslovi",
  "Napaka validacije »Delujoca slika« ima ime po domace in vodi na napacne naslove slik.");

// ─── #119: napaka nalaganja v dnevnik, »Ponovi«, poizvedbe samo enkrat ──────
// Stran se je pod obremenitvijo nalagala ~60 s (dve casovni meji po 30 s: predupodobitev in
// interaktivno vezje) in pokazala napako, ki je prazen catch ni zapisal nikamor.
Assert(page.Contains("@inject ILogger<Media> Log", StringComparison.Ordinal) && page.Contains("Log.LogError(failure, \"Mediji: seznam ni naložen", StringComparison.Ordinal),
  "Napaka nalaganja medijev mora iti v dnevnik aplikacije z vzrokom.");
Assert(!System.Text.RegularExpressions.Regex.IsMatch(page, @"catch\s*\{"),
  "Media.razor ne sme imeti praznega catch — vzrok napake mora biti zapisan.");
Assert(page.Contains("@onclick=\"RetryAsync\"", StringComparison.Ordinal) && page.Contains(">Ponovi</button>", StringComparison.Ordinal),
  "Ob napaki mora imeti uporabnik gumb »Ponovi«.");
Assert(page.Contains("new InteractiveServerRenderMode(prerender: false)", StringComparison.Ordinal),
  "Brez predupodabljanja — sicer stran vse poizvedbe medijev pozene dvakrat.");
Assert(page.Contains("includeCount: false", StringComparison.Ordinal) && page.Contains("TotalFromKindCounts", StringComparison.Ordinal),
  "Skupno stevilo je vsota stevcev po vrsti, ne se ena poizvedba cez celotno podlago.");
Assert(catalog.Contains("bool includeCount = true", StringComparison.Ordinal),
  "Paketno urejanje (MaxRows) se vedno potrebuje skupno stevilo iz GetMediaAsync.");
Assert(page.Contains("SlowLoadMilliseconds", StringComparison.Ordinal),
  "Pocasno nalaganje mora pustiti opozorilo s casom v dnevniku.");

// ─── #127: vsi filtri v naslovu strani ─────────────────────────────────────
// Klikalnik (#109, #119): podjetje, razvrstitev, vloga, streznik, cas vnosa in stanje izdelka so bili
// samo stanje komponente — povezave ni bilo mogoce deliti, »Nazaj« jih je izgubil.
foreach (var name in new[] { "podjetje", "izdelek", "vrsta", "razvrstitev", "vloga", "streznik", "dodano", "aktivnost" })
{
  Assert(page.Contains("Name = \"" + name + "\"", StringComparison.Ordinal), "Filter »" + name + "« se mora brati iz naslova.");
  Assert(page.Contains("[\"" + name + "\"] =", StringComparison.Ordinal), "Filter »" + name + "« se mora zapisati v naslov.");
}
Assert(page.Contains("Navigation.GetUriWithQueryParameters", StringComparison.Ordinal) && page.Contains("Navigation.NavigateTo(uri, replace: replace)", StringComparison.Ordinal),
  "Naslov se uskladi prek GetUriWithQueryParameters.");
Assert(page.Contains("protected override async Task OnParametersSetAsync()", StringComparison.Ordinal),
  "»Nazaj« v brskalniku mora stran prebrati znova (OnParametersSetAsync).");
Assert(page.Contains("OwnNavigations", StringComparison.Ordinal),
  "Zapozneli povratek lastnega naslova med tipkanjem ne sme povoziti vnosa ali sprozit dvojnega nalaganja.");
Assert(page.Contains("DropUnknownScopeFilters", StringComparison.Ordinal) && page.Contains("UrlNotice", StringComparison.Ordinal),
  "Vloga ali streznik iz povezave, ki ju podjetje nima, se zavrze z obvestilom — ne tiho prazen seznam.");
Assert(page.Contains("ApplyAsync(replaceUrl: true)", StringComparison.Ordinal),
  "Tipkanje v iskanje ne sme polniti zgodovine brskalnika z vsako vmesno besedo.");

Console.WriteLine("PIM.F10.MediaUxTests: vse trditve drzijo.");
return 0;

static void Assert(bool condition, string message)
{
  if (condition) return;
  Console.Error.WriteLine("NAPAKA: " + message);
  Environment.Exit(1);
}

// Naloga #111: manjkajoca datoteka je bila prej tiho prazen niz, zato je padla vsebinska trditev
// (npr. »Obseg medijev ...«) namesto jasne napake. Zdaj test pove, katere datoteke ni.
static string Read(string path) => File.Exists(path)
  ? File.ReadAllText(path)
  : throw new FileNotFoundException("Datoteke, ki jo test preverja, ni: " + path, path);

static string FindRoot()
{
  var directory = new DirectoryInfo(Directory.GetCurrentDirectory());
  while (directory is not null && !Directory.Exists(Path.Combine(directory.FullName, "src", "PIM.Intranet")))
    directory = directory.Parent;
  return directory?.FullName ?? throw new DirectoryNotFoundException("Korena PIM_Solution ni bilo mogoce najti.");
}
