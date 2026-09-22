/*
  261 — dvominutni premor po poslu SAOP tudi ni zamuda (dopolnilo 260).

  Po koncu vsakega posla, ki kliče SAOP, gostitelj počaka JobCatalog.SaopQuietSeconds (120 s), preden začne
  naslednjega. 260 je upoštevala samo posel, ki TEČE; v premoru po koncu je alarm JobOverdue za zalogo še
  vedno zazvonil (2026-09-22 22:45, »Zaloga iz SAOP zamuja 13 min«). Pot do SAOP je zasedena tudi, kadar
  se je posel SAOP končal v zadnjih 180 s (premor + minuta tika). Stran Nadzor ima isto pravilo.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;

DECLARE @definicija nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'ops.EvaluateJobAlerts'));
DECLARE @staro nvarchar(200) = N'WHERE busy.JobKey <> j.JobKey AND busy.RunningJobRunId IS NOT NULL';
DECLARE @novo nvarchar(400) = N'WHERE busy.JobKey <> j.JobKey AND (busy.RunningJobRunId IS NOT NULL OR busy.LastEndedUtc > DATEADD(second, -180, @now)) /* 261 */';

IF CHARINDEX(N'/* 261 */', @definicija) = 0
BEGIN
  IF CHARINDEX(@staro, @definicija) = 0
    THROW 52610, N'261: v ops.EvaluateJobAlerts ni pogoja iz 260.', 1;
  SET @definicija = REPLACE(@definicija, @staro, @novo);
  SET @definicija = STUFF(@definicija, CHARINDEX(N'CREATE', @definicija), LEN(N'CREATE'), N'CREATE OR ALTER');
  EXEC(@definicija);
END;

IF CHARINDEX(N'/* 261 */', OBJECT_DEFINITION(OBJECT_ID(N'ops.EvaluateJobAlerts'))) = 0
  THROW 52611, N'261: ops.EvaluateJobAlerts ni posodobljen.', 1;
