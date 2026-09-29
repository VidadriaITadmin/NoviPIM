/* 304: stari stolpci odprodaje v katalog.csv kažejo odprodajo iz /izdelki/odprodaja.

   katalog.csv ima od 204/207 tri stare stolpce odprodaje: »Popust na artikel« in »Popust odprodaje %«
   (Product.ClearancePercent, oddelčni popust X/O iz Nadzora kataloga) ter »Količina odprodaje«
   (Clearance.Quantity, zaloga artiklov X/O). 234 je odprodajo iz /izdelki/odprodaja (pim.ClearanceItem)
   namenoma izvozila v nove stolpce »Odprodaja«, »Odprodaja - popust %«, »Odprodaja - količina«, stara
   pa pustila pri miru. Posledica (preizkus uvoza Azzardo 2026-09-29): artikel v odprodaji je imel v
   novih stolpcih 55 % in 2 kosa, v starih pa 0 — kateri stolpec bere Magento, iz kode ni razvidno.

   Uporabnik 2026-09-29: »popravi stare stolpce odprodaje v katalog.csv«. Pravilo: kadar ima artikel
   aktivno odprodajo (»Odprodaja« = DA), stari polji dobita isti popust in količino kot nova; sicer
   ostane dosedanje obnašanje X/O. Stolpci ostanejo (Magento jih morda bere po imenu), vrednosti se
   prepišejo iz že izračunanih novih polj, zato ostanejo usklajene tudi s kasnejšimi popravki
   količine (288, 297). */
SET XACT_ABORT ON;

DECLARE @definition nvarchar(max)=OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows'));
IF @definition IS NULL THROW 53041,N'304: GetExportRows manjka.',1;
IF @definition NOT LIKE N'%OdprodajaExport234%'
  THROW 53042,N'304: GetExportRows nima izvoza odprodaje (234) - najprej migracija 234.',1;
IF @definition NOT LIKE N'%OdprodajaStariStolpci304%'
BEGIN
  DECLARE @anchor nvarchar(max)=N'CREATE CLUSTERED INDEX IX_Value ON #Value (RowKey);';
  IF CHARINDEX(@anchor,@definition)=0 THROW 53043,N'304: nepricakovana definicija izvoznih vrednosti.',1;
  DECLARE @values nvarchar(max)=N'
  IF @ValueSource=N''PIM_PRODUCT'' BEGIN
    /* OdprodajaStariStolpci304: artikel v odprodaji (234 »Odprodaja« = DA) ima v starih stolpcih
       (Product.ClearancePercent, Clearance.Quantity) isti popust in količino kot v novih. */
    SELECT RowKey INTO #Odprodaja304 FROM #Value
    WHERE FieldCode=N''ClearanceItem.IsActive'' AND Value=N''DA'';
    IF EXISTS(SELECT 1 FROM #Odprodaja304) BEGIN
      SELECT map.OldCode AS FieldCode,value.RowKey,value.Value
      INTO #OdprodajaVrednost304
      FROM #Value value
      JOIN (VALUES(N''Product.ClearancePercent'',N''ClearanceItem.DiscountPercent''),
                  (N''Clearance.Quantity'',N''ClearanceItem.Quantity'')) map(OldCode,NewCode) ON map.NewCode=value.FieldCode
      WHERE value.RowKey IN(SELECT RowKey FROM #Odprodaja304);
      DELETE FROM #Value
      WHERE FieldCode IN(N''Product.ClearancePercent'',N''Clearance.Quantity'')
        AND RowKey IN(SELECT RowKey FROM #Odprodaja304);
      INSERT #Value(RowKey,FieldCode,Value) SELECT RowKey,FieldCode,Value FROM #OdprodajaVrednost304;
    END;
  END;
  ';
  SET @definition=REPLACE(@definition,@anchor,@values+@anchor);
  SET @definition=N'ALTER '+SUBSTRING(@definition,CHARINDEX(N'PROCEDURE',@definition),2147483647);
  EXEC sys.sp_executesql @definition;
END;

IF OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows')) NOT LIKE N'%OdprodajaStariStolpci304%'
  THROW 53044,N'304: popravek starih stolpcev odprodaje ni v GetExportRows.',1;
