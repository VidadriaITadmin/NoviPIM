/*
  260 — »posel zamuja« ni čakanje na SAOP.

  David 2026-09-22 (posnetek strani Nadzor): »Zaloga iz SAOP — Zamuja« med ročnim tekom naročil.
  Gostitelj poganja posle, ki kličejo SAOP, po enega naenkrat z dvema minutama premora (zahteva ekipe
  SAOP, JobCatalog.UsesSaop). Ko teče daljši posel SAOP (naročila, ponoči dobavni roki za vse artikle,
  ~80 min), zaloga in cene čakajo — to ni zamuda, ampak vrsta. ops.EvaluateJobAlerts je takrat odprl
  kritičen alarm JobOverdue, ki je šel v zvonec in v e-pošto.

  Kaj naredi: v ops.EvaluateJobAlerts (živa definicija iz 256) doda pogoj, da posel SAOP ne zamuja,
  dokler teče drug posel SAOP. Seznam poslov SAOP je isti kot JobCatalog.UsesSaop v kodi.
  Odprt JobOverdue, ki ga ta pogoj ne bi odprl, se zapre ob naslednjem vrednotenju samodejno.
  Stran Nadzor ima enako pravilo v MonitorPolicy (»Čaka na SAOP«, siva).
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;

DECLARE @definicija nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'ops.EvaluateJobAlerts'));
DECLARE @staro nvarchar(400) = N'WHERE j.IsEnabled = 1 AND j.RunningJobRunId IS NULL AND j.NextDueUtc IS NOT NULL AND j.NextDueUtc < @now';
DECLARE @novo nvarchar(max) = @staro + N'
    /* 260: posel SAOP, ki čaka, da drug posel SAOP konča (en klic SAOP naenkrat), ne zamuja. */
    AND NOT (j.JobKey IN (N''SAOP_PRODUCT_IMPORT'', N''SAOP_ORDER_IMPORT'', N''STOCK_IMPORT'', N''PRICE_IMPORT'', N''SAOP_DELIVERY_IMPORT'', N''NIGHTLY_RECONCILIATION'', N''SAOP_OUTBOUND_DISPATCH'')
             AND EXISTS (SELECT 1 FROM ops.JobDefinition busy
                         WHERE busy.JobKey <> j.JobKey AND busy.RunningJobRunId IS NOT NULL
                           AND busy.JobKey IN (N''SAOP_PRODUCT_IMPORT'', N''SAOP_ORDER_IMPORT'', N''STOCK_IMPORT'', N''PRICE_IMPORT'', N''SAOP_DELIVERY_IMPORT'', N''NIGHTLY_RECONCILIATION'', N''SAOP_OUTBOUND_DISPATCH'')))';

IF CHARINDEX(N'/* 260:', @definicija) = 0
BEGIN
  IF CHARINDEX(@staro, @definicija) = 0
    THROW 52600, N'260: v ops.EvaluateJobAlerts ni pričakovanega pogoja zamude (definicija iz 256).', 1;
  SET @definicija = REPLACE(@definicija, @staro, @novo);
  SET @definicija = STUFF(@definicija, CHARINDEX(N'CREATE', @definicija), LEN(N'CREATE'), N'CREATE OR ALTER');
  EXEC(@definicija);
END;

IF CHARINDEX(N'/* 260:', OBJECT_DEFINITION(OBJECT_ID(N'ops.EvaluateJobAlerts'))) = 0
  THROW 52601, N'260: ops.EvaluateJobAlerts ni posodobljen.', 1;
