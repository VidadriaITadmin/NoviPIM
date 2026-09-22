/*
  112 — zaloga na 5 minut, prevzem katalogov ostane nocni.

  Naročnikova odlocitev 2026-08-27: zaloga ima natanko tri vire — SAOP, Nowodvorski prek FTP in
  Braytron prek XML — in vsi trije se osvezujejo na 5 minut. Loceno opravilo za prevzem datotek
  in loceno za branje datotek odpade; prevzem in branje gresta v istem prehodu, sicer je zaloga
  vedno en cikel zadaj.

  Zakaj SOURCE_FETCH kljub 5 minutam ne krsi dobaviteljeve omejitve: Braytron dovoli en prenos
  na 180 minut in cakalni cas pove v svojem odgovoru (<XmlAraligi>). Prevzemnik ga od te
  spremembe naprej spostuje sam in vira med tem sploh ne poklice, zato je pogostost cikla
  neodvisna od pogostosti prenosa.

  Migracija 107 je SOURCE_FETCH postavila na 180 minut prav zaradi te omejitve. Ker je omejitev
  zdaj resena v kodi in ne z urnikom, se ta vrstica umakne.

  Katalog (BT_XML, NW_XML) v tem ciklu ne sodi in ostane v nocnem toku: Braytronov katalog je
  19 MB, kar bi ob petminutnem ritmu pomenilo 5,5 GB prenosa na dan brez pomena.
*/

SET XACT_ABORT ON;

UPDATE ops.ScheduleProfile
SET IntervalSeconds = 300, StaleAfterSeconds = 3600, UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = N'migracija 112'
WHERE Pipeline IN (N'SOURCE_FETCH', N'STOCK_FILE', N'SAOP_STOCK');

/* --- preverba --------------------------------------------------------------- */

IF EXISTS (SELECT 1 FROM ops.ScheduleProfile
           WHERE Pipeline IN (N'SOURCE_FETCH', N'STOCK_FILE', N'SAOP_STOCK') AND IntervalSeconds <> 300)
  THROW 52807, 'Vsi trije zalogovni postopki morajo teci na 5 minut.', 1;

IF EXISTS (SELECT 1 FROM ops.ScheduleProfile WHERE StaleAfterSeconds <= IntervalSeconds)
  THROW 52808, 'Okno zastalosti mora biti daljse od intervala, sicer se zagon razglasi za zastalega sam od sebe.', 1;
