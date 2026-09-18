SET XACT_ABORT ON;

/* Enables local operational visibility only; this migration does not schedule or deliver anything. */
MERGE ops.ScheduleProfile AS target
USING (VALUES
  (2,N'LOCAL',N'WATCHDOG',1,300,900,N'MIGRATION'),
  (2,N'LOCAL',N'ALERT_DISPATCH',1,300,900,N'MIGRATION')
) source(OrganizationId,Provider,Pipeline,IsEnabled,IntervalSeconds,StaleAfterSeconds,UpdatedBy)
ON target.OrganizationId=source.OrganizationId AND target.Pipeline=source.Pipeline
WHEN MATCHED THEN UPDATE SET Provider=source.Provider,IsEnabled=source.IsEnabled,IntervalSeconds=source.IntervalSeconds,StaleAfterSeconds=source.StaleAfterSeconds,UpdatedUtc=SYSUTCDATETIME(),UpdatedBy=source.UpdatedBy
WHEN NOT MATCHED THEN INSERT(OrganizationId,Provider,Pipeline,IsEnabled,IntervalSeconds,StaleAfterSeconds,UpdatedBy)
  VALUES(source.OrganizationId,source.Provider,source.Pipeline,source.IsEnabled,source.IntervalSeconds,source.StaleAfterSeconds,source.UpdatedBy);
