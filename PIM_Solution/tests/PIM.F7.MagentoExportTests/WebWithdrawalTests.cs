using System.Data;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using PIM.B2b;
using PIM.B2bWorker;

/// <summary>
/// 251 — kaj gre v katalog.csv in samodejni umik s spleta.
///
/// Uporabnik 2026-09-22: »v katalog.csv samo artikli, ki so aktivni, imajo kljukico svetila ali
/// videlektro in so veljavni za splet. Če artikel ni veljaven (npr. se mu pobriše slika), se mora
/// avtomatsko odkljukati z obeh strani, uporabnik pa mora dobiti opozorilo, kaj manjka.« Prazne
/// »Spletne strani« Magento razume kot umik z vseh spletišč.
///
/// Vse teče v eni transakciji na pravem, za svetila_si veljavnem artiklu in se na koncu razveljavi:
/// brisanje slik, kljukice, umiki, opozorilo, zgodovina in stanje objave ne ostanejo v bazi.
/// </summary>
internal static class WebWithdrawalTests
{
    public static void RunWithoutDatabase()
    {
        // Zajem objave iz vrstic, ki gredo v datoteko: po kanonični kodi stolpca, ne po glavi.
        var columns = new[]
        {
            new ExportColumnDefinition("C1", "Šifra artikla", "Product.ItemID", 1, true, true),
            new ExportColumnDefinition("C2", "Naziv", "Product.Name", 2, false, true),
            new ExportColumnDefinition("C3", "Spletne strani", "Product.WebSites", 3, false, true),
        };
        var captured = new List<MagentoExportCommand.PublishedRow>();
        var rows = MagentoExportCommand.CapturePublication(Rows(), columns, captured, CancellationToken.None);
        var passed = rows.ToBlockingEnumerable().ToList();
        Check(passed.Count == 3, "zajem objave mora vrstice spustiti skozi nespremenjene");
        Check(captured.Count == 2, "zajem objave vzame samo vrstice s šifro");
        Check(captured[0] is { ItemId: "A-1", WebSites: "svetila|videlektro" }, "objavljena vrstica nosi Spletne strani");
        Check(captured[1] is { ItemId: "A-2", WebSites: null }, "odjavna vrstica ima prazne Spletne strani");

        static async IAsyncEnumerable<IReadOnlyList<string?>> Rows()
        {
            yield return new string?[] { "A-1", "Svetilka", "svetila|videlektro" };
            yield return new string?[] { "A-2", "Umaknjena", null };
            yield return new string?[] { null, "brez šifre", "svetila" };
            await Task.CompletedTask;
        }
    }

    public static async Task RunAsync(SqlConnection connection, int organizationId, long productId, string itemId)
    {
        await using var transaction = (SqlTransaction)await connection.BeginTransactionAsync();
        try
        {
            // --- Izhodišče: obe kljukici, artikel je bil objavljen, samodejni umik vklopljen -----------
            await Execute("""
                MERGE pim.ProductWebShop AS target
                USING (VALUES (N'svetila_si'), (N'videlektro')) AS source(WebShopCode)
                  ON target.ProductId = @ProductId AND target.WebShopCode = source.WebShopCode
                WHEN MATCHED THEN UPDATE SET IsPublished = 1, ChangedBy = N'F7-251'
                WHEN NOT MATCHED THEN INSERT (ProductId, WebShopCode, IsPublished, ChangedBy) VALUES (@ProductId, source.WebShopCode, 1, N'F7-251');
                DELETE out.WebPublication WHERE OrganizationId = @OrgId AND ItemID = @Item;
                INSERT out.WebPublication (OrganizationId, ItemID, WebSites, FirstPublishedUtc, LastPublishedUtc, Source)
                VALUES (@OrgId, @Item, N'svetila', SYSUTCDATETIME(), SYSUTCDATETIME(), N'F7-251');
                UPDATE pim.WebPublicationPolicy SET AutoWithdrawEnabled = 0, WithdrawalRowDays = 14, UpdatedBy = N'F7-251' WHERE OrganizationId = @OrgId;
                EXEC val.RunValidationForProduct @ProductId = @ProductId;
                """);

            var allowedTrees = await AllowedTreesAsync();
            Check(allowedTrees.Contains("svetila_si"), "izbran artikel mora biti za svetila veljaven (pogoj testa)");
            var sites = await ExportSitesAsync("MAGENTO_PRODUCTS");
            Check(sites.TryGetValue(itemId, out var published), "aktiven, označen in veljaven artikel mora biti v katalog.csv");
            Check(published!.Split('|').Contains("svetila"), "Spletne strani morajo našteti svetila");
            Check(published.Split('|').Contains("videlektro") == allowedTrees.Contains("videlektro"),
                $"Spletne strani naštejejo samo spletišča, na katera artikel dejansko gre (je: {published})");

            // --- Uvoz pobriše vse slike (ista pot kot delovni list: pim.SaveProductMediaBulk) ----------
            var images = await ImagesAsync();
            Check(images.Count > 0, "veljaven artikel za splet ima vsaj eno sliko (pogoj testa)");
            await ScalarAsync("""
                EXEC pim.SaveProductMediaBulk @OrganizationId = @OrgId, @ChangesJson = @Changes, @Actor = N'F7-251', @Note = N'F7 251: pobrisana slika';
                """, ("@Changes", JsonSerializer.Serialize(new[] { new { productId, kind = "IMAGES", urls = Array.Empty<string>(), remove = images } })));
            Check((await ImagesAsync()).Count == 0, "uvoz s praznim seznamom slik mora sliki pobrisati");

            // Še preden PIM odkljuka, artikel ne gre ven kot objavljen, ampak kot odjavna vrstica.
            sites = await ExportSitesAsync("MAGENTO_PRODUCTS");
            Check(sites.TryGetValue(itemId, out var beforeWithdrawal) && beforeWithdrawal == "",
                "neveljaven artikel, ki je bil objavljen, gre v katalog.csv s praznimi Spletne strani (umik v Magentu)");

            // Predogled ničesar ne spremeni, izklopljen umik ničesar ne odkljuka.
            var preview = await WithdrawAsync("PREVIEW");
            Check(preview.Count == 2 && preview.All(row => row.MissingFields?.Split('|').Contains("ProductMedia.Url") == true),
                "predogled mora najti obe spletišči z razlogom ProductMedia.Url");
            Check(await FlagCountAsync() == 2, "predogled ne sme odkljukati");
            Check((await WithdrawAsync("AUTO")).Count == 0, "pri izklopljenem samodejnem umiku AUTO ne odkljuka");
            Check(await FlagCountAsync() == 2, "pri izklopljenem samodejnem umiku kljukici ostaneta");

            // Vklopljen umik: odkljuka OBE spletišči, zapiše razlog in odpre opozorilo.
            await Execute("UPDATE pim.WebPublicationPolicy SET AutoWithdrawEnabled = 1 WHERE OrganizationId = @OrgId;");
            var withdrawn = await WithdrawAsync("AUTO", revalidate: true);
            Check(withdrawn.Count == 2 && withdrawn.All(row => row.WithdrawalId is not null), "umik mora odkljukati svetila in videlektro");
            Check(await FlagCountAsync() == 0, "po umiku artikel nima nobene kljukice");
            Check(Convert.ToInt32(await ScalarAsync("""
                SELECT COUNT(*) FROM pim.WebShopWithdrawal
                WHERE ProductId = @ProductId AND RestoredUtc IS NULL AND ReviewedUtc IS NULL
                  AND TriggerSource = N'VALIDACIJA' AND CHARINDEX(N'ProductMedia.Url', MissingFields) > 0;
                """)) == 2, "umik mora ohraniti razlog (manjka slika) za obe spletišči");
            Check(Convert.ToInt32(await ScalarAsync("""
                SELECT COUNT(*) FROM pim.ProductFieldHistory
                WHERE ProductId = @ProductId AND FieldKey IN (N'ProductWebShop.svetila_si', N'ProductWebShop.videlektro')
                  AND OldValue = N'da' AND NewValue = N'ne'
                  AND ChangeBatchId IN (SELECT ChangeBatchId FROM pim.ProductChangeBatch WHERE ChangedBy LIKE N'SISTEM%');
                """)) == 2, "odkljukanje mora biti v zgodovini sprememb z avtorjem SISTEM");
            var alert = (string?)await ScalarAsync("""
                SELECT TOP(1) CONCAT(Title, N' | ', PayloadSummaryRedacted) FROM ops.Alert
                WHERE OrganizationId = @OrgId AND AlertKind = N'WebShopWithdrawn' AND ResolvedUtc IS NULL;
                """);
            Check(alert is not null && alert.Contains(itemId, StringComparison.Ordinal),
                "opozorilo WebShopWithdrawn mora biti odprto in navesti artikel");
            Check(Convert.ToInt32(await ScalarAsync("""
                SELECT COUNT(*) FROM val.ProductValidationState state
                INNER JOIN val.ValidationProfile profile ON profile.ValidationProfileId = state.ValidationProfileId
                WHERE state.ProductId = @ProductId AND profile.ProfileCode IN (N'WEB_svetila_si', N'WEB_videlektro');
                """)) == 0, "odkljukan artikel ni več v obsegu spletnih profilov (248)");
            sites = await ExportSitesAsync("MAGENTO_PRODUCTS");
            Check(sites.TryGetValue(itemId, out var afterWithdrawal) && afterWithdrawal == "",
                "umaknjen artikel gre v katalog.csv kot odjavna vrstica");
            Check(!(await ExportSitesAsync("MAGENTO_STOCK_PRICES", sitesColumn: false)).ContainsKey(itemId),
                "datoteka cen in zaloge nosi samo objavljene artikle, brez odjav");

            // Ponovna kljukica brez slike ne obvelja in pove, kaj manjka.
            var rejected = await SaveWebShopsAsync("svetila_si");
            Check(rejected.Count == 1 && rejected[0].Split('|').Contains("ProductMedia.Url"),
                "kljukica na artiklu brez slike mora biti zavrnjena z razlogom ProductMedia.Url");
            Check(await FlagCountAsync() == 0, "zavrnjena kljukica ne ostane");

            // Slike nazaj, kljukica obvelja, umik tega spletišča se zapre, artikel je spet objavljen.
            await ScalarAsync("""
                EXEC pim.SaveProductMediaBulk @OrganizationId = @OrgId, @ChangesJson = @Changes, @Actor = N'F7-251', @Note = N'F7 251: slike nazaj';
                """, ("@Changes", JsonSerializer.Serialize(new[] { new { productId, kind = "IMAGES", urls = images, remove = Array.Empty<string>() } })));
            Check((await ImagesAsync()).Count == images.Count, "slike se morajo vrniti");
            Check((await SaveWebShopsAsync("svetila_si")).Count == 0, "veljaven artikel mora kljukico dobiti");
            Check(await FlagCountAsync() == 1, "po popravku ima artikel kljukico svetila");
            Check(await ScalarAsync("""
                SELECT RestoredBy FROM pim.WebShopWithdrawal WHERE ProductId = @ProductId AND WebShopCode = N'svetila_si';
                """) is string restoredBy && restoredBy == "F7-251", "sprejeta kljukica zapre umik tega spletišča");
            sites = await ExportSitesAsync("MAGENTO_PRODUCTS");
            Check(sites.TryGetValue(itemId, out var republished) && republished.Split('|').Contains("svetila"),
                "popravljen in ponovno označen artikel je spet objavljen");

            // Pregled preostalega umika (videlektro); opozorilo se zapre, kadar v podjetju ni odprtih umikov.
            Check(Convert.ToInt32(await ScalarAsync("""
                EXEC pim.ReviewWebShopWithdrawals @OrganizationId = @OrgId, @WithdrawalIdsJson = NULL, @Actor = N'F7-251';
                """)) >= 1, "pregled mora označiti odprt umik");
            var openLeft = Convert.ToInt32(await ScalarAsync(
                "SELECT COUNT(*) FROM pim.WebShopWithdrawal WHERE OrganizationId = @OrgId AND ReviewedUtc IS NULL AND RestoredUtc IS NULL;"));
            var openAlerts = Convert.ToInt32(await ScalarAsync(
                "SELECT COUNT(*) FROM ops.Alert WHERE OrganizationId = @OrgId AND AlertKind = N'WebShopWithdrawn' AND ResolvedUtc IS NULL;"));
            Check(openLeft > 0 || openAlerts == 0, "brez odprtih umikov mora biti opozorilo zaprto");

            // --- Odjavno okno in artikel, ki ni bil nikoli objavljen -------------------------------
            await Execute("UPDATE pim.ProductWebShop SET IsPublished = 0 WHERE ProductId = @ProductId;");
            await Execute("EXEC out.RecordWebPublication @OrganizationId = @OrgId, @RowsJson = @Rows;",
                ("@Rows", JsonSerializer.Serialize(new[] { new { i = itemId, s = "" } })));
            Check(await ScalarAsync("SELECT WithdrawnUtc FROM out.WebPublication WHERE OrganizationId = @OrgId AND ItemID = @Item;") is DateTime,
                "prvi izvoz z odjavno vrstico začne odjavno okno");
            Check((await ExportSitesAsync("MAGENTO_PRODUCTS")).TryGetValue(itemId, out var inWindow) && inWindow == "",
                "v odjavnem oknu gre artikel v katalog.csv s praznimi Spletne strani");
            await Execute("UPDATE out.WebPublication SET WithdrawnUtc = DATEADD(day, -15, SYSUTCDATETIME()) WHERE OrganizationId = @OrgId AND ItemID = @Item;");
            Check(!(await ExportSitesAsync("MAGENTO_PRODUCTS")).ContainsKey(itemId), "po odjavnem oknu (14 dni) artikla v katalog.csv ni več");
            await Execute("DELETE out.WebPublication WHERE OrganizationId = @OrgId AND ItemID = @Item;");
            Check(!(await ExportSitesAsync("MAGENTO_PRODUCTS")).ContainsKey(itemId), "artikel, ki ni bil nikoli objavljen, v katalog.csv ne gre");
            await Execute("EXEC out.RecordWebPublication @OrganizationId = @OrgId, @RowsJson = @Rows;",
                ("@Rows", JsonSerializer.Serialize(new[] { new { i = itemId, s = "svetila" } })));
            Check(await ScalarAsync("SELECT CONCAT(WebSites, N'|', CASE WHEN WithdrawnUtc IS NULL THEN N'objavljen' END) FROM out.WebPublication WHERE OrganizationId = @OrgId AND ItemID = @Item;")
                is "svetila|objavljen", "objava v izvozu zapiše spletne strani in zapre odjavo");

            // --- Neaktiven artikel s kljukico: umik z razlogom neaktivnosti ---------------------------
            await Execute("""
                UPDATE pim.ProductWebShop SET IsPublished = 1 WHERE ProductId = @ProductId AND WebShopCode = N'svetila_si';
                UPDATE canon.Product SET IsActive = 0 WHERE ProductId = @ProductId;
                """);
            var inactive = await WithdrawAsync("PREVIEW");
            Check(inactive.Count == 1 && inactive[0].WasInactive, "neaktiven artikel s kljukico je kandidat za umik (razlog: ni aktiven)");
            Check((await ExportSitesAsync("MAGENTO_PRODUCTS")).TryGetValue(itemId, out var inactiveSites) && inactiveSites == "",
                "neaktiven artikel, ki je bil objavljen, gre v katalog.csv kot odjava");

            Console.WriteLine($"F7 251: katalog.csv (objavljeni + odjave), samodejni umik ob pobrisani sliki, zavrnjena kljukica, odjavno okno za {itemId} PASS.");
        }
        finally
        {
            await transaction.RollbackAsync();
        }

        async Task<HashSet<string>> AllowedTreesAsync()
        {
            await using var command = Command("EXEC intranet.GetProductWebExportState @ProductId = @ProductId;");
            await using var reader = await command.ExecuteReaderAsync();
            await reader.NextResultAsync();
            var trees = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            while (await reader.ReadAsync())
                if (reader.GetBoolean(reader.GetOrdinal("IsAllowed"))) trees.Add(reader.GetString(reader.GetOrdinal("CategoryTreeCode")));
            return trees;
        }

        async Task<List<string>> ImagesAsync()
        {
            await using var command = Command("SELECT Url FROM canon.ProductMedia WHERE ProductId = @ProductId ORDER BY SortOrder, ProductMediaId;");
            await using var reader = await command.ExecuteReaderAsync();
            var urls = new List<string>();
            while (await reader.ReadAsync()) urls.Add(reader.GetString(0));
            return urls;
        }

        async Task<int> FlagCountAsync() =>
            Convert.ToInt32(await ScalarAsync("SELECT COUNT(*) FROM pim.ProductWebShop WHERE ProductId = @ProductId AND IsPublished = 1;"));

        async Task<List<(long? WithdrawalId, string? MissingFields, bool WasInactive)>> WithdrawAsync(string mode, bool revalidate = false)
        {
            await using var command = Command("""
                EXEC pim.WithdrawIneligibleWebShops @ProductIdsJson = @Ids, @TriggerSource = N'VALIDACIJA', @TriggeredBy = N'F7-251',
                  @Revalidate = @Revalidate, @Mode = @Mode;
                """);
            command.Parameters.AddWithValue("@Ids", $"[{productId}]");
            command.Parameters.AddWithValue("@Revalidate", revalidate);
            command.Parameters.AddWithValue("@Mode", mode);
            await using var reader = await command.ExecuteReaderAsync();
            var rows = new List<(long?, string?, bool)>();
            while (await reader.ReadAsync())
                rows.Add((reader.IsDBNull(0) ? null : reader.GetInt64(0),
                    reader.IsDBNull(reader.GetOrdinal("MissingFields")) ? null : reader.GetString(reader.GetOrdinal("MissingFields")),
                    reader.GetBoolean(reader.GetOrdinal("WasInactive"))));
            return rows;
        }

        // Vrne MissingFields zavrnjenih kljukic (drugi nabor pim.SaveProductWebShops).
        async Task<List<string>> SaveWebShopsAsync(string webShopCode)
        {
            await using var command = Command("""
                EXEC pim.SaveProductWebShops @OrganizationId = @OrgId, @ProductId = @ProductId, @ChangesJson = @Changes,
                  @Actor = N'F7-251', @Note = N'F7 251';
                """);
            command.Parameters.AddWithValue("@Changes", JsonSerializer.Serialize(new[] { new { webShopCode, isPublished = "1" } }));
            await using var reader = await command.ExecuteReaderAsync();
            while (await reader.ReadAsync()) { }
            var rejected = new List<string>();
            if (await reader.NextResultAsync())
                while (await reader.ReadAsync())
                    rejected.Add(reader.IsDBNull(reader.GetOrdinal("MissingFields")) ? "" : reader.GetString(reader.GetOrdinal("MissingFields")));
            return rejected;
        }

        // Šifra -> »Spletne strani« iz iste procedure, ki jo bere worker (iskanje po šifri).
        async Task<Dictionary<string, string>> ExportSitesAsync(string profileCode, bool sitesColumn = true)
        {
            await using var command = Command("""
                DECLARE @ProfileId int = (SELECT ExportProfileId FROM out.ExportProfile WHERE ProfileCode = @ProfileCode AND IsActive = 1);
                DECLARE @Total int;
                EXEC out.GetExportRows @OrganizationId = @OrgId, @ExportProfileId = @ProfileId, @OnlyPublished = 1,
                  @Search = @Item, @Take = 0, @TotalCount = @Total OUTPUT;
                """);
            command.Parameters.AddWithValue("@ProfileCode", profileCode);
            await using var reader = await command.ExecuteReaderAsync();
            var column = sitesColumn ? reader.GetOrdinal("Spletne strani") : -1;
            var result = new Dictionary<string, string>(StringComparer.Ordinal);
            while (await reader.ReadAsync())
                result[reader.IsDBNull(0) ? "" : reader.GetString(0)] = column < 0 || reader.IsDBNull(column) ? "" : reader.GetString(column);
            return result;
        }

        async Task Execute(string sql, params (string Name, object Value)[] parameters)
        {
            await using var command = Command(sql, parameters);
            await command.ExecuteNonQueryAsync();
        }

        async Task<object?> ScalarAsync(string sql, params (string Name, object Value)[] parameters)
        {
            await using var command = Command(sql, parameters);
            var value = await command.ExecuteScalarAsync();
            return value is DBNull ? null : value;
        }

        SqlCommand Command(string sql, params (string Name, object Value)[] parameters)
        {
            var command = new SqlCommand(sql, connection, transaction) { CommandTimeout = 600 };
            command.Parameters.Add("@OrgId", SqlDbType.Int).Value = organizationId;
            command.Parameters.Add("@ProductId", SqlDbType.BigInt).Value = productId;
            command.Parameters.Add("@Item", SqlDbType.NVarChar, 100).Value = itemId;
            foreach (var (name, value) in parameters) command.Parameters.AddWithValue(name, value);
            return command;
        }
    }

    static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException("F7 251 (katalog.csv in samodejni umik): " + message);
    }
}
