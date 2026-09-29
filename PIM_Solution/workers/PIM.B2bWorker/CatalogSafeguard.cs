using System.Data;
using System.Text;
using System.Text.Json;
using Microsoft.Data.SqlClient;

namespace PIM.B2bWorker;

/// <summary>
/// Izid varovalke katalog.csv (migracija 277, <c>ops.EvaluateCatalogSafeguards</c>).
/// </summary>
/// <param name="Status">CLEAN, WARNED, WAITING (so zadržani artikli) ali NOT_RUN (varovalka ni tekla).</param>
/// <param name="Headline">Povzetek, npr. »zadržanih artiklov: 3 (cena ×10/×100: 1, prazna cena: 2)«.</param>
/// <param name="HeldItems">Šifre artiklov, ki NE gredo v objavljeno datoteko, dokler jih nekdo ne potrdi.</param>
internal sealed record CatalogSafeguardDecision(
    long? CheckId, string Status, int FindingCount, int ConfirmCount, string? Headline, IReadOnlyList<string> HeldItems, string? Error)
{
    public static CatalogSafeguardDecision NotRun(string reason) => new(null, "NOT_RUN", 0, 0, null, [], reason);

    /// <summary>En stavek za fazo DATOTEKA, konzolo in sled izvoza.</summary>
    public string Describe() => Status switch
    {
        "WAITING" => $"varovalka: {Headline} — zadržani artikli niso v datoteki in čakajo potrditev na /varovalke",
        "WARNED" => $"varovalka: objavljeno z opozorili ({Headline})",
        "CLEAN" => "varovalka: brez ugotovitev",
        _ => $"varovalka ni tekla ({Error}); datoteka objavljena brez preverjanja",
    };
}

/// <summary>
/// Varovalka katalog.csv (277): pred zamenjavo datotek primerja pravkar zapisani katalog z zadnjo objavo —
/// cene (izgubljena vejica ×10/×100, 0, prazna, velik skok, neveljavno število), umike s spleta z razlogom
/// in nove kljukice, ki ne gredo na splet. Pravila in pragovi so v <c>ops.SafeguardRule</c>.
///
/// Uporabnik 2026-09-24: »če ima en artikel prazno polje, se ostali pojavijo v CSV, ta pa ne sme biti v CSV in
/// mora čakati odobritev«. Zato sumljiv artikel ne gre v objavljeno datoteko (Magento ga pusti, kot je bil;
/// nov artikel na splet ne pride), vsi ostali gredo ven kot vedno. Posel nikoli ne pade zaradi varovalke.
/// </summary>
internal static class CatalogSafeguard
{
    /// <summary>
    /// Vrstice za varovalko in zapis objave: <c>[{"i":"šifra","s":"svetila|videlektro","v":{"Product.PriceB2B":"13.02"}}]</c>.
    /// Cene so v strojni obliki s piko, kot jih vrne <c>out.GetExportRows</c> — vejico doda šele zapis datoteke.
    /// </summary>
    public static string RowsJson(IEnumerable<MagentoExportCommand.PublishedRow> rows)
    {
        using var buffer = new MemoryStream();
        using (var json = new Utf8JsonWriter(buffer))
        {
            json.WriteStartArray();
            foreach (var row in rows)
            {
                json.WriteStartObject();
                json.WriteString("i", row.ItemId);
                json.WriteString("s", row.WebSites ?? string.Empty);
                if (row.Guarded is { Count: > 0 } guarded)
                {
                    json.WriteStartObject("v");
                    foreach (var (field, value) in guarded)
                    {
                        if (value is null) json.WriteNull(field);
                        else json.WriteString(field, value);
                    }
                    json.WriteEndObject();
                }
                json.WriteEndObject();
            }
            json.WriteEndArray();
        }
        return Encoding.UTF8.GetString(buffer.ToArray());
    }

    /// <summary>
    /// Preverjanje pred objavo. Napaka varovalke dostave ne ustavi: datoteka gre ven kot pred 277, v zvoncu pa
    /// ostane opozorilo, da ni bila preverjena — tiho brez varovalke ne sme ostati.
    /// </summary>
    public static async Task<CatalogSafeguardDecision> EvaluateAsync(
        SqlConnection connection, int organizationId, string rowsJson, int rowCount, Guid? exportRunKey, CancellationToken ct)
    {
        try
        {
            await using var command = new SqlCommand("ops.EvaluateCatalogSafeguards", connection)
            {
                CommandType = CommandType.StoredProcedure,
                // Izmerjeno 2026-09-24 na DAVID\MSSQL19 (podjetje 2, 2.569 vrstic): ~7 s ob prvem klicu.
                CommandTimeout = 600,
            };
            command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
            command.Parameters.Add("@RowsJson", SqlDbType.NVarChar, -1).Value = rowsJson;
            command.Parameters.Add("@RowCount", SqlDbType.Int).Value = rowCount;
            command.Parameters.Add("@ExportRunKey", SqlDbType.UniqueIdentifier).Value = (object?)exportRunKey ?? DBNull.Value;
            command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = "PIM.B2bWorker";
            await using var reader = await command.ExecuteReaderAsync(ct);
            if (!await reader.ReadAsync(ct)) return CatalogSafeguardDecision.NotRun("varovalka ni vrnila izida");
            var checkId = reader.GetInt64(0);
            var status = reader.GetString(1);
            var findingCount = reader.GetInt32(2);
            var confirmCount = reader.GetInt32(3);
            var headline = reader.IsDBNull(4) ? null : reader.GetString(4);
            var held = new List<string>();
            if (await reader.NextResultAsync(ct))
                while (await reader.ReadAsync(ct))
                    held.Add(reader.GetString(0));
            return new CatalogSafeguardDecision(checkId, status, findingCount, confirmCount, headline, held, null);
        }
        catch (SqlException exception) when (!ct.IsCancellationRequested)
        {
            var reason = exception.Number == 2812
                ? "varovalka ni nameščena (migracija 277 še ni uveljavljena)"
                : $"napaka {exception.Number}: {exception.Message}";
            Console.Error.WriteLine($"Opozorilo: varovalka katalog.csv ni tekla ({reason}); datoteka se objavi brez preverjanja.");
            if (exception.Number != 2812) await TryRaiseFailureAlertAsync(connection, organizationId, reason);
            return CatalogSafeguardDecision.NotRun(reason);
        }
    }

    /// <summary>
    /// Po uspešni zamenjavi: objavljene cene postanejo izhodišče naslednje primerjave. Zadržani artikli obdržijo
    /// prejšnje izhodišče in stanje objave — v datoteki jih ni bilo.
    /// </summary>
    public static async Task RecordPublicationAsync(
        SqlConnection connection, int organizationId, string publishedRowsJson, long? checkId, IReadOnlyCollection<string> heldItems, CancellationToken ct)
    {
        try
        {
            await using var command = new SqlCommand("out.RecordCatalogPublication", connection)
            {
                CommandType = CommandType.StoredProcedure,
                CommandTimeout = 300,
            };
            command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
            command.Parameters.Add("@RowsJson", SqlDbType.NVarChar, -1).Value = publishedRowsJson;
            command.Parameters.Add("@SafeguardCheckId", SqlDbType.BigInt).Value = (object?)checkId ?? DBNull.Value;
            command.Parameters.Add("@HeldItemsJson", SqlDbType.NVarChar, -1).Value =
                heldItems.Count == 0 ? DBNull.Value : JsonSerializer.Serialize(heldItems);
            await command.ExecuteNonQueryAsync(ct);
        }
        catch (SqlException exception) when (exception.Number == 2812)
        {
            // Baza pred 277: ni česa zapisati.
        }
    }

    /// <summary>
    /// 282: varovalka datoteke cen in zaloge (MAGENTO_STOCK_PRICES) — cene in padec zaloge glede na zadnjo objavo.
    /// Enak dogovor kot pri katalog.csv: zadržani artikli ne gredo v datoteko, napaka varovalke objave ne ustavi.
    /// </summary>
    public static async Task<CatalogSafeguardDecision> EvaluateStockPriceAsync(
        SqlConnection connection, string profileCode, int organizationId, string rowsJson, int rowCount, CancellationToken ct)
    {
        try
        {
            await using var command = new SqlCommand("ops.EvaluateStockPriceSafeguards", connection)
            {
                CommandType = CommandType.StoredProcedure,
                CommandTimeout = 300,
            };
            command.Parameters.Add("@ProfileCode", SqlDbType.NVarChar, 100).Value = profileCode;
            command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
            command.Parameters.Add("@RowsJson", SqlDbType.NVarChar, -1).Value = rowsJson;
            command.Parameters.Add("@RowCount", SqlDbType.Int).Value = rowCount;
            command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = "PIM.B2bWorker";
            await using var reader = await command.ExecuteReaderAsync(ct);
            if (!await reader.ReadAsync(ct)) return CatalogSafeguardDecision.NotRun("varovalka ni vrnila izida");
            var checkId = reader.GetInt64(0);
            var status = reader.GetString(1);
            var findingCount = reader.GetInt32(2);
            var confirmCount = reader.GetInt32(3);
            var headline = reader.IsDBNull(4) ? null : reader.GetString(4);
            var held = new List<string>();
            if (await reader.NextResultAsync(ct))
                while (await reader.ReadAsync(ct))
                    held.Add(reader.GetString(0));
            return new CatalogSafeguardDecision(checkId, status, findingCount, confirmCount, headline, held, null);
        }
        catch (SqlException exception) when (!ct.IsCancellationRequested)
        {
            var reason = exception.Number == 2812
                ? "varovalka ni nameščena (migracija 282 še ni uveljavljena)"
                : $"napaka {exception.Number}: {exception.Message}";
            Console.Error.WriteLine($"Opozorilo: varovalka cen in zaloge ni tekla ({reason}); datoteka se objavi brez preverjanja.");
            if (exception.Number != 2812)
                await TryRaiseFailureAlertAsync(connection, organizationId, reason, "VAROVALKA:ZALOGA_CSV", $"safeguard-error-zaloga-{organizationId}",
                    "Varovalka cen in zaloge ni tekla — datoteka je šla na splet brez preverjanja");
            return CatalogSafeguardDecision.NotRun(reason);
        }
    }

    /// <summary>282: objavljene vrednosti datoteke cen in zaloge postanejo izhodišče; zadržani obdržijo prejšnje.</summary>
    public static async Task RecordExportPublicationAsync(
        SqlConnection connection, string profileCode, int organizationId, string publishedRowsJson, long? checkId,
        IReadOnlyCollection<string> heldItems, CancellationToken ct)
    {
        try
        {
            await using var command = new SqlCommand("out.RecordExportPublication", connection)
            {
                CommandType = CommandType.StoredProcedure,
                CommandTimeout = 300,
            };
            command.Parameters.Add("@ProfileCode", SqlDbType.NVarChar, 100).Value = profileCode;
            command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
            command.Parameters.Add("@RowsJson", SqlDbType.NVarChar, -1).Value = publishedRowsJson;
            command.Parameters.Add("@SafeguardCheckId", SqlDbType.BigInt).Value = (object?)checkId ?? DBNull.Value;
            command.Parameters.Add("@HeldItemsJson", SqlDbType.NVarChar, -1).Value =
                heldItems.Count == 0 ? DBNull.Value : JsonSerializer.Serialize(heldItems);
            await command.ExecuteNonQueryAsync(ct);
        }
        catch (SqlException exception) when (exception.Number == 2812)
        {
            // Baza pred 282: ni česa zapisati.
        }
    }

    static Task TryRaiseFailureAlertAsync(SqlConnection connection, int organizationId, string reason) =>
        TryRaiseFailureAlertAsync(connection, organizationId, reason, "VAROVALKA:KATALOG_CSV", $"safeguard-error-katalog-{organizationId}",
            "Varovalka katalog.csv ni tekla — datoteka je šla na splet brez preverjanja");

    static async Task TryRaiseFailureAlertAsync(SqlConnection connection, int organizationId, string reason, string pipeline, string dedupKey, string title)
    {
        try
        {
            await using var command = new SqlCommand("ops.UpsertAlert", connection) { CommandType = CommandType.StoredProcedure, CommandTimeout = 30 };
            command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
            command.Parameters.Add("@Pipeline", SqlDbType.NVarChar, 100).Value = pipeline;
            command.Parameters.Add("@AlertKind", SqlDbType.NVarChar, 50).Value = "SafeguardPending";
            command.Parameters.Add("@Severity", SqlDbType.NVarChar, 20).Value = "Warning";
            command.Parameters.Add("@DedupKey", SqlDbType.VarChar, 64).Value = dedupKey;
            command.Parameters.Add("@Title", SqlDbType.NVarChar, 300).Value = title;
            command.Parameters.Add("@PayloadSummaryRedacted", SqlDbType.NVarChar, 2000).Value = reason.Length <= 2000 ? reason : reason[..2000];
            command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = "PIM.B2bWorker";
            await command.ExecuteNonQueryAsync(CancellationToken.None);
        }
        catch (SqlException)
        {
            // Opozorilo je dodatek; če ga ni mogoče zapisati, ostane izpis v dnevniku posla.
        }
    }
}
