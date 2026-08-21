using Microsoft.Data.SqlClient;

var connectionString = Environment.GetEnvironmentVariable("PIM_CONNECTION_STRING") ?? throw new InvalidOperationException("Manjka PIM_CONNECTION_STRING.");
await using var connection = new SqlConnection(connectionString);
await connection.OpenAsync();
const string sql = """
DECLARE @ProductId bigint;
SELECT @ProductId = ProductId FROM canon.Product WHERE OrganizationId = 1 AND ItemID = N'F2-PROOF-001';
IF @ProductId IS NULL
BEGIN
  INSERT canon.Product (OrganizationId, ItemID) VALUES (1, N'F2-PROOF-001');
  SET @ProductId = SCOPE_IDENTITY();
END;
DELETE FROM canon.ProductText WHERE ProductId = @ProductId;
DELETE FROM canon.ProductAttribute WHERE ProductId = @ProductId;
DELETE FROM canon.ProductCategory WHERE ProductId = @ProductId;
DELETE FROM canon.ProductMedia WHERE ProductId = @ProductId;
DELETE FROM canon.ProductPrice WHERE ProductId = @ProductId;
DELETE FROM canon.ProductCommercial WHERE ProductId = @ProductId;
UPDATE canon.Product SET EAN = NULL, UoM = NULL, Supplier = NULL, Manufacturer = NULL, AccountingGroup = NULL, DiscountGroup = NULL, ItemGroup = NULL, Department = NULL, ValidationStatus = N'PENDING' WHERE ProductId = @ProductId;
EXEC val.RunValidation @OrganizationId = 1;
IF NOT EXISTS (SELECT 1 FROM val.ProductIssue WHERE ProductId = @ProductId AND IsActive = 1) THROW 52201, 'Manjkajoča polja niso označena.', 1;
-- "Poln izdelek" pomeni poln za VSE aktivne profile, ne le za prva dva. Od migracije 047 so
-- profili SHARED_CORE, ERP_L1_SLO, ERP_L1_EU/THIRD, COMMERCIAL_L2 in oba WEB; trditev spodaj
-- (poln izdelek nima nobene aktivne pomanjkljivosti) drzi samo, ce je res poln.
UPDATE canon.Product SET EAN=N'3830000000001', UoM=N'KOS', Supplier=N'Dobavitelj', Manufacturer=N'Proizvajalec', AccountingGroup=N'AG', DiscountGroup=N'DG', ItemGroup=N'SKUPINA', Department=N'ODDELEK' WHERE ProductId=@ProductId;
INSERT canon.ProductCommercial (ProductId,NetWeight,GrossWeight,CustomsTariff,CountryOfOrigin,Pak1,Pak2)
  VALUES (@ProductId,1.5,2.0,N'94051140',N'SI',1,6);
INSERT canon.ProductText (ProductId,Lang,TextType,Value) VALUES (@ProductId,N'sl',N'TITLE_ERP',N'ERP naziv'),(@ProductId,N'sl',N'WEB_TITLE',N'Spletni naziv'),(@ProductId,N'en',N'WEB_TITLE',N'Web title');
INSERT canon.ProductAttribute (ProductId,AttributeCode,Value) VALUES (@ProductId,N'CategoryRequired',N'Vrednost');
INSERT canon.ProductCategory (ProductId,WebSite,CategoryPath) VALUES (@ProductId,N'svetila.si',N'Svetila/Test');
INSERT canon.ProductMedia (ProductId,Url,Role,SortOrder) VALUES (@ProductId,N'https://example.invalid/image.jpg',N'Primary',1);
INSERT canon.ProductPrice (ProductId,PriceList,Net,VatRate,ValidFrom,IsActive) VALUES (@ProductId,N'B2C',10,22,'2026-01-01',1);
EXEC val.RunValidation @OrganizationId = 1;
IF EXISTS (SELECT 1 FROM val.ProductIssue WHERE ProductId = @ProductId AND IsActive = 1) THROW 52202, 'Poln izdelek ima aktivne napake.', 1;
-- Stopnja resnosti mora biti dosezljiva v obe smeri: brez angleskega spletnega naziva mora
-- nastati OPOZORILO, izdelek pa mora ostati VALID. Prej tega ni bilo mogoce izraziti.
DELETE FROM canon.ProductText WHERE ProductId = @ProductId AND Lang = N'en' AND TextType = N'WEB_TITLE';
EXEC val.RunValidation @OrganizationId = 1;
IF NOT EXISTS
(
  SELECT 1 FROM val.ProductIssue issue
  INNER JOIN val.FieldRequirement requirement ON requirement.FieldRequirementId = issue.FieldRequirementId
  WHERE issue.ProductId = @ProductId AND issue.IsActive = 1 AND requirement.Severity = N'WARNING'
) THROW 52205, 'Manjkajoce polje z opozorilom ni oznaceno.', 1;
IF NOT EXISTS (SELECT 1 FROM canon.Product WHERE ProductId=@ProductId AND ValidationStatus=N'VALID')
  THROW 52206, 'Opozorilo je izdelek razglasilo za neveljaven.', 1;
INSERT canon.ProductText (ProductId,Lang,TextType,Value) VALUES (@ProductId,N'en',N'WEB_TITLE',N'Web title');
EXEC val.RunValidation @OrganizationId = 1;
IF NOT EXISTS (SELECT 1 FROM canon.Product WHERE ProductId=@ProductId AND ValidationStatus=N'VALID') THROW 52203, 'Izdelek ni VALID.', 1;
EXEC val.Promote @OrganizationId = 1;
EXEC val.Promote @OrganizationId = 1;
IF (SELECT COUNT(*) FROM pim.Product WHERE OrganizationId=1 AND ItemID=N'F2-PROOF-001') <> 1 THROW 52204, 'Promocija ni idempotentna.', 1;
""";
await using var command = new SqlCommand(sql, connection);
await command.ExecuteNonQueryAsync();
Console.WriteLine("F2 integracijski dokaz je uspešen.");
