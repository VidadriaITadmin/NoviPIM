/*
  270 — Nowodvorski katalog (NW_XML) se prevzame sam prek povezave, ne vec rocno v mapo.

  Do zdaj je bil NW_XML v registru prevzemov Kind = MAPA (099, 106): XML se je rocno prenesel s
  Nowodvorskijeve PIM platforme in polozil v <LANDING_ROOT>\NW_XML. Na strezniku te mape ni bilo,
  zato je nocna uskladitev korak "XML Nowodvorski" tiho preskakovala in NW katalog se ni bral.

  Nowodvorski ima neposredno povezavo, ki brez prijave vrne celoten XML (products_en_US.xml,
  ~19 MB). Zdaj je vir HTTP kot Braytron:

    Kind             HTTP
    CredentialKey    Fetch:NW_XML   — naslov stoji v appsettings.Local.json, ne tu: v njem je
                                      dostopni zeton (isto pravilo kot BT_STOCK in BT_XML, 099)
    FileNamePattern  products_en_US.xml — ime mora imeti koncnico .xml. Prevzemnik iz vzorca z
                                      zvezdico (prej *.xml) naredi NW_XML.dat, tega pa
                                      PIM.XmlFileWorker ne bere.
    MinIntervalMinutes 360          — katalog se ne spreminja med dnevom; varovalka, da rocni
                                      zagoni prevzema ne vlecejo 19 MB vsakic znova.
    Location         NULL           — stara pot data\prevzem\NW_XML ni vec mesto prevzema.

  Kdo ga poklice: nocna uskladitev (00:30) pozene PIM.SourceFetchWorker za vse aktivne vire in
  nato PIM.XmlFileWorker nad <LANDING_ROOT>\NW_XML. Urnika ni treba spreminjati.

  Rocni korak: v appsettings.Local.json ob intranetu na strezniku dodaj pod "Fetch" vnos
    "NW_XML": "https://pim.nowodvorski.com/xmlfeed/download/1/<zeton>"
  Brez njega prevzem javi napako "Naslov ni nastavljen", ne tihega preskoka.
*/

SET XACT_ABORT ON;

UPDATE map.SourceFetchLocation
SET Kind = N'HTTP',
    Location = NULL,
    CredentialKey = N'Fetch:NW_XML',
    FileNamePattern = N'products_en_US.xml',
    MinIntervalMinutes = 360,
    IsActive = 1,
    Note = N'Nowodvorski PIM xmlfeed, neposreden prenos. Naslov z zetonom je v appsettings.Local.json pod Fetch:NW_XML.',
    UpdatedUtc = SYSUTCDATETIME()
WHERE SourceCode = N'NW_XML';

/* --- preverba --------------------------------------------------------------- */

IF NOT EXISTS (SELECT 1 FROM map.SourceFetchLocation
               WHERE SourceCode = N'NW_XML' AND Kind = N'HTTP' AND IsActive = 1
                 AND CredentialKey = N'Fetch:NW_XML' AND FileNamePattern = N'products_en_US.xml')
  THROW 52701, 'NW_XML ni preklopljen na prevzem prek HTTP.', 1;
