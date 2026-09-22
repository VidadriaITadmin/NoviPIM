/*
  190 — arhiviran (neaktiven) izdelek ne sproža obvestil o izločitvi in izgubi zastavico.

  Zahteva uporabnika 2026-09-10: "any archived products dont send notifications even if they
  get flagged because archived means no longer in use... if a product is archived it also
  should lose its flag". Preverjeno pred popravkom: od 616 danes izločenih izdelkov jih je
  306 (skoraj polovica) že arhiviranih (canon.Product.IsActive = 0) — to je bil pravi signal,
  ne robni primer.

  Kaj nastane:

  1) canon.TR_Product_ClearReservationFlagOnArchive — sprozilec na canon.Product (isti vzorec
     kot ze obstojeci canon.TR_Product_FieldHistory: AFTER UPDATE, join inserted/deleted po
     ProductId, brez kurzorja). Kadar IsActive preide iz 1 v 0, se ExcludeQuantityReservation
     za ta izdelek takoj pobrise. Sprozilec je namenoma na canon.Product in ne dodan v
     map.ProcessRawInbox (velika, ze preverjena splosna zajemna procedura za skoraj vsa polja
     izdelka) — locen, majhen sprozilec je enako ucinkovit, a se ne dotika kode, ki je danes
     ze v produkciji za vse izdelke.

  2) Backfill: obstojecih 306 izlocenih-in-arhiviranih izdelkov dobi ExcludeQuantityReservation
     = 0 takoj, ne sele ob naslednji spremembi IsActive (sprozilec bi jih sicer nikoli ne ujel,
     ker so arhivirani ze zdaj, ne sele od zdaj naprej).

  3) map.ProcessPlanningInbox: zaznava "na novo izloceno" (#NovoZaznano) in stevec za alarm
     (@SkupajIzlocenih) odslej izkljucita arhivirane izdelke (artikel.IsActive = 1) — ce SAOP
     posodobi planning podatke za ze arhiviran izdelek na true, se to ne sprozi kot novo
     obvestilo niti odhodno potrditev, in se ne steje v stevilo "se vedno izlocenih".

  4) Obstojeca 4 obvestila (DEMO/IQLighting/Vidadria/Ediito) se takoj posodobijo na novo,
     manjse stevilo po backfillu — enako kot je 188 storila za Severity, da se popravek pozna
     takoj in ne sele ob naslednji sinhronizaciji.
*/

SET XACT_ABORT ON;

/* --- 1) Sprozilec: arhiviranje izprazni zastavico ----------------------------------------- */

EXEC(N'
CREATE OR ALTER TRIGGER canon.TR_Product_ClearReservationFlagOnArchive ON canon.Product AFTER UPDATE
AS
BEGIN
  IF ROWCOUNT_BIG() = 0 RETURN;
  SET NOCOUNT ON;
  IF NOT UPDATE(IsActive) RETURN;

  UPDATE planning
  SET ExcludeQuantityReservation = 0, UpdatedUtc = SYSUTCDATETIME()
  FROM canon.ProductPlanning planning
  INNER JOIN inserted i ON i.ProductId = planning.ProductId
  INNER JOIN deleted d ON d.ProductId = i.ProductId
  WHERE d.IsActive = 1 AND i.IsActive = 0 AND planning.ExcludeQuantityReservation = 1;
END;
');

/* --- 2) Backfill: obstojeci arhivirani + izloceni izgubijo zastavico takoj ---------------- */

UPDATE planning
SET ExcludeQuantityReservation = 0, UpdatedUtc = SYSUTCDATETIME()
FROM canon.ProductPlanning planning
INNER JOIN canon.Product artikel ON artikel.ProductId = planning.ProductId
WHERE planning.ExcludeQuantityReservation = 1 AND artikel.IsActive = 0;

/* --- 3) Zajem planiranja: arhivirani izdelki ne sprozijo obvestila niti potrditve --------- */

EXEC(N'
CREATE OR ALTER PROCEDURE map.ProcessPlanningInbox
  @RunId uniqueidentifier,
  @OrganizationId int,
  @SourceCode nvarchar(100)
AS
BEGIN
  /*
    Planiranje: dobavni rok, kolicine in stikala, po katerih ERP odloca o narocanju. Ena vrstica
    na artikel.

    Prenesenih je sedem polj od sedemindvajsetih, ki jih SAOP poslje. Ostalo je notranje
    racunovodstvo proizvodnje (pretvorniki, povrsine, MIT) in ga PIM ne rabi; ce se izkaze, da
    ga kdo potrebuje, je dodajanje vrstica registra in stolpec, ne nov zajem.

    Migracija 187/188/190: pred MERGE se shrani prejsnja vrednost ExcludeQuantityReservation za
    izdelke te strani. Za vsak NA NOVO izloceni AKTIVNI izdelek (prej 0/NULL, zdaj 1; arhivirani
    izdelki se od 190 naprej izkljuceni — glej canon.TR_Product_ClearReservationFlagOnArchive za
    obratno smer, ko se izdelek arhivira potem, ko je ze izlocen) nastane odhodna potrditev za
    SAOP (out.EnqueueSaopItemChange, vrednost ''true''), ki caka na odobritev v Izhod v SAOP ->
    Cakalna vrsta, in se osvezi EN alarm na organizacijo v ops.Alert (prek ops.UpsertAlert,
    Severity Critical od 188 naprej, stevec od 190 naprej samo aktivni izdelki) s trenutnim
    skupnim stevilom izlocenih. Ponovno branje iste vrednosti 1 se ne ponovi, ker #Prej takrat
    ze kaze 1.
  */
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  DECLARE @InboxId bigint;
  DECLARE zajem_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT inbox.InboxId
    FROM raw.Inbox inbox
    WHERE inbox.RunId=@RunId AND inbox.OrganizationId=@OrganizationId
      AND inbox.SourceCode=@SourceCode AND inbox.Status=''Pending''
      AND EXISTS
      (
        SELECT 1
        FROM map.EntityMapping entityMapping
        INNER JOIN map.SourceConnector connector ON connector.SourceConnectorId=entityMapping.SourceConnectorId
        WHERE connector.SourceCode=inbox.SourceCode AND connector.OrganizationId=inbox.OrganizationId
          AND entityMapping.EntityType=inbox.EntityType AND entityMapping.IsActive=1
          AND entityMapping.TargetDomain=''ProductPlanning''
      )
    ORDER BY inbox.InboxId;

  OPEN zajem_cursor;
  FETCH NEXT FROM zajem_cursor INTO @InboxId;
  WHILE @@FETCH_STATUS=0
  BEGIN
    BEGIN TRY
      BEGIN TRANSACTION;

      IF OBJECT_ID(''tempdb..#Zapis'') IS NOT NULL DROP TABLE #Zapis;
      IF OBJECT_ID(''tempdb..#Prej'') IS NOT NULL DROP TABLE #Prej;
      IF OBJECT_ID(''tempdb..#NovoZaznano'') IS NOT NULL DROP TABLE #NovoZaznano;

      SELECT izdelek.ProductId,
        TRY_CONVERT(int, zapis.LeadTime) AS LeadTimeDays,
        TRY_CONVERT(int, zapis.PurchaseLeadTime) AS PurchaseLeadTimeDays,
        TRY_CONVERT(int, zapis.AggregationPeriodDays) AS AggregationPeriodDays,
        TRY_CONVERT(decimal(19,4), zapis.LeadTimeQty) AS LeadTimeQuantity,
        TRY_CONVERT(decimal(19,4), zapis.OptimumProductionQty) AS OptimumProductionQuantity,
        CASE WHEN LOWER(LTRIM(RTRIM(ISNULL(zapis.ExcludeQtyReservation,'''')))) IN (''true'',''1'',''da'') THEN 1 ELSE 0 END AS ExcludeQuantityReservation,
        CASE WHEN LOWER(LTRIM(RTRIM(ISNULL(zapis.Phantom,'''')))) IN (''true'',''1'',''da'') THEN 1 ELSE 0 END AS IsPhantom
      INTO #Zapis
      FROM
      (
        SELECT value.RecordOrdinal,
          MAX(CASE WHEN value.TargetFieldCode=''Record.ItemID'' THEN CONVERT(nvarchar(100),value.Value) END) AS ItemID,
          MAX(CASE WHEN value.TargetFieldCode=''Planning.LeadTime'' THEN CONVERT(nvarchar(50),value.Value) END) AS LeadTime,
          MAX(CASE WHEN value.TargetFieldCode=''Planning.PurchaseLeadTime'' THEN CONVERT(nvarchar(50),value.Value) END) AS PurchaseLeadTime,
          MAX(CASE WHEN value.TargetFieldCode=''Planning.AggregationPeriodDays'' THEN CONVERT(nvarchar(50),value.Value) END) AS AggregationPeriodDays,
          MAX(CASE WHEN value.TargetFieldCode=''Planning.LeadTimeQty'' THEN CONVERT(nvarchar(50),value.Value) END) AS LeadTimeQty,
          MAX(CASE WHEN value.TargetFieldCode=''Planning.OptimumProductionQty'' THEN CONVERT(nvarchar(50),value.Value) END) AS OptimumProductionQty,
          MAX(CASE WHEN value.TargetFieldCode=''Planning.ExcludeQtyReservation'' THEN CONVERT(nvarchar(20),value.Value) END) AS ExcludeQtyReservation,
          MAX(CASE WHEN value.TargetFieldCode=''Planning.Phantom'' THEN CONVERT(nvarchar(20),value.Value) END) AS Phantom
        FROM map.ExtractedValue value
        WHERE value.InboxId=@InboxId
          AND EXISTS(SELECT 1 FROM map.FieldMapping mapping
                     WHERE mapping.FieldMappingId=value.FieldMappingId AND mapping.IsActive=1)
        GROUP BY value.RecordOrdinal
      ) zapis
      INNER JOIN canon.Product izdelek
        ON izdelek.OrganizationId=@OrganizationId AND izdelek.ItemID=LTRIM(RTRIM(zapis.ItemID));

      SELECT planning.ProductId, planning.ExcludeQuantityReservation AS PrejsnjaVrednost
      INTO #Prej
      FROM canon.ProductPlanning planning
      WHERE planning.ProductId IN (SELECT DISTINCT ProductId FROM #Zapis);

      MERGE canon.ProductPlanning AS target
      USING (SELECT DISTINCT ProductId, LeadTimeDays, PurchaseLeadTimeDays, AggregationPeriodDays,
                    LeadTimeQuantity, OptimumProductionQuantity, ExcludeQuantityReservation, IsPhantom FROM #Zapis) source
        ON target.ProductId=source.ProductId
      WHEN MATCHED THEN UPDATE SET LeadTimeDays=source.LeadTimeDays, PurchaseLeadTimeDays=source.PurchaseLeadTimeDays,
        AggregationPeriodDays=source.AggregationPeriodDays, LeadTimeQuantity=source.LeadTimeQuantity,
        OptimumProductionQuantity=source.OptimumProductionQuantity,
        ExcludeQuantityReservation=source.ExcludeQuantityReservation, IsPhantom=source.IsPhantom,
        UpdatedUtc=SYSUTCDATETIME()
      WHEN NOT MATCHED THEN INSERT(ProductId,LeadTimeDays,PurchaseLeadTimeDays,AggregationPeriodDays,
        LeadTimeQuantity,OptimumProductionQuantity,ExcludeQuantityReservation,IsPhantom)
        VALUES(source.ProductId,source.LeadTimeDays,source.PurchaseLeadTimeDays,source.AggregationPeriodDays,
               source.LeadTimeQuantity,source.OptimumProductionQuantity,source.ExcludeQuantityReservation,source.IsPhantom);

      /* Novo izloceni: danes izloceni (1), prej niso bili (0 ali sploh se niso obstajali v #Prej),
         in izdelek ni arhiviran — arhiviran izdelek ne rabi ne obvestila ne odhodne potrditve. */
      SELECT DISTINCT zapis.ProductId, izdelek.ItemID
      INTO #NovoZaznano
      FROM #Zapis zapis
      INNER JOIN canon.Product izdelek ON izdelek.ProductId = zapis.ProductId
      WHERE zapis.ExcludeQuantityReservation = 1
        AND izdelek.IsActive = 1
        AND NOT EXISTS (SELECT 1 FROM #Prej prej WHERE prej.ProductId = zapis.ProductId AND prej.PrejsnjaVrednost = 1);

      IF EXISTS (SELECT 1 FROM #NovoZaznano)
      BEGIN
        DECLARE @NZ_ProductId bigint, @NZ_ItemID nvarchar(450), @NZ_OutboxMessageId bigint;
        DECLARE novo_cursor CURSOR LOCAL FAST_FORWARD FOR SELECT ProductId, ItemID FROM #NovoZaznano;
        OPEN novo_cursor;
        FETCH NEXT FROM novo_cursor INTO @NZ_ProductId, @NZ_ItemID;
        WHILE @@FETCH_STATUS = 0
        BEGIN
          SET @NZ_OutboxMessageId = NULL;
          EXEC out.EnqueueSaopItemChange
            @OrganizationId = @OrganizationId, @ItemID = @NZ_ItemID, @FieldKey = N''Planning.ExcludeQtyReservation'',
            @Value = N''true'', @Actor = N''map.ProcessPlanningInbox'', @OutboundBatchId = NULL,
            @OutboxMessageId = @NZ_OutboxMessageId OUTPUT;

          FETCH NEXT FROM novo_cursor INTO @NZ_ProductId, @NZ_ItemID;
        END;
        CLOSE novo_cursor;
        DEALLOCATE novo_cursor;

        /* En alarm na organizacijo v notifikacijskem centru (ops.Alert), ne eno na izdelek.
           Stevec upostevana samo aktivne izdelke (190). Vrednosti parametrov EXEC morajo biti
           spremenljivke, ne izrazi — sicer SQL Server v tako globoko gnezdenem kontekstu
           (WHILE v WHILE v IF) prijavi "Incorrect syntax", ceprav je isti klic v plitkem
           kontekstu videti veljaven. Zato je vsaka vrednost najprej v svoji spremenljivki. */
        DECLARE @SkupajIzlocenih int;
        SET @SkupajIzlocenih =
        (
          SELECT COUNT(*)
          FROM canon.ProductPlanning planiranje
          INNER JOIN canon.Product artikel ON artikel.ProductId = planiranje.ProductId
          WHERE artikel.OrganizationId = @OrganizationId AND planiranje.ExcludeQuantityReservation = 1
            AND artikel.IsActive = 1
        );

        DECLARE @ReservationDedupKey varchar(64);
        SET @ReservationDedupKey =
          CONVERT(varchar(64), HASHBYTES(''SHA2_256'', CONCAT(@OrganizationId, N'':reservation-excluded'')), 2);

        DECLARE @ReservationPayload nvarchar(2000);
        SET @ReservationPayload = CONCAT(@SkupajIzlocenih, N'' izdelkov je se vedno izlocenih iz rezervacije zaloge (SAOP).'');

        EXEC ops.UpsertAlert
          @OrganizationId = @OrganizationId, @Pipeline = N''SAOP_PRODUCTS'', @AlertKind = N''ReservationExcluded'',
          @Severity = N''Critical'', @DedupKey = @ReservationDedupKey,
          @Title = N''Izlocitve iz rezervacije zaloge'',
          @PayloadSummaryRedacted = @ReservationPayload,
          @Actor = N''map.ProcessPlanningInbox'';
      END;

      DECLARE @Zapisov int = (SELECT COUNT(DISTINCT value.RecordOrdinal) FROM map.ExtractedValue value WHERE value.InboxId=@InboxId);
      DECLARE @Uporabljenih int = (SELECT COUNT(*) FROM #Zapis);

      UPDATE raw.Inbox
      SET Status=''Processed'', ProcessedUtc=SYSUTCDATETIME(),
          FailureReason=CASE WHEN @Uporabljenih=@Zapisov THEN NULL
            ELSE CONCAT(''Uporabljenih: '', @Uporabljenih, '' od '', @Zapisov, ''. Preostali nimajo artikla v katalogu.'') END
      WHERE InboxId=@InboxId;

      DROP TABLE #Zapis;
      DROP TABLE #Prej;
      IF OBJECT_ID(''tempdb..#NovoZaznano'') IS NOT NULL DROP TABLE #NovoZaznano;
      COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
      IF XACT_STATE()<>0 ROLLBACK TRANSACTION;
      DECLARE @Napaka nvarchar(500)=ERROR_MESSAGE();
      UPDATE raw.Inbox SET Status=''Quarantined'', ProcessedUtc=SYSUTCDATETIME(), FailureReason=LEFT(@Napaka,2000)
      WHERE InboxId=@InboxId;
    END CATCH;

    FETCH NEXT FROM zajem_cursor INTO @InboxId;
  END;
  CLOSE zajem_cursor;
  DEALLOCATE zajem_cursor;
END;
');

/* --- 4) Osvezi obstojeca 4 obvestila na novo (manjse) stevilo takoj ----------------------- */

DECLARE @FixOrgId int, @FixCount int, @FixDedupKey varchar(64), @FixPayload nvarchar(2000);
DECLARE fix_cursor CURSOR LOCAL FAST_FORWARD FOR
  SELECT OrganizationId FROM dbo.OrganizationConfig WHERE IsActive = 1;
OPEN fix_cursor;
FETCH NEXT FROM fix_cursor INTO @FixOrgId;
WHILE @@FETCH_STATUS = 0
BEGIN
  SET @FixCount =
  (
    SELECT COUNT(*)
    FROM canon.ProductPlanning planiranje
    INNER JOIN canon.Product artikel ON artikel.ProductId = planiranje.ProductId
    WHERE artikel.OrganizationId = @FixOrgId AND planiranje.ExcludeQuantityReservation = 1 AND artikel.IsActive = 1
  );
  SET @FixDedupKey = CONVERT(varchar(64), HASHBYTES('SHA2_256', CONCAT(@FixOrgId, N':reservation-excluded')), 2);
  SET @FixPayload = CONCAT(@FixCount, N' izdelkov je še vedno izločenih iz rezervacije zaloge (SAOP).');

  IF @FixCount > 0
    UPDATE ops.Alert
    SET PayloadSummaryRedacted = @FixPayload, UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = N'migracija 190'
    WHERE OrganizationId = @FixOrgId AND AlertKind = N'ReservationExcluded' AND ResolvedUtc IS NULL;
  ELSE
    UPDATE ops.Alert
    SET ResolvedUtc = SYSUTCDATETIME(), ResolvedBy = N'migracija 190', UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = N'migracija 190'
    WHERE OrganizationId = @FixOrgId AND AlertKind = N'ReservationExcluded' AND ResolvedUtc IS NULL;

  FETCH NEXT FROM fix_cursor INTO @FixOrgId;
END;
CLOSE fix_cursor;
DEALLOCATE fix_cursor;

/* --- 5) Preverbe --------------------------------------------------------------------------- */

IF OBJECT_ID(N'canon.TR_Product_ClearReservationFlagOnArchive', N'TR') IS NULL
  THROW 53001, 'Sprozilec za brisanje zastavice ob arhiviranju ni nastal.', 1;

IF EXISTS
(
  SELECT 1 FROM canon.ProductPlanning planning
  INNER JOIN canon.Product product ON product.ProductId = planning.ProductId
  WHERE planning.ExcludeQuantityReservation = 1 AND product.IsActive = 0
)
  THROW 53002, 'Se vedno obstajajo arhivirani izdelki z zastavico izlocitve.', 1;

IF NOT EXISTS
(
  SELECT 1 FROM sys.sql_modules
  WHERE object_id = OBJECT_ID(N'map.ProcessPlanningInbox') AND definition LIKE N'%izdelek.IsActive = 1%'
    AND definition LIKE N'%artikel.IsActive = 1%'
)
  THROW 53003, 'Zajem planiranja se ne izkljuci arhiviranih izdelkov.', 1;
