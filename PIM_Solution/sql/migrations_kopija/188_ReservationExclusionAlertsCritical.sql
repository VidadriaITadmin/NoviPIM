/*
  188 — obvestilo o izlocitvi iz rezervacije zaloge postane Critical.

  Zahteva uporabnika 2026-09-10: pokazal je posnetek zaslona strani /sistem "Nadzor sistema" in
  jasno povedal, da je RDECI PAS "Potrebuje pozornost" tisto, kar misli z "notifikacijskim
  centrom" — ne samo zvonec ali /sistem/integracije. Ta pas (System.razor, lastnost Pozornost)
  je programsko filtriran na "Pulse.Alerts.Where(row => row.Severity == "Critical")"; alarm
  migracije 187 je bil namenoma Warning (poslovno stanje, ne okvara cevovoda) in se zato tam ni
  pokazal, čeprav je bil v zvoncku in na /sistem/integracije viden.

  Edina sprememba: Severity gre iz Warning v Critical, na dveh mestih —
    1) map.ProcessPlanningInbox, da bodo bodoce izlocitve takoj Critical;
    2) obstojece 4 vrstice v ops.Alert (ena na organizacijo, iz migracije 187 backfill),
       da se popravek pozna takoj in ne sele ob naslednji spremembi stanja pri SAOP.

  Telo procedure je sicer enako kot v 187 (CREATE OR ALTER zahteva celoten ponovni zapis;
  ne gre za urejanje ze uporabljene migracije — 187 ostaja nedotaknjena, to je nova).
*/

SET XACT_ABORT ON;

/* --- 1) Popravi obstojece 4 alarme takoj, brez cakanja na naslednjo sinhronizacijo ------ */

UPDATE ops.Alert
SET Severity = N'Critical', UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = N'migracija 188'
WHERE AlertKind = N'ReservationExcluded' AND ResolvedUtc IS NULL AND Severity <> N'Critical';

/* --- 2) Zajem planiranja: ista logika kot 187, samo Severity = Critical ----------------- */

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

    Migracija 187/188: pred MERGE se shrani prejsnja vrednost ExcludeQuantityReservation za
    izdelke te strani. Za vsak NA NOVO izloceni izdelek (prej 0/NULL, zdaj 1) nastane odhodna
    potrditev za SAOP (out.EnqueueSaopItemChange, vrednost ''true''), ki caka na odobritev v
    Izhod v SAOP -> Cakalna vrsta, in se osvezi EN alarm na organizacijo v ops.Alert (prek
    ops.UpsertAlert, Severity Critical od 188 naprej) s trenutnim skupnim stevilom izlocenih —
    zato se pokaze tudi v rdecem pasu "Potrebuje pozornost" na /sistem, ne le v zvoncku. Ponovno
    branje iste vrednosti 1 se ne ponovi, ker #Prej takrat ze kaze 1.
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

      /* Novo izloceni: danes izloceni (1), prej niso bili (0 ali sploh se niso obstajali v #Prej). */
      SELECT DISTINCT zapis.ProductId, izdelek.ItemID
      INTO #NovoZaznano
      FROM #Zapis zapis
      INNER JOIN canon.Product izdelek ON izdelek.ProductId = zapis.ProductId
      WHERE zapis.ExcludeQuantityReservation = 1
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
           Vrednosti parametrov EXEC morajo biti spremenljivke, ne izrazi — sicer SQL Server v
           tako globoko gnezdenem kontekstu (WHILE v WHILE v IF) prijavi "Incorrect syntax",
           ceprav je isti klic v plitkem kontekstu videti veljaven. Zato je vsaka vrednost
           najprej v svoji spremenljivki. */
        DECLARE @SkupajIzlocenih int;
        SET @SkupajIzlocenih =
        (
          SELECT COUNT(*)
          FROM canon.ProductPlanning planiranje
          INNER JOIN canon.Product artikel ON artikel.ProductId = planiranje.ProductId
          WHERE artikel.OrganizationId = @OrganizationId AND planiranje.ExcludeQuantityReservation = 1
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

/* --- 3) Preverbe ------------------------------------------------------------------------ */

IF NOT EXISTS
(
  SELECT 1 FROM sys.sql_modules
  WHERE object_id = OBJECT_ID(N'map.ProcessPlanningInbox') AND definition LIKE N'%UpsertAlert%'
    AND definition LIKE N'%Critical%'
)
  THROW 52990, 'Zajem planiranja ne oznacuje alarma izlocitve kot Critical.', 1;

IF EXISTS
(
  SELECT 1 FROM ops.Alert
  WHERE AlertKind = N'ReservationExcluded' AND ResolvedUtc IS NULL AND Severity <> N'Critical'
)
  THROW 52991, 'Obstoji nepopravljen alarm izlocitve, ki ni Critical.', 1;

IF (SELECT COUNT(*) FROM ops.Alert WHERE AlertKind = N'ReservationExcluded' AND ResolvedUtc IS NULL AND Severity = N'Critical') < 1
  THROW 52992, 'Noben alarm izlocitve ni Critical; popravek se ni prijel.', 1;
