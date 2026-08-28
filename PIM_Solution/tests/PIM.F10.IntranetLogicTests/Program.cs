using PIM.Intranet.Services;

var nw = MediaUrlPolicy.Normalize("//pim.nowodvorski.com/media/files/203.jpg");
Assert(nw.Href == "https://pim.nowodvorski.com/media/files/203.jpg", "NW naslov mora dobiti https:.");
Assert(nw.Note == "Dodan https:", "Popravljeni naslov mora ohraniti sled normalizacije.");

var http = MediaUrlPolicy.Normalize("http://primer.si/slika.jpg");
Assert(http.Href == "http://primer.si/slika.jpg", "HTTP naslova ne smemo tiho nadgraditi.");
Assert(http.Note == "Nešifrirana povezava", "HTTP naslov mora biti označen kot nešifriran.");

var unsafeUrl = MediaUrlPolicy.Normalize("javascript:alert(1)");
Assert(unsafeUrl.Href is null, "Izvedljiva shema ne sme postati povezava.");
Assert(unsafeUrl.Note == "Naslov ni varna spletna povezava", "Nevarna shema mora imeti razlago.");

var empty = MediaUrlPolicy.Normalize(" \u200B ");
Assert(empty.Href is null && empty.Display == "—" && empty.Note == "Naslov ni zapisan", "Prazen naslov mora biti pošteno prazen.");

var trimmed = MediaUrlPolicy.Normalize("  www.primer.si/slika.jpg\uFEFF ");
Assert(trimmed.Href == "https://www.primer.si/slika.jpg", "Presledki in nevidni robni znaki se morajo odstraniti.");

AssertLayers("ERP_L1_SLO", "ERP", true, false, PimValidationLayer.ErpSlo);
AssertLayers("ERP_L1_EU", "ERP", true, false, PimValidationLayer.ErpEuThird);
AssertLayers("ERP_L1_THIRD", "ERP", true, false, PimValidationLayer.ErpEuThird);
AssertLayers("COMMERCIAL_L2", "COMMERCIAL", false, false, PimValidationLayer.Komerciala);
AssertLayers("WEB_svetila_si", "WEB", false, true, PimValidationLayer.Splet);
AssertLayers("WEB_videlektro", "WEB", false, true, PimValidationLayer.Splet);
AssertLayers("ERP_L1", "ERP", false, false, PimValidationLayer.ErpSlo);
AssertLayers("WEB_B2C", "WEB", false, false, PimValidationLayer.Splet);
AssertLayers("SHARED_CORE", "SHARED", true, true,
  PimValidationLayer.ErpSlo, PimValidationLayer.ErpEuThird, PimValidationLayer.Splet);

var now = new DateTime(2026, 8, 27, 12, 0, 0, DateTimeKind.Utc);
Assert(PimFormat.Ago(now.AddHours(-2), now) == "pred 2 h", "Svežina mora imeti enoten zapis ur.");
Assert(PimFormat.Ago(null, now) == "—", "Manjkajoča svežina ne sme postati izmišljen čas.");

// ─── Politika polj kakovosti ───────────────────────────────────────────────
// Ime polja se ne prevaja iz slovarja: register zahtev se spreminja, izmisljen slovar bi se
// z njim razsel. Prevaja se samo predpona entitete, ki pride iz imena kanonicne tabele.
Expect(QualityFieldPolicy.EntityLabel("ProductMedia.Url") == "Medij", "Predpona entitete se prevede.");
Expect(QualityFieldPolicy.EntityLabel("ProductCommercial.CustomsTariff") == "Trgovinski podatki", "Trgovinski podatki so svoja entiteta.");
Expect(QualityFieldPolicy.EntityLabel("Cudno.Polje") == "Cudno", "Neznana predpona ostane, kot je.");
Expect(QualityFieldPolicy.FieldName("ProductText.WEB_TITLE.sl") == "WEB_TITLE.sl", "Ime polja obdrzi jezik.");
Expect(QualityFieldPolicy.FieldName("BrezPike") == "BrezPike", "Koda brez pike ostane cela.");

Expect(QualityFieldPolicy.FixTarget("ProductMedia.Url").Href == "mediji", "Manjkajoca slika se popravi na strani Mediji.");
Expect(QualityFieldPolicy.FixTarget("ProductCategory.CategoryPath").Href == "kakovost/kategorije", "Pot kategorije je stvar preslikave.");
Expect(QualityFieldPolicy.FixTarget("ProductAttribute.CategoryRequired").Href == "kakovost/kategorije", "Zahtevana kategorija je prav tako preslikava, ceprav je zapisana kot lastnost.");
Expect(QualityFieldPolicy.FixTarget("ProductText.WEB_TITLE.en").Href == "kakovost/prevodi", "Besedilo v tujem jeziku je manjkajoc prevod.");
Expect(QualityFieldPolicy.FixTarget("ProductText.WEB_TITLE.sl").Href == "izvozi/mnozicno", "Besedilo v slovenscini ni prevod, ampak manjkajoc vnos.");
Expect(QualityFieldPolicy.FixTarget("Product.EAN").Href == "saop/polja", "Polja izdelka prihajajo iz SAOP.");
Expect(QualityFieldPolicy.FixTarget("Cudno.Polje").Href is null, "Za neznano polje ne izmisljujemo strani.");
Expect(QualityFieldPolicy.IssuesHref("ProductText.WEB_TITLE.sl") == "kakovost/napake?polje=ProductText.WEB_TITLE.sl",
  "Napake polja se odprejo z obstojecim filtrom.");

Console.WriteLine("F10 intranet logic PASS.");

static void AssertLayers(string code, string scope, bool blocksErp, bool blocksWeb, params PimValidationLayer[] expected)
{
  var actual = ValidationLayer.Resolve(code, scope, blocksErp, blocksWeb);
  Assert(actual.SequenceEqual(expected), $"Napačni nivoji za {code}: {string.Join(", ", actual)}.");
}

static void Assert(bool condition, string message)
{
  if (!condition) throw new InvalidOperationException(message);
}

static void Expect(bool condition, string message)
{
  if (condition) return;
  Console.Error.WriteLine("NAPAKA: " + message);
  Environment.Exit(1);
}
