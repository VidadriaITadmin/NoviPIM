/*
  269 — pregled strani 2026-09-23: strani, ki so bile samo preusmeritev ali druga pot na isto
  stran, so odstranjene (/partnerji, /izvozi, /teki-obdelave, /napake-validacije, /karantena,
  /sistem/vloge, /sistem/mape, /sistem/uporabniki, /system/uporabniki, /administracija/uporabniki).
  Uporabnik: »preusmeritev je bv, še vedno imam dve strani — ena stran«.

  Samo /partnerji je imela svoj ključ pravice (view.customers.partners); ključ ni več v katalogu
  PimAccessCatalog, zato se vrstice vlog pobrišejo, da urejevalnik vlog ne kaže sirote.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;

DELETE FROM sec.RolePermission WHERE PermissionKey = N'view.customers.partners';
