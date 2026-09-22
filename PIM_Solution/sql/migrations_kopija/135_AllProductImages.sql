/*
  135 — izdelek dobi vse slike, ne samo prve.

  Zahteva uporabnika 2026-08-31: »Sliko pokaze samo glavno, je treba da vse slike pokaze in
  vse dokumente.«

  To ni bila napaka vmesnika. Kartica je vseskozi izpisala vse, kar je v canon.ProductMedia —
  tam pa je bila natanko ena vrstica na izdelek. Merjeno pred to migracijo: **7.648 slik pri
  7.648 izdelkih**. Vzroka sta bila dva in oba sta tu odpravljena:

  1. **Preslikava je brala samo prvo sliko.** Za vsak vir je obstajala ena sama preslikava,
     `photos/photo/url/text()[1]` (Braytron) oziroma `media/image_i/image_i_path/text()[1]`
     (Nowodvorski). Braytronova datoteka ima za en izdelek osem `<photo>`, Nowodvorski pa poleg
     glavne slike se sliko z merami — vse to je bilo v datoteki in nikoli v bazi.

     Ker `map.ExtractedValue` po `UQ_ExtractedValue_Trace` dovoli natanko eno vrednost na
     (zapis, preslikava), se vec slik doda z vec preslikavami, vsaka s svojim polozajem:
     `photos/photo[2]/url`, `[3]` … Tako ni treba spreminjati ne izvlecka ne kljuca sledi.

  2. **Zapis je zdruzil vse v eno vrstico.** Blok 13 v `map.ProcessRawInbox` je bral iz
     `#Value`, ki hrani eno vrednost na ciljno kodo, in z `MAX(Value)` obdrzal eno. Zdaj bere
     neposredno iz `map.ExtractedValue` — enako kot blok 12 za kategorije, kjer isti primer
     (vec vrednosti na zapis) ze deluje — in zapise eno vrstico na sliko.

  Prva slika ostane `PRIMARY`, ostale so `GALLERY`, da glavna slika ostane prepoznavna;
  vrstni red doloci polozaj v dobaviteljevi datoteki.

  **Migracija sama ne napolni slik.** Zapisane bodo ob naslednji preslikavi zajetih strani
  (`--map-run` oziroma `--full`); do takrat ostane stanje tako, kot je.

  Dokumenti so ze zdaj po vec na izdelek (9.953 dokumentov v sedmih vlogah) in se ne
  spreminjajo.

  Migracija je ponovljiva: CREATE OR ALTER in MERGE po sifri preslikave.
*/

SET XACT_ABORT ON;

/* --- 1) Preslikave za drugo in nadaljnje slike ------------------------------------------- */

/* Braytron: <photos><photo><url>…</url></photo>…</photos>, do deset slik na izdelek.
   Nowodvorski: media/image_i … image_v, vsak s svojo potjo. Polozaj je del izraza, ker
   izvlecek vzame eno vozlisce na preslikavo. */
DECLARE @MediaMapping TABLE (ConnectorPattern nvarchar(50), SourceElement nvarchar(400));

INSERT @MediaMapping (ConnectorPattern, SourceElement)
SELECT N'BT_XML', N'photos/photo[' + CONVERT(nvarchar(4), position.n) + N']/url/text()[1]'
FROM (VALUES (2),(3),(4),(5),(6),(7),(8),(9),(10)) AS position(n)
UNION ALL
SELECT N'NW_XML', N'media/image_' + roman.code + N'/image_' + roman.code + N'_path/text()[1]'
FROM (VALUES (N'ii'),(N'iii'),(N'iv'),(N'v')) AS roman(code);

MERGE map.FieldMapping AS target
USING
(
  SELECT connector.SourceConnectorId, mediaMapping.SourceElement,
    EntityType = existing.EntityType, MappingVersion = existing.MappingVersion
  FROM @MediaMapping AS mediaMapping
  INNER JOIN map.SourceConnector AS connector ON connector.SourceCode = mediaMapping.ConnectorPattern
  CROSS APPLY
  (
    SELECT TOP (1) sibling.EntityType, sibling.MappingVersion
    FROM map.FieldMapping AS sibling
    WHERE sibling.SourceConnectorId = connector.SourceConnectorId
      AND sibling.TargetFieldCode = N'ProductMedia.Url'
    ORDER BY sibling.FieldMappingId
  ) AS existing
) AS source
  ON target.SourceConnectorId = source.SourceConnectorId
 AND target.SourceElement = source.SourceElement
 AND target.TargetFieldCode = N'ProductMedia.Url'
WHEN NOT MATCHED THEN
  INSERT (SourceConnectorId, EntityType, SourceElement, TargetFieldCode, IsRequired, IsActive, MappingVersion)
  VALUES (source.SourceConnectorId, source.EntityType, source.SourceElement, N'ProductMedia.Url', 0, 1, source.MappingVersion);

/* --- 2) Zapis ene vrstice na sliko -------------------------------------------------------- */

EXEC(N'
CREATE OR ALTER PROCEDURE map.ProcessRawInbox
  @RunId uniqueidentifier,
  @OrganizationId int,
  @SourceCode nvarchar(100)
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  DECLARE @CanCreateProducts bit =
  (
    SELECT TOP(1) CanCreateProducts FROM map.SourceConnector
    WHERE SourceCode=@SourceCode AND OrganizationId=@OrganizationId AND IsActive=1
  );

  IF @CanCreateProducts IS NULL THROW 52310,''Aktivni izvorni konektor ne obstaja.'',1;

  /*
    En zapis iz XML = ena vrstica. Prej je bil to kurzor, zdaj je tabela, ki jo
    obdelamo v celoti naenkrat.
  */
  CREATE TABLE #Record
  (
    RecordOrdinal   int NOT NULL PRIMARY KEY,
    ItemID          nvarchar(100) COLLATE DATABASE_DEFAULT NULL,
    EAN             nvarchar(100) COLLATE DATABASE_DEFAULT NULL,
    ProductId       bigint NULL,
    RejectionReason nvarchar(500) COLLATE DATABASE_DEFAULT NULL
  );

  /* Artikli, ki jih je ta vhodna vrstica ustvarila (samo ERP viri). */
  CREATE TABLE #Created
  (
    ItemID    nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY,
    ProductId bigint NOT NULL
  );

  /*
    Zmagovalna vrednost na (izdelek, ciljno polje). Kurzor je zapise obdeloval po
    vrsti in vsak naslednji je s COALESCE prepisal prejsnjega; tu isto pravilo
    izrazimo z DENSE_RANK po RecordOrdinal DESC: zadnji nepraznji zapis zmaga.
  */
  CREATE TABLE #Value
  (
    ProductId       bigint NOT NULL,
    TargetFieldCode nvarchar(400) COLLATE DATABASE_DEFAULT NOT NULL,
    Value           nvarchar(max) COLLATE DATABASE_DEFAULT NULL,
    PRIMARY KEY(ProductId, TargetFieldCode)   /* brez imena: imenovana omejitev na #tabeli trci med hkratnimi sejami */
  );

  DECLARE @InboxId bigint;
  DECLARE inbox_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT inbox.InboxId
    FROM raw.Inbox inbox
    WHERE inbox.RunId=@RunId AND inbox.OrganizationId=@OrganizationId
      AND inbox.SourceCode=@SourceCode AND inbox.Status=''Pending''
      AND EXISTS(SELECT 1 FROM map.ExtractedValue value WHERE value.InboxId=inbox.InboxId)
      /*
        Ta postopek zna samo izdelke: zapis brez sifre ali EAN mu je zavrnjen zapis. Sifranti
        (skladisca, valute, ceniki) so drug svet in imajo svoj postopek, zato se tu preskocijo.
        Kateri svet je kateri, pove register (map.EntityMapping.TargetDomain), ne ime entitete.

        Pogoj je NOT EXISTS in ne EXISTS namenoma: preskoci se samo tisto, kar je izrecno
        oznaceno kot drug svet. Odsotnost vrstice v registru pomeni izdelek — enako kot prej,
        ko tega stolpca ni bilo, in enako kot privzetek TargetDomain.
      */
      AND NOT EXISTS
      (
        SELECT 1
        FROM map.EntityMapping entityMapping
        INNER JOIN map.SourceConnector connector ON connector.SourceConnectorId=entityMapping.SourceConnectorId
        WHERE connector.SourceCode=inbox.SourceCode AND connector.OrganizationId=inbox.OrganizationId
          AND entityMapping.EntityType=inbox.EntityType AND entityMapping.IsActive=1
          AND entityMapping.TargetDomain<>''Product''
      )
    ORDER BY inbox.InboxId;
  OPEN inbox_cursor;
  FETCH NEXT FROM inbox_cursor INTO @InboxId;
  WHILE @@FETCH_STATUS=0
  BEGIN
    BEGIN TRY
      /* Zunaj transakcije, da povrnitev ne ozivi vrstic prejsnje vhodne vrstice. */
      DELETE FROM #Record;
      DELETE FROM #Created;
      DELETE FROM #Value;

      BEGIN TRANSACTION;

      DECLARE @SuccessCount int=0,@RejectedCount int=0,@CreatedCount int=0,@LastFailureReason nvarchar(500)=NULL;

      /* --- 1. en zapis = ena vrstica ------------------------------------ */
      INSERT #Record(RecordOrdinal,ItemID,EAN)
      SELECT value.RecordOrdinal,
        NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(100),MAX(CASE WHEN value.TargetFieldCode=''Product.ItemID'' THEN value.Value END)))),''''),
        NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(100),MAX(CASE WHEN value.TargetFieldCode=''Product.EAN'' THEN value.Value END)))),'''')
      FROM map.ExtractedValue value
      WHERE value.InboxId=@InboxId
          AND EXISTS(SELECT 1 FROM map.FieldMapping mapping
                     WHERE mapping.FieldMappingId=value.FieldMappingId AND mapping.IsActive=1)
      GROUP BY value.RecordOrdinal;

      /* --- 2. manjkajoca obvezna vrednost -------------------------------- */
      UPDATE record SET RejectionReason=''Obvezna preslikana vrednost manjka.''
      FROM #Record record
      WHERE EXISTS
      (
        SELECT 1
        FROM map.ExtractedValue value
        INNER JOIN map.FieldMapping mapping ON mapping.FieldMappingId=value.FieldMappingId
          AND mapping.MappingVersion=value.MappingVersion
        WHERE value.InboxId=@InboxId AND value.RecordOrdinal=record.RecordOrdinal
          AND mapping.IsActive=1 AND mapping.IsRequired=1
          AND NULLIF(LTRIM(RTRIM(value.Value)),'''') IS NULL
      );

      /* --- 3. poisci izdelek: najprej po ItemID, sele nato po EAN --------- */
      UPDATE record SET ProductId=najden.ProductId
      FROM #Record record
      CROSS APPLY
      (
        SELECT TOP(1) product.ProductId FROM canon.Product product
        WHERE product.OrganizationId=@OrganizationId AND product.ItemID=record.ItemID
        ORDER BY product.ProductId
      ) najden
      WHERE record.RejectionReason IS NULL AND record.ItemID IS NOT NULL;

      UPDATE record SET ProductId=najden.ProductId
      FROM #Record record
      CROSS APPLY
      (
        SELECT TOP(1) product.ProductId FROM canon.Product product
        WHERE product.OrganizationId=@OrganizationId AND product.EAN=record.EAN
        ORDER BY product.ProductId
      ) najden
      WHERE record.RejectionReason IS NULL AND record.ProductId IS NULL AND record.EAN IS NOT NULL;

      /* --- 4. ERP vir sme artikel ustvariti ------------------------------- */
      IF @CanCreateProducts=1
      BEGIN
        /*
          Ista sifra se v isti strani lahko pojavi veckrat. Kurzor je artikel
          ustvaril ob prvem pojavu, ostali pojavi so ga nato nasli; tu ustvarimo
          eno vrstico na sifro, po prvem zapisu, in jo priklopimo na vse pojave.
        */
        ;WITH nov AS
        (
          SELECT ItemID,EAN,ROW_NUMBER() OVER(PARTITION BY ItemID ORDER BY RecordOrdinal) Zaporedje
          FROM #Record
          WHERE RejectionReason IS NULL AND ProductId IS NULL AND ItemID IS NOT NULL
        )
        INSERT canon.Product(OrganizationId,ItemID,EAN,BusinessHash)
        OUTPUT inserted.ItemID,inserted.ProductId INTO #Created(ItemID,ProductId)
        SELECT @OrganizationId,nov.ItemID,nov.EAN,
          CONVERT(char(64),HASHBYTES(''SHA2_256'',CONCAT(nov.ItemID,''|'',nov.EAN)),2)
        FROM nov WHERE nov.Zaporedje=1;

        SET @CreatedCount=@@ROWCOUNT;

        UPDATE record SET ProductId=created.ProductId
        FROM #Record record
        INNER JOIN #Created created ON created.ItemID=record.ItemID
        WHERE record.ProductId IS NULL;
      END;

      /* --- 5. izdelka ni ------------------------------------------------- */
      UPDATE #Record SET RejectionReason=''Izdelek za konfigurirani identifikator ne obstaja.''
      WHERE RejectionReason IS NULL AND ProductId IS NULL;

      /* --- 6. neveljavna cena -------------------------------------------- */
      UPDATE record SET RejectionReason=''Neveljavna cena, DDV ali datum veljavnosti.''
      FROM #Record record
      WHERE record.RejectionReason IS NULL AND EXISTS
      (
        SELECT 1 FROM map.ExtractedValue value
        WHERE value.InboxId=@InboxId AND value.RecordOrdinal=record.RecordOrdinal AND value.Value IS NOT NULL
          AND EXISTS(SELECT 1 FROM map.FieldMapping mapping
                     WHERE mapping.FieldMappingId=value.FieldMappingId AND mapping.IsActive=1)
          AND
          (
            (value.TargetFieldCode=''ProductPrice.Net''
              AND (TRY_CONVERT(decimal(19,4),value.Value) IS NULL OR TRY_CONVERT(decimal(19,4),value.Value)<0))
            OR (value.TargetFieldCode=''ProductPrice.VatRate''
              AND (TRY_CONVERT(decimal(5,2),value.Value) IS NULL
                OR TRY_CONVERT(decimal(5,2),value.Value)<0 OR TRY_CONVERT(decimal(5,2),value.Value)>100))
            OR (value.TargetFieldCode=''ProductPrice.ValidFrom''
              AND TRY_CONVERT(datetime2(3),value.Value) IS NULL)
          )
      );

      /* --- 7. stevci ------------------------------------------------------ */
      SELECT
        @SuccessCount=COALESCE(SUM(CASE WHEN RejectionReason IS NULL THEN 1 ELSE 0 END),0),
        @RejectedCount=COALESCE(SUM(CASE WHEN RejectionReason IS NULL THEN 0 ELSE 1 END),0)
      FROM #Record;

      SET @LastFailureReason=
      (
        SELECT TOP(1) RejectionReason FROM #Record
        WHERE RejectionReason IS NOT NULL ORDER BY RecordOrdinal DESC
      );

      /* --- 8. zmagovalne vrednosti sprejetih zapisov ---------------------- */
      INSERT #Value(ProductId,TargetFieldCode,Value)
      SELECT zmagovalec.ProductId,zmagovalec.TargetFieldCode,MAX(zmagovalec.Value)
      FROM
      (
        SELECT record.ProductId,value.TargetFieldCode,value.Value,
          DENSE_RANK() OVER(PARTITION BY record.ProductId,value.TargetFieldCode
                            ORDER BY value.RecordOrdinal DESC) Mesto
        FROM map.ExtractedValue value
        INNER JOIN #Record record ON record.RecordOrdinal=value.RecordOrdinal
        WHERE value.InboxId=@InboxId AND record.RejectionReason IS NULL AND value.Value IS NOT NULL
          AND EXISTS(SELECT 1 FROM map.FieldMapping mapping
                     WHERE mapping.FieldMappingId=value.FieldMappingId AND mapping.IsActive=1)
      ) zmagovalec
      WHERE zmagovalec.Mesto=1
      GROUP BY zmagovalec.ProductId,zmagovalec.TargetFieldCode;

      /* --- 9. canon.Product ----------------------------------------------- */
      UPDATE product SET
        EAN=COALESCE(source.EAN,product.EAN),
        UoM=COALESCE(source.UoM,product.UoM),
        AccountingGroup=COALESCE(source.AccountingGroup,product.AccountingGroup),
        Supplier=COALESCE(source.Supplier,product.Supplier),
        DiscountGroup=COALESCE(source.DiscountGroup,product.DiscountGroup),
        Manufacturer=COALESCE(source.Manufacturer,product.Manufacturer),
        ItemGroup=COALESCE(source.ItemGroup,product.ItemGroup),
        Department=COALESCE(source.Department,product.Department),
        WebPublish=COALESCE(source.WebPublish,product.WebPublish),
        IsActive=COALESCE(source.IsActive,product.IsActive),
        ValidationStatus=''PENDING''
      FROM canon.Product product
      INNER JOIN (SELECT DISTINCT ProductId FROM #Record WHERE RejectionReason IS NULL) sprejet
        ON sprejet.ProductId=product.ProductId
      LEFT JOIN
      (
        SELECT ProductId,
          NULLIF(LTRIM(RTRIM(MAX(CASE WHEN TargetFieldCode=''Product.EAN'' THEN Value END))),'''') EAN,
          MAX(CASE WHEN TargetFieldCode=''Product.UoM'' THEN Value END) UoM,
          MAX(CASE WHEN TargetFieldCode=''Product.AccountingGroup'' THEN Value END) AccountingGroup,
          MAX(CASE WHEN TargetFieldCode=''Product.Supplier'' THEN Value END) Supplier,
          MAX(CASE WHEN TargetFieldCode=''Product.DiscountGroup'' THEN Value END) DiscountGroup,
          MAX(CASE WHEN TargetFieldCode=''Product.Manufacturer'' THEN Value END) Manufacturer,
          NULLIF(LTRIM(RTRIM(MAX(CASE WHEN TargetFieldCode=''Product.ItemGroup'' THEN Value END))),'''') ItemGroup,
          NULLIF(LTRIM(RTRIM(MAX(CASE WHEN TargetFieldCode=''Product.Department'' THEN Value END))),'''') Department,
          CASE UPPER(LTRIM(RTRIM(MAX(CASE WHEN TargetFieldCode=''Product.WebPublish'' THEN Value END))))
            WHEN ''D'' THEN CONVERT(bit,1) WHEN ''Y'' THEN CONVERT(bit,1)
            WHEN ''TRUE'' THEN CONVERT(bit,1) WHEN ''1'' THEN CONVERT(bit,1)
            WHEN ''N'' THEN CONVERT(bit,0) WHEN ''FALSE'' THEN CONVERT(bit,0) WHEN ''0'' THEN CONVERT(bit,0)
            ELSE NULL END WebPublish,
          CASE UPPER(LTRIM(RTRIM(MAX(CASE WHEN TargetFieldCode=''Product.IsActive'' THEN Value END))))
            WHEN ''D'' THEN CONVERT(bit,1) WHEN ''Y'' THEN CONVERT(bit,1)
            WHEN ''TRUE'' THEN CONVERT(bit,1) WHEN ''1'' THEN CONVERT(bit,1)
            WHEN ''N'' THEN CONVERT(bit,0) WHEN ''FALSE'' THEN CONVERT(bit,0) WHEN ''0'' THEN CONVERT(bit,0)
            ELSE NULL END IsActive
        FROM #Value GROUP BY ProductId
      ) source ON source.ProductId=product.ProductId;

      /* --- 10. canon.ProductText ------------------------------------------ */
      MERGE canon.ProductText AS target
      USING
      (
        SELECT ProductId,
          CONVERT(nvarchar(50),SUBSTRING(TargetFieldCode,13,LEN(TargetFieldCode)-13-CHARINDEX(''.'',REVERSE(TargetFieldCode))+1)) TextType,
          CONVERT(nvarchar(20),RIGHT(TargetFieldCode,CHARINDEX(''.'',REVERSE(TargetFieldCode))-1)) Lang,
          MAX(Value) Value
        FROM #Value
        WHERE TargetFieldCode LIKE ''ProductText.%''
        GROUP BY ProductId,
          SUBSTRING(TargetFieldCode,13,LEN(TargetFieldCode)-13-CHARINDEX(''.'',REVERSE(TargetFieldCode))+1),
          RIGHT(TargetFieldCode,CHARINDEX(''.'',REVERSE(TargetFieldCode))-1)
      ) source
        ON target.ProductId=source.ProductId AND target.TextType=source.TextType AND target.Lang=source.Lang
      WHEN MATCHED THEN UPDATE SET Value=source.Value
      WHEN NOT MATCHED THEN INSERT(ProductId,Lang,TextType,Value)
        VALUES(source.ProductId,source.Lang,source.TextType,source.Value);

      /* --- 11. canon.ProductAttribute -------------------------------------- */
      MERGE canon.ProductAttribute AS target
      USING
      (
        SELECT ProductId,CONVERT(nvarchar(200),SUBSTRING(TargetFieldCode,18,200)) AttributeCode,MAX(Value) Value
        FROM #Value
        WHERE TargetFieldCode LIKE ''ProductAttribute.%''
        GROUP BY ProductId,SUBSTRING(TargetFieldCode,18,200)
      ) source
        ON target.ProductId=source.ProductId AND target.AttributeCode=source.AttributeCode
      WHEN MATCHED THEN UPDATE SET Value=source.Value
      WHEN NOT MATCHED THEN INSERT(ProductId,AttributeCode,Value)
        VALUES(source.ProductId,source.AttributeCode,source.Value);

      /*
        --- 12. canon.ProductCategory ---------------------------------------
        En zapis lahko pripada vec kategorijam (vec preslikav z isto ciljno kodo),
        zato se tu ne bere iz #Value, ki hrani eno vrednost na ciljno kodo.
      */
      MERGE canon.ProductCategory AS target
      USING
      (
        SELECT DISTINCT record.ProductId,CONVERT(nvarchar(1000),value.Value) CategoryPath
        FROM map.ExtractedValue value
        INNER JOIN #Record record ON record.RecordOrdinal=value.RecordOrdinal
        WHERE value.InboxId=@InboxId AND record.RejectionReason IS NULL
          AND value.TargetFieldCode=''ProductCategory.CategoryPath'' AND value.Value IS NOT NULL
          AND EXISTS(SELECT 1 FROM map.FieldMapping mapping
                     WHERE mapping.FieldMappingId=value.FieldMappingId AND mapping.IsActive=1)
      ) source
        ON target.ProductId=source.ProductId AND target.WebSite=''B2C'' AND target.CategoryPath=source.CategoryPath
      WHEN NOT MATCHED THEN INSERT(ProductId,WebSite,CategoryPath)
        VALUES(source.ProductId,''B2C'',source.CategoryPath);

      /*
        --- 13. canon.ProductMedia -------------------------------------------
        Izdelek ima vec slik, ne ene. Do migracije 135 je ta blok bral iz #Value, ki hrani
        eno vrednost na ciljno kodo, in z MAX(Value) obdrzal natanko eno — merjeno: 7.648
        slik pri 7.648 izdelkih, torej ena na izdelek, medtem ko ima Braytronov XML za isti
        izdelek osem <photo> in Nowodvorski poleg glavne se sliko z merami.

        Zato se tu bere neposredno iz map.ExtractedValue, enako kot pri kategorijah zgoraj:
        ena vrstica na sliko. Vrstni red slike doloci vrstni red preslikave (SourceElement),
        ker prav ta nosi zaporedje iz dobaviteljeve datoteke; prva slika je PRIMARY, ostale
        so GALLERY, da glavna slika ostane prepoznavna.
      */
      MERGE canon.ProductMedia AS target
      USING
      (
        SELECT ProductId, Url, Role = CASE WHEN Mesto = 1 THEN ''PRIMARY'' ELSE ''GALLERY'' END, SortOrder = Mesto
        FROM
        (
          SELECT record.ProductId, Url = CONVERT(nvarchar(2000), value.Value),
            Mesto = ROW_NUMBER() OVER (PARTITION BY record.ProductId ORDER BY MIN(mapping.SourceElement))
          FROM map.ExtractedValue value
          INNER JOIN #Record record ON record.RecordOrdinal=value.RecordOrdinal
          INNER JOIN map.FieldMapping mapping ON mapping.FieldMappingId=value.FieldMappingId AND mapping.IsActive=1
          WHERE value.InboxId=@InboxId AND record.RejectionReason IS NULL
            AND value.TargetFieldCode=''ProductMedia.Url'' AND value.Value IS NOT NULL
          GROUP BY record.ProductId, CONVERT(nvarchar(2000), value.Value)
        ) razvrsceno
      ) source
        ON target.ProductId=source.ProductId AND target.Url=source.Url
      WHEN MATCHED THEN UPDATE SET Role=source.Role, SortOrder=source.SortOrder
      WHEN NOT MATCHED THEN INSERT(ProductId,Url,Role,SortOrder)
        VALUES(source.ProductId,source.Url,source.Role,source.SortOrder);

      /*
        --- 14. canon.ProductPrice -------------------------------------------
        Cena je celota (cenik + neto + DDV + veljavnost) in nastane iz enega zapisa,
        zato se sestavi po zapisu, sele nato obvelja zadnji zapis na kljuc.
      */
      /*
        Novost 057: trgovinski podatki. SAOP jih posilja v ItemGeneralData pod PropertiesData
        (teze, volumen, mere, kolicine pakiranja) in v GeneralData/CustomsTariffNo, mi pa smo
        jih doslej zavrgli — canon.ProductCommercial je imela 0 vrstic, zato sta bila profila
        ERP_L1_EU in COMMERCIAL_L2 pri 0 % veljavnih.

        Stevilke pridejo kot besedilo; TRY_CONVERT pomeni, da neveljavna vrednost postane NULL
        namesto da bi podrla cel zapis. COALESCE ohrani obstojece, kadar vir vrednosti nima —
        enako pravilo kot pri canon.Product.
      */
      MERGE canon.ProductCommercial AS target
      USING
      (
        SELECT ProductId,
          TRY_CONVERT(decimal(19,4), MAX(CASE WHEN TargetFieldCode=''ProductCommercial.NetWeight'' THEN Value END)) NetWeight,
          TRY_CONVERT(decimal(19,4), MAX(CASE WHEN TargetFieldCode=''ProductCommercial.GrossWeight'' THEN Value END)) GrossWeight,
          TRY_CONVERT(decimal(19,4), MAX(CASE WHEN TargetFieldCode=''ProductCommercial.Volume'' THEN Value END)) Volume,
          TRY_CONVERT(decimal(19,4), MAX(CASE WHEN TargetFieldCode=''ProductCommercial.PackageLength'' THEN Value END)) PackageLength,
          TRY_CONVERT(decimal(19,4), MAX(CASE WHEN TargetFieldCode=''ProductCommercial.PackageWidth'' THEN Value END)) PackageWidth,
          TRY_CONVERT(decimal(19,4), MAX(CASE WHEN TargetFieldCode=''ProductCommercial.PackageHeight'' THEN Value END)) PackageHeight,
          TRY_CONVERT(decimal(19,4), MAX(CASE WHEN TargetFieldCode=''ProductCommercial.Pak1'' THEN Value END)) Pak1,
          TRY_CONVERT(decimal(19,4), MAX(CASE WHEN TargetFieldCode=''ProductCommercial.Pak2'' THEN Value END)) Pak2,
          NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(200), MAX(CASE WHEN TargetFieldCode=''ProductCommercial.CustomsTariff'' THEN Value END)))),'''') CustomsTariff,
          NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(200), MAX(CASE WHEN TargetFieldCode=''ProductCommercial.CountryOfOrigin'' THEN Value END)))),'''') CountryOfOrigin,
          NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(40),  MAX(CASE WHEN TargetFieldCode=''ProductCommercial.DimensionUnit'' THEN Value END)))),'''') DimensionUnit
        FROM #Value
        WHERE TargetFieldCode LIKE ''ProductCommercial.%''
        GROUP BY ProductId
      ) source ON target.ProductId=source.ProductId
      WHEN MATCHED THEN UPDATE SET
        NetWeight=COALESCE(source.NetWeight,target.NetWeight),
        GrossWeight=COALESCE(source.GrossWeight,target.GrossWeight),
        Volume=COALESCE(source.Volume,target.Volume),
        PackageLength=COALESCE(source.PackageLength,target.PackageLength),
        PackageWidth=COALESCE(source.PackageWidth,target.PackageWidth),
        PackageHeight=COALESCE(source.PackageHeight,target.PackageHeight),
        Pak1=COALESCE(source.Pak1,target.Pak1),
        Pak2=COALESCE(source.Pak2,target.Pak2),
        CustomsTariff=COALESCE(source.CustomsTariff,target.CustomsTariff),
        CountryOfOrigin=COALESCE(source.CountryOfOrigin,target.CountryOfOrigin),
        DimensionUnit=COALESCE(source.DimensionUnit,target.DimensionUnit)
      WHEN NOT MATCHED THEN
        INSERT(ProductId,NetWeight,GrossWeight,Volume,PackageLength,PackageWidth,PackageHeight,Pak1,Pak2,CustomsTariff,CountryOfOrigin,DimensionUnit)
        VALUES(source.ProductId,source.NetWeight,source.GrossWeight,source.Volume,source.PackageLength,source.PackageWidth,source.PackageHeight,source.Pak1,source.Pak2,source.CustomsTariff,source.CountryOfOrigin,source.DimensionUnit);

      ;WITH cena AS
      (
        SELECT record.ProductId,value.RecordOrdinal,
          MAX(CASE WHEN value.TargetFieldCode=''ProductPrice.PriceList'' THEN CONVERT(nvarchar(100),value.Value) END) PriceList,
          TRY_CONVERT(decimal(19,4),MAX(CASE WHEN value.TargetFieldCode=''ProductPrice.Net'' THEN value.Value END)) Net,
          TRY_CONVERT(decimal(5,2),MAX(CASE WHEN value.TargetFieldCode=''ProductPrice.VatRate'' THEN value.Value END)) VatRate,
          COALESCE(TRY_CONVERT(datetime2(3),MAX(CASE WHEN value.TargetFieldCode=''ProductPrice.ValidFrom'' THEN value.Value END)),
                   CONVERT(datetime2(3),''19000101'')) ValidFrom
        FROM map.ExtractedValue value
        INNER JOIN #Record record ON record.RecordOrdinal=value.RecordOrdinal
        WHERE value.InboxId=@InboxId AND record.RejectionReason IS NULL
          AND EXISTS(SELECT 1 FROM map.FieldMapping mapping
                     WHERE mapping.FieldMappingId=value.FieldMappingId AND mapping.IsActive=1)
        GROUP BY record.ProductId,value.RecordOrdinal
      ),
      zadnja AS
      (
        SELECT ProductId,PriceList,Net,VatRate,ValidFrom,
          ROW_NUMBER() OVER(PARTITION BY ProductId,PriceList,ValidFrom ORDER BY RecordOrdinal DESC) Mesto
        FROM cena
        WHERE PriceList IS NOT NULL AND Net IS NOT NULL AND VatRate IS NOT NULL
      )
      MERGE canon.ProductPrice AS target
      USING (SELECT ProductId,PriceList,Net,VatRate,ValidFrom FROM zadnja WHERE Mesto=1) source
        ON target.ProductId=source.ProductId AND target.PriceList=source.PriceList AND target.ValidFrom=source.ValidFrom
      WHEN MATCHED THEN UPDATE SET Net=source.Net,VatRate=source.VatRate,IsActive=1
      WHEN NOT MATCHED THEN INSERT(ProductId,PriceList,Net,VatRate,ValidFrom,IsActive)
        VALUES(source.ProductId,source.PriceList,source.Net,source.VatRate,source.ValidFrom,1);

      /* --- 15. zakljucek vhodne vrstice ------------------------------------ */
      UPDATE raw.Inbox
      SET Status=''Processed'',ProcessedUtc=SYSUTCDATETIME(),
        FailureReason=
          CASE
            WHEN @SuccessCount=0 THEN CONVERT(nvarchar(2000),CONCAT(''Vsi zapisi preskoceni ('',@RejectedCount,''): '',COALESCE(@LastFailureReason,''ni podrobnosti.'')))
            WHEN @RejectedCount>0 THEN CONVERT(nvarchar(2000),CONCAT(''Delno obogateno: '',@SuccessCount,'' uspeli, '',@RejectedCount,'' preskocenih. Novih artiklov: '',@CreatedCount,''. Zadnji razlog: '',@LastFailureReason))
            WHEN @CreatedCount>0 THEN CONVERT(nvarchar(2000),CONCAT(''Obdelano; novih artiklov: '',@CreatedCount,''.''))
            ELSE NULL
          END
      WHERE InboxId=@InboxId;

      COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
      IF XACT_STATE()<>0 ROLLBACK TRANSACTION;

      DECLARE @FailureReason nvarchar(2000)=LEFT(ERROR_MESSAGE(),2000);
      BEGIN TRANSACTION;
      INSERT map.UnmappedValue(ExtractedValueId,TargetFieldCode,Value,Reason)
      SELECT value.ExtractedValueId,value.TargetFieldCode,value.Value,@FailureReason
      FROM map.ExtractedValue value
      WHERE value.InboxId=@InboxId
        AND NOT EXISTS
        (
          SELECT 1 FROM map.UnmappedValue rejected
          WHERE rejected.ExtractedValueId=value.ExtractedValueId
        );
      UPDATE raw.Inbox
      SET Status=''Quarantined'',ProcessedUtc=SYSUTCDATETIME(),FailureReason=@FailureReason
      WHERE InboxId=@InboxId;
      COMMIT TRANSACTION;
    END CATCH;

    FETCH NEXT FROM inbox_cursor INTO @InboxId;
  END;
  CLOSE inbox_cursor;
  DEALLOCATE inbox_cursor;
END;
');

/* Varovalka: blok 13 ne sme vec zdruzevati slik v eno vrstico. */
IF (SELECT COUNT(*) FROM sys.sql_modules
    WHERE object_id = OBJECT_ID(N'map.ProcessRawInbox')
      AND definition LIKE N'%FROM #Value WHERE TargetFieldCode=''ProductMedia.Url''%') <> 0
  THROW 52681, 'map.ProcessRawInbox se vedno bere slike iz #Value in jih zdruzi v eno.', 1;

IF (SELECT COUNT(*) FROM sys.sql_modules
    WHERE object_id = OBJECT_ID(N'map.ProcessRawInbox')
      AND definition LIKE N'%Role = CASE WHEN Mesto = 1 THEN ''PRIMARY'' ELSE ''GALLERY'' END%') <> 1
  THROW 52682, 'map.ProcessRawInbox ne zapise ene vrstice na sliko.', 1;
