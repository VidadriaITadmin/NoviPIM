/*
  046 — tri resnicne vrzeli odhodne poti: O18, O16 in O19.

  Vir zahtev: list 'Outbound-vrzeli' v
  PIM_Solution\docs\Povezave_virov_in_sistemov\Mapiranje_SAOP_API_PIM.xlsx
  (izpeljan iz Nacrt_Pisanje_Nazaj_V_SAOP.md, razdelki 3.2, 3.4 in 3.5). Vrzeli so tam
  opisane nad tabelami starega sistema (pim.SaopItemOutboundQueue); tu so prenesene na
  dejansko shemo NoviPIM, ki je out.OutboxMessage.

  O18 — ponovni poskusi ne locijo tipa napake.
    Danes je zavrnitev 400 in napaka 401 isto: sporocilo umre, nihce ne ve zakaj, in
    napaka poverilnice se ponovi na vsakem artiklu posebej. Dodan je stolpec ErrorClass
    (Transient | Business | AuthConfig) na sporocilu in na poskusu, politika poskusov po
    razredu, ob AuthConfig pa se kanal ustavi (dbo.IntegrationProfile.IsEnabled = 0) in
    nastane en sam alarm na integracijo prek ops.UpsertAlert.

  O16 — vrsta ne loci nadomescenega sporocila od nepotrjenega.
    Zaporedje "poslji A -> urednik popravi na B -> poslji B -> SAOP potrdi B" pusti A v
    stanju Sent za vedno. Na nadzorni strani je to videti kot "SAOP ni potrdil", kar ni
    res. Dodano je stanje Superseded: ob novem sporocilu za isto polje istega izdelka in
    ob potrditvi novejsega sporocila.

  O19 — uskladitev nove sifre sloni samo na EAN.
    Dodana je tabela out.SaopItemAssignment in procedura out.ResolveSaopItemAssignment z
    vrstnim redom odgovor SAOP -> zahtevana sifra -> EAN -> clovek. Dvoumen EAN namenoma
    NE velja za ujemanje: napacna povezava je slabsa od nobene.

  Kaj ta migracija NE naredi in je posteno povedati:
    - Odhodna pot danes poslje spremembo polja, ne ustvari artikla. Poti, ki bi
      out.ResolveSaopItemAssignment klicala v zivo, se ni; tabela in procedura sta
      pripravljeni in dokazani s testom, uporabi ju prvi ADD tok.
    - Stanje Error ostaja mrtva pot, kot je bilo. Tega ne resuje ta migracija.

  Omejitev, ki se ji ni bilo mogoce izogniti: stanje Superseded je treba dodati v
  CK_OutboxMessage_Status, obstojece omejitve pa v SQL Serverju ni mogoce razsiriti brez
  DROP in ponovnega CREATE. Podatki se pri tem ne izgubijo; omejitev se takoj postavi
  nazaj z novim stanjem in se preveri nad obstojecimi vrsticami (WITH CHECK).

  Migrator ne pozna locila GO, zato so procedure in stavki, ki se sklicujejo na pravkar
  dodani stolpec, zaviti v EXEC(N'...') — enako kot v migracijah 017, 042 in 044.
*/

SET XACT_ABORT ON;

/* --- 1) O18: razred napake ---------------------------------------------- */

IF COL_LENGTH(N'out.OutboxMessage', N'ErrorClass') IS NULL
  ALTER TABLE out.OutboxMessage ADD ErrorClass nvarchar(20) NULL;

IF COL_LENGTH(N'out.OutboxAttempt', N'ErrorClass') IS NULL
  ALTER TABLE out.OutboxAttempt ADD ErrorClass nvarchar(20) NULL;

IF NOT EXISTS(SELECT 1 FROM sys.check_constraints WHERE name=N'CK_OutboxMessage_ErrorClass')
  EXEC(N'
ALTER TABLE out.OutboxMessage WITH CHECK ADD CONSTRAINT CK_OutboxMessage_ErrorClass
  CHECK (ErrorClass IS NULL OR ErrorClass IN(N''Transient'',N''Business'',N''AuthConfig''));
');

IF NOT EXISTS(SELECT 1 FROM sys.check_constraints WHERE name=N'CK_OutboxAttempt_ErrorClass')
  EXEC(N'
ALTER TABLE out.OutboxAttempt WITH CHECK ADD CONSTRAINT CK_OutboxAttempt_ErrorClass
  CHECK (ErrorClass IS NULL OR ErrorClass IN(N''Transient'',N''Business'',N''AuthConfig''));
');

/* --- 2) O16: stanje Superseded ------------------------------------------ */

IF NOT EXISTS
(
  SELECT 1 FROM sys.check_constraints
  WHERE name=N'CK_OutboxMessage_Status' AND definition LIKE N'%Superseded%'
)
BEGIN
  IF EXISTS(SELECT 1 FROM sys.check_constraints WHERE name=N'CK_OutboxMessage_Status')
    ALTER TABLE out.OutboxMessage DROP CONSTRAINT CK_OutboxMessage_Status;
  EXEC(N'
ALTER TABLE out.OutboxMessage WITH CHECK ADD CONSTRAINT CK_OutboxMessage_Status
  CHECK (Status IN(N''PendingApproval'',N''Pending'',N''Sending'',N''Sent'',N''Verified'',
                   N''Drift'',N''Superseded'',N''Retry'',N''Error'',N''Dead'',N''Cancelled''));
');
END;

/* --- 3) O19: evidenca dodeljene sifre ------------------------------------ */

IF OBJECT_ID(N'out.SaopItemAssignment', N'U') IS NULL
  CREATE TABLE out.SaopItemAssignment
  (
    SaopItemAssignmentId bigint IDENTITY(1,1) NOT NULL,
    OrganizationId int NOT NULL,
    OutboxMessageId bigint NOT NULL,
    CorrelationId uniqueidentifier NOT NULL,
    RequestedIdentifier nvarchar(200) NULL,
    EAN nvarchar(200) NULL,
    AssignedSaopItemId nvarchar(200) NULL,
    MatchMethod nvarchar(40) NOT NULL,
    MatchDetail nvarchar(400) NULL,
    ResolvedUtc datetime2(3) NOT NULL CONSTRAINT DF_SaopItemAssignment_ResolvedUtc DEFAULT SYSUTCDATETIME(),
    ResolvedBy nvarchar(200) NOT NULL,
    CONSTRAINT PK_SaopItemAssignment PRIMARY KEY CLUSTERED (SaopItemAssignmentId),
    CONSTRAINT UQ_SaopItemAssignment_Message UNIQUE (OutboxMessageId),
    CONSTRAINT FK_SaopItemAssignment_Outbox FOREIGN KEY (OutboxMessageId) REFERENCES out.OutboxMessage (OutboxMessageId),
    CONSTRAINT CK_SaopItemAssignment_Method CHECK (MatchMethod IN(N'Response', N'RequestedIdentifier', N'EAN', N'Manual', N'Unresolved')),
    /* Nacin ujemanja brez dodeljene sifre je trditev brez pokritja; Unresolved je pa nima. */
    CONSTRAINT CK_SaopItemAssignment_Resolved CHECK
    (
      (MatchMethod = N'Unresolved' AND AssignedSaopItemId IS NULL)
      OR (MatchMethod <> N'Unresolved' AND AssignedSaopItemId IS NOT NULL)
    )
  );

IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID(N'out.SaopItemAssignment') AND name=N'IX_SaopItemAssignment_Unresolved')
  CREATE NONCLUSTERED INDEX IX_SaopItemAssignment_Unresolved
    ON out.SaopItemAssignment(OrganizationId, MatchMethod, ResolvedUtc) INCLUDE(EAN, RequestedIdentifier);

/* --- 4) procedure -------------------------------------------------------- */

EXEC(N'
CREATE OR ALTER PROCEDURE out.CompleteAttempt
  @OutboxMessageId bigint,@WorkerId nvarchar(200),@Succeeded bit,@PermanentFailure bit,
  @ResponseStatusCode int=NULL,@ResponseBodyRedacted nvarchar(4000)=NULL,@ResponseCorrelationId nvarchar(200)=NULL,
  @FailureReason nvarchar(2000)=NULL,@ErrorClass nvarchar(20)=NULL
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON; BEGIN TRAN;

  IF @ErrorClass IS NOT NULL AND @ErrorClass NOT IN(N''Transient'',N''Business'',N''AuthConfig'')
  BEGIN ROLLBACK; THROW 51011, ''Neznan razred napake.'', 1; END;

  DECLARE @Attempt int,@MaxAttempts int,@BaseRetrySeconds int,@Status nvarchar(30),
          @OrganizationId int,@TargetKind nvarchar(200),@EntityKey nvarchar(450);
  SELECT @Attempt=message.AttemptCount,@MaxAttempts=profile.MaxAttempts,@BaseRetrySeconds=profile.BaseRetrySeconds,
         @OrganizationId=message.OrganizationId,@TargetKind=message.TargetKind,@EntityKey=message.EntityKey
  FROM out.OutboxMessage message WITH(UPDLOCK,ROWLOCK)
  INNER JOIN dbo.IntegrationProfile profile ON profile.OrganizationId=message.OrganizationId AND profile.TargetKind=message.TargetKind
  WHERE message.OutboxMessageId=@OutboxMessageId AND message.Status=N''Sending'' AND message.LeaseOwner=@WorkerId;
  IF @Attempt IS NULL BEGIN ROLLBACK; THROW 51005, ''Lease ni veljaven.'', 1; END;

  /*
    Novost O18: razred napake odloca o poskusih.

      Business   — SAOP je zahtevo razumel in jo je zavrnil. Ponoviti isto zahtevo pomeni
                   dobiti isti odgovor; poskusi se zato ne porabijo, sporocilo gre takoj v
                   Dead in caka cloveka.
      AuthConfig — ne gre za ta artikel, ampak za integracijo (poverilnica, pravica, naslov).
                   Ponavljanje na vsakem artiklu naredi sto enakih alarmov; zato se kanal
                   ustavi in nastane en sam alarm na integracijo.
      Transient  — omrezje ali zasedenost. Edini razred, ki se sme ponavljati.

    @PermanentFailure ostaja podprt zaradi obstojecih klicateljev in pomeni isto kot Business.
  */
  SET @Status=
    CASE
      WHEN @Succeeded=1 THEN N''Sent''
      WHEN @ErrorClass IN(N''Business'',N''AuthConfig'') THEN N''Dead''
      WHEN @PermanentFailure=1 OR @Attempt>=@MaxAttempts THEN N''Dead''
      ELSE N''Retry''
    END;

  UPDATE out.OutboxMessage SET Status=@Status,SentUtc=CASE WHEN @Status=N''Sent'' THEN SYSUTCDATETIME() ELSE SentUtc END,
    NextAttemptUtc=CASE WHEN @Status=N''Retry'' THEN DATEADD(second,@BaseRetrySeconds*CONVERT(int,POWER(CONVERT(float,2),@Attempt-1)),SYSUTCDATETIME()) END,
    LeaseOwner=NULL,LeaseUntilUtc=NULL,LastError=@FailureReason,ErrorClass=CASE WHEN @Succeeded=1 THEN NULL ELSE @ErrorClass END,
    ResponseStatusCode=@ResponseStatusCode,ResponseBodyRedacted=@ResponseBodyRedacted,ResponseCorrelationId=@ResponseCorrelationId,
    UpdatedUtc=SYSUTCDATETIME()
  WHERE OutboxMessageId=@OutboxMessageId;

  UPDATE out.OutboxAttempt SET Outcome=@Status,CompletedUtc=SYSUTCDATETIME(),ResponseStatusCode=@ResponseStatusCode,
    ResponseBodyRedacted=@ResponseBodyRedacted,ResponseCorrelationId=@ResponseCorrelationId,FailureReason=@FailureReason,
    ErrorClass=CASE WHEN @Succeeded=1 THEN NULL ELSE @ErrorClass END
  WHERE OutboxMessageId=@OutboxMessageId AND AttemptNumber=@Attempt AND WorkerId=@WorkerId AND Outcome=N''Sending'';

  IF @Succeeded=0 AND @ErrorClass=N''AuthConfig''
  BEGIN
    UPDATE dbo.IntegrationProfile
    SET IsEnabled=0,UpdatedUtc=SYSUTCDATETIME(),UpdatedBy=N''out.CompleteAttempt''
    WHERE OrganizationId=@OrganizationId AND TargetKind=@TargetKind AND IsEnabled=1;

    DECLARE @AlertKey varchar(64)=CONVERT(char(64),HASHBYTES(''SHA2_256'',CONCAT(N''OUTBOUND_AUTH|'',@OrganizationId,N''|'',@TargetKind)),2);
    EXEC ops.UpsertAlert
      @OrganizationId=@OrganizationId,
      @Pipeline=@TargetKind,
      @AlertKind=N''OUTBOUND_AUTH'',
      @Severity=N''Critical'',
      @DedupKey=@AlertKey,
      @Title=N''Odhodni kanal je ustavljen zaradi napake avtentikacije ali nastavitve.'',
      @PayloadSummaryRedacted=@FailureReason,
      @Actor=@WorkerId;
  END;

  COMMIT;
END;
');

EXEC(N'
CREATE OR ALTER PROCEDURE out.EnqueueMessage
  @OrganizationId int, @TargetKind nvarchar(100), @Operation nvarchar(100),
  @EntityType nvarchar(100), @PayloadJson nvarchar(max), @Actor nvarchar(200), @OutboxMessageId bigint OUTPUT
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  DECLARE @EntityKey nvarchar(450), @Field nvarchar(200), @Value nvarchar(4000), @Qualifier nvarchar(450),
    @CanonicalPayload nvarchar(max), @PayloadHash char(64), @Status nvarchar(30), @PropertyCount int;
  IF NULLIF(LTRIM(RTRIM(@Actor)),N'''') IS NULL THROW 51006, ''Akter je obvezen.'', 1;
  IF NULLIF(LTRIM(RTRIM(@Operation)),N'''') IS NULL THROW 51007, ''Operacija je obvezna.'', 1;
  IF ISJSON(@PayloadJson)<>1 OR JSON_QUERY(@PayloadJson,N''$'') IS NULL THROW 51000, ''PayloadJson mora biti JSON objekt.'', 1;
  SELECT @PropertyCount=COUNT(*) FROM OPENJSON(@PayloadJson);
  IF @PropertyCount NOT IN(3,4) OR EXISTS(SELECT 1 FROM OPENJSON(@PayloadJson) WHERE [key] NOT IN(N''entityKey'',N''field'',N''value'',N''qualifier''))
    OR (SELECT COUNT(*) FROM OPENJSON(@PayloadJson) WHERE [key]=N''entityKey'' AND [type]=1)<>1
    OR (SELECT COUNT(*) FROM OPENJSON(@PayloadJson) WHERE [key]=N''field'' AND [type]=1)<>1
    OR (SELECT COUNT(*) FROM OPENJSON(@PayloadJson) WHERE [key]=N''value'' AND [type]=1)<>1
    OR (SELECT COUNT(*) FROM OPENJSON(@PayloadJson) WHERE [key]=N''qualifier'')>1
    OR EXISTS(SELECT 1 FROM OPENJSON(@PayloadJson) WHERE [key]=N''qualifier'' AND [type]<>1)
    THROW 51008, ''PayloadJson ne ustreza dovoljeni pogodbi odhodne spremembe.'', 1;
  SELECT @EntityKey=JSON_VALUE(@PayloadJson,N''$.entityKey''),@Field=JSON_VALUE(@PayloadJson,N''$.field''),@Value=JSON_VALUE(@PayloadJson,N''$.value''),@Qualifier=JSON_VALUE(@PayloadJson,N''$.qualifier'');
  IF NULLIF(LTRIM(RTRIM(@EntityKey)),N'''') IS NULL OR NULLIF(LTRIM(RTRIM(@Field)),N'''') IS NULL OR @Value IS NULL
    THROW 51009, ''PayloadJson vsebuje manjkajoco obvezno vrednost.'', 1;
  SELECT @Status=CASE WHEN ApprovalMode=N''Automatic'' THEN N''Pending'' ELSE N''PendingApproval'' END
  FROM dbo.IntegrationProfile WHERE OrganizationId=@OrganizationId AND TargetKind=@TargetKind AND IsEnabled=1;
  IF @Status IS NULL THROW 51001, ''Integracijski profil ni omogocen.'', 1;
  IF NOT EXISTS
  (
    SELECT 1 FROM out.OwnershipPolicy policy
    WHERE policy.OrganizationId=@OrganizationId AND policy.TargetKind=@TargetKind AND policy.EntityType=@EntityType
      AND policy.FieldName=@Field AND policy.Owner=N''PIM'' AND policy.IsEnabled=1
      AND (policy.ConstraintKind IS NULL
        OR (policy.ConstraintKind=N''PriceList'' AND policy.ConstraintValue=@Qualifier)
        OR (policy.ConstraintKind=N''ExactValue'' AND policy.ConstraintValue=@Value))
  ) THROW 51010, ''Polje ni dovoljeno za PIM odhodno spremembo.'', 1;
  SELECT @CanonicalPayload=(SELECT @EntityKey AS [entityKey],@Field AS [field],@Value AS [value],@Qualifier AS [qualifier] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
  SET @PayloadHash=CONVERT(char(64),HASHBYTES(''SHA2_256'',CONVERT(varbinary(max),@CanonicalPayload)),2);
  BEGIN TRY
    INSERT out.OutboxMessage(OrganizationId,TargetKind,Operation,EntityType,EntityKey,FieldSummary,PayloadJson,PayloadHash,ExpectedEchoHash,DedupKey,Status,NextAttemptUtc,CreatedBy)
    VALUES(@OrganizationId,@TargetKind,@Operation,@EntityType,@EntityKey,@Field,@CanonicalPayload,@PayloadHash,@PayloadHash,@PayloadHash,@Status,
      CASE WHEN @Status=N''Pending'' THEN DATEADD(millisecond,-1,SYSUTCDATETIME()) END,@Actor);
    SET @OutboxMessageId=SCOPE_IDENTITY();

    /*
      Novost O16: starejsa sporocila za isto polje istega izdelka postanejo Superseded.

      Brez tega ostane prejsnje sporocilo v stanju Sent za vedno: echo prinese novo vrednost,
      VerifyEcho potrdi novejse sporocilo, starejse pa nikoli ne dobi odgovora, ki bi mu
      ustrezal. Na nadzorni strani je to videti kot "poslano, SAOP ni potrdil" — laz, saj je
      SAOP potrdil tisto, kar je bilo poslano nazadnje.

      Kljuc namenoma vsebuje tudi qualifier: cena za cenik B2B ne sme nadomestiti cene za B2C.
      Sending se ne dotakne — tisto sporocilo ima worker v rokah; zanj poskrbi VerifyEcho.
      Dead se ne dotakne — poslovna zavrnitev mora ostati vidna, tudi ce je pozneje sla druga
      vrednost skozi.
    */
    UPDATE previous
    SET Status=N''Superseded'',
        NextAttemptUtc=NULL,LeaseOwner=NULL,LeaseUntilUtc=NULL,
        LastError=CONVERT(nvarchar(4000),CONCAT(N''Nadomesceno s sporocilom '',@OutboxMessageId,N'' za isto polje.'')),
        UpdatedUtc=SYSUTCDATETIME()
    FROM out.OutboxMessage previous
    WHERE previous.OutboxMessageId<>@OutboxMessageId
      AND previous.OrganizationId=@OrganizationId AND previous.TargetKind=@TargetKind
      AND previous.EntityType=@EntityType AND previous.EntityKey=@EntityKey
      AND previous.FieldSummary=@Field
      AND ISNULL(JSON_VALUE(previous.PayloadJson,N''$.qualifier''),N'''')=ISNULL(@Qualifier,N'''')
      AND previous.Status IN(N''PendingApproval'',N''Pending'',N''Retry'',N''Sent'');
  END TRY
  BEGIN CATCH
    IF ERROR_NUMBER() IN(2601,2627)
    BEGIN
      SELECT @OutboxMessageId=OutboxMessageId FROM out.OutboxMessage
      WHERE OrganizationId=@OrganizationId AND DedupKey=@PayloadHash AND Status IN(N''PendingApproval'',N''Pending'',N''Sending'',N''Sent'',N''Error'',N''Retry'');
      RETURN;
    END;
    THROW;
  END CATCH;
END;
');

EXEC(N'
CREATE OR ALTER PROCEDURE out.VerifyEcho @OrganizationId int,@EntityType nvarchar(100),@EntityKey nvarchar(450),@InboundHash char(64),@ObservedUtc datetime2(3)
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON; BEGIN TRAN;
  DECLARE @MessageId bigint,@Expected char(64),@SentUtc datetime2(3),@Field nvarchar(200),@Qualifier nvarchar(450),@TargetKind nvarchar(200);
  SELECT TOP(1) @MessageId=OutboxMessageId,@Expected=ExpectedEchoHash,@SentUtc=SentUtc
  FROM out.OutboxMessage WITH(UPDLOCK,ROWLOCK)
  WHERE OrganizationId=@OrganizationId AND EntityType=@EntityType AND EntityKey=@EntityKey AND Status=N''Sent''
    AND @ObservedUtc>=SentUtc AND ExpectedEchoHash=@InboundHash
  ORDER BY SentUtc DESC,OutboxMessageId DESC;
  IF @MessageId IS NULL
    SELECT TOP(1) @MessageId=OutboxMessageId,@Expected=ExpectedEchoHash,@SentUtc=SentUtc
    FROM out.OutboxMessage WITH(UPDLOCK,ROWLOCK)
    WHERE OrganizationId=@OrganizationId AND EntityType=@EntityType AND EntityKey=@EntityKey AND Status=N''Sent'' AND @ObservedUtc>=SentUtc
    ORDER BY SentUtc DESC,OutboxMessageId DESC;
  IF @MessageId IS NOT NULL
  BEGIN
    UPDATE out.OutboxMessage SET Status=CASE WHEN @InboundHash=@Expected THEN N''Verified'' ELSE N''Drift'' END,
      VerifiedUtc=CASE WHEN @InboundHash=@Expected THEN SYSUTCDATETIME() END,
      DriftDetail=CASE WHEN @InboundHash<>@Expected THEN N''Prejeti echo se ne ujema s pricakovanim hashom.'' END,UpdatedUtc=SYSUTCDATETIME()
    WHERE OutboxMessageId=@MessageId;

    /*
      Novost O16, drugi del: sporocilo, ki je bilo ob prihodu novejsega se v roki workerja
      (Sending), takrat ni moglo postati Superseded. Ko novejse sporocilo dobi svoj odgovor,
      starejsa poslana sporocila za isto polje ne cakajo vec na echo, ki ne bo prisel.
    */
    SELECT @Field=FieldSummary,@TargetKind=TargetKind,@Qualifier=JSON_VALUE(PayloadJson,N''$.qualifier'')
    FROM out.OutboxMessage WHERE OutboxMessageId=@MessageId;

    UPDATE previous
    SET Status=N''Superseded'',
        LastError=CONVERT(nvarchar(4000),CONCAT(N''Nadomesceno s sporocilom '',@MessageId,N'', ki je dobilo odgovor SAOP.'')),
        UpdatedUtc=SYSUTCDATETIME()
    FROM out.OutboxMessage previous
    WHERE previous.OutboxMessageId<>@MessageId
      AND previous.OrganizationId=@OrganizationId AND previous.TargetKind=@TargetKind
      AND previous.EntityType=@EntityType AND previous.EntityKey=@EntityKey
      AND previous.FieldSummary=@Field
      AND ISNULL(JSON_VALUE(previous.PayloadJson,N''$.qualifier''),N'''')=ISNULL(@Qualifier,N'''')
      AND previous.Status=N''Sent''
      AND previous.SentUtc<@SentUtc;
  END;
  COMMIT;
END;
');

EXEC(N'
CREATE OR ALTER PROCEDURE out.ResolveSaopItemAssignment
  @OutboxMessageId bigint,
  @ResponseItemId nvarchar(200)=NULL,
  @RequestedIdentifier nvarchar(200)=NULL,
  @EAN nvarchar(200)=NULL,
  @Actor nvarchar(200),
  @MatchMethod nvarchar(40)=NULL OUTPUT,
  @AssignedSaopItemId nvarchar(200)=NULL OUTPUT
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;

  DECLARE @OrganizationId int,@CorrelationId uniqueidentifier;
  SELECT @OrganizationId=OrganizationId,@CorrelationId=CorrelationId
  FROM out.OutboxMessage WHERE OutboxMessageId=@OutboxMessageId;
  IF @OrganizationId IS NULL THROW 51012, ''Odhodno sporocilo ne obstaja.'', 1;

  SET @ResponseItemId=NULLIF(LTRIM(RTRIM(@ResponseItemId)),N'''');
  SET @RequestedIdentifier=NULLIF(LTRIM(RTRIM(@RequestedIdentifier)),N'''');
  SET @EAN=NULLIF(LTRIM(RTRIM(@EAN)),N'''');

  DECLARE @MatchDetail nvarchar(400)=NULL;
  SET @AssignedSaopItemId=NULL;
  SET @MatchMethod=NULL;

  /* 1. Kar je povedal SAOP, je resnica. */
  IF @ResponseItemId IS NOT NULL
  BEGIN
    SET @AssignedSaopItemId=@ResponseItemId;
    SET @MatchMethod=N''Response'';
    SET @MatchDetail=N''Sifra iz odgovora SAOP.'';
  END;

  /* 2. Sifra, ki jo je PIM zahteval; SAOP je odgovoril uspesno in je ni zavrnil. */
  IF @MatchMethod IS NULL AND @RequestedIdentifier IS NOT NULL
  BEGIN
    SET @AssignedSaopItemId=@RequestedIdentifier;
    SET @MatchMethod=N''RequestedIdentifier'';
    SET @MatchDetail=N''Odgovor ni vseboval sifre; uporabljena je zahtevana sifra.'';
  END;

  /*
    3. Sele nato EAN — in samo, ce je enolicen.

    To je jedro vrzeli O19: doslej je bila uskladitev odvisna izkljucno od EAN. Ce EAN
    manjka, ni globalno unikaten ali ga SAOP normalizira, se artikel poveze na napacnega.
    Napacna povezava je slabsa od nobene, zato dvoumen EAN tu ne velja za ujemanje.
  */
  IF @MatchMethod IS NULL AND @EAN IS NOT NULL
  BEGIN
    DECLARE @EanMatches int=(SELECT COUNT(*) FROM canon.Product WHERE OrganizationId=@OrganizationId AND EAN=@EAN);
    IF @EanMatches=1
    BEGIN
      SELECT @AssignedSaopItemId=ItemID FROM canon.Product WHERE OrganizationId=@OrganizationId AND EAN=@EAN;
      SET @MatchMethod=N''EAN'';
      SET @MatchDetail=N''Enolicno ujemanje po EAN.'';
    END
    ELSE IF @EanMatches>1
      SET @MatchDetail=CONVERT(nvarchar(400),CONCAT(N''EAN ustreza '',@EanMatches,N'' artiklom; samodejna uskladitev bi lahko povezala napacnega.''));
    ELSE
      SET @MatchDetail=N''Za ta EAN ni artikla.'';
  END;

  /* 4. Ostane clovek. */
  IF @MatchMethod IS NULL
  BEGIN
    SET @MatchMethod=N''Unresolved'';
    SET @MatchDetail=COALESCE(@MatchDetail,N''Ni odgovora, ni zahtevane sifre, ni EAN.'');
  END;

  MERGE out.SaopItemAssignment AS target
  USING (SELECT @OutboxMessageId AS OutboxMessageId) AS source
    ON target.OutboxMessageId=source.OutboxMessageId
  WHEN MATCHED THEN UPDATE SET
    RequestedIdentifier=@RequestedIdentifier,EAN=@EAN,AssignedSaopItemId=@AssignedSaopItemId,
    MatchMethod=@MatchMethod,MatchDetail=@MatchDetail,ResolvedUtc=SYSUTCDATETIME(),ResolvedBy=@Actor
  WHEN NOT MATCHED THEN INSERT
    (OrganizationId,OutboxMessageId,CorrelationId,RequestedIdentifier,EAN,AssignedSaopItemId,MatchMethod,MatchDetail,ResolvedBy)
    VALUES(@OrganizationId,@OutboxMessageId,@CorrelationId,@RequestedIdentifier,@EAN,@AssignedSaopItemId,@MatchMethod,@MatchDetail,@Actor);
END;
');
