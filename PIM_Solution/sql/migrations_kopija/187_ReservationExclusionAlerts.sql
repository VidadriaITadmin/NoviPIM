/*
  187 — obvestilo in odhodna potrditev, ko SAOP izdelek izloci iz rezervacije zaloge.

  Zahteva uporabnika 2026-09-10: stran za pregled izlocenih izdelkov (Nastavitve kataloga ->
  Rezervacija zaloge, ze na strani C#), obvestilo v aplikaciji, ko se izdelek NA NOVO izloci
  (prehod 0/NULL -> 1; ne ob ponovnem branju iste vrednosti in ne ob vrnitvi nazaj na 0), in
  odhodna potrditev, ki caka na odobritev v Izhod v SAOP -> Cakalna vrsta.

  Popravek 1 (isti dan): prvotna razlicica je ustvarila EN dogodek na izdelek v ops.OutboundEvent.
  Uporabnik je opozoril, da bi to ob 616 obstojecih izlocitvah (in vsaki naslednji) poplavilo
  stran Obvestila. Namesto seznama je zato eno obvestilo na organizacijo, ki ga vsaka nova
  izlocitev samo posodobi s trenutnim stevilom.

  Popravek 2 (isti dan): uporabnik je vprasal, zakaj obvestila ni v "notifikacijskem centru"
  (zvonec zgoraj desno, značka steje ops.Alert.IsSeen; stran /sistem "Nadzor sistema"). To NI
  ops.OutboundEvent (stran /izvozi/obvestila) — to je LOCEN sistem: intranet.GetAdminPulse bere
  ops.Alert, zvonec pa AdminPulse.UnseenCount (glej AdminConsoleService.cs, migracija 172).
  Obvestilo zato ne gre v ops.OutboundEvent, ampak v ops.Alert prek ze obstojece ops.UpsertAlert
  (migracija 025) — ista procedura, ki jo uporablja ops.RunWatchdog za StaleHeartbeat/OutboundDead.
  Ta procedura ze naredi natanko to, kar je uporabnik hotel: dedup po (OrganizationId, DedupKey),
  UPDATE namesto novega INSERT-a, ce vrstica ze obstaja in se ni razresena. Nobena nova
  infrastruktura ni potrebna — samo pravi klic namesto ops.RecordOutboundEvent.

  Resnost je Warning (ne Critical): to je poslovno stanje (izdelki, izloceni v ERP), ne okvara
  cevovoda, zato se NE prikaze v rdecem pasu "Potrebuje pozornost" na /sistem (ta je filtriran na
  Critical), pokaze pa se v zvoncku (steje vse neresene alarme) in na /sistem/integracije
  (Alarmi — vsa resnosti, s Potrdi/Resi).

  Zakaj tu in ne novo omrezje tabel za odhodno potrditev: polje Planning.ExcludeQtyReservation je
  v out.SaopXmlField in out.OwnershipPolicy ze pisljivo (Owner = PIM na vseh stirih organizacijah;
  glej migracija 156, ki ni v tem repozitoriju, a je v bazi), pot za posamicno spremembo pa je
  out.EnqueueSaopItemChange (migracija 089). To ni "spam" — vsak izdelek je svoja vrstica v
  cakalni vrsti, kot povsod drugod v Izhod v SAOP.

  Kaj je namenoma izpuscheno: odhodna potrditev se NE zapise za obstojece izlocene izdelke
  (backfill spodaj osvezi samo alarm, ne odhodnih sporocil) — stotine sporocil, ki bi cakala na
  odobritev cez noc brez izrecne zahteve, je vecja sprememba stanja, kot jo je uporabnik prosil.
  Za izdelke, ki se izlocijo OD ZDAJ NAPREJ, nastaneta oboje: osvezen alarm IN odhodna potrditev
  za tisti konkretni izdelek.

  Zakaj primerjava "prej" in "zdaj" znotraj map.ProcessPlanningInbox in ne drugje: samo tu se v
  istem trenutku vidi stara vrednost canon.ProductPlanning (pred MERGE) in nova (iz strani SAOP),
  zato je to edino mesto, kjer je prehod 0/NULL -> 1 zares razlocljiv od "se vedno izloceno" ali
  "na novo vrnjeno".
*/

SET XACT_ABORT ON;

/* --- 1) Zajem planiranja: zazna prehod, poklice odhodno potrditev in osvezi alarm ------ */

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

    Migracija 187: pred MERGE se shrani prejsnja vrednost ExcludeQuantityReservation za izdelke
    te strani. Za vsak NA NOVO izloceni izdelek (prej 0/NULL, zdaj 1) nastane odhodna potrditev
    za SAOP (out.EnqueueSaopItemChange, vrednost ''true''), ki caka na odobritev v Izhod v SAOP
    -> Cakalna vrsta, in se osvezi EN alarm na organizacijo v ops.Alert (prek ops.UpsertAlert) s
    trenutnim skupnim stevilom izlocenih — to je isti "notifikacijski center" (zvonec, /sistem),
    ne loceni seznam dogodkov na izdelek. Ponovno branje iste vrednosti 1 se ne ponovi, ker #Prej
    takrat ze kaze 1.
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
          @Severity = N''Warning'', @DedupKey = @ReservationDedupKey,
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

/* --- 2) Backfill: en alarm na organizacijo za obstojece izlocitve, brez odhodne potrditve --- */

DECLARE @BackfillOrgId int, @BackfillCount int;
DECLARE backfill_cursor CURSOR LOCAL FAST_FORWARD FOR
  SELECT OrganizationId FROM dbo.OrganizationConfig WHERE IsActive = 1;

OPEN backfill_cursor;
FETCH NEXT FROM backfill_cursor INTO @BackfillOrgId;
WHILE @@FETCH_STATUS = 0
BEGIN
  SET @BackfillCount =
  (
    SELECT COUNT(*)
    FROM canon.ProductPlanning planiranje
    INNER JOIN canon.Product artikel ON artikel.ProductId = planiranje.ProductId
    WHERE artikel.OrganizationId = @BackfillOrgId AND planiranje.ExcludeQuantityReservation = 1
  );

  IF @BackfillCount > 0
  BEGIN
    /* Vrednosti parametrov EXEC morajo biti spremenljivke, ne izrazi — sicer SQL Server v tako
       globoko gnezdenem kontekstu (WHILE v WHILE) prijavi "Incorrect syntax", ceprav je isti
       klic v plitkem kontekstu videti veljaven. Zato je vsaka vrednost najprej v svoji spremenljivki. */
    DECLARE @BackfillDedupKey varchar(64);
    SET @BackfillDedupKey =
      CONVERT(varchar(64), HASHBYTES('SHA2_256', CONCAT(@BackfillOrgId, N':reservation-excluded')), 2);

    DECLARE @BackfillPayload nvarchar(2000);
    SET @BackfillPayload = CONCAT(@BackfillCount, N' izdelkov je še vedno izločenih iz rezervacije zaloge (SAOP).');

    EXEC ops.UpsertAlert
      @OrganizationId = @BackfillOrgId, @Pipeline = N'SAOP_PRODUCTS', @AlertKind = N'ReservationExcluded',
      @Severity = N'Warning', @DedupKey = @BackfillDedupKey,
      @Title = N'Izločitve iz rezervacije zaloge',
      @PayloadSummaryRedacted = @BackfillPayload,
      @Actor = N'migracija 187';
  END;

  FETCH NEXT FROM backfill_cursor INTO @BackfillOrgId;
END;
CLOSE backfill_cursor;
DEALLOCATE backfill_cursor;

/* --- 3) Preverbe ------------------------------------------------------------------------ */

IF NOT EXISTS
(
  SELECT 1 FROM sys.sql_modules
  WHERE object_id = OBJECT_ID(N'map.ProcessPlanningInbox') AND definition LIKE N'%EnqueueSaopItemChange%'
    AND definition LIKE N'%UpsertAlert%'
)
  THROW 52982, 'Zajem planiranja ne sproza odhodne potrditve in alarma ob novi izlocitvi.', 1;

/* Vsaka organizacija sme imeti kvecjemu en neresen alarm te vrste — nikoli seznam po izdelku. */
IF EXISTS
(
  SELECT OrganizationId FROM ops.Alert
  WHERE AlertKind = N'ReservationExcluded' AND ResolvedUtc IS NULL
  GROUP BY OrganizationId HAVING COUNT(*) > 1
)
  THROW 52983, 'Alarm o izlocitvi iz rezervacije zaloge se je podvojil namesto posodobil.', 1;

DECLARE @OrganizacijSIzlocitvami int =
(
  SELECT COUNT(DISTINCT artikel.OrganizationId)
  FROM canon.ProductPlanning planiranje
  INNER JOIN canon.Product artikel ON artikel.ProductId = planiranje.ProductId
  WHERE planiranje.ExcludeQuantityReservation = 1
);
DECLARE @OrganizacijZAlarmom int =
(
  SELECT COUNT(DISTINCT OrganizationId) FROM ops.Alert
  WHERE AlertKind = N'ReservationExcluded' AND ResolvedUtc IS NULL
);
IF @OrganizacijZAlarmom < @OrganizacijSIzlocitvami
  THROW 52984, 'Vsaj ena organizacija z izlocenimi izdelki nima alarma o tem.', 1;
