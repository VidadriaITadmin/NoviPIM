/*
  107 — interval prevzema mora slediti dobaviteljevi omejitvi.

  Migracija 106 je prevzem in dobaviteljevo zalogo nastavila na 30 minut. Izmerjeno 2026-08-27
  je Braytron drugi prenos v isti uri zavrnil s HTTP 200 in telesom:

    <Hata><HataMi>True</HataMi><HataMesaj>Maximum Sorgu Limitine Ulastiniz.</HataMesaj>
          <XmlAraligi>180 Dk</XmlAraligi><SonrakiXmlTarihi>27.08.2026 18:28:19</SonrakiXmlTarihi></Hata>

  Dobavitelj torej dovoli en prenos na 180 minut. Pri 30-minutnem urniku bi pet od sestih zagonov
  naletelo na zavrnitev. Prevzemnik zavrnitev zdaj prepozna in prejsnje datoteke ne povozi
  (PIM.SourceFetchWorker.SupplierRefusal), a zaman ponavljati klic je vseeno napacno.

  SOURCE_FETCH gre zato na 180 minut. STOCK_FILE ostane pogostejsi (60 min): bere lokalno
  datoteko, ne dobavitelja, in mora zajeti datoteko takoj, ko jo prevzem prinese.
  SAOP_STOCK ostane na 15 minutah — SAOP je nas ERP in nima take omejitve.
*/

SET XACT_ABORT ON;

UPDATE ops.ScheduleProfile
SET IntervalSeconds = 10800, StaleAfterSeconds = 12600, UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = N'migracija 107'
WHERE Pipeline = N'SOURCE_FETCH';

UPDATE ops.ScheduleProfile
SET IntervalSeconds = 3600, StaleAfterSeconds = 5400, UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = N'migracija 107'
WHERE Pipeline = N'STOCK_FILE';

/* --- preverba --------------------------------------------------------------- */

IF EXISTS (SELECT 1 FROM ops.ScheduleProfile WHERE Pipeline = N'SOURCE_FETCH' AND IntervalSeconds < 10800)
  THROW 52805, 'Prevzem ne sme teci pogosteje od dobaviteljeve omejitve 180 minut.', 1;

IF EXISTS (SELECT 1 FROM ops.ScheduleProfile WHERE StaleAfterSeconds <= IntervalSeconds)
  THROW 52806, 'Okno zastalosti mora biti daljse od intervala, sicer se zagon razglasi za zastalega sam od sebe.', 1;
