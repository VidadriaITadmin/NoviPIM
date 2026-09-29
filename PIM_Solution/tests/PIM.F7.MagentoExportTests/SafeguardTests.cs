using System.Data;
using System.Text;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using PIM.B2b;
using PIM.B2bWorker;

/// <summary>
/// 277 — varovalka katalog.csv, cene z decimalno vejico in ločilo podpičje.
///
/// Uporabnik 2026-09-23/24: »katalog ni dal vejice cenam in smo imeli napačne cene na svetilih«; »dej cenam vejico,
/// ločilo naj bo ; ne pa vejica« (brez narekovajev: 29,78, ne "29,78"); »če je cena 0, mora biti tudi varovalka«;
/// »opozorilo, če je polje s ceno prazno — in če se potrdi, je potem v redu«; »če ima en artikel prazno polje, se
/// ostali pojavijo v CSV, ta pa ne sme biti v CSV in mora čakati odobritev«. Varovalka ne ustavi procesa: sumljiv
/// artikel je zadržan (ga ni v datoteki), vsi ostali gredo ven.
///
/// Del nad bazo teče v eni transakciji in se na koncu razveljavi: preverjanja, ugotovitve, potrditve, opozorilo,
/// zahteva za zagon izvoza in izhodišče cen ne ostanejo v bazi.
/// </summary>
internal static class SafeguardTests
{
    public static async Task RunWithoutDatabaseAsync()
    {
        // Oblika: samo število v strojni obliki dobi vejico; vse drugo ostane, kot je (ujame ga varovalka).
        var price = new ExportColumnDefinition("P", "Cena B2C", "Product.PriceB2C", 1, false, true, DecimalSeparator: ",", GuardKind: "PRICE");
        var weight = new ExportColumnDefinition("W", "Teža [kg]", "Product.NetWeight", 2, false, true);
        Check(ExportValueFormat.Apply(price, "13.02") == "13,02", "cena 13.02 se zapiše kot 13,02");
        Check(ExportValueFormat.Apply(price, "1302") == "1302", "cela cena ostane brez ločila");
        Check(ExportValueFormat.Apply(price, "-0.5") == "-0,5", "negativna cena dobi vejico");
        Check(ExportValueFormat.Apply(price, null) is null && ExportValueFormat.Apply(price, "") == "", "prazna cena ostane prazna");
        Check(ExportValueFormat.Apply(price, "1.2.3") == "1.2.3" && ExportValueFormat.Apply(price, "abc") == "abc",
            "vrednost, ki ni število, ostane nespremenjena (ujame jo varovalka KAT_CENA_OBLIKA)");
        Check(ExportValueFormat.Apply(weight, "1.5") == "1.5", "stolpec brez DecimalSeparator ostane s piko");

        var directory = Path.Combine(Path.GetTempPath(), "f7-277-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            var item = new ExportColumnDefinition("I", "Šifra artikla", "Product.ItemID", 0, true, true);

            // Ločilo podpičje: cena z vejico brez narekovajev, teža s piko.
            var path = Path.Combine(directory, "katalog.csv");
            var records = new List<(string Item, long Offset, int Length)>();
            await RegistryCsvWriter.WriteAsync(path, [item, price, weight], Rows(), CancellationToken.None, ';',
                (row, offset, length) => records.Add((row[0]!, offset, length)));
            var lines = (await File.ReadAllTextAsync(path, Encoding.UTF8)).Split('\n', StringSplitOptions.RemoveEmptyEntries);
            Check(lines[0] == "Šifra artikla;Cena B2C;Teža [kg]", $"glava z ločilom ; (je: {lines[0]})");
            Check(lines[1] == "A-1;13,02;1.5", $"vrstica s ceno mora biti A-1;13,02;1.5 (je: {lines[1]})");
            Check(lines[2] == "A-2;1302;", $"cela cena, prazna teža prazna (je: {lines[2]})");
            Check(lines[3] == "A-3;\"x;y\";2", $"vrednost z ločilom je v narekovajih (je: {lines[3]})");

            // Zadržan artikel: datoteka se prepiše brez njegove vrstice, ostalo bajt za bajtom enako.
            var filtered = Path.Combine(directory, "katalog.izbor.csv");
            var copied = await RegistryCsvWriter.CopyWithoutAsync(path, filtered,
                records.Select(record => (record.Offset, record.Length)).ToList(), new HashSet<int> { 1 });
            var kept = await File.ReadAllTextAsync(filtered, Encoding.UTF8);
            Check(copied == 2 && kept == "Šifra artikla;Cena B2C;Teža [kg]\nA-1;13,02;1.5\nA-3;\"x;y\";2\n",
                $"brez zadržanega A-2 ostanejo glava, A-1 in A-3 (je: {kept.Replace("\n", "⏎")})");

            // Vejica kot ločilo (stranke.csv): vrednost z vejico v narekovajih kot doslej.
            var commaPath = Path.Combine(directory, "stranke.csv");
            await RegistryCsvWriter.WriteAsync(commaPath, [item, price, weight], Rows());
            var commaLines = (await File.ReadAllTextAsync(commaPath, Encoding.UTF8)).Split('\n', StringSplitOptions.RemoveEmptyEntries);
            Check(commaLines[1] == "A-1,\"13,02\",1.5", $"pri ločilu vejica je cena v narekovajih (je: {commaLines[1]})");
        }
        finally { Directory.Delete(directory, true); }

        // Zajem za varovalko: cene s piko (pred zapisom), po kanonični kodi stolpca.
        var captured = new List<MagentoExportCommand.PublishedRow>();
        var columns = new[]
        {
            new ExportColumnDefinition("C1", "Šifra artikla", "Product.ItemID", 1, true, true),
            new ExportColumnDefinition("C2", "Spletne strani", "Product.WebSites", 2, false, true),
            new ExportColumnDefinition("C3", "Cena B2C", "Product.PriceB2C", 3, false, true, ",", "PRICE"),
        };
        var passed = MagentoExportCommand.CapturePublication(CaptureRows(), columns, captured, CancellationToken.None).ToBlockingEnumerable().ToList();
        Check(passed.Count == 2 && captured.Count == 2, "zajem spusti vrstice skozi in si zapomni obe");
        Check(captured[0].Guarded?["Product.PriceB2C"] == "13.02", "zajeta cena je s piko (strojna oblika)");
        Check(captured[1].Guarded is { } empty && empty["Product.PriceB2C"] is null, "prazna cena je zajeta kot null");

        var json = CatalogSafeguard.RowsJson(captured);
        using var document = JsonDocument.Parse(json);
        var first = document.RootElement[0];
        Check(first.GetProperty("i").GetString() == "A-1" && first.GetProperty("s").GetString() == "svetila"
              && first.GetProperty("v").GetProperty("Product.PriceB2C").GetString() == "13.02",
            $"vrstica za varovalko ima i, s in v (je: {json})");
        Check(document.RootElement[1].GetProperty("s").GetString() == ""
              && document.RootElement[1].GetProperty("v").GetProperty("Product.PriceB2C").ValueKind == JsonValueKind.Null,
            "odjavna vrstica ima prazne spletne strani, prazna cena je null");

        var waiting = new CatalogSafeguardDecision(1, "WAITING", 3, 2, "zadržanih artiklov: 1 (cena 0: 1)", ["A-2"], null);
        Check(waiting.HeldItems.Count == 1 && waiting.Describe().Contains("niso v datoteki", StringComparison.Ordinal),
            $"WAITING našteje zadržane artikle (je: {waiting.Describe()})");
        Check(CatalogSafeguardDecision.NotRun("x").HeldItems.Count == 0, "varovalka, ki ni tekla, ne zadrži nobenega artikla");
        Console.WriteLine("F7 277: cene z decimalno vejico, ločilo ;, izpust zadržanih vrstic, zajem cen za varovalko PASS.");

        static async IAsyncEnumerable<IReadOnlyList<string?>> Rows()
        {
            yield return new string?[] { "A-1", "13.02", "1.5" };
            yield return new string?[] { "A-2", "1302", null };
            yield return new string?[] { "A-3", "x;y", "2" };
            await Task.CompletedTask;
        }

        static async IAsyncEnumerable<IReadOnlyList<string?>> CaptureRows()
        {
            yield return new string?[] { "A-1", "svetila", "13.02" };
            yield return new string?[] { "A-2", null, null };
            await Task.CompletedTask;
        }
    }

    /// <summary>Procedure 277 nad razvojno bazo — v transakciji, ki se razveljavi.</summary>
    public static async Task RunAsync(SqlConnection connection, int organizationId)
    {
        await using var transaction = (SqlTransaction)await connection.BeginTransactionAsync();
        try
        {
            // Šest objavljenih artiklov, ki gredo na svetila.
            var items = new List<string>();
            await using (var command = Command("""
                SELECT TOP (6) publication.ItemID
                FROM out.WebPublication AS publication
                JOIN canon.Product AS product ON product.OrganizationId = publication.OrganizationId AND product.ItemID = publication.ItemID
                JOIN pim.WebShopReason(@OrgId) AS reason
                  ON reason.ProductId = product.ProductId AND reason.WebShopCode = N'svetila_si' AND reason.ReasonCode = N'PUBLISHED'
                WHERE publication.OrganizationId = @OrgId AND publication.WithdrawnUtc IS NULL
                ORDER BY publication.ItemID;
                """))
            await using (var reader = await command.ExecuteReaderAsync())
                while (await reader.ReadAsync()) items.Add(reader.GetString(0));
            if (items.Count < 6)
            {
                Console.WriteLine("F7 277: razvojna baza nima šestih objavljenih artiklov za svetila — preizkus varovalke nad bazo preskočen.");
                return;
            }
            var (a, b, c, d, e, f) = (items[0], items[1], items[2], items[3], items[4], items[5]);

            // C odkljuka uporabnik: gre s spleta z razlogom »odkljukano«.
            await Execute("""
                UPDATE shop SET IsPublished = 0, ChangedBy = N'F7-277', ChangedUtc = SYSUTCDATETIME()
                FROM pim.ProductWebShop AS shop JOIN canon.Product AS product ON product.ProductId = shop.ProductId
                WHERE product.OrganizationId = @OrgId AND product.ItemID = @Item;
                DELETE out.CatalogPublishedValue WHERE OrganizationId = @OrgId;
                UPDATE ops.SafeguardCheck SET Status = N'SUPERSEDED' WHERE AreaCode = N'KATALOG_CSV' AND OrganizationId = @OrgId AND Status = N'WAITING';
                DELETE ops.SafeguardApproval WHERE AreaCode = N'KATALOG_CSV' AND OrganizationId = @OrgId;
                """, ("@Item", c));
            await Execute("""
                INSERT out.CatalogPublishedValue (OrganizationId, ItemID, FieldCode, Value, PublishedUtc) VALUES
                  (@OrgId, @A, N'Product.PriceB2C', N'13.02', SYSUTCDATETIME()),
                  (@OrgId, @B, N'Product.PriceB2C', N'20', SYSUTCDATETIME()),
                  (@OrgId, @D, N'Product.PriceB2C', N'15', SYSUTCDATETIME()),
                  (@OrgId, @E, N'Product.PriceB2C', N'20', SYSUTCDATETIME()),
                  (@OrgId, @F, N'Product.PriceB2C', N'9.9', SYSUTCDATETIME());
                """, ("@A", a), ("@B", b), ("@D", d), ("@E", e), ("@F", f));

            // Nova datoteka: vsi objavljeni, šest s spremembo — v isti obliki, kot jo pošlje worker.
            var rows = new List<MagentoExportCommand.PublishedRow>();
            await using (var command = Command("SELECT ItemID, WebSites FROM out.WebPublication WHERE OrganizationId = @OrgId AND WithdrawnUtc IS NULL;"))
            await using (var reader = await command.ExecuteReaderAsync())
                while (await reader.ReadAsync())
                {
                    var item = reader.GetString(0);
                    var price = item == a ? "1302" : item == b ? null : item == d ? "0" : item == e ? "30" : item == f ? "12,5" : "__BREZ__";
                    rows.Add(new(item, item == c ? null : reader.GetString(1),
                        price == "__BREZ__" ? null : new Dictionary<string, string?> { ["Product.PriceB2C"] = price }));
                }
            var json = CatalogSafeguard.RowsJson(rows);

            var first = await EvaluateAsync(json, rows.Count);
            Check(first.Status == "WAITING", $"cena ×100, prazna, 0, +50 % in neveljavna morajo zadržati artikle (je {first.Status})");
            Check(first.Held.SetEquals([a, b, d, e, f]),
                $"zadržani so natanko artikli s sumljivo ceno, ne vsa datoteka (je: {string.Join(", ", first.Held)})");
            var findings = await FindingsAsync(first.CheckId);
            Check(Has(findings, "KAT_CENA_VEJICA", a, "×100"), "1302 proti 13.02 je izgubljena vejica ×100");
            Check(Has(findings, "KAT_CENA_PRAZNA", b), "prazna cena, ki je prej bila 20, zadrži artikel");
            Check(Has(findings, "KAT_CENA_NIC", d), "cena 0 zadrži artikel");
            Check(Has(findings, "KAT_CENA_SKOK", e, "+50 %"), "20 → 30 je skok +50 %");
            Check(Has(findings, "KAT_CENA_OBLIKA", f), "»12,5« v strojni obliki ni število");
            Check(findings.Any(row => row.Rule == "KAT_SPLET_UMIK" && row.Item == c && row.Reason == "UNCHECKED" && !row.Confirm)
                  && !first.Held.Contains(c),
                "odkljukan artikel gre s spleta z razlogom UNCHECKED; en umik je pod pragom 10, zato samo opozorilo");
            Check(Convert.ToInt32(await Scalar("""
                SELECT COUNT(*) FROM ops.Alert WHERE OrganizationId = @OrgId AND AlertKind = N'SafeguardPending' AND Pipeline = N'VAROVALKA:KATALOG_CSV' AND ResolvedUtc IS NULL
                  AND Title LIKE N'katalog.csv: 5 artiklov čaka potrditev%';
                """)) == 1, "zadržani artikli odprejo eno opozorilo v zvoncu");

            var again = await EvaluateAsync(json, rows.Count);
            Check(again.CheckId == first.CheckId, "isti izvoz z istimi ugotovitvami osveži isto preverjanje, ne ustvari novega");

            // Delna potrditev: artikel A gre ven, ostali čakajo; stran ostane ista.
            var approvedA = await ApproveAsync(first.CheckId,
                JsonSerializer.Serialize((await FindingsAsync(first.CheckId)).Where(row => row.Item == a && row.Confirm).Select(row => row.Id)));
            Check(approvedA is { Approved: 1, Remaining: 4 }, $"potrditev A: 1 potrjena, 4 čakajo (je {approvedA})");
            var afterPartial = await EvaluateAsync(json, rows.Count);
            Check(afterPartial.CheckId == first.CheckId && afterPartial.Status == "WAITING" && afterPartial.Held.SetEquals([b, d, e, f]),
                $"po potrditvi A gre A ven, ostali ostanejo zadržani v istem preverjanju (je {afterPartial.Status}, {string.Join(", ", afterPartial.Held)})");

            // Potrditev vseh: preverjanje je potrjeno, opozorilo se zapre, naslednji izvoz ne zadrži nikogar.
            var approvedAll = await ApproveAsync(first.CheckId, null);
            Check(approvedAll is { Approved: 4, Remaining: 0 }, $"potrditev vseh: 4 potrjene, 0 čaka (je {approvedAll})");
            Check(Convert.ToString(await Scalar("SELECT Status FROM ops.SafeguardCheck WHERE SafeguardCheckId = @Check;", ("@Check", first.CheckId))) == "CONFIRMED",
                "ko so potrjeni vsi, je preverjanje CONFIRMED");
            Check(Convert.ToInt32(await Scalar(
                "SELECT COUNT(*) FROM ops.Alert WHERE OrganizationId = @OrgId AND AlertKind = N'SafeguardPending' AND Pipeline = N'VAROVALKA:KATALOG_CSV' AND ResolvedUtc IS NULL;")) == 0,
                "potrditev vseh zapre opozorilo");
            var confirmedRun = await EvaluateAsync(json, rows.Count);
            Check(confirmedRun.Status == "WARNED" && confirmedRun.ConfirmCount == 0 && confirmedRun.Held.Count == 0,
                $"po potrditvi iste ugotovitve ne zadržijo več (je {confirmedRun.Status}, zadržanih {confirmedRun.Held.Count})");

            await Execute("EXEC out.RecordCatalogPublication @OrganizationId = @OrgId, @RowsJson = @Rows, @SafeguardCheckId = @Check;",
                ("@Rows", json), ("@Check", confirmedRun.CheckId));
            Check(Convert.ToString(await Scalar(
                "SELECT Value FROM out.CatalogPublishedValue WHERE OrganizationId = @OrgId AND ItemID = @Item AND FieldCode = N'Product.PriceB2C';",
                ("@Item", a))) == "1302", "objava zamenja izhodišče cen");
            var afterPublish = await EvaluateAsync(json, rows.Count);
            var priceFindings = (await FindingsAsync(afterPublish.CheckId)).Count(row => row.Rule.StartsWith("KAT_CENA", StringComparison.Ordinal));
            Check(priceFindings == 0, $"objavljene cene se naslednjič ne primerjajo več kot sprememba (je {priceFindings} cenovnih ugotovitev)");

            // Nova napaka po potrditvi se spet ujame — zadržan je samo ta artikel.
            var brokenRows = rows.Select(row => row.ItemId == e
                ? row with { Guarded = new Dictionary<string, string?> { ["Product.PriceB2C"] = "3" } } : row).ToList();
            var afterBreak = await EvaluateAsync(CatalogSafeguard.RowsJson(brokenRows), rows.Count);
            Check(afterBreak.Status == "WAITING" && afterBreak.Held.SetEquals([e]) && Has(await FindingsAsync(afterBreak.CheckId), "KAT_CENA_VEJICA", e, "÷10"),
                "cena 30 → 3 po objavi je nova ugotovitev ÷10 in zadrži samo ta artikel");

            // Objava brez zadržanega: izhodišče in stanje na spletu zadržanega ostaneta, kot sta bila.
            await Execute("EXEC out.RecordCatalogPublication @OrganizationId = @OrgId, @RowsJson = @Rows, @SafeguardCheckId = @Check, @HeldItemsJson = @Held;",
                ("@Rows", CatalogSafeguard.RowsJson(brokenRows.Where(row => row.ItemId != e))), ("@Check", afterBreak.CheckId),
                ("@Held", JsonSerializer.Serialize(new[] { e })));
            Check(Convert.ToString(await Scalar(
                "SELECT Value FROM out.CatalogPublishedValue WHERE OrganizationId = @OrgId AND ItemID = @Item AND FieldCode = N'Product.PriceB2C';",
                ("@Item", e))) == "30", "zadržan artikel obdrži izhodišče zadnje objave (30), ne napačne cene");
            Check(await Scalar("SELECT WithdrawnUtc FROM out.WebPublication WHERE OrganizationId = @OrgId AND ItemID = @Item;", ("@Item", e)) is null,
                "zadržan artikel ni zabeležen kot umaknjen s spleta — v datoteki ga ni, a na spletu ostane");

            Console.WriteLine($"F7 277: varovalka katalog.csv (zadržani artikli, delna in polna potrditev, objava brez zadržanih) nad podjetjem {organizationId} PASS.");
        }
        finally
        {
            await transaction.RollbackAsync();
        }

        async Task<(long CheckId, string Status, int ConfirmCount, HashSet<string> Held)> EvaluateAsync(string rowsJson, int rowCount)
        {
            await using var command = Command("EXEC ops.EvaluateCatalogSafeguards @OrganizationId = @OrgId, @RowsJson = @Rows, @RowCount = @Count, @Actor = N'F7-277';",
                ("@Rows", rowsJson), ("@Count", rowCount));
            await using var reader = await command.ExecuteReaderAsync();
            if (!await reader.ReadAsync()) throw new InvalidOperationException("F7 277: varovalka ni vrnila izida.");
            var result = (reader.GetInt64(0), reader.GetString(1), reader.GetInt32(3), new HashSet<string>(StringComparer.Ordinal));
            if (await reader.NextResultAsync())
                while (await reader.ReadAsync()) result.Item4.Add(reader.GetString(0));
            return result;
        }

        async Task<(int Approved, int Remaining)> ApproveAsync(long checkId, string? findingIdsJson)
        {
            await using var command = Command(
                "EXEC ops.ApproveSafeguardFindings @SafeguardCheckId = @Check, @FindingIdsJson = @Ids, @Actor = N'F7-277', @Note = N'preizkus';",
                ("@Check", checkId), ("@Ids", (object?)findingIdsJson ?? DBNull.Value));
            await using var reader = await command.ExecuteReaderAsync();
            if (!await reader.ReadAsync()) throw new InvalidOperationException("F7 277: potrditev ni vrnila izida.");
            return (reader.GetInt32(0), reader.GetInt32(1));
        }

        async Task<List<(long Id, string Rule, string? Item, string? Change, string? Reason, bool Confirm)>> FindingsAsync(long checkId)
        {
            await using var command = Command(
                "SELECT SafeguardFindingId, RuleCode, ItemID, ChangeText, ReasonCode, RequiresConfirmation FROM ops.SafeguardFinding WHERE SafeguardCheckId = @Check;",
                ("@Check", checkId));
            await using var reader = await command.ExecuteReaderAsync();
            var result = new List<(long, string, string?, string?, string?, bool)>();
            while (await reader.ReadAsync())
                result.Add((reader.GetInt64(0), reader.GetString(1), reader.IsDBNull(2) ? null : reader.GetString(2),
                    reader.IsDBNull(3) ? null : reader.GetString(3), reader.IsDBNull(4) ? null : reader.GetString(4), reader.GetBoolean(5)));
            return result;
        }

        static bool Has(List<(long Id, string Rule, string? Item, string? Change, string? Reason, bool Confirm)> findings, string rule, string item, string? change = null) =>
            findings.Any(row => row.Rule == rule && row.Item == item && row.Confirm && (change is null || row.Change == change));

        async Task Execute(string sql, params (string Name, object Value)[] parameters)
        {
            await using var command = Command(sql, parameters);
            await command.ExecuteNonQueryAsync();
        }

        async Task<object?> Scalar(string sql, params (string Name, object Value)[] parameters)
        {
            await using var command = Command(sql, parameters);
            var value = await command.ExecuteScalarAsync();
            return value is DBNull ? null : value;
        }

        SqlCommand Command(string sql, params (string Name, object Value)[] parameters)
        {
            var command = new SqlCommand(sql, connection, transaction) { CommandTimeout = 600 };
            command.Parameters.Add("@OrgId", SqlDbType.Int).Value = organizationId;
            foreach (var (name, value) in parameters) command.Parameters.AddWithValue(name, value);
            return command;
        }
    }

    static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException("F7 277 (varovalka katalog.csv): " + message);
    }
}
