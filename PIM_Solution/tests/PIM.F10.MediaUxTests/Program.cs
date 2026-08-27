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
Assert(page.Contains("izdelki?pogled=BREZ_SLIKE", StringComparison.Ordinal), "Stevilo izdelkov brez slike mora ostati delovna povezava.");

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
Assert(page.Contains("[Authorize", StringComparison.Ordinal), "Stran medijev zahteva prijavo.");

Console.WriteLine("PIM.F10.MediaUxTests: vse trditve drzijo.");
return 0;

static void Assert(bool condition, string message)
{
  if (condition) return;
  Console.Error.WriteLine("NAPAKA: " + message);
  Environment.Exit(1);
}

static string Read(string path) => File.Exists(path) ? File.ReadAllText(path) : string.Empty;

static string FindRoot()
{
  var directory = new DirectoryInfo(Directory.GetCurrentDirectory());
  while (directory is not null && !Directory.Exists(Path.Combine(directory.FullName, "src", "PIM.Intranet")))
    directory = directory.Parent;
  return directory?.FullName ?? throw new DirectoryNotFoundException("Korena PIM_Solution ni bilo mogoce najti.");
}
