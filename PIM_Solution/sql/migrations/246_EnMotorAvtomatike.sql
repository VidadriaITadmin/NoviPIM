/*
  246 — en motor avtomatike (PIM.AutomationHost), pas SAOP in urniki za zalogo in cene na 10 min.

  David 2026-09-22: »zakaj je toliko strani ... zakaj ne narediva kar je najbolj preprosto in dobro
  za sistem in da bo robustno delovalo«; ekipa SAOP: PIM kliče GetPrices in GetItem brez premora in
  obremenjuje procesor SAOP. Izmerjeno istega dne: workerje so poganjali trije razporejevalniki hkrati
  (Windows naloge, razporejevalnik v IIS, ki se je vklopil ob vsakem zagonu intraneta, in nenameščen
  gostitelj), cikel zaloge »na 5 min« je trajal 6-11 min in se takoj začel znova, dobavni roki so se
  iz IIS brali vsakih 30 min (do ~44.000 klicev na dan).

  Koda (isti commit): gostitelj poganja posle, ki kličejo SAOP, po enega naenkrat z 2 min tišine vmes,
  naslednji termin šteje od KONCA teka z odlogom po zaporednih napakah, workerji tečejo v Windows Job
  Objectu (brez sirot), vsako podjetje je svoj korak, razporejevalnik v IIS je privzeto izklopljen.

  Ta migracija uskladi obstoječe vrstice s kodo. ops.EnsureJobDefinition obstoječim vrsticam urnika ne
  spreminja (urnik je skrbnikov), zato se tu spremenijo samo vrstice, ki jih ni spreminjal človek
  (UpdatedBy je postopek ali migracija). Nova vrstica SUPPLIER_STOCK_IMPORT nastane ob zagonu gostitelja.

    1. STOCK_IMPORT (zdaj samo zaloga iz SAOP) in PRICE_IMPORT: razmik 600 s, meja 900 s, SLA 1800 s.
    2. WEB_STOCK_EXPORT: razmik 1800 s (sproži ga uspešna zaloga), meja 1800 s, SLA 3600 s.
    3. SAOP_DELIVERY_IMPORT: izklopljen, razmik 3 h (dobavne roke bere nočna uskladitev).
    4. SYSTEM_SELF_TEST: izklopljen (brez objavljenega samotesta bi ga gostitelj ponoči gradil z dotnet run).
    5. NIGHTLY_RECONCILIATION: ob 00:30 namesto 02:30 (okno poletnega časa).
    6. NextDueUtc = NULL za posle, ki ne tečejo: gostitelj jih ob naslednjem tiku razmakne znova.
    7. Podjetje DEMO (1, predpona DEMO) izključeno iz avtomatike (ops.OrganizationAutomationPolicy);
       ponovni vklop na /sistem/integracije.
    8. Stari cikli ops.WorkerCycle izklopljeni, samo kadar na bazi že teče PIM.AutomationHost
       (živ najem): razporejevalnik v IIS jih ne poganja več, PIM.Watchdog pa bi zanje ob vsakem tiku
       odprl alarm CycleOverdue. Brez gostitelja (PRD pred namestitvijo) ostanejo vklopljeni.
    9. ops.ScheduleProfile SAOP_DELIVERY: razmik 1 dan, zastarelost 36 h (samo nočno branje), da
       nadzornik ne javlja lažnega zamujanja.
*/

IF OBJECT_ID(N'ops.JobDefinition', N'U') IS NULL
  THROW 52970, N'246: ops.JobDefinition ne obstaja (najprej migracija 237).', 1;

DECLARE @kdo nvarchar(200) = N'246_EnMotorAvtomatike';

/* ── 1-5. Urniki obstoječih poslov (samo, kjer jih ni spreminjal človek) ───────── */
UPDATE ops.JobDefinition
SET IntervalSeconds = 600, DailyAtLocal = NULL, TimeoutSeconds = 900, SlaSeconds = 1800,
    UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = @kdo
WHERE JobKey IN (N'STOCK_IMPORT', N'PRICE_IMPORT')
  AND (UpdatedBy LIKE N'ops.%' OR UpdatedBy LIKE N'migracija%' OR UpdatedBy LIKE N'2[0-9][0-9][_ ]%');

UPDATE ops.JobDefinition
SET IntervalSeconds = 1800, DailyAtLocal = NULL, TimeoutSeconds = 1800, SlaSeconds = 3600,
    UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = @kdo
WHERE JobKey = N'WEB_STOCK_EXPORT'
  AND (UpdatedBy LIKE N'ops.%' OR UpdatedBy LIKE N'migracija%' OR UpdatedBy LIKE N'2[0-9][0-9][_ ]%');

UPDATE ops.JobDefinition
SET IsEnabled = 0, IntervalSeconds = 10800, DailyAtLocal = NULL, SlaSeconds = 129600,
    UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = @kdo
WHERE JobKey = N'SAOP_DELIVERY_IMPORT'
  AND (UpdatedBy LIKE N'ops.%' OR UpdatedBy LIKE N'migracija%' OR UpdatedBy LIKE N'2[0-9][0-9][_ ]%');

UPDATE ops.JobDefinition
SET IsEnabled = 0, UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = @kdo
WHERE JobKey = N'SYSTEM_SELF_TEST'
  AND (UpdatedBy LIKE N'ops.%' OR UpdatedBy LIKE N'migracija%' OR UpdatedBy LIKE N'2[0-9][0-9][_ ]%');

UPDATE ops.JobDefinition
SET DailyAtLocal = '00:30', IntervalSeconds = NULL, UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = @kdo
WHERE JobKey = N'NIGHTLY_RECONCILIATION' AND DailyAtLocal = '02:30'
  AND (UpdatedBy LIKE N'ops.%' OR UpdatedBy LIKE N'migracija%' OR UpdatedBy LIKE N'2[0-9][0-9][_ ]%');

/* ── 6. Nov razmik: gostitelj termine postavi znova ────────────────────────────── */
UPDATE ops.JobDefinition SET NextDueUtc = NULL WHERE RunningJobRunId IS NULL AND RequestedRunUtc IS NULL;

/* ── 7. DEMO izključen iz avtomatike ───────────────────────────────────────────── */
IF OBJECT_ID(N'ops.OrganizationAutomationPolicy', N'U') IS NOT NULL
   AND EXISTS (SELECT 1 FROM dbo.OrganizationConfig WHERE OrganizationId = 1 AND SaopPrefix = N'DEMO')
BEGIN
  MERGE ops.OrganizationAutomationPolicy AS target
  USING (SELECT CONVERT(int, 1) AS OrganizationId) AS source ON target.OrganizationId = source.OrganizationId
  WHEN MATCHED THEN UPDATE SET IsEnabled = 0, UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = @kdo
  WHEN NOT MATCHED THEN INSERT (OrganizationId, IsEnabled, UpdatedUtc, UpdatedBy) VALUES (1, 0, SYSUTCDATETIME(), @kdo);
END;

/* ── 8. Stari cikli izklopljeni, SAMO kadar na tej bazi že teče PIM.AutomationHost ──
   Brez gostitelja (npr. PRD, kjer storitev še ni nameščena) bi izklop ustavil razporejevalnik v IIS,
   Windows naloge pa bi se ob njegovem živem najmu vseeno umaknile — nič ne bi teklo. Tam se cikli
   izklopijo ročno po namestitvi storitve (/sistem/workerji ali isti UPDATE). */
DECLARE @gostiteljTece bit = CASE WHEN EXISTS (
  SELECT 1 FROM ops.SchedulerLease
  WHERE Owner LIKE N'%:AutomationHost%' AND HeartbeatUtc > DATEADD(MINUTE, -10, SYSUTCDATETIME())) THEN 1 ELSE 0 END;
IF OBJECT_ID(N'ops.WorkerCycle', N'U') IS NOT NULL AND @gostiteljTece = 1
  UPDATE ops.WorkerCycle SET IsEnabled = 0, UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = @kdo WHERE IsEnabled = 1;
IF @gostiteljTece = 0
  PRINT N'246: PIM.AutomationHost na tej bazi ne teče; stari cikli (ops.WorkerCycle) ostanejo vklopljeni. Izklopi jih po namestitvi storitve.';

/* ── 9. Dobavni roki samo ponoči ────────────────────────────────────────────────── */
UPDATE ops.ScheduleProfile
SET IntervalSeconds = 86400, StaleAfterSeconds = 129600, UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = @kdo
WHERE Pipeline = N'SAOP_DELIVERY' AND IntervalSeconds < 86400;

/* ── Preverbe ───────────────────────────────────────────────────────────────────── */
IF EXISTS (SELECT 1 FROM ops.JobDefinition WHERE JobKey IN (N'STOCK_IMPORT', N'PRICE_IMPORT') AND IntervalSeconds < 600 AND UpdatedBy = @kdo)
  THROW 52971, N'246: razmik zaloge ali cen ni 600 s.', 1;
IF @gostiteljTece = 1 AND OBJECT_ID(N'ops.WorkerCycle', N'U') IS NOT NULL AND EXISTS (SELECT 1 FROM ops.WorkerCycle WHERE IsEnabled = 1)
  THROW 52972, N'246: star cikel je še vklopljen.', 1;
