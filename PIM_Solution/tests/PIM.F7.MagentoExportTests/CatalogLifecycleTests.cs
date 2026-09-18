using System.Data;
using Microsoft.Data.SqlClient;

internal static class CatalogLifecycleTests
{
    public static async Task RunAsync(SqlConnection connection)
    {
        await using var transaction = (SqlTransaction)await connection.BeginTransactionAsync();
        var item = "F7_CAT_" + Guid.NewGuid().ToString("N");
        try
        {
            await Execute("""
                CREATE TABLE #CatalogTest(ProductId bigint,PimProductId bigint,ItemID nvarchar(100),CustomerId bigint NULL);
                CREATE TABLE #CatalogTestStock(SnapshotId bigint,Contribution nvarchar(20));
                INSERT canon.Product(OrganizationId,ItemID,Department,ItemGroup,DiscountGroup,ValidationStatus)
                VALUES(2,@Item,N'X',N'F7_GROUP',N'F7_ERP',N'VALID');
                DECLARE @ProductId bigint=SCOPE_IDENTITY();
                INSERT canon.Product(OrganizationId,ItemID,Department) VALUES(3,@Item,N'X');
                DECLARE @VidProductId bigint=SCOPE_IDENTITY();
                INSERT pim.Product(OrganizationId,ItemID,Name) VALUES(2,@Item,N'Catalog lifecycle fixture');
                DECLARE @PimProductId bigint=SCOPE_IDENTITY();
                INSERT #CatalogTest(ProductId,PimProductId,ItemID) VALUES(@ProductId,@PimProductId,@Item);
                INSERT pim.ProductWebShop(ProductId,WebShopCode,IsPublished,ChangedBy) VALUES(@ProductId,N'svetila_si',1,N'F7');
                INSERT pim.ProductCategory(PimProductId,WebSite,CategoryPath) VALUES(@PimProductId,N'svetila_si',N'F7 lifecycle');
                INSERT val.ProductValidationState(ProductId,ValidationProfileId,Status,Completeness,ValidatedUtc)
                SELECT @ProductId,ValidationProfileId,N'VALID',100,SYSUTCDATETIME() FROM val.ValidationProfile;
                EXEC pim.SaveCatalogPolicy 2,@ProductId,0,25,N'F7';

                DECLARE @Connector int,@Org int,@Contribution nvarchar(20),@Run uniqueidentifier,
                  @Snapshot bigint,@Landing bigint,@Qty decimal(19,4),@Time datetime2(3)=SYSUTCDATETIME();
                DECLARE sources CURSOR LOCAL FAST_FORWARD FOR
                SELECT connector.SourceConnectorId,registry.StockOrganizationId,registry.Contribution
                FROM out.ExportStockSource registry JOIN map.SourceConnector connector
                  ON connector.OrganizationId=registry.StockOrganizationId AND connector.SourceCode=registry.SourceCode
                WHERE registry.OrganizationId=2 AND registry.IsActive=1;
                UPDATE snapshot SET IsActive=0
                FROM stock.Snapshot snapshot
                JOIN out.ExportStockSource registry ON registry.StockOrganizationId=snapshot.OrganizationId
                JOIN map.SourceConnector connector ON connector.SourceConnectorId=snapshot.SourceConnectorId
                  AND connector.OrganizationId=registry.StockOrganizationId AND connector.SourceCode=registry.SourceCode
                WHERE registry.OrganizationId=2 AND registry.IsActive=1 AND snapshot.IsActive=1;
                OPEN sources;
                FETCH NEXT FROM sources INTO @Connector,@Org,@Contribution;
                WHILE @@FETCH_STATUS=0 BEGIN
                  SET @Run=NEWID();
                  SET @Qty=CASE @Contribution WHEN N'BASE' THEN 2 WHEN N'ADD' THEN 3 ELSE 7 END;
                  INSERT stock.SyncRun(SyncRunId,OrganizationId,SourceConnectorId,Status,Endpoint,StartedUtc)
                    VALUES(@Run,@Org,@Connector,N'Succeeded',N'F7',@Time);
                  INSERT stock.Snapshot(SyncRunId,OrganizationId,SourceConnectorId,Endpoint,SnapshotUtc,IsActive)
                    VALUES(@Run,@Org,@Connector,N'F7',@Time,1);
                  SET @Snapshot=SCOPE_IDENTITY();
                  INSERT #CatalogTestStock VALUES(@Snapshot,@Contribution);
                  INSERT stock.LandingRecord(SyncRunId,OrganizationId,SourceConnectorId,SourceRecordKey,SnapshotUtc,Endpoint,RawPayload,PayloadHash)
                    VALUES(@Run,@Org,@Connector,@Item,@Time,N'F7',N'{}',REPLICATE('0',64));
                  SET @Landing=SCOPE_IDENTITY();
                  INSERT stock.Position(SnapshotId,LandingRecordId,NormalizedItemId,Quantity,AvailableQuantity,MatchKey,MatchedProductId)
                    VALUES(@Snapshot,@Landing,@Item,@Qty,@Qty,N'ItemID',CASE WHEN @Org=3 THEN @VidProductId ELSE @ProductId END);
                  FETCH NEXT FROM sources INTO @Connector,@Org,@Contribution;
                END;
                CLOSE sources; DEALLOCATE sources;
                INSERT canon.ProductPrice(ProductId,PriceList,Net,VatRate,ValidFrom,IsActive)
                  VALUES(@ProductId,N'F7_LIFECYCLE',123.45,22,DATEADD(day,-1,SYSUTCDATETIME()),1),
                        (@ProductId,N'F7_LIFECYCLE',999,22,DATEADD(day,1,SYSUTCDATETIME()),1);
                INSERT out.ExportPriceList(OrganizationId,PriceFieldCode,PriceListCode,SortOrder,IsActive)
                  VALUES(2,N'Product.PriceB2B',N'F7_LIFECYCLE',-1000,1);
                INSERT canon.Codebook(OrganizationId,CodebookCode,EntryCode,ExtraCode) VALUES
                  (2,N'PRICELIST',N'F7_LIFECYCLE',N'F7_EUR'),(2,N'CURRENCY',N'F7_EUR',N'EUR');
                INSERT canon.ProductDocument(ProductId,Role,Url,SortOrder) VALUES
                  (@ProductId,N'MAIN',N'https://test.local/main.pdf',0),(@ProductId,N'CE',N'https://test.local/ce.pdf',1);
                INSERT stock.ItemDeliveryDate(OrganizationId,NormalizedItemId,DeliveryDate,Quantity,CheckedUtc) VALUES
                  (2,@Item,DATEADD(day,1,SYSUTCDATETIME()),4,SYSUTCDATETIME()),
                  (3,@Item,DATEADD(day,2,SYSUTCDATETIME()),6,SYSUTCDATETIME());
                """);

            var row = (await Export("MAGENTO_PRODUCTS")).Single();
            Check(row["ABC klasifikacija"] == "X", "ABC reaches the CSV");
            Check(row["VID razpoložljiva količina"] == "5", "IQ 2 + VID 3 are one SKU with stock 5");
            Check(row["Popust na artikel"] == "25", "own stock enables clearance");
            Check(row["Cena B2B"] == "123.45", "current canonical price without promotion");
            Check(row["Rabatna skupina artikla"] == "F7_GROUP", "item group has a separate field");
            Check(row["Rabatna skupina ERP"] == "F7_ERP", "ERP group remains distinct");
            Check(row["Valuta"] == "EUR" && row["DDV"] == "22", "price metadata follows current canonical price");
            Check(row["Glavni dokument"] == "https://test.local/main.pdf" && row["Ostali dokumenti"] == "https://test.local/ce.pdf", "documents reach their columns");
            Check(row["VID koli. prihodnjih dobav"] == "10", "future deliveries include both organizations once");
            var supplier = row["Dobavitelj zaloga"];

            await Execute("""
                UPDATE position SET Quantity=0,AvailableQuantity=0 FROM stock.Position position
                JOIN #CatalogTestStock fixture ON fixture.SnapshotId=position.SnapshotId WHERE fixture.Contribution IN(N'BASE',N'ADD');
                """);
            row = (await Export("MAGENTO_PRODUCTS")).Single();
            Check(row["Popust na artikel"] == "0", "depleted X resets discount explicitly");
            Check(row["Dobavitelj zaloga"] == supplier, "supplier stock survives depletion");
            Check((await Export("MAGENTO_STOCK_PRICES")).Single()["Popust odprodaje %"] == "0", "fast export clears discount too");

            await Execute("UPDATE canon.Product SET Department=N'O' WHERE ProductId=(SELECT ProductId FROM #CatalogTest); EXEC pim.RefreshCatalogReview 2; EXEC pim.RefreshCatalogReview 2;");
            Check(await Scalar("SELECT COUNT(*) FROM pim.CatalogReview WHERE ProductId=(SELECT ProductId FROM #CatalogTest) AND ResolvedUtc IS NULL;") == 1,
                "depleted O enters review exactly once");
            await Execute("""
                DECLARE @Id bigint=(SELECT ProductId FROM #CatalogTest);
                EXEC pim.SaveCatalogPolicy 2,@Id,1,25,N'F7';
                EXEC pim.ResolveCatalogReview 2,@Id,N'Excluded after review',N'F7';
                EXEC pim.RefreshCatalogReview 2;
                """);
            Check((await Export("MAGENTO_PRODUCTS")).Count == 0, "manual exclusion wins");
            Check(await Scalar("SELECT COUNT(*) FROM pim.CatalogReview WHERE ProductId=(SELECT ProductId FROM #CatalogTest) AND ResolvedUtc IS NULL;") == 0,
                "resolved excluded O stays resolved");

            await Execute("""
                DECLARE @Id bigint=(SELECT ProductId FROM #CatalogTest);
                EXEC pim.SaveCatalogPolicy 2,@Id,0,25,N'F7';
                UPDATE stock.Snapshot SET SnapshotUtc=DATEADD(day,-2,SYSUTCDATETIME())
                  WHERE SnapshotId IN(SELECT SnapshotId FROM #CatalogTestStock WHERE Contribution IN(N'BASE',N'ADD'));
                EXEC pim.RefreshCatalogReview 2;
                """);
            Check(await Scalar("SELECT COUNT(*) FROM pim.CatalogReview WHERE ProductId=(SELECT ProductId FROM #CatalogTest) AND ResolvedUtc IS NULL;") == 0,
                "stale observations do not reopen review");

            await Execute("""
                INSERT b2b.Customer(OrganizationId,CustomerKey,Name) VALUES(2,@Item,N'F7 catalog customer');
                DECLARE @Customer bigint=SCOPE_IDENTITY();
                UPDATE #CatalogTest SET CustomerId=@Customer;
                INSERT pim.CustomerWebProfile(CustomerId,CustomerTypeCode) VALUES(@Customer,N'INSTALLER');
                INSERT b2b.GroupDiscount(CustomerId,ItemGroupCode,PercentValue) VALUES(@Customer,N'F7_GROUP',5);
                INSERT b2b.GroupDiscountOverride(OrganizationId,TargetKind,CustomerTypeCode,ItemGroupCode,PercentValue)
                  VALUES(2,N'TYPE',N'INSTALLER',N'F7_GROUP',10);
                INSERT b2b.GroupDiscountOverride(OrganizationId,TargetKind,CustomerId,ItemGroupCode,PercentValue)
                  VALUES(2,N'CUSTOMER',@Customer,N'F7_GROUP',15);
                INSERT b2b.GroupDiscountOverride(OrganizationId,TargetKind,CustomerId,ItemGroupCode,PercentValue,ValidTo)
                  VALUES(2,N'CUSTOMER',@Customer,N'F7_GROUP',99,DATEADD(day,-1,SYSUTCDATETIME()));
                """);
            Check((await Export("MAGENTO_CUSTOMERS")).Single()["Skupine popustov"] == "F7_GROUP=15%", "customer override beats type and ERP; expired rules excluded");
            await Execute("UPDATE b2b.GroupDiscountOverride SET IsActive=0 WHERE CustomerId=(SELECT CustomerId FROM #CatalogTest);");
            Check((await Export("MAGENTO_CUSTOMERS")).Single()["Skupine popustov"] == "F7_GROUP=10%", "type fallback");
            Console.WriteLine("F7 catalog lifecycle: combined stock, X/O, review, exclusion, live prices and customer discounts PASS.");
        }
        finally { await transaction.RollbackAsync(); }

        SqlCommand Command(string sql)
        {
            var command = new SqlCommand(sql, connection, transaction) { CommandTimeout = 180 };
            command.Parameters.Add("@Item", SqlDbType.NVarChar, 100).Value = item;
            return command;
        }
        async Task Execute(string sql) { await using var command = Command(sql); await command.ExecuteNonQueryAsync(); }
        async Task<int> Scalar(string sql) { await using var command = Command(sql); return Convert.ToInt32(await command.ExecuteScalarAsync()); }
        async Task<List<Dictionary<string,string>>> Export(string profile)
        {
            await using var command = Command("""
                DECLARE @ProfileId int=(SELECT ExportProfileId FROM out.ExportProfile WHERE ProfileCode=@Profile),@Count int;
                EXEC out.GetExportRows @OrganizationId=2,@ExportProfileId=@ProfileId,@Search=@Item,@Take=0,@OnlyPublished=1,@TotalCount=@Count OUTPUT;
                """);
            command.Parameters.Add("@Profile", SqlDbType.NVarChar, 100).Value = profile;
            await using var reader = await command.ExecuteReaderAsync();
            var rows = new List<Dictionary<string,string>>();
            while (await reader.ReadAsync())
            {
                var row = new Dictionary<string,string>();
                for (var i=0;i<reader.FieldCount;i++) row.Add(reader.GetName(i), reader.IsDBNull(i) ? "" : reader.GetString(i));
                rows.Add(row);
            }
            return rows;
        }
    }
    static void Check(bool condition,string message)
    {
        if (!condition) throw new InvalidOperationException("Catalog lifecycle: " + message);
    }
}
