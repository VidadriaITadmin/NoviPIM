/*
  169 — ali artikel obstaja v SAOP, je odslej zapisano NA ARTIKLU; ne sklepa se vec iz tega,
  ali vrstica obstaja v canon.Product.

  Kaj je bilo narobe
  ------------------
  Odhodna pot mora za vsak artikel izbrati POST (nov zapis) ali PATCH (sprememba). To je
  odlocitev, ki je bila v stari vrsti vzrok 118 od 130 napak, zato je izpeljana in ne rocna
  (out.SaopIntentResolver, migracije 081/084/086). Merilo je bilo:

      ExistsInSaop = ali v canon.Product obstaja vrstica s to sifro

  To je bilo pravilno samo zaradi ene okoliscine: nove artikle je v canon.Product smel
  ustvariti izkljucno konektor z map.SourceConnector.CanCreateProducts = 1, kar je bil doslej
  samo SAOP (migracija 042). Prisotnost v kanonicnem modelu je bila zato res dokaz obstoja v
  SAOP.

  Ta okoliscina pada. Za nujno spletno objavo elektro artiklov bodo artikle v canon.Product
  ustvarjali tudi viri, ki niso ERP (scraper, rocni Excel). Tak artikel je v PIM, v SAOP pa
  ga ni. Staro merilo bi zanj reklo "obstaja" in odhodna pot bi poslala PATCH na zapis, ki ga
  v SAOP ni — torej natanko tista napaka, ki jo je bila izbira metode postavljena preprecevat.

  Kaj ta migracija naredi
  -----------------------
  1. canon.Product.ErpExistence (NOT_YET_IN_ERP / CONFIRMED_IN_ERP).
  2. Tri mesta, ki so ExistsInSaop sklepala iz obstoja vrstice, berejo odslej ta stolpec:
     out.GetSaopItemWriteState (081), out.ClaimItemDocument (084), out.PeekItemDocuments (086).
     Procedure so tu prepisane v celoti in nespremenjene razen tega enega merila; preverjeno je
     bilo, da je njihova ziva definicija v bazi enaka tisti iz 081/084/086 (sys.sql_modules,
     modify_date 2026-08-23), torej se s tem prepisom ne povozi nobena poznejsa sprememba.

  Kaj ta migracija NAMENOMA NE spremeni
  -------------------------------------
  - Vedenja za obstojece artikle. Privzetek je CONFIRMED_IN_ERP, zato vseh 196.566 obstojecih
    artiklov ohrani tocno tisti pomen, ki so ga imeli doslej ("v canon.Product je => SAOP ga
    pozna"), in izbira POST/PATCH se zanje ne spremeni.
  - Zapisovalne poti. map.ProcessRawInbox se tu NE dotika: dokler je edini vir, ki sme
    ustvarjati artikle, SAOP, je privzetek pravilen. Vpis NOT_YET_IN_ERP ob ustvarjanju iz
    ne-ERP vira je naloga naslednjega koraka, skupaj z registracijo tega vira.
  - Zavrnitve SAOP. SaopIntentResolver ze danes pusti, da odgovor SAOP prevlada nad tem, kar
    sklepamo iz baze (ItemAlreadyExists -> PATCH, ItemNotFound -> POST). Ta samopopravek
    ostane in je varovalka, ce bi bila zastavica kdaj napacna.

  Zakaj stevilka 169 in ne 155
  ----------------------------
  dbo.SchemaMigration v razvojni bazi PIM ima uporabljene migracije do 168, katerih izvornih
  datotek v tej delovni kopiji ni (najvisja tukaj je 154). Nova migracija zato dobi prvo
  stevilko nad zadnjo uporabljeno, da se nobena stevilka ne podvoji.

  Migrator ne pozna locila GO; vse, kar se sklicuje na pravkar dodani stolpec, in vse
  procedure so v EXEC(N'...') — enako kot v 017, 042, 139 in 152.
*/

SET XACT_ABORT ON;

/* --- 1) Zastavica na artiklu -------------------------------------------- */

IF COL_LENGTH(N'canon.Product', N'ErpExistence') IS NULL
  ALTER TABLE canon.Product
    ADD ErpExistence nvarchar(20) NOT NULL
      CONSTRAINT DF_Product_ErpExistence DEFAULT (N'CONFIRMED_IN_ERP');

/* Stolpec nastane v tej isti seriji, zato omejitev nad njim ne more biti preveden del iste
   serije; gre skozi EXEC. */
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_Product_ErpExistence')
  EXEC(N'
  ALTER TABLE canon.Product
    ADD CONSTRAINT CK_Product_ErpExistence
      CHECK (ErpExistence IN (N''NOT_YET_IN_ERP'', N''CONFIRMED_IN_ERP''));');

/* --- 2) Stanje enega artikla (081) --------------------------------------- */

/*
  Edina sprememba proti 081: ExistsInSaop ne pride vec iz "@ProductId ni NULL", ampak iz
  zastavice. Artikel, ki ga v canon.Product ni, ostane 0 kot doslej (@ErpExistence je NULL).
*/
EXEC(N'
CREATE OR ALTER PROCEDURE out.GetSaopItemWriteState @OrganizationId int, @ItemID nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON;

  DECLARE @ProductId bigint, @SourceKey nvarchar(50), @ErpExistence nvarchar(20);
  SELECT @ProductId = ProductId, @ErpExistence = ErpExistence
  FROM canon.Product WHERE OrganizationId = @OrganizationId AND ItemID = @ItemID;

  /* Predpona do prve pike; brez pike ni izvora in velja splosni privzetek. */
  SET @SourceKey = CASE
    WHEN CHARINDEX(N''.'', @ItemID) > 1 THEN UPPER(LEFT(@ItemID, CHARINDEX(N''.'', @ItemID) - 1))
    ELSE N''*'' END;

  SELECT
    ProductId = @ProductId,
    ItemID = @ItemID,
    SourceKey = @SourceKey,
    ExistsInSaop = CONVERT(bit, CASE WHEN @ErpExistence = N''CONFIRMED_IN_ERP'' THEN 1 ELSE 0 END);

  SELECT field.FieldKey, field.Value
  FROM
  (
    SELECT value.FieldKey, value.Value
    FROM canon.Product AS product
    LEFT JOIN canon.ProductCommercial AS commercial ON commercial.ProductId = product.ProductId
    CROSS APPLY
    (
      VALUES
        (N''Product.ItemID'',          product.ItemID),
        (N''Product.UoM'',             product.UoM),
        (N''Product.ItemGroup'',       product.ItemGroup),
        (N''Product.AccountingGroup'', product.AccountingGroup),
        (N''Product.Department'',      product.Department),
        (N''Product.DiscountGroup'',   product.DiscountGroup),
        (N''Product.EAN'',             product.EAN),
        (N''Product.Supplier'',        product.Supplier),
        (N''Product.Manufacturer'',    product.Manufacturer),
        (N''Product.IsActive'',        CONVERT(nvarchar(400), product.IsActive)),
        (N''Product.WebPublish'',      CONVERT(nvarchar(400), product.WebPublish)),
        (N''ProductCommercial.CustomsTariff'',   commercial.CustomsTariff),
        (N''ProductCommercial.CountryOfOrigin'', commercial.CountryOfOrigin),
        (N''ProductCommercial.DimensionUnit'',   commercial.DimensionUnit),
        (N''ProductCommercial.NetWeight'',       CONVERT(nvarchar(400), commercial.NetWeight)),
        (N''ProductCommercial.GrossWeight'',     CONVERT(nvarchar(400), commercial.GrossWeight)),
        (N''ProductCommercial.PackageWidth'',    CONVERT(nvarchar(400), commercial.PackageWidth)),
        (N''ProductCommercial.PackageHeight'',   CONVERT(nvarchar(400), commercial.PackageHeight))
    ) AS value (FieldKey, Value)
    WHERE product.ProductId = @ProductId

    UNION ALL

    SELECT N''ProductText.'' + text.TextType + N''.'' + text.Lang, text.Value
    FROM canon.ProductText AS text
    WHERE text.ProductId = @ProductId AND text.TextType IN (N''TITLE_ERP'', N''TITLE_ERP2'') AND text.Lang = N''sl''
  ) AS field
  WHERE NULLIF(LTRIM(RTRIM(field.Value)), N'''') IS NOT NULL;

  SELECT Section, ElementName, Value
  FROM out.SaopAddDefault
  WHERE OrganizationId = @OrganizationId AND IsEnabled = 1 AND SourceKey IN (N''*'', @SourceKey)
  /* Privzetek za konkreten izvor prevlada nad splosnim. */
  ORDER BY CASE WHEN SourceKey = N''*'' THEN 1 ELSE 0 END;
END;');

/* --- 3) Prevzem dokumenta (084) ------------------------------------------ */

/* Edina sprememba proti 084: v EXISTS je dodan pogoj o zastavici. */
EXEC(N'
CREATE OR ALTER PROCEDURE out.ClaimItemDocument @WorkerId nvarchar(200), @LeaseSeconds int = 90
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON; BEGIN TRAN;

  DECLARE @OrganizationId int, @EntityKey nvarchar(450);

  SELECT TOP(1) @OrganizationId = message.OrganizationId, @EntityKey = message.EntityKey
  FROM out.OutboxMessage AS message WITH (UPDLOCK, READPAST, ROWLOCK)
  INNER JOIN dbo.IntegrationProfile AS profile
    ON profile.OrganizationId = message.OrganizationId AND profile.TargetKind = message.TargetKind AND profile.IsEnabled = 1
  WHERE message.TargetKind = N''SAOP_PRODUCT'' AND message.EntityType = N''Product''
    AND message.Status IN (N''Pending'', N''Retry'')
    AND (message.NextAttemptUtc IS NULL OR message.NextAttemptUtc <= SYSUTCDATETIME())
    AND (message.LeaseUntilUtc IS NULL OR message.LeaseUntilUtc < SYSUTCDATETIME())
  ORDER BY message.OutboxMessageId;

  IF @EntityKey IS NULL BEGIN COMMIT; RETURN; END;

  DECLARE @Claimed TABLE(OutboxMessageId bigint PRIMARY KEY);

  UPDATE message
  SET Status = N''Sending'', AttemptCount = message.AttemptCount + 1,
      LeaseOwner = @WorkerId, LeaseUntilUtc = DATEADD(second, @LeaseSeconds, SYSUTCDATETIME()),
      UpdatedUtc = SYSUTCDATETIME()
  OUTPUT inserted.OutboxMessageId INTO @Claimed
  FROM out.OutboxMessage AS message WITH (UPDLOCK, ROWLOCK)
  WHERE message.OrganizationId = @OrganizationId AND message.EntityKey = @EntityKey
    AND message.TargetKind = N''SAOP_PRODUCT'' AND message.EntityType = N''Product''
    AND message.Status IN (N''Pending'', N''Retry'')
    AND (message.NextAttemptUtc IS NULL OR message.NextAttemptUtc <= SYSUTCDATETIME())
    AND (message.LeaseUntilUtc IS NULL OR message.LeaseUntilUtc < SYSUTCDATETIME());

  INSERT out.OutboxAttempt(OutboxMessageId, AttemptNumber, WorkerId)
  SELECT message.OutboxMessageId, message.AttemptCount, @WorkerId
  FROM out.OutboxMessage AS message INNER JOIN @Claimed AS claimed ON claimed.OutboxMessageId = message.OutboxMessageId;

  SELECT
    OrganizationId = @OrganizationId,
    ItemID = @EntityKey,
    BaseUrl = profile.EndpointTemplate,
    AddPath = ISNULL(profile.AddPath, N''api/Item/AddItemsGeneralData''),
    UpdatePath = ISNULL(profile.UpdatePath, N''api/Item/UpdateItemsGeneralData''),
    profile.TimeoutSeconds,
    profile.MaxAttempts,
    ExistsInSaop = CONVERT(bit, CASE WHEN EXISTS
      (SELECT 1 FROM canon.Product WHERE OrganizationId = @OrganizationId AND ItemID = @EntityKey
        AND ErpExistence = N''CONFIRMED_IN_ERP'') THEN 1 ELSE 0 END),
    LastErrorKind =
    (
      SELECT TOP(1) message.SaopErrorKind FROM out.OutboxMessage AS message
      INNER JOIN @Claimed AS claimed ON claimed.OutboxMessageId = message.OutboxMessageId
      WHERE message.SaopErrorKind IS NOT NULL ORDER BY message.OutboxMessageId DESC
    ),
    SourceKey = CASE WHEN CHARINDEX(N''.'', @EntityKey) > 1
      THEN UPPER(LEFT(@EntityKey, CHARINDEX(N''.'', @EntityKey) - 1)) ELSE N''*'' END
  FROM dbo.IntegrationProfile AS profile
  WHERE profile.OrganizationId = @OrganizationId AND profile.TargetKind = N''SAOP_PRODUCT'';

  SELECT message.OutboxMessageId, FieldKey = message.FieldSummary,
    Value = JSON_VALUE(message.PayloadJson, N''$.value''),
    message.AttemptCount, message.OutboundBatchId
  FROM out.OutboxMessage AS message
  INNER JOIN @Claimed AS claimed ON claimed.OutboxMessageId = message.OutboxMessageId
  ORDER BY message.OutboxMessageId;

  SELECT Section, ElementName, Value
  FROM out.SaopAddDefault
  WHERE OrganizationId = @OrganizationId AND IsEnabled = 1
    AND SourceKey IN (N''*'', CASE WHEN CHARINDEX(N''.'', @EntityKey) > 1
      THEN UPPER(LEFT(@EntityKey, CHARINDEX(N''.'', @EntityKey) - 1)) ELSE N''*'' END)
  ORDER BY CASE WHEN SourceKey = N''*'' THEN 1 ELSE 0 END;

  COMMIT;
END;');

/* --- 4) Suhi tek (086) --------------------------------------------------- */

/* Edina sprememba proti 086: v EXISTS je dodan pogoj o zastavici. Suhi tek mora pokazati
   isto metodo, kot jo bo uporabil pravi prevzem; sicer pregled pred posiljanjem laze. */
EXEC(N'
CREATE OR ALTER PROCEDURE out.PeekItemDocuments
  @OrganizationId int = NULL, @TargetKind nvarchar(100) = N''SAOP_PRODUCT'', @Top int = 50
AS
BEGIN
  SET NOCOUNT ON;

  /* Dokumenti, ki bi bili prevzeti ob naslednjem zagonu, po istem merilu kot prevzem —
     brez pogoja o omogocenem profilu, ker je suhi tek namenjen prav preverjanju PRED tem,
     da se profil omogoci. */
  ;WITH pripravljeni AS
  (
    SELECT message.OrganizationId, message.EntityKey,
      Sporocil = COUNT(*),
      Najstarejse = MIN(message.OutboxMessageId),
      Poskusov = MAX(message.AttemptCount),
      ZadnjaNapaka = MAX(message.SaopErrorKind)
    FROM out.OutboxMessage AS message
    WHERE message.TargetKind = @TargetKind
      AND (@OrganizationId IS NULL OR message.OrganizationId = @OrganizationId)
      AND message.Status IN (N''Pending'', N''Retry'')
      AND (message.NextAttemptUtc IS NULL OR message.NextAttemptUtc <= SYSUTCDATETIME())
    GROUP BY message.OrganizationId, message.EntityKey
  )
  SELECT TOP(@Top) pripravljeni.OrganizationId, pripravljeni.EntityKey, pripravljeni.Sporocil,
    pripravljeni.Poskusov, pripravljeni.ZadnjaNapaka,
    ExistsInSaop = CONVERT(bit, CASE WHEN EXISTS
      (SELECT 1 FROM canon.Product WHERE OrganizationId = pripravljeni.OrganizationId
        AND ItemID = pripravljeni.EntityKey AND ErpExistence = N''CONFIRMED_IN_ERP'')
      THEN 1 ELSE 0 END),
    SourceKey = CASE WHEN CHARINDEX(N''.'', pripravljeni.EntityKey) > 1
      THEN UPPER(LEFT(pripravljeni.EntityKey, CHARINDEX(N''.'', pripravljeni.EntityKey) - 1)) ELSE N''*'' END
  FROM pripravljeni
  ORDER BY pripravljeni.Najstarejse;
END;');

/* --- 5) Preverbe --------------------------------------------------------- */

IF COL_LENGTH(N'canon.Product', N'ErpExistence') IS NULL
  THROW 51690, N'169: canon.Product.ErpExistence ni nastal.', 1;

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_Product_ErpExistence')
  THROW 51691, N'169: CK_Product_ErpExistence ni nastal.', 1;

/* Nobena od treh procedur ne sme ostati na starem merilu: ce se katera sklicuje na
   canon.Product brez zastavice, bi POST/PATCH se naprej ugibala iz obstoja vrstice. */
IF EXISTS
(
  SELECT 1 FROM sys.sql_modules AS m
  WHERE m.object_id IN (OBJECT_ID(N'out.GetSaopItemWriteState'), OBJECT_ID(N'out.ClaimItemDocument'),
                        OBJECT_ID(N'out.PeekItemDocuments'))
    AND m.definition NOT LIKE N'%ErpExistence%'
)
  THROW 51692, N'169: izbira POST/PATCH se vedno ne bere canon.Product.ErpExistence.', 1;

/* Obstojeci artikli morajo ohraniti dosedanji pomen; karkoli drugega bi tiho spremenilo
   izbiro metode za ze delujoce artikle. */
EXEC(N'
IF EXISTS (SELECT 1 FROM canon.Product WHERE ErpExistence <> N''CONFIRMED_IN_ERP'')
  THROW 51693, N''169: obstojeci artikel ni ostal CONFIRMED_IN_ERP.'', 1;');
