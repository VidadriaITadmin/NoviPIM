/*
  141 — posnetek zapisa iz SAOP endpointa za en artikel.

  Zakaj: ko se PIM in SAOP ne ujemata, danes ni nacina, da bi videl, kaj SAOP dejansko ima.
  Kartica artikla pokaze kanonicne vrednosti PIM-a; kaj je poslal ERP, ostane skrito, tudi
  ce je odgovor ze v bazi.

  Od kod posnetek pride. NoviPIM nima tabel raw.{Org}_data_current, kot jih ima stari sistem;
  vhodni sloj je ena tabela raw.Inbox s celotnim odgovorom endpointa v PayloadXml. Imena
  tabele zato ni treba sestavljati in se tudi ne sme ugibati — razresi se register, tako kot
  to dela map.ProcessRawInbox (migracija 012):

    map.SourceConnector   ConnectorType = 'SAOP' -> kateri vir organizacije je SAOP
    map.EntityMapping     RecordXPath             -> kje v odgovoru stoji en zapis
    map.FieldMapping      Product.ItemID          -> kateri element nosi sifro artikla

  Ker so vsi trije podatki iz registra, se procedura ob spremembi vira ne popravlja, in
  organizacija brez SAOP vira (vir je XML) dobi prazen nabor s pojasnilom, ne napake.

  Dolga oblika namesto sirokega nabora: endpoint ima pri razlicnih organizacijah razlicne
  elemente, zato bi siroka tabela razbila odjemalca ze ob prvem novem stolpcu. Dolga oblika
  (Section, ElementName, Value) prenese karkoli.

  Razvrstitev v sklope bere out.SaopXmlField: element neposredno pod zapisom je 'Item',
  element v podelementu pa nosi ime podelementa, ce ga register pozna; karkoli drugega gre
  v 'Ostalo'. Nov element endpointa se tako pojavi sam, brez spremembe kode.

  Primerjava s PIM-om je pri poljih s kanonicno kodo tipizirana, ne znakovna: SAOP posilja
  '0.000000' tam, kjer ima PIM 0.0000, in crko 'D' tam, kjer ima PIM bit 1. Znakovna
  primerjava bi vsako tako polje razglasila za odklon in oznake ne bi bilo mogoce brati.

  Migrator ne pozna locila GO; procedura je zavita v EXEC(N'...') kot v 012, 081 in 129.
*/

SET XACT_ABORT ON;

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetSaopEndpointSnapshot
  @OrganizationId int,
  @ItemId nvarchar(64)
AS
BEGIN
  SET NOCOUNT ON;

  DECLARE @EntityType nvarchar(100) = N''ItemGeneralData'';
  DECLARE @SourceCode nvarchar(100), @RecordXPath nvarchar(2000), @IdElement nvarchar(2000);

  /* 1 — kateri vir te organizacije je SAOP in kje v odgovoru stoji en zapis. */
  SELECT TOP (1) @SourceCode = connector.SourceCode, @RecordXPath = entity.RecordXPath
  FROM map.SourceConnector AS connector
  INNER JOIN map.EntityMapping AS entity
    ON entity.SourceConnectorId = connector.SourceConnectorId
   AND entity.EntityType = @EntityType AND entity.IsActive = 1
  WHERE connector.OrganizationId = @OrganizationId
    AND connector.IsActive = 1 AND connector.ConnectorType = N''SAOP''
  ORDER BY connector.SourceConnectorId;

  /* 2 — kateri element nosi sifro artikla; tudi to je register, ne ugibanje. */
  SELECT TOP (1) @IdElement = mapping.SourceElement
  FROM map.FieldMapping AS mapping
  INNER JOIN map.SourceConnector AS connector
    ON connector.SourceConnectorId = mapping.SourceConnectorId
  WHERE connector.OrganizationId = @OrganizationId AND connector.SourceCode = @SourceCode
    AND mapping.EntityType = @EntityType AND mapping.IsActive = 1
    AND mapping.TargetFieldCode = N''Product.ItemID'';

  DECLARE @InboxId bigint, @PageNumber int, @ReceivedUtc datetime2(3), @Record xml,
          @Explanation nvarchar(600);

  IF @SourceCode IS NULL OR @RecordXPath IS NULL
    SET @Explanation = N''To podjetje nima aktivnega vira SAOP za zapise artiklov; njegovi artikli pridejo iz dobaviteljskega XML. Posnetka endpointa zato ni.'';
  ELSE IF @IdElement IS NULL
    SET @Explanation = N''Vir '' + @SourceCode + N'' nima preslikave Product.ItemID za '' + @EntityType + N'', zato zapisa artikla v odgovoru ni mogoce najti.'';

  IF @Explanation IS NULL
  BEGIN
    /* Vzorec LIKE odreze strani, ki artikla ne vsebujejo, preden se karkoli razgradi v XML.
       Odgovor ene strani je velik nekaj megabajtov; brez tega bi bilo treba razgraditi vse. */
    DECLARE @IdRoot nvarchar(200) = CASE
      WHEN CHARINDEX(N''/'', @IdElement) > 1 THEN LEFT(@IdElement, CHARINDEX(N''/'', @IdElement) - 1)
      ELSE @IdElement END;

    /* Sifra artikla je uporabnikov niz; posebni znaki vzorca LIKE morajo ostati znaki. */
    DECLARE @Escaped nvarchar(400) = REPLACE(REPLACE(REPLACE(REPLACE(
      @ItemId, N''\'', N''\\''), N''%'', N''\%''), N''_'', N''\_''), N''['', N''\['');
    DECLARE @Like nvarchar(600) = N''%<'' + @IdRoot + N''>'' + @Escaped + N''</'' + @IdRoot + N''>%'';

    /* .nodes() zahteva dobesedno pot, zato je poizvedba dinamicna — enako kot v
       map.ProcessRawInbox. Vse tri poti pridejo iz registra, ne iz uporabnikovega vnosa;
       uporabnikov je samo @ItemId, ki ostane parameter. */
    DECLARE @q char(1) = CHAR(39);
    DECLARE @sql nvarchar(max) =
      N''SELECT TOP (1) @OutInboxId = inbox.InboxId, @OutPage = inbox.PageNumber,'' +
      N'' @OutReceived = inbox.ReceivedUtc, @OutRecord = record.node.query('' + @q + N''.'' + @q + N'')'' +
      N'' FROM raw.Inbox AS inbox'' +
      N'' CROSS APPLY (SELECT TRY_CONVERT(xml, map.StripXmlDeclaration(inbox.PayloadXml)) AS doc) AS parsed'' +
      N'' CROSS APPLY parsed.doc.nodes('' + @q + REPLACE(@RecordXPath, @q, @q + @q) + @q + N'') AS record(node)'' +
      N'' WHERE inbox.OrganizationId = @InOrganizationId AND inbox.SourceCode = @InSourceCode'' +
      N''   AND inbox.EntityType = @InEntityType AND inbox.PayloadXml LIKE @InLike ESCAPE '' + @q + N''\'' + @q +
      N''   AND record.node.value('' + @q + N''('' + REPLACE(@IdElement, @q, @q + @q) + N'')[1]'' + @q +
      N'', '' + @q + N''nvarchar(200)'' + @q + N'') = @InItemId'' +
      N'' ORDER BY inbox.InboxId DESC;'';

    EXEC sp_executesql @sql,
      N''@InOrganizationId int, @InSourceCode nvarchar(100), @InEntityType nvarchar(100),
        @InLike nvarchar(600), @InItemId nvarchar(64), @OutInboxId bigint OUTPUT,
        @OutPage int OUTPUT, @OutReceived datetime2(3) OUTPUT, @OutRecord xml OUTPUT'',
      @InOrganizationId = @OrganizationId, @InSourceCode = @SourceCode, @InEntityType = @EntityType,
      @InLike = @Like, @InItemId = @ItemId,
      @OutInboxId = @InboxId OUTPUT, @OutPage = @PageNumber OUTPUT,
      @OutReceived = @ReceivedUtc OUTPUT, @OutRecord = @Record OUTPUT;

    IF @Record IS NULL
      SET @Explanation = N''Vir '' + @SourceCode + N'' za ta artikel nima zajetega zapisa. Zajem endpointa '' + @EntityType + N'' ga se ni prinesel ali pa artikel v SAOP ne obstaja.'';
  END;

  /* --- Dolga oblika zapisa ------------------------------------------------------------- */

  DECLARE @Element TABLE
  (
    SectionRaw nvarchar(100) NOT NULL,
    ElementName nvarchar(200) NOT NULL,
    Value nvarchar(max) NULL
  );

  IF @Record IS NOT NULL
  BEGIN
    /* Listi neposredno pod zapisom so sklop ''Item''; listi v podelementu nosijo ime
       podelementa. Vozlisce z otroki je sklop in ne vrednost, zato ga izpustimo. */
    INSERT @Element (SectionRaw, ElementName, Value)
    SELECT N''Item'', child.node.value(N''local-name(.)'', N''nvarchar(200)''),
           NULLIF(child.node.value(N''.'', N''nvarchar(max)''), N'''')
    FROM @Record.nodes(N''/*/*'') AS child(node)
    WHERE child.node.exist(N''*'') = 0
    UNION ALL
    SELECT child.node.value(N''local-name(..)'', N''nvarchar(100)''),
           child.node.value(N''local-name(.)'', N''nvarchar(200)''),
           NULLIF(child.node.value(N''.'', N''nvarchar(max)''), N'''')
    FROM @Record.nodes(N''/*/*/*'') AS child(node)
    WHERE child.node.exist(N''*'') = 0
    UNION ALL
    SELECT child.node.value(N''local-name(..)'', N''nvarchar(100)''),
           child.node.value(N''local-name(.)'', N''nvarchar(200)''),
           NULLIF(child.node.value(N''.'', N''nvarchar(max)''), N'''')
    FROM @Record.nodes(N''/*/*/*/*'') AS child(node)
    WHERE child.node.exist(N''*'') = 0;
  END;

  /* --- 1. nabor: od kod je posnetek in kdaj je bil narejen ----------------------------- */

  SELECT
    SourceTable = CASE WHEN @Record IS NULL THEN NULL ELSE N''raw.Inbox'' END,
    SourceCode = @SourceCode,
    EntityType = @EntityType,
    InboxId = @InboxId,
    PageNumber = @PageNumber,
    /* Kdaj je PIM zapis prevzel. */
    ReceivedUtc = @ReceivedUtc,
    /* Kdaj je bil zapis nazadnje spremenjen v SAOP; ime elementa se ne vpisuje na roko. */
    LastModifiedAtUtc =
    (
      SELECT MAX(TRY_CONVERT(datetime2(3), element.Value))
      FROM @Element AS element
      WHERE element.ElementName LIKE N''%LastModified%''
    ),
    HasSnapshot = CONVERT(bit, CASE WHEN @Record IS NULL THEN 0 ELSE 1 END),
    Explanation = @Explanation;

  /* --- 2. nabor: elementi zapisa in primerjava s PIM-om -------------------------------- */

  DECLARE @ProductId bigint =
    (SELECT TOP (1) ProductId FROM canon.Product WHERE OrganizationId = @OrganizationId AND ItemID = @ItemId);

  ;WITH canonical AS
  (
    /* Kanonicne vrednosti PIM-a po istih kodah, kot jih uporablja pogodba out.SaopXmlField. */
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
        (N''ProductCommercial.PackageLength'',   CONVERT(nvarchar(400), commercial.PackageLength)),
        (N''ProductCommercial.PackageWidth'',    CONVERT(nvarchar(400), commercial.PackageWidth)),
        (N''ProductCommercial.PackageHeight'',   CONVERT(nvarchar(400), commercial.PackageHeight)),
        (N''ProductCommercial.Volume'',          CONVERT(nvarchar(400), commercial.Volume)),
        (N''ProductCommercial.Pak1'',            CONVERT(nvarchar(400), commercial.Pak1)),
        (N''ProductCommercial.Pak2'',            CONVERT(nvarchar(400), commercial.Pak2))
    ) AS value (FieldKey, Value)
    WHERE product.ProductId = @ProductId

    UNION ALL

    /* Besedila in lastnosti nosijo vrsto oziroma kodo v sami kanonicni kodi, zato jih ni
       treba nastevati; tako se polje, ki ga doda nova migracija, pojavi samo od sebe. */
    SELECT N''ProductText.'' + text.TextType + N''.'' + text.Lang, text.Value
    FROM canon.ProductText AS text WHERE text.ProductId = @ProductId
    UNION ALL
    SELECT N''ProductAttribute.'' + attribute.AttributeCode, attribute.Value
    FROM canon.ProductAttribute AS attribute WHERE attribute.ProductId = @ProductId
  ),
  shaped AS
  (
    SELECT
      Section = CASE
        WHEN element.SectionRaw = N''Item'' THEN N''Item''
        WHEN EXISTS (SELECT 1 FROM out.SaopXmlField AS known
                     WHERE known.TargetKind = N''SAOP_PRODUCT'' AND known.Section = element.SectionRaw)
          THEN element.SectionRaw
        ELSE N''Ostalo'' END,
      element.ElementName,
      element.Value
    FROM @Element AS element
  )
  SELECT
    shaped.Section,
    SectionSort = COALESCE((SELECT MIN(known.SortOrder) FROM out.SaopXmlField AS known
                            WHERE known.TargetKind = N''SAOP_PRODUCT'' AND known.Section = shaped.Section), 9000),
    shaped.ElementName,
    shaped.Value,
    FieldKey = field.FieldKey,
    /* Bit PIM-a se pokaze v crki, ki jo uporablja SAOP; sicer bi bilo videti kot odklon. */
    PimValue = CASE
      WHEN field.FieldKey IS NULL THEN NULL
      WHEN field.ValueFormat = N''bool'' AND canonical.Value = N''1'' THEN field.TrueValue
      WHEN field.ValueFormat = N''bool'' AND canonical.Value = N''0'' THEN field.FalseValue
      ELSE canonical.Value END,
    HasCanonical = CONVERT(bit, CASE WHEN field.FieldKey IS NULL THEN 0 ELSE 1 END),
    IsDifferent = CONVERT(bit, CASE
      WHEN field.FieldKey IS NULL THEN 0
      /* Stevilke se primerjajo kot stevilke: ''0.000000'' in 0.0000 sta ista vrednost. */
      WHEN field.ValueFormat LIKE N''decimal%''
        THEN CASE WHEN COALESCE(TRY_CONVERT(decimal(28,8), shaped.Value), 0)
                   = COALESCE(TRY_CONVERT(decimal(28,8), canonical.Value), 0) THEN 0 ELSE 1 END
      WHEN field.ValueFormat = N''bool''
        THEN CASE WHEN LTRIM(RTRIM(COALESCE(shaped.Value, N'''')))
                     = LTRIM(RTRIM(COALESCE(CASE WHEN canonical.Value = N''1'' THEN field.TrueValue
                                                 WHEN canonical.Value = N''0'' THEN field.FalseValue END, N''''))) THEN 0 ELSE 1 END
      ELSE CASE WHEN LTRIM(RTRIM(COALESCE(shaped.Value, N'''')))
                   = LTRIM(RTRIM(COALESCE(canonical.Value, N''''))) THEN 0 ELSE 1 END END),
    SortOrder = COALESCE(field.SortOrder, 8000)
  FROM shaped
  LEFT JOIN out.SaopXmlField AS field
    ON field.TargetKind = N''SAOP_PRODUCT'' AND field.IsEnabled = 1
   AND field.Section = shaped.Section AND field.ElementName = shaped.ElementName
  LEFT JOIN canonical ON canonical.FieldKey = field.FieldKey
  ORDER BY SectionSort, SortOrder, shaped.ElementName;
END;');

/* --- Varovalke -------------------------------------------------------------------------- */

IF OBJECT_ID(N'intranet.GetSaopEndpointSnapshot', N'P') IS NULL
  THROW 52960, 'Procedure intranet.GetSaopEndpointSnapshot ni.', 1;

/*
  Ime tabele in poti se ne smejo pojaviti v kodi kot konstanta: ce bi se, bi procedura
  prenehala delati vsakic, ko se vir preimenuje.
*/
DECLARE @snapshotDefinition nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'intranet.GetSaopEndpointSnapshot'));

IF CHARINDEX(N'map.EntityMapping', @snapshotDefinition) = 0
   OR CHARINDEX(N'map.SourceConnector', @snapshotDefinition) = 0
   OR CHARINDEX(N'Product.ItemID', @snapshotDefinition) = 0
  THROW 52961, 'Posnetek endpointa mora vir razresiti iz registra, ne iz sestavljenega imena.', 1;

IF CHARINDEX(N'out.SaopXmlField', @snapshotDefinition) = 0 OR CHARINDEX(N'Ostalo', @snapshotDefinition) = 0
  THROW 52962, 'Razvrstitev v sklope mora brati register, neznano pa mora pasti v Ostalo.', 1;

/*
  Dokaz nad podatki ni v migraciji, ampak v testu PIM.F10.ProductDetailUxTests.
  Procedura vraca dva nabora; INSERT ... EXEC zna zajeti samo tak izhod, kjer se vsi nabori
  ujemajo z eno tabelo, zato je klic iz T-SQL tu nemogoc. Test prek SqlDataReader dokaze,
  da zajeti artikel vrne vrstice, da organizacija brez vira SAOP dobi pojasnilo namesto
  napake in da se sklopi in odkloni izracunajo, kot pise zgoraj.

  Kar je mogoce dokazati v migraciji, je pogodba glave: procedura mora imeti vseh devet
  stolpcev prvega nabora. sys.dm_exec_describe_first_result_set tu ne pomaga, ker prvega
  nabora zaradi pogojne poti in dinamicne poizvedbe ne zna staticno dolociti.
*/
DECLARE @headColumn nvarchar(100), @missing nvarchar(400) = NULL;
DECLARE head_cursor CURSOR LOCAL FAST_FORWARD FOR
  SELECT name FROM (VALUES
    (N'SourceTable'), (N'SourceCode'), (N'EntityType'), (N'InboxId'), (N'PageNumber'),
    (N'ReceivedUtc'), (N'LastModifiedAtUtc'), (N'HasSnapshot'), (N'Explanation')) AS expected(name);

OPEN head_cursor;
FETCH NEXT FROM head_cursor INTO @headColumn;
WHILE @@FETCH_STATUS = 0
BEGIN
  IF CHARINDEX(@headColumn + N' =', @snapshotDefinition) = 0
    SET @missing = COALESCE(@missing + N', ', N'') + @headColumn;
  FETCH NEXT FROM head_cursor INTO @headColumn;
END;
CLOSE head_cursor;
DEALLOCATE head_cursor;

IF @missing IS NOT NULL
  THROW 52963, 'Glava posnetka nima vseh stolpcev pogodbe.', 1;
