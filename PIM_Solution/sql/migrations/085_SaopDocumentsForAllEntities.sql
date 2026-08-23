/*
  085 — posplositev pogodbe XML z izdelkov na vse entitete, ki jih SAOP zna sprejeti:
  izdelki, stranke, ceniki in cene.

  Zakaj: migracija 081 je pogodbo zapisala za izdelke, a jo je oblikovala tako, da velja samo
  zanje — koren dokumenta, gnezdenje in poti so bili v kodi gradnika. SAOP pa ima za vsako
  entiteto svojo obliko:

    izdelki  <ItemsGeneralData><ItemGeneralData>...  POST api/Item/AddItemsGeneralData
                                                     PATCH api/Item/UpdateItemsGeneralData
    stranke  <Customer> ... </Customer>              POST  api/Customers/AddCustomer
             <CustomerV2> ... </CustomerV2>          PATCH api/V2/Customers/UpdateCustomer
    ceniki   <PriceList> ... </PriceList>            POST  api/pricelists/AddPriceLists
                                                     POST  api/pricelists/ModifyPriceLists
    cene     <ItemPrice> ... </ItemPrice>            POST  api/Price/AddPrices
                                                     POST  api/V2/Price/ModifyPricesV2

  Izdelki so edini z gnezdenim ovojem; ostale tri so ploski dokumenti. Ceniki in cene so edini,
  ki tudi za spremembo uporabljajo POST in ne PATCH. Nic od tega ni ugibano: oblika strank je
  prepisana iz resnicnega dokumenta, ki ga je SAOP razclenil in mu ocital napako po posameznem
  polju (pim.SaopCustomerOutboundQueue v PIM_test), poti in tipi teles pa iz swaggerja
  SAOP_API_swagger_v2.json in iz lista 'Stranke', 'Cene' in 'Ceniki' preglednice
  Mapiranje_SAOP_API_PIM.xlsx.

  ------------------------------------------------------------------------------------------
  KAJ JE TREBA POVEDATI NARAVNOST O CENAH IN CENIKIH

  V preglednici, ki je vir celotnega modela lastnistva (migracija 068), ima na listu 'Cene'
  vseh 18 polj smer 'SAOP -> PIM' ali 'samo RAW', na listu 'Ceniki' pa vseh 13. Master je
  povsod SAOP. Z drugimi besedami: po sprejeti preslikavi PIM cen in cenikov NE pise.

  Ta migracija zato za cene in cenike zapise OBLIKO dokumenta in poti — mehanizem je s tem
  celovit in deluje za vse stiri entitete — ne podeli pa nobene pravice do pisanja. Dokler
  vrstice v out.OwnershipPolicy z Owner='PIM' ni, out.EnqueueMessage vsako tako spremembo
  zavrne z 51010 in nic ne more oditi. To je odlocitev uporabnika, ne tehnicna, in je enako
  ravnanje, kot ga je za stranke izbrala migracija 068.

  Enako velja za stranke, a iz drugega razloga: pisljivih polj je po preglednici deset,
  b2b.Customer pa ima danes 0 vrstic in hrani stiri polja. Pravilo O9 (kar ne beremo nazaj,
  ne smemo pisati) zato dovoli natanko eno: naziv stranke.
  ------------------------------------------------------------------------------------------

  Migrator ne pozna locila GO; procedure so v EXEC(N'...').
*/

SET XACT_ABORT ON;

/* --- 1) Oblika dokumenta na entiteto ------------------------------------ */

IF OBJECT_ID(N'out.SaopDocument', N'U') IS NULL
BEGIN
  CREATE TABLE out.SaopDocument
  (
    TargetKind nvarchar(100) NOT NULL CONSTRAINT PK_SaopDocument PRIMARY KEY,
    EntityType nvarchar(100) NOT NULL,
    /* Koren se pri strankah med ustvarjanjem in spremembo razlikuje (Customer / CustomerV2). */
    RootElementAdd nvarchar(100) NOT NULL,
    RootElementUpdate nvarchar(100) NOT NULL,
    /* Gnezdeni ovoj pod korenom; NULL pomeni plosk dokument. Samo izdelki ga imajo. */
    ItemElement nvarchar(100) NULL,
    /* Elementi naravnega kljuca, loceni z '|'. Vrednosti se vzamejo iz EntityKey po istem locilu. */
    KeyElements nvarchar(400) NOT NULL,
    AddPath nvarchar(400) NOT NULL,
    AddOperation nvarchar(10) NOT NULL,
    UpdatePath nvarchar(400) NOT NULL,
    UpdateOperation nvarchar(10) NOT NULL,
    /* Casovni zig; NULL pomeni, da ga ta entiteta nima. */
    StampAddElement nvarchar(100) NULL,
    StampUpdateElement nvarchar(100) NULL,
    /* Element, s katerim SAOP sam dodeli sifro; NULL pomeni, da entiteta tega ne pozna. */
    SuggestCodeElement nvarchar(100) NULL,
    IsEnabled bit NOT NULL CONSTRAINT DF_SaopDocument_Enabled DEFAULT (1),
    UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_SaopDocument_UpdatedUtc DEFAULT SYSUTCDATETIME(),
    UpdatedBy nvarchar(200) NOT NULL CONSTRAINT DF_SaopDocument_UpdatedBy DEFAULT N'migracija 085',
    CONSTRAINT CK_SaopDocument_Operations CHECK (AddOperation IN (N'POST', N'PATCH') AND UpdateOperation IN (N'POST', N'PATCH'))
  );
END;

MERGE out.SaopDocument AS target
USING
(
  VALUES
    (N'SAOP_PRODUCT',   N'Product',   N'ItemsGeneralData', N'ItemsGeneralData', N'ItemGeneralData', N'ItemID',
     N'api/Item/AddItemsGeneralData',   N'POST',  N'api/Item/UpdateItemsGeneralData', N'PATCH',
     N'ItemCreated', N'ItemLastModified', N'SuggestFirstFreeCode'),
    (N'SAOP_CUSTOMER',  N'Customer',  N'Customer',         N'CustomerV2',       NULL,               N'Code',
     N'api/Customers/AddCustomer',      N'POST',  N'api/V2/Customers/UpdateCustomer', N'PATCH',
     NULL, NULL, N'SuggestFirstFreeCode'),
    (N'SAOP_PRICELIST', N'PriceList', N'PriceList',        N'PriceList',        NULL,               N'PriceListId',
     N'api/pricelists/AddPriceLists',   N'POST',  N'api/pricelists/ModifyPriceLists', N'POST',
     NULL, NULL, NULL),
    /* Naravni kljuc cene je po preglednici PriceListId + PriceListDate + ItemCode. */
    (N'SAOP_PRICE',     N'Price',     N'ItemPrice',        N'ItemPrice',        NULL,               N'PriceListId|ItemCode',
     N'api/Price/AddPrices',            N'POST',  N'api/V2/Price/ModifyPricesV2',     N'POST',
     NULL, NULL, NULL)
) AS source (TargetKind, EntityType, RootElementAdd, RootElementUpdate, ItemElement, KeyElements,
             AddPath, AddOperation, UpdatePath, UpdateOperation, StampAddElement, StampUpdateElement, SuggestCodeElement)
  ON target.TargetKind = source.TargetKind
WHEN MATCHED THEN UPDATE SET
  EntityType = source.EntityType, RootElementAdd = source.RootElementAdd, RootElementUpdate = source.RootElementUpdate,
  ItemElement = source.ItemElement, KeyElements = source.KeyElements,
  AddPath = source.AddPath, AddOperation = source.AddOperation,
  UpdatePath = source.UpdatePath, UpdateOperation = source.UpdateOperation,
  StampAddElement = source.StampAddElement, StampUpdateElement = source.StampUpdateElement,
  SuggestCodeElement = source.SuggestCodeElement, UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = N'migracija 085'
WHEN NOT MATCHED THEN INSERT (TargetKind, EntityType, RootElementAdd, RootElementUpdate, ItemElement, KeyElements,
  AddPath, AddOperation, UpdatePath, UpdateOperation, StampAddElement, StampUpdateElement, SuggestCodeElement)
  VALUES (source.TargetKind, source.EntityType, source.RootElementAdd, source.RootElementUpdate, source.ItemElement,
    source.KeyElements, source.AddPath, source.AddOperation, source.UpdatePath, source.UpdateOperation,
    source.StampAddElement, source.StampUpdateElement, source.SuggestCodeElement);

/* --- 2) Polja niso vec vezana na ovoje izdelka -------------------------- */

/*
  Omejitev iz migracije 081 je nastela ovoje izdelka (Item, GeneralData, SalesData, StockData,
  PropertiesData). Stranke, ceniki in cene ovojev nimajo — vsa polja so neposredno pod korenom,
  torej v ovoju 'Item'. Nova omejitev zato zahteva samo, da ovoj ni prazen.

  Omejitve v SQL Serverju ni mogoce razsiriti brez DROP in ponovnega CREATE. Podatki se pri tem
  ne izgubijo; omejitev se takoj postavi nazaj in se z WITH CHECK preveri nad obstojecimi
  vrsticami. Isto je moralo narediti ze 046 za CK_OutboxMessage_Status. Omejitev je nastala v
  081, torej v istem delu, in ni tuja.
*/
IF EXISTS
(
  SELECT 1 FROM sys.check_constraints
  WHERE name = N'CK_SaopXmlField_Section' AND definition LIKE N'%PropertiesData%'
)
BEGIN
  ALTER TABLE out.SaopXmlField DROP CONSTRAINT CK_SaopXmlField_Section;
  ALTER TABLE out.SaopXmlField WITH CHECK ADD CONSTRAINT CK_SaopXmlField_Section
    CHECK (LEN(LTRIM(RTRIM(Section))) > 0);
END;

/*
  Kateri element je kljucni, se NE zapisuje na polje. Izpeljan je iz out.SaopDocument.KeyElements,
  ker bi sicer isto dejstvo stalo na dveh mestih in bi se dalo razsuti narazen: dokument bi trdil,
  da je kljuc PriceListId|ItemCode, polje pa bi bilo oznaceno drugace. En vir resnice je kljuc.
*/

/* --- 3) Polja strank ---------------------------------------------------- */

/*
  Deset pisljivih polj z lista 'Stranke'. Vrstni red je tak, kot ga ima resnicni dokument,
  ki ga je SAOP sprejel v razclenitev.
*/
MERGE out.SaopXmlField AS target
USING
(
  VALUES
    (N'SAOP_CUSTOMER', N'Item', N'Code',           N'Customer.Code',           10, 1, N'text'),
    (N'SAOP_CUSTOMER', N'Item', N'Name',           N'Customer.Name',           20, 1, N'text'),
    (N'SAOP_CUSTOMER', N'Item', N'Address',        N'Customer.Address',        30, 0, N'text'),
    (N'SAOP_CUSTOMER', N'Item', N'PostalCode',     N'Customer.PostalCode',     40, 0, N'text'),
    (N'SAOP_CUSTOMER', N'Item', N'City',           N'Customer.City',           50, 0, N'text'),
    /* SAOP je resnicno zavrnil 'Slovenija' z 'sifra Slovenija ne obstaja v tabeli SPLDrzave';
       to polje je sifra drzave, ne ime. */
    (N'SAOP_CUSTOMER', N'Item', N'Country',        N'Customer.Country',        60, 0, N'text'),
    (N'SAOP_CUSTOMER', N'Item', N'TaxNumber',      N'Customer.TaxNumber',      70, 0, N'text'),
    (N'SAOP_CUSTOMER', N'Item', N'SubjectToVAT',   N'Customer.SubjectToVAT',   80, 0, N'text'),
    (N'SAOP_CUSTOMER', N'Item', N'WebSiteURL',     N'Customer.WebSiteURL',     90, 0, N'text'),
    (N'SAOP_CUSTOMER', N'Item', N'ExpirationDays', N'Customer.ExpirationDays', 100, 0, N'text'),
    (N'SAOP_CUSTOMER', N'Item', N'RebatePercent',  N'Customer.RebatePercent',  110, 0, N'decimal4'),
    (N'SAOP_CUSTOMER', N'Item', N'PriceList',      N'Customer.PriceList',      120, 0, N'text'),
    (N'SAOP_CUSTOMER', N'Item', N'CustomerStatus', N'Customer.CustomerStatus', 130, 0, N'text')
) AS source (TargetKind, Section, ElementName, FieldKey, SortOrder, IsAddMandatory, ValueFormat)
  ON target.TargetKind = source.TargetKind AND target.Section = source.Section AND target.ElementName = source.ElementName
WHEN MATCHED THEN UPDATE SET FieldKey = source.FieldKey, SortOrder = source.SortOrder,
  IsAddMandatory = source.IsAddMandatory, ValueFormat = source.ValueFormat, UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = N'migracija 085'
WHEN NOT MATCHED THEN INSERT (TargetKind, Section, ElementName, FieldKey, SortOrder, IsAddMandatory, ValueFormat)
  VALUES (source.TargetKind, source.Section, source.ElementName, source.FieldKey, source.SortOrder,
    source.IsAddMandatory, source.ValueFormat);

/* --- 4) Polja cenikov in cen -------------------------------------------- */

/*
  Oblika je zapisana, pravice do pisanja ni. Glej razlago na vrhu: po preglednici je master
  za vsa ta polja SAOP.
*/
MERGE out.SaopXmlField AS target
USING
(
  VALUES
    (N'SAOP_PRICELIST', N'Item', N'PriceListId',          N'PriceList.PriceListId',          10, 1, N'text'),
    (N'SAOP_PRICELIST', N'Item', N'PriceListDescription', N'PriceList.PriceListDescription', 20, 0, N'text'),
    (N'SAOP_PRICELIST', N'Item', N'CurrencyId',           N'PriceList.CurrencyId',           30, 0, N'text'),
    (N'SAOP_PRICELIST', N'Item', N'Active',               N'PriceList.Active',               40, 0, N'bool'),

    (N'SAOP_PRICE', N'Item', N'PriceListId',       N'Price.PriceListId',       10, 1, N'text'),
    (N'SAOP_PRICE', N'Item', N'ItemCode',          N'Price.ItemCode',          20, 1, N'text'),
    (N'SAOP_PRICE', N'Item', N'Price',             N'Price.Net',               30, 1, N'decimal4'),
    (N'SAOP_PRICE', N'Item', N'VATRate',           N'Price.VatRate',           40, 0, N'decimal4'),
    (N'SAOP_PRICE', N'Item', N'Active',            N'Price.Active',            50, 0, N'bool'),
    (N'SAOP_PRICE', N'Item', N'PriceValidityFrom', N'Price.ValidFrom',         60, 0, N'text')
) AS source (TargetKind, Section, ElementName, FieldKey, SortOrder, IsAddMandatory, ValueFormat)
  ON target.TargetKind = source.TargetKind AND target.Section = source.Section AND target.ElementName = source.ElementName
WHEN NOT MATCHED THEN INSERT (TargetKind, Section, ElementName, FieldKey, SortOrder, IsAddMandatory, ValueFormat, TrueValue, FalseValue)
  VALUES (source.TargetKind, source.Section, source.ElementName, source.FieldKey, source.SortOrder,
    source.IsAddMandatory, source.ValueFormat,
    CASE WHEN source.ValueFormat = N'bool' THEN N'true' END,
    CASE WHEN source.ValueFormat = N'bool' THEN N'false' END);

/* --- 5) Lastnistvo, kjer je zagovorljivo -------------------------------- */

/*
  Pravilo O9 iz migracije 068: pravica do pisanja nastane samo za polje, ki ga tudi beremo
  nazaj. Za stranke danes beremo styiri polja (b2b.Customer), od tega je po preglednici
  pisljiv naziv. Sifra je kljuc, ne polje v lasti PIM.

  Vsa ostala polja dobijo vrstico z Owner='SAOP', da je pravilo vidno in da se zavrnitev da
  razloziti — enako, kot je to naredila 068 za izdelke.
*/
MERGE out.OwnershipPolicy AS target
USING
(
  SELECT organization.OrganizationId, N'SAOP_CUSTOMER' AS TargetKind, N'Customer' AS EntityType,
    field.FieldKey AS FieldName,
    CASE WHEN field.FieldKey = N'Customer.Name' THEN N'PIM' ELSE N'SAOP' END AS Owner
  FROM dbo.OrganizationConfig AS organization
  CROSS JOIN out.SaopXmlField AS field
  INNER JOIN out.SaopDocument AS document ON document.TargetKind = field.TargetKind
  WHERE field.TargetKind = N'SAOP_CUSTOMER' AND field.FieldKey IS NOT NULL
    AND N'|' + document.KeyElements + N'|' NOT LIKE N'%|' + field.ElementName + N'|%'
) AS source
  ON target.OrganizationId = source.OrganizationId AND target.TargetKind = source.TargetKind
    AND target.EntityType = source.EntityType AND target.FieldName = source.FieldName
    AND target.ConstraintValue IS NULL
WHEN MATCHED THEN UPDATE SET Owner = source.Owner, IsEnabled = 1, UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = N'migracija 085'
WHEN NOT MATCHED THEN INSERT (OrganizationId, TargetKind, EntityType, FieldName, Owner, IsEnabled, UpdatedBy)
  VALUES (source.OrganizationId, source.TargetKind, source.EntityType, source.FieldName, source.Owner, 1, N'migracija 085');

/* Cene in ceniki: vrstice nastanejo samo z Owner='SAOP'. Nic se ne da poslati, dokler
   uporabnik izrecno ne odloci drugace. */
MERGE out.OwnershipPolicy AS target
USING
(
  SELECT organization.OrganizationId, field.TargetKind, document.EntityType, field.FieldKey AS FieldName
  FROM dbo.OrganizationConfig AS organization
  CROSS JOIN out.SaopXmlField AS field
  INNER JOIN out.SaopDocument AS document ON document.TargetKind = field.TargetKind
  WHERE field.TargetKind IN (N'SAOP_PRICE', N'SAOP_PRICELIST') AND field.FieldKey IS NOT NULL
    AND N'|' + document.KeyElements + N'|' NOT LIKE N'%|' + field.ElementName + N'|%'
) AS source
  ON target.OrganizationId = source.OrganizationId AND target.TargetKind = source.TargetKind
    AND target.EntityType = source.EntityType AND target.FieldName = source.FieldName
    AND target.ConstraintValue IS NULL
WHEN NOT MATCHED THEN INSERT (OrganizationId, TargetKind, EntityType, FieldName, Owner, IsEnabled, UpdatedBy)
  VALUES (source.OrganizationId, source.TargetKind, source.EntityType, source.FieldName, N'SAOP', 1, N'migracija 085');

/* --- 6) Branje pogodbe po entiteti -------------------------------------- */

EXEC(N'
CREATE OR ALTER PROCEDURE out.GetSaopXmlContract @TargetKind nvarchar(100) = N''SAOP_PRODUCT''
AS
BEGIN
  SET NOCOUNT ON;

  SELECT TargetKind, EntityType, RootElementAdd, RootElementUpdate, ItemElement, KeyElements,
    AddPath, AddOperation, UpdatePath, UpdateOperation,
    StampAddElement, StampUpdateElement, SuggestCodeElement
  FROM out.SaopDocument WHERE TargetKind = @TargetKind AND IsEnabled = 1;

  SELECT field.Section, field.ElementName, field.FieldKey, field.SortOrder, field.IsAddMandatory,
    field.ValueFormat, field.TrueValue, field.FalseValue,
    IsKey = CONVERT(bit, CASE WHEN N''|'' + document.KeyElements + N''|'' LIKE N''%|'' + field.ElementName + N''|%'' THEN 1 ELSE 0 END)
  FROM out.SaopXmlField AS field
  INNER JOIN out.SaopDocument AS document ON document.TargetKind = field.TargetKind
  WHERE field.TargetKind = @TargetKind AND field.IsEnabled = 1
  ORDER BY field.SortOrder;
END;');

/* --- 7) Preverbe -------------------------------------------------------- */

IF (SELECT COUNT(*) FROM out.SaopDocument WHERE IsEnabled = 1) < 4
  THROW 52850, 'Vse stiri entitete morajo imeti zapisano obliko dokumenta.', 1;

/* Vsak dokument mora imeti vsaj en kljucni element, sicer ga ni mogoce nasloviti. */
IF EXISTS
(
  SELECT 1 FROM out.SaopDocument AS document
  WHERE document.IsEnabled = 1
    AND NOT EXISTS (SELECT 1 FROM out.SaopXmlField AS field
      WHERE field.TargetKind = document.TargetKind AND field.IsEnabled = 1
        AND N'|' + document.KeyElements + N'|' LIKE N'%|' + field.ElementName + N'|%')
)
  THROW 52851, 'Dokument brez kljucnega elementa ni naslovljiv.', 1;

/* Stevilo kljucnih elementov se mora ujemati z zapisanim naravnim kljucem. */
IF EXISTS
(
  SELECT 1 FROM out.SaopDocument AS document
  CROSS APPLY (SELECT COUNT(*) AS Zapisanih FROM STRING_SPLIT(document.KeyElements, N'|')) AS pricakovano
  CROSS APPLY (SELECT COUNT(*) AS Dejanskih FROM out.SaopXmlField AS field
    WHERE field.TargetKind = document.TargetKind AND field.IsEnabled = 1
      AND N'|' + document.KeyElements + N'|' LIKE N'%|' + field.ElementName + N'|%') AS dejansko
  WHERE document.IsEnabled = 1 AND pricakovano.Zapisanih <> dejansko.Dejanskih
)
  THROW 52852, 'Stevilo kljucnih elementov se ne ujema z naravnim kljucem dokumenta.', 1;

/* Nobena cena in noben cenik ne sme dobiti pravice do pisanja mimo odlocitve uporabnika. */
IF EXISTS
(
  SELECT 1 FROM out.OwnershipPolicy
  WHERE TargetKind IN (N'SAOP_PRICE', N'SAOP_PRICELIST') AND Owner = N'PIM'
)
  THROW 52853, 'Cene in ceniki po sprejeti preslikavi niso v lasti PIM; pravica do pisanja ne sme nastati sama od sebe.', 1;
