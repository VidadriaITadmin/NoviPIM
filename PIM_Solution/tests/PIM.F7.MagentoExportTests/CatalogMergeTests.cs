using System.Text;
using PIM.B2b;
using PIM.B2bWorker;

/// <summary>
/// 285 — katalog.csv iz več podjetij (IQ + ViD), en artikel ena vrstica.
///
/// Uporabnik 2026-09-25: »ja potem naj ima artikel svetila|videlektro v spletišču pa ena vrstica«, in
/// »eni artikli bodo imeli samo videlektro pa bodo samo na vidadria«. Brez baze: načrt združevanja in zapis
/// datoteke iz dveh začasnih datotek, kot ju zapiše RegistryCsvWriter.
/// </summary>
internal static class CatalogMergeTests
{
    static readonly CatalogMerge.SiteColumns[] Sites =
    [
        new("svetila", 10, ["Product.CategorySvetilaSl"]),
        new("videlektro", 30, ["Product.CategorySl"]),
    ];

    // Stolpci: 0 šifra, 1 naziv, 2 spletne strani, 3 kategorija svetila, 4 kategorija videlektro, 5 cena.
    static readonly ExportColumnDefinition[] Columns =
    [
        new("C1", "Šifra artikla", "Product.ItemID", 1, true, true),
        new("C2", "Naziv", "Product.Name", 2, false, true),
        new("C3", "Spletne strani", "Product.WebSites", 3, false, true),
        new("C4", "Kategorija svetila", "Product.CategorySvetilaSl", 4, false, true),
        new("C5", "Kategorija", "Product.CategorySl", 5, false, true),
        new("C6", "Cena", "Product.PriceB2C", 6, false, true, DecimalSeparator: ","),
    ];

    static readonly Dictionary<string, IReadOnlyList<int>> CategoryIndex = new(StringComparer.OrdinalIgnoreCase)
    {
        ["svetila"] = [3],
        ["videlektro"] = [4],
    };

    public static async Task RunWithoutDatabaseAsync()
    {
        // Celice z ločilom, narekovajem in koncem vrstice morajo ostati cele.
        var cells = CatalogMerge.SplitRecord("A;\"x;y\";\"rekel je \"\"da\"\"\";\"dve\nvrstici\";\n", ';');
        Check(cells.Count == 5, "razbitje vrstice: 5 celic");
        Check(cells[1] == "\"x;y\"" && cells[2] == "\"rekel je \"\"da\"\"\"" && cells[3] == "\"dve\nvrstici\"" && cells[4] == "",
            "razbitje vrstice ohrani celice v narekovajih");

        var directory = Path.Combine(Path.GetTempPath(), "pim-f7-katalog-" + Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(directory);
        try
        {
            // IQ: A svetila, B oboje, C odjavna vrstica, D svetila. ViD: A videlektro, C videlektro, E samo ViD, D videlektro.
            var iq = await WriteSource(Path.Combine(directory, "iq.tmp"),
            [
                ["A", "Svetilka IQ", "svetila", "Notranja", "IQ-kat-v", "10.5"],
                ["B", "Luč IQ", "svetila|videlektro", "Zunanja", "IQ-B-v", "20"],
                ["C", "Umaknjena IQ", null, null, null, "5"],
                ["D", "Zadržana IQ", "svetila", "S-D", null, "7"],
            ]);
            var vid = await WriteSource(Path.Combine(directory, "vid.tmp"),
            [
                ["A", "Svetilka ViD", "videlektro", null, "Razsvetljava/Notranja", "11"],
                ["C", "Luč ViD", "videlektro", null, "Razsvetljava/C", "6"],
                ["E", "Samo ViD; s podpičjem", "videlektro", null, "Razsvetljava/E", "3.25"],
                ["D", "D ViD", "videlektro", null, "V-D", "8"],
            ]);
            IReadOnlyList<IReadOnlyList<CatalogMerge.SourceRow>> rows = [iq.Rows, vid.Rows];

            IReadOnlyList<IReadOnlySet<string>> none = [new HashSet<string>(), new HashSet<string>()];
            var plan = CatalogMerge.Plan(rows, none, Sites, 2, CategoryIndex);
            Check(plan.Select(row => row.ItemId).SequenceEqual(["A", "B", "C", "D", "E"]), "ena vrstica na šifro, najprej IQ, nato samo ViD");

            var target = Path.Combine(directory, "katalog.csv");
            var written = await CatalogMerge.WriteAsync(target, [iq.Path, vid.Path], rows, plan, Columns, ';', null, CancellationToken.None);
            Check(written == 5, "združena datoteka ima 5 vrstic");
            var lines = (await File.ReadAllTextAsync(target, Encoding.UTF8)).Split('\n', StringSplitOptions.RemoveEmptyEntries);
            Check(lines[0].StartsWith("Šifra artikla;Naziv;Spletne strani", StringComparison.Ordinal), "glava ostane ena, iz profila");
            // A: vsebina IQ, spletišči obeh, kategorija videlektro iz ViD, cena IQ z vejico.
            Check(lines[1] == "A;Svetilka IQ;svetila|videlektro;Notranja;Razsvetljava/Notranja;10,5",
                $"A: svetila z IQ kartice + videlektro z ViD kartice = ena vrstica (dobil: {lines[1]})");
            // B: IQ ima obe; ViD vrstice ni — nespremenjena.
            Check(lines[2] == "B;Luč IQ;svetila|videlektro;Zunanja;IQ-B-v;20", $"B: IQ vrstica nespremenjena (dobil: {lines[2]})");
            // C: IQ je umaknil, ViD objavlja → vsebina ViD (podjetje, ki artikel objavlja).
            Check(lines[3] == "C;Luč ViD;videlektro;;Razsvetljava/C;6", $"C: IQ odjava + ViD objava = ViD vrstica (dobil: {lines[3]})");
            Check(lines[5] == "E;\"Samo ViD; s podpičjem\";videlektro;;Razsvetljava/E;3,25", $"E: artikel samo v ViD gre ven, kot ga je zapisal ViD (dobil: {lines[5]})");

            // Zadržanje: D zadrži IQ (podjetje vsebine) → D ni v datoteki; A zadrži ViD → A brez videlektro.
            IReadOnlyList<IReadOnlySet<string>> held = [new HashSet<string> { "D" }, new HashSet<string> { "A" }];
            var heldPlan = CatalogMerge.Plan(rows, held, Sites, 2, CategoryIndex);
            Check(heldPlan.All(row => row.ItemId != "D"), "artikel, ki ga zadrži podjetje vsebine, ne gre v datoteko");
            var a = heldPlan.Single(row => row.ItemId == "A");
            Check(a.SourceIndex == 0 && a.Patches.Count == 0, "zadržanje ViD odvzame samo prispevek ViD (A ostane svetila)");
            var contributed = CatalogMerge.Contributed(rows, held, heldPlan);
            Check(!contributed[0].Contains("D") && !contributed[1].Contains("D"), "zadržanega D ne zapiše nobeno podjetje");
            Check(contributed[0].Contains("A") && !contributed[1].Contains("A"), "A zapiše samo IQ, ViD obdrži prejšnje stanje");
            Check(contributed[0].Contains("C") && contributed[1].Contains("C"), "C zapišeta obe: IQ odjavo, ViD objavo");

            // »svetila samo IQ, videlektro oba«: ViD sme prispevati samo videlektro.
            var vidSource = new CatalogMerge.Source(3, 20, new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "videlektro" });
            Check(vidSource.Allowed("svetila|videlektro") == "videlektro", "ViD: svetila|videlektro → videlektro");
            Check(vidSource.Allowed("svetila") is null, "ViD: samo svetila → ViD ne prispeva ničesar");
            Check(new CatalogMerge.Source(2, 10).Allowed("svetila") == "svetila", "IQ brez omejitve obdrži vsa spletišča");
            // Artikel samo v ViD z obema kljukicama: v datoteko gre samo videlektro, zapisana vrstica pa ima obe.
            var onlyVid = new CatalogMerge.SourceRow("F", 0, 0, "videlektro", new Dictionary<int, string?>(), "svetila|videlektro");
            var restricted = CatalogMerge.Plan([Array.Empty<CatalogMerge.SourceRow>(), new[] { onlyVid }],
                [new HashSet<string>(), new HashSet<string>()], Sites, 2, CategoryIndex);
            Check(restricted.Single().Patches.TryGetValue(2, out var fSites) && fSites == "videlektro",
                "ViD artikel s kljukico svetila gre ven samo z videlektro");

            // Eno podjetje: načrt je vrstica za vrstico brez zamenjav.
            var single = CatalogMerge.Plan([iq.Rows], [new HashSet<string>()], Sites, 2, CategoryIndex);
            Check(single.Count == 4 && single.All(row => row.Patches.Count == 0), "z enim podjetjem se nič ne spremeni");
        }
        finally
        {
            try { Directory.Delete(directory, recursive: true); } catch (IOException) { }
        }
        Console.WriteLine("F7 285 katalog iz več podjetij: ena vrstica na šifro, unija spletišč, vsebina, zadržanja PASS.");
    }

    static async Task<(string Path, List<CatalogMerge.SourceRow> Rows)> WriteSource(string path, string?[][] data)
    {
        var rows = new List<CatalogMerge.SourceRow>();
        await RegistryCsvWriter.WriteAsync(path, Columns, Stream(data), CancellationToken.None, ';',
            (row, offset, length) => rows.Add(new(row[0]!, offset, length, row[2],
                new Dictionary<int, string?> { [3] = row[3], [4] = row[4] })));
        return (path, rows);

        static async IAsyncEnumerable<IReadOnlyList<string?>> Stream(string?[][] data)
        {
            foreach (var row in data) yield return row;
            await Task.CompletedTask;
        }
    }

    static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException("F7 285: " + message);
    }
}
