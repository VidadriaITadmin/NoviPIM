/*
  087 — zadnje stiri koncne tocke SAOP dobijo cilj, dobaviteljeva zaloga pa vsa stiri podjetja.

  Stanje pred to migracijo (merjeno 2026-08-23 nad razvojno bazo, migracija 086):

      raw.Inbox Pending po entiteti      Customers 4, CustomerItemGroupDiscounts 4,
                                         GetItemCustomerDataV2 8, TechnologicalProcess 4
      b2b.Customer                       0 vrstic
      canon.Codebook                     0 vrstic
      NW_STOCK / BT_STOCK konektor        samo podjetje 2

  Migracija 082 je zapisala, da je "preslikanih vseh petnajst koncnih tock, ki kaj vrnejo, in da
  sestnajsta (tehnoloski proces) vraca prazen seznam". Prvi del je bil resnicen sele po tej
  migraciji, drugi pa ne drzi: tehnoloski proces je prazen samo pri DEMO. Presteto v bazi —
  Vidadria 101 zapisov, Ediito 13, IQLighting 5, DEMO 0. Trditev je bila narejena na enem
  podjetju in posplosena na vsa.

  Kaj ta migracija naredi:

    1. b2b.Customer dobi stolpce, ki jih SAOP posilja in jih preglednica vhodnih polj
       (docs/Vhodni_podatki_popis.csv) ze ima pripisane kot cilj.
    2. Novi tabeli b2b.CustomerItemGroupDiscount (popust skupina-stranke x skupina-artiklov)
       in b2b.CustomerItem (artikel pri stranki: njegova sifra, cena, rok, korak narocanja).
    3. Preslikave za Customers, CustomerItemGroupDiscounts in GetItemCustomerDataV2 na vseh
       SAOP konektorjih — ne na nastetih stirih, ampak na vseh, ki so v registru.
    4. TechnologicalProcess gre v canon.Codebook kot sifrant TECHPROCESS. Nove kode ni treba
       pisati: oblika je ista kot pri valutah in cenikih (sifra, ime, aktivnost), zato ga
       obdela ze obstojeci map.ProcessCodebookInbox.
    5. Braytronov XML dobi slike. Doslej je imel BT_XML samo entiteto Attribute; <photos> se
       niso brale, zato v canon.ProductMedia ni bilo nobene Braytronove slike.
    6. NW_STOCK in BT_STOCK konektor ter pravilo identitete za podjetja 1, 3 in 4 — isti
       razlog in isti vzorec kot 069 za dobaviteljev XML. Dobaviteljeva zaloga ni last enega
       podjetja: NW.* in BA.* artikle imajo vsa stiri (1: 3.148/16, 2: 5.316/410, 3: 5.414/2.375,
       4: 148/62).

  Cesar ta migracija NE naredi in zakaj:

    - Braytronove kategorije. Preslikava sama ne bi naredila nicesar: map.ResolveProductCategories
      dela CROSS JOIN cez drevesa iz map.CategoryPathMap za ta vir, in za BT_XML tam ni nobene
      vrstice. Brez odlocitve, v katero drevo Braytronove druzine sodijo, ne nastane ne vrstica
      v katalogu ne vrstica v delovnem seznamu manjkajocih. To je poslovna odlocitev in je
      zapisana v TASKBOARD.md, ne izmisljena tu.
    - Polja, ki jih preglednica oznacuje kot "ne rabimo": SAOP revizija (RecordInserted*),
      opozorila in blokade v ERP, porocanje SID, preverba VIES, referenti in naslovi za prenos.
      Zajeta ostanejo v raw.Inbox; ce jih kdo kdaj potrebuje, je to vrstica registra in ne
      nov zajem.
*/

SET XACT_ABORT ON;

/* --- 1) stolpci in tabele -------------------------------------------------- */

/* b2b.Customer je doslej imel samo sifro, ime, placnika in cenika. */
IF COL_LENGTH(N'b2b.Customer', N'Address')            IS NULL ALTER TABLE b2b.Customer ADD Address nvarchar(400) NULL;
IF COL_LENGTH(N'b2b.Customer', N'Street')             IS NULL ALTER TABLE b2b.Customer ADD Street nvarchar(400) NULL;
IF COL_LENGTH(N'b2b.Customer', N'HouseNumber')        IS NULL ALTER TABLE b2b.Customer ADD HouseNumber nvarchar(60) NULL;
IF COL_LENGTH(N'b2b.Customer', N'City')               IS NULL ALTER TABLE b2b.Customer ADD City nvarchar(200) NULL;
IF COL_LENGTH(N'b2b.Customer', N'PostalCode')         IS NULL ALTER TABLE b2b.Customer ADD PostalCode nvarchar(40) NULL;
IF COL_LENGTH(N'b2b.Customer', N'Country')            IS NULL ALTER TABLE b2b.Customer ADD Country nvarchar(20) NULL;
IF COL_LENGTH(N'b2b.Customer', N'TaxNumber')          IS NULL ALTER TABLE b2b.Customer ADD TaxNumber nvarchar(40) NULL;
IF COL_LENGTH(N'b2b.Customer', N'RegistrationNumber') IS NULL ALTER TABLE b2b.Customer ADD RegistrationNumber nvarchar(40) NULL;
IF COL_LENGTH(N'b2b.Customer', N'ActivityCode')       IS NULL ALTER TABLE b2b.Customer ADD ActivityCode nvarchar(40) NULL;
IF COL_LENGTH(N'b2b.Customer', N'SubjectToVat')       IS NULL ALTER TABLE b2b.Customer ADD SubjectToVat bit NULL;
IF COL_LENGTH(N'b2b.Customer', N'PaymentDays')        IS NULL ALTER TABLE b2b.Customer ADD PaymentDays int NULL;
IF COL_LENGTH(N'b2b.Customer', N'RebatePercent')      IS NULL ALTER TABLE b2b.Customer ADD RebatePercent decimal(9,4) NULL;
IF COL_LENGTH(N'b2b.Customer', N'IsActive')           IS NULL ALTER TABLE b2b.Customer ADD IsActive bit NULL;
IF COL_LENGTH(N'b2b.Customer', N'CustomerType')       IS NULL ALTER TABLE b2b.Customer ADD CustomerType nvarchar(10) NULL;
IF COL_LENGTH(N'b2b.Customer', N'LegalForm')          IS NULL ALTER TABLE b2b.Customer ADD LegalForm nvarchar(10) NULL;
IF COL_LENGTH(N'b2b.Customer', N'IsDefaulter')        IS NULL ALTER TABLE b2b.Customer ADD IsDefaulter bit NULL;
IF COL_LENGTH(N'b2b.Customer', N'UpfrontPayment')     IS NULL ALTER TABLE b2b.Customer ADD UpfrontPayment bit NULL;
IF COL_LENGTH(N'b2b.Customer', N'LanguageId')         IS NULL ALTER TABLE b2b.Customer ADD LanguageId nvarchar(20) NULL;
IF COL_LENGTH(N'b2b.Customer', N'CurrencyCode')       IS NULL ALTER TABLE b2b.Customer ADD CurrencyCode nvarchar(20) NULL;

/*
  Popust velja za par (skupina strank, skupina artiklov), ne za stranko. SAOP posilja
  CustomerDiscountGroupID, ki je pri nekaterih podjetjih sifra skupine ("B2C"), pri drugih pa
  sifra stranke ("73764256"). Tega tu ne razlocujemo — shranimo, kar vir posilja; kdo je kdo,
  se odloci ob branju, ko bo znano, kako podjetje skupine imenuje.

  ValidFrom je NOT NULL s privzetkom 1900-01-01: kljuc mora biti primerljiv, NULL pa se v MERGE
  ne ujame sam s sabo in bi ista vrstica ob vsakem zajemu nastala znova.
*/
IF OBJECT_ID(N'b2b.CustomerItemGroupDiscount') IS NULL
BEGIN
  CREATE TABLE b2b.CustomerItemGroupDiscount
  (
    CustomerItemGroupDiscountId bigint IDENTITY(1,1) NOT NULL
      CONSTRAINT PK_CustomerItemGroupDiscount PRIMARY KEY,
    OrganizationId int NOT NULL,
    CustomerGroupCode nvarchar(200) NOT NULL,
    ItemGroupCode nvarchar(200) NOT NULL,
    ValidFrom date NOT NULL CONSTRAINT DF_CustomerItemGroupDiscount_ValidFrom DEFAULT('1900-01-01'),
    ValidTo date NULL,
    MinQuantity decimal(19,5) NULL,
    DiscountPercent decimal(9,4) NULL,
    UpdatedUtc datetime2(3) NOT NULL
      CONSTRAINT DF_CustomerItemGroupDiscount_UpdatedUtc DEFAULT SYSUTCDATETIME(),
    CONSTRAINT UQ_CustomerItemGroupDiscount UNIQUE (OrganizationId, CustomerGroupCode, ItemGroupCode, ValidFrom),
    CONSTRAINT FK_CustomerItemGroupDiscount_Organization FOREIGN KEY (OrganizationId)
      REFERENCES dbo.OrganizationConfig(OrganizationId)
  );
END;

/*
  Artikel pri stranki. Kljuc je par (izdelek, stranka); stranka je tu sifra iz SAOP in ne
  tuji kljuc na b2b.Customer, ker se GetItemCustomerDataV2 in Customers zajemata loceno in
  vrstni red ni zajamcen. Ko sta oba zajeta, se povezeta po CustomerKey.
*/
IF OBJECT_ID(N'b2b.CustomerItem') IS NULL
BEGIN
  CREATE TABLE b2b.CustomerItem
  (
    CustomerItemId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_CustomerItem PRIMARY KEY,
    OrganizationId int NOT NULL,
    ProductId bigint NOT NULL,
    CustomerKey nvarchar(200) NOT NULL,
    CustomerName nvarchar(600) NULL,
    CustomerItemCode nvarchar(200) NULL,
    ConvertFactor decimal(19,5) NULL,
    OrderingAllowed bit NULL,
    OrderingCurrencyCode nvarchar(20) NULL,
    OrderingPrice decimal(19,5) NULL,
    OrderingDiscount decimal(9,4) NULL,
    LeadTimeDays int NULL,
    MinimalOrderQuantity decimal(19,3) NULL,
    OrderingMultiplier decimal(19,3) NULL,
    OrderingStep decimal(19,3) NULL,
    UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_CustomerItem_UpdatedUtc DEFAULT SYSUTCDATETIME(),
    CONSTRAINT UQ_CustomerItem UNIQUE (ProductId, CustomerKey),
    CONSTRAINT FK_CustomerItem_Product FOREIGN KEY (ProductId) REFERENCES canon.Product(ProductId),
    CONSTRAINT FK_CustomerItem_Organization FOREIGN KEY (OrganizationId)
      REFERENCES dbo.OrganizationConfig(OrganizationId)
  );
  CREATE INDEX IX_CustomerItem_Customer ON b2b.CustomerItem (OrganizationId, CustomerKey);
END;

/* --- 2) register: kateri svet je katera entiteta ---------------------------- */

IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_EntityMapping_TargetDomain')
  ALTER TABLE map.EntityMapping DROP CONSTRAINT CK_EntityMapping_TargetDomain;

ALTER TABLE map.EntityMapping WITH CHECK
  ADD CONSTRAINT CK_EntityMapping_TargetDomain
  CHECK (TargetDomain IN (N'Product', N'Warehouse', N'Language', N'ProductText',
                          N'ProductAttributePair', N'ProductStockPolicy',
                          N'Codebook', N'ProductStockAccounting', N'ProductPlanning',
                          N'Customer', N'CustomerItem', N'CustomerGroupDiscount'));

/* --- 3) preslikave na vseh SAOP konektorjih --------------------------------- */

/*
  Vrstice nastanejo za vsak SAOP konektor v registru, ne za nastete stiri. Peto podjetje dobi
  isto preslikavo brez nove migracije. Konektorji za zalogo (SAOP_*_STOCK) so izpusceni: ti
  ne hodijo skozi raw.Inbox, ampak skozi stock.*.
*/
DECLARE @SaopKonektorji TABLE (SourceConnectorId int PRIMARY KEY);
INSERT @SaopKonektorji (SourceConnectorId)
SELECT SourceConnectorId FROM map.SourceConnector
WHERE ConnectorType = N'SAOP' AND SourceCode NOT LIKE N'%[_]STOCK';

DECLARE @Entitete TABLE
(
  EntityType nvarchar(200) NOT NULL PRIMARY KEY,
  RecordXPath nvarchar(400) NOT NULL,
  TargetDomain nvarchar(100) NOT NULL,
  CodebookCode nvarchar(50) NULL
);
INSERT @Entitete (EntityType, RecordXPath, TargetDomain, CodebookCode) VALUES
  (N'Customers',                  N'/ArrayOfCustomer/Customer',
   N'Customer', NULL),
  (N'CustomerItemGroupDiscounts', N'/ArrayOfCustomerItemGroupDiscountsComercialTermsV2/CustomerItemGroupDiscountsComercialTermsV2',
   N'CustomerGroupDiscount', NULL),
  (N'GetItemCustomerDataV2',      N'/ArrayOfItemCustomerDataHeader/ItemCustomerDataHeader/ItemCustomersData/ItemCustomerData',
   N'CustomerItem', NULL),
  (N'TechnologicalProcess',       N'/ArrayOfTechnologicalProcessHeader/TechnologicalProcessHeader',
   N'Codebook', N'TECHPROCESS');

MERGE map.EntityMapping AS target
USING
(
  SELECT konektor.SourceConnectorId, entiteta.EntityType, entiteta.RecordXPath,
         entiteta.TargetDomain, entiteta.CodebookCode
  FROM @SaopKonektorji konektor
  CROSS JOIN @Entitete entiteta
) source
  ON target.SourceConnectorId = source.SourceConnectorId AND target.EntityType = source.EntityType
WHEN MATCHED THEN UPDATE SET RecordXPath = source.RecordXPath, TargetDomain = source.TargetDomain,
  CodebookCode = source.CodebookCode, IsActive = 1
WHEN NOT MATCHED THEN INSERT (SourceConnectorId, EntityType, RecordXPath, TargetDomain, CodebookCode, IsActive)
  VALUES (source.SourceConnectorId, source.EntityType, source.RecordXPath, source.TargetDomain,
          source.CodebookCode, 1);

/*
  Polja. Pot je zapisana tako, kot jo posilja vir — preverjeno na zajetih straneh, ne po
  dokumentaciji. Pri artiklu pri stranki je zapis notranji element ItemCustomerData, sifra
  artikla pa je dve ravni visje; ista resitev kot pri kontih zaloge v 082.
*/
DECLARE @Polja TABLE
(
  EntityType nvarchar(200) NOT NULL,
  SourceElement nvarchar(4000) NOT NULL,
  TargetFieldCode nvarchar(400) NOT NULL,
  IsRequired bit NOT NULL,
  PRIMARY KEY (EntityType, TargetFieldCode)
);
INSERT @Polja (EntityType, SourceElement, TargetFieldCode, IsRequired) VALUES
  /* --- stranke --- */
  (N'Customers', N'Code/text()[1]',               N'Customer.CustomerKey',          1),
  (N'Customers', N'Name/text()[1]',               N'Customer.Name',                 0),
  (N'Customers', N'Address/text()[1]',            N'Customer.Address',              0),
  (N'Customers', N'Street/text()[1]',             N'Customer.Street',               0),
  (N'Customers', N'HomeNumber/text()[1]',         N'Customer.HouseNumber',          0),
  (N'Customers', N'City/text()[1]',               N'Customer.City',                 0),
  (N'Customers', N'PostalCode/text()[1]',         N'Customer.PostalCode',           0),
  (N'Customers', N'Country/text()[1]',            N'Customer.Country',              0),
  (N'Customers', N'TaxNumber/text()[1]',          N'Customer.TaxNumber',            0),
  (N'Customers', N'RegistrationNumber/text()[1]', N'Customer.RegistrationNumber',   0),
  (N'Customers', N'ActivityCode/text()[1]',       N'Customer.ActivityCode',         0),
  (N'Customers', N'SubjectToVAT/text()[1]',       N'Customer.SubjectToVat',         0),
  (N'Customers', N'ExpirationDays/text()[1]',     N'Customer.PaymentDays',          0),
  (N'Customers', N'RebatePercent/text()[1]',      N'Customer.RebatePercent',        0),
  (N'Customers', N'CustomerStatus/text()[1]',     N'Customer.IsActive',             0),
  (N'Customers', N'CustomerType/text()[1]',       N'Customer.CustomerType',         0),
  (N'Customers', N'EntityType/text()[1]',         N'Customer.LegalForm',            0),
  (N'Customers', N'Defaulter/text()[1]',          N'Customer.IsDefaulter',          0),
  (N'Customers', N'UpfrontPayment/text()[1]',     N'Customer.UpfrontPayment',       0),
  (N'Customers', N'LanguageID/text()[1]',         N'Customer.LanguageId',           0),
  (N'Customers', N'Currency/text()[1]',           N'Customer.CurrencyCode',         0),
  (N'Customers', N'PriceList/text()[1]',          N'Customer.PriceListCode',        0),
  (N'Customers', N'DiscountGroupID/text()[1]',    N'Customer.DiscountPriceListCode',0),
  (N'Customers', N'CustomerPayerCode/text()[1]',  N'Customer.PayerCode',            0),
  /* --- popust skupina strank x skupina artiklov --- */
  (N'CustomerItemGroupDiscounts', N'CustomerDiscountGroupID/text()[1]', N'GroupDiscount.CustomerGroupCode', 1),
  (N'CustomerItemGroupDiscounts', N'ItemDiscountGroupID/text()[1]',     N'GroupDiscount.ItemGroupCode',     1),
  (N'CustomerItemGroupDiscounts', N'ValidFromDate/text()[1]',           N'GroupDiscount.ValidFrom',         0),
  (N'CustomerItemGroupDiscounts', N'ValidToDate/text()[1]',             N'GroupDiscount.ValidTo',           0),
  (N'CustomerItemGroupDiscounts', N'LimitQTY/text()[1]',                N'GroupDiscount.MinQuantity',       0),
  (N'CustomerItemGroupDiscounts', N'Discount/text()[1]',                N'GroupDiscount.DiscountPercent',   0),
  /* --- artikel pri stranki --- */
  (N'GetItemCustomerDataV2', N'../../ItemID/text()[1]',        N'Record.ItemID',                  1),
  (N'GetItemCustomerDataV2', N'CustomerID/text()[1]',          N'CustomerItem.CustomerKey',       1),
  (N'GetItemCustomerDataV2', N'CustomerName/text()[1]',        N'CustomerItem.CustomerName',      0),
  (N'GetItemCustomerDataV2', N'CustomerItemID/text()[1]',      N'CustomerItem.CustomerItemCode',  0),
  (N'GetItemCustomerDataV2', N'CustomerConvertFactor/text()[1]',N'CustomerItem.ConvertFactor',    0),
  (N'GetItemCustomerDataV2', N'OrderingAllowed/text()[1]',     N'CustomerItem.OrderingAllowed',   0),
  (N'GetItemCustomerDataV2', N'OrderingCurrencyID/text()[1]',  N'CustomerItem.OrderingCurrencyCode', 0),
  (N'GetItemCustomerDataV2', N'OrderingPrice/text()[1]',       N'CustomerItem.OrderingPrice',     0),
  (N'GetItemCustomerDataV2', N'OrderingDiscount/text()[1]',    N'CustomerItem.OrderingDiscount',  0),
  (N'GetItemCustomerDataV2', N'LeadTime/text()[1]',            N'CustomerItem.LeadTimeDays',      0),
  (N'GetItemCustomerDataV2', N'MinimalOrderQty/text()[1]',     N'CustomerItem.MinimalOrderQuantity', 0),
  (N'GetItemCustomerDataV2', N'OrderingMultiplier/text()[1]',  N'CustomerItem.OrderingMultiplier',0),
  (N'GetItemCustomerDataV2', N'OrderingStep/text()[1]',        N'CustomerItem.OrderingStep',      0),
  /* --- tehnoloski proces kot sifrant --- */
  (N'TechnologicalProcess', N'TechProcessID/text()[1]',          N'Codebook.EntryCode', 1),
  (N'TechnologicalProcess', N'TechProcessDescription/text()[1]', N'Codebook.Name',      0),
  (N'TechnologicalProcess', N'Active/text()[1]',                 N'Codebook.IsActive',  0);

MERGE map.FieldMapping AS target
USING
(
  SELECT konektor.SourceConnectorId, polje.EntityType, polje.SourceElement,
         polje.TargetFieldCode, polje.IsRequired
  FROM @SaopKonektorji konektor
  CROSS JOIN @Polja polje
) source
  ON target.SourceConnectorId = source.SourceConnectorId AND target.EntityType = source.EntityType
    AND target.TargetFieldCode = source.TargetFieldCode
WHEN MATCHED THEN UPDATE SET SourceElement = source.SourceElement, IsRequired = source.IsRequired, IsActive = 1
WHEN NOT MATCHED THEN INSERT (SourceConnectorId, EntityType, SourceElement, TargetFieldCode, IsRequired, IsActive)
  VALUES (source.SourceConnectorId, source.EntityType, source.SourceElement, source.TargetFieldCode,
          source.IsRequired, 1);

/* --- 4) Braytron: slike ------------------------------------------------------ */

/*
  BT_XML je imel doslej samo entiteto Attribute. Slike so v datoteki od zacetka
  (<photos><photo><url>), a jih ni bral nihce — v canon.ProductMedia ni bilo nobene
  Braytronove vrstice. Vzamemo prvo sliko, enako kot pri Nowodvorskem: katalog ima danes
  eno sliko na izdelek in vec kot ena nima kam.
*/
DECLARE @BtKonektorji TABLE (SourceConnectorId int PRIMARY KEY);
INSERT @BtKonektorji (SourceConnectorId)
SELECT SourceConnectorId FROM map.SourceConnector WHERE SourceCode = N'BT_XML';

MERGE map.EntityMapping AS target
USING (SELECT SourceConnectorId, N'Media' AS EntityType, N'/response/products/product' AS RecordXPath,
              N'Product' AS TargetDomain FROM @BtKonektorji) source
  ON target.SourceConnectorId = source.SourceConnectorId AND target.EntityType = source.EntityType
WHEN MATCHED THEN UPDATE SET RecordXPath = source.RecordXPath, TargetDomain = source.TargetDomain, IsActive = 1
WHEN NOT MATCHED THEN INSERT (SourceConnectorId, EntityType, RecordXPath, TargetDomain, IsActive)
  VALUES (source.SourceConnectorId, source.EntityType, source.RecordXPath, source.TargetDomain, 1);

MERGE map.FieldMapping AS target
USING
(
  SELECT konektor.SourceConnectorId, N'Media' AS EntityType, polje.SourceElement,
         polje.TargetFieldCode, polje.IsRequired
  FROM @BtKonektorji konektor
  CROSS JOIN (VALUES
    (N'code_ean/text()[1]',             N'Product.EAN',      CONVERT(bit, 1)),
    (N'photos/photo/url/text()[1]',     N'ProductMedia.Url', CONVERT(bit, 0))
  ) AS polje(SourceElement, TargetFieldCode, IsRequired)
) source
  ON target.SourceConnectorId = source.SourceConnectorId AND target.EntityType = source.EntityType
    AND target.TargetFieldCode = source.TargetFieldCode
WHEN MATCHED THEN UPDATE SET SourceElement = source.SourceElement, IsRequired = source.IsRequired, IsActive = 1
WHEN NOT MATCHED THEN INSERT (SourceConnectorId, EntityType, SourceElement, TargetFieldCode, IsRequired, IsActive)
  VALUES (source.SourceConnectorId, source.EntityType, source.SourceElement, source.TargetFieldCode,
          source.IsRequired, 1);

/* --- 5) dobaviteljeva zaloga za vsa podjetja --------------------------------- */

/*
  Isti vzorec kot 069 za dobaviteljev XML: konektor in pravilo identitete se prepiseta s
  podjetja 2, ki je edino imelo oboje. Nic ni napisano na novo — pravilo (predpona NW.
  oziroma BA. z zamenjavo "-" v ".") je bilo dokazano na 2.697 in 1.361 vrsticah.
*/
DECLARE @ZalogaViri TABLE (SourceCode nvarchar(200) PRIMARY KEY);
INSERT @ZalogaViri (SourceCode) VALUES (N'NW_STOCK'), (N'BT_STOCK');

MERGE map.SourceConnector AS target
USING
(
  SELECT vir.SourceCode, podjetje.OrganizationId, izvor.ConnectorType
  FROM @ZalogaViri vir
  CROSS JOIN (SELECT OrganizationId FROM dbo.OrganizationConfig WHERE OrganizationId <> 2) podjetje
  INNER JOIN map.SourceConnector izvor ON izvor.SourceCode = vir.SourceCode AND izvor.OrganizationId = 2
) source
  ON target.SourceCode = source.SourceCode AND target.OrganizationId = source.OrganizationId
WHEN NOT MATCHED THEN INSERT (SourceCode, OrganizationId, ConnectorType, IsActive, CanCreateProducts)
  VALUES (source.SourceCode, source.OrganizationId, source.ConnectorType, 1, 0);

MERGE map.StockIdentityRule AS target
USING
(
  SELECT cilj.SourceConnectorId, pravilo.SourceKeyField, pravilo.Prefix, pravilo.ReplaceOld,
         pravilo.ReplaceNew, pravilo.MatchPriority, pravilo.IsActive
  FROM map.SourceConnector cilj
  INNER JOIN @ZalogaViri vir ON vir.SourceCode = cilj.SourceCode
  INNER JOIN map.SourceConnector izvor ON izvor.SourceCode = cilj.SourceCode AND izvor.OrganizationId = 2
  INNER JOIN map.StockIdentityRule pravilo ON pravilo.SourceConnectorId = izvor.SourceConnectorId
  WHERE cilj.OrganizationId <> 2
) source
  ON target.SourceConnectorId = source.SourceConnectorId AND target.SourceKeyField = source.SourceKeyField
WHEN MATCHED THEN UPDATE SET Prefix = source.Prefix, ReplaceOld = source.ReplaceOld,
  ReplaceNew = source.ReplaceNew, MatchPriority = source.MatchPriority, IsActive = source.IsActive
WHEN NOT MATCHED THEN INSERT (SourceConnectorId, SourceKeyField, Prefix, ReplaceOld, ReplaceNew, MatchPriority, IsActive)
  VALUES (source.SourceConnectorId, source.SourceKeyField, source.Prefix, source.ReplaceOld,
          source.ReplaceNew, source.MatchPriority, source.IsActive);

/* --- 6) postopki ------------------------------------------------------------- */

/*
  Trije novi postopki po istem vzorcu kot 082: stran za stranjo, vsaka v svoji transakciji,
  napaka ene strani je karantena te strani in ne padec zajema. Tehnoloski proces svojega
  postopka nima — je sifrant in ga obdela map.ProcessCodebookInbox.
*/

EXEC(N'
CREATE OR ALTER PROCEDURE map.ProcessCustomerInbox
  @RunId uniqueidentifier,
  @OrganizationId int,
  @SourceCode nvarchar(100)
AS
BEGIN
  /*
    Stranke iz SAOP. Kljuc je sifra stranke znotraj podjetja; ista sifra pri drugem podjetju
    je druga stranka, zato je OrganizationId del kljuca.

    Prazno polje ne prepise izpolnjenega: SAOP posilja prazen niz tam, kjer podatka ni, in
    delni odgovor bi sicer izbrisal ime ali naslov, ki ga je prinesel prejsnji zajem.
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
          AND entityMapping.TargetDomain=''Customer''
      )
    ORDER BY inbox.InboxId;

  OPEN zajem_cursor;
  FETCH NEXT FROM zajem_cursor INTO @InboxId;
  WHILE @@FETCH_STATUS=0
  BEGIN
    BEGIN TRY
      BEGIN TRANSACTION;

      IF OBJECT_ID(''tempdb..#Stranka'') IS NOT NULL DROP TABLE #Stranka;

      SELECT
        LTRIM(RTRIM(zapis.CustomerKey)) AS CustomerKey,
        zapis.RecordOrdinal,
        NULLIF(LTRIM(RTRIM(zapis.Name)),'''')               AS Name,
        NULLIF(LTRIM(RTRIM(zapis.Address)),'''')            AS Address,
        NULLIF(LTRIM(RTRIM(zapis.Street)),'''')             AS Street,
        NULLIF(LTRIM(RTRIM(zapis.HouseNumber)),'''')        AS HouseNumber,
        NULLIF(LTRIM(RTRIM(zapis.City)),'''')               AS City,
        NULLIF(LTRIM(RTRIM(zapis.PostalCode)),'''')         AS PostalCode,
        NULLIF(LTRIM(RTRIM(zapis.Country)),'''')            AS Country,
        NULLIF(LTRIM(RTRIM(zapis.TaxNumber)),'''')          AS TaxNumber,
        NULLIF(LTRIM(RTRIM(zapis.RegistrationNumber)),'''') AS RegistrationNumber,
        NULLIF(LTRIM(RTRIM(zapis.ActivityCode)),'''')       AS ActivityCode,
        NULLIF(LTRIM(RTRIM(zapis.CustomerType)),'''')       AS CustomerType,
        NULLIF(LTRIM(RTRIM(zapis.LegalForm)),'''')          AS LegalForm,
        NULLIF(LTRIM(RTRIM(zapis.LanguageId)),'''')         AS LanguageId,
        NULLIF(LTRIM(RTRIM(zapis.CurrencyCode)),'''')       AS CurrencyCode,
        NULLIF(LTRIM(RTRIM(zapis.PriceListCode)),'''')      AS PriceListCode,
        NULLIF(LTRIM(RTRIM(zapis.DiscountPriceListCode)),'''') AS DiscountPriceListCode,
        NULLIF(LTRIM(RTRIM(zapis.PayerCode)),'''')          AS PayerCode,
        TRY_CONVERT(int, LTRIM(RTRIM(zapis.PaymentDays)))              AS PaymentDays,
        TRY_CONVERT(decimal(9,4), LTRIM(RTRIM(zapis.RebatePercent)))   AS RebatePercent,
        CASE WHEN LOWER(LTRIM(RTRIM(ISNULL(zapis.SubjectToVat,''''))))   IN (''true'',''1'') THEN 1
             WHEN LOWER(LTRIM(RTRIM(ISNULL(zapis.SubjectToVat,''''))))   IN (''false'',''0'') THEN 0 END AS SubjectToVat,
        CASE WHEN LOWER(LTRIM(RTRIM(ISNULL(zapis.IsActive,''''))))       IN (''true'',''1'') THEN 1
             WHEN LOWER(LTRIM(RTRIM(ISNULL(zapis.IsActive,''''))))       IN (''false'',''0'') THEN 0 END AS IsActive,
        CASE WHEN LOWER(LTRIM(RTRIM(ISNULL(zapis.IsDefaulter,''''))))    IN (''true'',''1'') THEN 1
             WHEN LOWER(LTRIM(RTRIM(ISNULL(zapis.IsDefaulter,''''))))    IN (''false'',''0'') THEN 0 END AS IsDefaulter,
        CASE WHEN LOWER(LTRIM(RTRIM(ISNULL(zapis.UpfrontPayment,'''')))) IN (''true'',''1'') THEN 1
             WHEN LOWER(LTRIM(RTRIM(ISNULL(zapis.UpfrontPayment,'''')))) IN (''false'',''0'') THEN 0 END AS UpfrontPayment
      INTO #Stranka
      FROM
      (
        SELECT value.RecordOrdinal,
          MAX(CASE WHEN value.TargetFieldCode=''Customer.CustomerKey''          THEN CONVERT(nvarchar(200),value.Value) END) AS CustomerKey,
          MAX(CASE WHEN value.TargetFieldCode=''Customer.Name''                 THEN CONVERT(nvarchar(600),value.Value) END) AS Name,
          MAX(CASE WHEN value.TargetFieldCode=''Customer.Address''              THEN CONVERT(nvarchar(400),value.Value) END) AS Address,
          MAX(CASE WHEN value.TargetFieldCode=''Customer.Street''               THEN CONVERT(nvarchar(400),value.Value) END) AS Street,
          MAX(CASE WHEN value.TargetFieldCode=''Customer.HouseNumber''          THEN CONVERT(nvarchar(60),value.Value)  END) AS HouseNumber,
          MAX(CASE WHEN value.TargetFieldCode=''Customer.City''                 THEN CONVERT(nvarchar(200),value.Value) END) AS City,
          MAX(CASE WHEN value.TargetFieldCode=''Customer.PostalCode''           THEN CONVERT(nvarchar(40),value.Value)  END) AS PostalCode,
          MAX(CASE WHEN value.TargetFieldCode=''Customer.Country''              THEN CONVERT(nvarchar(20),value.Value)  END) AS Country,
          MAX(CASE WHEN value.TargetFieldCode=''Customer.TaxNumber''            THEN CONVERT(nvarchar(40),value.Value)  END) AS TaxNumber,
          MAX(CASE WHEN value.TargetFieldCode=''Customer.RegistrationNumber''   THEN CONVERT(nvarchar(40),value.Value)  END) AS RegistrationNumber,
          MAX(CASE WHEN value.TargetFieldCode=''Customer.ActivityCode''         THEN CONVERT(nvarchar(40),value.Value)  END) AS ActivityCode,
          MAX(CASE WHEN value.TargetFieldCode=''Customer.CustomerType''         THEN CONVERT(nvarchar(10),value.Value)  END) AS CustomerType,
          MAX(CASE WHEN value.TargetFieldCode=''Customer.LegalForm''            THEN CONVERT(nvarchar(10),value.Value)  END) AS LegalForm,
          MAX(CASE WHEN value.TargetFieldCode=''Customer.LanguageId''           THEN CONVERT(nvarchar(20),value.Value)  END) AS LanguageId,
          MAX(CASE WHEN value.TargetFieldCode=''Customer.CurrencyCode''         THEN CONVERT(nvarchar(20),value.Value)  END) AS CurrencyCode,
          MAX(CASE WHEN value.TargetFieldCode=''Customer.PriceListCode''        THEN CONVERT(nvarchar(200),value.Value) END) AS PriceListCode,
          MAX(CASE WHEN value.TargetFieldCode=''Customer.DiscountPriceListCode''THEN CONVERT(nvarchar(200),value.Value) END) AS DiscountPriceListCode,
          MAX(CASE WHEN value.TargetFieldCode=''Customer.PayerCode''            THEN CONVERT(nvarchar(200),value.Value) END) AS PayerCode,
          MAX(CASE WHEN value.TargetFieldCode=''Customer.PaymentDays''          THEN CONVERT(nvarchar(40),value.Value)  END) AS PaymentDays,
          MAX(CASE WHEN value.TargetFieldCode=''Customer.RebatePercent''        THEN CONVERT(nvarchar(40),value.Value)  END) AS RebatePercent,
          MAX(CASE WHEN value.TargetFieldCode=''Customer.SubjectToVat''         THEN CONVERT(nvarchar(20),value.Value)  END) AS SubjectToVat,
          MAX(CASE WHEN value.TargetFieldCode=''Customer.IsActive''             THEN CONVERT(nvarchar(20),value.Value)  END) AS IsActive,
          MAX(CASE WHEN value.TargetFieldCode=''Customer.IsDefaulter''          THEN CONVERT(nvarchar(20),value.Value)  END) AS IsDefaulter,
          MAX(CASE WHEN value.TargetFieldCode=''Customer.UpfrontPayment''       THEN CONVERT(nvarchar(20),value.Value)  END) AS UpfrontPayment
        FROM map.ExtractedValue value
        WHERE value.InboxId=@InboxId
          AND EXISTS(SELECT 1 FROM map.FieldMapping mapping
                     WHERE mapping.FieldMappingId=value.FieldMappingId AND mapping.IsActive=1)
        GROUP BY value.RecordOrdinal
      ) zapis
      WHERE NULLIF(LTRIM(RTRIM(zapis.CustomerKey)),'''') IS NOT NULL;

      /* Ista sifra dvakrat na isti strani: zmaga zadnji zapis, enako kot pri izdelkih. */
      MERGE b2b.Customer AS target
      USING
      (
        SELECT stranka.*
        FROM #Stranka stranka
        INNER JOIN
        (
          SELECT CustomerKey, MAX(RecordOrdinal) AS RecordOrdinal
          FROM #Stranka GROUP BY CustomerKey
        ) zadnji ON zadnji.CustomerKey=stranka.CustomerKey AND zadnji.RecordOrdinal=stranka.RecordOrdinal
      ) source
        ON target.OrganizationId=@OrganizationId AND target.CustomerKey=source.CustomerKey
      WHEN MATCHED THEN UPDATE SET
        Name=ISNULL(source.Name,target.Name),
        Address=ISNULL(source.Address,target.Address),
        Street=ISNULL(source.Street,target.Street),
        HouseNumber=ISNULL(source.HouseNumber,target.HouseNumber),
        City=ISNULL(source.City,target.City),
        PostalCode=ISNULL(source.PostalCode,target.PostalCode),
        Country=ISNULL(source.Country,target.Country),
        TaxNumber=ISNULL(source.TaxNumber,target.TaxNumber),
        RegistrationNumber=ISNULL(source.RegistrationNumber,target.RegistrationNumber),
        ActivityCode=ISNULL(source.ActivityCode,target.ActivityCode),
        CustomerType=ISNULL(source.CustomerType,target.CustomerType),
        LegalForm=ISNULL(source.LegalForm,target.LegalForm),
        LanguageId=ISNULL(source.LanguageId,target.LanguageId),
        CurrencyCode=ISNULL(source.CurrencyCode,target.CurrencyCode),
        PriceListCode=ISNULL(source.PriceListCode,target.PriceListCode),
        DiscountPriceListCode=ISNULL(source.DiscountPriceListCode,target.DiscountPriceListCode),
        PayerCode=ISNULL(source.PayerCode,target.PayerCode),
        PaymentDays=ISNULL(source.PaymentDays,target.PaymentDays),
        RebatePercent=ISNULL(source.RebatePercent,target.RebatePercent),
        SubjectToVat=ISNULL(source.SubjectToVat,target.SubjectToVat),
        IsActive=ISNULL(source.IsActive,target.IsActive),
        IsDefaulter=ISNULL(source.IsDefaulter,target.IsDefaulter),
        UpfrontPayment=ISNULL(source.UpfrontPayment,target.UpfrontPayment),
        SourceInboxId=@InboxId, SourceRecordOrdinal=source.RecordOrdinal, UpdatedUtc=SYSUTCDATETIME()
      WHEN NOT MATCHED THEN INSERT
        (OrganizationId, CustomerKey, Name, Address, Street, HouseNumber, City, PostalCode, Country,
         TaxNumber, RegistrationNumber, ActivityCode, CustomerType, LegalForm, LanguageId, CurrencyCode,
         PriceListCode, DiscountPriceListCode, PayerCode, PaymentDays, RebatePercent, SubjectToVat,
         IsActive, IsDefaulter, UpfrontPayment, SourceInboxId, SourceRecordOrdinal)
        VALUES
        (@OrganizationId, source.CustomerKey, ISNULL(source.Name, source.CustomerKey), source.Address,
         source.Street, source.HouseNumber, source.City, source.PostalCode, source.Country,
         source.TaxNumber, source.RegistrationNumber, source.ActivityCode, source.CustomerType,
         source.LegalForm, source.LanguageId, source.CurrencyCode, source.PriceListCode,
         source.DiscountPriceListCode, source.PayerCode, source.PaymentDays, source.RebatePercent,
         source.SubjectToVat, source.IsActive, source.IsDefaulter, source.UpfrontPayment,
         @InboxId, source.RecordOrdinal);

      DECLARE @Zapisov int = (SELECT COUNT(DISTINCT value.RecordOrdinal) FROM map.ExtractedValue value WHERE value.InboxId=@InboxId);
      DECLARE @Uporabljenih int = (SELECT COUNT(*) FROM #Stranka);

      UPDATE raw.Inbox
      SET Status=''Processed'', ProcessedUtc=SYSUTCDATETIME(),
          FailureReason=CASE WHEN @Uporabljenih=@Zapisov THEN NULL
            ELSE CONCAT(''Uporabljenih: '', @Uporabljenih, '' od '', @Zapisov, ''. Vrstice brez sifre stranke se ne shranijo.'') END
      WHERE InboxId=@InboxId;

      DROP TABLE #Stranka;
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

EXEC(N'
CREATE OR ALTER PROCEDURE map.ProcessCustomerGroupDiscountInbox
  @RunId uniqueidentifier,
  @OrganizationId int,
  @SourceCode nvarchar(100)
AS
BEGIN
  /*
    Popust za par (skupina strank, skupina artiklov). Ni vezan na izdelek in ne na stranko,
    zato ne potrebuje ne canon.Product ne b2b.Customer in se sme zajeti pred njima.

    ValidFrom je del kljuca: isti par ima lahko vec obdobij. Prazen datum postane 1900-01-01,
    da se kljuc ujame sam s sabo.
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
          AND entityMapping.TargetDomain=''CustomerGroupDiscount''
      )
    ORDER BY inbox.InboxId;

  OPEN zajem_cursor;
  FETCH NEXT FROM zajem_cursor INTO @InboxId;
  WHILE @@FETCH_STATUS=0
  BEGIN
    BEGIN TRY
      BEGIN TRANSACTION;

      IF OBJECT_ID(''tempdb..#Popust'') IS NOT NULL DROP TABLE #Popust;

      SELECT
        LTRIM(RTRIM(zapis.CustomerGroupCode)) AS CustomerGroupCode,
        LTRIM(RTRIM(zapis.ItemGroupCode))     AS ItemGroupCode,
        ISNULL(TRY_CONVERT(date, LTRIM(RTRIM(zapis.ValidFrom)), 126), ''1900-01-01'') AS ValidFrom,
        TRY_CONVERT(date, LTRIM(RTRIM(zapis.ValidTo)), 126)          AS ValidTo,
        TRY_CONVERT(decimal(19,5), LTRIM(RTRIM(zapis.MinQuantity)))  AS MinQuantity,
        TRY_CONVERT(decimal(9,4), LTRIM(RTRIM(zapis.DiscountPercent))) AS DiscountPercent
      INTO #Popust
      FROM
      (
        SELECT value.RecordOrdinal,
          MAX(CASE WHEN value.TargetFieldCode=''GroupDiscount.CustomerGroupCode'' THEN CONVERT(nvarchar(200),value.Value) END) AS CustomerGroupCode,
          MAX(CASE WHEN value.TargetFieldCode=''GroupDiscount.ItemGroupCode''     THEN CONVERT(nvarchar(200),value.Value) END) AS ItemGroupCode,
          MAX(CASE WHEN value.TargetFieldCode=''GroupDiscount.ValidFrom''         THEN CONVERT(nvarchar(60),value.Value)  END) AS ValidFrom,
          MAX(CASE WHEN value.TargetFieldCode=''GroupDiscount.ValidTo''           THEN CONVERT(nvarchar(60),value.Value)  END) AS ValidTo,
          MAX(CASE WHEN value.TargetFieldCode=''GroupDiscount.MinQuantity''       THEN CONVERT(nvarchar(60),value.Value)  END) AS MinQuantity,
          MAX(CASE WHEN value.TargetFieldCode=''GroupDiscount.DiscountPercent''   THEN CONVERT(nvarchar(60),value.Value)  END) AS DiscountPercent
        FROM map.ExtractedValue value
        WHERE value.InboxId=@InboxId
          AND EXISTS(SELECT 1 FROM map.FieldMapping mapping
                     WHERE mapping.FieldMappingId=value.FieldMappingId AND mapping.IsActive=1)
        GROUP BY value.RecordOrdinal
      ) zapis
      WHERE NULLIF(LTRIM(RTRIM(zapis.CustomerGroupCode)),'''') IS NOT NULL
        AND NULLIF(LTRIM(RTRIM(zapis.ItemGroupCode)),'''') IS NOT NULL;

      MERGE b2b.CustomerItemGroupDiscount AS target
      USING
      (
        SELECT CustomerGroupCode, ItemGroupCode, ValidFrom,
               MAX(ValidTo) AS ValidTo, MAX(MinQuantity) AS MinQuantity, MAX(DiscountPercent) AS DiscountPercent
        FROM #Popust GROUP BY CustomerGroupCode, ItemGroupCode, ValidFrom
      ) source
        ON target.OrganizationId=@OrganizationId AND target.CustomerGroupCode=source.CustomerGroupCode
          AND target.ItemGroupCode=source.ItemGroupCode AND target.ValidFrom=source.ValidFrom
      WHEN MATCHED THEN UPDATE SET ValidTo=source.ValidTo, MinQuantity=source.MinQuantity,
        DiscountPercent=source.DiscountPercent, UpdatedUtc=SYSUTCDATETIME()
      WHEN NOT MATCHED THEN INSERT
        (OrganizationId, CustomerGroupCode, ItemGroupCode, ValidFrom, ValidTo, MinQuantity, DiscountPercent)
        VALUES (@OrganizationId, source.CustomerGroupCode, source.ItemGroupCode, source.ValidFrom,
                source.ValidTo, source.MinQuantity, source.DiscountPercent);

      DECLARE @Zapisov int = (SELECT COUNT(DISTINCT value.RecordOrdinal) FROM map.ExtractedValue value WHERE value.InboxId=@InboxId);
      DECLARE @Uporabljenih int = (SELECT COUNT(*) FROM #Popust);

      UPDATE raw.Inbox
      SET Status=''Processed'', ProcessedUtc=SYSUTCDATETIME(),
          FailureReason=CASE WHEN @Uporabljenih=@Zapisov THEN NULL
            ELSE CONCAT(''Uporabljenih: '', @Uporabljenih, '' od '', @Zapisov, ''. Vrstice brez obeh skupin se ne shranijo.'') END
      WHERE InboxId=@InboxId;

      DROP TABLE #Popust;
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

EXEC(N'
CREATE OR ALTER PROCEDURE map.ProcessCustomerItemInbox
  @RunId uniqueidentifier,
  @OrganizationId int,
  @SourceCode nvarchar(100)
AS
BEGIN
  /*
    Artikel pri stranki: njena sifra za nas artikel, njena cena, popust, rok in korak narocanja.
    Zapis je notranji element ItemCustomerData, sifra artikla pa dve ravni visje — zato
    ../../ItemID v registru, enako kot pri kontih zaloge.

    Zapis brez artikla v katalogu se preskoci in ostane viden v FailureReason. Dobaviteljevo
    pravilo velja tudi tu: ta vir artikla ne ustvarja.
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
          AND entityMapping.TargetDomain=''CustomerItem''
      )
    ORDER BY inbox.InboxId;

  OPEN zajem_cursor;
  FETCH NEXT FROM zajem_cursor INTO @InboxId;
  WHILE @@FETCH_STATUS=0
  BEGIN
    BEGIN TRY
      BEGIN TRANSACTION;

      IF OBJECT_ID(''tempdb..#ArtikelStranke'') IS NOT NULL DROP TABLE #ArtikelStranke;

      SELECT
        izdelek.ProductId,
        LTRIM(RTRIM(zapis.CustomerKey)) AS CustomerKey,
        NULLIF(LTRIM(RTRIM(zapis.CustomerName)),'''')     AS CustomerName,
        NULLIF(LTRIM(RTRIM(zapis.CustomerItemCode)),'''') AS CustomerItemCode,
        NULLIF(LTRIM(RTRIM(zapis.OrderingCurrencyCode)),'''') AS OrderingCurrencyCode,
        TRY_CONVERT(decimal(19,5), LTRIM(RTRIM(zapis.ConvertFactor)))        AS ConvertFactor,
        TRY_CONVERT(decimal(19,5), LTRIM(RTRIM(zapis.OrderingPrice)))        AS OrderingPrice,
        TRY_CONVERT(decimal(9,4),  LTRIM(RTRIM(zapis.OrderingDiscount)))     AS OrderingDiscount,
        TRY_CONVERT(int,           LTRIM(RTRIM(zapis.LeadTimeDays)))         AS LeadTimeDays,
        TRY_CONVERT(decimal(19,3), LTRIM(RTRIM(zapis.MinimalOrderQuantity))) AS MinimalOrderQuantity,
        TRY_CONVERT(decimal(19,3), LTRIM(RTRIM(zapis.OrderingMultiplier)))   AS OrderingMultiplier,
        TRY_CONVERT(decimal(19,3), LTRIM(RTRIM(zapis.OrderingStep)))         AS OrderingStep,
        CASE WHEN LOWER(LTRIM(RTRIM(ISNULL(zapis.OrderingAllowed,'''')))) IN (''true'',''1'') THEN 1
             WHEN LOWER(LTRIM(RTRIM(ISNULL(zapis.OrderingAllowed,'''')))) IN (''false'',''0'') THEN 0 END AS OrderingAllowed
      INTO #ArtikelStranke
      FROM
      (
        SELECT value.RecordOrdinal,
          MAX(CASE WHEN value.TargetFieldCode=''Record.ItemID''                    THEN CONVERT(nvarchar(100),value.Value) END) AS ItemID,
          MAX(CASE WHEN value.TargetFieldCode=''CustomerItem.CustomerKey''         THEN CONVERT(nvarchar(200),value.Value) END) AS CustomerKey,
          MAX(CASE WHEN value.TargetFieldCode=''CustomerItem.CustomerName''        THEN CONVERT(nvarchar(600),value.Value) END) AS CustomerName,
          MAX(CASE WHEN value.TargetFieldCode=''CustomerItem.CustomerItemCode''    THEN CONVERT(nvarchar(200),value.Value) END) AS CustomerItemCode,
          MAX(CASE WHEN value.TargetFieldCode=''CustomerItem.ConvertFactor''       THEN CONVERT(nvarchar(60),value.Value)  END) AS ConvertFactor,
          MAX(CASE WHEN value.TargetFieldCode=''CustomerItem.OrderingAllowed''     THEN CONVERT(nvarchar(20),value.Value)  END) AS OrderingAllowed,
          MAX(CASE WHEN value.TargetFieldCode=''CustomerItem.OrderingCurrencyCode''THEN CONVERT(nvarchar(20),value.Value)  END) AS OrderingCurrencyCode,
          MAX(CASE WHEN value.TargetFieldCode=''CustomerItem.OrderingPrice''       THEN CONVERT(nvarchar(60),value.Value)  END) AS OrderingPrice,
          MAX(CASE WHEN value.TargetFieldCode=''CustomerItem.OrderingDiscount''    THEN CONVERT(nvarchar(60),value.Value)  END) AS OrderingDiscount,
          MAX(CASE WHEN value.TargetFieldCode=''CustomerItem.LeadTimeDays''        THEN CONVERT(nvarchar(60),value.Value)  END) AS LeadTimeDays,
          MAX(CASE WHEN value.TargetFieldCode=''CustomerItem.MinimalOrderQuantity''THEN CONVERT(nvarchar(60),value.Value)  END) AS MinimalOrderQuantity,
          MAX(CASE WHEN value.TargetFieldCode=''CustomerItem.OrderingMultiplier''  THEN CONVERT(nvarchar(60),value.Value)  END) AS OrderingMultiplier,
          MAX(CASE WHEN value.TargetFieldCode=''CustomerItem.OrderingStep''        THEN CONVERT(nvarchar(60),value.Value)  END) AS OrderingStep
        FROM map.ExtractedValue value
        WHERE value.InboxId=@InboxId
          AND EXISTS(SELECT 1 FROM map.FieldMapping mapping
                     WHERE mapping.FieldMappingId=value.FieldMappingId AND mapping.IsActive=1)
        GROUP BY value.RecordOrdinal
      ) zapis
      INNER JOIN canon.Product izdelek
        ON izdelek.OrganizationId=@OrganizationId AND izdelek.ItemID=LTRIM(RTRIM(zapis.ItemID))
      WHERE NULLIF(LTRIM(RTRIM(zapis.CustomerKey)),'''') IS NOT NULL;

      MERGE b2b.CustomerItem AS target
      USING
      (
        SELECT ProductId, CustomerKey,
               MAX(CustomerName) AS CustomerName, MAX(CustomerItemCode) AS CustomerItemCode,
               MAX(ConvertFactor) AS ConvertFactor, MAX(OrderingAllowed) AS OrderingAllowed,
               MAX(OrderingCurrencyCode) AS OrderingCurrencyCode, MAX(OrderingPrice) AS OrderingPrice,
               MAX(OrderingDiscount) AS OrderingDiscount, MAX(LeadTimeDays) AS LeadTimeDays,
               MAX(MinimalOrderQuantity) AS MinimalOrderQuantity, MAX(OrderingMultiplier) AS OrderingMultiplier,
               MAX(OrderingStep) AS OrderingStep
        FROM #ArtikelStranke GROUP BY ProductId, CustomerKey
      ) source
        ON target.ProductId=source.ProductId AND target.CustomerKey=source.CustomerKey
      WHEN MATCHED THEN UPDATE SET
        CustomerName=ISNULL(source.CustomerName,target.CustomerName),
        CustomerItemCode=ISNULL(source.CustomerItemCode,target.CustomerItemCode),
        ConvertFactor=source.ConvertFactor, OrderingAllowed=source.OrderingAllowed,
        OrderingCurrencyCode=source.OrderingCurrencyCode, OrderingPrice=source.OrderingPrice,
        OrderingDiscount=source.OrderingDiscount, LeadTimeDays=source.LeadTimeDays,
        MinimalOrderQuantity=source.MinimalOrderQuantity, OrderingMultiplier=source.OrderingMultiplier,
        OrderingStep=source.OrderingStep, UpdatedUtc=SYSUTCDATETIME()
      WHEN NOT MATCHED THEN INSERT
        (OrganizationId, ProductId, CustomerKey, CustomerName, CustomerItemCode, ConvertFactor,
         OrderingAllowed, OrderingCurrencyCode, OrderingPrice, OrderingDiscount, LeadTimeDays,
         MinimalOrderQuantity, OrderingMultiplier, OrderingStep)
        VALUES
        (@OrganizationId, source.ProductId, source.CustomerKey, source.CustomerName, source.CustomerItemCode,
         source.ConvertFactor, source.OrderingAllowed, source.OrderingCurrencyCode, source.OrderingPrice,
         source.OrderingDiscount, source.LeadTimeDays, source.MinimalOrderQuantity,
         source.OrderingMultiplier, source.OrderingStep);

      DECLARE @Zapisov int = (SELECT COUNT(DISTINCT value.RecordOrdinal) FROM map.ExtractedValue value WHERE value.InboxId=@InboxId);
      DECLARE @Uporabljenih int = (SELECT COUNT(*) FROM #ArtikelStranke);

      UPDATE raw.Inbox
      SET Status=''Processed'', ProcessedUtc=SYSUTCDATETIME(),
          FailureReason=CASE WHEN @Uporabljenih=@Zapisov THEN NULL
            ELSE CONCAT(''Uporabljenih: '', @Uporabljenih, '' od '', @Zapisov, ''. Zapisi brez artikla v katalogu se ne shranijo.'') END
      WHERE InboxId=@InboxId;

      DROP TABLE #ArtikelStranke;
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

/* --- 7) dokaz ---------------------------------------------------------------- */

/*
  Vsak SAOP konektor mora imeti vseh sestnajst bralnih koncnih tock v registru. To je edina
  preverba, ki bi ujela napako, zaradi katere je bila ta migracija potrebna: entiteta se je
  zajemala, cilja pa ni imela, in nihce tega ni videl, dokler ni nekdo prestel vrstic v canon.
*/
IF EXISTS
(
  SELECT 1
  FROM map.SourceConnector connector
  WHERE connector.ConnectorType = N'SAOP' AND connector.SourceCode NOT LIKE N'%[_]STOCK'
    AND (SELECT COUNT(*) FROM map.EntityMapping entityMapping
         WHERE entityMapping.SourceConnectorId = connector.SourceConnectorId AND entityMapping.IsActive = 1) < 16
)
  THROW 51087, N'087: vsaj en SAOP konektor nima vseh 16 koncnih tock v registru.', 1;

IF EXISTS (SELECT 1 FROM map.EntityMapping WHERE TargetDomain = N'Codebook' AND CodebookCode IS NULL)
  THROW 51087, N'087: sifrant brez oznake, kateri sifrant je.', 1;

IF OBJECT_ID(N'map.ProcessCustomerInbox') IS NULL
  OR OBJECT_ID(N'map.ProcessCustomerGroupDiscountInbox') IS NULL
  OR OBJECT_ID(N'map.ProcessCustomerItemInbox') IS NULL
  THROW 51087, N'087: manjka eden od novih postopkov.', 1;

/* Braytron: slike na vseh konektorjih tega vira. */
IF EXISTS
(
  SELECT 1 FROM map.SourceConnector connector
  WHERE connector.SourceCode = N'BT_XML'
    AND NOT EXISTS (SELECT 1 FROM map.EntityMapping entityMapping
                    WHERE entityMapping.SourceConnectorId = connector.SourceConnectorId
                      AND entityMapping.EntityType = N'Media' AND entityMapping.IsActive = 1)
)
  THROW 51087, N'087: Braytronov konektor brez entitete Media.', 1;

/* Dobaviteljeva zaloga: konektor in pravilo identitete za vsako podjetje. */
IF EXISTS
(
  SELECT 1
  FROM dbo.OrganizationConfig organization
  CROSS JOIN (VALUES (N'NW_STOCK'), (N'BT_STOCK')) AS vir(SourceCode)
  WHERE NOT EXISTS (SELECT 1 FROM map.SourceConnector connector
                    WHERE connector.SourceCode = vir.SourceCode
                      AND connector.OrganizationId = organization.OrganizationId
                      AND connector.IsActive = 1)
)
  THROW 51087, N'087: dobaviteljeva zaloga nima konektorja pri vseh podjetjih.', 1;

IF EXISTS
(
  SELECT 1
  FROM map.SourceConnector connector
  WHERE connector.SourceCode IN (N'NW_STOCK', N'BT_STOCK')
    AND NOT EXISTS (SELECT 1 FROM map.StockIdentityRule pravilo
                    WHERE pravilo.SourceConnectorId = connector.SourceConnectorId AND pravilo.IsActive = 1)
)
  THROW 51087, N'087: konektor dobaviteljeve zaloge brez pravila identitete.', 1;
