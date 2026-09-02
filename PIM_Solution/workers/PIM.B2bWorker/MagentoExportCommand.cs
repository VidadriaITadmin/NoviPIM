using System.Data;
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

    /// <summary>
    /// Ime procedure, ki iz tabel sestavi vrstice po izvoznem registru (migracija 142).
    /// Isto proceduro bere intranet, zato datoteka na spletu in predogled v intranetu
    /// ne moreta pokazati razlicne vsebine.
    /// </summary>
    internal const string ExportRowsProcedure = "out.GetExportRows";

    public static async Task ExecuteAsync(int organizationId, string outputDir, string connectionString, CancellationToken ct = default)
    {
        if (organizationId <= 0) throw new ArgumentOutOfRangeException(nameof(organizationId), "OrganizationId mora biti pozitivno celo število.");
        ArgumentException.ThrowIfNullOrWhiteSpace(outputDir, nameof(outputDir));
        if (string.IsNullOrWhiteSpace(connectionString))
            throw new InvalidOperationException("Manjka PIM_CONNECTION_STRING. Nastavite okoljsko spremenljivko PIM_CONNECTION_STRING.");

        Directory.CreateDirectory(outputDir);

        await using var connection = new SqlConnection(connectionString);
        await connection.OpenAsync(ct);

        // Datoteki sta par in ju Magento uvozi skupaj. Zato obe najprej zapisemo ob stran,
        // sele nato prestavimo na koncni imeni. Ce pade poizvedba za stranke ali pisanje druge
        // datoteke, v izhodni mapi ne nastane nov magento-products.csv poleg stare ali
        // manjkajoce magento-customers.csv - torej ni polovicnega izvoza.
        // Obliko preberemo pred podatki: manjkajoč ali izklopljen profil je napaka
        // konfiguracije in mora pasti, preden se karkoli zapiše v izhodno mapo.
        var productProfile = await ExportProfileRegistry.LoadProfileAsync(connection, MagentoProductSchema.ProfileCode, ct);
        var customerProfile = await ExportProfileRegistry.LoadProfileAsync(connection, MagentoCustomerSchema.ProfileCode, ct);

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
            // Izdelki nimajo filtra objave: izvoz za Magento je od nekdaj jemal ves katalog
            // podjetja. Stranke ga imajo — brez WebEnabled stranka na splet ne sodi.
            var productCount = await RegistryCsvWriter.WriteAsync(productTempPath, productProfile.Columns,
                ReadExportRowsAsync(connection, productProfile.ExportProfileId, organizationId, onlyPublished: false, ct), ct);
            var customerCount = await RegistryCsvWriter.WriteAsync(customerTempPath, customerProfile.Columns,
                ReadExportRowsAsync(connection, customerProfile.ExportProfileId, organizationId, onlyPublished: true, ct), ct);

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
                    $"{runId}\n{DateTime.UtcNow:O}\nizdelki={productCount}\nstranke={customerCount}\n",
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

    /// <summary>
    /// Vrstice izvoza, kot jih po registru sestavi <see cref="ExportRowsProcedure"/>.
    ///
    /// Do migracije 142 je bilo tu osem poizvedb nad <c>pim.*</c> in <c>b2b.*</c> ter
    /// sestavljanje slovarja kanonicnih vrednosti v pomnilniku. Zdaj je vse to v bazi:
    /// katera vrednost pride v kateri stolpec, pove <c>out.ExportColumn</c>, kako nastane,
    /// pa procedura. Tu ostane samo prenos — vrednost na mestu <c>i</c> pripada stolpcu
    /// na mestu <c>i</c>, ker sta oba urejena po istem <c>SortOrder</c>.
    ///
    /// Vrstice tecejo skozi in ne nastanejo vse hkrati v pomnilniku; zato je bralnik
    /// <c>SequentialAccess</c> in vrednosti beremo po vrsti.
    /// </summary>
    /// <param name="onlyPublished">
    /// Pri izdelkih <c>false</c>: izvoz za Magento je od nekdaj jemal ves katalog podjetja
    /// in filter objave bi tiho spremenil vsebino datoteke, ki ze odhaja. Pri strankah
    /// <c>true</c>: stranka brez <c>WebEnabled</c> na splet ne sodi.
    /// </param>
    private static async IAsyncEnumerable<IReadOnlyList<string?>> ReadExportRowsAsync(
        SqlConnection connection,
        int exportProfileId,
        int organizationId,
        bool onlyPublished,
        [EnumeratorCancellation] CancellationToken ct)
    {
        await using var command = new SqlCommand(ExportRowsProcedure, connection)
        {
            CommandType = CommandType.StoredProcedure,
            // Cel katalog je lahko vec deset tisoc vrstic; privzetih 30 sekund ne zadosca.
            CommandTimeout = 600,
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

        await using var reader = await command.ExecuteReaderAsync(CommandBehavior.SequentialAccess, ct);
        while (await reader.ReadAsync(ct))
        {
            var values = new string?[reader.FieldCount];
            for (var index = 0; index < values.Length; index++)
                values[index] = await reader.IsDBNullAsync(index, ct) ? null : reader.GetString(index);
            yield return values;
        }
    }
}
