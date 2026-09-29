using Microsoft.Data.SqlClient;
using PIM.B2bWorker;

/// <summary>
/// 302 (naloga #5): »Pakirno naročanje« brez Pakiranja 2 drži artikel s spleta. Pakiranje 2 lahko vpiše ali
/// pobriše zajem iz SAOP mimo kartice in uvoza Excela, zato izvoz katalog.csv pred sestavo datoteke uskladi
/// zadržke (MagentoExportCommand.SyncPackageOrderHoldsAsync). Test teče v transakciji in se na koncu povrne.
/// </summary>
internal static class PackageOrderHoldTests
{
    public static async Task RunAsync(SqlConnection connection)
    {
        await using var transaction = (SqlTransaction)await connection.BeginTransactionAsync();
        var item = "F7_PAK_" + Guid.NewGuid().ToString("N")[..20];
        try
        {
            long productId;
            await using (var seed = new SqlCommand("""
                INSERT canon.Product(OrganizationId,ItemID,Department) VALUES(2,@Item,N'X');
                DECLARE @ProductId bigint=SCOPE_IDENTITY();
                INSERT pim.Product(OrganizationId,ItemID,Name) VALUES(2,@Item,N'Pakirno naročanje fixture');
                INSERT pim.ProductCommercial(PimProductId,Pak2) VALUES(SCOPE_IDENTITY(),NULL);
                INSERT pim.ProductFlag(ProductId,FlagCode,IsSet,ChangedBy) VALUES(@ProductId,N'PAKIRNO_NAROCANJE',1,N'F7');
                SELECT @ProductId;
                """, connection, transaction))
            {
                seed.Parameters.AddWithValue("@Item", item);
                productId = Convert.ToInt64(await seed.ExecuteScalarAsync());
            }

            // Brez Pakiranja 2: izvoz postavi zadržek za splet (pravilo 302).
            var first = await MagentoExportCommand.SyncPackageOrderHoldsAsync(connection, 2, CancellationToken.None, transaction);
            Assert(first.Held >= 1, "Izvoz mora zadržati artikel s Pakirnim naročanjem brez Pakiranja 2.");
            Assert(await ActiveRuleHoldAsync(connection, transaction, productId), "Zadržek »pravilo 302« za WEB mora obstajati.");

            // Zajem iz SAOP vpiše Pakiranje 2 = 6: naslednji izvoz zadržek sprosti.
            await using (var capture = new SqlCommand("""
                UPDATE commercial SET Pak2 = 6
                FROM pim.ProductCommercial commercial JOIN pim.Product promoted ON promoted.PimProductId = commercial.PimProductId
                WHERE promoted.OrganizationId = 2 AND promoted.ItemID = @Item;
                """, connection, transaction))
            {
                capture.Parameters.AddWithValue("@Item", item);
                await capture.ExecuteNonQueryAsync();
            }
            var second = await MagentoExportCommand.SyncPackageOrderHoldsAsync(connection, 2, CancellationToken.None, transaction);
            Assert(second.Released >= 1, "Ko ima artikel Pakiranje 2, mora izvoz zadržek sprostiti.");
            Assert(!await ActiveRuleHoldAsync(connection, transaction, productId), "Po vpisu Pakiranja 2 zadržek »pravilo 302« ni več aktiven.");

            // Ročnega zadržka pravilo ne sprosti.
            await using (var manual = new SqlCommand(
                "INSERT val.ProductHold(ProductId,ChannelCode,Reason,CreatedBy) VALUES(@ProductId,N'WEB',N'F7 ročni zadržek',N'F7');",
                connection, transaction))
            {
                manual.Parameters.AddWithValue("@ProductId", productId);
                await manual.ExecuteNonQueryAsync();
            }
            await MagentoExportCommand.SyncPackageOrderHoldsAsync(connection, 2, CancellationToken.None, transaction);
            await using (var check = new SqlCommand(
                "SELECT COUNT(*) FROM val.ProductHold WHERE ProductId=@ProductId AND IsActive=1 AND CreatedBy=N'F7';", connection, transaction))
            {
                check.Parameters.AddWithValue("@ProductId", productId);
                Assert(Convert.ToInt32(await check.ExecuteScalarAsync()) == 1, "Ročni zadržek mora ostati.");
            }

            Console.WriteLine("F7 Pakirno naročanje: izvoz zadrži artikel brez Pakiranja 2 in ga sprosti po zajemu PASS.");
        }
        finally
        {
            await transaction.RollbackAsync();
        }
    }

    static async Task<bool> ActiveRuleHoldAsync(SqlConnection connection, SqlTransaction transaction, long productId)
    {
        await using var command = new SqlCommand(
            "SELECT COUNT(*) FROM val.ProductHold WHERE ProductId=@ProductId AND IsActive=1 AND ChannelCode=N'WEB' AND CreatedBy=N'pravilo 302';",
            connection, transaction);
        command.Parameters.AddWithValue("@ProductId", productId);
        return Convert.ToInt32(await command.ExecuteScalarAsync()) > 0;
    }

    static void Assert(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
