using System.Globalization;
using System.Runtime.CompilerServices;
using Microsoft.Data.SqlClient;
using PIM.B2b;

[assembly: InternalsVisibleTo("PIM.F7.MagentoExportTests")]

namespace PIM.B2bWorker;

public static class MagentoExportCommand
{
    // Oblika datoteke (kateri stolpci, v kakšnem vrstnem redu, s katero glavo in iz katere
    // kanonične vrednosti) pride od klicatelja, ki jo prebere iz registra out.ExportColumn.
    // Prej jo je sestavljal switch v MagentoProductSchema; zato je bil nov spletni kanal
    // sprememba programa in ne vrstica v bazi.
    public static Task WriteProductCsvAsync(string path, IReadOnlyList<ExportColumnDefinition> columns, IEnumerable<IReadOnlyDictionary<string, string?>> rows, CancellationToken ct = default)
        => CustomerCsvGenerator.WriteAsync(path, columns, rows, ct);

    public static Task WriteCustomerCsvAsync(string path, IReadOnlyList<ExportColumnDefinition> columns, IEnumerable<IReadOnlyDictionary<string, string?>> rows, CancellationToken ct = default)
        => CustomerCsvGenerator.WriteAsync(path, columns, rows, ct);

    public static async Task ExecuteAsync(int organizationId, string outputDir, string connectionString, CancellationToken ct = default)
    {
        if (organizationId <= 0) throw new ArgumentOutOfRangeException(nameof(organizationId), "OrganizationId mora biti pozitivno celo število.");
        ArgumentException.ThrowIfNullOrWhiteSpace(outputDir, nameof(outputDir));
        if (string.IsNullOrWhiteSpace(connectionString))
            throw new InvalidOperationException("Manjka PIM_CONNECTION_STRING. Nastavite okoljsko spremenljivko PIM_CONNECTION_STRING.");

        Directory.CreateDirectory(outputDir);

        await using var connection = new SqlConnection(connectionString);
        await connection.OpenAsync(ct);

        // Datoteki sta par in ju Magento uvozi skupaj. Zato najprej preberemo oba nabora in
        // ju zapisemo ob stran, sele nato prestavimo na koncni imeni. Ce pade poizvedba za
        // stranke ali pisanje druge datoteke, v izhodni mapi ne nastane nov magento-products.csv
        // poleg stare ali manjkajoce magento-customers.csv - torej ni polovicnega izvoza.
        // Obliko preberemo pred podatki: manjkajoč ali izklopljen profil je napaka
        // konfiguracije in mora pasti, preden se karkoli zapiše v izhodno mapo.
        var productColumns = await ExportProfileRegistry.LoadColumnsAsync(connection, MagentoProductSchema.ProfileCode, ct);
        var customerColumns = await ExportProfileRegistry.LoadColumnsAsync(connection, MagentoCustomerSchema.ProfileCode, ct);

        var productRows = await LoadProductRowsAsync(connection, organizationId, ct);
        var customerRows = await LoadCustomerRowsAsync(connection, organizationId, ct);

        var productPath = Path.Combine(outputDir, "magento-products.csv");
        var customerPath = Path.Combine(outputDir, "magento-customers.csv");

        // Zacasna in varnostna imena so enolicna za posamezen zagon. Dva socasna zagona v isto
        // mapo bi si sicer povozila .tmp in .prej: eden bi pobrisal drugemu varnostno kopijo ali
        // pa bi nastal par, sestavljen iz dveh razlicnih zagonov.
        var runId = Guid.NewGuid().ToString("N")[..8];
        var productTempPath = $"{productPath}.{runId}.tmp";
        var customerTempPath = $"{customerPath}.{runId}.tmp";
        var productBackupPath = $"{productPath}.{runId}.prej";
        var customerBackupPath = $"{customerPath}.{runId}.prej";
        var completeMarkerPath = Path.Combine(outputDir, "magento-export.complete");
        var markerBackupPath = $"{completeMarkerPath}.{runId}.prej";

        // Enolicna imena preprecijo trk datotek, ne pa prepletanja same zamenjave. Zato je
        // zamenjava se pod kljucavnico na izhodni mapi: drugi zagon raje pade z jasnim
        // sporocilom, kot da objavi par iz dveh zagonov.
        using var directoryLock = MagentoExportLock.Acquire(outputDir);
        var markerBackedUp = false;
        var productBackedUp = false;
        var customerBackedUp = false;
        var productReplaced = false;
        var replacementSucceeded = false;

        try
        {
            await WriteProductCsvAsync(productTempPath, productColumns, productRows, ct);
            await WriteCustomerCsvAsync(customerTempPath, customerColumns, customerRows, ct);

            // Vse premikanje datotek je znotraj ENEGA try: tudi odmik prejsnjega para.
            // Ce bi bil odmik zunaj, bi neuspesen odmik datoteke strank (na primer ker je
            // zaklenjena) pustil izdelcno datoteko odmaknjeno v .prej, zunanji finally pa bi
            // jo pobrisal — in prejsnji veljavni izvoz izdelkov bi bil trajno izgubljen.
            try
            {
                // Oznaka dokoncanosti izgine PRED zamenjavo in nastane sele po njej. Med tem par
                // ni popoln — dve preimenovanji na datotecnem sistemu nista ena atomarna operacija
                // in bralec bi lahko videl nov izvoz izdelkov ob stari datoteki strank. Porabnik
                // zato bere sele, ko oznaka obstaja. Odmaknemo jo, ne pobrisemo: ce zamenjava pade
                // in se prejsnji par vrne, mora oznaka spet veljati zanj.
                if (File.Exists(completeMarkerPath)) { File.Move(completeMarkerPath, markerBackupPath, overwrite: true); markerBackedUp = true; }

                if (File.Exists(productPath)) { File.Move(productPath, productBackupPath, overwrite: true); productBackedUp = true; }
                if (File.Exists(customerPath)) { File.Move(customerPath, customerBackupPath, overwrite: true); customerBackedUp = true; }

                File.Move(productTempPath, productPath, overwrite: true);
                productReplaced = true;
                File.Move(customerTempPath, customerPath, overwrite: true);
                replacementSucceeded = true;

                // Par je popoln. Sele zdaj sme porabnik brati.
                await File.WriteAllTextAsync(
                    completeMarkerPath,
                    $"{runId}\n{DateTime.UtcNow:O}\nizdelki={productRows.Count}\nstranke={customerRows.Count}\n",
                    ct);
            }
            catch
            {
                // Vrnemo prejsnje stanje v celoti; raje star veljaven par kot nov polovicen.
                // Napake pri vracanju ne smejo prekriti prvotne — ta pove, kaj je res slo narobe.
                TryRestore(() => { if (productReplaced) DeleteIfExists(productPath); });
                TryRestore(() => { if (productBackedUp) File.Move(productBackupPath, productPath, overwrite: true); });
                TryRestore(() => { if (customerBackedUp) File.Move(customerBackupPath, customerPath, overwrite: true); });
                TryRestore(() => { if (markerBackedUp) File.Move(markerBackupPath, completeMarkerPath, overwrite: true); });
                throw;
            }
        }
        finally
        {
            DeleteIfExists(productTempPath);
            DeleteIfExists(customerTempPath);

            // Varnostni kopiji brisemo SAMO po popolnoma uspesni zamenjavi. Ce je zamenjava
            // padla, je uspesen povratek datoteki ze prestavil nazaj in tu ni kaj brisati;
            // ce pa je padel tudi povratek, je .prej zadnja veljavna kopija izvoza. Prejsnja
            // razlicica jih je brisala brezpogojno in bi jo v tem primeru unicila.
            if (replacementSucceeded)
            {
                DeleteIfExists(productBackupPath);
                DeleteIfExists(customerBackupPath);
                DeleteIfExists(markerBackupPath);
            }
        }
    }

    /// <summary>Korak vracanja v prejsnje stanje, ki ne sme prekriti prvotne izjeme.</summary>
    private static void TryRestore(Action step)
    {
        try { step(); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    /// <summary>Odstrani zacasno datoteko, ce je se ostala. Napake pri ciscenju ne skrijejo prvotne.</summary>
    private static void DeleteIfExists(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private static async Task<List<Dictionary<string, string?>>> LoadProductRowsAsync(SqlConnection connection, int organizationId, CancellationToken ct)
    {
        var products = new Dictionary<string, Dictionary<string, string?>>(StringComparer.Ordinal);

        await using (var cmd = new SqlCommand("""
            SELECT
                p.ItemID,
                p.EAN,
                p.Name,
                p.Manufacturer,
                p.Supplier,
                p.UoM,
                pc.CustomsTariff,
                pc.CountryOfOrigin,
                CONVERT(nvarchar(50), pc.GrossWeight) AS GrossWeight,
                CONVERT(nvarchar(50), pc.NetWeight) AS NetWeight,
                CONVERT(nvarchar(50), pc.Pak1) AS Pak1,
                CONVERT(nvarchar(50), pc.Pak2) AS Pak2,
                CONVERT(nvarchar(50), pc.Volume) AS Volume,
                CONVERT(nvarchar(50), pc.PackageLength) AS PackageLength,
                CONVERT(nvarchar(50), pc.PackageWidth) AS PackageWidth,
                CONVERT(nvarchar(50), pc.PackageHeight) AS PackageHeight,
                pc.DimensionUnit,
                ppd.DiscountCode AS PackagingDiscountCode,
                CONVERT(nvarchar(50), pdc.PercentValue) AS PackagingDiscountPercent,
                prb2b.Net AS PriceB2B,
                prb2c.Net AS PriceB2C,
                COALESCE(prb2b.VatRate, prb2c.VatRate, prany.VatRate) AS VatRate
            FROM pim.Product p
            LEFT JOIN pim.ProductCommercial pc ON pc.PimProductId = p.PimProductId
            LEFT JOIN pim.ProductPackagingDiscount ppd ON ppd.PimProductId = p.PimProductId
            -- IsActive = 1: izklopljena akcija v katalogu se ne sme izvoziti kot veljaven popust.
            LEFT JOIN pim.PackagingDiscountCatalog pdc ON pdc.DiscountCode = ppd.DiscountCode AND pdc.IsActive = 1
            LEFT JOIN (
                -- ValidFrom <= zdaj: brez tega bi ORDER BY ValidFrom DESC izbral vnaprej
                -- pripravljeno ceno in bi se ta pojavila v Magentu, preden zacne veljati.
                SELECT PimProductId, CONVERT(nvarchar(50), Net) Net, CONVERT(nvarchar(10), VatRate) VatRate,
                    ROW_NUMBER() OVER(PARTITION BY PimProductId ORDER BY ValidFrom DESC) rn
                FROM pim.ProductPrice WHERE PriceList = N'B2B' AND IsActive = 1 AND ValidFrom <= SYSUTCDATETIME()
            ) prb2b ON prb2b.PimProductId = p.PimProductId AND prb2b.rn = 1
            LEFT JOIN (
                -- VatRate je tu obvezen: zunanja projekcija bere prb2c.VatRate v COALESCE.
                -- Brez njega se poizvedba ne prevede ("Invalid column name 'VatRate'") in
                -- ukaz --export-magento ne more zajeti niti ene vrstice.
                SELECT PimProductId, CONVERT(nvarchar(50), Net) Net, CONVERT(nvarchar(10), VatRate) VatRate,
                    ROW_NUMBER() OVER(PARTITION BY PimProductId ORDER BY ValidFrom DESC) rn
                FROM pim.ProductPrice WHERE PriceList = N'B2C' AND IsActive = 1 AND ValidFrom <= SYSUTCDATETIME()
            ) prb2c ON prb2c.PimProductId = p.PimProductId AND prb2c.rn = 1
            LEFT JOIN (
                SELECT PimProductId, CONVERT(nvarchar(10), VatRate) VatRate,
                    ROW_NUMBER() OVER(PARTITION BY PimProductId ORDER BY ValidFrom DESC) rn
                FROM pim.ProductPrice WHERE IsActive = 1 AND ValidFrom <= SYSUTCDATETIME()
            ) prany ON prany.PimProductId = p.PimProductId AND prany.rn = 1
            WHERE p.OrganizationId = @OrgId
            ORDER BY p.ItemID;
            """, connection) { CommandTimeout = 120 })
        {
            cmd.Parameters.AddWithValue("@OrgId", organizationId);
            await using var reader = await cmd.ExecuteReaderAsync(ct);
            while (await reader.ReadAsync(ct))
            {
                var itemId = reader["ItemID"] as string ?? "";
                var row = new Dictionary<string, string?>(StringComparer.Ordinal)
                {
                    ["Product.ItemID"] = itemId,
                    ["Product.EAN"] = reader["EAN"] as string,
                    // pim.Product.Name je ERP naziv artikla. V spletni stolpec ne gre: ERP naziv in
                    // spletni naziv sta razlicna (odlocitev uporabnika 2026-08-23). Stolpca 'Naziv
                    // artikla' in 'Naziv artikla EN' polni izkljucno WEB_TITLE.
                    ["Product.ErpTitleSl"] = reader["Name"] as string,
                    ["Product.Manufacturer"] = reader["Manufacturer"] as string,
                    // Dobavitelj in merska enota sta v katalogu od prvega zajema; do migracije 077
                    // ju objava ni nesla naprej, zato sta bila stolpca prazna.
                    ["Product.Supplier"] = reader["Supplier"] as string,
                    ["Product.UoM"] = reader["UoM"] as string,
                    ["Product.CustomsTariff"] = reader["CustomsTariff"] as string,
                    ["Product.CountryOfOrigin"] = reader["CountryOfOrigin"] as string,
                    ["Product.GrossWeight"] = FormatDecimalString(reader["GrossWeight"]),
                    ["Product.NetWeight"] = FormatDecimalString(reader["NetWeight"]),
                    ["Product.Pak1"] = FormatDecimalString(reader["Pak1"]),
                    ["Product.Pak2"] = FormatDecimalString(reader["Pak2"]),
                    // Mere in volumen pakiranja: v katalogu so od migracije 057, stolpci predloge
                    // pa so vir dobili v 074. Enota je ena sama za vse tri dimenzije, tako jo
                    // poslje SAOP (PropertiesData/ItemDimensionUOM).
                    ["Product.Volume"] = FormatDecimalString(reader["Volume"]),
                    ["Product.PackageLength"] = FormatDecimalString(reader["PackageLength"]),
                    ["Product.PackageWidth"] = FormatDecimalString(reader["PackageWidth"]),
                    ["Product.PackageHeight"] = FormatDecimalString(reader["PackageHeight"]),
                    ["Product.DimensionUnit"] = reader["DimensionUnit"] as string,
                    ["Product.PackagingDiscountCode"] = reader["PackagingDiscountCode"] as string,
                    ["Product.PackagingDiscountPercent"] = FormatDecimalString(reader["PackagingDiscountPercent"]),
                    ["Product.PriceB2B"] = FormatDecimalString(reader["PriceB2B"]),
                    ["Product.PriceB2C"] = FormatDecimalString(reader["PriceB2C"]),
                    ["Product.VatRate"] = FormatDecimalString(reader["VatRate"]),
                };
                products[itemId] = row;
            }
        }

        await using (var cmd = new SqlCommand("""
            SELECT p.ItemID, pt.Lang, pt.TextType, pt.Value
            FROM pim.Product p
            JOIN pim.ProductText pt ON pt.PimProductId = p.PimProductId
            WHERE p.OrganizationId = @OrgId;
            """, connection) { CommandTimeout = 120 })
        {
            cmd.Parameters.AddWithValue("@OrgId", organizationId);
            await using var reader = await cmd.ExecuteReaderAsync(ct);
            while (await reader.ReadAsync(ct))
            {
                var itemId = reader["ItemID"] as string ?? "";
                if (!products.TryGetValue(itemId, out var row)) continue;
                var lang = reader["Lang"] as string ?? "";
                var textType = reader["TextType"] as string ?? "";
                var value = reader["Value"] as string;
                // Spletni naziv in ERP naziv sta razlicna (odlocitev uporabnika 2026-08-23), zato
                // ERP naziv v spletni stolpec ne gre niti takrat, ko spletnega ni. Prazen stolpec
                // pove resnico: spletnega naziva za ta izdelek se ni.
                if (textType == "WEB_TITLE" && lang == "en") row["Product.WebTitleEn"] = value;
                if (textType == "WEB_TITLE" && lang == "sl") row["Product.WebTitleSl"] = value;
                if (textType == "TITLE_ERP" && lang == "en") row["Product.ErpTitleEn"] = value;
            }
        }

        await using (var cmd = new SqlCommand("""
            SELECT p.ItemID, pm.Role, pm.Url, pm.SortOrder
            FROM pim.Product p
            JOIN pim.ProductMedia pm ON pm.PimProductId = p.PimProductId
            WHERE p.OrganizationId = @OrgId
            ORDER BY p.ItemID, pm.SortOrder, pm.PimProductMediaId;
            """, connection) { CommandTimeout = 120 })
        {
            cmd.Parameters.AddWithValue("@OrgId", organizationId);
            await using var reader = await cmd.ExecuteReaderAsync(ct);
            var others = new Dictionary<string, List<string>>(StringComparer.Ordinal);
            while (await reader.ReadAsync(ct))
            {
                var itemId = reader["ItemID"] as string ?? "";
                if (!products.TryGetValue(itemId, out var row)) continue;
                var role = reader["Role"] as string ?? "";
                var url = reader["Url"] as string ?? "";

                // Prva slika po SortOrder z glavno vlogo je glavna, vse ostale so dodatne.
                // Vrstni red je SortOrder in ne Role: prej je bil ORDER BY Role, kar bi ob
                // vec glavnih slikah izbralo abecedno prvo vlogo namesto najnizjega SortOrder.
                if (IsPrimaryMediaRole(role) && !row.ContainsKey("Product.MainImage"))
                {
                    row["Product.MainImage"] = url;
                    continue;
                }

                if (!others.TryGetValue(itemId, out var list)) { list = []; others[itemId] = list; }
                list.Add(url);
            }
            foreach (var (itemId, list) in others)
                if (products.TryGetValue(itemId, out var row))
                    row["Product.OtherImages"] = string.Join('|', list);
        }

        // Register spletnih strani: koda strani -> kanonicna koda stolpca izvoza.
        var siteFieldCodes = new Dictionary<string, string>(StringComparer.Ordinal);
        await using (var cmd = new SqlCommand(
            "SELECT WebSiteCode, CategoryFieldCode FROM canon.WebSite WHERE IsActive = 1;",
            connection) { CommandTimeout = 60 })
        {
            await using var reader = await cmd.ExecuteReaderAsync(ct);
            while (await reader.ReadAsync(ct))
                siteFieldCodes[reader.GetString(0)] = reader.GetString(1);
        }

        await using (var cmd = new SqlCommand("""
            SELECT p.ItemID, pc.WebSite, pc.CategoryPath
            FROM pim.Product p
            JOIN pim.ProductCategory pc ON pc.PimProductId = p.PimProductId
            WHERE p.OrganizationId = @OrgId
            ORDER BY p.ItemID, pc.WebSite, pc.CategoryPath;
            """, connection) { CommandTimeout = 120 })
        {
            cmd.Parameters.AddWithValue("@OrgId", organizationId);
            await using var reader = await cmd.ExecuteReaderAsync(ct);
            var sites = new Dictionary<string, List<string>>(StringComparer.Ordinal);
            // Katera spletna stran gre v kateri stolpec, pove register canon.WebSite, ne koda.
            // Prej je bilo to stikalo v C# ("B2C" => SLO, "B2C_EN" => ANG) in nova stran je
            // pomenila novo razlicico programa; zdaj je vrstica v bazi.
            var byField = new Dictionary<string, Dictionary<string, List<string>>>(StringComparer.Ordinal);
            while (await reader.ReadAsync(ct))
            {
                var itemId = reader["ItemID"] as string ?? "";
                var site = reader["WebSite"] as string ?? "";
                if (!sites.TryGetValue(itemId, out var list)) { list = []; sites[itemId] = list; }
                if (!list.Contains(site, StringComparer.Ordinal)) list.Add(site);

                if (!siteFieldCodes.TryGetValue(site, out var fieldCode)) continue;

                var path = reader["CategoryPath"] as string ?? "";
                if (path.Length == 0) continue;
                if (!byField.TryGetValue(fieldCode, out var target))
                {
                    target = new Dictionary<string, List<string>>(StringComparer.Ordinal);
                    byField[fieldCode] = target;
                }
                if (!target.TryGetValue(itemId, out var paths)) { paths = []; target[itemId] = paths; }
                if (!paths.Contains(path, StringComparer.Ordinal)) paths.Add(path);
            }

            foreach (var (itemId, list) in sites)
                if (products.TryGetValue(itemId, out var row))
                    row["Product.WebSites"] = string.Join('|', list);
            foreach (var (fieldCode, perProduct) in byField)
                foreach (var (itemId, paths) in perProduct)
                    if (products.TryGetValue(itemId, out var row))
                        row[fieldCode] = string.Join('|', paths);
        }

        await using (var cmd = new SqlCommand("""
            SELECT p.ItemID, pa.AttributeCode, pa.Value
            FROM pim.Product p
            JOIN pim.ProductAttribute pa ON pa.PimProductId = p.PimProductId
            WHERE p.OrganizationId = @OrgId;
            """, connection) { CommandTimeout = 120 })
        {
            cmd.Parameters.AddWithValue("@OrgId", organizationId);
            await using var reader = await cmd.ExecuteReaderAsync(ct);
            while (await reader.ReadAsync(ct))
            {
                var itemId = reader["ItemID"] as string ?? "";
                if (!products.TryGetValue(itemId, out var row)) continue;
                var attrCode = reader["AttributeCode"] as string ?? "";
                var value = reader["Value"] as string;
                row["Attr." + attrCode] = value;
            }
        }

        return products.Values.OrderBy(r => r.TryGetValue("Product.ItemID", out var id) ? id : "").ToList();
    }

    private static async Task<List<Dictionary<string, string?>>> LoadCustomerRowsAsync(SqlConnection connection, int organizationId, CancellationToken ct)
    {
        var customers = new Dictionary<string, Dictionary<string, string?>>(StringComparer.Ordinal);

        await using (var cmd = new SqlCommand("""
            SELECT
                c.CustomerKey,
                c.Name,
                g.MagentoGroupKey,
                c.PriceListCode,
                c.PayerCode,
                c.PayerName,
                CONVERT(bit, p.PackagingDiscountEnabled) AS PackDisc,
                CONVERT(bit, p.ValueDiscountEnabled) AS ValDisc,
                CONVERT(bit, CASE WHEN p.B2bPlusEnabled = 1
                    AND (p.B2bPlusValidFrom IS NULL OR p.B2bPlusValidFrom <= CONVERT(date, SYSUTCDATETIME()))
                    AND (p.B2bPlusValidTo   IS NULL OR p.B2bPlusValidTo   >= CONVERT(date, SYSUTCDATETIME()))
                    THEN 1 ELSE 0 END) AS B2bPlus,
                COALESCE(t1.ThresholdGrossExVat, d1.ThresholdGrossExVat) AS T1Thr,
                COALESCE(t1.PercentValue, d1.PercentValue) AS T1Pct,
                COALESCE(t2.ThresholdGrossExVat, d2.ThresholdGrossExVat) AS T2Thr,
                COALESCE(t2.PercentValue, d2.PercentValue) AS T2Pct,
                COALESCE(t3.ThresholdGrossExVat, d3.ThresholdGrossExVat) AS T3Thr,
                COALESCE(t3.PercentValue, d3.PercentValue) AS T3Pct
            FROM b2b.Customer c
            JOIN pim.CustomerWebProfile p ON p.CustomerId = c.CustomerId
            LEFT JOIN pim.CustomerTypeMagentoGroup g ON g.CustomerTypeCode = p.CustomerTypeCode
            -- IsActive = 1 je obvezen: brez njega bi izklopljen override stranke povozil
            -- privzeti prag iz pim.ValueDiscountTier in izvozili bi zastarel rabat.
            -- Podvojitve vrstic ni — PK je (CustomerId, TierNumber) — gre izkljucno za to,
            -- ali se COALESCE pravilno vrne na privzeto vrednost.
            LEFT JOIN pim.CustomerValueDiscountTier t1 ON t1.CustomerId = c.CustomerId AND t1.TierNumber = 1 AND t1.IsActive = 1
            LEFT JOIN pim.CustomerValueDiscountTier t2 ON t2.CustomerId = c.CustomerId AND t2.TierNumber = 2 AND t2.IsActive = 1
            LEFT JOIN pim.CustomerValueDiscountTier t3 ON t3.CustomerId = c.CustomerId AND t3.TierNumber = 3 AND t3.IsActive = 1
            LEFT JOIN pim.ValueDiscountTier d1 ON d1.TierNumber = 1 AND d1.IsActive = 1
            LEFT JOIN pim.ValueDiscountTier d2 ON d2.TierNumber = 2 AND d2.IsActive = 1
            LEFT JOIN pim.ValueDiscountTier d3 ON d3.TierNumber = 3 AND d3.IsActive = 1
            WHERE c.OrganizationId = @OrgId AND p.WebEnabled = 1
            ORDER BY c.CustomerKey;
            """, connection) { CommandTimeout = 120 })
        {
            cmd.Parameters.AddWithValue("@OrgId", organizationId);
            await using var reader = await cmd.ExecuteReaderAsync(ct);
            while (await reader.ReadAsync(ct))
            {
                var key = reader["CustomerKey"] as string ?? "";
                var payerCode = reader["PayerCode"] as string ?? "";
                var payerName = reader["PayerName"] as string ?? "";
                var payer = (payerCode.Length > 0 || payerName.Length > 0)
                    ? $"{payerCode}|{payerName}"
                    : null;
                customers[key] = new Dictionary<string, string?>(StringComparer.Ordinal)
                {
                    ["Customer.Key"] = key,
                    ["Customer.Name"] = reader["Name"] as string,
                    ["Customer.MagentoGroup"] = reader["MagentoGroupKey"] as string,
                    ["Customer.PriceList"] = reader["PriceListCode"] as string,
                    ["Customer.Payer"] = payer,
                    ["Customer.PackagingDiscountEnabled"] = reader["PackDisc"] is bool pd ? (pd ? "1" : "0") : null,
                    ["Customer.ValueDiscountEnabled"] = reader["ValDisc"] is bool vd ? (vd ? "1" : "0") : null,
                    ["Customer.B2bPlus"] = reader["B2bPlus"] is bool bp ? (bp ? "1" : "0") : null,
                    ["Customer.Tier1Threshold"] = FormatDecimalString(reader["T1Thr"]),
                    ["Customer.Tier1Percent"] = FormatDecimalString(reader["T1Pct"]),
                    ["Customer.Tier2Threshold"] = FormatDecimalString(reader["T2Thr"]),
                    ["Customer.Tier2Percent"] = FormatDecimalString(reader["T2Pct"]),
                    ["Customer.Tier3Threshold"] = FormatDecimalString(reader["T3Thr"]),
                    ["Customer.Tier3Percent"] = FormatDecimalString(reader["T3Pct"]),
                };
            }
        }

        await using (var cmd = new SqlCommand("""
            SELECT c.CustomerKey, gd.ItemGroupCode, gd.PercentValue
            FROM b2b.Customer c
            JOIN b2b.GroupDiscount gd ON gd.CustomerId = c.CustomerId
            JOIN pim.CustomerWebProfile p ON p.CustomerId = c.CustomerId
            WHERE c.OrganizationId = @OrgId AND p.WebEnabled = 1
              -- Veljavnostno okno: potekel ali sele prihodnji rabat ne sme v izvoz.
              -- NULL pomeni "brez omejitve" na tisti strani. Isto pravilo uporablja
              -- out.ExportB2bCustomersCsv oziroma MagentoExportRunner.
              AND (gd.ValidFrom IS NULL OR gd.ValidFrom <= CONVERT(date, SYSUTCDATETIME()))
              AND (gd.ValidTo IS NULL OR gd.ValidTo >= CONVERT(date, SYSUTCDATETIME()))
            ORDER BY c.CustomerKey, gd.ItemGroupCode;
            """, connection) { CommandTimeout = 120 })
        {
            cmd.Parameters.AddWithValue("@OrgId", organizationId);
            await using var reader = await cmd.ExecuteReaderAsync(ct);
            var discountsByCustomer = new Dictionary<string, List<(string Code, string Pct)>>(StringComparer.Ordinal);
            while (await reader.ReadAsync(ct))
            {
                var key = reader["CustomerKey"] as string ?? "";
                var code = reader["ItemGroupCode"] as string ?? "";
                var pct = FormatDecimalString(reader["PercentValue"]) ?? "";
                if (!discountsByCustomer.TryGetValue(key, out var list)) { list = []; discountsByCustomer[key] = list; }
                list.Add((code, pct));
            }
            foreach (var (key, discounts) in discountsByCustomer)
            {
                if (!customers.TryGetValue(key, out var row)) continue;
                row["Customer.GroupDiscounts"] = string.Join(" | ", discounts.Select(d => $"{d.Code}={d.Pct}%"));
                var nw = discounts.FirstOrDefault(d => string.Equals(d.Code, "NW", StringComparison.OrdinalIgnoreCase));
                if (nw != default) row["Customer.NwDiscount"] = nw.Pct;
            }
        }

        return customers.Values.OrderBy(r => r.TryGetValue("Customer.Key", out var k) ? k : "").ToList();
    }

    /// <summary>
    /// Ali je ta vloga medija glavna slika?
    ///
    /// Kanonicni sloj pise <c>PRIMARY</c> — tako vstavljajo migracije 012, 013, 016, 017,
    /// 040 in 042 (<c>Role=N'PRIMARY', SortOrder=1</c>), v <c>canon.ProductMedia</c> pa
    /// obstajajo tudi starejse vrstice z zapisom <c>Primary</c>. Prejsnja koda je primerjala
    /// z <c>MAIN</c>, kar se ni ujemalo z nicimer: glavna slika je ostala prazna, vsaka slika
    /// pa je pristala med dodatnimi.
    ///
    /// Primerjava je zato neobcutljiva na velikost crk in sprejme oba zapisa. <c>MAIN</c>
    /// ostane podprt, ker je Magentov izraz in se lahko pojavi v rocno urejenih vrsticah.
    /// </summary>
    internal static bool IsPrimaryMediaRole(string? role) =>
        string.Equals(role, "PRIMARY", StringComparison.OrdinalIgnoreCase)
        || string.Equals(role, "MAIN", StringComparison.OrdinalIgnoreCase);

    private static string? FormatDecimalString(object? value)
    {
        if (value is null or DBNull) return null;
        if (value is decimal d) return d.ToString("0.####", CultureInfo.InvariantCulture);
        if (value is string s && decimal.TryParse(s, NumberStyles.Any, CultureInfo.InvariantCulture, out var parsed))
            return parsed.ToString("0.####", CultureInfo.InvariantCulture);
        return value.ToString();
    }
}
