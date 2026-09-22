using System.Data;
using System.Runtime.CompilerServices;
using Microsoft.Data.SqlClient;
using PIM.B2b;
using PIM.Operations;

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
    public static async Task ExecuteAsync(int organizationId, string outputDir, string connectionString, bool publishToMagento, CancellationToken ct = default)
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
        var publication = new List<PublishedRow>();

        try
        {
            directoryLock = AcquireOutputDirectory(outputDir);
            await RefreshCatalogReviewAsync(connection, organizationId, ct);
            if (publishToMagento) await WithdrawIneligibleWebShopsAsync(connection, organizationId, ct);
            // Od migracije 146 gre v datoteko samo, kar na splet sodi: objavljen izdelek s spletno
            // stranjo, veljaven za to stran (pravilo je v out.GetExportRows in registru profila).
            // Do takrat je izvoz jemal ves katalog podjetja (43.504 vrstic namesto 1.957 pri
            // podjetju 2) — uporabnik 2026-09-02: "v izvozu morajo biti cisti podatki".
            // 251: poleg objavljenih gre v datoteko se odjavna vrstica (prazne »Spletne strani«) za
            // artikel, ki je bil objavljen in ni vec; artikel, ki ni bil nikoli na spletu, ne gre.
            productCount = await RegistryCsvWriter.WriteAsync(productTempPath, productProfile.Columns,
                CapturePublication(
                    ReadExportRowsAsync(connection, productProfile.ExportProfileId, organizationId, productProfile.Columns, onlyPublished: true, ct),
                    productProfile.Columns, publication, ct), ct);
            customerCount = await RegistryCsvWriter.WriteAsync(customerTempPath, customerProfile.Columns,
                ReadExportRowsAsync(connection, customerProfile.ExportProfileId, organizationId, customerProfile.Columns, onlyPublished: true, ct), ct);

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
            if (publishToMagento) await RecordWebPublicationAsync(connection, organizationId, publication, ct);
        }
        catch (Exception exception)
        {
            failure = exception.Message;
            throw;
        }
        finally
        {
            DeleteIfExists(productTempPath);
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
    }

    /// <summary>
    /// En sam profil iz registra v eno datoteko — za hitro osvezitev cen in zaloge
    /// (MAGENTO_STOCK_PRICES, migracija 146), ki tece vsakih pet minut iz Zaloga-cikel.ps1.
    /// Datoteka nastane ob strani in se zamenja sele, ko je cela; bralec nikoli ne vidi
    /// polovicne. Vrne stevilo zapisanih vrstic.
    /// </summary>
    public static async Task<int> ExportProfileAsync(string profileCode, int organizationId, string outputDir, string? fileName, string connectionString, CancellationToken ct = default)
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
            var count = await RegistryCsvWriter.WriteAsync(tempPath, profile.Columns,
                ReadExportRowsAsync(connection, profile.ExportProfileId, organizationId, profile.Columns, onlyPublished: true, ct), ct);
            File.Move(tempPath, targetPath, overwrite: true);
            await ExportRunLog.CompleteAsync(connection, runKey, succeeded: true,
                rowCount: count, columnCount: profile.Columns.Count, filePath: targetPath, ct: CancellationToken.None);
            return count;
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

    /// <summary>Ena vrstica zapisanega katalog.csv za out.WebPublication: sifra in »Spletne strani« (prazno = odjava).</summary>
    internal sealed record PublishedRow(string ItemId, string? WebSites);

    /// <summary>
    /// Vrstice gredo skozi nespremenjene; ob tem si zapomnimo sifro in »Spletne strani« (po kanonicni kodi
    /// stolpca, ne po naslovu v glavi). Brez stolpca sifre profil ne more nositi objave — takrat nic ne zbiramo.
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
        await foreach (var row in rows.WithCancellation(ct))
        {
            if (itemIndex >= 0 && row[itemIndex] is { Length: > 0 } itemId)
                into.Add(new(itemId, sitesIndex >= 0 ? row[sitesIndex] : null));
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

    /// <summary>251: kaj je slo v objavljeni katalog.csv — od tega je odvisno, kdo dobi odjavno vrstico in kdaj izpade.</summary>
    internal static async Task RecordWebPublicationAsync(SqlConnection connection, int organizationId, IReadOnlyList<PublishedRow> rows, CancellationToken ct)
    {
        await using var command = new SqlCommand("out.RecordWebPublication", connection)
        {
            CommandType = CommandType.StoredProcedure,
            CommandTimeout = 300,
        };
        command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
        command.Parameters.Add("@RowsJson", SqlDbType.NVarChar, -1).Value =
            System.Text.Json.JsonSerializer.Serialize(rows.Select(row => new { i = row.ItemId, s = row.WebSites ?? string.Empty }));
        await using var reader = await command.ExecuteReaderAsync(ct);
        if (await reader.ReadAsync(ct))
            Console.WriteLine($"Objava na splet zapisana: {reader.GetInt32(0)} objavljenih, {reader.GetInt32(1)} odjavnih vrstic ({reader.GetInt32(2)} novih odjav).");
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

    /// <summary>Odstrani zacasno datoteko, ce je se ostala. Napake pri ciscenju ne skrijejo prvotne.</summary>
    private static void DeleteIfExists(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
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
