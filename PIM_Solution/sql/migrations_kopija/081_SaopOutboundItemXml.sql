/*
  081 — pogodba XML za pisanje artiklov v SAOP (ADD in PATCH).

  Zakaj: odhodna pot je doslej nosila PIM-ov interni JSON {entityKey, field, value},
  SAOP pa sprejema tipiziran XML dokument ItemsGeneralData s Content-Type application/xml.
  Prevoda med njima ni bilo, zato ni bilo mogoce poslati nicesar, tudi ko bi vse ostalo
  delovalo.

  Vir pogodbe ni ugibanje in ni swagger — swagger imen elementov ne pove dovolj natancno.
  Vir so RESNICNI zapisi iz stare vrste ..\PIM_test, pim.SaopItemOutboundQueue: 557 vrstic,
  od tega 427 z odgovorom SAOP. Prebrano samo za branje, kot dovoljuje AGENTS.md §1.

    ADD    POST  api/Item/AddItemsGeneralData     -> odgovor <CreateResult>, ResultCode=Created,
                                                     dodeljena sifra v Keys/Key[Name=SifraArtikla]/Value
    PATCH  PATCH api/Item/UpdateItemsGeneralData  -> odgovor <UpdateResult>, ResultCode=Ok
    napaka HTTP 409 z ovojem <ArrayOfError><Error><Level>ValidationError</Level><Message>...

  Kaj ta migracija naredi:
    1. out.SaopXmlField   — kje v dokumentu ItemsGeneralData stoji katero kanonicno polje.
                            Ena vrstica = en element. Vrstni red elementov je pomemben,
                            ker ga SAOP v odgovorih ohranja in ker je tako v vseh 427 zapisih.
    2. out.SaopAddDefault — vrednosti, ki jih PIM nima in jih je stari sistem imel zapisane
                            kot konstante v builder procedurah (ItemType, VATRateID ...).
                            Tu so podatek, ne trda koda, in se dajo popraviti brez migracije.
    3. out.GetSaopXmlContract     — prebere pogodbo (staticna, prebere se enkrat).
    4. out.GetSaopItemWriteState  — za en artikel vrne trenutne kanonicne vrednosti,
                                    privzetke in ali artikel v SAOP ze obstaja.

  Kaj ta migracija NAMENOMA NE naredi:
    - Ne posilja nicesar in ne odpira nobenega kanala. dbo.IntegrationProfile ostane prazen.
    - Ne dovoli nobenega novega polja. Kaj sme iti ven, odloca izkljucno out.OwnershipPolicy
      iz migracije 068; ta tabela opisuje samo OBLIKO dokumenta, ne pravice.
    - Ne dodaja opisov (ItemDescription). Ti gredo na svojo koncno tocko
      UpdateItemsDescriptions in sodijo v svoj korak.

  Zakaj sta IsActive in WebPublish posebna: v canon.Product sta bit, v SAOP sta crki.
  Vhodna pot (044_BulkProcessRawInbox, vrstice 279-288) pretvarja D/Y/TRUE/1 -> 1 in
  N/FALSE/0 -> 0. Obratna pot mora vrniti natanko tisto crko, ki jo je SAOP sprejel v
  resnicnih zapisih: IsActive 'D'/'N', WebPublish 'd'/'N'. Zato TrueValue in FalseValue
  nista izpeljana, ampak zapisana.

  Migrator ne pozna locila GO, celotna datoteka je en paket. CREATE PROCEDURE mora biti prvi
  stavek paketa, zato so procedure zavite v EXEC(N'...') — enako kot v 017, 042, 044 in 046.
*/

SET XACT_ABORT ON;

/* --- 1) Oblika dokumenta ItemsGeneralData -------------------------------- */

IF OBJECT_ID(N'out.SaopXmlField', N'U') IS NULL
BEGIN
  CREATE TABLE out.SaopXmlField
  (
    SaopXmlFieldId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_SaopXmlField PRIMARY KEY,
    TargetKind nvarchar(100) NOT NULL CONSTRAINT DF_SaopXmlField_TargetKind DEFAULT N'SAOP_PRODUCT',
    /* Item = neposredno pod <ItemGeneralData>; ostalo je ime podelementa. */
    Section nvarchar(50) NOT NULL,
    ElementName nvarchar(100) NOT NULL,
    /* Kanonicna koda iz pim.FieldOwnership.FieldKey. NULL = vrednosti PIM nima in pride
       iz out.SaopAddDefault (ItemType, VATRateID ...). */
    FieldKey nvarchar(200) NULL,
    SortOrder int NOT NULL,
    /* Ali brez tega polja ADD ni smiseln. Za PATCH ne velja nic od tega: PATCH nosi
       samo izpolnjena polja, ker vsako poslano polje SAOP prepise. */
    IsAddMandatory bit NOT NULL CONSTRAINT DF_SaopXmlField_AddMandatory DEFAULT (0),
    /* text | decimal4 | decimal8 | bool */
    ValueFormat nvarchar(30) NOT NULL CONSTRAINT DF_SaopXmlField_Format DEFAULT N'text',
    TrueValue nvarchar(20) NULL,
    FalseValue nvarchar(20) NULL,
    IsEnabled bit NOT NULL CONSTRAINT DF_SaopXmlField_Enabled DEFAULT (1),
    UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_SaopXmlField_UpdatedUtc DEFAULT SYSUTCDATETIME(),
    UpdatedBy nvarchar(200) NOT NULL CONSTRAINT DF_SaopXmlField_UpdatedBy DEFAULT N'migracija 081',
    CONSTRAINT UQ_SaopXmlField_Element UNIQUE (TargetKind, Section, ElementName),
    CONSTRAINT CK_SaopXmlField_Section CHECK (Section IN (N'Item', N'GeneralData', N'SalesData', N'StockData', N'PropertiesData')),
    CONSTRAINT CK_SaopXmlField_Format CHECK (ValueFormat IN (N'text', N'decimal4', N'decimal8', N'bool')),
    /* bool brez obeh crk je past: tiho bi poslal 'True', kar SAOP zavrne. */
    CONSTRAINT CK_SaopXmlField_Bool CHECK (ValueFormat <> N'bool' OR (TrueValue IS NOT NULL AND FalseValue IS NOT NULL))
  );
END;

/* Vrstni red in imena so prepisani iz resnicnih poslanih dokumentov, ne izmisljeni. */
MERGE out.SaopXmlField AS target
USING
(
  VALUES
    /* --- neposredno pod <ItemGeneralData> --- */
    (N'Item', N'ItemID',                 N'Product.ItemID',                      10, 1, N'text',     NULL, NULL),
    (N'Item', N'ItemTitle1',             N'ProductText.TITLE_ERP.sl',            30, 1, N'text',     NULL, NULL),
    (N'Item', N'ItemTitle2',             N'ProductText.TITLE_ERP2.sl',           40, 0, N'text',     NULL, NULL),
    /* --- <GeneralData> --- */
    (N'GeneralData', N'ItemType',              NULL,                            110, 1, N'text',     NULL, NULL),
    (N'GeneralData', N'ItemUnitOfMeas',        N'Product.UoM',                   120, 1, N'text',     NULL, NULL),
    (N'GeneralData', N'VATRateID',             NULL,                            130, 1, N'text',     NULL, NULL),
    (N'GeneralData', N'ItemGroup',             N'Product.ItemGroup',             140, 1, N'text',     NULL, NULL),
    (N'GeneralData', N'AccountingBookGroupID', N'Product.AccountingGroup',       150, 1, N'text',     NULL, NULL),
    (N'GeneralData', N'WebPublish',            N'Product.WebPublish',            160, 0, N'bool',     N'd', N'N'),
    (N'GeneralData', N'CustomsTariffNo',       N'ProductCommercial.CustomsTariff', 170, 0, N'text',   NULL, NULL),
    (N'GeneralData', N'ItemDepartment',        N'Product.Department',            180, 1, N'text',     NULL, NULL),
    (N'GeneralData', N'ItemEANCode',           N'Product.EAN',                   190, 0, N'text',     NULL, NULL),
    /* --- <SalesData> --- */
    (N'SalesData', N'DiscountGroup1ID',      N'Product.DiscountGroup',           210, 1, N'text',     NULL, NULL),
    (N'SalesData', N'IsActive',              N'Product.IsActive',                220, 1, N'bool',     N'D', N'N'),
    /* V starem sistemu je bila ta lastnost vedno enaka oddelku artikla; ker oddelek PIM ima,
       je to ista kanonicna koda in ne konstanta. */
    (N'SalesData', N'AdditionalProperty1ID', N'Product.Department',              230, 0, N'text',     NULL, NULL),
    (N'SalesData', N'AdditionalProperty4ID', NULL,                               240, 0, N'text',     NULL, NULL),
    /* --- <StockData> --- */
    (N'StockData', N'SupplierID',            N'Product.Supplier',                310, 1, N'text',     NULL, NULL),
    (N'StockData', N'ManufacturerID',        N'Product.Manufacturer',            320, 0, N'text',     NULL, NULL),
    /* --- <PropertiesData> --- */
    (N'PropertiesData', N'ItemWeightPerUnit',   N'ProductCommercial.NetWeight',      410, 0, N'decimal4', NULL, NULL),
    (N'PropertiesData', N'ItemGrossWeight',     N'ProductCommercial.GrossWeight',    420, 0, N'decimal4', NULL, NULL),
    (N'PropertiesData', N'ItemWidth',           N'ProductCommercial.PackageWidth',   430, 0, N'decimal8', NULL, NULL),
    (N'PropertiesData', N'ItemHeight',          N'ProductCommercial.PackageHeight',  440, 0, N'decimal8', NULL, NULL),
    (N'PropertiesData', N'ItemDimensionUOM',    N'ProductCommercial.DimensionUnit',  450, 0, N'text',     NULL, NULL),
    (N'PropertiesData', N'ItemCountryOfOrigin', N'ProductCommercial.CountryOfOrigin',460, 0, N'text',     NULL, NULL)
) AS source (Section, ElementName, FieldKey, SortOrder, IsAddMandatory, ValueFormat, TrueValue, FalseValue)
  ON target.TargetKind = N'SAOP_PRODUCT' AND target.Section = source.Section AND target.ElementName = source.ElementName
WHEN MATCHED THEN UPDATE SET
  FieldKey = source.FieldKey, SortOrder = source.SortOrder, IsAddMandatory = source.IsAddMandatory,
  ValueFormat = source.ValueFormat, TrueValue = source.TrueValue, FalseValue = source.FalseValue,
  UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = N'migracija 081'
WHEN NOT MATCHED THEN INSERT (Section, ElementName, FieldKey, SortOrder, IsAddMandatory, ValueFormat, TrueValue, FalseValue)
  VALUES (source.Section, source.ElementName, source.FieldKey, source.SortOrder, source.IsAddMandatory,
          source.ValueFormat, source.TrueValue, source.FalseValue);

/* --- 2) Privzetki, ki jih PIM nima -------------------------------------- */

IF OBJECT_ID(N'out.SaopAddDefault', N'U') IS NULL
BEGIN
  CREATE TABLE out.SaopAddDefault
  (
    SaopAddDefaultId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_SaopAddDefault PRIMARY KEY,
    OrganizationId int NOT NULL,
    /* Predpona sifre artikla do prve pike (NW, BA, LB ...) ali '*' za vse ostale.
       Stari sistem je isto locnico imel kot 'ManufacturerBuilders' v appsettings. */
    SourceKey nvarchar(50) NOT NULL,
    Section nvarchar(50) NOT NULL,
    ElementName nvarchar(100) NOT NULL,
    Value nvarchar(400) NOT NULL,
    IsEnabled bit NOT NULL CONSTRAINT DF_SaopAddDefault_Enabled DEFAULT (1),
    UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_SaopAddDefault_UpdatedUtc DEFAULT SYSUTCDATETIME(),
    UpdatedBy nvarchar(200) NOT NULL CONSTRAINT DF_SaopAddDefault_UpdatedBy DEFAULT N'migracija 081',
    CONSTRAINT UQ_SaopAddDefault UNIQUE (OrganizationId, SourceKey, Section, ElementName),
    CONSTRAINT FK_SaopAddDefault_Organization FOREIGN KEY (OrganizationId) REFERENCES dbo.OrganizationConfig(OrganizationId)
  );
END;

/*
  Vrednosti so prepisane iz builder procedur starega sistema
  (pim.usp_Saop_Build_AddItemsGeneralData_BA in _NW v bazi PIM_test) in so v resnicnih
  poslanih dokumentih. Niso izmisljene in niso privzetek "ker se zdi prav".

  Za vsako organizacijo enako, ker sta ItemType in VATRateID sifranta SAOP, ne PIM.
  AdditionalProperty1ID je v starem sistemu vedno enak oddelku artikla; ker oddelek PIM ima
  (Product.Department), ga tu NE podvajamo kot konstanto — izpelje ga gradnik.
*/
MERGE out.SaopAddDefault AS target
USING
(
  SELECT organization.OrganizationId, source.SourceKey, source.Section, source.ElementName, source.Value
  FROM dbo.OrganizationConfig AS organization
  CROSS JOIN
  (
    VALUES
      (N'*',  N'GeneralData', N'ItemType',              N'B'),
      (N'*',  N'GeneralData', N'VATRateID',             N'02'),
      (N'*',  N'SalesData',   N'AdditionalProperty4ID', N'B2B')
  ) AS source (SourceKey, Section, ElementName, Value)
) AS source
  ON target.OrganizationId = source.OrganizationId AND target.SourceKey = source.SourceKey
    AND target.Section = source.Section AND target.ElementName = source.ElementName
WHEN NOT MATCHED THEN INSERT (OrganizationId, SourceKey, Section, ElementName, Value)
  VALUES (source.OrganizationId, source.SourceKey, source.Section, source.ElementName, source.Value);

/* --- 3) Branje pogodbe -------------------------------------------------- */

EXEC(N'
CREATE OR ALTER PROCEDURE out.GetSaopXmlContract @TargetKind nvarchar(100) = N''SAOP_PRODUCT''
AS
BEGIN
  SET NOCOUNT ON;
  SELECT Section, ElementName, FieldKey, SortOrder, IsAddMandatory, ValueFormat, TrueValue, FalseValue
  FROM out.SaopXmlField
  WHERE TargetKind = @TargetKind AND IsEnabled = 1
  ORDER BY SortOrder;
END;');

/* --- 4) Stanje enega artikla ------------------------------------------- */

/*
  Tri rezultatne mnozice:
    1) glava    — ProductId, ItemID, SourceKey in ali artikel v SAOP ze obstaja
    2) vrednosti— kanonicne vrednosti pisljivih polj (samo neprazne)
    3) privzetki— vrstice iz out.SaopAddDefault za to organizacijo in izvor

  Kako vemo, ali artikel v SAOP ze obstaja: v canon.Product artikel lahko USTVARI samo
  konektor z map.SourceConnector.CanCreateProducts = 1, kar je danes izkljucno SAOP
  (dobaviteljevi feedi BT_XML in NW_XML imajo 0 in obstojece artikle samo dopolnijo).
  Zato je prisotnost v canon.Product za to organizacijo dokaz, da artikel v SAOP obstaja,
  in s tem pravilo za izbiro PATCH namesto ADD.

  Zakaj to sploh steje: v stari vrsti je 118 od 130 napak natanko ta ena napaka —
  "Zapis za artikel ze obstaja" (poslan ADD namesto PATCH) ali "sifra artikla ne obstaja"
  (poslan PATCH namesto ADD). Ta odlocitev zato ne sme biti rocna.
*/
EXEC(N'
CREATE OR ALTER PROCEDURE out.GetSaopItemWriteState @OrganizationId int, @ItemID nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON;

  DECLARE @ProductId bigint, @SourceKey nvarchar(50);
  SELECT @ProductId = ProductId FROM canon.Product WHERE OrganizationId = @OrganizationId AND ItemID = @ItemID;

  /* Predpona do prve pike; brez pike ni izvora in velja splosni privzetek. */
  SET @SourceKey = CASE
    WHEN CHARINDEX(N''.'', @ItemID) > 1 THEN UPPER(LEFT(@ItemID, CHARINDEX(N''.'', @ItemID) - 1))
    ELSE N''*'' END;

  SELECT
    ProductId = @ProductId,
    ItemID = @ItemID,
    SourceKey = @SourceKey,
    ExistsInSaop = CONVERT(bit, CASE WHEN @ProductId IS NULL THEN 0 ELSE 1 END);

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

/* --- 5) Preverbe -------------------------------------------------------- */

/*
  Vsako polje s kanonicno kodo mora ustrezati kodi, ki jo odhodna pot ze pozna iz migracije
  068 (out.OwnershipPolicy). Brez te preverbe bi tipkarska napaka v kodi tiho pomenila polje,
  ki se nikoli ne izpolni, in dokument bi odsel brez njega.

  Merilo je namenoma out.OwnershipPolicy in ne pim.FieldOwnership: slednja pokriva sledenje
  sprememb (20 vrstic) in ne pozna niti Product.ItemID niti dimenzij paketa, ceprav sta oboje
  v kanonicnem modelu in v resnicnih dokumentih SAOP. Merodajen za odhodno pot je register
  lastnistva, ne register sledenja.

  Besedila (ProductText.*) so izvzeta: njihova koda nosi se vrsto in jezik, zato so v
  registru samo tiste kombinacije, ki jih PIM res bere.
*/
IF EXISTS
(
  SELECT 1 FROM out.SaopXmlField field
  WHERE field.FieldKey IS NOT NULL
    AND field.FieldKey NOT LIKE N'ProductText.%'
    AND NOT EXISTS (SELECT 1 FROM out.OwnershipPolicy policy WHERE policy.FieldName = field.FieldKey)
)
  THROW 52810, 'Pogodba XML se sklicuje na kanonicno kodo, ki je out.OwnershipPolicy ne pozna.', 1;

/* Vsako ADD obvezno polje mora biti ali kanonicno ali imeti privzetek; sicer ADD ne more uspeti. */
IF EXISTS
(
  SELECT 1 FROM out.SaopXmlField field
  WHERE field.IsAddMandatory = 1 AND field.IsEnabled = 1 AND field.FieldKey IS NULL
    AND NOT EXISTS
    (
      SELECT 1 FROM out.SaopAddDefault d
      WHERE d.Section = field.Section AND d.ElementName = field.ElementName AND d.IsEnabled = 1
    )
)
  THROW 52811, 'ADD obvezno polje nima ne kanonicnega vira ne privzetka.', 1;

IF (SELECT COUNT(*) FROM out.SaopXmlField WHERE TargetKind = N'SAOP_PRODUCT' AND IsEnabled = 1) < 24
  THROW 52812, 'Pogodba XML je nepopolna; pricakovanih je vsaj 24 elementov.', 1;

IF NOT EXISTS (SELECT 1 FROM out.SaopAddDefault WHERE ElementName = N'ItemType')
  THROW 52813, 'Privzetek ItemType manjka; ADD brez njega SAOP zavrne.', 1;
