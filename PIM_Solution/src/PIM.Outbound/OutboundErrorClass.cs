namespace PIM.Outbound;

/// <summary>
/// Razred napake iz vrzeli O18. Odloca o poskusih in o tem, koga je treba obvestiti.
///
/// <c>Transient</c> — omrezje ali zasedenost; edini razred, ki se sme ponavljati.
/// <c>Business</c> — SAOP je zahtevo razumel in jo zavrnil; ponavljanje da isti odgovor.
/// <c>AuthConfig</c> — napaka ni na tem artiklu, ampak na integraciji; kanal se ustavi in
/// nastane en alarm namesto enega na vsak artikel.
/// </summary>
public enum OutboundErrorClass { None, Transient, Business, AuthConfig }
