/*
  139 — registrski spletni izvoz na zahtevo.

  Oblika rezultata je dinamicna namenoma: glave, vrstni red in kanonicne kode pridejo iz
  out.ExportProfile/out.ExportColumn. Dodan profil zato ne zahteva spremembe procedure.
  Vrednosti bere canon.FieldValue; vec vrednosti istega polja zdruzi z " | ". Stolpec brez
  kanonicne kode ostane prazen — to je vidna vrzel registra, ne razlog za izmisljeno vrednost.

  @Take=0 izkljuci stranicenje in je namenjen pretocnemu prenosu. Procedura podpira produktne
  profile; filtra WebSite in OnlyPublished imata samo pri izdelku dolocen poslovni pomen.

  Migrator ne pozna locila GO; procedura je v EXEC(N'...').
*/

SET XACT_ABORT ON;

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetWebExportRows
  @OrganizationId int,
  @ExportProfileId int,
  @WebSite nvarchar(100) = NULL,
  @OnlyPublished bit = 1,
  @Search nvarchar(200) = NULL,
  @Skip int = 0,
  @Take int = 200,
  @TotalCount int OUTPUT
AS
BEGIN
  SET NOCOUNT ON;

  IF @Skip < 0 THROW 52952, ''Odmik izvoza ne sme biti negativen.'', 1;
  IF @Take < 0 THROW 52953, ''Velikost strani izvoza ne sme biti negativna.'', 1;
  IF NOT EXISTS (SELECT 1 FROM dbo.OrganizationConfig WHERE OrganizationId=@OrganizationId)
    THROW 52954, ''Organizacija za spletni izvoz ne obstaja.'', 1;

  DECLARE @EntityType nvarchar(100), @ProfileCode nvarchar(100), @ColumnCount int;
  SELECT @EntityType=EntityType, @ProfileCode=ProfileCode
  FROM out.ExportProfile
  WHERE ExportProfileId=@ExportProfileId AND IsActive=1;

  IF @ProfileCode IS NULL THROW 52955, ''Aktivni izvozni profil ne obstaja.'', 1;
  IF UPPER(@EntityType) NOT IN (N''PRODUCT'', N''PRODUCTS'')
    THROW 52956, ''Izvoz na zahtevo trenutno podpira produktne profile.'', 1;

  SELECT @ColumnCount=COUNT(*)
  FROM out.ExportColumn
  WHERE ExportProfileId=@ExportProfileId AND IsActive=1;
  IF @ColumnCount=0 THROW 52957, ''Izvozni profil nima aktivnih stolpcev.'', 1;

  SET @WebSite=NULLIF(LTRIM(RTRIM(@WebSite)),N'''');
  SET @Search=NULLIF(LTRIM(RTRIM(@Search)),N'''');
  DECLARE @SearchLike nvarchar(410)=CASE WHEN @Search IS NULL THEN NULL ELSE
    N''%''+REPLACE(REPLACE(REPLACE(@Search,N''['',N''[[]''),N''%'',N''[%]''),N''_'',N''[_]'')+N''%'' END;

  SELECT @TotalCount=COUNT(*)
  FROM canon.Product AS product
  WHERE product.OrganizationId=@OrganizationId
    AND (@OnlyPublished=0 OR product.WebPublish=1)
    AND (@WebSite IS NULL OR EXISTS
      (SELECT 1 FROM canon.ProductCategory AS category
       WHERE category.ProductId=product.ProductId AND category.WebSite=@WebSite))
    AND (@SearchLike IS NULL
      OR product.ItemID LIKE @SearchLike
      OR product.EAN LIKE @SearchLike
      OR EXISTS
        (SELECT 1 FROM canon.ProductText AS textValue
         WHERE textValue.ProductId=product.ProductId AND textValue.Value LIKE @SearchLike));

  DECLARE @SelectList nvarchar(max);
  SELECT @SelectList=STRING_AGG(CONVERT(nvarchar(max),
    CASE WHEN NULLIF(CanonicalFieldCode,N'''') IS NULL
      THEN N''CAST(NULL AS nvarchar(max)) AS ''+QUOTENAME(OutputColumnName)
      ELSE N''MAX(CASE WHEN value.FieldCode=N''''''+REPLACE(CanonicalFieldCode,N'''''''',N'''''''''''')+
           N'''''' THEN value.Value END) AS ''+QUOTENAME(OutputColumnName)
    END),N'','') WITHIN GROUP (ORDER BY SortOrder)
  FROM out.ExportColumn
  WHERE ExportProfileId=@ExportProfileId AND IsActive=1;

  DECLARE @FieldCodes nvarchar(max);
  SELECT @FieldCodes=STRING_AGG(CONVERT(nvarchar(max),N''N''''''+
      REPLACE(CanonicalFieldCode,N'''''''',N'''''''''''')+N''''''''),N'','')
  FROM out.ExportColumn
  WHERE ExportProfileId=@ExportProfileId AND IsActive=1
    AND NULLIF(CanonicalFieldCode,N'''') IS NOT NULL;
  SET @FieldCodes=COALESCE(@FieldCodes,N''N''''__BREZ_POLJA__'''''');

  DECLARE @Paging nvarchar(200)=CASE WHEN @Take=0
    THEN N'' OFFSET @Skip ROWS''
    ELSE N'' OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY'' END;

  DECLARE @Sql nvarchar(max)=N''
    ;WITH FilteredProducts AS
    (
      SELECT product.ProductId, product.ItemID
      FROM canon.Product AS product
      WHERE product.OrganizationId=@OrganizationId
        AND (@OnlyPublished=0 OR product.WebPublish=1)
        AND (@WebSite IS NULL OR EXISTS
          (SELECT 1 FROM canon.ProductCategory AS category
           WHERE category.ProductId=product.ProductId AND category.WebSite=@WebSite))
        AND (@SearchLike IS NULL
          OR product.ItemID LIKE @SearchLike
          OR product.EAN LIKE @SearchLike
          OR EXISTS
            (SELECT 1 FROM canon.ProductText AS textValue
             WHERE textValue.ProductId=product.ProductId AND textValue.Value LIKE @SearchLike))
    ),
    PagedProducts AS
    (
      SELECT ProductId, ItemID FROM FilteredProducts
      ORDER BY ItemID''+@Paging+N''
    ),
    ValueRows AS
    (
      SELECT fieldValue.ProductId, fieldValue.FieldCode, fieldValue.Value
      FROM canon.FieldValue AS fieldValue
      INNER JOIN PagedProducts AS page ON page.ProductId=fieldValue.ProductId
      WHERE fieldValue.FieldCode IN (''+@FieldCodes+N'')
        AND fieldValue.FieldCode<>N''''ProductCategory.CategoryPath''''
      UNION ALL
      SELECT category.ProductId, N''''ProductCategory.CategoryPath'''', category.CategoryPath
      FROM canon.ProductCategory AS category
      INNER JOIN PagedProducts AS page ON page.ProductId=category.ProductId
      WHERE N''''ProductCategory.CategoryPath'''' IN (''+@FieldCodes+N'')
        AND (@WebSite IS NULL OR category.WebSite=@WebSite)
    ),
    ValuesGrouped AS
    (
      SELECT ProductId, FieldCode,
        STRING_AGG(CONVERT(nvarchar(max),Value),N'''' | '''') WITHIN GROUP (ORDER BY Value) AS Value
      FROM ValueRows WHERE NULLIF(Value,N'''''''') IS NOT NULL
      GROUP BY ProductId,FieldCode
    )
    SELECT ''+@SelectList+N''
    FROM PagedProducts AS product
    LEFT JOIN ValuesGrouped AS value ON value.ProductId=product.ProductId
    GROUP BY product.ProductId,product.ItemID
    ORDER BY product.ItemID;'';

  EXEC sys.sp_executesql @Sql,
    N''@OrganizationId int,@OnlyPublished bit,@WebSite nvarchar(100),@SearchLike nvarchar(410),@Skip int,@Take int'',
    @OrganizationId=@OrganizationId,@OnlyPublished=@OnlyPublished,@WebSite=@WebSite,
    @SearchLike=@SearchLike,@Skip=@Skip,@Take=@Take;
END;');

/* Izvedbeni dokaz na obstojecem, aktivnem profilu. Migrator rezultat zavrze, proceduro pa
   vseeno v celoti prevede in izvede. */
IF OBJECT_ID(N'intranet.GetWebExportRows', N'P') IS NULL
  THROW 52958, 'Procedura intranet.GetWebExportRows ni nastala.', 1;

DECLARE @ProbeProfileId int=(SELECT ExportProfileId FROM out.ExportProfile WHERE ProfileCode=N'WEB_B2C_PRODUCTS' AND IsActive=1);
DECLARE @ProbeOrganizationId int=(SELECT MIN(OrganizationId) FROM dbo.OrganizationConfig);
IF @ProbeProfileId IS NULL OR @ProbeOrganizationId IS NULL
  THROW 52959, 'Manjka profil ali organizacija za dokaz spletnega izvoza.', 1;
IF NOT EXISTS (SELECT 1 FROM out.ExportColumn WHERE ExportProfileId=@ProbeProfileId AND IsActive=1)
  THROW 52960, 'Obstojeci spletni profil nima aktivnega stolpca.', 1;

DECLARE @ProbeTotal int;
EXEC intranet.GetWebExportRows
  @OrganizationId=@ProbeOrganizationId,
  @ExportProfileId=@ProbeProfileId,
  @WebSite=NULL,
  @OnlyPublished=0,
  @Search=N'__MIGRACIJA_139_BREZ_ZADETKA__',
  @Skip=0,
  @Take=1,
  @TotalCount=@ProbeTotal OUTPUT;

IF @ProbeTotal<>0
  THROW 52961, 'Kontrolno iskanje spletnega izvoza mora vrniti prazen nabor.', 1;
