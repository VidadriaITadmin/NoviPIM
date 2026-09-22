/*
  210 — cene za vsa podjetja na 5 min, narocila locena na VNK in VND, oboje samodejno.

  Uporabnik 2026-09-15, po tem ko je nadzor razkril, da PIM.KatalogWorker --endpoints GetPrices
  pade z "Razpored ni omogocen" (51100): v ops.ScheduleProfile ni bilo niti ene vrstice SAOP_PRICES
  za nobeno podjetje, cetudi Zaloga-cikel.ps1 ta korak ze klice vsakih 5 minut. Hkrati je bil
  Zaloga-cikel.ps1 zacasno omejen na podjetje 2 (pilotni preizkus) - ta migracija razpored
  razsiri na vsa stiri, skripta pa je popravljena locenocasno (glej Zaloga-cikel.ps1).

  Narocila (PIM.SaopOrdersWorker, migracija 199) doslej niso tekla nikoli avtomatsko - noben od
  stirih ciklov ga ni klical, ceprav je SAOP_ORDERS v ops.ScheduleProfile ves cas kazal vklopljeno.
  Uporabnik zahteva locen razpored za VNK (narocila kupcev) in VND (narocila dobaviteljem), da ju
  lahko na /sistem/urniki vklopi/izklopi/spremlja loceno - PIM.SaopOrdersWorker je zato preurejen,
  da vsakega odpre pod svojim OperationsRun (glej Program.cs). Stara skupna vrstica SAOP_ORDERS
  se izklopi in ne izbrise, da zgodovina tekov pod tem imenom ostane berljiva.

  Objekti: samo ops.ScheduleProfile (brez sprememb sheme ali procedur).
  Rocni korak po uvedbi: ni potreben. Katalog-cikel.ps1 od te spremembe naprej vsako uro klice
  PIM.SaopOrdersWorker za vsa stiri podjetja; naslednji zagon naloge "PIM katalog" zacne narocila
  brati sam, brez posega v Windows Scheduled Tasks.
*/

SET XACT_ABORT ON;

/* --- 1) SAOP_PRICES za vsa podjetja, ne le za tisto, ki je bilo v pilotu ------------------- */

MERGE ops.ScheduleProfile AS target
USING
(
  SELECT organization.OrganizationId, N'SAOP' AS Provider, N'SAOP_PRICES' AS Pipeline,
    300 AS IntervalSeconds, 900 AS StaleAfterSeconds, 5000 AS LockTimeoutMilliseconds
  FROM dbo.OrganizationConfig organization
  WHERE EXISTS (SELECT 1 FROM map.SourceConnector connector
                WHERE connector.OrganizationId = organization.OrganizationId
                  AND connector.ConnectorType = N'SAOP' AND connector.IsActive = 1)
) AS source
  ON target.OrganizationId = source.OrganizationId AND target.Pipeline = source.Pipeline
WHEN NOT MATCHED THEN
  INSERT (OrganizationId, Provider, Pipeline, IsEnabled, IntervalSeconds, StaleAfterSeconds, LockTimeoutMilliseconds, UpdatedBy)
  VALUES (source.OrganizationId, source.Provider, source.Pipeline, 1, source.IntervalSeconds,
          source.StaleAfterSeconds, source.LockTimeoutMilliseconds, N'migracija 210');

/* --- 2) narocila: VNK in VND kot loceni razporedi ------------------------------------------ */

MERGE ops.ScheduleProfile AS target
USING
(
  SELECT organization.OrganizationId, pipeline.Pipeline
  FROM dbo.OrganizationConfig organization
  CROSS JOIN (VALUES (N'SAOP_ORDERS_VNK'), (N'SAOP_ORDERS_VND')) AS pipeline (Pipeline)
  WHERE EXISTS (SELECT 1 FROM map.SourceConnector connector
                WHERE connector.OrganizationId = organization.OrganizationId
                  AND connector.ConnectorType = N'SAOP' AND connector.IsActive = 1)
) AS source
  ON target.OrganizationId = source.OrganizationId AND target.Pipeline = source.Pipeline
WHEN NOT MATCHED THEN
  /* Isti razmik (1h) kot je imel skupni SAOP_ORDERS - to je bilo ze usklajeno z urnim
     Katalog-cikel.ps1, ki narocila zdaj klice. */
  INSERT (OrganizationId, Provider, Pipeline, IsEnabled, IntervalSeconds, StaleAfterSeconds, LockTimeoutMilliseconds, UpdatedBy)
  VALUES (source.OrganizationId, N'SAOP', source.Pipeline, 1, 3600, 7200, 5000, N'migracija 210');

/* Stara skupna vrstica: izklopljena in ne izbrisana, da CompleteRun/PipelineRun zgodovina pod
   tem imenom ostane berljiva na /sistem/postopki. Worker je nanjo ze nehal pisati. */
UPDATE ops.ScheduleProfile
SET IsEnabled = 0, UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = N'migracija 210 (razdeljeno na VNK/VND)'
WHERE Pipeline = N'SAOP_ORDERS' AND IsEnabled = 1;

/* --- preverbe -------------------------------------------------------------------------------- */

IF (SELECT COUNT(DISTINCT OrganizationId) FROM ops.ScheduleProfile WHERE Pipeline = N'SAOP_PRICES' AND IsEnabled = 1) < 1
  THROW 52921, N'210: razpored SAOP_PRICES ni omogocen za nobeno organizacijo; ops.BeginRun bi vrgel 51100.', 1;

IF EXISTS (SELECT 1 FROM dbo.OrganizationConfig organization
           WHERE EXISTS (SELECT 1 FROM map.SourceConnector connector
                         WHERE connector.OrganizationId = organization.OrganizationId
                           AND connector.ConnectorType = N'SAOP' AND connector.IsActive = 1)
             AND NOT EXISTS (SELECT 1 FROM ops.ScheduleProfile schedule
                             WHERE schedule.OrganizationId = organization.OrganizationId
                               AND schedule.Pipeline = N'SAOP_PRICES' AND schedule.IsEnabled = 1))
  THROW 52922, N'210: vsaj eno podjetje s SAOP konektorjem nima omogocenega SAOP_PRICES.', 1;

IF (SELECT COUNT(DISTINCT OrganizationId) FROM ops.ScheduleProfile WHERE Pipeline = N'SAOP_ORDERS_VNK' AND IsEnabled = 1) < 1
  THROW 52923, N'210: razpored SAOP_ORDERS_VNK ni omogocen za nobeno organizacijo.', 1;
IF (SELECT COUNT(DISTINCT OrganizationId) FROM ops.ScheduleProfile WHERE Pipeline = N'SAOP_ORDERS_VND' AND IsEnabled = 1) < 1
  THROW 52924, N'210: razpored SAOP_ORDERS_VND ni omogocen za nobeno organizacijo.', 1;
IF EXISTS (SELECT 1 FROM ops.ScheduleProfile WHERE Pipeline = N'SAOP_ORDERS' AND IsEnabled = 1)
  THROW 52925, N'210: stara vrstica SAOP_ORDERS bi se se vedno lahko zagnala vzporedno z VNK/VND.', 1;
