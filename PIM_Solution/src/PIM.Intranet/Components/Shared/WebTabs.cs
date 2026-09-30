namespace PIM.Intranet.Components.Shared;

/// <summary>
/// Zavihki izhoda na splet (#25, lastnik 2026-09-29): namesto osmih enakovrednih gumbov na vrhu /splet
/// ima vsaka stran področja iste zavihke. Ključi pravic so obstoječi view.web.* (PimAccessCatalog), zato
/// vloga, ki strani ne sme videti, zavihka ne vidi. Varovalke in validacija nista stran tega področja in
/// ostaneta tihi povezavi na Pregledu.
/// </summary>
public static class WebTabs
{
  public static readonly IReadOnlyList<PimTab> Tabs =
  [
    // Kratki napisi: pri 1024 px mora biti vseh pet zavihkov vidnih brez vodoravnega drsnika (#25).
    new("overview", "Pregled", "splet", "Stanje katalog.csv", PermissionKey: "view.web.overview"),
    new("withdrawals", "Umaknjeni", "splet/umaknjeni", "Kaj je šlo s spleta", PermissionKey: "view.web.withdrawals"),
    new("mismatches", "Neskladja", "splet/neskladja", "IQ in Vidadria", PermissionKey: "view.web.mismatches"),
    new("catalog", "Nadzor kataloga", "splet/katalog", "Izključitve, odprodaja", PermissionKey: "view.web.catalog"),
    new("build", "Predogled izvoza", "splet/izvoz", "Podatki po profilu", PermissionKey: "view.web.build"),
  ];
}
