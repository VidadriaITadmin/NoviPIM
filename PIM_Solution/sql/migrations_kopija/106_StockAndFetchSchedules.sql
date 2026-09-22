/*
  105 — razpored za zalogo in prevzem dobaviteljevih datotek.

  Do zdaj v ops.ScheduleProfile ni bilo niti ene vrstice za zalogo: registrirani so bili samo
  ALERT_DISPATCH, GENERIC_XML, SAOP_PRODUCTS in WATCHDOG. Zaloga se je zato brala samo takrat,
  ko jo je clovek pognal rocno — izmerjeno 2026-08-27 je bila zadnja dobaviteljeva datoteka z
  31. 7., zaloga iz SAOP pa ni bila prebrana nikoli.

  Hkrati se oba zalogovna workerja ne prijavljata prek ops.BeginRun, zato jih ni bilo v
  /zajem/teki in njihovo stanje ni bilo vidno nikjer. Ta migracija je podatkovna polovica tega
  popravka; programska je v PIM.SaopStockWorker in PIM.StockFileWorker.

  Trije novi postopki:
    SOURCE_FETCH  — prevzem datotek od dobaviteljev (PIM.SourceFetchWorker)
    STOCK_FILE    — branje dobaviteljeve datoteke v stock.* (PIM.StockFileWorker)
    SAOP_STOCK    — branje zaloge iz SAOP (PIM.SaopStockWorker)

  Intervali so prepisani po naravi vira, ne enotno:
    - prevzem in dobaviteljeva zaloga na 30 min, ker dobavitelj datoteke ne osvezuje pogosteje;
    - zaloga iz SAOP na 15 min, ker je to nas ERP in se premika ves dan.
  StaleAfterSeconds je pri SAOP_STOCK namerno velik: izmerjeno 2026-08-27 je zajem 70 skladisc
  pri Vidadrii trajal vec minut, okno zastalosti pa mora biti obcutno daljse od najdaljsega
  zagona, sicer se zagon razglasi za zastalega sam od sebe (ista past kot pri SAOP_PRODUCTS).

  SOURCE_FETCH je registriran samo pri podjetju 1: prevzem je skupen vsem stirim, ker je
  map.SourceFetchLocation.OrganizationId NULL — ista datoteka se prenese enkrat. Vrstica obstaja
  zgolj zato, ker ops.BeginRun zahteva organizacijo.
*/

SET XACT_ABORT ON;

MERGE ops.ScheduleProfile AS target
USING
(
  VALUES
    (1, N'LOCAL', N'SOURCE_FETCH', 1800, 3600, 5000),
    (1, N'FILE',  N'STOCK_FILE',   1800, 3600, 5000),
    (2, N'FILE',  N'STOCK_FILE',   1800, 3600, 5000),
    (3, N'FILE',  N'STOCK_FILE',   1800, 3600, 5000),
    (4, N'FILE',  N'STOCK_FILE',   1800, 3600, 5000),
    (1, N'SAOP',  N'SAOP_STOCK',    900, 5400, 5000),
    (2, N'SAOP',  N'SAOP_STOCK',    900, 5400, 5000),
    (3, N'SAOP',  N'SAOP_STOCK',    900, 5400, 5000),
    (4, N'SAOP',  N'SAOP_STOCK',    900, 5400, 5000)
) AS source(OrganizationId, Provider, Pipeline, IntervalSeconds, StaleAfterSeconds, LockTimeoutMilliseconds)
  ON target.OrganizationId = source.OrganizationId AND target.Pipeline = source.Pipeline
WHEN NOT MATCHED THEN
  INSERT (OrganizationId, Provider, Pipeline, IsEnabled, IntervalSeconds, StaleAfterSeconds, LockTimeoutMilliseconds, UpdatedBy)
  VALUES (source.OrganizationId, source.Provider, source.Pipeline, 1, source.IntervalSeconds,
          source.StaleAfterSeconds, source.LockTimeoutMilliseconds, N'migracija 105');

/* --- register prevzemov ------------------------------------------------------

  Naslova in poverilnice so v appsettings.Local.json pod Fetch:* in v bazo ne gredo. Register
  hrani samo to, kje jih worker najde. BT_XML in NW_STOCK sta bila IsActive = 0, ker nastavitve
  ni bilo; zdaj je in ju vklopimo.

  NW_XML ostane MAPA in ostane rocen: Nowodvorski ima svojo PIM platformo, iz katere se XML
  potegne rocno. Pot popravimo iz fixtures/ v data/, ker so fixtures testni podatki in jih ziv
  prevzem ne sme povoziti — to se je 2026-08-27 zgodilo in podrlo tri teste F6.
*/

UPDATE map.SourceFetchLocation SET IsActive = 1, UpdatedUtc = SYSUTCDATETIME()
WHERE SourceCode IN (N'BT_XML', N'NW_STOCK') AND IsActive = 0;

UPDATE map.SourceFetchLocation
SET Location = N'PIM_Solution\data\prevzem\NW_XML', UpdatedUtc = SYSUTCDATETIME()
WHERE SourceCode = N'NW_XML' AND Kind = N'MAPA';

/* --- preverba --------------------------------------------------------------- */

IF (SELECT COUNT(*) FROM ops.ScheduleProfile WHERE Pipeline = N'SAOP_STOCK' AND IsEnabled = 1) < 4
  THROW 52801, 'Razpored za zalogo iz SAOP ni omogocen pri vseh stirih podjetjih.', 1;

IF (SELECT COUNT(*) FROM ops.ScheduleProfile WHERE Pipeline = N'STOCK_FILE' AND IsEnabled = 1) < 4
  THROW 52802, 'Razpored za dobaviteljevo zalogo ni omogocen pri vseh stirih podjetjih.', 1;

IF NOT EXISTS (SELECT 1 FROM ops.ScheduleProfile WHERE Pipeline = N'SOURCE_FETCH' AND IsEnabled = 1)
  THROW 52803, 'Razpored za prevzem dobaviteljevih datotek ni omogocen.', 1;

IF EXISTS (SELECT 1 FROM map.SourceFetchLocation WHERE IsActive = 0)
  THROW 52804, 'Vsi stirje prevzemi morajo biti aktivni; nastavitve so zdaj na voljo.', 1;
