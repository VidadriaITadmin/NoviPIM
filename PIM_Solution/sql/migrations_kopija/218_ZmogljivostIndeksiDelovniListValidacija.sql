/*
  218 — zmogljivost: indeksi, delovni list brez pogleda canon.FieldValue, mnozicna nadzorna
  plosca, hitra validacija ob shranjevanju in mnozicni zapis za uvoz.

  Analiza 2026-09-17 (lokalna baza DAVID\MSSQL19, 196.594 canon.Product, 2,5 M canon.ProductText,
  1,5 M val.ProductIssue, 4 M stock.Position, 12 M stock.LandingRecord), izmerjeno pred popravkom:

    intranet.GetProductWorkbook (2.000 izdelkov)      43-61 s   -> 1. del (stik canon.FieldValue
                                                                   s tabelno spremenljivko) 89 s
                                                                   od 90; ostalih pet delov < 0,2 s
    intranet.GetDashboard (eno podjetje)              12-16 s   -> stran jo klice za vsako podjetje
    pim.SaveProductTexts (ista vrednost, en izdelek)  10,7 s    -> EXEC val.RunValidation @ProductId
                                                                   traja 14-95 s (glej 195), hitra
                                                                   val.RunValidationForProduct 0,1-0,5 s
    stock.LandingRecord WHERE SyncRunId = @r          1,5-5,6 s -> brez indeksa; StockLandingWriter
                                                                   jo poganja vsakih 5 minut (dvakrat)
    intranet.GetStockOverview                         1,1-2,7 s -> stock.Position brez indeksa po SnapshotId
    intranet.GetProductListViews (vsa podjetja)       1,1-1,7 s -> canon.ProductText brez indeksa po TextType
    intranet.GetQualityOverview                       4,0-4,5 s -> CROSS APPLY COUNT na vsak izdelek podjetja
    intranet.GetProductList @ErpStatus                1,3-2,4 s -> val.ProductValidationState brez (profil, stanje)

  Kaj migracija naredi (vse ponovljivo; vsak korak preveri, ali je ze narejen):
    1. Indeksi (glej spodaj; vsak ima ob sebi poizvedbo, ki ga potrebuje).
    2. val.RunValidationForProduct — zagotovljena (195 zivi izven mape migracij, na TEST je morda ni).
    3. val.RunValidationForProducts — ista logika za seznam izdelkov (JSON), za mnozicni uvoz.
    4. pim.SaveProductTexts / SaveProductAttributes / SaveProductWebShops — validacija izdelka
       po shranjevanju prek val.RunValidationForProduct (0,1-0,5 s) namesto val.RunValidation (14-95 s).
    5. pim.SaveProductTextsBulk / SaveProductAttributesBulk — mnozicni zapis za uvoz delovnega
       lista (ProductWorkbookService.ApplyAsync): en MERGE, ena serija zgodovine, ena validacija.
    6. intranet.GetProductWorkbook — 1. del bere polja neposredno iz tabel (iste kode in vrednosti
       kot canon.FieldValue), ne prek pogleda; ostalo nespremenjeno.
    7. intranet.GetDashboard — mnozicni izracun stevcev (isti pomen kot 215).
    8. intranet.GetQualityOverview — odprte napake podjetja prebere enkrat (zacasna tabela), ne trikrat.
    9. val.ProductChannelReadiness (pogled) — stevci napak in zadrzkov mnozicno (GROUP BY), naziv
       neposredno iz canon.ProductText; intranet.GetQualityProducts (/kakovost/artikli) 24-39 s -> pod 2 s.
   10. intranet.GetStockByItem — meja @Take 200 -> 20.000: izvoz zaloge v enem klicu, ne v desetinah.
   11. intranet.GetCategoryTreeNodes — prevedene poti drevesa enkrat v zacasno tabelo, ne za vsako vozlisce.
   12. intranet.GetPriceChecks — nabor izdelkov v zacasni tabeli (statistika) namesto tabelne spremenljivke,
       naziv samo za vrnjeno stran.
   13. intranet.GetProductOrigin — pogoj, ki ustreza filtriranemu indeksu IX_ExtractedValue_Identity (17,8 s -> < 1 s).
   14. intranet.GetCategoryMappings — prevedene poti enkrat v zacasno tabelo (27,7 s -> < 1 s).
   15. intranet.GetCategoryTree — stevci izdelkov po kategoriji mnozicno (12,5 s -> < 1 s).
   16. intranet.GetStockOverview — LOOP JOIN pri zavrnjenih pozicijah (3,7 s -> ms).
   17. intranet.GetValidationIssues — @Take = 0 vrne samo profile (nadzorna plosca), brez seznama in kod napak.

  Migrator ne pozna locila GO, zato so procedure zavite v EXEC(N'...').
  Rocni korak po uvedbi: ni potreben. Priporocilo za instanco (ni del migracije, odlocitev
  skrbnika): cost threshold for parallelism 5 -> 50 (CXPACKET je bil najvecje cakanje), glej
  docs/DATABASE.md, razdelek 218.
*/

SET XACT_ABORT ON;

/* ── 1. Indeksi ─────────────────────────────────────────────────────────────────────────── */

/* Stock worker (StockLandingWriter): SELECT SUM(...) FROM stock.LandingRecord WHERE SyncRunId = @RunId
   — dvakrat na cikel (5 min), prej polni pregled 12 M vrstic (2 GB). */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'stock.LandingRecord') AND name = N'IX_StockLandingRecord_SyncRun')
  CREATE NONCLUSTERED INDEX IX_StockLandingRecord_SyncRun ON stock.LandingRecord (SyncRunId) INCLUDE (Status);

/* intranet.GetStockOverview / GetStockByItem / izvoz zaloge: stock.Position JOIN stock.Snapshot (IsActive = 1)
   — aktivnih je ~31.000 od 4 M pozicij, prej polni pregled. */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'stock.Position') AND name = N'IX_stock_Position_Snapshot')
  CREATE NONCLUSTERED INDEX IX_stock_Position_Snapshot ON stock.Position (SnapshotId) INCLUDE (MatchedProductId, Quantity, IncomingQuantity);

/* intranet.GetProductListViews (NoWebTitleCount), GetProductList @View = NO_WEB_TITLE:
   DISTINCT ProductId FROM canon.ProductText WHERE TextType = N'WEB_TITLE' — prej pregled 2,5 M vrstic. */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'canon.ProductText') AND name = N'IX_CanonProductText_TextType_Product')
  CREATE NONCLUSTERED INDEX IX_CanonProductText_TextType_Product ON canon.ProductText (TextType, ProductId) INCLUDE (Lang);

/* intranet.GetDashboard, GetQualityOverview, val.*: odprte napake s profilom in zahtevo.
   Obstojeci filtrirani indeks (IsActive = 1) dobi se ValidationProfileId, da stik s profilom ne
   potrebuje iskanja po kljucu za vsako od 1,36 M odprtih napak. */
IF NOT EXISTS
(
  SELECT 1 FROM sys.indexes AS i
  INNER JOIN sys.index_columns AS ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 1
  INNER JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id AND c.name = N'IssueCode'
  WHERE i.object_id = OBJECT_ID(N'val.ProductIssue') AND i.name = N'IX_ProductIssue_Active_ProductRequirement'
)
  CREATE NONCLUSTERED INDEX IX_ProductIssue_Active_ProductRequirement ON val.ProductIssue (ProductId, FieldRequirementId)
    INCLUDE (ValidationProfileId, IssueCode) WHERE IsActive = 1 WITH (DROP_EXISTING = ON);

/* Stran /zajem (PipelineReadService.GetInboundFlowsAsync): stevilo cakajocih in karanteniranih zapisov zaloge
   po konektorju. Vse razen 1.845 od 4,1 M vrstic je "Applied"; filtriran indeks drzi samo odprte, poizvedba
   pa je od 218 naprej omejena na ista dva stanja (prej pregled milijonov vrstic na konektor, 25-39 s). */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'stock.LandingRecord') AND name = N'IX_StockLandingRecord_Open')
  CREATE NONCLUSTERED INDEX IX_StockLandingRecord_Open ON stock.LandingRecord (OrganizationId, SourceConnectorId, Status)
    WHERE Status IN (N'Pending', N'Quarantined');

/* intranet.GetProductList @ErpStatus/@WebStatus (#ErpValid/#WebValid): stanje po profilu. */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'val.ProductValidationState') AND name = N'IX_ProductValidationState_Profile_Status')
  CREATE NONCLUSTERED INDEX IX_ProductValidationState_Profile_Status ON val.ProductValidationState (ValidationProfileId, Status, ProductId);

/* intranet.GetAdminPulse in zvonec v glavi: zadnji tek po (podjetje, postopek). Obstojeci indeks
   je po SourceCode, ne po Pipeline. */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'ops.PipelineRun') AND name = N'IX_PipelineRun_OrganizationPipelineStartedUtc')
  CREATE NONCLUSTERED INDEX IX_PipelineRun_OrganizationPipelineStartedUtc ON ops.PipelineRun (OrganizationId, Pipeline, StartedUtc DESC)
    INCLUDE (Status, EndedUtc, RowsRead, RowsFailed);

/* Zvonec v glavi vsake strani (AdminConsoleService.GetAttentionAsync, intranet.GetRecentAlerts): odprti alarmi. */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'ops.Alert') AND name = N'IX_Alert_Open')
  CREATE NONCLUSTERED INDEX IX_Alert_Open ON ops.Alert (OrganizationId, Severity, LastSeenUtc DESC) WHERE ResolvedUtc IS NULL;

/* Cene po ceniku (izvoz kataloga, cenik, GetProductCard): canon.ProductPrice po (cenik, aktivna, od). */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'canon.ProductPrice') AND name = N'IX_CanonProductPrice_ListActive')
  CREATE NONCLUSTERED INDEX IX_CanonProductPrice_ListActive ON canon.ProductPrice (PriceList, IsActive, ValidFrom) INCLUDE (ProductId, Net, VatRate);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'pim.ProductPrice') AND name = N'IX_PimProductPrice_ListActive')
  CREATE NONCLUSTERED INDEX IX_PimProductPrice_ListActive ON pim.ProductPrice (PriceList, IsActive, ValidFrom) INCLUDE (PimProductId, Net, VatRate);

/* Filtri in fasete seznama izdelkov (intranet.GetProductList, GetProductListFilters) ter izvoz kataloga:
   dobavitelj, proizvajalec, skupina, oddelek znotraj podjetja. */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'canon.Product') AND name = N'IX_CanonProduct_OrgSupplier')
  CREATE NONCLUSTERED INDEX IX_CanonProduct_OrgSupplier ON canon.Product (OrganizationId, Supplier) INCLUDE (ItemID);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'canon.Product') AND name = N'IX_CanonProduct_OrgManufacturer')
  CREATE NONCLUSTERED INDEX IX_CanonProduct_OrgManufacturer ON canon.Product (OrganizationId, Manufacturer) INCLUDE (ItemID);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'canon.Product') AND name = N'IX_CanonProduct_OrgItemGroup')
  CREATE NONCLUSTERED INDEX IX_CanonProduct_OrgItemGroup ON canon.Product (OrganizationId, ItemGroup) INCLUDE (ItemID);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'canon.Product') AND name = N'IX_CanonProduct_OrgActiveDepartment')
  CREATE NONCLUSTERED INDEX IX_CanonProduct_OrgActiveDepartment ON canon.Product (OrganizationId, IsActive, Department) INCLUDE (ItemID);

/* Kartica izdelka (intranet.GetProductOrigin): iskanje vhodnih zapisov po sifri/EAN v map.ExtractedValue (78 M vrstic,
   4 GB). Value je nvarchar(max) in ne more biti kljuc; filtriran indeks drzi samo tri identitetna polja (~2,9 M vrstic)
   z vrednostjo kot vkljucenim stolpcem, procedura pa se nanj omeji z istim pogojem. Izmerjeno pred: 17,8 s na vsako
   odprtje kartice. Gradnja indeksa prebere vso tabelo (nekaj minut). */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'map.ExtractedValue') AND name = N'IX_ExtractedValue_Identity')
  CREATE NONCLUSTERED INDEX IX_ExtractedValue_Identity ON map.ExtractedValue (TargetFieldCode, InboxId, RecordOrdinal) INCLUDE (Value)
    WHERE TargetFieldCode IN (N'Product.ItemID', N'Record.ItemID', N'Product.EAN');

/* ── 2.–8. Procedure ─────────────────────────────────────────────────────────────────────── */

/* ── RunValidationForProduct ── */
EXEC(N'CREATE OR ALTER PROCEDURE val.RunValidationForProduct
  @ProductId bigint
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;
  BEGIN TRY
    /* 147: obseg zahteve. Za vsak izdelek in vsak atribut, ki ga kaksna kategorija po verigi
       prednikov omenja, obvelja najblizja vrstica nabora (EXCLUDED pri otroku prekrije REQUIRED
       pri starsu). Zahteva z obsegom velja za izdelek, kadar je njena kategorija tista, kjer
       obveljala vrstica stoji, in raven ni EXCLUDED. */
    CREATE TABLE #Effective
      (ProductId bigint NOT NULL, CategoryTreeCode nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL,
       AttributeCode nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
       DefinedAtCategoryCode nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
       Level nvarchar(20) COLLATE DATABASE_DEFAULT NOT NULL,
       PRIMARY KEY (ProductId, CategoryTreeCode, AttributeCode));

    ;WITH assigned AS
    (
      SELECT DISTINCT product.ProductId, node.CategoryTreeCode, node.CategoryCode, node.ParentCategoryCode
      FROM canon.Product AS product
      INNER JOIN canon.ProductCategory AS productCategory ON productCategory.ProductId = product.ProductId
      INNER JOIN canon.WebSite AS site ON site.WebSiteCode = productCategory.WebSite
      INNER JOIN canon.Category AS node
        ON node.CategoryTreeCode = site.CategoryTreeCode AND node.CategoryPath = productCategory.CategoryPath
      WHERE product.IsActive = 1
        AND product.ProductId = @ProductId
    ),
    chain AS
    (
      SELECT ProductId, CategoryTreeCode, CategoryCode, ParentCategoryCode, 0 AS Depth FROM assigned
      UNION ALL
      SELECT chain.ProductId, parent.CategoryTreeCode, parent.CategoryCode, parent.ParentCategoryCode, chain.Depth + 1
      FROM chain
      INNER JOIN canon.Category AS parent
        ON parent.CategoryTreeCode = chain.CategoryTreeCode AND parent.CategoryCode = chain.ParentCategoryCode
      WHERE chain.Depth < 12
    ),
    ranked AS
    (
      SELECT chain.ProductId, chain.CategoryTreeCode, setRow.AttributeCode, chain.CategoryCode AS DefinedAtCategoryCode, setRow.Level,
        ROW_NUMBER() OVER (PARTITION BY chain.ProductId, chain.CategoryTreeCode, setRow.AttributeCode ORDER BY chain.Depth) AS PickRank
      FROM chain
      INNER JOIN canon.CategoryAttributeSet AS setRow
        ON setRow.CategoryTreeCode = chain.CategoryTreeCode AND setRow.CategoryCode = chain.CategoryCode AND setRow.IsActive = 1
    )
    INSERT #Effective (ProductId, CategoryTreeCode, AttributeCode, DefinedAtCategoryCode, Level)
    SELECT ProductId, CategoryTreeCode, AttributeCode, DefinedAtCategoryCode, Level FROM ranked WHERE PickRank = 1;

    /* Zahteva z obsegom -> koda atributa v registru (zahteva nosi slovensko ime). */
    CREATE TABLE #ScopedRequirement
      (FieldRequirementId int NOT NULL PRIMARY KEY, CategoryTreeCode nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL,
       CategoryCode nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL, AttributeCode nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL);
    INSERT #ScopedRequirement (FieldRequirementId, CategoryTreeCode, CategoryCode, AttributeCode)
    SELECT requirement.FieldRequirementId, requirement.CategoryTreeCode, requirement.CategoryCode, definition.AttributeCode
    FROM val.FieldRequirement AS requirement
    INNER JOIN canon.AttributeDefinition AS definition
      ON CONCAT(N''ProductAttribute.'', COALESCE(
           (SELECT TOP (1) Name FROM canon.AttributeTranslation WHERE AttributeCode = definition.AttributeCode AND LanguageCode = N''sl''),
           definition.AttributeCode)) = requirement.FieldCode
    WHERE requirement.CategoryCode IS NOT NULL;

    BEGIN TRANSACTION;
    ;WITH RequiredField AS
    (
      SELECT product.ProductId, profile.ValidationProfileId, requirement.FieldRequirementId, requirement.FieldCode
      FROM canon.Product product
      CROSS JOIN val.ValidationProfile profile
      INNER JOIN val.FieldRequirement requirement ON requirement.ValidationProfileId = profile.ValidationProfileId
      WHERE product.IsActive = 1 AND profile.IsActive = 1 AND requirement.IsActive = 1 AND requirement.IsRequired = 1
        AND product.ProductId = @ProductId
        /* 182: spletni profil velja samo za izdelek, ki je za to spletisce oznacen v PIM.
           Prej je CROSS JOIN vsak profil pripel na vsak izdelek, zato sta spletna profila
           odpirala napake tudi na 162.000 izdelkih, ki na splet sploh ne gredo. */
        AND (profile.Scope <> N''WEB'' OR EXISTS
          (SELECT 1 FROM pim.ProductWebShop shop
           WHERE shop.ProductId = product.ProductId
             AND shop.WebShopCode = profile.CategoryTreeCode
             AND shop.IsPublished = 1))
        AND (requirement.CategoryCode IS NULL OR EXISTS
          (SELECT 1 FROM #ScopedRequirement scoped
           INNER JOIN #Effective effective ON effective.ProductId = product.ProductId
             AND effective.CategoryTreeCode = scoped.CategoryTreeCode AND effective.AttributeCode = scoped.AttributeCode
             AND effective.DefinedAtCategoryCode = scoped.CategoryCode AND effective.Level <> N''EXCLUDED''
           WHERE scoped.FieldRequirementId = requirement.FieldRequirementId))
    ), MissingField AS
    (
      SELECT requiredField.*
      FROM RequiredField requiredField
      WHERE NOT EXISTS
      (
        SELECT 1 FROM canon.FieldValue fieldValue
        WHERE fieldValue.ProductId = requiredField.ProductId
          AND fieldValue.FieldCode = requiredField.FieldCode
          AND NULLIF(fieldValue.Value, N'''') IS NOT NULL
      )
    )
    MERGE val.ProductIssue AS target
    USING MissingField AS source
    ON target.ProductId = source.ProductId AND target.FieldRequirementId = source.FieldRequirementId
    WHEN MATCHED THEN UPDATE SET ValidationProfileId = source.ValidationProfileId, IssueCode = N''MISSING_REQUIRED_FIELD'', Message = CONCAT(N''Manjka obvezno polje: '', source.FieldCode), IsActive = 1, LastDetectedUtc = SYSUTCDATETIME(), ResolvedUtc = NULL
    WHEN NOT MATCHED THEN INSERT (ProductId, ValidationProfileId, FieldRequirementId, IssueCode, Message) VALUES (source.ProductId, source.ValidationProfileId, source.FieldRequirementId, N''MISSING_REQUIRED_FIELD'', CONCAT(N''Manjka obvezno polje: '', source.FieldCode));

    UPDATE issue SET IsActive = 0, ResolvedUtc = SYSUTCDATETIME()
    FROM val.ProductIssue issue
    INNER JOIN canon.Product product ON product.ProductId = issue.ProductId
    INNER JOIN val.ValidationProfile profile ON profile.ValidationProfileId = issue.ValidationProfileId
    WHERE issue.IsActive = 1
      AND product.ProductId = @ProductId
      /* 182: napaka se zapre tudi takrat, ko profil za ta izdelek ne velja vec — brez tega bi
         obstojece spletne napake ostale odprte, ceprav izdelek na to spletisce ne gre. */
      AND (NOT (profile.Scope <> N''WEB'' OR EXISTS
            (SELECT 1 FROM pim.ProductWebShop shop
             WHERE shop.ProductId = product.ProductId
               AND shop.WebShopCode = profile.CategoryTreeCode
               AND shop.IsPublished = 1))
      OR NOT EXISTS
      (
        SELECT 1 FROM val.FieldRequirement requirement
        WHERE requirement.FieldRequirementId = issue.FieldRequirementId AND requirement.IsActive = 1 AND requirement.IsRequired = 1
          AND (requirement.CategoryCode IS NULL OR EXISTS
            (SELECT 1 FROM #ScopedRequirement scoped
             INNER JOIN #Effective effective ON effective.ProductId = product.ProductId
               AND effective.CategoryTreeCode = scoped.CategoryTreeCode AND effective.AttributeCode = scoped.AttributeCode
               AND effective.DefinedAtCategoryCode = scoped.CategoryCode AND effective.Level <> N''EXCLUDED''
             WHERE scoped.FieldRequirementId = requirement.FieldRequirementId))
          AND NOT EXISTS (SELECT 1 FROM canon.FieldValue fieldValue WHERE fieldValue.ProductId = product.ProductId AND fieldValue.FieldCode = requirement.FieldCode AND NULLIF(fieldValue.Value, N'''') IS NOT NULL)
      ));

    ;WITH ProfileScore AS
    (
      SELECT product.ProductId, profile.ValidationProfileId,
        CAST(100.0 * (COUNT(requirement.FieldRequirementId) - SUM(CASE WHEN issue.ProductIssueId IS NULL THEN 0 ELSE 1 END)) / NULLIF(COUNT(requirement.FieldRequirementId), 0) AS decimal(5,2)) AS Completeness,
        CASE WHEN SUM(CASE WHEN issue.ProductIssueId IS NOT NULL AND requirement.Severity = N''ERROR'' THEN 1 ELSE 0 END) = 0
          THEN N''VALID'' ELSE N''INVALID'' END AS Status
      FROM canon.Product product
      CROSS JOIN val.ValidationProfile profile
      INNER JOIN val.FieldRequirement requirement ON requirement.ValidationProfileId = profile.ValidationProfileId AND requirement.IsActive = 1 AND requirement.IsRequired = 1
        AND (requirement.CategoryCode IS NULL OR EXISTS
          (SELECT 1 FROM #ScopedRequirement scoped
           INNER JOIN #Effective effective ON effective.ProductId = product.ProductId
             AND effective.CategoryTreeCode = scoped.CategoryTreeCode AND effective.AttributeCode = scoped.AttributeCode
             AND effective.DefinedAtCategoryCode = scoped.CategoryCode AND effective.Level <> N''EXCLUDED''
           WHERE scoped.FieldRequirementId = requirement.FieldRequirementId))
      LEFT JOIN val.ProductIssue issue ON issue.ProductId = product.ProductId AND issue.FieldRequirementId = requirement.FieldRequirementId AND issue.IsActive = 1
      WHERE product.IsActive = 1 AND profile.IsActive = 1
        AND product.ProductId = @ProductId
        AND (profile.Scope <> N''WEB'' OR EXISTS
          (SELECT 1 FROM pim.ProductWebShop shop
           WHERE shop.ProductId = product.ProductId
             AND shop.WebShopCode = profile.CategoryTreeCode
             AND shop.IsPublished = 1))
        GROUP BY product.ProductId, profile.ValidationProfileId
    )
    MERGE val.ProductValidationState AS target
    USING ProfileScore AS source ON target.ProductId = source.ProductId AND target.ValidationProfileId = source.ValidationProfileId
    WHEN MATCHED THEN UPDATE SET Status = source.Status, Completeness = source.Completeness, ValidatedUtc = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT (ProductId, ValidationProfileId, Status, Completeness, ValidatedUtc) VALUES (source.ProductId, source.ValidationProfileId, source.Status, source.Completeness, SYSUTCDATETIME());

    UPDATE product
    SET ValidationStatus =
        CASE WHEN EXISTS
        (
          SELECT 1 FROM val.ProductIssue issue
          INNER JOIN val.FieldRequirement requirement ON requirement.FieldRequirementId = issue.FieldRequirementId
          INNER JOIN val.ValidationProfile profile ON profile.ValidationProfileId = issue.ValidationProfileId
          WHERE issue.ProductId = product.ProductId AND issue.IsActive = 1
            AND requirement.Severity = N''ERROR''
            AND (profile.BlocksErp = 1 OR profile.BlocksWeb = 1)
            /* 182: profil, ki za ta izdelek ne velja, ne sme dolocati njegovega stanja. */
            AND (profile.Scope <> N''WEB'' OR EXISTS
              (SELECT 1 FROM pim.ProductWebShop shop
               WHERE shop.ProductId = product.ProductId
                 AND shop.WebShopCode = profile.CategoryTreeCode
                 AND shop.IsPublished = 1))
        ) THEN N''INVALID'' ELSE N''VALID'' END,
        Completeness = ISNULL
        ((
          SELECT MIN(state.Completeness) FROM val.ProductValidationState state
          INNER JOIN val.ValidationProfile profile ON profile.ValidationProfileId = state.ValidationProfileId
          WHERE state.ProductId = product.ProductId AND (profile.BlocksErp = 1 OR profile.BlocksWeb = 1)
            AND (profile.Scope <> N''WEB'' OR EXISTS
              (SELECT 1 FROM pim.ProductWebShop shop
               WHERE shop.ProductId = product.ProductId
                 AND shop.WebShopCode = profile.CategoryTreeCode
                 AND shop.IsPublished = 1))
        ), 0),
        LastValidatedUtc = SYSUTCDATETIME()
    FROM canon.Product product
    WHERE product.IsActive = 1
      AND product.ProductId = @ProductId;

    COMMIT TRANSACTION;
  END TRY
  BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    DECLARE @ErrorMessage nvarchar(4000) = ERROR_MESSAGE();
    EXEC ops.LogError @Layer = N''val'', @Severity = N''Error'', @ErrorCode = N''RUN_VALIDATION_FAILED'', @Message = @ErrorMessage;
    THROW;
  END CATCH;
END;');

/* ── RunValidationForProducts ── */
EXEC(N'CREATE OR ALTER PROCEDURE val.RunValidationForProducts
  @ProductIdsJson nvarchar(max)   /* [1, 2, 3, ...] */
AS
BEGIN
  /*
    218: ista validacija kot val.RunValidationForProduct (195), za SEZNAM izdelkov v enem teku -
    za mnozicni uvoz delovnega lista (pim.SaveProductTextsBulk, pim.SaveProductAttributesBulk).
    Besedilo je izpeljano iz 195: vsak pogoj "izdelek = @ProductId" je zamenjan s clanstvom
    izdelka v zacasni tabeli #Izbrani (EXISTS). Kot v 211 validacija ob zastoju s preslikavo (map.ProcessRawInbox) vedno izgubi.
  */
  SET NOCOUNT ON;
  SET XACT_ABORT ON;
  SET DEADLOCK_PRIORITY LOW;
  CREATE TABLE #Izbrani (ProductId bigint NOT NULL PRIMARY KEY);
  INSERT #Izbrani (ProductId)
  SELECT DISTINCT TRY_CONVERT(bigint, parsed.value) FROM OPENJSON(@ProductIdsJson) AS parsed
  WHERE ISJSON(parsed.value) = 0 AND TRY_CONVERT(bigint, parsed.value) IS NOT NULL;
  IF NOT EXISTS (SELECT 1 FROM #Izbrani) RETURN;
  BEGIN TRY
    /* 147: obseg zahteve. Za vsak izdelek in vsak atribut, ki ga kaksna kategorija po verigi
       prednikov omenja, obvelja najblizja vrstica nabora (EXCLUDED pri otroku prekrije REQUIRED
       pri starsu). Zahteva z obsegom velja za izdelek, kadar je njena kategorija tista, kjer
       obveljala vrstica stoji, in raven ni EXCLUDED. */
    CREATE TABLE #Effective
      (ProductId bigint NOT NULL, CategoryTreeCode nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL,
       AttributeCode nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
       DefinedAtCategoryCode nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
       Level nvarchar(20) COLLATE DATABASE_DEFAULT NOT NULL,
       PRIMARY KEY (ProductId, CategoryTreeCode, AttributeCode));

    ;WITH assigned AS
    (
      SELECT DISTINCT product.ProductId, node.CategoryTreeCode, node.CategoryCode, node.ParentCategoryCode
      FROM canon.Product AS product
      INNER JOIN canon.ProductCategory AS productCategory ON productCategory.ProductId = product.ProductId
      INNER JOIN canon.WebSite AS site ON site.WebSiteCode = productCategory.WebSite
      INNER JOIN canon.Category AS node
        ON node.CategoryTreeCode = site.CategoryTreeCode AND node.CategoryPath = productCategory.CategoryPath
      WHERE product.IsActive = 1
        AND EXISTS (SELECT 1 FROM #Izbrani AS izbrani WHERE izbrani.ProductId = product.ProductId)
    ),
    chain AS
    (
      SELECT ProductId, CategoryTreeCode, CategoryCode, ParentCategoryCode, 0 AS Depth FROM assigned
      UNION ALL
      SELECT chain.ProductId, parent.CategoryTreeCode, parent.CategoryCode, parent.ParentCategoryCode, chain.Depth + 1
      FROM chain
      INNER JOIN canon.Category AS parent
        ON parent.CategoryTreeCode = chain.CategoryTreeCode AND parent.CategoryCode = chain.ParentCategoryCode
      WHERE chain.Depth < 12
    ),
    ranked AS
    (
      SELECT chain.ProductId, chain.CategoryTreeCode, setRow.AttributeCode, chain.CategoryCode AS DefinedAtCategoryCode, setRow.Level,
        ROW_NUMBER() OVER (PARTITION BY chain.ProductId, chain.CategoryTreeCode, setRow.AttributeCode ORDER BY chain.Depth) AS PickRank
      FROM chain
      INNER JOIN canon.CategoryAttributeSet AS setRow
        ON setRow.CategoryTreeCode = chain.CategoryTreeCode AND setRow.CategoryCode = chain.CategoryCode AND setRow.IsActive = 1
    )
    INSERT #Effective (ProductId, CategoryTreeCode, AttributeCode, DefinedAtCategoryCode, Level)
    SELECT ProductId, CategoryTreeCode, AttributeCode, DefinedAtCategoryCode, Level FROM ranked WHERE PickRank = 1;

    /* Zahteva z obsegom -> koda atributa v registru (zahteva nosi slovensko ime). */
    CREATE TABLE #ScopedRequirement
      (FieldRequirementId int NOT NULL PRIMARY KEY, CategoryTreeCode nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL,
       CategoryCode nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL, AttributeCode nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL);
    INSERT #ScopedRequirement (FieldRequirementId, CategoryTreeCode, CategoryCode, AttributeCode)
    SELECT requirement.FieldRequirementId, requirement.CategoryTreeCode, requirement.CategoryCode, definition.AttributeCode
    FROM val.FieldRequirement AS requirement
    INNER JOIN canon.AttributeDefinition AS definition
      ON CONCAT(N''ProductAttribute.'', COALESCE(
           (SELECT TOP (1) Name FROM canon.AttributeTranslation WHERE AttributeCode = definition.AttributeCode AND LanguageCode = N''sl''),
           definition.AttributeCode)) = requirement.FieldCode
    WHERE requirement.CategoryCode IS NOT NULL;

    BEGIN TRANSACTION;
    ;WITH RequiredField AS
    (
      SELECT product.ProductId, profile.ValidationProfileId, requirement.FieldRequirementId, requirement.FieldCode
      FROM canon.Product product
      CROSS JOIN val.ValidationProfile profile
      INNER JOIN val.FieldRequirement requirement ON requirement.ValidationProfileId = profile.ValidationProfileId
      WHERE product.IsActive = 1 AND profile.IsActive = 1 AND requirement.IsActive = 1 AND requirement.IsRequired = 1
        AND EXISTS (SELECT 1 FROM #Izbrani AS izbrani WHERE izbrani.ProductId = product.ProductId)
        /* 182: spletni profil velja samo za izdelek, ki je za to spletisce oznacen v PIM.
           Prej je CROSS JOIN vsak profil pripel na vsak izdelek, zato sta spletna profila
           odpirala napake tudi na 162.000 izdelkih, ki na splet sploh ne gredo. */
        AND (profile.Scope <> N''WEB'' OR EXISTS
          (SELECT 1 FROM pim.ProductWebShop shop
           WHERE shop.ProductId = product.ProductId
             AND shop.WebShopCode = profile.CategoryTreeCode
             AND shop.IsPublished = 1))
        AND (requirement.CategoryCode IS NULL OR EXISTS
          (SELECT 1 FROM #ScopedRequirement scoped
           INNER JOIN #Effective effective ON effective.ProductId = product.ProductId
             AND effective.CategoryTreeCode = scoped.CategoryTreeCode AND effective.AttributeCode = scoped.AttributeCode
             AND effective.DefinedAtCategoryCode = scoped.CategoryCode AND effective.Level <> N''EXCLUDED''
           WHERE scoped.FieldRequirementId = requirement.FieldRequirementId))
    ), MissingField AS
    (
      SELECT requiredField.*
      FROM RequiredField requiredField
      WHERE NOT EXISTS
      (
        SELECT 1 FROM canon.FieldValue fieldValue
        WHERE fieldValue.ProductId = requiredField.ProductId
          AND fieldValue.FieldCode = requiredField.FieldCode
          AND NULLIF(fieldValue.Value, N'''') IS NOT NULL
      )
    )
    MERGE val.ProductIssue AS target
    USING MissingField AS source
    ON target.ProductId = source.ProductId AND target.FieldRequirementId = source.FieldRequirementId
    WHEN MATCHED THEN UPDATE SET ValidationProfileId = source.ValidationProfileId, IssueCode = N''MISSING_REQUIRED_FIELD'', Message = CONCAT(N''Manjka obvezno polje: '', source.FieldCode), IsActive = 1, LastDetectedUtc = SYSUTCDATETIME(), ResolvedUtc = NULL
    WHEN NOT MATCHED THEN INSERT (ProductId, ValidationProfileId, FieldRequirementId, IssueCode, Message) VALUES (source.ProductId, source.ValidationProfileId, source.FieldRequirementId, N''MISSING_REQUIRED_FIELD'', CONCAT(N''Manjka obvezno polje: '', source.FieldCode));

    UPDATE issue SET IsActive = 0, ResolvedUtc = SYSUTCDATETIME()
    FROM val.ProductIssue issue
    INNER JOIN canon.Product product ON product.ProductId = issue.ProductId
    INNER JOIN val.ValidationProfile profile ON profile.ValidationProfileId = issue.ValidationProfileId
    WHERE issue.IsActive = 1
      AND EXISTS (SELECT 1 FROM #Izbrani AS izbrani WHERE izbrani.ProductId = product.ProductId)
      /* 182: napaka se zapre tudi takrat, ko profil za ta izdelek ne velja vec — brez tega bi
         obstojece spletne napake ostale odprte, ceprav izdelek na to spletisce ne gre. */
      AND (NOT (profile.Scope <> N''WEB'' OR EXISTS
            (SELECT 1 FROM pim.ProductWebShop shop
             WHERE shop.ProductId = product.ProductId
               AND shop.WebShopCode = profile.CategoryTreeCode
               AND shop.IsPublished = 1))
      OR NOT EXISTS
      (
        SELECT 1 FROM val.FieldRequirement requirement
        WHERE requirement.FieldRequirementId = issue.FieldRequirementId AND requirement.IsActive = 1 AND requirement.IsRequired = 1
          AND (requirement.CategoryCode IS NULL OR EXISTS
            (SELECT 1 FROM #ScopedRequirement scoped
             INNER JOIN #Effective effective ON effective.ProductId = product.ProductId
               AND effective.CategoryTreeCode = scoped.CategoryTreeCode AND effective.AttributeCode = scoped.AttributeCode
               AND effective.DefinedAtCategoryCode = scoped.CategoryCode AND effective.Level <> N''EXCLUDED''
             WHERE scoped.FieldRequirementId = requirement.FieldRequirementId))
          AND NOT EXISTS (SELECT 1 FROM canon.FieldValue fieldValue WHERE fieldValue.ProductId = product.ProductId AND fieldValue.FieldCode = requirement.FieldCode AND NULLIF(fieldValue.Value, N'''') IS NOT NULL)
      ));

    ;WITH ProfileScore AS
    (
      SELECT product.ProductId, profile.ValidationProfileId,
        CAST(100.0 * (COUNT(requirement.FieldRequirementId) - SUM(CASE WHEN issue.ProductIssueId IS NULL THEN 0 ELSE 1 END)) / NULLIF(COUNT(requirement.FieldRequirementId), 0) AS decimal(5,2)) AS Completeness,
        CASE WHEN SUM(CASE WHEN issue.ProductIssueId IS NOT NULL AND requirement.Severity = N''ERROR'' THEN 1 ELSE 0 END) = 0
          THEN N''VALID'' ELSE N''INVALID'' END AS Status
      FROM canon.Product product
      CROSS JOIN val.ValidationProfile profile
      INNER JOIN val.FieldRequirement requirement ON requirement.ValidationProfileId = profile.ValidationProfileId AND requirement.IsActive = 1 AND requirement.IsRequired = 1
        AND (requirement.CategoryCode IS NULL OR EXISTS
          (SELECT 1 FROM #ScopedRequirement scoped
           INNER JOIN #Effective effective ON effective.ProductId = product.ProductId
             AND effective.CategoryTreeCode = scoped.CategoryTreeCode AND effective.AttributeCode = scoped.AttributeCode
             AND effective.DefinedAtCategoryCode = scoped.CategoryCode AND effective.Level <> N''EXCLUDED''
           WHERE scoped.FieldRequirementId = requirement.FieldRequirementId))
      LEFT JOIN val.ProductIssue issue ON issue.ProductId = product.ProductId AND issue.FieldRequirementId = requirement.FieldRequirementId AND issue.IsActive = 1
      WHERE product.IsActive = 1 AND profile.IsActive = 1
        AND EXISTS (SELECT 1 FROM #Izbrani AS izbrani WHERE izbrani.ProductId = product.ProductId)
        AND (profile.Scope <> N''WEB'' OR EXISTS
          (SELECT 1 FROM pim.ProductWebShop shop
           WHERE shop.ProductId = product.ProductId
             AND shop.WebShopCode = profile.CategoryTreeCode
             AND shop.IsPublished = 1))
        GROUP BY product.ProductId, profile.ValidationProfileId
    )
    MERGE val.ProductValidationState AS target
    USING ProfileScore AS source ON target.ProductId = source.ProductId AND target.ValidationProfileId = source.ValidationProfileId
    WHEN MATCHED THEN UPDATE SET Status = source.Status, Completeness = source.Completeness, ValidatedUtc = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT (ProductId, ValidationProfileId, Status, Completeness, ValidatedUtc) VALUES (source.ProductId, source.ValidationProfileId, source.Status, source.Completeness, SYSUTCDATETIME());

    UPDATE product
    SET ValidationStatus =
        CASE WHEN EXISTS
        (
          SELECT 1 FROM val.ProductIssue issue
          INNER JOIN val.FieldRequirement requirement ON requirement.FieldRequirementId = issue.FieldRequirementId
          INNER JOIN val.ValidationProfile profile ON profile.ValidationProfileId = issue.ValidationProfileId
          WHERE issue.ProductId = product.ProductId AND issue.IsActive = 1
            AND requirement.Severity = N''ERROR''
            AND (profile.BlocksErp = 1 OR profile.BlocksWeb = 1)
            /* 182: profil, ki za ta izdelek ne velja, ne sme dolocati njegovega stanja. */
            AND (profile.Scope <> N''WEB'' OR EXISTS
              (SELECT 1 FROM pim.ProductWebShop shop
               WHERE shop.ProductId = product.ProductId
                 AND shop.WebShopCode = profile.CategoryTreeCode
                 AND shop.IsPublished = 1))
        ) THEN N''INVALID'' ELSE N''VALID'' END,
        Completeness = ISNULL
        ((
          SELECT MIN(state.Completeness) FROM val.ProductValidationState state
          INNER JOIN val.ValidationProfile profile ON profile.ValidationProfileId = state.ValidationProfileId
          WHERE state.ProductId = product.ProductId AND (profile.BlocksErp = 1 OR profile.BlocksWeb = 1)
            AND (profile.Scope <> N''WEB'' OR EXISTS
              (SELECT 1 FROM pim.ProductWebShop shop
               WHERE shop.ProductId = product.ProductId
                 AND shop.WebShopCode = profile.CategoryTreeCode
                 AND shop.IsPublished = 1))
        ), 0),
        LastValidatedUtc = SYSUTCDATETIME()
    FROM canon.Product product
    WHERE product.IsActive = 1
      AND EXISTS (SELECT 1 FROM #Izbrani AS izbrani WHERE izbrani.ProductId = product.ProductId);

    COMMIT TRANSACTION;
  END TRY
  BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    DECLARE @ErrorMessage nvarchar(4000) = ERROR_MESSAGE();
    EXEC ops.LogError @Layer = N''val'', @Severity = N''Error'', @ErrorCode = N''RUN_VALIDATION_FAILED'', @Message = @ErrorMessage;
    THROW;
  END CATCH;
END;');

/* ── SaveProductTexts ── */
EXEC(N'CREATE OR ALTER PROCEDURE pim.SaveProductTexts
  @OrganizationId int,
  @ProductId bigint,
  @ChangesJson nvarchar(max),
  @Actor nvarchar(200),
  @Note nvarchar(400) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  IF NOT EXISTS (SELECT 1 FROM canon.Product WHERE ProductId = @ProductId AND OrganizationId = @OrganizationId)
    THROW 52401, N''Izdelek ne obstaja v tem podjetju.'', 1;

  DECLARE @Changes TABLE (Lang nvarchar(40) NOT NULL, TextType nvarchar(100) NOT NULL, Value nvarchar(max) NULL,
                          Expected nvarchar(max) NULL, HasExpected bit NOT NULL);
  INSERT @Changes (Lang, TextType, Value, Expected, HasExpected)
  SELECT LTRIM(RTRIM(parsed.lang)), UPPER(LTRIM(RTRIM(parsed.textType))), parsed.value,
         parsed.expected, CASE WHEN parsed.hasExpected = 1 THEN 1 ELSE 0 END
  FROM OPENJSON(@ChangesJson) WITH (lang nvarchar(40) N''$.lang'', textType nvarchar(100) N''$.textType'',
                                    value nvarchar(max) N''$.value'', expected nvarchar(max) N''$.expected'',
                                    hasExpected bit N''$.hasExpected'') AS parsed
  WHERE NULLIF(LTRIM(RTRIM(parsed.lang)), N'''') IS NOT NULL AND NULLIF(LTRIM(RTRIM(parsed.textType)), N'''') IS NOT NULL;

  /* Katero besedilo potuje v SAOP, ne odloca ime, ampak register out.SaopXmlField. */
  IF EXISTS
  (
    SELECT 1 FROM @Changes AS change
    INNER JOIN out.SaopXmlField AS field
      ON field.TargetKind = N''SAOP_PRODUCT'' AND field.IsEnabled = 1
     AND field.FieldKey = N''ProductText.'' + change.TextType + N''.'' + change.Lang
  )
    THROW 52402, N''To besedilo pise SAOP; sprememba mora skozi odhodno vrsto z odobritvijo.'', 1;

  -- Sporne vrstice: urednik je videl eno, v katalogu pa danes stoji drugo.
  DECLARE @Conflict TABLE (Lang nvarchar(40) NOT NULL, TextType nvarchar(100) NOT NULL,
                           Expected nvarchar(max) NULL, TheirValue nvarchar(max) NULL);
  INSERT @Conflict (Lang, TextType, Expected, TheirValue)
  SELECT change.Lang, change.TextType, change.Expected, current_.Value
  FROM @Changes AS change
  OUTER APPLY
  (
    SELECT TOP (1) textValue.Value
    FROM canon.ProductText AS textValue
    WHERE textValue.ProductId = @ProductId AND textValue.Lang = change.Lang AND textValue.TextType = change.TextType
  ) AS current_
  WHERE change.HasExpected = 1
    AND ISNULL(current_.Value, N'''') <> ISNULL(change.Expected, N'''');

  DELETE change FROM @Changes AS change
  INNER JOIN @Conflict AS conflict ON conflict.Lang = change.Lang AND conflict.TextType = change.TextType;

  DECLARE @BatchId uniqueidentifier = NEWID();
  EXEC pim.SetChangeContext @ChangeSource = N''INTRANET'', @ChangedBy = @Actor, @BatchId = @BatchId, @Note = @Note;

  BEGIN TRY
    BEGIN TRANSACTION;

    DELETE textValue
    FROM canon.ProductText AS textValue
    INNER JOIN @Changes AS change ON change.Lang = textValue.Lang AND change.TextType = textValue.TextType
    WHERE textValue.ProductId = @ProductId AND NULLIF(LTRIM(RTRIM(change.Value)), N'''') IS NULL;

    MERGE canon.ProductText AS target
    USING (SELECT Lang, TextType, Value FROM @Changes WHERE NULLIF(LTRIM(RTRIM(Value)), N'''') IS NOT NULL) AS source
    ON target.ProductId = @ProductId AND target.Lang = source.Lang AND target.TextType = source.TextType
    WHEN MATCHED AND ISNULL(target.Value, N'''') <> source.Value THEN UPDATE SET Value = source.Value
    WHEN NOT MATCHED THEN INSERT (ProductId, Lang, TextType, Value) VALUES (@ProductId, source.Lang, source.TextType, source.Value);

    COMMIT TRANSACTION;
  END TRY
  BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    EXEC pim.ClearChangeContext;
    THROW;
  END CATCH;

  EXEC pim.ClearChangeContext;
  /* 218: hitra validacija enega izdelka (0,1-0,5 s) namesto val.RunValidation @ProductId (14-95 s, glej 195). */
  EXEC val.RunValidationForProduct @ProductId = @ProductId;

  SELECT ChangedCount = (SELECT COUNT_BIG(*) FROM @Changes),
    ConflictCount = (SELECT COUNT_BIG(*) FROM @Conflict),
    ValidationStatus = product.ValidationStatus, Completeness = product.Completeness,
    OpenIssueCount = (SELECT COUNT_BIG(*) FROM val.ProductIssue AS issue WHERE issue.ProductId = @ProductId AND issue.IsActive = 1)
  FROM canon.Product AS product WHERE product.ProductId = @ProductId;

  SELECT FieldKey = CONCAT(N''ProductText.'', TextType, N''.'', Lang), Expected, TheirValue FROM @Conflict;
END;');

/* ── SaveProductAttributes ── */
EXEC(N'CREATE OR ALTER PROCEDURE pim.SaveProductAttributes
  @OrganizationId int,
  @ProductId bigint,
  @ChangesJson nvarchar(max),
  @Actor nvarchar(200),
  @Note nvarchar(400) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  IF NOT EXISTS (SELECT 1 FROM canon.Product WHERE ProductId = @ProductId AND OrganizationId = @OrganizationId)
    THROW 52401, N''Izdelek ne obstaja v tem podjetju.'', 1;

  DECLARE @Changes TABLE (AttributeCode nvarchar(200) NOT NULL PRIMARY KEY, Value nvarchar(max) NULL,
                          Expected nvarchar(max) NULL, HasExpected bit NOT NULL);
  INSERT @Changes (AttributeCode, Value, Expected, HasExpected)
  SELECT LTRIM(RTRIM(parsed.attributeCode)), parsed.value, parsed.expected,
         CASE WHEN parsed.hasExpected = 1 THEN 1 ELSE 0 END
  FROM OPENJSON(@ChangesJson) WITH (attributeCode nvarchar(200) N''$.attributeCode'', value nvarchar(max) N''$.value'',
                                    expected nvarchar(max) N''$.expected'', hasExpected bit N''$.hasExpected'') AS parsed
  WHERE NULLIF(LTRIM(RTRIM(parsed.attributeCode)), N'''') IS NOT NULL;

  DECLARE @Conflict TABLE (AttributeCode nvarchar(200) NOT NULL PRIMARY KEY,
                           Expected nvarchar(max) NULL, TheirValue nvarchar(max) NULL);
  INSERT @Conflict (AttributeCode, Expected, TheirValue)
  SELECT change.AttributeCode, change.Expected, current_.Value
  FROM @Changes AS change
  OUTER APPLY
  (
    SELECT TOP (1) attributeValue.Value
    FROM canon.ProductAttribute AS attributeValue
    WHERE attributeValue.ProductId = @ProductId AND attributeValue.AttributeCode = change.AttributeCode
    ORDER BY attributeValue.ProductAttributeId
  ) AS current_
  WHERE change.HasExpected = 1
    AND ISNULL(current_.Value, N'''') <> ISNULL(change.Expected, N'''');

  DELETE change FROM @Changes AS change
  INNER JOIN @Conflict AS conflict ON conflict.AttributeCode = change.AttributeCode;

  DECLARE @BatchId uniqueidentifier = NEWID();
  EXEC pim.SetChangeContext @ChangeSource = N''INTRANET'', @ChangedBy = @Actor, @BatchId = @BatchId, @Note = @Note;

  BEGIN TRY
    BEGIN TRANSACTION;

    DELETE attributeValue
    FROM canon.ProductAttribute AS attributeValue
    INNER JOIN @Changes AS change ON change.AttributeCode = attributeValue.AttributeCode
    WHERE attributeValue.ProductId = @ProductId AND NULLIF(LTRIM(RTRIM(change.Value)), N'''') IS NULL;

    MERGE canon.ProductAttribute AS target
    USING (SELECT AttributeCode, Value FROM @Changes WHERE NULLIF(LTRIM(RTRIM(Value)), N'''') IS NOT NULL) AS source
    ON target.ProductId = @ProductId AND target.AttributeCode = source.AttributeCode
    WHEN MATCHED AND ISNULL(target.Value, N'''') <> source.Value THEN UPDATE SET Value = source.Value
    WHEN NOT MATCHED THEN INSERT (ProductId, AttributeCode, Value) VALUES (@ProductId, source.AttributeCode, source.Value);

    COMMIT TRANSACTION;
  END TRY
  BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    EXEC pim.ClearChangeContext;
    THROW;
  END CATCH;

  EXEC pim.ClearChangeContext;
  /* 218: hitra validacija enega izdelka (0,1-0,5 s) namesto val.RunValidation @ProductId (14-95 s, glej 195). */
  EXEC val.RunValidationForProduct @ProductId = @ProductId;

  SELECT ChangedCount = (SELECT COUNT_BIG(*) FROM @Changes),
    ConflictCount = (SELECT COUNT_BIG(*) FROM @Conflict),
    ValidationStatus = product.ValidationStatus, Completeness = product.Completeness,
    OpenIssueCount = (SELECT COUNT_BIG(*) FROM val.ProductIssue AS issue WHERE issue.ProductId = @ProductId AND issue.IsActive = 1)
  FROM canon.Product AS product WHERE product.ProductId = @ProductId;

  SELECT FieldKey = CONCAT(N''ProductAttribute.'', AttributeCode), Expected, TheirValue FROM @Conflict;
END;');

/* ── SaveProductWebShops ── */
EXEC(N'CREATE OR ALTER PROCEDURE pim.SaveProductWebShops
  @OrganizationId int,
  @ProductId bigint,
  @ChangesJson nvarchar(max),
  @Actor nvarchar(200),
  @Note nvarchar(400) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  IF NOT EXISTS (SELECT 1 FROM canon.Product WHERE ProductId = @ProductId AND OrganizationId = @OrganizationId)
    THROW 52401, N''Izdelek ne pripada temu podjetju.'', 1;

  DECLARE @Changes TABLE (WebShopCode nvarchar(100) NOT NULL PRIMARY KEY, IsPublished bit NOT NULL);
  INSERT @Changes (WebShopCode, IsPublished)
  SELECT DISTINCT parsed.webShopCode, CASE WHEN parsed.isPublished IN (N''1'', N''true'') THEN 1 ELSE 0 END
  FROM OPENJSON(@ChangesJson)
  WITH (webShopCode nvarchar(100) N''$.webShopCode'', isPublished nvarchar(10) N''$.isPublished'') AS parsed
  WHERE NULLIF(parsed.webShopCode, N'''') IS NOT NULL;

  IF EXISTS (SELECT 1 FROM @Changes changed
             WHERE NOT EXISTS (SELECT 1 FROM canon.WebSite site
                               WHERE site.CategoryTreeCode = changed.WebShopCode AND site.IsActive = 1))
    THROW 52403, N''Neznano spletisce.'', 1;

  DECLARE @ItemID nvarchar(50) = (SELECT ItemID FROM canon.Product WHERE ProductId = @ProductId);
  DECLARE @BatchId bigint;

  BEGIN TRANSACTION;
  BEGIN TRY
    DECLARE @Changed TABLE (WebShopCode nvarchar(100), OldValue nvarchar(10), NewValue nvarchar(10));

    MERGE pim.ProductWebShop AS target
    USING @Changes AS source ON target.ProductId = @ProductId AND target.WebShopCode = source.WebShopCode
    WHEN MATCHED AND target.IsPublished <> source.IsPublished
      THEN UPDATE SET IsPublished = source.IsPublished, ChangedBy = @Actor, ChangedUtc = SYSUTCDATETIME()
    WHEN NOT MATCHED BY TARGET
      THEN INSERT (ProductId, WebShopCode, IsPublished, ChangedBy) VALUES (@ProductId, source.WebShopCode, source.IsPublished, @Actor)
    OUTPUT inserted.WebShopCode,
           CASE WHEN deleted.IsPublished IS NULL THEN N''ne'' WHEN deleted.IsPublished = 1 THEN N''da'' ELSE N''ne'' END,
           CASE WHEN inserted.IsPublished = 1 THEN N''da'' ELSE N''ne'' END
    INTO @Changed (WebShopCode, OldValue, NewValue);

    DELETE @Changed WHERE OldValue = NewValue;

    IF EXISTS (SELECT 1 FROM @Changed)
    BEGIN
      INSERT pim.ProductChangeBatch (BatchId, ChangeSource, ChangedBy, OrganizationId, Note)
      VALUES (NEWID(), N''CARD'', @Actor, @OrganizationId, @Note);
      SET @BatchId = SCOPE_IDENTITY();

      INSERT pim.ProductFieldHistory (ChangeBatchId, OrganizationId, ProductId, ItemID, FieldKey, CanonTable, CanonColumn, Owner, OldValue, NewValue)
      SELECT @BatchId, @OrganizationId, @ProductId, @ItemID,
             CONCAT(N''ProductWebShop.'', changed.WebShopCode), N''pim.ProductWebShop'', N''IsPublished'', N''PIM'',
             changed.OldValue, changed.NewValue
      FROM @Changed changed;
    END;

    COMMIT;
  END TRY
  BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    THROW;
  END CATCH

  /* 218: hitra validacija enega izdelka (0,1-0,5 s) namesto val.RunValidation @ProductId (14-95 s, glej 195). */
  EXEC val.RunValidationForProduct @ProductId = @ProductId;

  SELECT (SELECT COUNT(*) FROM @Changes) AS RequestedCount,
         (SELECT COUNT(*) FROM pim.ProductWebShop WHERE ProductId = @ProductId AND IsPublished = 1) AS PublishedCount;
END;');

/* ── SaveProductTextsBulk ── */
EXEC(N'CREATE OR ALTER PROCEDURE pim.SaveProductTextsBulk
  @OrganizationId int,
  @ChangesJson nvarchar(max),   /* [{"productId":123,"lang":"sl","textType":"DESCRIPTION","value":"..."}, ...] */
  @Actor nvarchar(200),
  @Note nvarchar(400) = NULL
AS
BEGIN
  /*
    218: mnozicni zapis besedil za uvoz delovnega lista (ProductWorkbookService.ApplyAsync).
    Ista pravila kot pim.SaveProductTexts (lastnistvo iz out.SaopXmlField, prazna vrednost
    brise, zgodovina prek sprozilca in pim.SetChangeContext), a za poljubno mnogo izdelkov v
    enem klicu: en MERGE, ena serija sprememb (pim.ProductChangeBatch) in ena mnozicna
    validacija (val.RunValidationForProducts) namesto ene procedure in ene validacije na vrstico.
    Sporna polja (Expected/HasExpected) tu niso podprta: uvoz jih ne posilja.
  */
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  DECLARE @Changes TABLE (ProductId bigint NOT NULL, Lang nvarchar(40) NOT NULL, TextType nvarchar(100) NOT NULL,
                          Value nvarchar(max) NULL, PRIMARY KEY (ProductId, Lang, TextType));
  INSERT @Changes (ProductId, Lang, TextType, Value)
  SELECT vrstica.ProductId, vrstica.Lang, vrstica.TextType, vrstica.Value
  FROM
  (
    SELECT parsed.productId AS ProductId, LTRIM(RTRIM(parsed.lang)) AS Lang, UPPER(LTRIM(RTRIM(parsed.textType))) AS TextType,
      parsed.value AS Value,
      ROW_NUMBER() OVER (PARTITION BY parsed.productId, LTRIM(RTRIM(parsed.lang)), UPPER(LTRIM(RTRIM(parsed.textType)))
                         ORDER BY CONVERT(int, element.[key])) AS Zaporedna
    FROM OPENJSON(@ChangesJson) AS element
    CROSS APPLY OPENJSON(element.value)
      WITH (productId bigint N''$.productId'', lang nvarchar(40) N''$.lang'', textType nvarchar(100) N''$.textType'',
            value nvarchar(max) N''$.value'') AS parsed
    WHERE parsed.productId IS NOT NULL
      AND NULLIF(LTRIM(RTRIM(parsed.lang)), N'''') IS NOT NULL
      AND NULLIF(LTRIM(RTRIM(parsed.textType)), N'''') IS NOT NULL
  ) AS vrstica
  WHERE vrstica.Zaporedna = 1;

  /* Izdelek, ki ni v tem podjetju, odpade in se pove; ne podre celega paketa. */
  DECLARE @Skipped TABLE (ProductId bigint NOT NULL PRIMARY KEY, Reason nvarchar(200) NOT NULL);
  INSERT @Skipped (ProductId, Reason)
  SELECT DISTINCT change.ProductId, N''Izdelek ne obstaja v tem podjetju.''
  FROM @Changes AS change
  WHERE NOT EXISTS (SELECT 1 FROM canon.Product AS product WHERE product.ProductId = change.ProductId AND product.OrganizationId = @OrganizationId);
  DELETE change FROM @Changes AS change INNER JOIN @Skipped AS skipped ON skipped.ProductId = change.ProductId;

  /* Katero besedilo potuje v SAOP, ne odloca ime, ampak register out.SaopXmlField. */
  IF EXISTS
  (
    SELECT 1 FROM @Changes AS change
    INNER JOIN out.SaopXmlField AS field
      ON field.TargetKind = N''SAOP_PRODUCT'' AND field.IsEnabled = 1
     AND field.FieldKey = N''ProductText.'' + change.TextType + N''.'' + change.Lang
  )
    THROW 52402, N''To besedilo pise SAOP; sprememba mora skozi odhodno vrsto z odobritvijo.'', 1;

  DECLARE @BatchId uniqueidentifier = NEWID();
  EXEC pim.SetChangeContext @ChangeSource = N''INTRANET'', @ChangedBy = @Actor, @BatchId = @BatchId, @Note = @Note;

  BEGIN TRY
    BEGIN TRANSACTION;

    DELETE textValue
    FROM canon.ProductText AS textValue
    INNER JOIN @Changes AS change
      ON change.ProductId = textValue.ProductId AND change.Lang = textValue.Lang AND change.TextType = textValue.TextType
    WHERE NULLIF(LTRIM(RTRIM(change.Value)), N'''') IS NULL;

    MERGE canon.ProductText AS target
    USING (SELECT ProductId, Lang, TextType, Value FROM @Changes WHERE NULLIF(LTRIM(RTRIM(Value)), N'''') IS NOT NULL) AS source
    ON target.ProductId = source.ProductId AND target.Lang = source.Lang AND target.TextType = source.TextType
    WHEN MATCHED AND ISNULL(target.Value, N'''') <> source.Value THEN UPDATE SET Value = source.Value
    WHEN NOT MATCHED THEN INSERT (ProductId, Lang, TextType, Value) VALUES (source.ProductId, source.Lang, source.TextType, source.Value);

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
     FROM (SELECT DISTINCT ProductId FROM @Changes) AS izdelek);
  IF @ProductIdsJson IS NOT NULL
    EXEC val.RunValidationForProducts @ProductIdsJson = @ProductIdsJson;

  SELECT ChangedCount = (SELECT COUNT_BIG(*) FROM @Changes),
         ProductCount = (SELECT COUNT_BIG(DISTINCT ProductId) FROM @Changes),
         SkippedCount = (SELECT COUNT_BIG(*) FROM @Skipped);

  SELECT ProductId, Reason FROM @Skipped ORDER BY ProductId;
END;');

/* ── SaveProductAttributesBulk ── */
EXEC(N'CREATE OR ALTER PROCEDURE pim.SaveProductAttributesBulk
  @OrganizationId int,
  @ChangesJson nvarchar(max),   /* [{"productId":123,"attributeCode":"Barva","value":"..."}, ...] */
  @Actor nvarchar(200),
  @Note nvarchar(400) = NULL
AS
BEGIN
  /*
    218: mnozicni zapis atributov za uvoz delovnega lista - dvojcek pim.SaveProductAttributes
    za poljubno mnogo izdelkov v enem klicu (glej pim.SaveProductTextsBulk za razlog).
    Enako kot pri posamicni proceduri se ujemanje dela po (izdelek, koda atributa), brez jezika.
  */
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  DECLARE @Changes TABLE (ProductId bigint NOT NULL, AttributeCode nvarchar(200) NOT NULL, Value nvarchar(max) NULL,
                          PRIMARY KEY (ProductId, AttributeCode));
  INSERT @Changes (ProductId, AttributeCode, Value)
  SELECT vrstica.ProductId, vrstica.AttributeCode, vrstica.Value
  FROM
  (
    SELECT parsed.productId AS ProductId, LTRIM(RTRIM(parsed.attributeCode)) AS AttributeCode, parsed.value AS Value,
      ROW_NUMBER() OVER (PARTITION BY parsed.productId, LTRIM(RTRIM(parsed.attributeCode)) ORDER BY CONVERT(int, element.[key])) AS Zaporedna
    FROM OPENJSON(@ChangesJson) AS element
    CROSS APPLY OPENJSON(element.value)
      WITH (productId bigint N''$.productId'', attributeCode nvarchar(200) N''$.attributeCode'', value nvarchar(max) N''$.value'') AS parsed
    WHERE parsed.productId IS NOT NULL
      AND NULLIF(LTRIM(RTRIM(parsed.attributeCode)), N'''') IS NOT NULL
  ) AS vrstica
  WHERE vrstica.Zaporedna = 1;

  DECLARE @Skipped TABLE (ProductId bigint NOT NULL PRIMARY KEY, Reason nvarchar(200) NOT NULL);
  INSERT @Skipped (ProductId, Reason)
  SELECT DISTINCT change.ProductId, N''Izdelek ne obstaja v tem podjetju.''
  FROM @Changes AS change
  WHERE NOT EXISTS (SELECT 1 FROM canon.Product AS product WHERE product.ProductId = change.ProductId AND product.OrganizationId = @OrganizationId);
  DELETE change FROM @Changes AS change INNER JOIN @Skipped AS skipped ON skipped.ProductId = change.ProductId;

  DECLARE @BatchId uniqueidentifier = NEWID();
  EXEC pim.SetChangeContext @ChangeSource = N''INTRANET'', @ChangedBy = @Actor, @BatchId = @BatchId, @Note = @Note;

  BEGIN TRY
    BEGIN TRANSACTION;

    DELETE attributeValue
    FROM canon.ProductAttribute AS attributeValue
    INNER JOIN @Changes AS change
      ON change.ProductId = attributeValue.ProductId AND change.AttributeCode = attributeValue.AttributeCode
    WHERE NULLIF(LTRIM(RTRIM(change.Value)), N'''') IS NULL;

    MERGE canon.ProductAttribute AS target
    USING (SELECT ProductId, AttributeCode, Value FROM @Changes WHERE NULLIF(LTRIM(RTRIM(Value)), N'''') IS NOT NULL) AS source
    ON target.ProductId = source.ProductId AND target.AttributeCode = source.AttributeCode
    WHEN MATCHED AND ISNULL(target.Value, N'''') <> source.Value THEN UPDATE SET Value = source.Value
    WHEN NOT MATCHED THEN INSERT (ProductId, AttributeCode, Value) VALUES (source.ProductId, source.AttributeCode, source.Value);

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
     FROM (SELECT DISTINCT ProductId FROM @Changes) AS izdelek);
  IF @ProductIdsJson IS NOT NULL
    EXEC val.RunValidationForProducts @ProductIdsJson = @ProductIdsJson;

  SELECT ChangedCount = (SELECT COUNT_BIG(*) FROM @Changes),
         ProductCount = (SELECT COUNT_BIG(DISTINCT ProductId) FROM @Changes),
         SkippedCount = (SELECT COUNT_BIG(*) FROM @Skipped);

  SELECT ProductId, Reason FROM @Skipped ORDER BY ProductId;
END;');

/* ── GetProductWorkbook ── */
EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetProductWorkbook
  @ProductIdsJson nvarchar(max),
  @FieldCodesJson nvarchar(max),
  @CategoryTreeCode nvarchar(100) = NULL,
  @CategoryCode nvarchar(200) = NULL
AS
BEGIN
  SET NOCOUNT ON;

  DECLARE @Products TABLE (ProductId bigint NOT NULL PRIMARY KEY);
  INSERT @Products (ProductId)
  SELECT DISTINCT CONVERT(bigint, parsed.value) FROM OPENJSON(@ProductIdsJson) AS parsed
  WHERE ISJSON(parsed.value) = 0 AND TRY_CONVERT(bigint, parsed.value) IS NOT NULL;

  DECLARE @VsiIzdelki bit = CASE WHEN EXISTS (SELECT 1 FROM @Products) THEN 0 ELSE 1 END;

  DECLARE @Fields TABLE (FieldCode nvarchar(200) NOT NULL PRIMARY KEY);
  INSERT @Fields (FieldCode)
  SELECT DISTINCT CONVERT(nvarchar(200), parsed.value) FROM OPENJSON(@FieldCodesJson) AS parsed
  WHERE ISJSON(parsed.value) = 0 AND NULLIF(LTRIM(RTRIM(parsed.value)), N'''') IS NOT NULL;

  SET @CategoryCode = NULLIF(LTRIM(RTRIM(@CategoryCode)), N'''');
  SET @CategoryTreeCode = NULLIF(LTRIM(RTRIM(@CategoryTreeCode)), N'''');

  /* 1) Vrednosti polj.
     218: polja se berejo neposredno iz tabel, ne prek pogleda canon.FieldValue: stik pogleda
     (35 vej UNION ALL) s tabelno spremenljivko izdelkov je optimizer izvedel kot polni pregled
     vseh vej za vsako polje - izmerjeno 89 s od 90 s za 2.000 izdelkov. Kode polj in oblika
     vrednosti so DOBESEDNO iste kot v canon.FieldValue (migracija 124); ce se pogled dopolni,
     se dopolni tudi ta seznam. Vsaka veja seka po ProductId in vzame samo zahtevana polja. */
  SELECT vrednost.ProductId, vrednost.FieldCode,
    Value = STRING_AGG(CONVERT(nvarchar(max), vrednost.Value), N'' | '') WITHIN GROUP (ORDER BY vrednost.Value)
  FROM
  (
    SELECT polje.ProductId, polje.FieldCode, polje.Value
    FROM @Products AS product
    INNER JOIN canon.Product AS izdelek ON izdelek.ProductId = product.ProductId
    CROSS APPLY
    (VALUES
      (izdelek.ProductId, N''Product.ItemID'', NULLIF(izdelek.ItemID, N'''')),
      (izdelek.ProductId, N''Product.EAN'', NULLIF(izdelek.EAN, N'''')),
      (izdelek.ProductId, N''Product.UoM'', NULLIF(izdelek.UoM, N'''')),
      (izdelek.ProductId, N''Product.Supplier'', NULLIF(izdelek.Supplier, N'''')),
      (izdelek.ProductId, N''Product.Manufacturer'', NULLIF(izdelek.Manufacturer, N'''')),
      (izdelek.ProductId, N''Product.AccountingGroup'', NULLIF(izdelek.AccountingGroup, N'''')),
      (izdelek.ProductId, N''Product.DiscountGroup'', NULLIF(izdelek.DiscountGroup, N'''')),
      (izdelek.ProductId, N''Product.ItemGroup'', NULLIF(izdelek.ItemGroup, N'''')),
      (izdelek.ProductId, N''Product.Department'', NULLIF(izdelek.Department, N'''')),
      (izdelek.ProductId, N''Product.VatRateId'', NULLIF(izdelek.VatRateId, N'''')),
      (izdelek.ProductId, N''Product.PriceListCode'', NULLIF(izdelek.PriceListCode, N'''')),
      (izdelek.ProductId, N''Product.HasSeries'', CONVERT(nvarchar(10), izdelek.HasSeries)),
      (izdelek.ProductId, N''Product.IsActive'', CONVERT(nvarchar(10), izdelek.IsActive)),
      (izdelek.ProductId, N''Product.WebPublish'', CONVERT(nvarchar(10), izdelek.WebPublish))
    ) AS polje (ProductId, FieldCode, Value)
    WHERE EXISTS (SELECT 1 FROM @Fields AS field WHERE field.FieldCode = polje.FieldCode)
    UNION ALL
    SELECT polje.ProductId, polje.FieldCode, polje.Value
    FROM @Products AS product
    INNER JOIN canon.ProductCommercial AS komerciala ON komerciala.ProductId = product.ProductId
    CROSS APPLY
    (VALUES
      (komerciala.ProductId, N''ProductCommercial.NetWeight'', NULLIF(CONVERT(nvarchar(50), komerciala.NetWeight), N'''')),
      (komerciala.ProductId, N''ProductCommercial.GrossWeight'', NULLIF(CONVERT(nvarchar(50), komerciala.GrossWeight), N'''')),
      (komerciala.ProductId, N''ProductCommercial.CustomsTariff'', NULLIF(komerciala.CustomsTariff, N'''')),
      (komerciala.ProductId, N''ProductCommercial.CountryOfOrigin'', NULLIF(komerciala.CountryOfOrigin, N'''')),
      (komerciala.ProductId, N''ProductCommercial.Pak1'', NULLIF(CONVERT(nvarchar(50), komerciala.Pak1), N'''')),
      (komerciala.ProductId, N''ProductCommercial.Pak2'', NULLIF(CONVERT(nvarchar(50), komerciala.Pak2), N'''')),
      (komerciala.ProductId, N''ProductCommercial.Volume'', NULLIF(CONVERT(nvarchar(50), komerciala.Volume), N'''')),
      (komerciala.ProductId, N''ProductCommercial.PackageLength'', NULLIF(CONVERT(nvarchar(50), komerciala.PackageLength), N'''')),
      (komerciala.ProductId, N''ProductCommercial.PackageWidth'', NULLIF(CONVERT(nvarchar(50), komerciala.PackageWidth), N'''')),
      (komerciala.ProductId, N''ProductCommercial.PackageHeight'', NULLIF(CONVERT(nvarchar(50), komerciala.PackageHeight), N'''')),
      (komerciala.ProductId, N''ProductCommercial.DimensionUnit'', NULLIF(komerciala.DimensionUnit, N''''))
    ) AS polje (ProductId, FieldCode, Value)
    WHERE EXISTS (SELECT 1 FROM @Fields AS field WHERE field.FieldCode = polje.FieldCode)
    UNION ALL
    SELECT besedilo.ProductId, CONCAT(N''ProductText.'', besedilo.TextType, N''.'', besedilo.Lang), NULLIF(besedilo.Value, N'''')
    FROM @Products AS product
    INNER JOIN canon.ProductText AS besedilo ON besedilo.ProductId = product.ProductId
    WHERE EXISTS (SELECT 1 FROM @Fields AS field WHERE field.FieldCode = CONCAT(N''ProductText.'', besedilo.TextType, N''.'', besedilo.Lang))
    UNION ALL
    SELECT atribut.ProductId, CONCAT(N''ProductAttribute.'', atribut.AttributeCode), NULLIF(atribut.Value, N'''')
    FROM @Products AS product
    INNER JOIN canon.ProductAttribute AS atribut ON atribut.ProductId = product.ProductId
    WHERE EXISTS (SELECT 1 FROM @Fields AS field WHERE field.FieldCode = CONCAT(N''ProductAttribute.'', atribut.AttributeCode))
    UNION ALL
    SELECT atribut.ProductId, CONCAT(N''ProductAttribute.'', atribut.AttributeCode, N''.'', atribut.LanguageCode), NULLIF(atribut.Value, N'''')
    FROM @Products AS product
    INNER JOIN canon.ProductAttribute AS atribut ON atribut.ProductId = product.ProductId
    WHERE atribut.LanguageCode IS NOT NULL
      AND EXISTS (SELECT 1 FROM @Fields AS field WHERE field.FieldCode = CONCAT(N''ProductAttribute.'', atribut.AttributeCode, N''.'', atribut.LanguageCode))
    UNION ALL
    SELECT kategorija.ProductId, N''ProductCategory.CategoryPath'', NULLIF(kategorija.CategoryPath, N'''')
    FROM @Products AS product
    INNER JOIN canon.ProductCategory AS kategorija ON kategorija.ProductId = product.ProductId
    WHERE EXISTS (SELECT 1 FROM @Fields AS field WHERE field.FieldCode = N''ProductCategory.CategoryPath'')
    UNION ALL
    SELECT medij.ProductId, N''ProductMedia.Url'', NULLIF(medij.Url, N'''')
    FROM @Products AS product
    INNER JOIN canon.ProductMedia AS medij ON medij.ProductId = product.ProductId
    WHERE EXISTS (SELECT 1 FROM @Fields AS field WHERE field.FieldCode = N''ProductMedia.Url'')
    UNION ALL
    SELECT cena.ProductId, N''ProductPrice.VatRate'', CONVERT(nvarchar(50), cena.VatRate)
    FROM @Products AS product
    INNER JOIN canon.ProductPrice AS cena ON cena.ProductId = product.ProductId
    WHERE cena.IsActive = 1
      AND EXISTS (SELECT 1 FROM @Fields AS field WHERE field.FieldCode = N''ProductPrice.VatRate'')
    UNION ALL
    SELECT cena.ProductId, N''ProductPrice.Gross'', CONVERT(nvarchar(50), cena.Net * (1 + cena.VatRate / 100))
    FROM @Products AS product
    INNER JOIN canon.ProductPrice AS cena ON cena.ProductId = product.ProductId
    WHERE cena.IsActive = 1 AND cena.Net * (1 + cena.VatRate / 100) > 0
      AND EXISTS (SELECT 1 FROM @Fields AS field WHERE field.FieldCode = N''ProductPrice.Gross'')
  ) AS vrednost
  WHERE vrednost.Value IS NOT NULL
  GROUP BY vrednost.ProductId, vrednost.FieldCode;

  /* 2) Kategorije po spletnih straneh. */
  SELECT
    category.ProductId,
    category.WebSite,
    CategoryPaths = STRING_AGG(CONVERT(nvarchar(max), category.CategoryPath), N'' | '') WITHIN GROUP (ORDER BY category.CategoryPath)
  FROM canon.ProductCategory AS category
  INNER JOIN @Products AS product ON product.ProductId = category.ProductId
  GROUP BY category.ProductId, category.WebSite;

  /* 3) Atributi. */
  SELECT
    attributeValue.ProductId,
    attributeValue.AttributeCode,
    Value = STRING_AGG(CONVERT(nvarchar(max), attributeValue.Value), N'' | '') WITHIN GROUP (ORDER BY attributeValue.Value)
  FROM canon.ProductAttribute AS attributeValue
  INNER JOIN @Products AS product ON product.ProductId = attributeValue.ProductId
  WHERE attributeValue.Value IS NOT NULL
  GROUP BY attributeValue.ProductId, attributeValue.AttributeCode;

  /* 4) Mediji — surovo, brez STRING_AGG in brez razvrstitve slika/dokument. C# razvrsti z
        MediaKindPolicy.Classify (isto pravilo kot stran Mediji) in sele nato zdruzi v celico. */
  SELECT media.ProductId, media.Url, media.Role, media.SortOrder
  FROM canon.ProductMedia AS media
  INNER JOIN @Products AS product ON product.ProductId = media.ProductId
  UNION ALL
  SELECT document.ProductId, document.Url, document.Role, document.SortOrder
  FROM canon.ProductDocument AS document
  INNER JOIN @Products AS product ON product.ProductId = document.ProductId
  ORDER BY ProductId, SortOrder;

  /*
    5) Sifrant atributov za naslove stolpcev.

    Trije viri, zdruzeni po slovenskem imenu, ker je to kljuc v canon.ProductAttribute:
      NABOR    — ucinkoviti nabor kategorije (dedovanje da canon.CategoryAttributeEffective);
                 kadar je kategorija dana, samo zanjo, sicer za vse kategorije danih izdelkov,
      VREDNOST — kar dani izdelki ze imajo zapisano,
      ZAHTEVA  — kar zahteva validacija.

    Prazen seznam izdelkov in brez kategorije pomeni ves sifrant: uvoz ne ve vnaprej, katere
    izdelke datoteka nosi, in mora prepoznati vsak stolpec, ki ga je izvoz izpisal.
  */
  DECLARE @Kategorije TABLE (CategoryTreeCode nvarchar(100) NOT NULL, CategoryCode nvarchar(200) NOT NULL,
    PRIMARY KEY (CategoryTreeCode, CategoryCode));

  IF @CategoryCode IS NOT NULL
  BEGIN
    INSERT @Kategorije (CategoryTreeCode, CategoryCode)
    SELECT DISTINCT node.CategoryTreeCode, node.CategoryCode
    FROM canon.Category AS node
    WHERE node.CategoryCode = @CategoryCode
      AND (@CategoryTreeCode IS NULL OR node.CategoryTreeCode = @CategoryTreeCode);
  END
  ELSE IF @VsiIzdelki = 0
  BEGIN
    INSERT @Kategorije (CategoryTreeCode, CategoryCode)
    SELECT DISTINCT node.CategoryTreeCode, node.CategoryCode
    FROM canon.ProductCategory AS productCategory
    INNER JOIN @Products AS product ON product.ProductId = productCategory.ProductId
    INNER JOIN canon.WebSite AS site ON site.WebSiteCode = productCategory.WebSite
    INNER JOIN canon.Category AS node
      ON node.CategoryTreeCode = site.CategoryTreeCode AND node.CategoryPath = productCategory.CategoryPath;
  END

  ;WITH nabor AS
  (
    SELECT effective.AttributeCode, effective.Level, MinSort = MIN(effective.SortOrder)
    FROM @Kategorije AS kategorija
    CROSS APPLY canon.CategoryAttributeEffective(kategorija.CategoryTreeCode, kategorija.CategoryCode) AS effective
    WHERE effective.Level <> N''EXCLUDED''
    GROUP BY effective.AttributeCode, effective.Level
  ),
  imena AS
  (
    SELECT
      AttributeName = COALESCE(translation.Name, nabor.AttributeCode),
      /* Ista koda v dveh kategorijah z razlicno ravnijo: obvelja strozja. REQUIRED je po
         abecedi za RECOMMENDED, zato MAX in ne MIN. */
      Level = MAX(nabor.Level),
      SortOrder = MIN(nabor.MinSort)
    FROM nabor
    LEFT JOIN canon.AttributeTranslation AS translation
      ON translation.AttributeCode = nabor.AttributeCode AND translation.LanguageCode = N''sl''
    GROUP BY COALESCE(translation.Name, nabor.AttributeCode)
  ),
  vsi AS
  (
    SELECT AttributeName, IsRequired = 0, InSet = 1, SetLevel = Level, SortOrder FROM imena
    UNION ALL
    SELECT DISTINCT attributeValue.AttributeCode, 0, 0, NULL, 1000
    FROM canon.ProductAttribute AS attributeValue
    WHERE (@VsiIzdelki = 1 AND @CategoryCode IS NULL)
       OR EXISTS (SELECT 1 FROM @Products AS product WHERE product.ProductId = attributeValue.ProductId)
    UNION ALL
    SELECT DISTINCT SUBSTRING(requirement.FieldCode, 18, 200), 1, 0, NULL, 0
    FROM val.FieldRequirement AS requirement
    INNER JOIN val.ValidationProfile AS validationProfile
      ON validationProfile.ValidationProfileId = requirement.ValidationProfileId
    WHERE requirement.IsActive = 1 AND requirement.IsRequired = 1 AND validationProfile.IsActive = 1
      AND requirement.FieldCode LIKE N''ProductAttribute.%''
      AND CHARINDEX(N''.'', SUBSTRING(requirement.FieldCode, 18, 200)) = 0
  )
  SELECT
    AttributeCode = vsi.AttributeName,
    Name = vsi.AttributeName,
    IsRequired = CONVERT(bit, MAX(vsi.IsRequired)),
    InSet = CONVERT(bit, MAX(vsi.InSet)),
    SetLevel = MAX(vsi.SetLevel),
    SortOrder = MIN(vsi.SortOrder)
  FROM vsi
  WHERE NULLIF(LTRIM(RTRIM(vsi.AttributeName)), N'''') IS NOT NULL
  GROUP BY vsi.AttributeName;

  /* 6) Register zahtevanih polj. */
  SELECT
    requirement.FieldCode,
    BlocksErp = CONVERT(bit, MAX(CASE WHEN exportProfile.ChannelCode LIKE N''%ERP%'' THEN 1 ELSE 0 END)),
    BlocksWeb = CONVERT(bit, MAX(CASE WHEN exportProfile.ChannelCode LIKE N''%ERP%'' THEN 0 ELSE 1 END))
  FROM val.FieldRequirement AS requirement
  INNER JOIN val.ValidationProfile AS validationProfile
    ON validationProfile.ValidationProfileId = requirement.ValidationProfileId
  INNER JOIN out.ExportProfile AS exportProfile
    ON exportProfile.ExportProfileId = validationProfile.ExportProfileId
  WHERE requirement.IsActive = 1 AND requirement.IsRequired = 1 AND validationProfile.IsActive = 1
  GROUP BY requirement.FieldCode;
END;');

/* ── GetDashboard ── */
EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetDashboard
  @OrganizationId int
AS
BEGIN
  /*
    218: isti stevci kot v 215 (ErpValidCount = izdelki brez odprte napake resnosti ERROR na
    profilu, ki blokira ERP; WebInvalidCount = izdelki z odprto tako napako na profilu, ki
    blokira splet in za izdelek velja), izracunani mnozicno namesto s koreliranim (NOT) EXISTS
    za vsak izdelek posebej. Izmerjeno pred: 12-16 s na podjetje (stran nadzorne plosce jo
    klice za vsako podjetje), po: pod sekundo.
  */
  SET NOCOUNT ON;

  CREATE TABLE #ErpBlocked (ProductId bigint NOT NULL PRIMARY KEY);
  CREATE TABLE #WebBlocked (ProductId bigint NOT NULL PRIMARY KEY);

  INSERT #ErpBlocked (ProductId)
  SELECT DISTINCT issueValue.ProductId
  FROM val.ProductIssue AS issueValue
  INNER JOIN canon.Product AS productValue
    ON productValue.ProductId = issueValue.ProductId AND productValue.OrganizationId = @OrganizationId
  INNER JOIN val.FieldRequirement AS requirementValue
    ON requirementValue.FieldRequirementId = issueValue.FieldRequirementId AND requirementValue.Severity = N''ERROR''
  INNER JOIN val.ValidationProfile AS profileValue
    ON profileValue.ValidationProfileId = issueValue.ValidationProfileId AND profileValue.BlocksErp = 1
  WHERE issueValue.IsActive = 1;

  INSERT #WebBlocked (ProductId)
  SELECT DISTINCT issueValue.ProductId
  FROM val.ProductIssue AS issueValue
  INNER JOIN canon.Product AS productValue
    ON productValue.ProductId = issueValue.ProductId AND productValue.OrganizationId = @OrganizationId
  INNER JOIN val.FieldRequirement AS requirementValue
    ON requirementValue.FieldRequirementId = issueValue.FieldRequirementId AND requirementValue.Severity = N''ERROR''
  INNER JOIN val.ValidationProfile AS profileValue
    ON profileValue.ValidationProfileId = issueValue.ValidationProfileId AND profileValue.BlocksWeb = 1
  WHERE issueValue.IsActive = 1
    AND (profileValue.Scope <> N''WEB'' OR EXISTS
      (SELECT 1 FROM pim.ProductWebShop AS shopValue
       WHERE shopValue.ProductId = productValue.ProductId
         AND shopValue.WebShopCode = profileValue.CategoryTreeCode
         AND shopValue.IsPublished = 1));

  DECLARE @CanonProductCount int = (SELECT COUNT(*) FROM canon.Product WHERE OrganizationId = @OrganizationId);

  SELECT
    @CanonProductCount AS CanonProductCount,
    (SELECT COUNT(*) FROM pim.Product WHERE OrganizationId = @OrganizationId) AS PimProductCount,
    @CanonProductCount - (SELECT COUNT(*) FROM #ErpBlocked) AS ErpValidCount,
    (SELECT COUNT(*) FROM #WebBlocked) AS WebInvalidCount,
    (SELECT COUNT(*) FROM raw.Inbox WHERE OrganizationId = @OrganizationId AND Status = N''Quarantined'') AS QuarantineCount;

  DROP TABLE #ErpBlocked;
  DROP TABLE #WebBlocked;
END;');

/* ── GetQualityOverview ── */
EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetQualityOverview
  @OrganizationId int,
  @TopRules int = 15
AS
BEGIN
  SET NOCOUNT ON;
  SET @TopRules = CASE WHEN @TopRules < 1 THEN 15 WHEN @TopRules > 100 THEN 100 ELSE @TopRules END;

  /* 218: odprte napake podjetja se preberejo enkrat v ozko zacasno tabelo (samo kljuci; opisna
     polja pridejo iz majhnih registrov ob branju), trije nabori spodaj jo berejo, namesto da bi
     vsak znova prebral 1,4 M odprtih napak s CROSS APPLY na vsak izdelek (izmerjeno 4 s).
     Pomen vseh treh naborov je nespremenjen. */
  CREATE TABLE #Odprte
  (
    ProductId bigint NOT NULL,
    ValidationProfileId int NOT NULL,
    FieldRequirementId int NULL,
    /* Koda tezave je potrebna samo, kadar zahteve ni (COALESCE spodaj); sicer ostane prazna. */
    IssueCode nvarchar(100) COLLATE DATABASE_DEFAULT NULL
  );
  INSERT #Odprte (ProductId, ValidationProfileId, FieldRequirementId, IssueCode)
  SELECT issueValue.ProductId, issueValue.ValidationProfileId, issueValue.FieldRequirementId,
    CASE WHEN issueValue.FieldRequirementId IS NULL THEN issueValue.IssueCode END
  FROM val.ProductIssue AS issueValue
  INNER JOIN canon.Product AS product ON product.ProductId = issueValue.ProductId AND product.OrganizationId = @OrganizationId
  WHERE issueValue.IsActive = 1;

  /* 1 - koliko je odprtega in kaj od tega zares blokira. */
  SELECT
    OpenIssueCount = COUNT_BIG(*),
    ErrorCount = SUM(CASE WHEN COALESCE(requirement.Severity, N''ERROR'') = N''ERROR'' THEN 1 ELSE 0 END),
    WarningCount = SUM(CASE WHEN requirement.Severity = N''WARNING'' THEN 1 ELSE 0 END),
    BlockingErpCount = SUM(CASE WHEN profileValue.BlocksErp = 1 THEN 1 ELSE 0 END),
    BlockingWebCount = SUM(CASE WHEN profileValue.BlocksWeb = 1 THEN 1 ELSE 0 END),
    AdvisoryCount = SUM(CASE WHEN profileValue.BlocksErp = 0 AND profileValue.BlocksWeb = 0 THEN 1 ELSE 0 END),
    AffectedProductCount = COUNT_BIG(DISTINCT odprta.ProductId)
  FROM #Odprte AS odprta
  INNER JOIN val.ValidationProfile AS profileValue ON profileValue.ValidationProfileId = odprta.ValidationProfileId
  LEFT JOIN val.FieldRequirement AS requirement ON requirement.FieldRequirementId = odprta.FieldRequirementId;

  /* 2 - katera zahteva ustavi najvec izdelkov; to je delovni seznam, ne statistika. */
  SELECT TOP (@TopRules)
    FieldCode = COALESCE(requirement.FieldCode, odprta.IssueCode),
    profileValue.ProfileCode, profileValue.BlocksErp, profileValue.BlocksWeb,
    Severity = COALESCE(requirement.Severity, N''ERROR''),
    IssueCount = COUNT_BIG(*),
    ProductCount = COUNT_BIG(DISTINCT odprta.ProductId)
  FROM #Odprte AS odprta
  INNER JOIN val.ValidationProfile AS profileValue ON profileValue.ValidationProfileId = odprta.ValidationProfileId
  LEFT JOIN val.FieldRequirement AS requirement ON requirement.FieldRequirementId = odprta.FieldRequirementId
  GROUP BY COALESCE(requirement.FieldCode, odprta.IssueCode), profileValue.ProfileCode,
    profileValue.BlocksErp, profileValue.BlocksWeb, COALESCE(requirement.Severity, N''ERROR'')
  ORDER BY COUNT_BIG(DISTINCT odprta.ProductId) DESC, COUNT_BIG(*) DESC;

  /* 3 - pri katerem dobavitelju se napake kopicijo. Izdelek brez napak steje v ProductCount
     z IssueCount 0 (isto kot prejsnji CROSS APPLY COUNT na vsak izdelek). */
  SELECT TOP (@TopRules)
    Supplier = COALESCE(product.Supplier, N''(brez dobavitelja)''),
    ProductCount = COUNT_BIG(*),
    WithIssuesCount = SUM(CASE WHEN ISNULL(issueCounter.IssueCount, 0) > 0 THEN 1 ELSE 0 END),
    IssueCount = SUM(ISNULL(issueCounter.IssueCount, 0))
  FROM canon.Product AS product
  LEFT JOIN
  (
    SELECT ProductId, IssueCount = COUNT_BIG(*)
    FROM #Odprte
    GROUP BY ProductId
  ) AS issueCounter ON issueCounter.ProductId = product.ProductId
  WHERE product.OrganizationId = @OrganizationId
  GROUP BY COALESCE(product.Supplier, N''(brez dobavitelja)'')
  HAVING SUM(ISNULL(issueCounter.IssueCount, 0)) > 0
  ORDER BY SUM(CASE WHEN ISNULL(issueCounter.IssueCount, 0) > 0 THEN 1 ELSE 0 END) DESC, COUNT_BIG(*) DESC;

  DROP TABLE #Odprte;
END;');

/* ── ProductChannelReadiness ── */
EXEC(N'CREATE OR ALTER VIEW val.ProductChannelReadiness
AS
/*
  218: isti stolpci in isti pomen kot prej (migracija 194), a mnozicno: stevci napak in zadrzkov
  pridejo iz enega GROUP BY po izdelku, ne iz OUTER APPLY za vsak izdelek posebej, in naziv
  pride naravnost iz canon.ProductText (TITLE_ERP, sl) namesto prek pogleda canon.FieldValue za
  vsak izdelek posebej. Izmerjeno pred: intranet.GetQualityProducts (SELECT * INTO #Rows iz tega
  pogleda za eno podjetje) 24-39 s; stran /kakovost/artikli je padla na 30 s meji ukaza.
  Opomba: prejsnji COALESCE je najprej iskal kodo "Product.Name", ki je v canon.FieldValue ni,
  zato je vedno obveljal ProductText.TITLE_ERP.sl - tu je to zapisano neposredno.
*/
SELECT product.ProductId,product.OrganizationId,product.ItemID,product.EAN,
  ProductName=COALESCE(NULLIF(title.Value,N''''),product.ItemID),
  product.IsActive,product.WebPublish,product.ValidationStatus,product.Completeness,product.LastValidatedUtc,
  IsValidationStale=CONVERT(bit,CASE WHEN product.LastValidatedUtc IS NULL
    OR product.LastValidatedUtc<DATEADD(hour,-2,SYSUTCDATETIME()) THEN 1 ELSE 0 END),
  ErrorCount=CONVERT(bigint,ISNULL(issueCount.ErrorCount,0)),
  WarningCount=CONVERT(bigint,ISNULL(issueCount.WarningCount,0)),
  ErpBlockingCount=CONVERT(bigint,ISNULL(issueCount.ErpBlockingCount,0)),
  WebBlockingCount=CONVERT(bigint,ISNULL(issueCount.WebBlockingCount,0)),
  HasGlobalHold=CONVERT(bit,ISNULL(holdCount.HasGlobalHold,0)),
  HasErpHold=CONVERT(bit,ISNULL(holdCount.HasErpHold,0)),
  HasWebHold=CONVERT(bit,ISNULL(holdCount.HasWebHold,0)),
  IsErpReady=CONVERT(bit,CASE WHEN product.IsActive=1 AND product.LastValidatedUtc IS NOT NULL
    AND ISNULL(issueCount.ErpBlockingCount,0)=0
    AND ISNULL(holdCount.HasGlobalHold,0)=0 AND ISNULL(holdCount.HasErpHold,0)=0 THEN 1 ELSE 0 END),
  IsWebReady=CONVERT(bit,CASE WHEN product.IsActive=1 AND product.WebPublish=1 AND product.LastValidatedUtc IS NOT NULL
    AND ISNULL(issueCount.WebBlockingCount,0)=0
    AND ISNULL(holdCount.HasGlobalHold,0)=0 AND ISNULL(holdCount.HasWebHold,0)=0 THEN 1 ELSE 0 END)
FROM canon.Product AS product
LEFT JOIN canon.ProductText AS title
  ON title.ProductId=product.ProductId AND title.TextType=N''TITLE_ERP'' AND title.Lang=N''sl''
LEFT JOIN
(
  SELECT issue.ProductId,
    ErrorCount=SUM(CASE WHEN requirement.Severity=N''ERROR'' THEN 1 ELSE 0 END),
    WarningCount=SUM(CASE WHEN requirement.Severity=N''WARNING'' THEN 1 ELSE 0 END),
    ErpBlockingCount=SUM(CASE WHEN requirement.Severity=N''ERROR'' AND profile.BlocksErp=1 THEN 1 ELSE 0 END),
    WebBlockingCount=SUM(CASE WHEN requirement.Severity=N''ERROR'' AND profile.BlocksWeb=1 THEN 1 ELSE 0 END)
  FROM val.ProductIssue AS issue
  INNER JOIN val.FieldRequirement AS requirement ON requirement.FieldRequirementId=issue.FieldRequirementId AND requirement.IsActive=1
  INNER JOIN val.ValidationProfile AS profile ON profile.ValidationProfileId=issue.ValidationProfileId AND profile.IsActive=1
  WHERE issue.IsActive=1
  GROUP BY issue.ProductId
) AS issueCount ON issueCount.ProductId=product.ProductId
LEFT JOIN
(
  SELECT ProductId,
    HasGlobalHold=MAX(CASE WHEN ChannelCode=N''ALL'' THEN 1 ELSE 0 END),
    HasErpHold=MAX(CASE WHEN ChannelCode=N''ERP'' THEN 1 ELSE 0 END),
    HasWebHold=MAX(CASE WHEN ChannelCode=N''WEB'' THEN 1 ELSE 0 END)
  FROM val.ProductHold WHERE IsActive=1
  GROUP BY ProductId
) AS holdCount ON holdCount.ProductId=product.ProductId;');

/* ── GetStockByItem ── */
EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetStockByItem
  @OrganizationId int = NULL,
  @Skip int = 0,
  @Take int = 50,
  @Search nvarchar(200) = NULL,
  @SourceCode nvarchar(100) = NULL,
  @Availability nvarchar(20) = NULL,
  @MaxAgeHours int = NULL,
  @Language nvarchar(20) = N''sl''
AS
BEGIN
  SET NOCOUNT ON;

  SET @Skip = CASE WHEN @Skip < 0 THEN 0 ELSE @Skip END;
  /* 218: meja 200 je izvoz zaloge (StockReadService.BuildStockWorkbookAsync) prisilila v desetine
     klicev po 200 vrstic, vsak pa znova sestavi celo #StockByItem (izmerjeno 1-6 s na klic, izvoz
     44 s za eno podjetje). Stran bere po 50, izvoz po 20.000 - v enem klicu. */
  SET @Take = CASE WHEN @Take < 1 THEN 50 WHEN @Take > 20000 THEN 20000 ELSE @Take END;
  SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'''');
  SET @SourceCode = NULLIF(LTRIM(RTRIM(@SourceCode)), N'''');
  SET @Availability = NULLIF(UPPER(LTRIM(RTRIM(@Availability))), N'''');
  SET @Language = COALESCE(NULLIF(LTRIM(RTRIM(@Language)), N''''), N''sl'');
  IF @Availability NOT IN (N''IN_STOCK'', N''OUT_OF_STOCK'', N''INCOMING'') SET @Availability = NULL;
  IF @MaxAgeHours IS NOT NULL AND @MaxAgeHours < 1 SET @MaxAgeHours = NULL;

  DECLARE @Like nvarchar(210) = CASE WHEN @Search IS NULL THEN NULL ELSE N''%'' + @Search + N''%'' END;
  DECLARE @Now datetime2(3) = SYSUTCDATETIME();

  CREATE TABLE #StockByItem
  (
    GroupKey nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY,
    OrganizationId int NOT NULL,
    OrganizationName nvarchar(200) NOT NULL,
    NormalizedItemId nvarchar(200) NULL,
    Ean nvarchar(100) NULL,
    MatchedProductId bigint NULL,
    ProductName nvarchar(1000) NULL,
    ProductItemId nvarchar(200) NULL,
    HasErp bit NOT NULL,
    ErpWarehouse nvarchar(1000) NULL,
    ErpQuantity decimal(18,4) NOT NULL,
    ErpAvailable decimal(18,4) NOT NULL,
    ErpOrdered decimal(18,4) NOT NULL,
    ErpForShipment decimal(18,4) NOT NULL,
    ErpSupplierOrdered decimal(18,4) NOT NULL,
    ErpIncomingQuantity decimal(18,4) NULL,
    ErpIncomingDate datetime2(3) NULL,
    ErpSnapshotUtc datetime2(3) NULL,
    HasSupplier bit NOT NULL,
    SupplierCode nvarchar(1000) NULL,
    SupplierQuantity decimal(18,4) NOT NULL,
    SupplierIncoming decimal(18,4) NULL,
    SupplierIncomingDate datetime2(3) NULL,
    SupplierSnapshotUtc datetime2(3) NULL,
    MinimumStock decimal(18,4) NULL,
    MaximumStock decimal(18,4) NULL,
    CombinedQuantity decimal(18,4) NOT NULL,
    CombinedIncoming decimal(18,4) NOT NULL
  );

  ;WITH filtered AS
  (
    SELECT position.PositionId, position.NormalizedItemId, position.Ean, position.MatchedProductId,
      position.Quantity, position.AvailabilityDate, position.IncomingQuantity, position.AvailableQuantity,
      position.OrderedQuantity, position.ForShipmentQuantity, position.SupplierOrderedQuantity,
      connector.ConnectorType, connector.SourceCode, snapshot.OrganizationId, snapshot.SnapshotUtc,
      GroupKey = ISNULL(CONVERT(nvarchar(20), position.MatchedProductId), CONCAT(N''U:'', connector.SourceCode, N'':'', position.NormalizedItemId)),
      Warehouse = CASE WHEN connector.ConnectorType = N''SAOP'' THEN registry.WarehouseLabel END
    FROM stock.Position AS position
    INNER JOIN stock.Snapshot AS snapshot ON snapshot.SnapshotId = position.SnapshotId AND snapshot.IsActive = 1
    INNER JOIN map.SourceConnector AS connector ON connector.SourceConnectorId = snapshot.SourceConnectorId
    LEFT JOIN out.ExportStockSource AS registry
      ON registry.OrganizationId = snapshot.OrganizationId AND registry.StockOrganizationId = snapshot.OrganizationId
     AND registry.SourceCode = connector.SourceCode AND registry.IsActive = 1
    WHERE (@OrganizationId IS NULL OR snapshot.OrganizationId = @OrganizationId)
      AND (@SourceCode IS NULL OR connector.SourceCode = @SourceCode)
      AND (@Like IS NULL OR position.NormalizedItemId LIKE @Like OR position.Ean LIKE @Like)
      AND (@MaxAgeHours IS NULL OR snapshot.SnapshotUtc >= DATEADD(hour, -@MaxAgeHours, @Now))
  ),
  delivery AS
  (
    SELECT OrganizationId, NormalizedItemId,
      DeliveryDate = MIN(DeliveryDate), Quantity = SUM(ISNULL(Quantity, 0))
    FROM stock.ItemDeliveryDate
    WHERE @OrganizationId IS NULL OR OrganizationId = @OrganizationId
    GROUP BY OrganizationId, NormalizedItemId
  ),
  -- Skladisce/dobavitelja zdruzi iz RAZLICNIH virov v skupini, ne enkrat na pozicijo: en
  -- dobavitelj lahko v isti skupini nastopi z vec pozicijami (vec njegovih sifer je pripetih na
  -- isti PIM izdelek) — STRING_AGG neposredno na "filtered" bi zato ponovil isto kodo vira
  -- tolikokrat, kolikor ima pozicij (opazovano: "BT_STOCK + BT_STOCK + ..." desetkrat), dokler
  -- ne bi podrl sirine stolpca. DISTINCT najprej odpravi to podvajanje.
  sourceLabels AS
  (
    SELECT DISTINCT f.GroupKey, f.ConnectorType, f.SourceCode, f.Warehouse
    FROM filtered AS f
  ),
  labels AS
  (
    SELECT GroupKey,
      ErpWarehouse = STRING_AGG(CASE WHEN ConnectorType = N''SAOP'' THEN ISNULL(Warehouse, SourceCode) END, N'' + ''),
      SupplierCode = STRING_AGG(CASE WHEN ConnectorType <> N''SAOP'' THEN SourceCode END, N'' + '')
    FROM sourceLabels
    GROUP BY GroupKey
  ),
  aggregated AS
  (
    SELECT
      f.GroupKey,
      OrganizationId = MAX(f.OrganizationId),
      NormalizedItemId = MAX(f.NormalizedItemId),
      Ean = MAX(f.Ean),
      MatchedProductId = MAX(f.MatchedProductId),
      HasErp = MAX(CASE WHEN f.ConnectorType = N''SAOP'' THEN 1 ELSE 0 END),
      ErpQuantity = SUM(CASE WHEN f.ConnectorType = N''SAOP'' THEN f.Quantity ELSE 0 END),
      -- ISNULL na vsakem polju, ne samo na vsoti: brez tega SUM cez vrstice enega vira, kjer
      -- polje sploh ni znano (navaden GetStocks nima Available/Ordered/ForShipment/SupplierOrdered
      -- — to poroca samo registrirani pogled, migracija 145), vrne NULL namesto 0 in podre NOT
      -- NULL stolpec. Prav to je bil razlog, da je stran delala samo za Vidadrio (registrirani
      -- pogled) in ne za druga podjetja (navaden GetStocks).
      ErpAvailable = SUM(CASE WHEN f.ConnectorType = N''SAOP'' THEN ISNULL(f.AvailableQuantity, 0) ELSE 0 END),
      ErpOrdered = SUM(CASE WHEN f.ConnectorType = N''SAOP'' THEN ISNULL(f.OrderedQuantity, 0) ELSE 0 END),
      ErpForShipment = SUM(CASE WHEN f.ConnectorType = N''SAOP'' THEN ISNULL(f.ForShipmentQuantity, 0) ELSE 0 END),
      ErpSupplierOrdered = SUM(CASE WHEN f.ConnectorType = N''SAOP'' THEN ISNULL(f.SupplierOrderedQuantity, 0) ELSE 0 END),
      ErpOwnIncoming = SUM(CASE WHEN f.ConnectorType = N''SAOP'' THEN f.IncomingQuantity ELSE 0 END),
      ErpOwnIncomingDate = MIN(CASE WHEN f.ConnectorType = N''SAOP'' THEN f.AvailabilityDate END),
      ErpSnapshotUtc = MAX(CASE WHEN f.ConnectorType = N''SAOP'' THEN f.SnapshotUtc END),
      HasSupplier = MAX(CASE WHEN f.ConnectorType <> N''SAOP'' THEN 1 ELSE 0 END),
      SupplierQuantity = SUM(CASE WHEN f.ConnectorType <> N''SAOP'' THEN f.Quantity ELSE 0 END),
      SupplierIncoming = SUM(CASE WHEN f.ConnectorType <> N''SAOP'' THEN f.IncomingQuantity ELSE 0 END),
      SupplierIncomingDate = MIN(CASE WHEN f.ConnectorType <> N''SAOP'' THEN f.AvailabilityDate END),
      SupplierSnapshotUtc = MAX(CASE WHEN f.ConnectorType <> N''SAOP'' THEN f.SnapshotUtc END)
    FROM filtered AS f
    GROUP BY f.GroupKey
  )
  INSERT #StockByItem
  (
    GroupKey, OrganizationId, OrganizationName, NormalizedItemId, Ean, MatchedProductId, ProductName, ProductItemId,
    HasErp, ErpWarehouse, ErpQuantity, ErpAvailable, ErpOrdered, ErpForShipment, ErpSupplierOrdered,
    ErpIncomingQuantity, ErpIncomingDate, ErpSnapshotUtc,
    HasSupplier, SupplierCode, SupplierQuantity, SupplierIncoming, SupplierIncomingDate, SupplierSnapshotUtc,
    MinimumStock, MaximumStock, CombinedQuantity, CombinedIncoming
  )
  SELECT
    aggregated.GroupKey, aggregated.OrganizationId, organization.Name,
    aggregated.NormalizedItemId, aggregated.Ean, aggregated.MatchedProductId,
    productTitle.Value, matched.ItemID,
    aggregated.HasErp, labels.ErpWarehouse, aggregated.ErpQuantity, aggregated.ErpAvailable,
    aggregated.ErpOrdered, aggregated.ErpForShipment, aggregated.ErpSupplierOrdered,
    ErpIncomingQuantity = COALESCE(NULLIF(aggregated.ErpOwnIncoming, 0), delivery.Quantity),
    ErpIncomingDate = COALESCE(aggregated.ErpOwnIncomingDate, delivery.DeliveryDate),
    aggregated.ErpSnapshotUtc,
    aggregated.HasSupplier, labels.SupplierCode, aggregated.SupplierQuantity,
    aggregated.SupplierIncoming, aggregated.SupplierIncomingDate, aggregated.SupplierSnapshotUtc,
    policyValue.MinimumStock, policyValue.MaximumStock,
    CombinedQuantity = aggregated.ErpQuantity + aggregated.SupplierQuantity,
    CombinedIncoming = ISNULL(COALESCE(NULLIF(aggregated.ErpOwnIncoming, 0), delivery.Quantity), 0) + ISNULL(aggregated.SupplierIncoming, 0)
  FROM aggregated
  INNER JOIN labels ON labels.GroupKey = aggregated.GroupKey
  LEFT JOIN delivery ON delivery.OrganizationId = aggregated.OrganizationId AND delivery.NormalizedItemId = aggregated.NormalizedItemId
  LEFT JOIN canon.Product AS matched ON matched.ProductId = aggregated.MatchedProductId
  INNER JOIN dbo.OrganizationConfig AS organization ON organization.OrganizationId = aggregated.OrganizationId
  OUTER APPLY
  (
    SELECT TOP (1) textValue.Value
    FROM canon.ProductText AS textValue
    WHERE textValue.ProductId = aggregated.MatchedProductId AND textValue.TextType IN (N''WEB_TITLE'', N''TITLE_ERP'')
    ORDER BY CASE WHEN textValue.TextType = N''WEB_TITLE'' THEN 0 ELSE 1 END,
      CASE WHEN textValue.Lang = @Language THEN 0 WHEN textValue.Lang = N''sl'' THEN 1 ELSE 2 END, textValue.Lang
  ) AS productTitle
  OUTER APPLY
  (
    SELECT TOP (1) top1.MinimumStock, top1.MaximumStock
    FROM canon.ProductStockPolicy AS top1
    WHERE top1.ProductId = aggregated.MatchedProductId
    ORDER BY top1.WarehouseCode
  ) AS policyValue
  OPTION (RECOMPILE, MAXDOP 1);

  SELECT GroupKey, OrganizationId, OrganizationName, NormalizedItemId, Ean, MatchedProductId, ProductName, ProductItemId,
    HasErp, ErpWarehouse, ErpQuantity, ErpAvailable, ErpOrdered, ErpForShipment, ErpSupplierOrdered,
    ErpIncomingQuantity, ErpIncomingDate, ErpSnapshotUtc,
    HasSupplier, SupplierCode, SupplierQuantity, SupplierIncoming, SupplierIncomingDate, SupplierSnapshotUtc,
    MinimumStock, MaximumStock
  FROM #StockByItem
  WHERE
  (
    @Availability IS NULL
    OR (@Availability = N''IN_STOCK'' AND CombinedQuantity > 0)
    OR (@Availability = N''OUT_OF_STOCK'' AND CombinedQuantity <= 0)
    OR (@Availability = N''INCOMING'' AND CombinedIncoming > 0)
  )
  ORDER BY NormalizedItemId, GroupKey
  OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY;

  SELECT TotalCount = COUNT_BIG(*)
  FROM #StockByItem
  WHERE
  (
    @Availability IS NULL
    OR (@Availability = N''IN_STOCK'' AND CombinedQuantity > 0)
    OR (@Availability = N''OUT_OF_STOCK'' AND CombinedQuantity <= 0)
    OR (@Availability = N''INCOMING'' AND CombinedIncoming > 0)
  );

  DROP TABLE #StockByItem;
END;');

/* ── GetCategoryTreeNodes ── */
EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetCategoryTreeNodes
  @CategoryTreeCode nvarchar(100),
  @Iskanje nvarchar(200) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  /*
    Izbirnik kategorije. Pot je slovenska (najnizja SortOrder aktivne spletne strani tega
    drevesa), ker clovek izbira po tem, kar vidi v trgovini, ne po sifri.

    218: prevedene poti drevesa se izracunajo ENKRAT v zacasno tabelo. canon.CategoryPathTranslated
    je rekurzivni pogled cez vse kategorije in jezike; v OUTER APPLY na vsako vozlisce ga je SQL
    Server izracunal za vsako vozlisce posebej (izmerjeno: 0,5 s na izracun x stevilo vozlisc).
  */
  CREATE TABLE #Pot (CategoryCode nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL, SortOrder int NOT NULL,
                     CategoryPath nvarchar(1000) COLLATE DATABASE_DEFAULT NULL);
  INSERT #Pot (CategoryCode, SortOrder, CategoryPath)
  SELECT prevod.CategoryCode, spletna.SortOrder, prevod.CategoryPath
  FROM canon.CategoryPathTranslated prevod
  INNER JOIN canon.WebSite spletna
    ON spletna.CategoryTreeCode = prevod.CategoryTreeCode AND spletna.LanguageCode = prevod.LanguageCode
  WHERE prevod.CategoryTreeCode = @CategoryTreeCode AND spletna.IsActive = 1;

  SELECT
    kategorija.CategoryCode,
    kategorija.CategoryName,
    kategorija.LevelNo,
    kategorija.ParentCategoryCode,
    pot.CategoryPath
  FROM canon.Category kategorija
  OUTER APPLY
  (
    SELECT TOP (1) prevod.CategoryPath
    FROM #Pot prevod
    WHERE prevod.CategoryCode = kategorija.CategoryCode
    ORDER BY prevod.SortOrder
  ) pot
  WHERE kategorija.CategoryTreeCode = @CategoryTreeCode AND kategorija.IsActive = 1
    AND (@Iskanje IS NULL OR kategorija.CategoryName LIKE N''%'' + @Iskanje + N''%''
         OR ISNULL(pot.CategoryPath, N'''') LIKE N''%'' + @Iskanje + N''%'')
  ORDER BY pot.CategoryPath, kategorija.CategoryCode;

  DROP TABLE #Pot;
END;');

/* ── GetPriceChecks ── */
EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetPriceChecks
  @OrganizationId int,
  @ProductId bigint = NULL,
  @CheckCode nvarchar(60) = NULL,
  @Context nvarchar(100) = NULL,
  @Search nvarchar(200) = NULL,
  @Skip int = 0,
  @Take int = 50
AS
BEGIN
  SET NOCOUNT ON;

  SET @Skip = CASE WHEN @Skip < 0 THEN 0 ELSE @Skip END;
  SET @Take = CASE WHEN @Take < 1 THEN 50 WHEN @Take > 2000 THEN 2000 ELSE @Take END;
  SET @CheckCode = NULLIF(UPPER(LTRIM(RTRIM(@CheckCode))), N'''');
  SET @Context = NULLIF(LTRIM(RTRIM(@Context)), N'''');
  SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'''');

  /* 150: prag faktorja je vrstica registra pim.CheckThreshold — najprej vrstica podjetja,
     sicer privzeta (OrganizationId NULL), sicer 2,00. Uporabnik ga ureja na /preverbe. */
  DECLARE @MarginThreshold decimal(18,4) = COALESCE(
    (SELECT TOP (1) Threshold FROM pim.CheckThreshold WHERE CheckCode = N''FAKTOR_MARZE'' AND OrganizationId = @OrganizationId AND IsActive = 1),
    (SELECT TOP (1) Threshold FROM pim.CheckThreshold WHERE CheckCode = N''FAKTOR_MARZE'' AND OrganizationId IS NULL AND IsActive = 1),
    2.0);
  DECLARE @Like nvarchar(210) = CASE WHEN @Search IS NULL THEN NULL ELSE N''%'' + @Search + N''%'' END;

  /* Aktivni izdelki tega podjetja; ozek nabor, na katerem se racunajo vse preverbe.
     218: zacasna tabela namesto tabelne spremenljivke (pri 98.000 izdelkih je optimizer brez
     statistike izbral nacrte za 5-8 s na klic; stran /preverbe klice proceduro veckrat vzporedno)
     in naziv se poisce samo za vrnjene vrstice (spodaj), ne za vsak izdelek podjetja vnaprej.
     Iskanje po nazivu ostane: zadene katerokoli spletni ali ERP naziv izdelka. */
  CREATE TABLE #Scope (ProductId bigint PRIMARY KEY, ItemID nvarchar(200) COLLATE DATABASE_DEFAULT NULL);
  INSERT #Scope (ProductId, ItemID)
  SELECT product.ProductId, product.ItemID
  FROM canon.Product AS product
  WHERE product.OrganizationId = @OrganizationId AND product.IsActive = 1
    AND (@ProductId IS NULL OR product.ProductId = @ProductId)
    AND (@Like IS NULL OR product.ItemID LIKE @Like OR product.EAN LIKE @Like
      OR EXISTS (SELECT 1 FROM canon.ProductText AS textValue
                 WHERE textValue.ProductId = product.ProductId AND textValue.TextType IN (N''WEB_TITLE'', N''TITLE_ERP'')
                   AND textValue.Value LIKE @Like));

  ;WITH activePrice AS
  (
    SELECT price.ProductId, price.PriceList, price.Net, price.VatRate, price.ValidFrom,
      Duplicates = COUNT(*) OVER (PARTITION BY price.ProductId, price.PriceList),
      Ordinal = ROW_NUMBER() OVER (PARTITION BY price.ProductId, price.PriceList ORDER BY price.ValidFrom DESC)
    FROM canon.ProductPrice AS price
    INNER JOIN #Scope AS scopeValue ON scopeValue.ProductId = price.ProductId
    WHERE price.IsActive = 1
  ),
  purchase AS
  (
    SELECT ProductId, PurchaseNet = MIN(Net)
    FROM activePrice WHERE PriceList = N''NAB'' AND Net > 0
    GROUP BY ProductId
  ),
  checks AS
  (
    /* Manjka aktivna cena v obveznem ceniku. */
    SELECT scopeValue.ProductId, CheckCode = required.CheckCode, Context = required.PriceList,
      Detail = N''Izdelek nima aktivne cene v ceniku '' + required.PriceList + N''.'',
      SalesPrice = CONVERT(decimal(18,4), NULL), PurchasePrice = CONVERT(decimal(18,4), NULL),
      MarginFactor = CONVERT(decimal(18,4), NULL), UnitBasis = CONVERT(nvarchar(40), NULL),
      ObservedUtc = CONVERT(datetime2(3), NULL)
    FROM #Scope AS scopeValue
    CROSS JOIN (VALUES (N''B2C'', N''CENA_MANJKA_B2C''), (N''B2B'', N''CENA_MANJKA_B2B'')) AS required (PriceList, CheckCode)
    WHERE NOT EXISTS
    (
      SELECT 1 FROM activePrice AS priceValue
      WHERE priceValue.ProductId = scopeValue.ProductId AND priceValue.PriceList = required.PriceList
    )

    UNION ALL

    /* Aktivna cena je nic ali manj. */
    SELECT priceValue.ProductId, N''CENA_NIC'', priceValue.PriceList,
      N''Aktivna cena v ceniku '' + priceValue.PriceList + N'' je '' + CONVERT(nvarchar(40), priceValue.Net) + N''.'',
      priceValue.Net, NULL, NULL, NULL, NULL
    FROM activePrice AS priceValue
    WHERE priceValue.Ordinal = 1 AND priceValue.Net <= 0

    UNION ALL

    /* Aktivna cena brez stopnje DDV. */
    SELECT priceValue.ProductId, N''DDV_MANJKA'', priceValue.PriceList,
      N''Aktivna cena v ceniku '' + priceValue.PriceList + N'' nima stopnje DDV.'',
      priceValue.Net, NULL, NULL, NULL, NULL
    FROM activePrice AS priceValue
    WHERE priceValue.Ordinal = 1 AND (priceValue.VatRate IS NULL OR priceValue.VatRate = 0)

    UNION ALL

    /* Vec kot ena aktivna cena za isti izdelek in cenik. */
    SELECT priceValue.ProductId, N''PODVOJEN_ZAPIS'', priceValue.PriceList,
      N''Cenik '' + priceValue.PriceList + N'' ima '' + CONVERT(nvarchar(20), priceValue.Duplicates) + N'' aktivnih zapisov cene.'',
      priceValue.Net, NULL, NULL, NULL, NULL
    FROM activePrice AS priceValue
    WHERE priceValue.Ordinal = 1 AND priceValue.Duplicates > 1

    UNION ALL

    /* Cena je oznacena kot aktivna, njena veljavnost pa se ni nastopila. */
    SELECT priceValue.ProductId, N''CENIK_POTEKEL'', priceValue.PriceList,
      N''Cena velja od '' + CONVERT(nvarchar(20), priceValue.ValidFrom, 104) + N'', a je ze oznacena kot aktivna.'',
      priceValue.Net, NULL, NULL, NULL, CONVERT(datetime2(3), priceValue.ValidFrom)
    FROM activePrice AS priceValue
    WHERE priceValue.Ordinal = 1 AND priceValue.ValidFrom > SYSUTCDATETIME()

    UNION ALL

    /* Faktor prodajne in nabavne cene pod pragom. */
    SELECT priceValue.ProductId, N''FAKTOR_MARZE'', priceValue.PriceList,
      N''Faktor '' + CONVERT(nvarchar(20), CONVERT(decimal(18,2), priceValue.Net / purchaseValue.PurchaseNet))
        + N'' je pod pragom '' + CONVERT(nvarchar(20), CONVERT(decimal(18,2), @MarginThreshold)) + N''.'',
      priceValue.Net, purchaseValue.PurchaseNet,
      CONVERT(decimal(18,4), priceValue.Net / purchaseValue.PurchaseNet), N''cenik NAB'', NULL
    FROM activePrice AS priceValue
    INNER JOIN purchase AS purchaseValue ON purchaseValue.ProductId = priceValue.ProductId
    WHERE priceValue.Ordinal = 1 AND priceValue.PriceList IN (N''B2B'', N''B2C'')
      AND priceValue.Net > 0 AND priceValue.Net / purchaseValue.PurchaseNet < @MarginThreshold
      AND priceValue.Net >= purchaseValue.PurchaseNet

    UNION ALL

    /* Prodajna cena pod nabavno je svoja preverba, ne le nizek faktor. */
    SELECT priceValue.ProductId, N''CENA_POD_NABAVNO'', priceValue.PriceList,
      N''Prodajna cena '' + CONVERT(nvarchar(40), priceValue.Net) + N'' je nizja od nabavne ''
        + CONVERT(nvarchar(40), purchaseValue.PurchaseNet) + N''.'',
      priceValue.Net, purchaseValue.PurchaseNet,
      CONVERT(decimal(18,4), priceValue.Net / NULLIF(purchaseValue.PurchaseNet, 0)), N''cenik NAB'', NULL
    FROM activePrice AS priceValue
    INNER JOIN purchase AS purchaseValue ON purchaseValue.ProductId = priceValue.ProductId
    WHERE priceValue.Ordinal = 1 AND priceValue.PriceList IN (N''B2B'', N''B2C'')
      AND priceValue.Net > 0 AND priceValue.Net < purchaseValue.PurchaseNet
  )
  /* 132: preverbe se zberejo enkrat v zacasno tabelo, seznam in stevec pa bereta iz nje. */
  SELECT checks.ProductId, scopeValue.ItemID, checks.CheckCode, checks.Context,
    checks.Detail, checks.ObservedUtc, checks.SalesPrice, checks.PurchasePrice,
    checks.MarginFactor, checks.UnitBasis
  INTO #PriceChecks
  FROM checks
  INNER JOIN #Scope AS scopeValue ON scopeValue.ProductId = checks.ProductId
  WHERE (@CheckCode IS NULL OR checks.CheckCode = @CheckCode)
    AND (@Context IS NULL OR checks.Context = @Context)
  OPTION (RECOMPILE);

  /* Naziv samo za vrnjeno stran: isto pravilo izbire naziva kot prej (splet pred ERP, sl pred ostalimi). */
  SELECT page.ProductId, page.ItemID, Name = COALESCE(title.Value, page.ItemID), page.CheckCode, page.Context, page.Detail, page.ObservedUtc,
    page.SalesPrice, page.PurchasePrice, page.MarginFactor, page.UnitBasis
  FROM
  (
    SELECT ProductId, ItemID, CheckCode, Context, Detail, ObservedUtc, SalesPrice, PurchasePrice, MarginFactor, UnitBasis
    FROM #PriceChecks
    ORDER BY ItemID, CheckCode, Context
    OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY
  ) AS page
  OUTER APPLY
  (
    SELECT TOP (1) textValue.Value
    FROM canon.ProductText AS textValue
    WHERE textValue.ProductId = page.ProductId AND textValue.TextType IN (N''WEB_TITLE'', N''TITLE_ERP'')
    ORDER BY CASE WHEN textValue.TextType = N''WEB_TITLE'' THEN 0 ELSE 1 END,
      CASE WHEN textValue.Lang = N''sl'' THEN 0 ELSE 1 END, textValue.Lang
  ) AS title
  ORDER BY page.ItemID, page.CheckCode, page.Context;

  SELECT TotalCount = COUNT_BIG(*) FROM #PriceChecks;

  DROP TABLE #PriceChecks;
  DROP TABLE #Scope;
END;');

/* ── GetProductOrigin ── */
EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetProductOrigin
  @OrganizationId int,
  @ProductId bigint
AS
BEGIN
  SET NOCOUNT ON;

  DECLARE @ItemID nvarchar(450), @EAN nvarchar(450);
  SELECT @ItemID = product.ItemID, @EAN = product.EAN
  FROM canon.Product AS product
  WHERE product.OrganizationId = @OrganizationId AND product.ProductId = @ProductId;

  IF @ItemID IS NULL
  BEGIN
    SELECT TOP (0) inbox.InboxId, inbox.RunId, inbox.SourceCode, inbox.EntityType,
      inbox.PageNumber, inbox.Status, inbox.ReceivedUtc, inbox.ProcessedUtc,
      CONVERT(int, NULL) AS RecordOrdinal, CONVERT(bigint, 0) AS ExtractedFieldCount
    FROM raw.Inbox AS inbox;
    RETURN;
  END;

  ;WITH identityValue AS
  (
    SELECT extracted.InboxId, extracted.RecordOrdinal,
      ItemID = MAX(CASE WHEN extracted.TargetFieldCode IN (N''Product.ItemID'', N''Record.ItemID'')
        AND extracted.Value = @ItemID THEN @ItemID END),
      EAN = MAX(CASE WHEN extracted.TargetFieldCode = N''Product.EAN''
        AND @EAN IS NOT NULL AND extracted.Value = @EAN THEN @EAN END)
    FROM map.ExtractedValue AS extracted
    /* 218: zunanji pogoj se ujema s filtrom indeksa IX_ExtractedValue_Identity (samo identitetna polja),
       zato poizvedba bere ~3 M vrstic indeksa namesto 78 M vrstic tabele (izmerjeno 17,8 s na kartico). */
    WHERE extracted.TargetFieldCode IN (N''Product.ItemID'', N''Record.ItemID'', N''Product.EAN'')
      AND (
      (extracted.TargetFieldCode IN (N''Product.ItemID'', N''Record.ItemID'')
        AND extracted.Value = @ItemID)
      OR
      (extracted.TargetFieldCode = N''Product.EAN'' AND @EAN IS NOT NULL
        AND extracted.Value = @EAN)
      )
    GROUP BY extracted.InboxId, extracted.RecordOrdinal
  )
  SELECT TOP (100) inbox.InboxId, inbox.RunId, inbox.SourceCode, inbox.EntityType,
    inbox.PageNumber, inbox.Status, inbox.ReceivedUtc, inbox.ProcessedUtc,
    identityValue.RecordOrdinal,
    ExtractedFieldCount =
    (
      SELECT COUNT_BIG(*) FROM map.ExtractedValue AS fieldValue
      WHERE fieldValue.InboxId = identityValue.InboxId
        AND fieldValue.RecordOrdinal = identityValue.RecordOrdinal
    )
  FROM identityValue
  INNER JOIN raw.Inbox AS inbox ON inbox.InboxId = identityValue.InboxId
  WHERE inbox.OrganizationId = @OrganizationId
    AND (identityValue.ItemID = @ItemID OR (identityValue.ItemID IS NULL AND identityValue.EAN = @EAN))
  ORDER BY inbox.ReceivedUtc DESC, inbox.InboxId DESC, identityValue.RecordOrdinal DESC;
END;');

/* ── GetCategoryMappings ── */
EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetCategoryMappings
  @SourceCode nvarchar(100) = NULL,
  @CategoryTreeCode nvarchar(100) = NULL,
  @Stanje nvarchar(20) = NULL,          /* NULL = vse, ''Nepreslikano'', ''Preslikano'', ''Ugasnjeno'' */
  @Iskanje nvarchar(200) = NULL,
  @Stran int = 1,
  @NaStran int = 50
AS
BEGIN
  SET NOCOUNT ON;
  IF @Stran < 1 SET @Stran = 1;
  IF @NaStran < 1 OR @NaStran > 500 SET @NaStran = 50;

  /*
    Ena vrstica na (vir, drevo, izvorna pot). Register pove, kaj je dobavitelj poslal in koliko
    izdelkov je za tem; slovar pove, ali ima to cilj. Strani se stejejo v bazi, ker jih je lahko
    vec sto in filtriranje v pomnilniku je bila natanko napaka, ki jo je odpravila migracija 102.
  */
  /* 218: prevedene poti vseh dreves enkrat v zacasno tabelo; prej je OUTER APPLY za vsako vrstico registra
     (vir x drevo) znova izracunal rekurzivni pogled canon.CategoryPathTranslated (izmerjeno 27,7 s). */
  CREATE TABLE #Pot (CategoryTreeCode nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL, CategoryCode nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
                     SortOrder int NOT NULL, CategoryPath nvarchar(1000) COLLATE DATABASE_DEFAULT NULL);
  INSERT #Pot (CategoryTreeCode, CategoryCode, SortOrder, CategoryPath)
  SELECT prevod.CategoryTreeCode, prevod.CategoryCode, spletna.SortOrder, prevod.CategoryPath
  FROM canon.CategoryPathTranslated prevod
  INNER JOIN canon.WebSite spletna
    ON spletna.CategoryTreeCode = prevod.CategoryTreeCode AND spletna.LanguageCode = prevod.LanguageCode;

  ;WITH Drevo AS
  (
    SELECT DISTINCT spletna.CategoryTreeCode
    FROM canon.WebSite spletna WHERE spletna.IsActive = 1
  ),
  Osnova AS
  (
    SELECT
      register.SourceCode,
      drevo.CategoryTreeCode,
      register.SourcePathKey,
      register.SourceLevel1,
      register.SourceLevel2,
      register.SourceLevel3,
      register.ProductCount,
      register.LastSeenUtc,
      slovar.CategoryCode,
      slovar.IsActive AS MapIsActive,
      slovar.UpdatedUtc,
      slovar.UpdatedBy,
      pot.CategoryPath
    FROM map.SourceCategory register
    CROSS JOIN Drevo drevo
    LEFT JOIN map.CategoryPathMap slovar
      ON slovar.SourceCode = register.SourceCode
     AND slovar.CategoryTreeCode = drevo.CategoryTreeCode
     AND slovar.SourcePathKey = register.SourcePathKey
    OUTER APPLY
    (
      SELECT TOP (1) prevod.CategoryPath
      FROM #Pot prevod
      WHERE prevod.CategoryTreeCode = drevo.CategoryTreeCode AND prevod.CategoryCode = slovar.CategoryCode
      ORDER BY prevod.SortOrder
    ) pot
    WHERE (@SourceCode IS NULL OR register.SourceCode = @SourceCode)
      AND (@CategoryTreeCode IS NULL OR drevo.CategoryTreeCode = @CategoryTreeCode)
  ),
  Filtrirano AS
  (
    SELECT *,
      CASE WHEN CategoryCode IS NULL THEN N''Nepreslikano''
           WHEN MapIsActive = 0 THEN N''Ugasnjeno''
           ELSE N''Preslikano'' END AS Stanje
    FROM Osnova
  )
  SELECT
    SourceCode, CategoryTreeCode, SourcePathKey, SourceLevel1, SourceLevel2, SourceLevel3,
    ProductCount, LastSeenUtc, CategoryCode, CategoryPath, Stanje, UpdatedUtc, UpdatedBy,
    COUNT(*) OVER () AS SkupajVrstic
  FROM Filtrirano
  WHERE (@Stanje IS NULL OR Stanje = @Stanje)
    AND (@Iskanje IS NULL OR SourcePathKey LIKE N''%'' + @Iskanje + N''%''
         OR ISNULL(SourceLevel1, N'''') LIKE N''%'' + @Iskanje + N''%''
         OR ISNULL(SourceLevel2, N'''') LIKE N''%'' + @Iskanje + N''%''
         OR ISNULL(CategoryPath, N'''') LIKE N''%'' + @Iskanje + N''%'')
  ORDER BY ProductCount DESC, SourcePathKey
  OFFSET (@Stran - 1) * @NaStran ROWS FETCH NEXT @NaStran ROWS ONLY;

  DROP TABLE #Pot;
END;');

/* ── GetCategoryTree ── */
EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetCategoryTree
  @CategoryTreeCode nvarchar(100) = NULL,
  @OrganizationId int = NULL,
  @LanguageCode nvarchar(10) = N''en'',
  @Iskanje nvarchar(200) = NULL,
  @Veja nvarchar(400) = NULL,
  @SamoBrezPrevoda bit = 0,
  @SamoZIzdelki bit = 0,
  @Nivo int = NULL
AS
BEGIN
  SET NOCOUNT ON;

  DECLARE @Jezikov int = (SELECT COUNT(DISTINCT LanguageCode) FROM canon.Language WHERE IsActive = 1);

  /* 218: uvrstitve izdelkov se preberejo enkrat (#Uvrstitev), stevci na kategorijo pa se izracunajo
     mnozicno: neposredni po enakosti poti (#Neposredno), poddrevo prek poti pod kategorijo (#Spodaj).
     Prej je OUTER APPLY za vsako kategorijo znova pregledal vse uvrstitve z LIKE - izmerjeno 12,5 s
     na klic, stran /nastavitve/kategorije ga klice dvakrat. Pomen je isti: stetje po poti, ne po
     drevesu (poti iz vseh spletnih strani), locilo poti je N'' > '' (110). */
  CREATE TABLE #Uvrstitev (CategoryPath nvarchar(1000) COLLATE DATABASE_DEFAULT NOT NULL, ProductId bigint NOT NULL);
  INSERT #Uvrstitev (CategoryPath, ProductId)
  SELECT DISTINCT k.CategoryPath, k.ProductId
  FROM canon.ProductCategory k
  INNER JOIN canon.Product izdelek ON izdelek.ProductId = k.ProductId
  WHERE (@OrganizationId IS NULL OR izdelek.OrganizationId = @OrganizationId);

  /* Brez kljuca po poti: nvarchar(1000) presega mejo kljuca 1700 bajtov; vrstic je nekaj tisoc. */
  CREATE TABLE #Neposredno (CategoryPath nvarchar(1000) COLLATE DATABASE_DEFAULT NOT NULL, Kolicina bigint NOT NULL);
  INSERT #Neposredno (CategoryPath, Kolicina)
  SELECT CategoryPath, COUNT_BIG(DISTINCT ProductId) FROM #Uvrstitev GROUP BY CategoryPath;

  CREATE TABLE #Spodaj (CategoryTreeCode nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL, CategoryCode nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
                        Kolicina bigint NOT NULL, PRIMARY KEY (CategoryTreeCode, CategoryCode));
  INSERT #Spodaj (CategoryTreeCode, CategoryCode, Kolicina)
  SELECT kategorija.CategoryTreeCode, kategorija.CategoryCode, COUNT_BIG(DISTINCT uvrstitev.ProductId)
  FROM canon.Category kategorija
  INNER JOIN (SELECT DISTINCT CategoryPath FROM #Uvrstitev) pot
    ON pot.CategoryPath = kategorija.CategoryPath OR pot.CategoryPath LIKE kategorija.CategoryPath + N'' > %''
  INNER JOIN #Uvrstitev uvrstitev ON uvrstitev.CategoryPath = pot.CategoryPath
  WHERE (@CategoryTreeCode IS NULL OR kategorija.CategoryTreeCode = @CategoryTreeCode)
  GROUP BY kategorija.CategoryTreeCode, kategorija.CategoryCode;

  ;WITH Osnova AS
  (
    SELECT kategorija.CategoryTreeCode, kategorija.CategoryCode, kategorija.ParentCategoryCode,
           kategorija.LevelNo, kategorija.CategoryName, kategorija.CategoryPath, kategorija.IsActive
    FROM canon.Category kategorija
    WHERE (@CategoryTreeCode IS NULL OR kategorija.CategoryTreeCode = @CategoryTreeCode)
  ),
  VejaFilter AS
  (
    SELECT o.* FROM Osnova o
    WHERE @Veja IS NULL
       OR o.CategoryCode = @Veja
       OR EXISTS (SELECT 1 FROM Osnova koren
                  WHERE koren.CategoryCode = @Veja
                    AND o.CategoryPath LIKE koren.CategoryPath + N'' > %'')
  ),
  Bogato AS
  (
    SELECT v.*,
      prevod.CategoryName AS TranslatedName,
      manjka.Manjka AS MissingLanguages,
      manjka.Seznam AS MissingLanguageList,
      ISNULL(neposredno.Kolicina, 0) AS ProductCount,
      ISNULL(spodaj.Kolicina, 0) AS DescendantProductCount,
      ISNULL(otroci.Kolicina, 0) AS ChildCount,
      vsi.Json AS TranslationsJson
    FROM VejaFilter v
    LEFT JOIN canon.CategoryTranslation prevod
      ON prevod.CategoryTreeCode = v.CategoryTreeCode AND prevod.CategoryCode = v.CategoryCode
        AND prevod.LanguageCode = @LanguageCode
    OUTER APPLY
    (
      SELECT COUNT(*) AS Manjka, STRING_AGG(jezik.LanguageCode, N'','') AS Seznam
      FROM (SELECT DISTINCT LanguageCode FROM canon.Language WHERE IsActive = 1) jezik
      WHERE NOT EXISTS
      (
        SELECT 1 FROM canon.CategoryTranslation p
        WHERE p.CategoryTreeCode = v.CategoryTreeCode AND p.CategoryCode = v.CategoryCode
          AND p.LanguageCode = jezik.LanguageCode
      )
    ) manjka
    OUTER APPLY
    (
      /* Vsi zapisani prevodi te kategorije v eni celici: urednik prevaja enkrat, v vse jezike. */
      SELECT (SELECT p.LanguageCode AS lang, p.CategoryName AS name
              FROM canon.CategoryTranslation p
              WHERE p.CategoryTreeCode = v.CategoryTreeCode AND p.CategoryCode = v.CategoryCode
              ORDER BY p.LanguageCode
              FOR JSON PATH) AS Json
    ) vsi
    OUTER APPLY
    (
      SELECT COUNT_BIG(*) AS Kolicina FROM canon.Category otrok
      WHERE otrok.CategoryTreeCode = v.CategoryTreeCode AND otrok.ParentCategoryCode = v.CategoryCode
        AND otrok.IsActive = 1
    ) otroci
    LEFT JOIN #Neposredno neposredno ON neposredno.CategoryPath = v.CategoryPath
    LEFT JOIN #Spodaj spodaj ON spodaj.CategoryTreeCode = v.CategoryTreeCode AND spodaj.CategoryCode = v.CategoryCode
  ),
  Zadetki AS
  (
    SELECT b.* FROM Bogato b
    WHERE (@Iskanje IS NULL
            OR b.CategoryName LIKE N''%'' + @Iskanje + N''%''
            OR b.CategoryPath LIKE N''%'' + @Iskanje + N''%''
            OR ISNULL(b.TranslationsJson, N'''') LIKE N''%'' + @Iskanje + N''%'')
      AND (@Nivo IS NULL OR b.LevelNo = @Nivo)
      AND (@SamoBrezPrevoda = 0 OR b.TranslatedName IS NULL)
      AND (@SamoZIzdelki = 0 OR b.DescendantProductCount > 0)
  ),
  ZPredniki AS
  (
    SELECT z.CategoryTreeCode, z.CategoryCode, CONVERT(bit, 1) AS JeZadetek FROM Zadetki z
    UNION
    SELECT b.CategoryTreeCode, b.CategoryCode, CONVERT(bit, 0)
    FROM Bogato b
    WHERE EXISTS (SELECT 1 FROM Zadetki z
                  WHERE z.CategoryTreeCode = b.CategoryTreeCode
                    AND z.CategoryPath LIKE b.CategoryPath + N'' > %'')
  )
  SELECT
    b.CategoryTreeCode, b.CategoryCode, b.ParentCategoryCode, b.LevelNo,
    b.CategoryName, b.CategoryPath, b.IsActive,
    b.TranslatedName, b.MissingLanguages, b.MissingLanguageList, b.TranslationsJson,
    b.ProductCount, b.DescendantProductCount, b.ChildCount,
    MAX(CONVERT(tinyint, izbor.JeZadetek)) AS JeZadetek,
    @Jezikov AS Jezikov
  FROM Bogato b
  INNER JOIN ZPredniki izbor
    ON izbor.CategoryTreeCode = b.CategoryTreeCode AND izbor.CategoryCode = b.CategoryCode
  GROUP BY
    b.CategoryTreeCode, b.CategoryCode, b.ParentCategoryCode, b.LevelNo,
    b.CategoryName, b.CategoryPath, b.IsActive,
    b.TranslatedName, b.MissingLanguages, b.MissingLanguageList, b.TranslationsJson,
    b.ProductCount, b.DescendantProductCount, b.ChildCount
  ORDER BY b.CategoryTreeCode, b.CategoryPath;

  DROP TABLE #Spodaj; DROP TABLE #Neposredno; DROP TABLE #Uvrstitev;
END;');

/* ── GetStockOverview ── */
EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetStockOverview
  @OrganizationId int = NULL
AS
BEGIN
  SET NOCOUNT ON;
  DECLARE @Now datetime2(3) = SYSUTCDATETIME();

  /* 1 - koliko je zaloge in koliko je od nje uporabne. */
  SELECT
    PositionCount = COUNT_BIG(*),
    MatchedCount = SUM(CASE WHEN position.MatchedProductId IS NULL THEN 0 ELSE 1 END),
    UnmatchedCount = SUM(CASE WHEN position.MatchedProductId IS NULL THEN 1 ELSE 0 END),
    InStockCount = SUM(CASE WHEN position.Quantity > 0 THEN 1 ELSE 0 END),
    OutOfStockCount = SUM(CASE WHEN position.Quantity <= 0 THEN 1 ELSE 0 END),
    IncomingCount = SUM(CASE WHEN position.IncomingQuantity > 0 THEN 1 ELSE 0 END),
    OldestSnapshotUtc = MIN(snapshot.SnapshotUtc),
    NewestSnapshotUtc = MAX(snapshot.SnapshotUtc)
  FROM stock.Position AS position
  INNER JOIN stock.Snapshot AS snapshot ON snapshot.SnapshotId = position.SnapshotId
  WHERE (@OrganizationId IS NULL OR snapshot.OrganizationId = @OrganizationId) AND snapshot.IsActive = 1;

  /* 2 - po viru: svezina je lastnost vira, ne celotne zaloge. */
  SELECT connector.SourceCode, snapshot.ProviderKind, snapshot.Endpoint,
    SnapshotUtc = MAX(snapshot.SnapshotUtc),
    FreshnessMinutes = DATEDIFF(minute, MAX(snapshot.SnapshotUtc), @Now),
    PositionCount = COUNT_BIG(*),
    MatchedCount = SUM(CASE WHEN position.MatchedProductId IS NULL THEN 0 ELSE 1 END),
    InStockCount = SUM(CASE WHEN position.Quantity > 0 THEN 1 ELSE 0 END)
  FROM stock.Position AS position
  INNER JOIN stock.Snapshot AS snapshot ON snapshot.SnapshotId = position.SnapshotId
  INNER JOIN map.SourceConnector AS connector ON connector.SourceConnectorId = snapshot.SourceConnectorId
  WHERE (@OrganizationId IS NULL OR snapshot.OrganizationId = @OrganizationId) AND snapshot.IsActive = 1
  GROUP BY connector.SourceCode, snapshot.ProviderKind, snapshot.Endpoint
  ORDER BY connector.SourceCode, snapshot.Endpoint;

  /* 3 - izpeljane tezave: nastanejo iz podatka in izginejo z njim, zato jih ni mogoce
     rocno zapreti. Zavrnjena pozicija pove razlog, ne le da je bila zavrnjena.
     218: LOOP JOIN - zavrnjenih pozicij je ~2.000, zapisov zaloge 4 M; optimizer je pregledal vse
     zapise, da bi jih filtriral po podjetju (izmerjeno 3,7 s), namesto da bi za vsako zavrnjeno
     pozicijo poiskal njen zapis po kljucu. */
  SELECT unmatched.ReasonCode,
    PositionCount = COUNT_BIG(*),
    FirstSeenUtc = MIN(unmatched.CreatedUtc),
    LastSeenUtc = MAX(unmatched.CreatedUtc),
    SampleDetail = MIN(unmatched.Detail)
  FROM stock.UnmatchedPosition AS unmatched
  INNER LOOP JOIN stock.LandingRecord AS landing ON landing.LandingRecordId = unmatched.LandingRecordId
  WHERE landing.OrganizationId = @OrganizationId
  GROUP BY unmatched.ReasonCode
  ORDER BY COUNT_BIG(*) DESC, unmatched.ReasonCode;
END;');

/* ── GetValidationIssues ── */
EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetValidationIssues
  @OrganizationId int,
  @Take int = 200
AS
BEGIN
  SET NOCOUNT ON;
  IF @Take IS NULL OR @Take < 0 SET @Take = 200;

  /* 218: @Take = 0 pomeni "samo profili" - nadzorna plosca bere iz te procedure samo drugi nabor
     (stanje po profilih), prvi (zadnjih 200 napak po datumu cez vse odprte napake podjetja) in
     tretji (najpogostejse kode) pa sta stala ~3 s na podjetje in se na plosci ne prikazeta.
     Oba nabora ostaneta v odgovoru (prazna), da se pogodba treh naborov ne spremeni. */
  IF @Take = 0
    SELECT TOP (0)
           issueValue.ProductIssueId AS ProductIssueId, CONVERT(bigint, 0) AS ProductId,
           CONVERT(nvarchar(200), NULL) AS ItemId, CONVERT(nvarchar(100), NULL) AS ProfileCode,
           issueValue.IssueCode AS IssueCode, issueValue.Message AS Message,
           issueValue.LastDetectedUtc AS LastDetectedUtc
    FROM val.ProductIssue issueValue;
  ELSE
    SELECT TOP (@Take)
           issueValue.ProductIssueId AS ProductIssueId, productValue.ProductId AS ProductId,
           productValue.ItemID AS ItemId, profileValue.ProfileCode AS ProfileCode,
           issueValue.IssueCode AS IssueCode, issueValue.Message AS Message,
           issueValue.LastDetectedUtc AS LastDetectedUtc
    FROM val.ProductIssue issueValue
    INNER JOIN canon.Product productValue ON productValue.ProductId = issueValue.ProductId
    INNER JOIN val.ValidationProfile profileValue ON profileValue.ValidationProfileId = issueValue.ValidationProfileId
    WHERE productValue.OrganizationId = @OrganizationId AND issueValue.IsActive = 1
    ORDER BY issueValue.LastDetectedUtc DESC, issueValue.ProductIssueId DESC;

  SELECT profileValue.ProfileCode AS ProfileCode, COUNT_BIG(*) AS ProductCount,
         SUM(CASE WHEN stateValue.Status = N''VALID'' THEN CONVERT(bigint, 1) ELSE CONVERT(bigint, 0) END) AS ValidCount,
         SUM(CASE WHEN stateValue.Status = N''INVALID'' THEN CONVERT(bigint, 1) ELSE CONVERT(bigint, 0) END) AS InvalidCount,
         AVG(CONVERT(decimal(9,2), stateValue.Completeness)) AS AverageCompleteness
  FROM val.ProductValidationState stateValue
  INNER JOIN val.ValidationProfile profileValue ON profileValue.ValidationProfileId = stateValue.ValidationProfileId
  INNER JOIN canon.Product productValue ON productValue.ProductId = stateValue.ProductId
  WHERE productValue.OrganizationId = @OrganizationId
  GROUP BY profileValue.ProfileCode ORDER BY profileValue.ProfileCode;

  IF @Take = 0
    SELECT TOP (0) issueValue.IssueCode AS IssueCode, issueValue.Message AS Message, CONVERT(bigint, 0) AS OccurrenceCount
    FROM val.ProductIssue issueValue;
  ELSE
    SELECT TOP (10) issueValue.IssueCode AS IssueCode, issueValue.Message AS Message, COUNT_BIG(*) AS OccurrenceCount
    FROM val.ProductIssue issueValue
    INNER JOIN canon.Product productValue ON productValue.ProductId = issueValue.ProductId
    WHERE productValue.OrganizationId = @OrganizationId AND issueValue.IsActive = 1
    GROUP BY issueValue.IssueCode, issueValue.Message
    ORDER BY COUNT_BIG(*) DESC, issueValue.IssueCode;
END;');

/* ── Preverba ── */
IF OBJECT_ID(N'val.RunValidationForProducts') IS NULL OR OBJECT_ID(N'pim.SaveProductTextsBulk') IS NULL OR OBJECT_ID(N'pim.SaveProductAttributesBulk') IS NULL
  THROW 52180, N'218: procedure niso bile ustvarjene.', 1;
