namespace PIM.Intranet.Services;

/// <summary>
/// Izbrano podjetje, deljeno med vsemi stranmi izhoda v SAOP (Artikli/Čakalna vrsta/Zgodovina/
/// Pregled) znotraj ene seje (Blazor Server: AddScoped = en krog povezave, torej en uporabnik).
///
/// Zakaj obstaja: vsaka od teh strani je svoj @page in ima svoj izbirnik podjetja; brez skupnega
/// mesta bi vsaka ob prehodu spet padla na privzeto podjetje (GetCurrentOrganizationAsync, ki
/// vedno vrne tisto z najnizjo sifro). Uporabnik izbere IQLighting na Artiklih, klikne na zavihek
/// Cakalna vrsta in bi spet videl DEMO — videti bi bilo, kot da za druga podjetja "ne dela",
/// ceprav podatki v bazi ze ves cas pravilno locijo po OrganizationId. Uporabnikova zahteva
/// 2026-09-11.
/// </summary>
public sealed class SaopOrganizationContext
{
  public int? OrganizationId { get; set; }
}
