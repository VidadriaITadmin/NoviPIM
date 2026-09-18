/*
  226 — izključitev podjetja iz avtomatike.

  »Ne obdeluj tega podjetja« je operativna odločitev, ne izbris podjetja: artikli in zgodovina
  ostanejo vidni, avtomatski cikli pa ga ne kličejo in zanj ne ustvarjajo oziroma ne dostavljajo
  opozoril. To je namenjeno tudi DEMO okolju.
*/
SET XACT_ABORT ON;

IF OBJECT_ID(N'ops.OrganizationAutomationPolicy', N'U') IS NULL
BEGIN
  CREATE TABLE ops.OrganizationAutomationPolicy
  (
    OrganizationId int NOT NULL CONSTRAINT PK_OrganizationAutomationPolicy PRIMARY KEY
      CONSTRAINT FK_OrganizationAutomationPolicy_Organization REFERENCES dbo.OrganizationConfig(OrganizationId),
    IsEnabled bit NOT NULL CONSTRAINT DF_OrganizationAutomationPolicy_Enabled DEFAULT (1),
    UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_OrganizationAutomationPolicy_UpdatedUtc DEFAULT SYSUTCDATETIME(),
    UpdatedBy nvarchar(200) NOT NULL
  );
END;

INSERT ops.OrganizationAutomationPolicy (OrganizationId, IsEnabled, UpdatedBy)
SELECT organizationValue.OrganizationId, CONVERT(bit, 1), N'226_OrganizationAutomationControl'
FROM dbo.OrganizationConfig organizationValue
WHERE NOT EXISTS
(
  SELECT 1 FROM ops.OrganizationAutomationPolicy policy
  WHERE policy.OrganizationId = organizationValue.OrganizationId
);

EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetOrganizationAutomation
AS
BEGIN
  SET NOCOUNT ON;
  SELECT organizationValue.OrganizationId, organizationValue.Name,
         COALESCE(policy.IsEnabled, CONVERT(bit, 1)) AS IsAutomationEnabled,
         policy.UpdatedUtc, policy.UpdatedBy
  FROM dbo.OrganizationConfig organizationValue
  LEFT JOIN ops.OrganizationAutomationPolicy policy ON policy.OrganizationId = organizationValue.OrganizationId
  WHERE organizationValue.IsActive = 1
  ORDER BY organizationValue.OrganizationId;
END;');

EXEC(N'CREATE OR ALTER PROCEDURE intranet.SetOrganizationAutomation
  @OrganizationId int,
  @IsEnabled bit,
  @Actor nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  IF NOT EXISTS (SELECT 1 FROM dbo.OrganizationConfig WHERE OrganizationId = @OrganizationId AND IsActive = 1)
    THROW 51260, N''Aktivno podjetje ne obstaja.'', 1;

  MERGE ops.OrganizationAutomationPolicy AS target
  USING (SELECT @OrganizationId AS OrganizationId) AS source ON target.OrganizationId = source.OrganizationId
  WHEN MATCHED THEN UPDATE SET IsEnabled = @IsEnabled, UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = @Actor
  WHEN NOT MATCHED THEN INSERT (OrganizationId, IsEnabled, UpdatedBy) VALUES (@OrganizationId, @IsEnabled, @Actor);

  /* Izključitev velja takoj tudi za že odprte alarme in čakajoče dostave. */
  IF @IsEnabled = 0
  BEGIN
    UPDATE alert SET ResolvedUtc = SYSUTCDATETIME(), ResolvedBy = @Actor, UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = @Actor
    FROM ops.Alert alert WHERE alert.OrganizationId = @OrganizationId AND alert.ResolvedUtc IS NULL;

    UPDATE delivery SET Status = N''Dead'', NextAttemptUtc = NULL, LeaseOwner = NULL, LeaseUntilUtc = NULL,
      LastErrorRedacted = N''Dostava je ustavljena: podjetje je izključeno iz avtomatike.'', UpdatedUtc = SYSUTCDATETIME()
    FROM ops.AlertDelivery delivery
    INNER JOIN ops.Alert alert ON alert.AlertId = delivery.AlertId
    WHERE alert.OrganizationId = @OrganizationId AND delivery.Status IN (N''Pending'', N''Retry'');
  END;
END;');

/* Watchdog ne odpira novih opozoril za izključeno podjetje. */
EXEC(N'CREATE OR ALTER PROCEDURE ops.RunWatchdog @Actor nvarchar(200)=N''PIM.Watchdog''
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  DECLARE @now datetime2(3)=SYSUTCDATETIME();
  UPDATE health SET Status=N''Stale'',UpdatedUtc=@now
  FROM ops.IntegrationHealth health
  INNER JOIN ops.ScheduleProfile profile ON profile.OrganizationId=health.OrganizationId AND profile.Pipeline=health.Pipeline
  LEFT JOIN ops.OrganizationAutomationPolicy policy ON policy.OrganizationId=profile.OrganizationId
  WHERE profile.IsEnabled=1 AND COALESCE(policy.IsEnabled, CONVERT(bit, 1))=1
    AND health.LastHeartbeatUtc<DATEADD(second,-profile.StaleAfterSeconds,@now) AND health.Status=N''Running'';
  MERGE ops.Alert AS target USING
  (
    SELECT profile.OrganizationId,profile.Pipeline,N''StaleHeartbeat'' AlertKind,N''Critical'' Severity,
      CONVERT(varchar(64),HASHBYTES(''SHA2_256'',CONCAT(profile.OrganizationId,N'':'',profile.Pipeline,N'':stale'')),2) DedupKey,
      N''Zastarel srčni utrip'' Title,N''Worker nima pravočasnega srčnega utripa.'' PayloadSummaryRedacted
    FROM ops.ScheduleProfile profile
    INNER JOIN ops.IntegrationHealth health ON health.OrganizationId=profile.OrganizationId AND health.Pipeline=profile.Pipeline
    LEFT JOIN ops.OrganizationAutomationPolicy policy ON policy.OrganizationId=profile.OrganizationId
    WHERE profile.IsEnabled=1 AND COALESCE(policy.IsEnabled, CONVERT(bit, 1))=1 AND health.Status=N''Stale''
    UNION ALL
    SELECT message.OrganizationId,N''Outbound'',CASE WHEN message.Status=N''Dead'' THEN N''OutboundDead'' ELSE N''OutboundDrift'' END,N''Critical'',
      CONVERT(varchar(64),HASHBYTES(''SHA2_256'',CONCAT(message.OrganizationId,N'':outbound:'',message.Status)),2),
      CASE WHEN message.Status=N''Dead'' THEN N''Odhodno sporočilo je mrtvo'' ELSE N''Zaznan je odklon'' END,
      CONCAT(N''Število sporočil: '',COUNT_BIG(*))
    FROM out.OutboxMessage message
    LEFT JOIN ops.OrganizationAutomationPolicy policy ON policy.OrganizationId=message.OrganizationId
    WHERE message.Status IN(N''Dead'',N''Drift'') AND COALESCE(policy.IsEnabled, CONVERT(bit, 1))=1
    GROUP BY message.OrganizationId,message.Status
    UNION ALL
    SELECT profile.OrganizationId,profile.Pipeline,N''StalledWatermark'',N''Warning'',
      CONVERT(varchar(64),HASHBYTES(''SHA2_256'',CONCAT(profile.OrganizationId,N'':'',profile.Pipeline,N'':watermark'')),2),
      N''Vodni žig miruje'',N''Vodni žig ni napredoval v dovoljenem času.''
    FROM ops.ScheduleProfile profile
    INNER JOIN ops.IntegrationHealth health ON health.OrganizationId=profile.OrganizationId AND health.Pipeline=profile.Pipeline
    LEFT JOIN ops.OrganizationAutomationPolicy policy ON policy.OrganizationId=profile.OrganizationId
    WHERE profile.IsEnabled=1 AND COALESCE(policy.IsEnabled, CONVERT(bit, 1))=1
      AND health.WatermarkUtc IS NOT NULL AND health.WatermarkUtc<DATEADD(second,-profile.StaleAfterSeconds,@now)
  ) source ON target.OrganizationId=source.OrganizationId AND target.DedupKey=source.DedupKey AND target.ResolvedUtc IS NULL
  WHEN MATCHED THEN UPDATE SET LastSeenUtc=@now,OccurrenceCount=target.OccurrenceCount+1,UpdatedUtc=@now,UpdatedBy=@Actor
  WHEN NOT MATCHED THEN INSERT(OrganizationId,Pipeline,AlertKind,Severity,DedupKey,Title,PayloadSummaryRedacted,UpdatedBy)
    VALUES(source.OrganizationId,source.Pipeline,source.AlertKind,source.Severity,source.DedupKey,source.Title,source.PayloadSummaryRedacted,@Actor);
  UPDATE alert SET ResolvedUtc=@now,ResolvedBy=@Actor,UpdatedUtc=@now,UpdatedBy=@Actor
  FROM ops.Alert alert
  INNER JOIN ops.IntegrationHealth health ON health.OrganizationId=alert.OrganizationId AND health.Pipeline=alert.Pipeline
  WHERE alert.AlertKind=N''StaleHeartbeat'' AND alert.ResolvedUtc IS NULL AND health.Status IN(N''Healthy'',N''Running'')
    AND health.LastHeartbeatUtc>=DATEADD(second,-(SELECT StaleAfterSeconds FROM ops.ScheduleProfile WHERE OrganizationId=health.OrganizationId AND Pipeline=health.Pipeline),@now);
END;');

/* Dostava in prevzem dostave sta dodatno zaščitena, tudi če je worker zagnan ročno. */
EXEC(N'CREATE OR ALTER PROCEDURE ops.QueueAlertDeliveries
AS
BEGIN
  SET NOCOUNT ON;
  INSERT ops.AlertDelivery(AlertId,Channel,RecipientKey,NextAttemptUtc)
  SELECT alert.AlertId,recipient.Channel,recipient.RecipientKey,SYSUTCDATETIME()
  FROM ops.Alert alert
  INNER JOIN ops.AlertRecipientConfig recipient ON recipient.OrganizationId=alert.OrganizationId AND recipient.IsEnabled=1
  LEFT JOIN ops.OrganizationAutomationPolicy policy ON policy.OrganizationId=alert.OrganizationId
  WHERE alert.ResolvedUtc IS NULL AND COALESCE(policy.IsEnabled, CONVERT(bit, 1))=1
    AND CASE alert.Severity WHEN N''Critical'' THEN 3 WHEN N''Warning'' THEN 2 ELSE 1 END >= CASE recipient.MinimumSeverity WHEN N''Critical'' THEN 3 WHEN N''Warning'' THEN 2 ELSE 1 END
    AND NOT EXISTS (SELECT 1 FROM ops.AlertDelivery delivery WHERE delivery.AlertId=alert.AlertId AND delivery.Channel=recipient.Channel AND delivery.RecipientKey=recipient.RecipientKey);
END;');

EXEC(N'CREATE OR ALTER PROCEDURE ops.ClaimAlertDelivery @WorkerId nvarchar(200),@LeaseSeconds int=60
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON; BEGIN TRAN;
  ;WITH candidate AS
  (
    SELECT TOP(1) delivery.* FROM ops.AlertDelivery delivery WITH(UPDLOCK,READPAST,ROWLOCK)
    INNER JOIN ops.Alert alert ON alert.AlertId=delivery.AlertId
    LEFT JOIN ops.OrganizationAutomationPolicy policy ON policy.OrganizationId=alert.OrganizationId
    WHERE delivery.Status IN(N''Pending'',N''Retry'') AND (delivery.NextAttemptUtc IS NULL OR delivery.NextAttemptUtc<=SYSUTCDATETIME())
      AND (delivery.LeaseUntilUtc IS NULL OR delivery.LeaseUntilUtc<SYSUTCDATETIME())
      AND COALESCE(policy.IsEnabled, CONVERT(bit, 1))=1
    ORDER BY delivery.AlertDeliveryId
  )
  UPDATE candidate SET Status=N''Sending'',AttemptCount=AttemptCount+1,LeaseOwner=@WorkerId,LeaseUntilUtc=DATEADD(second,@LeaseSeconds,SYSUTCDATETIME()),UpdatedUtc=SYSUTCDATETIME()
  OUTPUT inserted.*; COMMIT;
END;');

/* Enaka izjema velja še za alarme, ki jih ustvari ura razporejevalnika. */
EXEC(N'CREATE OR ALTER PROCEDURE ops.RaiseOverdueAlerts @Actor nvarchar(200) = N''razporejevalnik''
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  DECLARE @now datetime2(3) = SYSUTCDATETIME();
  DECLARE @org int =
  (
    SELECT MIN(organizationValue.OrganizationId)
    FROM dbo.OrganizationConfig organizationValue
    LEFT JOIN ops.OrganizationAutomationPolicy policy ON policy.OrganizationId=organizationValue.OrganizationId
    WHERE organizationValue.IsActive=1 AND COALESCE(policy.IsEnabled, CONVERT(bit, 1))=1
  );

  DECLARE @cikli TABLE (Pipeline nvarchar(200), DedupKey varchar(64), Title nvarchar(300), Summary nvarchar(2000));
  IF @org IS NOT NULL
    INSERT @cikli (Pipeline, DedupKey, Title, Summary)
    SELECT CONCAT(N''CIKEL:'', cycleValue.CycleKey),
           CONVERT(varchar(64), HASHBYTES(''SHA2_256'', CONCAT(N''CycleOverdue:'', cycleValue.CycleKey)), 2),
           CONCAT(N''Cikel "'', cycleValue.Label, N''" ni tekel '', DATEDIFF(minute, COALESCE(cycleValue.LastStartedUtc, cycleValue.UpdatedUtc), @now), N'' min.''),
           CONCAT(N''Zadnji začetek: '', COALESCE(CONVERT(nvarchar(19), cycleValue.LastStartedUtc, 120), N''nikoli''),
                  N'' UTC. Preveri razporejevalnik in dnevnik na /sistem/workerji.'')
    FROM ops.WorkerCycle cycleValue
    WHERE cycleValue.IsEnabled=1 AND cycleValue.RunningRunId IS NULL
      AND DATEDIFF(second, COALESCE(cycleValue.LastStartedUtc, cycleValue.UpdatedUtc), @now) > cycleValue.WarnAfterMultiplier * COALESCE(cycleValue.IntervalSeconds, 86400);

  MERGE ops.Alert AS target
  USING (SELECT @org AS OrganizationId, Pipeline, DedupKey, Title, Summary FROM @cikli) AS source
    ON target.OrganizationId=source.OrganizationId AND target.DedupKey=source.DedupKey AND target.ResolvedUtc IS NULL
  WHEN MATCHED THEN UPDATE SET LastSeenUtc=@now, OccurrenceCount=target.OccurrenceCount+1, Title=source.Title, PayloadSummaryRedacted=source.Summary, UpdatedUtc=@now, UpdatedBy=@Actor
  WHEN NOT MATCHED BY TARGET AND source.OrganizationId IS NOT NULL THEN
    INSERT (OrganizationId,Pipeline,AlertKind,Severity,DedupKey,Title,PayloadSummaryRedacted,UpdatedBy)
    VALUES (source.OrganizationId,source.Pipeline,N''CycleOverdue'',N''Critical'',source.DedupKey,source.Title,source.Summary,@Actor);

  UPDATE alert SET ResolvedUtc=@now, ResolvedBy=@Actor, UpdatedUtc=@now, UpdatedBy=@Actor
  FROM ops.Alert alert WHERE alert.AlertKind=N''CycleOverdue'' AND alert.ResolvedUtc IS NULL
    AND NOT EXISTS (SELECT 1 FROM @cikli cycleValue WHERE cycleValue.DedupKey=alert.DedupKey)
    AND (alert.OrganizationId=@org OR @org IS NULL);

  DECLARE @postopki TABLE (OrganizationId int, Pipeline nvarchar(200), DedupKey varchar(64), Title nvarchar(300), Summary nvarchar(2000));
  INSERT @postopki (OrganizationId, Pipeline, DedupKey, Title, Summary)
  SELECT profile.OrganizationId, profile.Pipeline,
         CONVERT(varchar(64), HASHBYTES(''SHA2_256'', CONCAT(N''PipelineOverdue:'', profile.OrganizationId, N'':'', profile.Pipeline)), 2),
         CONCAT(N''Postopek '', profile.Pipeline, N'' ni tekel '', DATEDIFF(minute, COALESCE(health.LastHeartbeatUtc, profile.UpdatedUtc), @now), N'' min.''),
         CONCAT(N''Podjetje: '', organizationValue.Name, N''. Zadnji utrip: '', COALESCE(CONVERT(nvarchar(19), health.LastHeartbeatUtc, 120), N''nikoli''),
                N'' UTC. Preveri stanje in dnevnik na /sistem/workerji.'')
  FROM ops.ScheduleProfile profile
  INNER JOIN dbo.OrganizationConfig organizationValue ON organizationValue.OrganizationId=profile.OrganizationId
  LEFT JOIN ops.IntegrationHealth health ON health.OrganizationId=profile.OrganizationId AND health.Pipeline=profile.Pipeline
  LEFT JOIN ops.OrganizationAutomationPolicy policy ON policy.OrganizationId=profile.OrganizationId
  WHERE profile.IsEnabled=1 AND organizationValue.IsActive=1 AND COALESCE(policy.IsEnabled, CONVERT(bit, 1))=1
    AND DATEDIFF(second, COALESCE(health.LastHeartbeatUtc, profile.UpdatedUtc), @now)>2*profile.IntervalSeconds;

  MERGE ops.Alert AS target
  USING (SELECT OrganizationId,Pipeline,DedupKey,Title,Summary FROM @postopki) AS source
    ON target.OrganizationId=source.OrganizationId AND target.DedupKey=source.DedupKey AND target.ResolvedUtc IS NULL
  WHEN MATCHED THEN UPDATE SET LastSeenUtc=@now, OccurrenceCount=target.OccurrenceCount+1, Title=source.Title, PayloadSummaryRedacted=source.Summary, UpdatedUtc=@now, UpdatedBy=@Actor
  WHEN NOT MATCHED THEN INSERT (OrganizationId,Pipeline,AlertKind,Severity,DedupKey,Title,PayloadSummaryRedacted,UpdatedBy)
    VALUES (source.OrganizationId,source.Pipeline,N''PipelineOverdue'',N''Critical'',source.DedupKey,source.Title,source.Summary,@Actor);

  UPDATE alert SET ResolvedUtc=@now, ResolvedBy=@Actor, UpdatedUtc=@now, UpdatedBy=@Actor
  FROM ops.Alert alert WHERE alert.AlertKind=N''PipelineOverdue'' AND alert.ResolvedUtc IS NULL
    AND NOT EXISTS (SELECT 1 FROM @postopki profile WHERE profile.DedupKey=alert.DedupKey AND profile.OrganizationId=alert.OrganizationId);
END;');
