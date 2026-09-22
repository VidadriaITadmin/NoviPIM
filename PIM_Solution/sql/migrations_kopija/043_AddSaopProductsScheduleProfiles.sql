/*
  ops.BeginRun vzame razpored iz ops.ScheduleProfile in brez vrstice vrže
  51100 'Razpored ni omogočen.'. Profili so bili dodani v 035 (WATCHDOG,
  ALERT_DISPATCH) in ročno za GENERIC_XML, za SAOP_PRODUCTS pa nikoli — zato
  PIM.KatalogWorker od migracije 025 naprej pade takoj ob zagonu, še preden
  karkoli prebere. Zadnji uspešen SAOP zajem je bil 30. 7. 2026, dan pred 025.

  Profil ne ustvari Scheduled Taska in ničesar ne zažene sam; pove le, da je
  zagon dovoljen, in določi ključavnico, ki prepreči dva hkratna zajema istega
  podjetja.

  StaleAfterSeconds je 7200: poln zajem 200.000 artiklov traja bistveno dlje od
  900 sekund, ki veljajo za watchdog, in bi bil sicer sredi dela označen za
  zastalega. Worker med zajemom pošilja heartbeat po vsaki končni točki.
*/

SET XACT_ABORT ON;

MERGE ops.ScheduleProfile AS target
USING (VALUES
  (1, N'LOCAL', N'SAOP_PRODUCTS', 1, 3600, 7200, 5000, N'MIGRATION_043'),
  (2, N'LOCAL', N'SAOP_PRODUCTS', 1, 3600, 7200, 5000, N'MIGRATION_043'),
  (3, N'LOCAL', N'SAOP_PRODUCTS', 1, 3600, 7200, 5000, N'MIGRATION_043'),
  (4, N'LOCAL', N'SAOP_PRODUCTS', 1, 3600, 7200, 5000, N'MIGRATION_043')
) source(OrganizationId, Provider, Pipeline, IsEnabled, IntervalSeconds, StaleAfterSeconds, LockTimeoutMilliseconds, UpdatedBy)
ON target.OrganizationId = source.OrganizationId AND target.Pipeline = source.Pipeline
WHEN NOT MATCHED THEN
  INSERT (OrganizationId, Provider, Pipeline, IsEnabled, IntervalSeconds, StaleAfterSeconds, LockTimeoutMilliseconds, UpdatedBy)
  VALUES (source.OrganizationId, source.Provider, source.Pipeline, source.IsEnabled,
          source.IntervalSeconds, source.StaleAfterSeconds, source.LockTimeoutMilliseconds, source.UpdatedBy);

/*
  Obstoječih vrstic namenoma ne posodabljamo: če skrbnik profil kdaj izklopi ali
  mu spremeni interval, ponovni zagon migracije tega ne sme povoziti.
*/
