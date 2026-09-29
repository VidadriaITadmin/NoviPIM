using System.Data;
using System.Runtime.CompilerServices;
using Microsoft.Data.SqlClient;
using PIM.B2b;
using PIM.Operations;

[assembly: InternalsVisibleTo("PIM.F7.MagentoExportTests")]

namespace PIM.B2bWorker;

/// <summary>
/// Ena zapisana izvozna datoteka: kar gre v fazo DATOTEKA (blok 6 prenove nadzora) — ime, vrstice,
/// stolpci in velikost. Velikost je null, kadar je datoteke po zamenjavi ni bilo mogoče prebrati.
/// </summary>
/// <param name="Note">
/// 277: kaj je o datoteki povedala varovalka (npr. »zadržanih artiklov: 3 … čakajo potrditev«); null = nič posebnega.
/// </param>
public sealed record ExportFileResult(string ProfileCode, string FilePath, int Rows, int Columns, long? Bytes, string? Note = null);

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

    /// <summary>
    /// Ime procedure, ki iz tabel sestavi vrstice po izvoznem registru (migracija 142).
    /// Isto proceduro bere intranet, zato datoteka na spletu in predogled v intranetu
    /// ne moreta pokazati razlicne vsebine.
    /// </summary>
    internal const string ExportRowsProcedure = "out.GetExportRows";

    /// <summary>
    /// Par katalog.csv + stranke.csv v izhodno mapo. Ta oblika NE zapiše, kaj je šlo na splet
    /// (out.WebPublication), in ne umika kljukic — za preizkuse in ročne izvoze ob strani, ki jih
    /// Magento ne bere. Pravi izvoz (worker) kliče <see cref="ExecuteAsync(int, string, string, bool, CancellationToken)"/>
    /// s <c>publishToMagento: true</c>.
    /// </summary>
    public static Task ExecuteAsync(int organizationId, string outputDir, string connectionString, CancellationToken ct = default)
        => ExecuteAsync(organizationId, outputDir, connectionString, publishToMagento: false, ct);

    /// <param name="publishToMagento">
    /// true, kadar gre za datoteki, ki ju bere Magento (migracija 251): pred izvozom se umaknejo kljukice
    /// artiklov, ki na spletišče ne smejo (samo pri podjetju z vklopljenim samodejnim umikom), po uspešni
    /// zamenjavi pa se v out.WebPublication zapiše, kaj je bilo objavljeno in kaj umaknjeno. Od tega je
    /// odvisno, kdo dobi odjavno vrstico (prazne »Spletne strani«) in kdaj ta iz datoteke izpade — preizkus,
    /// ki piše v začasno mapo, bi sicer začel odjavno okno, ne da bi Magento datoteko sploh videl.
    /// </param>
    /// <returns>Zapisani datoteki (katalog.csv, stranke.csv) za fazo DATOTEKA.</returns>
    public static async Task<IReadOnlyList<ExportFileResult>> ExecuteAsync(int organizationId, string outputDir, string connectionString, bool publishToMagento, CancellationToken ct = default)
    {
        if (organizationId <= 0) throw new ArgumentOutOfRangeException(nameof(organizationId), "OrganizationId mora biti pozitivno celo število.");
        ArgumentException.ThrowIfNullOrWhiteSpace(outputDir, nameof(outputDir));
        if (string.IsNullOrWhiteSpace(connectionString))
            throw new InvalidOperationException(LocalSettings.MissingConnectionMessage());

        await using var connection = new SqlConnection(connectionString);
        await connection.OpenAsync(ct);

        // Datoteki sta par in ju Magento uvozi skupaj. Zato obe najprej zapisemo ob stran,
        // sele nato prestavimo na koncni imeni. Ce pade poizvedba za stranke ali pisanje druge
        // datoteke, v izhodni mapi ne nastane nov katalog.csv poleg stare ali
        // manjkajoce stranke.csv - torej ni polovicnega izvoza.
        // Obliko preberemo pred podatki: manjkajoč ali izklopljen profil je napaka
        // konfiguracije in mora pasti, preden se karkoli zapiše v izhodno mapo.
        // 286: stolpci atributov sledijo naborom atributov po kategorijah (uporabnik 2026-09-25: »to ne sme biti fiksno«).
        await SyncAttributeColumnsAsync(connection, MagentoProductSchema.ProfileCode, ct);
        var productProfile = await ExportProfileRegistry.LoadProfileAsync(connection, MagentoProductSchema.ProfileCode, ct);
        var customerProfile = await ExportProfileRegistry.LoadProfileAsync(connection, MagentoCustomerSchema.ProfileCode, ct);

        var productPath = Path.Combine(outputDir, "katalog.csv");
        var customerPath = Path.Combine(outputDir, "stranke.csv");

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
        var markerTempPath = $"{completeMarkerPath}.{runId}.tmp";

        // Enolicna imena preprecijo trk datotek, ne pa prepletanja same zamenjave. Zato je
        // zamenjava se pod kljucavnico na izhodni mapi: drugi zagon raje pade z jasnim
        // sporocilom, kot da objavi par iz dveh zagonov.
        IDisposable? directoryLock = null;
        var markerBackedUp = false;
        var productBackedUp = false;
        var customerBackedUp = false;
        var productReplaced = false;
        var customerReplaced = false;
        var replacementSucceeded = false;
        string? failure = null;

        // Sled izvoza (migracija 172). Datoteki sta par, zapisa pa sta dva — vsak profil ima
        // svoje stevilo vrstic, svojo velikost in svoj hash. Skupen izid imata zato, ker se
        // par zamenja skupaj: ce pade zamenjava, nista uspesna niti eden niti drugi.
        var productRunKey = await ExportRunLog.BeginAsync(connection, MagentoProductSchema.ProfileCode, organizationId, ct);
        var customerRunKey = await ExportRunLog.BeginAsync(connection, MagentoCustomerSchema.ProfileCode, organizationId, ct);
        var productCount = 0;
        var customerCount = 0;
        // 251: sifra in »Spletne strani« vsake zapisane vrstice — po uspesni zamenjavi gre v out.WebPublication.
        // 277: in varovane vrednosti (cene), ki jih varovalka primerja z zadnjo objavo.
        var publication = new List<PublishedRow>();
        // 277: kje v zacasni datoteki je vsaka vrstica (odmik, dolzina v bajtih) — zadrzane se izpustijo.
        var records = new List<(string? ItemId, long Offset, int Length)>();
        var itemIndex = ConfiguredItemIndex(productProfile.Columns);
        var filteredTempPath = $"{productPath}.{runId}.izbor.tmp";
        CatalogSafeguardDecision? safeguard = null;
        IReadOnlyList<string> heldItems = [];
        // 285: katalog iz več podjetij — začasne datoteke po podjetju in kaj je vsako prispevalo.
        var sourceTempPaths = new List<string>();
        MergedCatalog? mergedParts = null;

        try
        {
            directoryLock = AcquireOutputDirectory(outputDir);
            RemoveStaleTempFiles(outputDir);
            // 285: katalog iz več podjetij (out.CatalogSource). Brez registra ali z enim podjetjem je izvoz enak kot pred 285.
            var sources = await CatalogMerge.LoadSourcesAsync(connection, organizationId, ct);
            var mergedCatalog = sources.Count > 1 || sources[0].OrganizationId != organizationId;
            foreach (var source in sources)
            {
                await RefreshCatalogReviewAsync(connection, source.OrganizationId, ct);
                if (publishToMagento) await WithdrawIneligibleWebShopsAsync(connection, source.OrganizationId, ct);
            }
            string publishFrom;
            if (mergedCatalog)
            {
                mergedParts = await WriteMergedCatalogAsync(connection, sources, productProfile, productPath, runId, productTempPath,
                    publishToMagento, productRunKey, sourceTempPaths, ct);
                productCount = mergedParts.Rows;
                publishFrom = productTempPath;
            }
            else
            {
                // Od migracije 146 gre v datoteko samo, kar na splet sodi: objavljen izdelek s spletno
                // stranjo, veljaven za to stran (pravilo je v out.GetExportRows in registru profila).
                // Do takrat je izvoz jemal ves katalog podjetja (43.504 vrstic namesto 1.957 pri
                // podjetju 2) — uporabnik 2026-09-02: "v izvozu morajo biti cisti podatki".
                // 251: poleg objavljenih gre v datoteko se odjavna vrstica (prazne »Spletne strani«) za
                // artikel, ki je bil objavljen in ni vec; artikel, ki ni bil nikoli na spletu, ne gre.
                // 277: locilo stolpcev iz registra (katalog.csv ';'), cene z decimalno vejico (ExportValueFormat).
                productCount = await RegistryCsvWriter.WriteAsync(productTempPath, productProfile.Columns,
                    CapturePublication(
                        ReadExportRowsAsync(connection, productProfile.ExportProfileId, organizationId, productProfile.Columns, onlyPublished: true, ct),
                        productProfile.Columns, publication, ct), ct,
                    productProfile.FieldDelimiter,
                    (row, offset, length) => records.Add((itemIndex >= 0 ? row[itemIndex] : null, offset, length)));

                // 277: varovalka pred zamenjavo. Artikel s sumljivo spremembo (cena ×100, 0, prazna, množičen umik s
                // spleta …) ne gre v objavljeno datoteko in čaka potrditev na /varovalke; ostali gredo ven kot vedno.
                // Magento se artikla, ki ga v datoteki ni, ne dotakne: na spletu ostane s prejšnjimi podatki.
                if (publishToMagento)
                {
                    safeguard = await CatalogSafeguard.EvaluateAsync(connection, organizationId, CatalogSafeguard.RowsJson(publication), productCount, productRunKey, ct);
                    heldItems = safeguard.HeldItems;
                    Console.WriteLine($"Varovalka katalog.csv: {safeguard.Describe()}.");
                }
                publishFrom = productTempPath;
                if (heldItems.Count > 0)
                {
                    var held = heldItems.ToHashSet(StringComparer.Ordinal);
                    var skip = Enumerable.Range(0, records.Count).Where(index => records[index].ItemId is { } item && held.Contains(item)).ToHashSet();
                    productCount = await RegistryCsvWriter.CopyWithoutAsync(productTempPath, filteredTempPath,
                        records.Select(record => (record.Offset, record.Length)).ToList(), skip, ct);
                    publishFrom = filteredTempPath;
                }
            }

            // 285: stranke iz vseh podjetij kataloga. Anja Zorenc 2026-09-25: »Stranke so dvojne, imajo tudi dvojne
            // šifre … Vodimo jo posebej. Združevali jih bomo pomoje samo v analizah.« Vsaka stranka gre ven s svojo
            // šifro, cenikom in popusti svojega podjetja; šifre podjetij se ne prekrivajo (IQ 8 mest, ViD 7).
            customerCount = await RegistryCsvWriter.WriteAsync(customerTempPath, customerProfile.Columns,
                mergedCatalog
                    ? CustomersFromAllAsync(connection, customerProfile, sources, ct)
                    : ReadExportRowsAsync(connection, customerProfile.ExportProfileId, organizationId, customerProfile.Columns, onlyPublished: true, ct), ct,
                customerProfile.FieldDelimiter);

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

                File.Move(publishFrom, productPath, overwrite: true);
                productReplaced = true;
                File.Move(customerTempPath, customerPath, overwrite: true);
                customerReplaced = true;

                // Par je popoln. Sele zdaj sme porabnik brati.
                await File.WriteAllTextAsync(
                    markerTempPath,
                    $"{runId}\n{DateTime.UtcNow:O}\nizdelki={productCount}\nstranke={customerCount}\n",
                    ct);
                File.Move(markerTempPath, completeMarkerPath, overwrite: true);
                replacementSucceeded = true;
            }
            catch
            {
                // Vrnemo prejsnje stanje v celoti; raje star veljaven par kot nov polovicen.
                // Napake pri vracanju ne smejo prekriti prvotne — ta pove, kaj je res slo narobe.
                if (markerBackedUp || productReplaced || customerReplaced) DeleteIfExists(completeMarkerPath);
                TryRestore(() => { if (productReplaced) DeleteIfExists(productPath); });
                TryRestore(() => { if (customerReplaced) DeleteIfExists(customerPath); });
                TryRestore(() => { if (productBackedUp) File.Move(productBackupPath, productPath, overwrite: true); });
                TryRestore(() => { if (customerBackedUp) File.Move(customerBackupPath, customerPath, overwrite: true); });
                // Oznako vrnemo le, če sta se prejšnji datoteki res vrnili.
                if (!File.Exists(productBackupPath) && !File.Exists(customerBackupPath))
                    TryRestore(() => { if (markerBackedUp) File.Move(markerBackupPath, completeMarkerPath, overwrite: true); });
                throw;
            }

            // 251: sele ko je par objavljen, zapisemo, kaj je slo ven. Ce ta zapis pade, datoteki ostaneta
            // (sta veljavni), zagon pa se konca z napako: naslednji izvoz poslje iste odjave znova.
            // 277: zapise se samo, kar je v objavljeni datoteki; zadrzani artikli ostanejo, kot so bili.
            if (publishToMagento && mergedParts is not null)
            {
                // 285: vsako podjetje zapiše svoje vrstice (svoja spletišča) — od tega so odvisne njegove odjavne vrstice.
                foreach (var part in mergedParts.Parts)
                {
                    var publishedJson = CatalogSafeguard.RowsJson(part.Publication.Where(row => part.Contributed.Contains(row.ItemId)));
                    await RecordWebPublicationAsync(connection, part.OrganizationId, publishedJson, ct);
                    await CatalogSafeguard.RecordPublicationAsync(connection, part.OrganizationId, publishedJson, part.Safeguard?.CheckId, part.Held, ct);
                }
            }
            else if (publishToMagento)
            {
                var held = heldItems.ToHashSet(StringComparer.Ordinal);
                var publishedJson = CatalogSafeguard.RowsJson(publication.Where(row => !held.Contains(row.ItemId)));
                await RecordWebPublicationAsync(connection, organizationId, publishedJson, ct);
                await CatalogSafeguard.RecordPublicationAsync(connection, organizationId, publishedJson, safeguard?.CheckId, heldItems, ct);
            }
        }
        catch (Exception exception)
        {
            failure = exception.Message;
            throw;
        }
        finally
        {
            DeleteIfExists(productTempPath);
            DeleteIfExists(filteredTempPath);
            foreach (var sourceTempPath in sourceTempPaths) DeleteIfExists(sourceTempPath);
            DeleteIfExists(customerTempPath);
            DeleteIfExists(markerTempPath);

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

            // Zapis nastane tudi ob padcu: izvoz, ki ni uspel, mora biti v zgodovini viden,
            // sicer je videti, kot da tiste noci sploh ni bil poskusen.
            await ExportRunLog.CompleteAsync(connection, productRunKey, replacementSucceeded,
                rowCount: productCount, columnCount: productProfile.Columns.Count,
                filePath: productPath, error: failure, ct: CancellationToken.None);
            await ExportRunLog.CompleteAsync(connection, customerRunKey, replacementSucceeded,
                rowCount: customerCount, columnCount: customerProfile.Columns.Count,
                filePath: customerPath, error: failure, ct: CancellationToken.None);
            directoryLock?.Dispose();
        }

        // 277: faza DATOTEKA pove, koliko artiklov je zadrzanih (niso v datoteki, cakajo potrditev).
        var note = mergedParts is not null
            ? mergedParts.Note
            : safeguard is { Status: not "CLEAN" } ? safeguard.Describe() : null;
        return
        [
            new(MagentoProductSchema.ProfileCode, productPath, productCount, productProfile.Columns.Count, FileSize(productPath), note),
            new(MagentoCustomerSchema.ProfileCode, customerPath, customerCount, customerProfile.Columns.Count, FileSize(customerPath)),
        ];
    }

    /// <summary>
    /// 285: stranke vseh podjetij kataloga zaporedoma. Šifra stranke je ključ v Magentu; če bi se kdaj ponovila v
    /// dveh podjetjih, gre ven samo prva (po prednosti), ostale so naštete v izpisu — dve vrstici z isto šifro bi
    /// Magento zmešal v eno stranko z napačnim cenikom.
    /// </summary>
    static async IAsyncEnumerable<IReadOnlyList<string?>> CustomersFromAllAsync(
        SqlConnection connection, ExportProfileDefinition profile, IReadOnlyList<CatalogMerge.Source> sources,
        [EnumeratorCancellation] CancellationToken ct)
    {
        var keyIndex = profile.Columns.Where(column => column.IsActive).OrderBy(column => column.SortOrder).ToList()
            .FindIndex(column => string.Equals(column.CanonicalFieldCode, "Customer.Key", StringComparison.Ordinal));
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var duplicates = new List<string>();
        foreach (var source in sources)
        {
            var count = 0;
            await foreach (var row in ReadExportRowsAsync(connection, profile.ExportProfileId, source.OrganizationId, profile.Columns, onlyPublished: true, ct))
            {
                if (keyIndex >= 0 && row[keyIndex] is { Length: > 0 } key && !seen.Add(key))
                {
                    duplicates.Add($"{key} (podjetje {source.OrganizationId})");
                    continue;
                }
                count++;
                yield return row;
            }
            Console.WriteLine($"Stranke: podjetje {source.OrganizationId} prispeva {count} strank.");
        }
        if (duplicates.Count > 0)
            Console.Error.WriteLine($"Opozorilo: {duplicates.Count} šifer strank se ponovi v več podjetjih, izvožena je prva: {string.Join(", ", duplicates.Take(20))}.");
    }

    /// <summary>285: kaj je v združeni katalog.csv prispevalo posamezno podjetje.</summary>
    internal sealed record MergedPart(
        int OrganizationId, List<PublishedRow> Publication, IReadOnlySet<string> Contributed,
        CatalogSafeguardDecision? Safeguard, IReadOnlyList<string> Held, int SourceRows);

    /// <summary>285: združena datoteka — vrstice v njej in prispevki po podjetjih.</summary>
    internal sealed record MergedCatalog(int Rows, IReadOnlyList<MergedPart> Parts, string? Note);

    /// <summary>
    /// 285: katalog.csv iz več podjetij. Vsako podjetje zapiše svoje vrstice po obstoječih pravilih v svojo začasno
    /// datoteko in gre skozi svojo varovalko (277, primerjava z SVOJO zadnjo objavo); nato <see cref="CatalogMerge"/>
    /// sestavi eno vrstico na šifro. Rezultat je v <paramref name="targetTempPath"/>.
    /// </summary>
    static async Task<MergedCatalog> WriteMergedCatalogAsync(
        SqlConnection connection, IReadOnlyList<CatalogMerge.Source> sources, ExportProfileDefinition profile,
        string productPath, string runId, string targetTempPath, bool publishToMagento, Guid? productRunKey,
        List<string> sourceTempPaths, CancellationToken ct)
    {
        var ordered = profile.Columns.Where(column => column.IsActive).OrderBy(column => column.SortOrder)
            .ThenBy(column => column.ColumnCode, StringComparer.Ordinal).ToList();
        var itemIndex = ordered.FindIndex(column => string.Equals(column.CanonicalFieldCode, "Product.ItemID", StringComparison.Ordinal));
        var sitesIndex = ordered.FindIndex(column => string.Equals(column.CanonicalFieldCode, "Product.WebSites", StringComparison.Ordinal));
        if (itemIndex < 0 || sitesIndex < 0)
            throw new InvalidOperationException("Katalog iz več podjetij potrebuje v profilu stolpca šifre in »Spletne strani«. Prejšnja datoteka ostane veljavna.");
        var sites = await CatalogMerge.LoadSitesAsync(connection, ct);
        var categoryIndex = sites.ToDictionary(
            site => site.Label,
            site => (IReadOnlyList<int>)site.CategoryFieldCodes
                .Select(code => ordered.FindIndex(column => string.Equals(column.CanonicalFieldCode, code, StringComparison.Ordinal)))
                .Where(index => index >= 0).ToList(),
            StringComparer.OrdinalIgnoreCase);
        var siteColumns = categoryIndex.Values.SelectMany(indexes => indexes).Distinct().ToArray();

        var rows = new List<IReadOnlyList<CatalogMerge.SourceRow>>();
        var publications = new List<List<PublishedRow>>();
        var decisions = new List<CatalogSafeguardDecision?>();
        var held = new List<IReadOnlySet<string>>();
        foreach (var source in sources)
        {
            var tempPath = $"{productPath}.{runId}.podjetje{source.OrganizationId}.tmp";
            sourceTempPaths.Add(tempPath);
            var sourceRows = new List<CatalogMerge.SourceRow>();
            var publication = new List<PublishedRow>();
            // Podjetje z omejenimi spletišči (ViD: samo videlektro): vrstica brez dovoljenega spletišča ne gre ven,
            // razen kot odjavna vrstica za artikel, ki ga je podjetje nedavno objavilo (kot 251).
            var recent = source.WebSiteLabels is null ? null : await CatalogMerge.LoadRecentPublicationAsync(connection, source.OrganizationId, source.WebSiteLabels, ct);
            var dropped = 0;
            await RegistryCsvWriter.WriteAsync(tempPath, profile.Columns,
                CapturePublication(
                    ReadExportRowsAsync(connection, profile.ExportProfileId, source.OrganizationId, profile.Columns, onlyPublished: true, ct),
                    profile.Columns, publication, ct), ct,
                profile.FieldDelimiter,
                (row, offset, length) =>
                {
                    var values = new Dictionary<int, string?>(siteColumns.Length);
                    foreach (var index in siteColumns) values[index] = row[index];
                    // Vrstica brez šifre se ne združuje; dobi svoj ključ in gre skozi, kot je.
                    var itemId = row[itemIndex] is { Length: > 0 } id ? id : $"\0{source.OrganizationId}:{sourceRows.Count}";
                    var allowed = source.Allowed(row[sitesIndex]);
                    // Tudi odjavna vrstica podjetja (prazne »Spletne strani«) gre ven samo za artikel, ki ga je podjetje
                    // objavilo na dovoljenem spletišču — sicer bi ViD umikal artikle, ki jih je objavljal samo na svetilih.
                    if (allowed is null && recent is not null && !recent.Contains(itemId))
                    {
                        dropped++;
                        return;
                    }
                    sourceRows.Add(new(itemId, offset, length, allowed, values, row[sitesIndex]));
                });
            // Objava in varovalka podjetja vidita samo, kar podjetje res prispeva: dovoljena spletišča.
            var kept = sourceRows.ToDictionary(row => row.ItemId, row => row.WebSites, StringComparer.Ordinal);
            publication = publication.Where(row => kept.ContainsKey(row.ItemId))
                .Select(row => row with { WebSites = kept[row.ItemId] }).ToList();
            var count = sourceRows.Count;
            CatalogSafeguardDecision? decision = null;
            if (publishToMagento)
            {
                decision = await CatalogSafeguard.EvaluateAsync(connection, source.OrganizationId, CatalogSafeguard.RowsJson(publication), count, productRunKey, ct);
                Console.WriteLine($"Varovalka katalog.csv (podjetje {source.OrganizationId}): {decision.Describe()}.");
            }
            rows.Add(sourceRows);
            publications.Add(publication);
            decisions.Add(decision);
            held.Add((decision?.HeldItems ?? []).ToHashSet(StringComparer.Ordinal));
            Console.WriteLine($"Katalog: podjetje {source.OrganizationId} prispeva {count} vrstic"
                + (dropped > 0 ? $" ({dropped} brez dovoljenega spletišča {string.Join('|', source.WebSiteLabels!)} izpuščenih)." : "."));
        }

        var plan = CatalogMerge.Plan(rows, held, sites, sitesIndex, categoryIndex);
        var written = await CatalogMerge.WriteAsync(targetTempPath, sourceTempPaths, rows, plan, ordered, profile.FieldDelimiter, null, ct);
        var contributed = CatalogMerge.Contributed(rows, held, plan);
        var parts = sources.Select((source, index) => new MergedPart(source.OrganizationId, publications[index], contributed[index],
            decisions[index], decisions[index]?.HeldItems ?? [], rows[index].Count)).ToList();
        var fromFirst = plan.Count(row => row.SourceIndex == 0);
        Console.WriteLine($"Katalog iz {sources.Count} podjetij: {written} vrstic (podjetje {sources[0].OrganizationId}: {fromFirst}, ostala: {written - fromFirst}), "
            + $"{plan.Count(row => row.Patches.Count > 0)} vrstic z združenimi spletišči.");
        var notes = parts.Where(part => part.Safeguard is { Status: not "CLEAN" })
            .Select(part => $"podjetje {part.OrganizationId}: {part.Safeguard!.Describe()}").ToList();
        var summary = $"iz {sources.Count} podjetij ({string.Join(" + ", parts.Select(part => $"{part.OrganizationId}: {part.SourceRows}"))} vrstic → {written})";
        return new MergedCatalog(written, parts, notes.Count == 0 ? summary : summary + "; " + string.Join("; ", notes));
    }

    /// <summary>Stolpec s šifro artikla v urejenem registru (po SortOrder); -1, če ga profil nima.</summary>
    static int ConfiguredItemIndex(IReadOnlyList<ExportColumnDefinition> columns) =>
        columns.Where(column => column.IsActive).OrderBy(column => column.SortOrder).ThenBy(column => column.ColumnCode, StringComparer.Ordinal)
            .ToList().FindIndex(column => string.Equals(column.CanonicalFieldCode, "Product.ItemID", StringComparison.Ordinal));

    /// <summary>
    /// En sam profil iz registra v eno datoteko — za hitro osvezitev cen in zaloge
    /// (MAGENTO_STOCK_PRICES, migracija 146), ki tece vsakih pet minut iz Zaloga-cikel.ps1.
    /// Datoteka nastane ob strani in se zamenja sele, ko je cela; bralec nikoli ne vidi
    /// polovicne. Vrne stevilo zapisanih vrstic.
    /// </summary>
    public static async Task<int> ExportProfileAsync(string profileCode, int organizationId, string outputDir, string? fileName, string connectionString, CancellationToken ct = default)
        => (await ExportProfileFileAsync(profileCode, organizationId, outputDir, fileName, connectionString, ct)).Rows;

    /// <summary>Kot <see cref="ExportProfileAsync"/>, a vrne celo datoteko (ime, vrstice, stolpci, velikost) za fazo DATOTEKA.</summary>
    public static async Task<ExportFileResult> ExportProfileFileAsync(string profileCode, int organizationId, string outputDir, string? fileName, string connectionString, CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(profileCode, nameof(profileCode));
        if (organizationId <= 0) throw new ArgumentOutOfRangeException(nameof(organizationId), "OrganizationId mora biti pozitivno celo število.");
        ArgumentException.ThrowIfNullOrWhiteSpace(outputDir, nameof(outputDir));
        if (string.IsNullOrWhiteSpace(connectionString))
            throw new InvalidOperationException(LocalSettings.MissingConnectionMessage());

        await using var connection = new SqlConnection(connectionString);
        await connection.OpenAsync(ct);

        var profile = await ExportProfileRegistry.LoadProfileAsync(connection, profileCode, ct);
        var targetPath = Path.Combine(outputDir, fileName ?? $"magento-{profileCode.ToLowerInvariant().Replace('_', '-')}.csv");
        var tempPath = $"{targetPath}.{Guid.NewGuid():N}.tmp";
        var filteredPath = $"{tempPath}.izbor";

        // Sled izvoza (migracija 172) nastane PRED izhodno mapo in kljucavnico, enako kot pri paru
        // katalog/stranke. Do 2026-09-21 je bil zapis sele za kljucavnico: 76 zagonov v 48 urah je
        // padlo na pravicah do izhodne mape (UnauthorizedAccess na .magento-export.lock) in v
        // out.ExportRun ni ostala niti ena vrstica — zgodovina je kazala, kot da izvoz ni bil poskusen.
        var runKey = await ExportRunLog.BeginAsync(connection, profileCode, organizationId, ct);
        IDisposable? directoryLock = null;
        try
        {
            directoryLock = AcquireOutputDirectory(outputDir);
            await RefreshCatalogReviewAsync(connection, organizationId, ct);

            // Samo objavljeni izdelki s spletno stranjo; ali je zahtevana tudi veljavnost za splet,
            // pove profil (RequireWebValid) — hitri profil je namenoma ne zahteva.
            // 282: profil z varovanimi stolpci (cene, zaloga) gre skozi varovalko — sumljivi artikli ne gredo v
            // datoteko in na spletu ostanejo s prejšnjo ceno in zalogo; ostali gredo ven kot vedno.
            var itemIndex = ConfiguredItemIndex(profile.Columns);
            var guarded = itemIndex >= 0 && profile.Columns.Any(column => column.IsActive && column.GuardKind is not null);
            var publication = new List<PublishedRow>();
            var records = new List<(string? ItemId, long Offset, int Length)>();
            var rows = ReadExportRowsAsync(connection, profile.ExportProfileId, organizationId, profile.Columns, onlyPublished: true, ct);
            Action<IReadOnlyList<string?>, long, int>? recordWritten = guarded ? (row, offset, length) => records.Add((row[itemIndex], offset, length)) : null;
            var count = await RegistryCsvWriter.WriteAsync(tempPath, profile.Columns,
                guarded ? CapturePublication(rows, profile.Columns, publication, ct) : rows, ct,
                profile.FieldDelimiter, recordWritten);
            CatalogSafeguardDecision? safeguard = null;
            IReadOnlyList<string> heldItems = [];
            if (guarded)
            {
                safeguard = await CatalogSafeguard.EvaluateStockPriceAsync(connection, profileCode, organizationId,
                    CatalogSafeguard.RowsJson(publication), count, ct);
                heldItems = safeguard.HeldItems;
                Console.WriteLine($"Varovalka {profileCode}: {safeguard.Describe()}.");
                if (heldItems.Count > 0)
                {
                    var heldSet = heldItems.ToHashSet(StringComparer.Ordinal);
                    var skip = Enumerable.Range(0, records.Count).Where(index => records[index].ItemId is { } item && heldSet.Contains(item)).ToHashSet();
                    count = await RegistryCsvWriter.CopyWithoutAsync(tempPath, filteredPath,
                        records.Select(record => (record.Offset, record.Length)).ToList(), skip, ct);
                    File.Move(filteredPath, tempPath, overwrite: true);
                }
            }
            File.Move(tempPath, targetPath, overwrite: true);
            if (guarded && safeguard is { CheckId: not null })
            {
                var heldSet = heldItems.ToHashSet(StringComparer.Ordinal);
                await CatalogSafeguard.RecordExportPublicationAsync(connection, profileCode, organizationId,
                    CatalogSafeguard.RowsJson(publication.Where(row => !heldSet.Contains(row.ItemId))), safeguard.CheckId, heldItems, ct);
            }
            await ExportRunLog.CompleteAsync(connection, runKey, succeeded: true,
                rowCount: count, columnCount: profile.Columns.Count, filePath: targetPath, ct: CancellationToken.None);
            return new ExportFileResult(profileCode, targetPath, count, profile.Columns.Count, FileSize(targetPath),
                safeguard is { Status: not "CLEAN" } ? safeguard.Describe() : null);
        }
        catch (Exception exception)
        {
            // Zakljucek se zabelezi tudi ob preklicu: vrstica Running brez konca bi bila lazen "se tece".
            await ExportRunLog.CompleteAsync(connection, runKey, succeeded: false, error: exception.Message, ct: CancellationToken.None);
            throw;
        }
        finally
        {
            DeleteIfExists(tempPath);
            DeleteIfExists(filteredPath);
            directoryLock?.Dispose();
        }
    }

    /// <summary>
    /// val.RunValidation in val.Promote za podjetje — isti korak, ki ga Katalog-cikel.ps1 in
    /// Nocno-vse.ps1 pozeneta pred izvozom. Izvoz vzame samo izdelke, ki so VALID in promovirani
    /// v pim.*; worker, ki ga Scheduled Task zazene neposredno (namenski streznik), bi brez tega
    /// izvazal po zadnji validaciji, ki jo je slucajno sprozil kdo drug.
    /// </summary>
    /// <param name="maxAgeMinutes">
    /// Ce je podano, validacija tece samo, kadar je najstarejsa validacija aktivnega izdelka podjetja
    /// starejsa od te meje ali kak aktiven izdelek se sploh ni bil validiran. Validacija celega podjetja
    /// traja minute (podjetje 2 na razvojnem racunalniku 2026-09-21: 3,5 min) in jo urni cikel kataloga
    /// ze poganja; petminutni cikel CSV jo s to mejo osvezi samo, kadar urni cikel ni tekel.
    /// </param>
    /// <returns>true, ce sta validacija in objava tekli; false, ce je bila validacija dovolj sveza.</returns>
    public static async Task<bool> RefreshValidationAsync(int organizationId, string connectionString, int? maxAgeMinutes = null, CancellationToken ct = default)
    {
        if (organizationId <= 0) throw new ArgumentOutOfRangeException(nameof(organizationId), "OrganizationId mora biti pozitivno celo število.");
        if (maxAgeMinutes is < 0) throw new ArgumentOutOfRangeException(nameof(maxAgeMinutes), "Starost validacije mora biti nenegativna.");

        await using var connection = new SqlConnection(connectionString);
        await connection.OpenAsync(ct);
        if (maxAgeMinutes is { } maxAge)
        {
            var age = await OldestValidationAgeMinutesAsync(connection, organizationId, ct);
            if (age is { } minutes && minutes < maxAge) return false;
        }
        foreach (var procedure in new[] { "val.RunValidation", "val.Promote" })
        {
            await using var command = new SqlCommand(procedure, connection)
            {
                CommandType = CommandType.StoredProcedure,
                // Enaka meja kot v scripts\Sql.ps1: validacija celega podjetja lahko traja minute.
                CommandTimeout = 1800,
            };
            command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
            await command.ExecuteNonQueryAsync(ct);
        }
        return true;
    }

    /// <summary>
    /// Starost najstarejse validacije aktivnega izdelka podjetja v minutah; null, ce je kak aktiven izdelek
    /// se brez validacije (ali izdelkov ni). val.RunValidation za podjetje postavi LastValidatedUtc vsem
    /// aktivnim izdelkom hkrati, zato MIN pove, kdaj je nazadnje tekla za celo podjetje — posamezna
    /// "Preveri zdaj" na kartici je ne premakne. Razlika se racuna v bazi, da ura workerja ne steje.
    /// </summary>
    internal static async Task<int?> OldestValidationAgeMinutesAsync(SqlConnection connection, int organizationId, CancellationToken ct)
    {
        await using var command = new SqlCommand(
            "SELECT CASE WHEN COUNT(*) = 0 OR COUNT(*) <> COUNT(LastValidatedUtc) THEN NULL "
            + "ELSE DATEDIFF(minute, MIN(LastValidatedUtc), SYSUTCDATETIME()) END "
            + "FROM canon.Product WHERE OrganizationId = @OrganizationId AND IsActive = 1;", connection);
        command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
        var value = await command.ExecuteScalarAsync(ct);
        return value is int minutes ? minutes : null;
    }

    /// <summary>
    /// Ena vrstica zapisanega katalog.csv za out.WebPublication: sifra in »Spletne strani« (prazno = odjava).
    /// 277: <paramref name="Guarded"/> so vrednosti stolpcev, ki jih preverja varovalka (cene), v strojni
    /// obliki s piko — po kanonični kodi stolpca, npr. Product.PriceB2B.
    /// </summary>
    internal sealed record PublishedRow(string ItemId, string? WebSites, IReadOnlyDictionary<string, string?>? Guarded = null);

    /// <summary>
    /// Vrstice gredo skozi nespremenjene; ob tem si zapomnimo sifro, »Spletne strani« in varovane vrednosti
    /// (po kanonicni kodi stolpca, ne po naslovu v glavi). Brez stolpca sifre profil ne more nositi objave —
    /// takrat nic ne zbiramo. Vrednosti so zajete PRED zapisom, torej s piko, kot jih vrne baza.
    /// </summary>
    internal static async IAsyncEnumerable<IReadOnlyList<string?>> CapturePublication(
        IAsyncEnumerable<IReadOnlyList<string?>> rows,
        IReadOnlyList<ExportColumnDefinition> columns,
        List<PublishedRow> into,
        [EnumeratorCancellation] CancellationToken ct)
    {
        var ordered = columns.OrderBy(column => column.SortOrder).ToList();
        var itemIndex = ordered.FindIndex(column => string.Equals(column.CanonicalFieldCode, "Product.ItemID", StringComparison.Ordinal));
        var sitesIndex = ordered.FindIndex(column => string.Equals(column.CanonicalFieldCode, "Product.WebSites", StringComparison.Ordinal));
        var guarded = ordered
            .Select((column, index) => (column, index))
            .Where(pair => !string.IsNullOrEmpty(pair.column.GuardKind))
            .ToArray();
        await foreach (var row in rows.WithCancellation(ct))
        {
            if (itemIndex >= 0 && row[itemIndex] is { Length: > 0 } itemId)
            {
                Dictionary<string, string?>? values = null;
                if (guarded.Length > 0)
                {
                    values = new Dictionary<string, string?>(StringComparer.Ordinal);
                    foreach (var (column, index) in guarded) values[column.CanonicalFieldCode] = row[index];
                }
                into.Add(new(itemId, sitesIndex >= 0 ? row[sitesIndex] : null, values));
            }
            yield return row;
        }
    }

    /// <summary>
    /// 251: kljukice artiklov, ki na spletisce ne smejo (neaktiven, brez kategorije spletisca, neveljaven),
    /// se umaknejo pred izvozom — samo pri podjetju z vklopljenim samodejnim umikom (pim.WebPublicationPolicy).
    /// Kandidati se najprej ponovno validirajo, ker je stanje lahko staro. Napaka tu izvoza ne ustavi: artikel,
    /// ki ni veljaven, v datoteko itak ne gre; umik bo ponovil naslednji zagon.
    /// </summary>
    private static async Task WithdrawIneligibleWebShopsAsync(SqlConnection connection, int organizationId, CancellationToken ct)
    {
        try
        {
            await using var command = new SqlCommand("pim.WithdrawIneligibleWebShops", connection)
            {
                CommandType = CommandType.StoredProcedure,
                CommandTimeout = 600,
            };
            command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
            command.Parameters.Add("@TriggerSource", SqlDbType.NVarChar, 50).Value = "IZVOZ";
            command.Parameters.Add("@Revalidate", SqlDbType.Bit).Value = true;
            command.Parameters.Add("@Mode", SqlDbType.NVarChar, 10).Value = "AUTO";
            var withdrawn = 0;
            await using (var reader = await command.ExecuteReaderAsync(ct))
                while (await reader.ReadAsync(ct)) withdrawn++;
            if (withdrawn > 0)
                Console.WriteLine($"Samodejni umik s spleta: {withdrawn} kljukic odstranjenih (podjetje {organizationId}); seznam na /splet/umaknjeni.");
        }
        catch (SqlException exception)
        {
            Console.Error.WriteLine($"Samodejni umik s spleta ni uspel (izvoz se nadaljuje): {exception.Message}");
        }
    }

    /// <summary>
    /// 251: kaj je slo v objavljeni katalog.csv — od tega je odvisno, kdo dobi odjavno vrstico in kdaj izpade.
    /// Vrstice so iste kot za varovalko (<see cref="CatalogSafeguard.RowsJson"/>); procedura bere samo i in s.
    /// </summary>
    internal static async Task RecordWebPublicationAsync(SqlConnection connection, int organizationId, string rowsJson, CancellationToken ct)
    {
        await using var command = new SqlCommand("out.RecordWebPublication", connection)
        {
            CommandType = CommandType.StoredProcedure,
            CommandTimeout = 300,
        };
        command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
        command.Parameters.Add("@RowsJson", SqlDbType.NVarChar, -1).Value = rowsJson;
        await using var reader = await command.ExecuteReaderAsync(ct);
        if (await reader.ReadAsync(ct))
            Console.WriteLine($"Objava na splet zapisana: {reader.GetInt32(0)} objavljenih, {reader.GetInt32(1)} odjavnih vrstic ({reader.GetInt32(2)} novih odjav).");
    }

    /// <summary>
    /// 286: stolpec za vsak atribut iz naborov atributov po kategorijah (<c>out.SyncAttributeExportColumns</c>) —
    /// nov atribut v naboru dobi stolpec na koncu datoteke, preimenovan se preimenuje, umaknjen izklopi. Napaka
    /// tu izvoza ne ustavi: datoteka nastane s stolpci, kot so bili; baza pred 286 procedure nima.
    /// </summary>
    private static async Task SyncAttributeColumnsAsync(SqlConnection connection, string profileCode, CancellationToken ct)
    {
        try
        {
            await using var command = new SqlCommand("out.SyncAttributeExportColumns", connection)
            {
                CommandType = CommandType.StoredProcedure,
                CommandTimeout = 120,
            };
            command.Parameters.Add("@ProfileCode", SqlDbType.NVarChar, 200).Value = profileCode;
            command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = "PIM.B2bWorker";
            await using var reader = await command.ExecuteReaderAsync(ct);
            var changes = new List<string>();
            while (await reader.ReadAsync(ct))
                changes.Add($"{reader.GetString(1).ToLowerInvariant()}: {(reader.IsDBNull(3) ? reader.IsDBNull(2) ? reader.GetString(0) : reader.GetString(2) : reader.GetString(3))}");
            if (changes.Count > 0)
                Console.WriteLine($"Stolpci atributov usklajeni z nabori ({changes.Count}): {string.Join("; ", changes)}.");
        }
        catch (SqlException exception) when (exception.Number == 2812)
        {
            // Baza pred 286: stolpci ostanejo, kot so v registru.
        }
        catch (SqlException exception) when (!ct.IsCancellationRequested)
        {
            Console.Error.WriteLine($"Opozorilo: stolpci atributov niso usklajeni z nabori (izvoz se nadaljuje s trenutnimi stolpci): {exception.Message}");
        }
    }

    private static async Task RefreshCatalogReviewAsync(SqlConnection connection, int organizationId, CancellationToken ct)
    {
        await using var command = new SqlCommand("pim.RefreshCatalogReview", connection)
        {
            CommandType = CommandType.StoredProcedure,
            CommandTimeout = 120,
        };
        command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
        await command.ExecuteNonQueryAsync(ct);
    }

    /// <summary>
    /// Izhodna mapa in kljucavnica. Pravice so najpogostejsi vzrok padca (2026-09-21: 76 padcev v 48 h,
    /// ker je imel racun Windows naloge na C:\inetpub\wwwroot\PIM_exports_csv samo branje), zato napaka
    /// pove mapo, racun in kaj storiti — ne samo "Access to the path ... is denied". Sporocilo gre v
    /// out.ExportRun.ErrorRedacted in na /splet; prejsnji veljavni par datotek ostane nedotaknjen.
    /// </summary>
    internal static MagentoExportLock AcquireOutputDirectory(string outputDir)
    {
        try
        {
            Directory.CreateDirectory(outputDir);
            return MagentoExportLock.Acquire(outputDir);
        }
        catch (UnauthorizedAccessException exception)
        {
            throw new UnauthorizedAccessException(
                $"Izhodna mapa {outputDir} ni zapisljiva za račun {Environment.UserDomainName}\\{Environment.UserName}. "
                + "Dodeli pravico spreminjanja (scripts\\Nastavi-pravice-izvozne-mape.ps1 kot skrbnik) ali nastavi drugo mapo "
                + "(EXPORT_ROOT na /sistem/mape). Prejšnji veljavni par datotek ostane. "
                + $"Sistem: {exception.Message}", exception);
        }
    }

    /// <summary>Korak vracanja v prejsnje stanje, ki ne sme prekriti prvotne izjeme.</summary>
    private static void TryRestore(Action step)
    {
        try { step(); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    /// <summary>Velikost zapisane datoteke za fazo DATOTEKA; branje velikosti ne sme podreti uspelega izvoza.</summary>
    private static long? FileSize(string path)
    {
        try { return File.Exists(path) ? new FileInfo(path).Length : null; }
        catch (IOException) { return null; }
        catch (UnauthorizedAccessException) { return null; }
    }

    /// <summary>Odstrani zacasno datoteko, ce je se ostala. Napake pri ciscenju ne skrijejo prvotne.</summary>
    private static void DeleteIfExists(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    /// <summary>
    /// Zacasne datoteke zagonov, ki so bili prekinjeni na silo (Job Object, ubit proces) in niso prisli do
    /// pospravljanja v finally — uporabnik 2026-09-28 je v mapi nasel katalog.csv.….podjetje2.tmp izpred treh dni.
    /// Klice se pod kljucavnico mape, torej noben drug izvoz ne pise; ura starosti je samo dodatna varnost.
    /// Varnostne kopije (.prej) ostanejo: ob neuspeli obnovi so lahko edina kopija prejsnje datoteke.
    /// </summary>
    internal static int RemoveStaleTempFiles(string outputDir, TimeSpan? olderThan = null)
    {
        var limit = DateTime.UtcNow - (olderThan ?? TimeSpan.FromHours(1));
        var removed = 0;
        foreach (var pattern in new[] { "katalog.csv.*.tmp", "stranke.csv.*.tmp", "magento-export.complete.*.tmp" })
            foreach (var path in Directory.EnumerateFiles(outputDir, pattern, SearchOption.TopDirectoryOnly))
            {
                if (File.GetLastWriteTimeUtc(path) >= limit) continue;
                DeleteIfExists(path);
                if (!File.Exists(path)) removed++;
            }
        if (removed > 0) Console.WriteLine($"Pospravljenih {removed} zacasnih datotek prekinjenih izvozov.");
        return removed;
    }

    /// <summary>
    /// Vrstice izvoza, kot jih po registru sestavi <see cref="ExportRowsProcedure"/>.
    ///
    /// Do migracije 142 je bilo tu osem poizvedb nad <c>pim.*</c> in <c>b2b.*</c> ter
    /// sestavljanje slovarja kanonicnih vrednosti v pomnilniku. Zdaj je vse to v bazi:
    /// katera vrednost pride v kateri stolpec, pove <c>out.ExportColumn</c>, kako nastane,
    /// pa procedura. Tu ostane samo prenos — vrednost na mestu <c>i</c> pripada stolpcu
    /// na mestu <c>i</c>, ker sta oba urejena po istem <c>SortOrder</c>.
    ///
    /// Vrstice tecejo skozi in ne nastanejo vse hkrati v pomnilniku: bralnik vrne eno vrstico
    /// naenkrat, vrednosti vrstice pa preberemo z enim klicem (<c>GetValues</c>). Do 2026-09-21 je
    /// bil bralnik <c>SequentialAccess</c> z <c>IsDBNullAsync</c> + <c>GetString</c> za vsako celico
    /// posebej: pri 89.491 vrsticah x 180 stolpcih (16 milijonov celic) je prenos trajal vec kot
    /// 9 minut in izvoz je padel na 600 s meji ukaza, ceprav je sama procedura na strezniku
    /// koncala v ~65 s (izmerjeno na DAVID\MSSQL19 z @Take = 2000 in 10000: 76 s oziroma 65 s —
    /// strosek je fiksen, ne na vrstico).
    /// </summary>
    /// <param name="onlyPublished">
    /// Vsi izvozi za Magento podajo <c>true</c>: izdelek gre v datoteko samo aktiven, s kljukico in
    /// veljaven (ali kot odjavna vrstica, 251), stranka samo aktivna s spletnim profilom (202).
    /// </param>
    private static async IAsyncEnumerable<IReadOnlyList<string?>> ReadExportRowsAsync(
        SqlConnection connection,
        int exportProfileId,
        int organizationId,
        IReadOnlyList<ExportColumnDefinition> columns,
        bool onlyPublished,
        [EnumeratorCancellation] CancellationToken ct)
    {
        await using var command = new SqlCommand(ExportRowsProcedure, connection)
        {
            CommandType = CommandType.StoredProcedure,
            // Cel katalog je lahko vec deset tisoc vrstic; privzetih 30 sekund ne zadosca. Procedura
            // sama traja ~65 s (glej zgoraj), pod socasno validacijo celega podjetja tudi vec; meja
            // je zato pol ure. Prekrivanje dveh izvozov prepreci kljucavnica na mapi, ne ta meja.
            CommandTimeout = 1800,
        };
        command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
        command.Parameters.Add("@ExportProfileId", SqlDbType.Int).Value = exportProfileId;
        command.Parameters.Add("@WebSite", SqlDbType.NVarChar, 100).Value = DBNull.Value;
        command.Parameters.Add("@OnlyPublished", SqlDbType.Bit).Value = onlyPublished;
        command.Parameters.Add("@Search", SqlDbType.NVarChar, 200).Value = DBNull.Value;
        command.Parameters.Add("@Skip", SqlDbType.Int).Value = 0;
        // @Take = 0 pomeni cel nabor brez stranicenja.
        command.Parameters.Add("@Take", SqlDbType.Int).Value = 0;
        command.Parameters.Add("@TotalCount", SqlDbType.Int).Direction = ParameterDirection.Output;

        await using var reader = await command.ExecuteReaderAsync(CommandBehavior.SingleResult, ct);
        var expected = columns.OrderBy(column => column.SortOrder).Select(column => column.OutputColumnName).ToArray();
        if (!expected.SequenceEqual(Enumerable.Range(0, reader.FieldCount).Select(reader.GetName), StringComparer.Ordinal))
            throw new InvalidOperationException("Stolpci podatkov se ne ujemajo z izvoznim profilom. Prejšnja datoteka ostane veljavna.");
        var raw = new object[reader.FieldCount];
        while (await reader.ReadAsync(ct))
        {
            reader.GetValues(raw);
            var values = new string?[raw.Length];
            for (var index = 0; index < raw.Length; index++)
                values[index] = raw[index] switch
                {
                    DBNull => null,
                    string text => text,
                    var other => Convert.ToString(other, System.Globalization.CultureInfo.InvariantCulture),
                };
            yield return values;
        }
    }
}
