/* Organization 2 has no ERP price list named B2B. B2C is its current base
   selling list; customer/item-group discounts are exported separately. */
SET XACT_ABORT ON;
IF NOT EXISTS (SELECT 1 FROM dbo.OrganizationConfig WHERE OrganizationId=2)
  THROW 52801,N'Organizacija 2 ne obstaja.',1;
IF NOT EXISTS (SELECT 1 FROM canon.Codebook WHERE OrganizationId=2 AND CodebookCode=N'PRICELIST' AND EntryCode=N'B2C' AND IsActive=1)
  THROW 52802,N'Cenik B2C za organizacijo 2 ni zajet v sifrantu.',1;
MERGE out.ExportPriceList AS target
USING (SELECT 2 OrganizationId,N'Product.PriceB2B' PriceFieldCode,N'B2C' PriceListCode,10 SortOrder) source
 ON target.OrganizationId=source.OrganizationId AND target.PriceFieldCode=source.PriceFieldCode
WHEN MATCHED THEN UPDATE SET PriceListCode=source.PriceListCode,SortOrder=source.SortOrder,IsActive=1,UpdatedUtc=SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT(OrganizationId,PriceFieldCode,PriceListCode,SortOrder,IsActive)
 VALUES(source.OrganizationId,source.PriceFieldCode,source.PriceListCode,source.SortOrder,1);
UPDATE out.ExportPriceList SET IsActive=0,UpdatedUtc=SYSUTCDATETIME()
WHERE OrganizationId=2 AND PriceFieldCode=N'Product.PriceB2B' AND PriceListCode<>N'B2C';
IF EXISTS(SELECT 1 FROM out.ExportPriceList WHERE OrganizationId=2 AND PriceFieldCode=N'Product.PriceB2B' AND PriceListCode<>N'B2C' AND IsActive=1)
  THROW 52803,N'Neaktiven cenik B2B za organizacijo 2 je ostal aktiven.',1;
