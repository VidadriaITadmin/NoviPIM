using System.Text;
using PIM.B2b;
using PIM.B2bWorker;

public static class MagentoExportTests
{
    public static async Task RunAllAsync()
    {
        Equal(215, MagentoProductSchema.Headers.Length, "Product CSV mora imeti točno 215 stolpcev.");
        Equal(19, MagentoCustomerSchema.Headers.Length, "Customer CSV mora imeti točno 19 stolpcev.");

        Equal("Šifra artikla", MagentoProductSchema.Headers[0], "1. stolpec produktov (ItemID).");
        Equal("EAN", MagentoProductSchema.Headers[1], "2. stolpec produktov (EAN).");
        Equal("Spletne strani", MagentoProductSchema.Headers[2], "3. stolpec produktov (spletne strani).");
        Equal("Naziv artikla EN", MagentoProductSchema.Headers[3], "4. stolpec produktov (naziv EN).");
        Equal("Naziv artikla", MagentoProductSchema.Headers[4], "5. stolpec produktov (naziv SLO).");
        Equal("Proizvajalec", MagentoProductSchema.Headers[5], "6. stolpec produktov (manufacturer).");
        Equal("Oznaka tarifa", MagentoProductSchema.Headers[9], "10. stolpec produktov (carinska tarifa).");
        Equal("PAK2", MagentoProductSchema.Headers[32], "33. stolpec produktov (PAK2).");
        Equal("Skupina popusta", MagentoProductSchema.Headers[34], "35. stolpec produktov (S code).");
        Equal("S popust %", MagentoProductSchema.Headers[35], "36. stolpec produktov (S percent).");
        Equal("Glavna slika", MagentoProductSchema.Headers[37], "38. stolpec produktov (main image).");
        Equal("Grlo ANG", MagentoProductSchema.Headers[53], "54. stolpec produktov (1. atribut).");
        Equal("Združljivo z", MagentoProductSchema.Headers[214], "215. stolpec produktov (zadnji).");

        Equal("Šifra stranke", MagentoCustomerSchema.Headers[0], "1. stolpec strank (key).");
        Equal("Naziv", MagentoCustomerSchema.Headers[1], "2. stolpec strank (name).");
        Equal("Skupina (Magento)", MagentoCustomerSchema.Headers[5], "6. stolpec strank (Magento group).");
        Equal("Rabat prag 1", MagentoCustomerSchema.Headers[10], "11. stolpec strank (tier 1 threshold).");
        Equal("B2B+", MagentoCustomerSchema.Headers[16], "17. stolpec strank (B2B+).");
        Equal("Popust NW", MagentoCustomerSchema.Headers[18], "19. stolpec strank (NW discount).");

        // Od migracije 045 obliko izvoza pove register out.ExportColumn, ne koda. Ta test
        // baze nima, zato si obliko sestavi sam iz iste predloge in preveri, kar je njegovo:
        // da zapisovalnik postavi vrednosti na mesto po SortOrder, izpiše 215 oziroma 19 polj,
        // pusti nekonfigurirane stolpce prazne in pravilno ubeži vejico in narekovaj.
        // Da se register in predloga nista razšla, dokazuje PIM.F7.MagentoExportTests proti bazi.
        var productColumns = TemplateColumns(MagentoProductSchema.Headers, new Dictionary<int, string>
        {
            [0] = "Product.ItemID",
            [1] = "Product.EAN",
            [5] = "Product.Manufacturer",
            [32] = "Product.Pak2",
        });
        var customerColumns = TemplateColumns(MagentoCustomerSchema.Headers, new Dictionary<int, string>
        {
            [0] = "Customer.Key",
            [1] = "Customer.Name",
            [5] = "Customer.MagentoGroup",
        });

        var dir = Path.Combine(Path.GetTempPath(), "f7-magento-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        try
        {
            var productRow = new Dictionary<string, string?>
            {
                ["Product.ItemID"] = "0000123",
                ["Product.EAN"] = "4030096006084",
                ["Product.Pak2"] = "5",
                ["Product.Manufacturer"] = "Nowodvorski",
            };
            var productPath = Path.Combine(dir, "magento-products.csv");
            await MagentoExportCommand.WriteProductCsvAsync(productPath, productColumns, [productRow]);

            var bytes = await File.ReadAllBytesAsync(productPath);
            if (bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF)
                throw new InvalidOperationException("Product CSV ne sme imeti UTF-8 BOM.");
            var text = Encoding.UTF8.GetString(bytes);
            if (text.Contains('\r'))
                throw new InvalidOperationException("Product CSV mora imeti samo LF, ne CRLF.");

            var lines = text.Split('\n', StringSplitOptions.RemoveEmptyEntries);
            var headerFields = ParseCsv(lines[0]);
            Equal(215, headerFields.Length, "Header line ima 215 polj.");
            Equal("Šifra artikla", headerFields[0], "1. header v CSV.");
            Equal("PAK2", headerFields[32], "33. header je PAK2.");
            Equal("Združljivo z", headerFields[214], "215. header je Združljivo z.");

            var dataFields = ParseCsv(lines[1]);
            Equal(215, dataFields.Length, "Data line ima 215 polj.");
            Equal("0000123", dataFields[0], "ItemID ohranja vodilne ničle.");
            Equal("4030096006084", dataFields[1], "EAN vrednost.");
            Equal("5", dataFields[32], "PAK2 vrednost.");
            Equal("Nowodvorski", dataFields[5], "Manufacturer vrednost.");
            Equal("", dataFields[6], "Dobavitelj je prazen (stolpec brez kanonične kode).");
            Equal("", dataFields[8], "Merska enota je prazna (stolpec brez kanonične kode).");
            Equal("", dataFields[53], "Grlo ANG je prazen (stolpec brez kanonične kode).");

            var escapeRow = new Dictionary<string, string?>
            {
                ["Product.ItemID"] = "BA,123",
                ["Product.EAN"] = "test\"quote",
            };
            var escapePath = Path.Combine(dir, "escape.csv");
            await MagentoExportCommand.WriteProductCsvAsync(escapePath, productColumns, [escapeRow]);
            var escapeLines = Encoding.UTF8.GetString(await File.ReadAllBytesAsync(escapePath))
                .Split('\n', StringSplitOptions.RemoveEmptyEntries);
            var escapeData = ParseCsv(escapeLines[1]);
            Equal("BA,123", escapeData[0], "Vejica mora biti pravilno escapirana (RFC4180).");
            Equal("test\"quote", escapeData[1], "Narekovaj mora biti pravilno escapiran.");

            var custRow = new Dictionary<string, string?>
            {
                ["Customer.Key"] = "C-001",
                ["Customer.Name"] = "Test stranka, d.o.o.",
                ["Customer.MagentoGroup"] = "b2b_instalater",
            };
            var custPath = Path.Combine(dir, "magento-customers.csv");
            await MagentoExportCommand.WriteCustomerCsvAsync(custPath, customerColumns, [custRow]);

            var custBytes = await File.ReadAllBytesAsync(custPath);
            if (custBytes.Length >= 3 && custBytes[0] == 0xEF && custBytes[1] == 0xBB && custBytes[2] == 0xBF)
                throw new InvalidOperationException("Customer CSV ne sme imeti UTF-8 BOM.");
            var custText = Encoding.UTF8.GetString(custBytes);
            if (custText.Contains('\r'))
                throw new InvalidOperationException("Customer CSV mora imeti samo LF.");
            var custLines = custText.Split('\n', StringSplitOptions.RemoveEmptyEntries);
            var custHeader = ParseCsv(custLines[0]);
            Equal(19, custHeader.Length, "Customer header ima 19 polj.");
            Equal("Šifra stranke", custHeader[0], "1. customer header.");
            Equal("Popust NW", custHeader[18], "19. customer header.");
            var custData = ParseCsv(custLines[1]);
            Equal(19, custData.Length, "Customer data ima 19 polj.");
            Equal("C-001", custData[0], "Customer key.");
            Equal("Test stranka, d.o.o.", custData[1], "Ime z vejico je pravilno escapirano.");
            Equal("", custData[2], "E-pošta je prazna (stolpec brez kanonične kode).");
            Equal("b2b_instalater", custData[5], "Magento skupina.");
        }
        finally
        {
            Directory.Delete(dir, true);
        }

        await ThrowsAsync<InvalidOperationException>(
            () => MagentoExportCommand.ExecuteAsync(1, Path.GetTempPath(), "", CancellationToken.None),
            "Manjka PIM_CONNECTION_STRING mora sprožiti izjemo.");
        await ThrowsAsync<ArgumentOutOfRangeException>(
            () => MagentoExportCommand.ExecuteAsync(0, Path.GetTempPath(), "Server=x", CancellationToken.None),
            "OrganizationId=0 mora sprožiti ArgumentOutOfRangeException.");

        Console.WriteLine("F7 magento export: shema, format, BOM, LF, escaping, CLI validacija PASS.");
    }

    private static string[] ParseCsv(string line)
    {
        var fields = new List<string>();
        var pos = 0;
        while (pos <= line.Length)
        {
            string field;
            if (pos < line.Length && line[pos] == '"')
            {
                pos++;
                var sb = new StringBuilder();
                while (pos < line.Length)
                {
                    if (line[pos] == '"')
                    {
                        pos++;
                        if (pos < line.Length && line[pos] == '"') { sb.Append('"'); pos++; }
                        else break;
                    }
                    else { sb.Append(line[pos]); pos++; }
                }
                if (pos < line.Length && line[pos] == ',') pos++;
                field = sb.ToString();
            }
            else
            {
                var end = line.IndexOf(',', pos);
                if (end < 0) { field = line[pos..]; pos = line.Length + 1; }
                else { field = line[pos..end]; pos = end + 1; }
            }
            fields.Add(field);
        }
        return [.. fields];
    }

    /// <summary>Stolpci iz predloge; kanonično kodo dobijo samo tisti, ki jih ta test postavlja.</summary>
    private static ExportColumnDefinition[] TemplateColumns(IReadOnlyList<string> headers, IReadOnlyDictionary<int, string> codes)
        => [.. headers.Select((header, index) => new ExportColumnDefinition(
            $"C{index + 1:D3}", header, codes.TryGetValue(index, out var code) ? code : "", index + 1, false, true))];

    private static void Equal<T>(T expected, T actual, string message)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
            throw new InvalidOperationException($"{message}: pričakovano '{expected}', dejansko '{actual}'.");
    }

    private static async Task ThrowsAsync<T>(Func<Task> action, string message) where T : Exception
    {
        try { await action(); }
        catch (T) { return; }
        throw new InvalidOperationException($"{message} — pričakovala se je {typeof(T).Name}.");
    }
}
