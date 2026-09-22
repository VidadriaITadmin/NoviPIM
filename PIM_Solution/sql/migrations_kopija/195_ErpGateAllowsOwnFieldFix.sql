/*
  195 - varovalka 194 (out.TR_OutboxMessage_ErpQualityGate) je artikel z blokirajoco napako
  zaklenila tudi za polje, ki je vzrok te napake. Uporabnik je poskusil vpisati manjkajoco
  vrednost (npr. Product.VatRateId, ProductAttribute.Garancija) na artiklu, ki jo prav zato
  pogresa - sporocilo je bilo zavrnjeno z 51497 "Artikel ni pripravljen za ERP", ker
  val.IsProductChannelReady gleda VSE odprte blokirajoce napake artikla, ne glede na to, katero
  polje popravlja sporocilo, ki ga proza. Popravek ni bil mogoc: artikla ni bilo mogoce narediti
  pripravljenega, ker edina pot do popravka (vrsta za SAOP) je bila zaprta prav zaradi
  nepripravljenosti. Brez izhoda bi vsak tako blokiran artikel ostal blokiran za vedno.

  Kaj varovalka 194 dejansko sme prepovedati: nova sporocila za DRUGA polja istega pokvarjenega
  artikla (da se vrsta ne polni z necim, kar tako ali tako ne bo poslano, dokler artikel ni
  popravljen). Polje, ki je samo vzrok trenutne blokirajoce napake, mora ostati urejivo - drugace
  ni poti iz stanja.

  val.IsProductChannelReady ostane nespremenjen (edini klicatelj je bil ta prozilec; drugod v
  bazi ni klica), ker skalarna funkcija v SELECT ne dovoli izpuscenih parametrov - vsak klic bi
  bilo treba popraviti. Namesto tega nova funkcija z dodatnim parametrom, ki izloci polje
  sporocila iz preverbe odprtih napak.
*/
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;

EXEC(N'
CREATE OR ALTER FUNCTION val.IsProductChannelReadyForField
(
  @OrganizationId int, @ItemId nvarchar(450), @ChannelCode nvarchar(20), @ExcludeFieldKey nvarchar(200)
)
RETURNS bit
AS
BEGIN
  DECLARE @ProductId bigint, @LastValidatedUtc datetime2(3);
  SELECT @ProductId=ProductId,@LastValidatedUtc=LastValidatedUtc
  FROM canon.Product WHERE OrganizationId=@OrganizationId AND ItemID=@ItemId AND IsActive=1;
  IF @ProductId IS NULL OR @LastValidatedUtc IS NULL
    OR @LastValidatedUtc<DATEADD(hour,-2,SYSUTCDATETIME()) RETURN 0;

  IF EXISTS(SELECT 1 FROM val.ProductHold
            WHERE ProductId=@ProductId AND IsActive=1
              AND (ChannelCode=N''ALL'' OR ChannelCode=@ChannelCode)) RETURN 0;

  IF EXISTS
  (
    SELECT 1 FROM val.ProductIssue AS issue
    INNER JOIN val.FieldRequirement AS requirement ON requirement.FieldRequirementId=issue.FieldRequirementId
    INNER JOIN val.ValidationProfile AS profile ON profile.ValidationProfileId=issue.ValidationProfileId
    WHERE issue.ProductId=@ProductId AND issue.IsActive=1 AND requirement.IsActive=1
      AND requirement.Severity=N''ERROR'' AND profile.IsActive=1
      AND ((@ChannelCode=N''ERP'' AND profile.BlocksErp=1)
        OR (@ChannelCode=N''WEB'' AND profile.BlocksWeb=1))
      AND (@ExcludeFieldKey IS NULL OR requirement.FieldCode<>@ExcludeFieldKey)
  ) RETURN 0;
  RETURN 1;
END;');

/* Zamenja prozilec iz 194: ista varovalka, dodan izjema za polje, ki ga sporocilo samo popravlja. */
EXEC(N'
CREATE OR ALTER TRIGGER out.TR_OutboxMessage_ErpQualityGate ON out.OutboxMessage
AFTER INSERT,UPDATE AS
BEGIN
  SET NOCOUNT ON;
  IF EXISTS
  (
    SELECT 1 FROM inserted AS message
    INNER JOIN canon.Product AS product
      ON product.OrganizationId=message.OrganizationId AND product.ItemID=message.EntityKey
    WHERE message.TargetKind=N''SAOP_PRODUCT'' AND message.EntityType=N''Product''
      AND message.Status IN(N''PendingApproval'',N''Pending'',N''Retry'',N''Sending'')
      AND val.IsProductChannelReadyForField(message.OrganizationId,message.EntityKey,N''ERP'',message.FieldSummary)=0
  ) THROW 51497,N''Artikel ni pripravljen za ERP. Najprej odpravite blokirajoce napake ali sprostite rocni zadrzek.'',1;
END;');

IF OBJECT_ID(N'val.IsProductChannelReadyForField', N'FN') IS NULL
  THROW 51501, '195: val.IsProductChannelReadyForField ni nastala.', 1;
