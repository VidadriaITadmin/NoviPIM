/*
  088 — zaloga dobavitelja se sme ujeti samo z artiklom istega podjetja.

  Napaka je iz migracije 018 in je bila do zdaj nevidna, ker je dobaviteljevo zalogo imelo
  samo podjetje 2:

      DECLARE @ProductId bigint = (SELECT TOP(1) ProductId FROM canon.Product
                                   WHERE ItemID=@Identity OR (@Identity IS NULL AND EAN=@Ean) ...);

  Pogoja po podjetju ni. Ko je 087 dobaviteljevo zalogo vklopil za vsa stiri podjetja, je isti
  stavek zacel vezati zalogo podjetja 4 na artikel podjetja 2 — sifra NW.* obstaja pri vseh
  stirih, TOP(1) pa vrne poljubnega. Dokaz pred popravkom: aktivni posnetki so imeli pri vseh
  stirih podjetjih natanko enako stevilo ujetih vrstic (NW 2.461, BT 1.296), ceprav ima
  podjetje 1 17.425 artiklov in podjetje 2 111.063.

  Popravek je en pogoj: podjetje se prebere iz vhodne vrstice (stock.LandingRecord.OrganizationId),
  ki ga ze nosi. Vse ostalo v postopku ostane nespremenjeno.

  Kar ta migracija NE popravi: ze zapisane vrstice v stock.Position. Te nastanejo ob zajemu in
  se prepisejo z naslednjim zagonom zaloge; brisanja ta migracija ne dela.
*/

SET XACT_ABORT ON;

EXEC(N'
CREATE OR ALTER PROCEDURE stock.ApplyLandingRecord @LandingRecordId bigint, @DateFormat nvarchar(30)=N''yyyy-MM-dd''
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  DECLARE @Quantity decimal(19,4), @Incoming decimal(19,4), @Date date, @Identity nvarchar(450), @Ean nvarchar(100), @Reason nvarchar(50), @OrganizationId int;
  SELECT @Quantity=TRY_CONVERT(decimal(19,4),NULLIF(REPLACE(QuantityText,NCHAR(0),N''''),N'''')),
    @Incoming=TRY_CONVERT(decimal(19,4),NULLIF(REPLACE(IncomingQuantityText,NCHAR(0),N''''),N'''')),
    @Date=CASE WHEN NULLIF(REPLACE(AvailabilityDateText,NCHAR(0),N''''),N'''') IS NULL THEN NULL
      WHEN @DateFormat=N''yyyy-MM-dd'' THEN TRY_CONVERT(date,REPLACE(AvailabilityDateText,NCHAR(0),N''''),23)
      WHEN @DateFormat=N''dd.MM.yyyy'' THEN TRY_CONVERT(date,REPLACE(AvailabilityDateText,NCHAR(0),N''''),104) END,
    @Identity=NULLIF(LTRIM(RTRIM(NormalizedItemId)),N''''), @Ean=NULLIF(LTRIM(RTRIM(Ean)),N''''),
    @OrganizationId=OrganizationId
  FROM stock.LandingRecord WHERE LandingRecordId=@LandingRecordId AND Status=N''Pending'';
  IF @@ROWCOUNT=0 RETURN;
  SET @Reason=CASE WHEN @Identity IS NULL AND @Ean IS NULL THEN N''MissingIdentity''
    WHEN @Quantity IS NULL THEN N''InvalidQuantity'' WHEN @Quantity<0 THEN N''NegativeQuantity''
    WHEN NULLIF(REPLACE((SELECT AvailabilityDateText FROM stock.LandingRecord WHERE LandingRecordId=@LandingRecordId),NCHAR(0),N''''),N'''') IS NOT NULL AND @Date IS NULL THEN N''InvalidDate'' END;
  IF @Reason IS NOT NULL
  BEGIN
    INSERT stock.UnmatchedPosition(LandingRecordId,ReasonCode,Detail) VALUES(@LandingRecordId,@Reason,N''Zapis ni prestal generične normalizacije.'');
    UPDATE stock.LandingRecord SET Status=N''Quarantined'',FailureReason=@Reason WHERE LandingRecordId=@LandingRecordId; RETURN;
  END;
  DECLARE @SnapshotId bigint=(SELECT SnapshotId FROM stock.Snapshot s JOIN stock.LandingRecord l ON l.SyncRunId=s.SyncRunId AND l.OrganizationId=s.OrganizationId AND l.SourceConnectorId=s.SourceConnectorId AND l.SnapshotUtc=s.SnapshotUtc WHERE l.LandingRecordId=@LandingRecordId);
  /* Edina sprememba proti 018: artikel mora biti iz istega podjetja kot vhodna vrstica. */
  DECLARE @ProductId bigint=(SELECT TOP(1) ProductId FROM canon.Product
    WHERE OrganizationId=@OrganizationId AND (ItemID=@Identity OR (@Identity IS NULL AND EAN=@Ean))
    ORDER BY CASE WHEN ItemID=@Identity THEN 0 ELSE 1 END);
  INSERT stock.Position(SnapshotId,LandingRecordId,NormalizedItemId,Ean,Quantity,AvailabilityDate,IncomingQuantity,MatchKey,MatchedProductId)
  VALUES(@SnapshotId,@LandingRecordId,@Identity,@Ean,@Quantity,@Date,@Incoming,CASE WHEN @ProductId IS NULL THEN N''Unmatched'' WHEN EXISTS(SELECT 1 FROM canon.Product WHERE ProductId=@ProductId AND ItemID=@Identity) THEN N''ItemID'' ELSE N''EAN'' END,@ProductId);
  UPDATE stock.LandingRecord SET Status=N''Applied'' WHERE LandingRecordId=@LandingRecordId;
END');

/* --- dokaz ------------------------------------------------------------------- */

IF OBJECT_DEFINITION(OBJECT_ID(N'stock.ApplyLandingRecord')) NOT LIKE N'%OrganizationId=@OrganizationId AND (ItemID=@Identity%'
  THROW 51088, N'088: ujemanje zaloge se vedno ne omejuje na podjetje vhodne vrstice.', 1;
