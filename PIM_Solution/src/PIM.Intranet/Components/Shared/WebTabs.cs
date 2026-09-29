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
    new("overview", "Pregled", "splet", "Ali je katalog.csv v redu", PermissionKey: "view.web.overview"),
    new("withdrawals", "Umaknjeni s spleta", "splet/umaknjeni", "Kaj je šlo s spleta in zakaj", PermissionKey: "view.web.withdrawals"),
    new("mismatches", "Neskladja med podjetji", "splet/neskladja", "Ista šifra v IQ in Vidadrii", PermissionKey: "view.web.mismatches"),
    new("catalog", "Nadzor kataloga", "splet/katalog", "Izključitve in odprodaja", PermissionKey: "view.web.catalog"),
    new("build", "Predogled izvoza", "splet/izvoz", "Trenutni podatki po profilu", PermissionKey: "view.web.build"),
  ];
}
