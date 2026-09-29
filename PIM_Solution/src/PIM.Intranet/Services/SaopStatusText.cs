namespace PIM.Intranet.Services;

/// <summary>
/// Ena razlaga stanja odhodnega sporočila za SAOP na vseh straneh izhoda (Pregled, Čakalna vrsta,
/// Zgodovina, Razlike). Prej je imela vsaka stran svoj <c>switch</c> in neznano stanje je tiho
/// postalo »V obdelavi« (UX pravilo 10: neznano stanje se izpiše z izvorno vrednostjo).
///
/// Skupine so tisto, kar komercialist sprašuje: kaj čaka mene, kaj je v vrsti, kaj je šlo, kaj je
/// SAOP zavrnil. Ključi skupin gredo v URL (<c>?stanje=napaka</c>), zato so slovenski in kratki;
/// stari naslovi s surovim stanjem (<c>?stanje=Error</c>) se preslikajo v isto skupino.
/// </summary>
public static class SaopStatusText
{
  public const string Waiting = "caka";
  public const string Queued = "vrsta";
  public const string Sent = "poslano";
  public const string Confirmed = "potrjeno";
  public const string Failed = "napaka";
  public const string Rejected = "zavrnjeno";
  public const string Superseded = "nadomesceno";

  /// <summary>Skupina stanja; neznano stanje ostane samo svoja skupina (izvorna vrednost).</summary>
  public static string Group(string status) => status switch
  {
    "PendingApproval" => Waiting,
    "Pending" or "Retry" or "Sending" => Queued,
    "Sent" => Sent,
    "Verified" or "Succeeded" or "Completed" => Confirmed,
    "Error" or "Dead" or "Drift" => Failed,
    "Cancelled" => Rejected,
    "Superseded" => Superseded,
    _ => status,
  };

  /// <summary>Vrednost iz naslova (<c>?stanje=</c>) → skupina; sprejme tudi staro surovo stanje.</summary>
  public static string? NormalizeFilter(string? value)
  {
    if (string.IsNullOrWhiteSpace(value)) return null;
    var trimmed = value.Trim();
    return trimmed.ToLowerInvariant() switch
    {
      Waiting or Queued or Sent or Confirmed or Failed or Rejected or Superseded => trimmed.ToLowerInvariant(),
      _ => Group(trimmed),
    };
  }

  public static string GroupLabel(string group) => group switch
  {
    Waiting => "Čaka odobritev",
    Queued => "V vrsti",
    Sent => "Poslano",
    Confirmed => "Potrjeno v SAOP",
    Failed => "Napaka",
    Rejected => "Zavrnjeno",
    Superseded => "Nadomeščeno",
    _ => group,
  };

  /// <summary>Vidna oznaka stanja sporočila; neznano stanje ostane izvorna vrednost.</summary>
  public static string Label(string status) => GroupLabel(Group(status));

  /// <summary>Ton čipa: zeleno samo potrjeno, rdeče napaka, oranžno tisto, kar čaka človeka.</summary>
  public static string? Tone(string status) => Group(status) switch
  {
    Confirmed => "good",
    Failed => "bad",
    Waiting => "warn",
    _ => null,
  };

  /// <summary>Kaj pomeni skupina, v enem stavku (title na hitrem izboru).</summary>
  public static string Hint(string group) => group switch
  {
    Waiting => "Sprememba je pripravljena in čaka, da jo nekdo odobri. Brez odobritve ne gre v SAOP.",
    Queued => "Odobreno; avtomatika ali gumb »Pošlji zdaj« jo pošlje v SAOP.",
    Sent => "Poslano v SAOP; potrditev pride ob naslednjem branju iz SAOP.",
    Confirmed => "SAOP je vrednost prevzel in naslednje branje jo je potrdilo.",
    Failed => "SAOP je zahtevo zavrnil ali se vrednost ne ujema. Razlog je ob vrstici.",
    Rejected => "Sprememba je bila zavrnjena ali preklicana in v SAOP ne gre.",
    Superseded => "Kasnejša sprememba istega polja je to nadomestila.",
    _ => "",
  };

  /// <summary>Kaj naj uporabnik naredi ob zavrnitvi SAOP (vrsta napake iz <c>SaopErrorTranslator</c>).</summary>
  public static string ErrorAdvice(string? errorKind) => errorKind switch
  {
    "ItemAlreadyExists" => "Artikel v SAOP že obstaja. PIM ob naslednjem poskusu pošlje spremembo namesto novega artikla.",
    "ItemNotFound" => "Artikla v SAOP ni. PIM ga ob naslednjem poskusu pošlje kot nov artikel.",
    "CodebookMissing" => "Vrednost ni v šifrantu SAOP. Popravi vrednost na kartici artikla (ali dodaj šifro v SAOP) in pošlji znova.",
    "SupplierMissing" => "Šifra dobavitelja v SAOP ne obstaja ali ni aktivna. Popravi dobavitelja na kartici artikla in pošlji znova.",
    "AuthConfig" => "Težava je v povezavi s SAOP (prijava ali pravice), ne v artiklu. Obvesti skrbnika.",
    _ => "SAOP ni dal jasnega razloga. Odpri celotno sporočilo in preveri artikel.",
  };
}
