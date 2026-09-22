/*
  245 — uvoz delovnega lista (/izdelki/uvoz): ERP polja v PIM takoj, slike in dokumenti.

  David 2026-09-22 ob datoteki Objemke.xlsx (31 artiklov Vidadria): »morajo se v PIM vstaviti
  vsi podatki. Sepravi ERP brez cakanja SAOPa in omejitev, potem kategorije, nazivi splet in pa
  ERP morajo biti loceni in ravno tako opisi, potem atributi, slike, dokumenti, kljukica za
  izlocanje«. Enako kot pri 243 (»ne bomo nic cakal SAOP«).

  Kaj je test pokazal pred to migracijo (razvojna baza, isti uvoz kot na strani):
    - ERP stolpci so sli SAMO v odhodno vrsto; kanonicna vrednost v PIM se je spremenila sele,
      ko jo je naslednji zajem prinesel nazaj iz SAOP (pravilo 089: »v canon ne zapisemo nicesar,
      cesar SAOP se ni potrdil«). Uporabnik tega pravila za uvoz ne zeli vec.
    - Stolpca »Slike« in »Dokumenti« sta bila samo za branje; uvoz ju je prezrl.

  Zato dve novi proceduri; obe pisete po istem vzorcu kot pim.SaveProductTextsBulk (218):
  en klic za paket izdelkov, zgodovina prek pim.SetChangeContext (vir EXCEL) in sprozilcev,
  kjer sprozilca ni pa rocna vrstica v pim.ProductFieldHistory, in ena mnozicna validacija.

  1) pim.SaveProductErpFieldsBulk — ERP polja iz registra out.SaopXmlField zapise v kanonicne
     tabele TAKOJ: canon.Product, canon.ProductCommercial, canon.ProductText (TITLE_ERP,
     TITLE_ERP2, SEARCH_NAME), canon.ProductAttribute (Garancija) in canon.ProductPlanning
     (kljukica »izloci iz rezervacije«, Planning.ExcludeQtyReservation). Odhodna vrsta za SAOP
     ostane: aplikacija isto spremembo PREJ uvrsti z out.EnqueueSaopItemChanges, kjer caka
     odobritev kot doslej. Slaba vrednost (neznano polje, besedilo namesto stevila, »mogoce«
     namesto da/ne, predolga vrednost) ne podre paketa: vrstica odpade in se vrne z razlogom.
  2) pim.SaveProductMediaBulk — slike in dokumenti iz celic lista. Celica je CEL seznam za
     izdelek (isto pravilo kot stolpec kategorij): kar je v celici, obstaja, kar aplikacija
     poda v "remove", se izbrise. Aplikacija sama ve, kaj je slika in kaj dokument
     (MediaKindPolicy, ista razvrstitev kot izvoz in stran Mediji), zato brisanje poda izrecno.
     Prva slika je PRIMARY, ostale GALLERY (obstojeca AMBIENT ostane AMBIENT); nov dokument
     dobi vlogo "Dokument".

  Kaj je namenoma izpusceno / tveganje, ki ga uporabnik sprejema:
    - Zajem iz SAOP (delta) prepise kanonicno vrednost, ko se artikel v SAOP spremeni. Ce SAOP
      spremembe iz vrste se ni sprejel, se medtem pa je nekdo artikel v SAOP spremenil drugace,
      PIM za trenutek spet kaze vrednost iz SAOP, dokler sporocilo iz vrste ne odide.
    - out.VerifyEchoBatch (243) primerja poslana sporocila s kanonicno vrednostjo; ker je ta po
      uvozu ze nova, se poslano sporocilo potrdi takoj, ko ga kdo preveri.

  Zacasne tabele imajo edinstvena imena (#ErpUvoz..., #MedijUvoz...) — glej 244: gnezdena
  procedura (val.RunValidationForProducts) bi se sicer lahko vezala na klicateljevo tabelo.

  Migrator ne pozna GO, zato CREATE OR ALTER v EXEC(N'...').
*/
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;

/* ── 1) pim.SaveProductErpFieldsBulk ─────────────────────────────────────────── */
EXEC(N'CREATE OR ALTER PROCEDURE pim.SaveProductErpFieldsBulk
  @OrganizationId int,
  @ChangesJson nvarchar(max),   /* [{"productId":123,"fieldKey":"Product.UoM","value":"kom"}, ...] */
  @Actor nvarchar(200),
  @Note nvarchar(400) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  SET @Actor = NULLIF(LTRIM(RTRIM(@Actor)), N'''');
  IF @Actor IS NULL THROW 52950, N''Kdo zapisuje ERP polja, mora biti znano (Actor).'', 1;
  IF ISJSON(@ChangesJson) <> 1 THROW 52951, N''Seznam ERP sprememb ni veljaven JSON.'', 1;

  CREATE TABLE #ErpUvozSprememba
  (
    ProductId bigint NOT NULL,
    FieldKey nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
    Value nvarchar(4000) COLLATE DATABASE_DEFAULT NULL,
    Kind nvarchar(30) COLLATE DATABASE_DEFAULT NULL,
    ColumnName nvarchar(200) COLLATE DATABASE_DEFAULT NULL,
    TextType nvarchar(100) COLLATE DATABASE_DEFAULT NULL,
    Lang nvarchar(40) COLLATE DATABASE_DEFAULT NULL,
    NumberValue decimal(19,4) NULL,
    BitValue bit NULL,
    Reason nvarchar(400) COLLATE DATABASE_DEFAULT NULL,
    PRIMARY KEY (ProductId, FieldKey)
  );

  /* Isto pravilo kot pim.SaveProductTextsBulk: isto polje istega izdelka dvakrat — velja prvo. */
  INSERT #ErpUvozSprememba (ProductId, FieldKey, Value)
  SELECT vrstica.ProductId, vrstica.FieldKey, vrstica.Value
  FROM
  (
    SELECT parsed.productId AS ProductId, LTRIM(RTRIM(parsed.fieldKey)) AS FieldKey,
      NULLIF(LTRIM(RTRIM(parsed.value)), N'''') AS Value,
      ROW_NUMBER() OVER (PARTITION BY parsed.productId, LTRIM(RTRIM(parsed.fieldKey)) ORDER BY CONVERT(int, element.[key])) AS Zaporedna
    FROM OPENJSON(@ChangesJson) AS element
    CROSS APPLY OPENJSON(element.value)
      WITH (productId bigint N''$.productId'', fieldKey nvarchar(200) N''$.fieldKey'', value nvarchar(4000) N''$.value'') AS parsed
    WHERE parsed.productId IS NOT NULL AND NULLIF(LTRIM(RTRIM(parsed.fieldKey)), N'''') IS NOT NULL
  ) AS vrstica
  WHERE vrstica.Zaporedna = 1;

  UPDATE change SET Reason = N''Izdelek ne obstaja v tem podjetju.''
  FROM #ErpUvozSprememba AS change
  WHERE NOT EXISTS (SELECT 1 FROM canon.Product AS product WHERE product.ProductId = change.ProductId AND product.OrganizationId = @OrganizationId);

  /* Katero polje je ERP, pove register — isti, iz katerega nastanejo stolpci lista. */
  UPDATE change SET Reason = N''Polje ni v registru ERP polj (out.SaopXmlField).''
  FROM #ErpUvozSprememba AS change
  WHERE change.Reason IS NULL
    AND NOT EXISTS (SELECT 1 FROM out.SaopXmlField AS field
                    WHERE field.TargetKind = N''SAOP_PRODUCT'' AND field.IsEnabled = 1 AND field.FieldKey = change.FieldKey);

  UPDATE change SET
    Kind = CASE
      WHEN change.FieldKey IN (N''Product.EAN'', N''Product.UoM'', N''Product.VatRateId'', N''Product.ItemGroup'',
        N''Product.AccountingGroup'', N''Product.Department'', N''Product.DiscountGroup'', N''Product.PriceListCode'',
        N''Product.Supplier'', N''Product.Manufacturer'') THEN N''PRODUCT_TEXT''
      WHEN change.FieldKey IN (N''Product.WebPublish'', N''Product.IsActive'') THEN N''PRODUCT_BIT''
      WHEN change.FieldKey IN (N''ProductCommercial.NetWeight'', N''ProductCommercial.GrossWeight'', N''ProductCommercial.Volume'',
        N''ProductCommercial.PackageLength'', N''ProductCommercial.PackageWidth'', N''ProductCommercial.PackageHeight'',
        N''ProductCommercial.Pak1'', N''ProductCommercial.Pak2'') THEN N''COMMERCIAL_NUMBER''
      WHEN change.FieldKey IN (N''ProductCommercial.CustomsTariff'', N''ProductCommercial.CountryOfOrigin'',
        N''ProductCommercial.DimensionUnit'') THEN N''COMMERCIAL_TEXT''
      WHEN change.FieldKey LIKE N''ProductText.%.%'' AND PARSENAME(change.FieldKey, 3) = N''ProductText'' THEN N''TEXT''
      WHEN change.FieldKey LIKE N''ProductAttribute.%'' THEN N''ATTRIBUTE''
      WHEN change.FieldKey = N''Planning.ExcludeQtyReservation'' THEN N''PLANNING_BIT''
    END,
    ColumnName = SUBSTRING(change.FieldKey, CHARINDEX(N''.'', change.FieldKey) + 1, 200),
    TextType = CASE WHEN change.FieldKey LIKE N''ProductText.%'' THEN UPPER(PARSENAME(change.FieldKey, 2)) END,
    Lang = CASE WHEN change.FieldKey LIKE N''ProductText.%'' THEN PARSENAME(change.FieldKey, 1) END
  FROM #ErpUvozSprememba AS change
  WHERE change.Reason IS NULL;

  UPDATE #ErpUvozSprememba SET Reason = N''Polje nima mesta v katalogu PIM; gre samo v vrsto za SAOP.''
  WHERE Reason IS NULL AND Kind IS NULL;

  /* Logicne vrednosti: iste besede, ki jih sprejme SaopDocumentBuilder, in se »ja/yes/x«. */
  UPDATE #ErpUvozSprememba SET BitValue = CASE
      WHEN LOWER(Value) IN (N''1'', N''true'', N''da'', N''d'', N''y'', N''yes'', N''ja'', N''x'') THEN 1
      WHEN LOWER(Value) IN (N''0'', N''false'', N''ne'', N''n'', N''no'') THEN 0 END
  WHERE Reason IS NULL AND Kind IN (N''PRODUCT_BIT'', N''PLANNING_BIT'');
  UPDATE #ErpUvozSprememba SET Reason = CONCAT(N''Vrednost »'', Value, N''« ni da ali ne.'')
  WHERE Reason IS NULL AND Kind IN (N''PRODUCT_BIT'', N''PLANNING_BIT'') AND BitValue IS NULL;

  /* Stevila: decimalna vejica ali pika; prazno pomeni izprazni. */
  UPDATE #ErpUvozSprememba SET NumberValue = TRY_CONVERT(decimal(19,4), REPLACE(REPLACE(Value, N'' '', N''''), N'','', N''.''))
  WHERE Reason IS NULL AND Kind = N''COMMERCIAL_NUMBER'';
  UPDATE #ErpUvozSprememba SET Reason = CONCAT(N''Vrednost »'', Value, N''« ni stevilo.'')
  WHERE Reason IS NULL AND Kind = N''COMMERCIAL_NUMBER'' AND Value IS NOT NULL AND NumberValue IS NULL;

  /* Predolgo besedilo bi podrlo cel paket (prirezovanje), zato odpade samo ta vrstica. */
  UPDATE #ErpUvozSprememba SET Reason = N''Vrednost je daljsa, kot jo polje sprejme.''
  WHERE Reason IS NULL AND Value IS NOT NULL
    AND ((Kind = N''PRODUCT_TEXT'' AND LEN(Value) > COL_LENGTH(N''canon.Product'', ColumnName) / 2)
      OR (Kind = N''COMMERCIAL_TEXT'' AND LEN(Value) > COL_LENGTH(N''canon.ProductCommercial'', ColumnName) / 2));

  UPDATE #ErpUvozSprememba SET Reason = N''Logicnega polja ni mogoce izprazniti.''
  WHERE Reason IS NULL AND Kind IN (N''PRODUCT_BIT'', N''PLANNING_BIT'') AND Value IS NULL;

  DECLARE @BatchId uniqueidentifier = NEWID();
  EXEC pim.SetChangeContext @ChangeSource = N''EXCEL'', @ChangedBy = @Actor, @BatchId = @BatchId, @Note = @Note;

  BEGIN TRY
    BEGIN TRANSACTION;

    /* Zgodovina za polja, ki jih sprozilci ne belezijo (VatRateId, PriceListCode, planiranje).
       Serija nastane prva, da jo sprozilci spodaj najdejo po istem BatchId in je ne podvojijo. */
    INSERT pim.ProductChangeBatch (BatchId, ChangeSource, ChangedBy, OrganizationId, Note)
    VALUES (@BatchId, N''EXCEL'', @Actor, @OrganizationId, @Note);
    DECLARE @ChangeBatchId bigint = SCOPE_IDENTITY();

    INSERT pim.ProductFieldHistory (ChangeBatchId, OrganizationId, ProductId, ItemID, FieldKey, CanonTable, CanonColumn, Owner, OldValue, NewValue)
    SELECT @ChangeBatchId, product.OrganizationId, product.ProductId, product.ItemID, change.FieldKey,
      CASE WHEN change.Kind = N''PLANNING_BIT'' THEN N''canon.ProductPlanning'' ELSE N''canon.Product'' END,
      CASE WHEN change.Kind = N''PLANNING_BIT'' THEN N''ExcludeQuantityReservation'' ELSE change.ColumnName END,
      N''SAOP'', staro.OldValue,
      CASE WHEN change.Kind = N''PLANNING_BIT'' THEN CONVERT(nvarchar(400), change.BitValue) ELSE CONVERT(nvarchar(400), change.Value) END
    FROM #ErpUvozSprememba AS change
    INNER JOIN canon.Product AS product ON product.ProductId = change.ProductId
    LEFT JOIN canon.ProductPlanning AS planning ON planning.ProductId = change.ProductId
    CROSS APPLY (SELECT OldValue = CASE change.FieldKey
        WHEN N''Product.VatRateId'' THEN CONVERT(nvarchar(400), product.VatRateId)
        WHEN N''Product.PriceListCode'' THEN CONVERT(nvarchar(400), product.PriceListCode)
        WHEN N''Planning.ExcludeQtyReservation'' THEN CONVERT(nvarchar(400), planning.ExcludeQuantityReservation) END) AS staro
    WHERE change.Reason IS NULL
      AND change.FieldKey IN (N''Product.VatRateId'', N''Product.PriceListCode'', N''Planning.ExcludeQtyReservation'')
      AND EXISTS (SELECT staro.OldValue
                  EXCEPT SELECT CASE WHEN change.Kind = N''PLANNING_BIT'' THEN CONVERT(nvarchar(400), change.BitValue) ELSE CONVERT(nvarchar(400), change.Value) END);

    /* canon.Product — ena posodobitev, en sprozilec zgodovine (TR_Product_FieldHistory). */
    ;WITH vrtenje AS
    (
      SELECT ProductId,
        HasEAN = MAX(CASE WHEN FieldKey = N''Product.EAN'' THEN 1 ELSE 0 END), EAN = MAX(CASE WHEN FieldKey = N''Product.EAN'' THEN Value END),
        HasUoM = MAX(CASE WHEN FieldKey = N''Product.UoM'' THEN 1 ELSE 0 END), UoM = MAX(CASE WHEN FieldKey = N''Product.UoM'' THEN Value END),
        HasVat = MAX(CASE WHEN FieldKey = N''Product.VatRateId'' THEN 1 ELSE 0 END), VatRateId = MAX(CASE WHEN FieldKey = N''Product.VatRateId'' THEN Value END),
        HasGroup = MAX(CASE WHEN FieldKey = N''Product.ItemGroup'' THEN 1 ELSE 0 END), ItemGroup = MAX(CASE WHEN FieldKey = N''Product.ItemGroup'' THEN Value END),
        HasAccounting = MAX(CASE WHEN FieldKey = N''Product.AccountingGroup'' THEN 1 ELSE 0 END), AccountingGroup = MAX(CASE WHEN FieldKey = N''Product.AccountingGroup'' THEN Value END),
        HasDepartment = MAX(CASE WHEN FieldKey = N''Product.Department'' THEN 1 ELSE 0 END), Department = MAX(CASE WHEN FieldKey = N''Product.Department'' THEN Value END),
        HasDiscount = MAX(CASE WHEN FieldKey = N''Product.DiscountGroup'' THEN 1 ELSE 0 END), DiscountGroup = MAX(CASE WHEN FieldKey = N''Product.DiscountGroup'' THEN Value END),
        HasPriceList = MAX(CASE WHEN FieldKey = N''Product.PriceListCode'' THEN 1 ELSE 0 END), PriceListCode = MAX(CASE WHEN FieldKey = N''Product.PriceListCode'' THEN Value END),
        HasSupplier = MAX(CASE WHEN FieldKey = N''Product.Supplier'' THEN 1 ELSE 0 END), Supplier = MAX(CASE WHEN FieldKey = N''Product.Supplier'' THEN Value END),
        HasManufacturer = MAX(CASE WHEN FieldKey = N''Product.Manufacturer'' THEN 1 ELSE 0 END), Manufacturer = MAX(CASE WHEN FieldKey = N''Product.Manufacturer'' THEN Value END),
        HasWebPublish = MAX(CASE WHEN FieldKey = N''Product.WebPublish'' THEN 1 ELSE 0 END), WebPublish = CONVERT(bit, MAX(CASE WHEN FieldKey = N''Product.WebPublish'' THEN CONVERT(int, BitValue) END)),
        HasIsActive = MAX(CASE WHEN FieldKey = N''Product.IsActive'' THEN 1 ELSE 0 END), IsActive = CONVERT(bit, MAX(CASE WHEN FieldKey = N''Product.IsActive'' THEN CONVERT(int, BitValue) END))
      FROM #ErpUvozSprememba
      WHERE Reason IS NULL AND Kind IN (N''PRODUCT_TEXT'', N''PRODUCT_BIT'')
      GROUP BY ProductId
    )
    UPDATE product SET
      EAN = CASE WHEN vrtenje.HasEAN = 1 THEN vrtenje.EAN ELSE product.EAN END,
      UoM = CASE WHEN vrtenje.HasUoM = 1 THEN vrtenje.UoM ELSE product.UoM END,
      VatRateId = CASE WHEN vrtenje.HasVat = 1 THEN vrtenje.VatRateId ELSE product.VatRateId END,
      ItemGroup = CASE WHEN vrtenje.HasGroup = 1 THEN vrtenje.ItemGroup ELSE product.ItemGroup END,
      AccountingGroup = CASE WHEN vrtenje.HasAccounting = 1 THEN vrtenje.AccountingGroup ELSE product.AccountingGroup END,
      Department = CASE WHEN vrtenje.HasDepartment = 1 THEN vrtenje.Department ELSE product.Department END,
      DiscountGroup = CASE WHEN vrtenje.HasDiscount = 1 THEN vrtenje.DiscountGroup ELSE product.DiscountGroup END,
      PriceListCode = CASE WHEN vrtenje.HasPriceList = 1 THEN vrtenje.PriceListCode ELSE product.PriceListCode END,
      Supplier = CASE WHEN vrtenje.HasSupplier = 1 THEN vrtenje.Supplier ELSE product.Supplier END,
      Manufacturer = CASE WHEN vrtenje.HasManufacturer = 1 THEN vrtenje.Manufacturer ELSE product.Manufacturer END,
      WebPublish = CASE WHEN vrtenje.HasWebPublish = 1 THEN vrtenje.WebPublish ELSE product.WebPublish END,
      IsActive = CASE WHEN vrtenje.HasIsActive = 1 THEN vrtenje.IsActive ELSE product.IsActive END
    FROM canon.Product AS product
    INNER JOIN vrtenje ON vrtenje.ProductId = product.ProductId;

    /* canon.ProductCommercial — vrstica nastane, ce je izdelek se nima. */
    ;WITH vrtenje AS
    (
      SELECT ProductId,
        HasNet = MAX(CASE WHEN FieldKey = N''ProductCommercial.NetWeight'' THEN 1 ELSE 0 END), NetWeight = MAX(CASE WHEN FieldKey = N''ProductCommercial.NetWeight'' THEN NumberValue END),
        HasGross = MAX(CASE WHEN FieldKey = N''ProductCommercial.GrossWeight'' THEN 1 ELSE 0 END), GrossWeight = MAX(CASE WHEN FieldKey = N''ProductCommercial.GrossWeight'' THEN NumberValue END),
        HasVolume = MAX(CASE WHEN FieldKey = N''ProductCommercial.Volume'' THEN 1 ELSE 0 END), Volume = MAX(CASE WHEN FieldKey = N''ProductCommercial.Volume'' THEN NumberValue END),
        HasLength = MAX(CASE WHEN FieldKey = N''ProductCommercial.PackageLength'' THEN 1 ELSE 0 END), PackageLength = MAX(CASE WHEN FieldKey = N''ProductCommercial.PackageLength'' THEN NumberValue END),
        HasWidth = MAX(CASE WHEN FieldKey = N''ProductCommercial.PackageWidth'' THEN 1 ELSE 0 END), PackageWidth = MAX(CASE WHEN FieldKey = N''ProductCommercial.PackageWidth'' THEN NumberValue END),
        HasHeight = MAX(CASE WHEN FieldKey = N''ProductCommercial.PackageHeight'' THEN 1 ELSE 0 END), PackageHeight = MAX(CASE WHEN FieldKey = N''ProductCommercial.PackageHeight'' THEN NumberValue END),
        HasPak1 = MAX(CASE WHEN FieldKey = N''ProductCommercial.Pak1'' THEN 1 ELSE 0 END), Pak1 = MAX(CASE WHEN FieldKey = N''ProductCommercial.Pak1'' THEN NumberValue END),
        HasPak2 = MAX(CASE WHEN FieldKey = N''ProductCommercial.Pak2'' THEN 1 ELSE 0 END), Pak2 = MAX(CASE WHEN FieldKey = N''ProductCommercial.Pak2'' THEN NumberValue END),
        HasTariff = MAX(CASE WHEN FieldKey = N''ProductCommercial.CustomsTariff'' THEN 1 ELSE 0 END), CustomsTariff = MAX(CASE WHEN FieldKey = N''ProductCommercial.CustomsTariff'' THEN Value END),
        HasCountry = MAX(CASE WHEN FieldKey = N''ProductCommercial.CountryOfOrigin'' THEN 1 ELSE 0 END), CountryOfOrigin = MAX(CASE WHEN FieldKey = N''ProductCommercial.CountryOfOrigin'' THEN Value END),
        HasUnit = MAX(CASE WHEN FieldKey = N''ProductCommercial.DimensionUnit'' THEN 1 ELSE 0 END), DimensionUnit = MAX(CASE WHEN FieldKey = N''ProductCommercial.DimensionUnit'' THEN Value END)
      FROM #ErpUvozSprememba
      WHERE Reason IS NULL AND Kind IN (N''COMMERCIAL_NUMBER'', N''COMMERCIAL_TEXT'')
      GROUP BY ProductId
    )
    MERGE canon.ProductCommercial AS target
    USING vrtenje AS source ON target.ProductId = source.ProductId
    WHEN MATCHED THEN UPDATE SET
      NetWeight = CASE WHEN source.HasNet = 1 THEN source.NetWeight ELSE target.NetWeight END,
      GrossWeight = CASE WHEN source.HasGross = 1 THEN source.GrossWeight ELSE target.GrossWeight END,
      Volume = CASE WHEN source.HasVolume = 1 THEN source.Volume ELSE target.Volume END,
      PackageLength = CASE WHEN source.HasLength = 1 THEN source.PackageLength ELSE target.PackageLength END,
      PackageWidth = CASE WHEN source.HasWidth = 1 THEN source.PackageWidth ELSE target.PackageWidth END,
      PackageHeight = CASE WHEN source.HasHeight = 1 THEN source.PackageHeight ELSE target.PackageHeight END,
      Pak1 = CASE WHEN source.HasPak1 = 1 THEN source.Pak1 ELSE target.Pak1 END,
      Pak2 = CASE WHEN source.HasPak2 = 1 THEN source.Pak2 ELSE target.Pak2 END,
      CustomsTariff = CASE WHEN source.HasTariff = 1 THEN source.CustomsTariff ELSE target.CustomsTariff END,
      CountryOfOrigin = CASE WHEN source.HasCountry = 1 THEN source.CountryOfOrigin ELSE target.CountryOfOrigin END,
      DimensionUnit = CASE WHEN source.HasUnit = 1 THEN source.DimensionUnit ELSE target.DimensionUnit END
    WHEN NOT MATCHED THEN INSERT
      (ProductId, NetWeight, GrossWeight, Volume, PackageLength, PackageWidth, PackageHeight, Pak1, Pak2, CustomsTariff, CountryOfOrigin, DimensionUnit)
      VALUES (source.ProductId, source.NetWeight, source.GrossWeight, source.Volume, source.PackageLength, source.PackageWidth,
              source.PackageHeight, source.Pak1, source.Pak2, source.CustomsTariff, source.CountryOfOrigin, source.DimensionUnit);

    /* ERP besedila (TITLE_ERP, TITLE_ERP2, SEARCH_NAME) — spletnih (WEB_TITLE, DESCRIPTION) se ne dotakne. */
    DELETE textValue
    FROM canon.ProductText AS textValue
    INNER JOIN #ErpUvozSprememba AS change
      ON change.ProductId = textValue.ProductId AND change.TextType = textValue.TextType AND change.Lang = textValue.Lang
    WHERE change.Reason IS NULL AND change.Kind = N''TEXT'' AND change.Value IS NULL;

    MERGE canon.ProductText AS target
    USING (SELECT ProductId, Lang, TextType, Value FROM #ErpUvozSprememba WHERE Reason IS NULL AND Kind = N''TEXT'' AND Value IS NOT NULL) AS source
    ON target.ProductId = source.ProductId AND target.Lang = source.Lang AND target.TextType = source.TextType
    WHEN MATCHED AND ISNULL(target.Value, N'''') <> source.Value THEN UPDATE SET Value = source.Value
    WHEN NOT MATCHED THEN INSERT (ProductId, Lang, TextType, Value) VALUES (source.ProductId, source.Lang, source.TextType, source.Value);

    /* ERP atribut (Garancija) — kljuc je ime, kot pri pim.SaveProductAttributesBulk. */
    DELETE attributeValue
    FROM canon.ProductAttribute AS attributeValue
    INNER JOIN #ErpUvozSprememba AS change
      ON change.ProductId = attributeValue.ProductId AND change.ColumnName = attributeValue.AttributeCode
    WHERE change.Reason IS NULL AND change.Kind = N''ATTRIBUTE'' AND change.Value IS NULL;

    MERGE canon.ProductAttribute AS target
    USING (SELECT ProductId, AttributeCode = ColumnName, Value FROM #ErpUvozSprememba WHERE Reason IS NULL AND Kind = N''ATTRIBUTE'' AND Value IS NOT NULL) AS source
    ON target.ProductId = source.ProductId AND target.AttributeCode = source.AttributeCode
    WHEN MATCHED AND ISNULL(target.Value, N'''') <> source.Value THEN UPDATE SET Value = source.Value
    WHEN NOT MATCHED THEN INSERT (ProductId, AttributeCode, Value) VALUES (source.ProductId, source.AttributeCode, source.Value);

    /* Kljukica »izloci iz rezervacije zaloge«. */
    MERGE canon.ProductPlanning AS target
    USING (SELECT ProductId, BitValue FROM #ErpUvozSprememba WHERE Reason IS NULL AND Kind = N''PLANNING_BIT'') AS source
    ON target.ProductId = source.ProductId
    WHEN MATCHED AND target.ExcludeQuantityReservation <> source.BitValue
      THEN UPDATE SET ExcludeQuantityReservation = source.BitValue, UpdatedUtc = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT (ProductId, ExcludeQuantityReservation) VALUES (source.ProductId, source.BitValue);

    /* Serija brez ene same vrstice zgodovine ni sprememba. */
    DELETE batch FROM pim.ProductChangeBatch AS batch
    WHERE batch.BatchId = @BatchId
      AND NOT EXISTS (SELECT 1 FROM pim.ProductFieldHistory AS history WHERE history.ChangeBatchId = batch.ChangeBatchId);

    COMMIT TRANSACTION;
  END TRY
  BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    EXEC pim.ClearChangeContext;
    THROW;
  END CATCH;

  EXEC pim.ClearChangeContext;

  DECLARE @ProductIdsJson nvarchar(max) =
    (SELECT N''['' + STRING_AGG(CONVERT(nvarchar(max), izdelek.ProductId), N'','') + N'']''
     FROM (SELECT DISTINCT ProductId FROM #ErpUvozSprememba WHERE Reason IS NULL) AS izdelek);
  IF @ProductIdsJson IS NOT NULL
    EXEC val.RunValidationForProducts @ProductIdsJson = @ProductIdsJson;

  SELECT ChangedCount = (SELECT COUNT_BIG(*) FROM #ErpUvozSprememba WHERE Reason IS NULL),
         ProductCount = (SELECT COUNT_BIG(DISTINCT ProductId) FROM #ErpUvozSprememba WHERE Reason IS NULL),
         SkippedCount = (SELECT COUNT_BIG(*) FROM #ErpUvozSprememba WHERE Reason IS NOT NULL);

  SELECT ProductId, FieldKey, Reason FROM #ErpUvozSprememba WHERE Reason IS NOT NULL ORDER BY ProductId, FieldKey;
END;');

/* ── 2) pim.SaveProductMediaBulk ─────────────────────────────────────────────── */
EXEC(N'CREATE OR ALTER PROCEDURE pim.SaveProductMediaBulk
  @OrganizationId int,
  @ChangesJson nvarchar(max),   /* [{"productId":1,"kind":"IMAGES","urls":["..."],"remove":["..."]}, {"productId":1,"kind":"DOCUMENTS",...}] */
  @Actor nvarchar(200),
  @Note nvarchar(400) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  SET @Actor = NULLIF(LTRIM(RTRIM(@Actor)), N'''');
  IF @Actor IS NULL THROW 52955, N''Kdo zapisuje slike in dokumente, mora biti znano (Actor).'', 1;
  IF ISJSON(@ChangesJson) <> 1 THROW 52956, N''Seznam slik in dokumentov ni veljaven JSON.'', 1;

  CREATE TABLE #MedijUvozVnos (ProductId bigint NOT NULL, Kind nvarchar(20) COLLATE DATABASE_DEFAULT NOT NULL, UrlsJson nvarchar(max) COLLATE DATABASE_DEFAULT NULL, RemoveJson nvarchar(max) COLLATE DATABASE_DEFAULT NULL);
  INSERT #MedijUvozVnos (ProductId, Kind, UrlsJson, RemoveJson)
  SELECT parsed.productId, UPPER(LTRIM(RTRIM(parsed.kind))), parsed.urls, parsed.remove
  FROM OPENJSON(@ChangesJson)
    WITH (productId bigint N''$.productId'', kind nvarchar(20) N''$.kind'',
          urls nvarchar(max) N''$.urls'' AS JSON, remove nvarchar(max) N''$.remove'' AS JSON) AS parsed
  WHERE parsed.productId IS NOT NULL AND UPPER(LTRIM(RTRIM(parsed.kind))) IN (N''IMAGES'', N''DOCUMENTS'');

  CREATE TABLE #MedijUvozPreskok (ProductId bigint NOT NULL PRIMARY KEY, Reason nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL);
  INSERT #MedijUvozPreskok (ProductId, Reason)
  SELECT DISTINCT vnos.ProductId, N''Izdelek ne obstaja v tem podjetju.''
  FROM #MedijUvozVnos AS vnos
  WHERE NOT EXISTS (SELECT 1 FROM canon.Product AS product WHERE product.ProductId = vnos.ProductId AND product.OrganizationId = @OrganizationId);
  DELETE vnos FROM #MedijUvozVnos AS vnos INNER JOIN #MedijUvozPreskok AS preskok ON preskok.ProductId = vnos.ProductId;

  /* Seznam iz celice: vrstni red je vrstni red v celici, podvojen naslov velja enkrat. */
  CREATE TABLE #MedijUvozSeznam (Id int IDENTITY(1,1) PRIMARY KEY, ProductId bigint NOT NULL, Kind nvarchar(20) COLLATE DATABASE_DEFAULT NOT NULL,
    Url nvarchar(2000) COLLATE DATABASE_DEFAULT NOT NULL, Position int NOT NULL);
  INSERT #MedijUvozSeznam (ProductId, Kind, Url, Position)
  SELECT naslov.ProductId, naslov.Kind, naslov.Url,
    ROW_NUMBER() OVER (PARTITION BY naslov.ProductId, naslov.Kind ORDER BY naslov.Prvi)
  FROM
  (
    SELECT vnos.ProductId, vnos.Kind, Url = LTRIM(RTRIM(url.value)), Prvi = MIN(CONVERT(int, url.[key]))
    FROM #MedijUvozVnos AS vnos
    CROSS APPLY OPENJSON(vnos.UrlsJson) AS url
    WHERE NULLIF(LTRIM(RTRIM(url.value)), N'''') IS NOT NULL AND LEN(LTRIM(RTRIM(url.value))) <= 1000
    GROUP BY vnos.ProductId, vnos.Kind, LTRIM(RTRIM(url.value))
  ) AS naslov;

  /* Naslov, ki je hkrati med slikami in dokumenti, je slika. */
  DELETE dokument FROM #MedijUvozSeznam AS dokument
  WHERE dokument.Kind = N''DOCUMENTS''
    AND EXISTS (SELECT 1 FROM #MedijUvozSeznam AS slika WHERE slika.Kind = N''IMAGES'' AND slika.ProductId = dokument.ProductId AND slika.Url = dokument.Url);

  CREATE TABLE #MedijUvozOdstrani (ProductId bigint NOT NULL, Url nvarchar(2000) COLLATE DATABASE_DEFAULT NOT NULL);
  INSERT #MedijUvozOdstrani (ProductId, Url)
  SELECT DISTINCT vnos.ProductId, LTRIM(RTRIM(url.value))
  FROM #MedijUvozVnos AS vnos
  CROSS APPLY OPENJSON(vnos.RemoveJson) AS url
  WHERE NULLIF(LTRIM(RTRIM(url.value)), N'''') IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM #MedijUvozSeznam AS seznam WHERE seznam.ProductId = vnos.ProductId AND seznam.Url = LTRIM(RTRIM(url.value)));

  DECLARE @Dokumenti TABLE (ProductId bigint NOT NULL, Role nvarchar(400) NULL, OldUrl nvarchar(2000) NULL, NewUrl nvarchar(2000) NULL);
  DECLARE @Slike TABLE (ProductId bigint NOT NULL, Action nvarchar(10) NOT NULL);

  DECLARE @BatchId uniqueidentifier = NEWID();
  EXEC pim.SetChangeContext @ChangeSource = N''EXCEL'', @ChangedBy = @Actor, @BatchId = @BatchId, @Note = @Note;

  BEGIN TRY
    BEGIN TRANSACTION;

    /* 1) Odstrani, kar je aplikacija izrecno poslala v "remove" (iz obeh tabel). */
    DELETE media OUTPUT deleted.ProductId, N''DELETE'' INTO @Slike (ProductId, Action)
    FROM canon.ProductMedia AS media
    INNER JOIN #MedijUvozOdstrani AS odstrani ON odstrani.ProductId = media.ProductId AND odstrani.Url = media.Url;

    DELETE document OUTPUT deleted.ProductId, deleted.Role, deleted.Url, NULL INTO @Dokumenti (ProductId, Role, OldUrl, NewUrl)
    FROM canon.ProductDocument AS document
    INNER JOIN #MedijUvozOdstrani AS odstrani ON odstrani.ProductId = document.ProductId AND odstrani.Url = document.Url;

    /* 2) Slike. Naslov, ki je bil med dokumenti, se preseli med slike. */
    DELETE document OUTPUT deleted.ProductId, deleted.Role, deleted.Url, NULL INTO @Dokumenti (ProductId, Role, OldUrl, NewUrl)
    FROM canon.ProductDocument AS document
    INNER JOIN #MedijUvozSeznam AS seznam ON seznam.Kind = N''IMAGES'' AND seznam.ProductId = document.ProductId AND seznam.Url = document.Url;

    /* Isti naslov dvakrat pri istem izdelku: ostane ena vrstica. */
    DELETE media OUTPUT deleted.ProductId, N''DELETE'' INTO @Slike (ProductId, Action)
    FROM canon.ProductMedia AS media
    WHERE EXISTS (SELECT 1 FROM #MedijUvozSeznam AS seznam WHERE seznam.Kind = N''IMAGES'' AND seznam.ProductId = media.ProductId AND seznam.Url = media.Url)
      AND EXISTS (SELECT 1 FROM canon.ProductMedia AS prva
                  WHERE prva.ProductId = media.ProductId AND prva.Url = media.Url AND prva.ProductMediaId < media.ProductMediaId);

    /* Vrstni red: najprej vse vrstice teh izdelkov odmaknemo, sicer bi se prestavljanje
       spotaknilo ob UQ_CanonProductMedia_ProductRoleSort (izdelek, vloga, zaporedje). */
    UPDATE media SET SortOrder = media.SortOrder + 1000000
    FROM canon.ProductMedia AS media
    WHERE media.ProductId IN (SELECT ProductId FROM #MedijUvozVnos WHERE Kind = N''IMAGES'');

    UPDATE media SET
      Role = CASE WHEN seznam.Position = 1 THEN N''PRIMARY'' WHEN media.Role = N''AMBIENT'' THEN N''AMBIENT'' ELSE N''GALLERY'' END,
      SortOrder = seznam.Position
    FROM canon.ProductMedia AS media
    INNER JOIN #MedijUvozSeznam AS seznam ON seznam.Kind = N''IMAGES'' AND seznam.ProductId = media.ProductId AND seznam.Url = media.Url;

    INSERT canon.ProductMedia (ProductId, Url, Role, SortOrder)
    OUTPUT inserted.ProductId, N''INSERT'' INTO @Slike (ProductId, Action)
    SELECT seznam.ProductId, seznam.Url, CASE WHEN seznam.Position = 1 THEN N''PRIMARY'' ELSE N''GALLERY'' END, seznam.Position
    FROM #MedijUvozSeznam AS seznam
    WHERE seznam.Kind = N''IMAGES''
      AND NOT EXISTS (SELECT 1 FROM canon.ProductMedia AS media WHERE media.ProductId = seznam.ProductId AND media.Url = seznam.Url);

    /* Kar v tabeli slik ostane izven seznama (npr. dokument, shranjen med mediji), gre za slike. */
    ;WITH ostale AS
    (
      SELECT media.SortOrder,
        Novo = (SELECT COUNT(*) FROM #MedijUvozSeznam AS seznam WHERE seznam.Kind = N''IMAGES'' AND seznam.ProductId = media.ProductId)
               + ROW_NUMBER() OVER (PARTITION BY media.ProductId ORDER BY media.SortOrder)
      FROM canon.ProductMedia AS media
      WHERE media.SortOrder > 1000000
        AND media.ProductId IN (SELECT ProductId FROM #MedijUvozVnos WHERE Kind = N''IMAGES'')
    )
    UPDATE ostale SET SortOrder = Novo;

    /* 3) Dokumenti: obstojeci ostanejo s svojo vlogo, nov dobi vlogo "Dokument". */
    UPDATE document SET SortOrder = seznam.Position
    FROM canon.ProductDocument AS document
    INNER JOIN #MedijUvozSeznam AS seznam ON seznam.Kind = N''DOCUMENTS'' AND seznam.ProductId = document.ProductId AND seznam.Url = document.Url;

    INSERT canon.ProductDocument (ProductId, Role, Url, Title, SortOrder)
    OUTPUT inserted.ProductId, inserted.Role, NULL, inserted.Url INTO @Dokumenti (ProductId, Role, OldUrl, NewUrl)
    SELECT seznam.ProductId, N''Dokument'', seznam.Url, NULL, seznam.Position
    FROM #MedijUvozSeznam AS seznam
    WHERE seznam.Kind = N''DOCUMENTS''
      AND NOT EXISTS (SELECT 1 FROM canon.ProductDocument AS document WHERE document.ProductId = seznam.ProductId AND document.Url = seznam.Url)
      AND NOT EXISTS (SELECT 1 FROM canon.ProductMedia AS media WHERE media.ProductId = seznam.ProductId AND media.Url = seznam.Url);

    /* canon.ProductDocument nima sprozilca zgodovine; vrstice zapisemo sami. */
    IF EXISTS (SELECT 1 FROM @Dokumenti)
    BEGIN
      DECLARE @ChangeBatchId bigint = (SELECT ChangeBatchId FROM pim.ProductChangeBatch WHERE BatchId = @BatchId);
      IF @ChangeBatchId IS NULL
      BEGIN
        INSERT pim.ProductChangeBatch (BatchId, ChangeSource, ChangedBy, OrganizationId, Note)
        VALUES (@BatchId, N''EXCEL'', @Actor, @OrganizationId, @Note);
        SET @ChangeBatchId = SCOPE_IDENTITY();
      END;
      INSERT pim.ProductFieldHistory (ChangeBatchId, OrganizationId, ProductId, ItemID, FieldKey, CanonTable, CanonColumn, Owner, OldValue, NewValue)
      SELECT @ChangeBatchId, product.OrganizationId, product.ProductId, product.ItemID, N''ProductDocument.Url'',
        N''canon.ProductDocument'', ISNULL(dokument.Role, N''Url''), N''PIM'', LEFT(dokument.OldUrl, 400), LEFT(dokument.NewUrl, 400)
      FROM @Dokumenti AS dokument
      INNER JOIN canon.Product AS product ON product.ProductId = dokument.ProductId;
    END;

    COMMIT TRANSACTION;
  END TRY
  BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    EXEC pim.ClearChangeContext;
    THROW;
  END CATCH;

  EXEC pim.ClearChangeContext;

  DECLARE @ProductIdsJson nvarchar(max) =
    (SELECT N''['' + STRING_AGG(CONVERT(nvarchar(max), izdelek.ProductId), N'','') + N'']''
     FROM (SELECT DISTINCT ProductId FROM #MedijUvozVnos) AS izdelek);
  IF @ProductIdsJson IS NOT NULL
    EXEC val.RunValidationForProducts @ProductIdsJson = @ProductIdsJson;

  SELECT AddedCount = (SELECT COUNT_BIG(*) FROM @Slike WHERE Action = N''INSERT'') + (SELECT COUNT_BIG(*) FROM @Dokumenti WHERE NewUrl IS NOT NULL),
         RemovedCount = (SELECT COUNT_BIG(*) FROM @Slike WHERE Action = N''DELETE'') + (SELECT COUNT_BIG(*) FROM @Dokumenti WHERE NewUrl IS NULL),
         ProductCount = (SELECT COUNT_BIG(DISTINCT ProductId) FROM #MedijUvozVnos),
         SkippedCount = (SELECT COUNT_BIG(*) FROM #MedijUvozPreskok);

  SELECT ProductId, Reason FROM #MedijUvozPreskok ORDER BY ProductId;
END;');

/* ── Preverbe ─────────────────────────────────────────────────────────────────── */
IF OBJECT_ID(N'pim.SaveProductErpFieldsBulk', N'P') IS NULL
  THROW 52960, N'245: pim.SaveProductErpFieldsBulk ni nastala.', 1;
IF OBJECT_ID(N'pim.SaveProductMediaBulk', N'P') IS NULL
  THROW 52961, N'245: pim.SaveProductMediaBulk ni nastala.', 1;
IF NOT EXISTS (SELECT 1 FROM out.SaopXmlField WHERE TargetKind = N'SAOP_PRODUCT' AND FieldKey = N'Planning.ExcludeQtyReservation')
  THROW 52962, N'245: register ERP polj nima kljukice Planning.ExcludeQtyReservation.', 1;
