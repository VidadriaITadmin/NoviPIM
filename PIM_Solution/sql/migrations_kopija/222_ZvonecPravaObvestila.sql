/*
  222 — Zvonec kaze prava obvestila: uskladitev imen vrst alarmov, narocnin in popravek
  podvojenega kodiranja besedila.

  Zvonec (MainLayout, migracija 188) in narocnine (migracija 214, razsirjene v 221) seznam v
  spustnem meniju filtrirajo po intranet.UserAlertSubscription.AlertKind. Trije zivi proizvajalci
  alarmov pisejo vrsto, ki je na seznamu dovoljenih vrst ni bilo, zato zvonec njihovih alarmov
  ni mogel pokazati NIKOMUR, ne glede na narocnino ali resnost:

    1) ops.EvaluateReservationExclusionAlerts (187) pise AlertKind N'RESERVATION_EXCLUSION'
       (eno vrstico na artikel — glej PayloadSummaryRedacted "Sifra: ..."), medtem ko
       map.ProcessPlanningInbox za isto temo (agregatno, ena vrstica na podjetje, kriticna) pise
       N'ReservationExcluded'. Migracija 214 pozna samo slednjo. Posledica: 616 odprtih
       opozoril, vsako o enem konkretnem artiklu, je bilo v zvoncu trajno nevidnih — dosegljiva
       so bila samo prek /sistem/integracije. Ta migracija obe zdruzi pod N'ReservationExcluded'
       (preimenuje proceduro IN obstojece vrstice); Pipeline stolpec ('ReservationExclusion' za
       artikel, 'SAOP_PRODUCTS' za agregat) ostane razlicen, da se vir vidi.
    2) ops.EvaluateStockSnapshotAlerts (179) pise N'StockSnapshotStale'/N'StockSnapshotEmpty'.
    3) ops.SetExportRejectionAlert pise N'ExportRejected'.
  Noben od teh treh ni bil na seznamu CK_UserAlertSubscription_Kind niti po 221 (ki je dodala
  PipelinePaused/CycleOverdue/PipelineOverdue za isti razlog). Ta migracija doda vse tri.

  Migracija 190 je 15. 9. rocno zasejala 4 agregatna ReservationExcluded opozorila (po eno na
  podjetje, glej UpdatedBy='migracija 190'); besedilo je bilo ob tem rocnem zapisu podvojeno
  kodirano (UTF-8 prebran kot Windows-1250: "Izločitve" -> "IzloÄŤitve") in se od takrat ni
  osvezilo, ker je SAOP_PRODUCTS pri vseh 4 podjetjih v napaki (ops.IntegrationHealth.Status =
  'Failed', zadnji utrip > 2h nazaj) in torej ne tece znova. Brez pipelinea, ki bi ga sam
  popravil, bi se v prenovljenem, zdaj vidnem zvoncu prikazovalo pokvarjeno besedilo — to je bilo
  tocno videti kot glavni razlog za obcutek "ni profesionalno". Ta migracija besedilo teh 4
  vrstic popravi nazaj na cisto obliko, ki jo pise map.ProcessPlanningInbox (stevilka izdelkov je
  ohranjena, popravi se samo okoliski, staticni del besedila).
*/

SET XACT_ABORT ON;

/* --- 1: ena sama, dosledna vrsta za izlocitve iz rezervacije zaloge --------------------- */

EXEC(N'CREATE OR ALTER PROCEDURE ops.EvaluateReservationExclusionAlerts
  @Actor nvarchar(200) = N''intranet''
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  DECLARE @now datetime2(3) = SYSUTCDATETIME();

  MERGE ops.Alert AS target
  USING
  (
    SELECT product.OrganizationId, N''ReservationExclusion'' AS Pipeline,
      N''ReservationExcluded'' AS AlertKind, N''Warning'' AS Severity,
      CONVERT(varchar(64), HASHBYTES(''SHA2_256'', CONCAT(product.OrganizationId, N'':reservation-exclusion:'', product.ProductId)), 2) AS DedupKey,
      N''Artikel je izlocen iz rezervacije zaloge'' AS Title,
      CONCAT(N''Sifra: '', product.ItemID, N''. Kljukica ne bi smela biti nastavljena, razen za izjeme.'') AS PayloadSummaryRedacted
    FROM canon.Product AS product
    INNER JOIN canon.ProductPlanning AS planning ON planning.ProductId = product.ProductId
    WHERE planning.ExcludeQuantityReservation = 1
      AND NOT EXISTS (SELECT 1 FROM pim.ReservationExclusionException exception WHERE exception.ProductId = product.ProductId)
  ) AS source
    ON target.OrganizationId = source.OrganizationId AND target.DedupKey = source.DedupKey AND target.ResolvedUtc IS NULL
  WHEN MATCHED THEN UPDATE SET LastSeenUtc = @now, OccurrenceCount = target.OccurrenceCount + 1, UpdatedUtc = @now, UpdatedBy = @Actor
  WHEN NOT MATCHED THEN
    INSERT (OrganizationId, Pipeline, AlertKind, Severity, DedupKey, Title, PayloadSummaryRedacted, UpdatedBy)
    VALUES (source.OrganizationId, source.Pipeline, source.AlertKind, source.Severity, source.DedupKey, source.Title, source.PayloadSummaryRedacted, @Actor);

  /*
    Razresi, kar ni vec anomalija. Pipeline = ''ReservationExclusion'' omeji to na alarme TE
    procedure: odkar (222) N''ReservationExcluded'' pise tudi map.ProcessPlanningInbox (agregatno,
    Pipeline=''SAOP_PRODUCTS''), bi brez tega pogoja spodnji NOT EXISTS napacno zaprl tudi agregatne
    alarme, ki jih ta procedura sploh ne pozna.
  */
  UPDATE alert SET ResolvedUtc = @now, ResolvedBy = @Actor, UpdatedUtc = @now, UpdatedBy = @Actor
  FROM ops.Alert AS alert
  WHERE alert.AlertKind = N''ReservationExcluded'' AND alert.Pipeline = N''ReservationExclusion'' AND alert.ResolvedUtc IS NULL
    AND NOT EXISTS
    (
      SELECT 1
      FROM canon.Product product
      INNER JOIN canon.ProductPlanning planning ON planning.ProductId = product.ProductId
      WHERE product.OrganizationId = alert.OrganizationId
        AND planning.ExcludeQuantityReservation = 1
        AND NOT EXISTS (SELECT 1 FROM pim.ReservationExclusionException exception WHERE exception.ProductId = product.ProductId)
        AND alert.DedupKey = CONVERT(varchar(64), HASHBYTES(''SHA2_256'', CONCAT(product.OrganizationId, N'':reservation-exclusion:'', product.ProductId)), 2)
    );
END;');

/* Obstojece vrstice preimenuj v novo, dosledno vrsto. DedupKey, OccurrenceCount in vsa
   zgodovina ostanejo — preimenovanje ne more trciti ob obstojeco vrstico, ker je edinstvenost
   UX_Alert_OpenDedup samo na (OrganizationId, DedupKey), ne na AlertKind. */
UPDATE ops.Alert SET AlertKind = N'ReservationExcluded', UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = N'222: uskladitev imena vrste alarma'
WHERE AlertKind = N'RESERVATION_EXCLUSION';

/* --- 2: popravek podvojenega kodiranja iz rocnega zasevanja (190, 15. 9.) --------------- */

UPDATE ops.Alert
SET Title = N'Izlocitve iz rezervacije zaloge',
    PayloadSummaryRedacted = CONCAT(
      LEFT(PayloadSummaryRedacted, PATINDEX('%[^0-9]%', PayloadSummaryRedacted + 'X') - 1),
      N' izdelkov je se vedno izlocenih iz rezervacije zaloge (SAOP).'),
    UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = N'222: popravek podvojenega kodiranja besedila'
WHERE AlertKind = N'ReservationExcluded' AND Pipeline = N'SAOP_PRODUCTS' AND ResolvedUtc IS NULL
  AND Title <> N'Izlocitve iz rezervacije zaloge';

/* --- 3: zvonec pozna se preostale zive vrste alarmov ------------------------------------ */

IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_UserAlertSubscription_Kind')
  ALTER TABLE intranet.UserAlertSubscription DROP CONSTRAINT CK_UserAlertSubscription_Kind;

ALTER TABLE intranet.UserAlertSubscription ADD CONSTRAINT CK_UserAlertSubscription_Kind CHECK (AlertKind IN (
  N'StaleHeartbeat', N'OutboundDead', N'OutboundDrift', N'StalledWatermark',
  N'PipelineDisabled', N'ReservationExcluded', N'OutboundUnacknowledged',
  N'PipelinePaused', N'CycleOverdue', N'PipelineOverdue',
  N'StockSnapshotStale', N'StockSnapshotEmpty', N'ExportRejected'));

/* Obstojeci skrbniki: brez tega bi ta migracija dodala vrste, na katere ni nihce narocen, in bi
   zvonec za njih se naprej molcal, dokler admin sam ne bi vedel, da jih mora vklopiti. */
INSERT intranet.UserAlertSubscription (UserName, AlertKind, UpdatedBy)
SELECT localUser.UserName, kind.AlertKind, N'222_ZvonecPravaObvestila'
FROM sec.LocalUser localUser
INNER JOIN sec.LocalUserRole userRole ON userRole.LocalUserId = localUser.LocalUserId
INNER JOIN sec.Role roleValue ON roleValue.RoleId = userRole.RoleId AND roleValue.RoleCode = N'ADMIN'
CROSS JOIN (VALUES (N'StockSnapshotStale'), (N'StockSnapshotEmpty'), (N'ExportRejected')) AS kind(AlertKind)
WHERE NOT EXISTS (
  SELECT 1 FROM intranet.UserAlertSubscription existing
  WHERE existing.UserName = localUser.UserName AND existing.AlertKind = kind.AlertKind);

/* --- preverba ---------------------------------------------------------------------------- */

IF EXISTS (SELECT 1 FROM ops.Alert WHERE AlertKind = N'RESERVATION_EXCLUSION')
  THROW 52218, N'222: se vedno obstajajo vrstice s staro vrsto RESERVATION_EXCLUSION.', 1;
IF EXISTS (SELECT 1 FROM ops.Alert WHERE AlertKind = N'ReservationExcluded' AND Pipeline = N'SAOP_PRODUCTS' AND ResolvedUtc IS NULL AND Title <> N'Izlocitve iz rezervacije zaloge')
  THROW 52219, N'222: besedilo agregatnih ReservationExcluded opozoril se ni popravljeno.', 1;
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_UserAlertSubscription_Kind' AND definition LIKE '%ExportRejected%' AND definition LIKE '%StockSnapshotStale%')
  THROW 52220, N'222: CK_UserAlertSubscription_Kind se vedno ne pozna vseh zivih vrst alarmov.', 1;
