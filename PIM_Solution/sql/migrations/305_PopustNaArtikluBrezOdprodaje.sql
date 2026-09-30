/* 305: »Popust na artikel« ne nosi popusta odprodaje.

   304 je artiklom v odprodaji (/izdelki/odprodaja) prepisala polje Product.ClearancePercent s popustom
   odprodaje. Isto polje pa bere tudi stolpec »Popust na artikel« (COL030), zato je artikel v odprodaji
   imel popust odprodaje v dveh popustnih stolpcih — nevarnost dvojnega popusta, če Magento »Popust na
   artikel« uporabi kot redni popust. Uporabnik 2026-09-29: »Popust na artikel« naj odprodaje ne meša
   (ostane oddelčni popust X/O iz Nadzora kataloga, sicer 0; iz cenikov SAOP PIM popusta ne zajema).

   - Novo izvozno polje Clearance.CatalogDiscountPercent = Product.ClearancePercent, pri artiklih v
     odprodaji pa popust odprodaje (blok 304 prepiše to polje namesto Product.ClearancePercent).
   - Nanj se preusmerita stolpca »Popust odprodaje %« (MAGENTO_PRODUCTS COL217 in CATALOG_CLEARANCE,
     MAGENTO_STOCK_PRICES CATALOG_CLEARANCE). »Popust na artikel« ostane na Product.ClearancePercent.
   - »Količina odprodaje« (Clearance.Quantity) ostane kot po 304. */
SET XACT_ABORT ON;

DECLARE @definition nvarchar(max)=OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows'));
IF @definition IS NULL THROW 53051,N'305: GetExportRows manjka.',1;
IF @definition NOT LIKE N'%OdprodajaStariStolpci304%'
  THROW 53052,N'305: GetExportRows nima bloka 304 - najprej migracija 304.',1;
IF @definition NOT LIKE N'%PopustNaArtikluBrezOdprodaje305%'
BEGIN
  DECLARE @start nvarchar(max)=N'SELECT RowKey INTO #Odprodaja304 FROM #Value';
  DECLARE @map nvarchar(max)=N'JOIN (VALUES(N''Product.ClearancePercent'',N''ClearanceItem.DiscountPercent''),';
  DECLARE @delete nvarchar(max)=N'WHERE FieldCode IN(N''Product.ClearancePercent'',N''Clearance.Quantity'')';
  IF CHARINDEX(@start,@definition)=0 OR CHARINDEX(@map,@definition)=0 OR CHARINDEX(@delete,@definition)=0
    THROW 53053,N'305: blok 304 v GetExportRows ni v pricakovani obliki.',1;

  /* Nobenega sumnika v besedilu procedure (zaganjalnik migracij ne bere UTF-8). */
  SET @definition=REPLACE(@definition,@start,N'/* PopustNaArtikluBrezOdprodaje305: stolpec Popust odprodaje % bere svoje polje;
       Popust na artikel (Product.ClearancePercent) ostane brez odprodaje. */
    INSERT #Value(RowKey,FieldCode,Value)
    SELECT RowKey,N''Clearance.CatalogDiscountPercent'',Value FROM #Value WHERE FieldCode=N''Product.ClearancePercent'';
    '+@start);
  SET @definition=REPLACE(@definition,@map,N'JOIN (VALUES(N''Clearance.CatalogDiscountPercent'',N''ClearanceItem.DiscountPercent''),');
  SET @definition=REPLACE(@definition,@delete,N'WHERE FieldCode IN(N''Clearance.CatalogDiscountPercent'',N''Clearance.Quantity'')');
  SET @definition=N'ALTER '+SUBSTRING(@definition,CHARINDEX(N'PROCEDURE',@definition),2147483647);
  EXEC sys.sp_executesql @definition;
END;

UPDATE c SET CanonicalFieldCode=N'Clearance.CatalogDiscountPercent'
FROM out.ExportColumn c JOIN out.ExportProfile p ON p.ExportProfileId=c.ExportProfileId
WHERE p.ProfileCode IN(N'MAGENTO_PRODUCTS',N'MAGENTO_STOCK_PRICES')
  AND c.OutputColumnName=N'Popust odprodaje %' AND c.CanonicalFieldCode=N'Product.ClearancePercent';

IF OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows')) NOT LIKE N'%PopustNaArtikluBrezOdprodaje305%'
  THROW 53054,N'305: popravek ni v GetExportRows.',1;
IF EXISTS(SELECT 1 FROM out.ExportColumn c JOIN out.ExportProfile p ON p.ExportProfileId=c.ExportProfileId
  WHERE p.ProfileCode IN(N'MAGENTO_PRODUCTS',N'MAGENTO_STOCK_PRICES') AND c.OutputColumnName=N'Popust odprodaje %'
    AND c.CanonicalFieldCode<>N'Clearance.CatalogDiscountPercent')
  THROW 53055,N'305: stolpec Popust odprodaje % ni preusmerjen.',1;
IF NOT EXISTS(SELECT 1 FROM out.ExportColumn c JOIN out.ExportProfile p ON p.ExportProfileId=c.ExportProfileId
  WHERE p.ProfileCode=N'MAGENTO_PRODUCTS' AND c.ColumnCode=N'COL030' AND c.CanonicalFieldCode=N'Product.ClearancePercent')
  THROW 53056,N'305: Popust na artikel ni vec na Product.ClearancePercent.',1;
