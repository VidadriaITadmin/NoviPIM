/*
  089 — mnozicno narocilo sprememb, seznam pisljivih polj in prekrivka cakajocih vrednosti.

  Zakaj mnozicno svoja procedura in ne 500 klicev iz aplikacije:

  1) Uporabnik ne dela po enem artiklu. Najpogostejsi tok je uvoz Excela z nekaj sto vrsticami.
     Klic na vrstico bi pomenil nekaj sto krozenj do baze in nobenega skupnega izida.

  2) Ena slaba vrstica ne sme podreti celotnega uvoza. Vsaka vrstica ima svoj TRY/CATCH in svoj
     izid; uvoz se vedno konca in vedno pove, katera vrstica ni sla skozi in zakaj. Tiho
     odrezan uvoz je huji od zavrnjenega, ker se ga ne vidi.

  3) Skupina (out.OutboundBatch) nastane enkrat, ne na vrstico, zato se da povedati "uvoz je
     koncan" in "od 500 jih je 12 padlo".

  Kaj se NE spremeni: pravila. Vsaka vrstica gre skozi out.EnqueueSaopItemChange in s tem skozi
  vse iste varovalke kot posamicna sprememba — pogodba payloada, lastnistvo polja iz 068,
  pripadnost dokumentu iz 081 in dedup. Mnozicna pot ni blizjica.

  Prekrivka (intranet.GetPendingOverlay) je izvedba pravila iz docs\NACRT_INTRANET_PRENOVA.md
  §4.1: v canon ne zapisemo nicesar, cesar SAOP se ni potrdil. Zelena vrednost zivi v
  out.OutboxMessage in se uporabniku pokaze NAD kanonicno vrednostjo, oznacena kot "caka
  potrditev". Tako dobi takojsen odziv, ne da bi se pretvarjali, da je vrednost ze dejstvo.

  Migrator ne pozna locila GO; procedure so v EXEC(N'...').
*/

SET XACT_ABORT ON;

/* --- 1) Mnozicno narocilo ----------------------------------------------- */

/*
  @ChangesJson je polje objektov: [{"itemId":"NW.1","fieldKey":"Product.EAN","value":"38300..."}]

  Vrne eno vrstico na vhodno vrstico z izidom:
    Queued    — sporocilo je nastalo
    Duplicate — enako sporocilo ze caka; novo ni nastalo in to ni napaka
    Rejected  — vrstica ni presla varovalke; Reason pove katere
*/
EXEC(N'
CREATE OR ALTER PROCEDURE out.EnqueueSaopItemChanges
  @OrganizationId int, @ChangesJson nvarchar(max), @Actor nvarchar(200),
  @Source nvarchar(30) = N''BULK'', @Note nvarchar(400) = NULL,
  @OutboundBatchId bigint = NULL OUTPUT
AS
BEGIN
  SET NOCOUNT ON;
  IF ISJSON(@ChangesJson) <> 1 THROW 52890, ''Seznam sprememb ni veljaven JSON.'', 1;

  DECLARE @Vhod TABLE
  (
    Zaporedna int IDENTITY(1,1) PRIMARY KEY,
    ItemID nvarchar(450) NULL,
    FieldKey nvarchar(200) NULL,
    Value nvarchar(4000) NULL
  );

  INSERT @Vhod(ItemID, FieldKey, Value)
  SELECT LTRIM(RTRIM(vrstica.itemId)), LTRIM(RTRIM(vrstica.fieldKey)), vrstica.value
  FROM OPENJSON(@ChangesJson)
  WITH (itemId nvarchar(450) N''$.itemId'', fieldKey nvarchar(200) N''$.fieldKey'', value nvarchar(4000) N''$.value'') AS vrstica;

  IF NOT EXISTS(SELECT 1 FROM @Vhod) THROW 52891, ''Seznam sprememb je prazen.'', 1;

  IF @OutboundBatchId IS NULL
    EXEC out.BeginOutboundBatch @OrganizationId = @OrganizationId, @Source = @Source, @Note = @Note,
      @Actor = @Actor, @OutboundBatchId = @OutboundBatchId OUTPUT;

  DECLARE @Izid TABLE
  (
    Zaporedna int PRIMARY KEY, ItemID nvarchar(450) NULL, FieldKey nvarchar(200) NULL,
    Status nvarchar(20) NOT NULL, Reason nvarchar(400) NULL, OutboxMessageId bigint NULL
  );

  DECLARE @Zaporedna int, @ItemID nvarchar(450), @FieldKey nvarchar(200), @Value nvarchar(4000),
          @MessageId bigint, @ZeObstaja bit;

  DECLARE vrstice CURSOR LOCAL FAST_FORWARD FOR SELECT Zaporedna, ItemID, FieldKey, Value FROM @Vhod ORDER BY Zaporedna;
  OPEN vrstice;
  FETCH NEXT FROM vrstice INTO @Zaporedna, @ItemID, @FieldKey, @Value;

  WHILE @@FETCH_STATUS = 0
  BEGIN
    SET @MessageId = NULL;
    BEGIN TRY
      /* Ali enako sporocilo ze caka — da se "ze v vrsti" loci od "na novo uvrsceno". */
      SET @ZeObstaja = CASE WHEN EXISTS
      (
        SELECT 1 FROM out.OutboxMessage
        WHERE OrganizationId = @OrganizationId AND TargetKind = N''SAOP_PRODUCT''
          AND EntityKey = @ItemID AND FieldSummary = @FieldKey
          AND Status IN (N''PendingApproval'', N''Pending'', N''Sending'', N''Sent'', N''Error'', N''Retry'')
      ) THEN 1 ELSE 0 END;

      EXEC out.EnqueueSaopItemChange
        @OrganizationId = @OrganizationId, @ItemID = @ItemID, @FieldKey = @FieldKey, @Value = @Value,
        @Actor = @Actor, @OutboundBatchId = @OutboundBatchId, @OutboxMessageId = @MessageId OUTPUT;

      INSERT @Izid(Zaporedna, ItemID, FieldKey, Status, Reason, OutboxMessageId)
      VALUES(@Zaporedna, @ItemID, @FieldKey,
        CASE WHEN @ZeObstaja = 1 THEN N''Duplicate'' ELSE N''Queued'' END,
        CASE WHEN @ZeObstaja = 1 THEN N''Enaka sprememba ze caka v vrsti; nova ni nastala.'' END,
        @MessageId);
    END TRY
    BEGIN CATCH
      /* Ena slaba vrstica ne sme podreti uvoza. Razlog je sporocilo varovalke, ki je zavrnila. */
      INSERT @Izid(Zaporedna, ItemID, FieldKey, Status, Reason, OutboxMessageId)
      VALUES(@Zaporedna, @ItemID, @FieldKey, N''Rejected'', LEFT(ERROR_MESSAGE(), 400), NULL);
    END CATCH;

    FETCH NEXT FROM vrstice INTO @Zaporedna, @ItemID, @FieldKey, @Value;
  END;

  CLOSE vrstice;
  DEALLOCATE vrstice;

  SELECT Zaporedna, ItemID, FieldKey, Status, Reason, OutboxMessageId FROM @Izid ORDER BY Zaporedna;
END;');

/* --- 2) Katera polja sme uporabnik urejati ------------------------------ */

/*
  Presek treh registrov: polje mora biti del dokumenta (081), v lasti PIM (068) in omogoceno.
  Vmesnik ne sme ponujati polja, ki bi ga baza potem zavrnila — to je najhitrejsi nacin, da
  uporabnik izgubi zaupanje v mnozicno urejanje.
*/
EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetWritableSaopFields
  @OrganizationId int, @TargetKind nvarchar(100) = N''SAOP_PRODUCT''
AS
BEGIN
  SET NOCOUNT ON;
  SELECT field.FieldKey, field.ElementName, field.Section, field.ValueFormat,
    field.TrueValue, field.FalseValue, field.IsAddMandatory, field.SortOrder,
    ownership.EntityType
  FROM out.SaopXmlField AS field
  INNER JOIN out.SaopDocument AS document ON document.TargetKind = field.TargetKind
  INNER JOIN out.OwnershipPolicy AS ownership
    ON ownership.OrganizationId = @OrganizationId AND ownership.TargetKind = field.TargetKind
      AND ownership.FieldName = field.FieldKey AND ownership.Owner = N''PIM'' AND ownership.IsEnabled = 1
  WHERE field.TargetKind = @TargetKind AND field.IsEnabled = 1 AND field.FieldKey IS NOT NULL
    AND N''|'' + document.KeyElements + N''|'' NOT LIKE N''%|'' + field.ElementName + N''|%''
  ORDER BY field.SortOrder;
END;');

/* --- 3) Prekrivka: kaj caka potrditev ----------------------------------- */

/*
  Za dane artikle vrne polja, ki imajo cakajoco odhodno vrednost, skupaj s stanjem. Vmesnik jo
  pokaze nad kanonicno vrednostjo z oznako "caka potrditev".

  Zakaj tudi Sent in ne le Pending: Sent pomeni "SAOP je sprejel, potrditve iz zajema pa se ni".
  Prav v tem oknu je razlika med tem, kar uporabnik vidi, in tem, kar je res, najvecja — in prav
  tam mora biti oznaka najbolj vidna.
*/
EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetPendingOverlay
  @OrganizationId int, @ItemIdsJson nvarchar(max) = NULL, @TargetKind nvarchar(100) = N''SAOP_PRODUCT''
AS
BEGIN
  SET NOCOUNT ON;
  IF @ItemIdsJson IS NOT NULL AND ISJSON(@ItemIdsJson) <> 1 THROW 52892, ''Seznam artiklov ni veljaven JSON.'', 1;

  SELECT message.EntityKey, FieldKey = message.FieldSummary,
    Value = JSON_VALUE(message.PayloadJson, N''$.value''),
    message.Status, message.OutboxMessageId, message.OutboundBatchId,
    message.CreatedUtc, message.SentUtc, message.LastError, message.SaopErrorKind
  FROM out.OutboxMessage AS message
  WHERE message.OrganizationId = @OrganizationId AND message.TargetKind = @TargetKind
    AND message.Status IN (N''PendingApproval'', N''Pending'', N''Retry'', N''Sending'', N''Sent'', N''Drift'', N''Dead'')
    AND (@ItemIdsJson IS NULL OR message.EntityKey IN (SELECT value FROM OPENJSON(@ItemIdsJson)))
  ORDER BY message.EntityKey, message.FieldSummary;
END;');

/* --- 4) Odobritev in preklic cele skupine ------------------------------- */

/*
  Pri mnozicni spremembi je odobravanje po sporocilu neuporabno: 500 klikov ni odobritev, je
  ovira, ki jo bo uporabnik obsel. Odobri se skupina, in to zapise, kdo jo je odobril.
*/
EXEC(N'
CREATE OR ALTER PROCEDURE out.ApproveOutboundBatch @OutboundBatchId bigint, @Actor nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON; BEGIN TRAN;
  UPDATE out.OutboxMessage
  SET Status = N''Pending'', ApprovedUtc = SYSUTCDATETIME(), ApprovedBy = @Actor,
      NextAttemptUtc = SYSUTCDATETIME(), UpdatedUtc = SYSUTCDATETIME()
  WHERE OutboundBatchId = @OutboundBatchId AND Status = N''PendingApproval'';
  DECLARE @Odobrenih int = @@ROWCOUNT;
  UPDATE out.OutboundBatch SET ClosedUtc = NULL WHERE OutboundBatchId = @OutboundBatchId;
  COMMIT;
  SELECT Odobrenih = @Odobrenih;
END;');

EXEC(N'
CREATE OR ALTER PROCEDURE out.CancelOutboundBatch @OutboundBatchId bigint, @Actor nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON; BEGIN TRAN;
  UPDATE out.OutboxMessage
  SET Status = N''Cancelled'', LastError = N''Preklicana skupina: '' + @Actor,
      NextAttemptUtc = NULL, UpdatedUtc = SYSUTCDATETIME()
  WHERE OutboundBatchId = @OutboundBatchId
    AND Status IN (N''PendingApproval'', N''Pending'', N''Error'', N''Retry'');
  DECLARE @Preklicanih int = @@ROWCOUNT;
  UPDATE out.OutboundBatch SET ClosedUtc = SYSUTCDATETIME() WHERE OutboundBatchId = @OutboundBatchId;
  COMMIT;
  SELECT Preklicanih = @Preklicanih;
END;');

/* --- 5) Manjkajoce lastnistvo za drugi ERP naziv ------------------------ */

/*
  Preverba na dnu te migracije je nasla resnicno vrzel: ItemTitle2
  (ProductText.TITLE_ERP2.sl) je del dokumenta iz migracije 081, v registru lastnistva pa ni
  imel vrstice. Vmesnik bi ga ponudil za urejanje, out.EnqueueMessage pa bi ga zavrnil z 51010.

  Zakaj ga 068 ni zajela: takrat to besedilo se ni obstajalo — nastalo je z migracijo 073
  (ProductTextSecondTitle), 068 pa je lastnistvo izpeljala iz takratnega stanja preslikav.

  Zakaj sme biti v lasti PIM: pravilo O9 zahteva, da polje tudi beremo nazaj. canon.ProductText
  ima zanj 109.352 vrstic v slovenscini, na listu 'Izdelki-splosno' preglednice pa je ItemTitle2
  oznacen kot pisljiv ('obojesmerno'), enako kot ItemTitle1.
*/
MERGE out.OwnershipPolicy AS target
USING
(
  SELECT organization.OrganizationId, N'SAOP_PRODUCT' AS TargetKind, N'Product' AS EntityType,
    N'ProductText.TITLE_ERP2.sl' AS FieldName, N'PIM' AS Owner
  FROM dbo.OrganizationConfig AS organization
) AS source
  ON target.OrganizationId = source.OrganizationId AND target.TargetKind = source.TargetKind
    AND target.EntityType = source.EntityType AND target.FieldName = source.FieldName
    AND target.ConstraintValue IS NULL
WHEN NOT MATCHED THEN INSERT (OrganizationId, TargetKind, EntityType, FieldName, Owner, IsEnabled, UpdatedBy)
  VALUES (source.OrganizationId, source.TargetKind, source.EntityType, source.FieldName, source.Owner, 1, N'migracija 089');

/* --- 6) Preverbe -------------------------------------------------------- */

IF OBJECT_ID(N'out.EnqueueSaopItemChanges', N'P') IS NULL
  THROW 52893, 'Mnozicno narocilo sprememb ni nastalo.', 1;

IF OBJECT_ID(N'intranet.GetWritableSaopFields', N'P') IS NULL OR OBJECT_ID(N'intranet.GetPendingOverlay', N'P') IS NULL
  THROW 52894, 'Seznam pisljivih polj ali prekrivka nista nastala.', 1;

IF OBJECT_ID(N'out.ApproveOutboundBatch', N'P') IS NULL OR OBJECT_ID(N'out.CancelOutboundBatch', N'P') IS NULL
  THROW 52895, 'Odobritev ali preklic skupine ni nastal.', 1;

/* Pisljivo polje brez lastnistva ne sme obstajati: vmesnik bi ga ponudil, baza pa zavrnila. */
IF EXISTS
(
  SELECT 1 FROM out.SaopXmlField AS field
  WHERE field.TargetKind = N'SAOP_PRODUCT' AND field.IsEnabled = 1 AND field.FieldKey IS NOT NULL
    AND field.FieldKey NOT IN (SELECT FieldName FROM out.OwnershipPolicy WHERE TargetKind = N'SAOP_PRODUCT')
)
  THROW 52896, 'Polje dokumenta nima vrstice v registru lastnistva; vmesnik bi ponujal polje, ki ga baza zavrne.', 1;
