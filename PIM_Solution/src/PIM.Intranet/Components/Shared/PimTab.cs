namespace PIM.Intranet.Components.Shared;

/// <param name="Key">Kljuc aktivnega zavihka; ujema se z <c>Active</c> na <c>PimTabs</c>.</param>
/// <param name="Label">Vidno ime zavihka.</param>
/// <param name="Href">Base-relativna pot brez zacetne posevnice (zaradi IIS /PIM).</param>
/// <param name="Description">Kratek opis; null ohrani ozek zavihek.</param>
/// <param name="Count">Stevilo za zavihkom, ze oblikovano; vedno iz baze.</param>
public sealed record PimTab(string Key, string Label, string Href, string? Description = null, string? Count = null, string? PermissionKey = null);

/// <summary>Skupen seznam zavihkov za vsa podrocja izhoda v SAOP (Pregled/Artikli/Vrsta/Zgodovina),
/// da se ne podvaja po straneh in da so vse vedno v istem vrstnem redu.</summary>
public static class SaopTabs
{
  // Vrstni red je uporabnikova zahteva: Artikli je delo, ki se z njim dejansko zacne, Pregled
  // (samo stevci po entitetah) pa je najmanj uporabljen, zato je zadnji.
  public static readonly IReadOnlyList<PimTab> Tabs =
  [
    new("items", "Artikli", "saop/artikli", "Nov artikel in sprememba", PermissionKey: "tab.saop.items"),
    new("queue", "Čakalna vrsta", "outbound", "Odobritev in ponovni poskus", PermissionKey: "tab.saop.queue"),
    new("history", "Zgodovina", "saop/zgodovina", "Operacija in odgovor ERP", PermissionKey: "tab.saop.history"),
    new("overview", "Pregled", "saop", "Stanje po entitetah", PermissionKey: "tab.saop.overview"),
  ];
}

/// <summary>
/// Skupen seznam zavihkov za vsa podrocja kakovosti. Prej so bile te strani dosegljive samo
/// prek kartic-gumbov na dnu /kakovost ("Kje popraviti"); uporabnik je zahteval zavihke po
/// zgledu SAOP-a in odstranitev kartic ter zavihka "Pregled", ker je isto videti na nadzorni
/// plosci. Karantena in napake validacije so prva dva zavihka, ker se z njima delo dejansko
/// zacne — urednik gre po sklopih (najprej karantena, potem napake).
/// </summary>
public static class QualityTabs
{
  public static readonly IReadOnlyList<PimTab> Tabs =
  [
    new("artikli", "Artikli za popravilo", "kakovost/artikli", "Pripravljenost in blokade po izhodnih kanalih", PermissionKey: "tab.quality.products"),
    new("napake", "Napake validacije", "kakovost/napake", "Izdelek obstaja, a mu manjka zahtevano polje", PermissionKey: "tab.quality.validation"),
    new("karantena", "Napake uvoza", "kakovost/karantena", "Tehnični zapis, ki ga preslikava ni sprejela", PermissionKey: "tab.quality.quarantine"),
    new("prevodi", "Manjkajoči prevodi", "kakovost/prevodi", "Vrednost obstaja, prevoda pa ne", PermissionKey: "tab.quality.translations"),
    new("mapiranje", "Nepreslikane kategorije", "kakovost/kategorije", "Dobaviteljeva pot brez naše kategorije", PermissionKey: "tab.quality.categories"),
    new("pokategorijah", "Po kategorijah", "kakovost?pogled=kategorije", "Odprte zahteve po kategoriji", PermissionKey: "tab.quality.by-category"),
  ];
}

/// <summary>
/// Registri, ki določajo pot podatka od vhodnega elementa do poslovnega izhoda. Vrstni red je
/// namenoma enak dejanskemu toku: najprej preslikava vira, nato poenotenje vrednosti, preverjanje
/// obveznosti in šele zatem pravila, ki izdelajo vsebino oziroma komercialni rezultat.
/// </summary>
public static class RulesTabs
{
  public static readonly IReadOnlyList<PimTab> Tabs =
  [
    new("mappings", "Izvor in polja", "pravila/preslikave", "Od kod pride podatek in kam se zapiše", PermissionKey: "view.rules.mappings"),
    new("dictionary", "Slovar vrednosti", "pravila/slovar", "Prevodi in poenotenje vrednosti", PermissionKey: "view.rules.dictionary"),
    new("validation", "Validacija", "pravila/validacija", "Kaj je obvezno in kaj blokira", PermissionKey: "view.rules.validation"),
    new("titles", "Spletni nazivi", "pravila/nazivi", "Sestava, predogled in zapis nazivov", PermissionKey: "view.rules.titles"),
    new("commercial", "Komercialna pravila", "pravila-popustov", "Popusti, pragovi in poštnina", PermissionKey: "view.rules.discounts"),
  ];
}

/// <summary>
/// Zavihki nadzora (prenova 2026-09-22, blok 7): ena stran Nadzor z eno vrstico na posel; koraki,
/// faze, izpis, urnik in postopki posla so na njegovi strani (sistem/posel/&lt;KEY&gt;), ne na ločenih
/// zavihkih. Uporabnik je hotel vsak korak videti na enem mestu, zato so Opravila, Zagoni, Alarmi,
/// Izvozi in Zmogljivost odstranjeni. Ostaneta samo samotest in sled sprememb, ki nista posel.
/// </summary>
public static class NadzorTabs
{
  public static readonly IReadOnlyList<PimTab> Tabs =
  [
    new("nadzor", "Nadzor", "sistem", "Ali podatki prihajajo in kje je napaka", PermissionKey: "tab.system.overview"),
    new("samotest", "Samotest", "sistem/samotest", "Rezultati nočnega samotesta", PermissionKey: "view.system.self-test"),
    new("sled", "Sled sprememb", "sistem/sled", "Kdo je kaj spremenil in kdaj", PermissionKey: "view.system.activity"),
  ];
}

/// <summary>
/// Zavihki za upravljanje dostopa in nastavitev — namerno loceno od NadzorTabs: to ni vprasanje
/// "ali sistem dela", ampak "kdo sme kaj in kam gredo datoteke". Uporabnikova zahteva 2026-09-10.
/// </summary>
public static class SistemskeZadeveTabs
{
  public static readonly IReadOnlyList<PimTab> Tabs =
  [
    new("uporabniki", "Uporabniki", "administracija", "Lokalni in domenski računi", PermissionKey: "tab.admin.users"),
    new("vloge", "Vloge", "administracija/vloge", "Dodeljene vloge in dostop", PermissionKey: "tab.admin.roles"),
    new("mape", "Mesta shranjevanja", "administracija/mape", "Kam gredo prevzete datoteke in izvozi", PermissionKey: "tab.admin.paths"),
  ];
}
