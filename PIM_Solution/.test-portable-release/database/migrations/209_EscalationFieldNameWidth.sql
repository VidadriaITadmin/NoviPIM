/*
  209 — ops.EscalateOutboundEvents ne sme pasti na dolgem imenu polja.

  Najdeno 2026-09-15: naloga »PIM nadzor« je vsakih pet minut koncala z napako, ker je
  PIM.AlertDispatcher padel v ops.EscalateOutboundEvents z
  "String or binary data would be truncated in table '#...', column 'FieldName'" (2628).

  Migracija 196 je ops.OutboundEvent.FieldName razsirila na nvarchar(400), ker obvestilo za en
  dokument zdruzi imena vseh spremenjenih polj. Stopnjevanje pa je ta stolpec se naprej bralo v
  tabelno spremenljivko in kurzor z nvarchar(200). V razvojni bazi sta taka dva nepotrjena
  dogodka (369 znakov, 2026-09-11), zato je padel vsak zagon: stopnjevanje ni stopnjevalo
  nicesar in razposiljanje alarmov ni prislo do vrste.

  Popravek: isti tip kot stolpec, nvarchar(400). Telo je sicer nespremenjeno od 090.
*/

SET XACT_ABORT ON;

EXEC(N'
CREATE OR ALTER PROCEDURE ops.EscalateOutboundEvents
  @AfterSeconds int = 300, @Actor nvarchar(200) = N''ops.Escalate''
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  DECLARE @Prag datetime2(3) = DATEADD(second, -@AfterSeconds, SYSUTCDATETIME());

  /* FieldName ima isti tip kot ops.OutboundEvent.FieldName (196). Ozji tip tu pomeni, da en
     dolg dogodek ustavi stopnjevanje vseh ostalih. */
  DECLARE @ZaStopnjevanje TABLE
  (
    OutboundEventId bigint PRIMARY KEY, OrganizationId int, EntityKey nvarchar(450),
    Title nvarchar(300), Detail nvarchar(2000), FieldName nvarchar(400)
  );

  UPDATE dogodek SET EscalatedUtc = SYSUTCDATETIME()
  OUTPUT inserted.OutboundEventId, inserted.OrganizationId, inserted.EntityKey,
         inserted.Title, inserted.Detail, inserted.FieldName INTO @ZaStopnjevanje
  FROM ops.OutboundEvent AS dogodek
  WHERE dogodek.Severity = N''Error'' AND dogodek.AcknowledgedUtc IS NULL
    AND dogodek.EscalatedUtc IS NULL AND dogodek.CreatedUtc <= @Prag;

  IF NOT EXISTS(SELECT 1 FROM @ZaStopnjevanje) BEGIN SELECT Stopnjevanih = 0; RETURN; END;

  DECLARE @EventId bigint, @OrganizationId int, @EntityKey nvarchar(450),
          @Title nvarchar(300), @Detail nvarchar(2000), @FieldName nvarchar(400);

  DECLARE dogodki CURSOR LOCAL FAST_FORWARD FOR
    SELECT OutboundEventId, OrganizationId, EntityKey, Title, Detail, FieldName FROM @ZaStopnjevanje;
  OPEN dogodki;
  FETCH NEXT FROM dogodki INTO @EventId, @OrganizationId, @EntityKey, @Title, @Detail, @FieldName;

  WHILE @@FETCH_STATUS = 0
  BEGIN
    /* Dedup po dogodku: isti dogodek ne sme poslati dveh e-post. */
    DECLARE @DedupKey varchar(64) =
      CONVERT(varchar(64), HASHBYTES(''SHA2_256'', CONCAT(N''outbound-event:'', @EventId)), 2);

    EXEC ops.UpsertAlert
      @OrganizationId = @OrganizationId, @Pipeline = N''OUTBOUND'', @AlertKind = N''OutboundUnacknowledged'',
      @Severity = N''Critical'', @DedupKey = @DedupKey,
      @Title = @Title,
      @PayloadSummaryRedacted = @Detail,
      @Actor = @Actor;

    FETCH NEXT FROM dogodki INTO @EventId, @OrganizationId, @EntityKey, @Title, @Detail, @FieldName;
  END;

  CLOSE dogodki;
  DEALLOCATE dogodki;

  EXEC ops.QueueAlertDeliveries;
  SELECT Stopnjevanih = (SELECT COUNT(*) FROM @ZaStopnjevanje);
END;');

/* --- preverba ---------------------------------------------------------------- */

IF OBJECT_DEFINITION(OBJECT_ID(N'ops.EscalateOutboundEvents')) LIKE N'%FieldName nvarchar(200)%'
  THROW 52909, 'ops.EscalateOutboundEvents ima FieldName se vedno nvarchar(200).', 1;

IF (SELECT max_length / 2 FROM sys.columns WHERE object_id = OBJECT_ID(N'ops.OutboundEvent') AND name = N'FieldName') > 400
  THROW 52910, 'ops.OutboundEvent.FieldName je sirsi od stopnjevanja; uskladi 209.', 1;
