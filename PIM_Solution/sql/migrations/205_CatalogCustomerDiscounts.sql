/* The exported item group and Customer.GroupDiscounts share ItemGroupCode.
   Apply the same advertised priority as the commercial editor: customer, type,
   imported ERP rule. Emit one effective value per customer and item group. */
SET XACT_ABORT ON;
DECLARE @definition nvarchar(max)=OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows'));
IF @definition IS NULL THROW 52501,N'GetExportRows manjka.',1;
IF @definition NOT LIKE N'%/* CatalogCustomer205 */%'
BEGIN
 DECLARE @start int=CHARINDEX(N'    INSERT #GroupDiscount (RowKey, ItemGroupCode, PercentText)',@definition);
 DECLARE @finish int=CHARINDEX(N'    INSERT #Value (RowKey, FieldCode, Value)',@definition,@start);
 IF @start=0 OR @finish<=@start THROW 52502,N'Nepricakovana definicija skupinskih rabatov.',1;
 DECLARE @replacement nvarchar(max)=N'
    /* CatalogCustomer205 */
    INSERT #GroupDiscount(RowKey,ItemGroupCode,PercentText)
    SELECT RowKey,ItemGroupCode,out.MagentoNumber(PercentValue)
    FROM (
      SELECT candidates.*,ROW_NUMBER() OVER(PARTITION BY RowKey,ItemGroupCode
        ORDER BY Priority,ValidFrom DESC,RuleId DESC) PickRank
      FROM (
        SELECT page.RowKey,discount.ItemGroupCode,discount.PercentValue,
          3 Priority,discount.ValidFrom,discount.GroupDiscountId RuleId
        FROM #Page page JOIN b2b.GroupDiscount discount ON discount.CustomerId=page.EntityId
        WHERE (discount.ValidFrom IS NULL OR discount.ValidFrom<=CONVERT(date,SYSUTCDATETIME()))
          AND (discount.ValidTo IS NULL OR discount.ValidTo>=CONVERT(date,SYSUTCDATETIME()))
        UNION ALL
        SELECT page.RowKey,discount.ItemGroupCode,discount.PercentValue,
          CASE discount.TargetKind WHEN N''CUSTOMER'' THEN 1 ELSE 2 END,
          discount.ValidFrom,discount.OverrideId
        FROM #Page page
        JOIN pim.CustomerWebProfile profile ON profile.CustomerId=page.EntityId
        JOIN b2b.GroupDiscountOverride discount ON discount.OrganizationId=@OrganizationId
          AND ((discount.TargetKind=N''CUSTOMER'' AND discount.CustomerId=page.EntityId)
            OR (discount.TargetKind=N''TYPE'' AND discount.CustomerTypeCode=profile.CustomerTypeCode))
        WHERE discount.IsActive=1
          AND (discount.ValidFrom IS NULL OR discount.ValidFrom<=CONVERT(date,SYSUTCDATETIME()))
          AND (discount.ValidTo IS NULL OR discount.ValidTo>=CONVERT(date,SYSUTCDATETIME()))
      ) candidates
    ) ranked WHERE PickRank=1;

 ';
 SET @definition=STUFF(@definition,@start,@finish-@start,@replacement);
 SET @definition=N'ALTER '+SUBSTRING(@definition,CHARINDEX(N'PROCEDURE',@definition),2147483647);
 EXEC sys.sp_executesql @definition;
END;
