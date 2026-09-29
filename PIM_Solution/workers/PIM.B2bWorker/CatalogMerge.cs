using System.Data;
using System.Text;
using Microsoft.Data.SqlClient;
using PIM.B2b;

namespace PIM.B2bWorker;

/// <summary>
/// 285: katalog.csv iz več podjetij (<c>out.CatalogSource</c>). Uporabnik 2026-09-25: IQ in ViD artikli v eni
/// datoteki brez podvajanj; »Spletne strani« iz kljukic obeh kartic (svetila na IQ + videlektro na ViD =
/// <c>svetila|videlektro</c>), en artikel ena vrstica.
///
/// Vsako podjetje najprej zapiše svoje vrstice po obstoječih pravilih (<c>out.GetExportRows</c>: kljukica,
/// veljavnost, odjavne vrstice 251, cene, zaloga) v svojo začasno datoteko. Tu se samo odloči, katera vrstica
/// gre ven in katere celice se ji zamenjajo — vsebina se ne računa na novo, zato ostane enaka kot doslej.
/// </summary>
internal static class CatalogMerge
{
    /// <summary>Podjetje, ki prispeva vrstice v katalog; manjša <paramref name="Priority"/> ima prednost pri vsebini.</summary>
    /// <param name="WebSiteLabels">
    /// Spletišča, ki jih podjetje sme prispevati (oznake iz »Spletnih strani«); null = vsa. Uporabnik 2026-09-25:
    /// »svetila samo IQ, videlektro oba« — ViD kljukica svetila ne pošlje artikla na svetila.si.
    /// </param>
    internal sealed record Source(int OrganizationId, int Priority, IReadOnlySet<string>? WebSiteLabels = null)
    {
        /// <summary>»Spletne strani« vrstice, omejene na spletišča, ki jih podjetje sme prispevati; null = nobenega.</summary>
        public string? Allowed(string? webSites)
        {
            if (WebSiteLabels is null) return string.IsNullOrWhiteSpace(webSites) ? null : webSites;
            var kept = Labels(webSites).Where(WebSiteLabels.Contains).ToList();
            return kept.Count == 0 ? null : string.Join('|', kept);
        }
    }

    /// <summary>Spletišče, kot ga piše stolpec »Spletne strani« (<c>canon.WebSite.TreeLabel</c>), in njegovi stolpci kategorij.</summary>
    internal sealed record SiteColumns(string Label, int SortOrder, IReadOnlyList<string> CategoryFieldCodes);

    /// <summary>Ena zapisana vrstica podjetja: kje je v začasni datoteki in kar je treba za združevanje.</summary>
    /// <param name="WebSites">Spletišča, ki jih vrstica prispeva (že omejena na dovoljena spletišča podjetja).</param>
    /// <param name="WrittenWebSites">»Spletne strani«, kot so zapisane v začasni datoteki (pred omejitvijo).</param>
    internal sealed record SourceRow(string ItemId, long Offset, int Length, string? WebSites, IReadOnlyDictionary<int, string?> SiteValues,
        string? WrittenWebSites = null)
    {
        public string? WrittenWebSites { get; init; } = WrittenWebSites ?? WebSites;
    }

    /// <summary>Kaj gre v datoteko: vrstica podjetja <paramref name="SourceIndex"/> z zamenjanimi celicami (indeks stolpca → surova vrednost).</summary>
    internal sealed record OutputRow(string ItemId, int SourceIndex, int RowIndex, IReadOnlyDictionary<int, string?> Patches);

    /// <summary>
    /// Register virov za podjetje kataloga. Brez registra (baza pred 285) ali brez vklopljenih vrstic velja samo
    /// podjetje kataloga — natanko kot pred 285.
    /// </summary>
    public static async Task<IReadOnlyList<Source>> LoadSourcesAsync(SqlConnection connection, int catalogOrganizationId, CancellationToken ct)
    {
        const string sql = """
            IF OBJECT_ID(N'out.CatalogSource', N'U') IS NOT NULL
              EXEC sys.sp_executesql
                N'SELECT SourceOrganizationId, Priority, WebSiteLabels FROM out.CatalogSource
                  WHERE CatalogOrganizationId = @Catalog AND IsActive = 1 ORDER BY Priority, SourceOrganizationId;',
                N'@Catalog int', @Catalog = @CatalogOrganizationId;
            """;
        // Poizvedba je v sp_executesql, da se prevede šele, ko tabela obstaja (baza pred 285).
        await using var command = new SqlCommand(sql, connection);
        command.Parameters.Add("@CatalogOrganizationId", SqlDbType.Int).Value = catalogOrganizationId;
        var sources = new List<Source>();
        await using (var reader = await command.ExecuteReaderAsync(ct))
            while (await reader.ReadAsync(ct))
            {
                var labels = reader.IsDBNull(2) ? null : Labels(reader.GetString(2));
                sources.Add(new(reader.GetInt32(0), reader.GetInt32(1),
                    labels is { Count: > 0 } ? labels.ToHashSet(StringComparer.OrdinalIgnoreCase) : null));
            }
        return sources.Count == 0 ? [new(catalogOrganizationId, 0)] : sources;
    }

    /// <summary>
    /// Šifre, ki jih je podjetje v katalogu objavilo in jih še ni umaknilo ali jih je umaknilo pred manj kot
    /// <c>WithdrawalRowDays</c> dnevi (<c>pim.WebPublicationPolicy</c>, 251). Samo za takšen artikel gre vrstica
    /// brez dovoljenega spletišča v datoteko kot odjavna vrstica; artikel, ki ga podjetje ni nikoli objavilo, ne.
    /// </summary>
    /// <param name="allowed">Samo artikli, objavljeni na vsaj enem od teh spletišč (npr. ViD na videlektro).</param>
    public static async Task<IReadOnlySet<string>> LoadRecentPublicationAsync(SqlConnection connection, int organizationId, IReadOnlySet<string> allowed, CancellationToken ct)
    {
        const string sql = """
            SELECT publication.ItemID, publication.WebSites
            FROM out.WebPublication AS publication
            WHERE publication.OrganizationId = @OrganizationId
              AND (publication.WithdrawnUtc IS NULL
                   OR publication.WithdrawnUtc >= DATEADD(day, -ISNULL((SELECT policy.WithdrawalRowDays FROM pim.WebPublicationPolicy AS policy
                                                                      WHERE policy.OrganizationId = @OrganizationId), 14), SYSUTCDATETIME()));
            """;
        await using var command = new SqlCommand(sql, connection);
        command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
        var items = new HashSet<string>(StringComparer.Ordinal);
        await using var reader = await command.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
            if (!reader.IsDBNull(1) && Labels(reader.GetString(1)).Any(allowed.Contains))
                items.Add(reader.GetString(0));
        return items;
    }

    /// <summary>Aktivna spletišča in stolpci kategorij, ki jih vsako polni (<c>canon.WebSite.CategoryFieldCode</c>).</summary>
    public static async Task<IReadOnlyList<SiteColumns>> LoadSitesAsync(SqlConnection connection, CancellationToken ct)
    {
        await using var command = new SqlCommand(
            "SELECT TreeLabel, SortOrder, CategoryFieldCode FROM canon.WebSite WHERE IsActive = 1 AND NULLIF(TreeLabel, N'') IS NOT NULL;", connection);
        var rows = new List<(string Label, int Sort, string? Field)>();
        await using (var reader = await command.ExecuteReaderAsync(ct))
            while (await reader.ReadAsync(ct))
                rows.Add((reader.GetString(0), reader.GetInt32(1), reader.IsDBNull(2) ? null : reader.GetString(2)));
        return rows
            .GroupBy(row => row.Label, StringComparer.OrdinalIgnoreCase)
            .Select(group => new SiteColumns(group.Key, group.Min(row => row.Sort),
                group.Where(row => row.Field is { Length: > 0 }).Select(row => row.Field!).Distinct(StringComparer.Ordinal).ToList()))
            .OrderBy(site => site.SortOrder).ThenBy(site => site.Label, StringComparer.Ordinal)
            .ToList();
    }

    /// <summary>Oznake spletišč iz »Spletnih strani« (<c>svetila|videlektro</c>); prazno = odjavna vrstica.</summary>
    public static IReadOnlyList<string> Labels(string? webSites) =>
        string.IsNullOrWhiteSpace(webSites) ? [] : webSites.Split('|', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

    /// <summary>
    /// Načrt datoteke. Vrstni red: vrstice prvega podjetja, kot jih je zapisalo, nato vrstice naslednjih, ki jih
    /// prejšnja nimajo. Za vsako šifro:
    ///   - vsebina iz podjetja z najvišjo prednostjo, ki artikel objavlja (ima spletišča); če ga ne objavlja nobeno,
    ///     iz prvega (odjavna vrstica 251);
    ///   - »Spletne strani« = unija spletišč vseh podjetij, po vrstnem redu spletišč;
    ///   - kategorije spletišča, ki ga vsebinsko podjetje ne objavlja, iz podjetja, ki ga objavlja.
    /// Zadržanja varovalke (277) so po podjetju: zadržan artikel podjetja vsebine ne gre v datoteko (Magento ga pusti,
    /// kot je bil); zadržanje drugega podjetja mu odvzame samo njegov prispevek.
    /// </summary>
    /// <param name="rows">Vrstice po podjetjih, v vrstnem redu <paramref name="sources"/>.</param>
    /// <param name="held">Zadržane šifre po podjetjih (isti vrstni red).</param>
    /// <param name="sitesIndex">Indeks stolpca »Spletne strani«.</param>
    /// <param name="categoryIndex">Indeksi stolpcev kategorij po oznaki spletišča.</param>
    public static IReadOnlyList<OutputRow> Plan(
        IReadOnlyList<IReadOnlyList<SourceRow>> rows,
        IReadOnlyList<IReadOnlySet<string>> held,
        IReadOnlyList<SiteColumns> sites,
        int sitesIndex,
        IReadOnlyDictionary<string, IReadOnlyList<int>> categoryIndex)
    {
        var bySource = rows.Select(list =>
        {
            var map = new Dictionary<string, int>(StringComparer.Ordinal);
            for (var index = 0; index < list.Count; index++) map.TryAdd(list[index].ItemId, index);
            return map;
        }).ToList();
        var order = sites.Select((site, index) => (site.Label, index)).ToDictionary(pair => pair.Label, pair => pair.index, StringComparer.OrdinalIgnoreCase);

        var seen = new HashSet<string>(StringComparer.Ordinal);
        var output = new List<OutputRow>();
        for (var source = 0; source < rows.Count; source++)
        {
            foreach (var first in rows[source])
            {
                if (!seen.Add(first.ItemId)) continue;

                // Vse vrstice te šifre po prednosti.
                var candidates = new List<(int Source, int Row, SourceRow Data)>();
                for (var other = 0; other < rows.Count; other++)
                    if (bySource[other].TryGetValue(first.ItemId, out var rowIndex))
                        candidates.Add((other, rowIndex, rows[other][rowIndex]));

                var content = candidates.FirstOrDefault(candidate => Labels(candidate.Data.WebSites).Count > 0);
                if (content.Data is null) content = candidates[0];
                if (held[content.Source].Contains(first.ItemId)) continue;

                var contributors = candidates.Where(candidate => !held[candidate.Source].Contains(first.ItemId)).ToList();
                var ownLabels = new HashSet<string>(Labels(content.Data.WebSites), StringComparer.OrdinalIgnoreCase);
                var union = contributors
                    .SelectMany(candidate => Labels(candidate.Data.WebSites))
                    .Distinct(StringComparer.OrdinalIgnoreCase)
                    .OrderBy(label => order.TryGetValue(label, out var position) ? position : int.MaxValue)
                    .ThenBy(label => label, StringComparer.Ordinal)
                    .ToList();

                var patches = new Dictionary<int, string?>();
                var merged = union.Count == 0 ? null : string.Join('|', union);
                if (sitesIndex >= 0 && !string.Equals(merged ?? "", content.Data.WrittenWebSites ?? "", StringComparison.Ordinal))
                    patches[sitesIndex] = merged;
                foreach (var label in union.Where(label => !ownLabels.Contains(label)))
                {
                    if (!categoryIndex.TryGetValue(label, out var columns)) continue;
                    var provider = contributors.First(candidate => Labels(candidate.Data.WebSites).Contains(label, StringComparer.OrdinalIgnoreCase));
                    foreach (var column in columns)
                        patches[column] = provider.Data.SiteValues.TryGetValue(column, out var value) ? value : null;
                }
                output.Add(new(first.ItemId, content.Source, content.Row, patches));
            }
        }
        return output;
    }

    /// <summary>Kaj je vsako podjetje prispevalo v datoteko — za zapis objave (251) po podjetju.</summary>
    /// <returns>Po podjetjih: šifre, katerih vrstica tega podjetja je v datoteki upoštevana (vsebina ali spletišče).</returns>
    public static IReadOnlyList<IReadOnlySet<string>> Contributed(
        IReadOnlyList<IReadOnlyList<SourceRow>> rows, IReadOnlyList<IReadOnlySet<string>> held, IReadOnlyList<OutputRow> plan)
    {
        var inFile = plan.Select(row => row.ItemId).ToHashSet(StringComparer.Ordinal);
        return rows.Select((list, source) => (IReadOnlySet<string>)list
            .Select(row => row.ItemId)
            .Where(item => inFile.Contains(item) && !held[source].Contains(item))
            .ToHashSet(StringComparer.Ordinal)).ToList();
    }

    /// <summary>
    /// Razbije zapisano vrstico CSV na celice, kot jih je zapisal <see cref="RegistryCsvWriter"/> (RFC 4180:
    /// v narekovajih samo celica z ločilom, narekovajem ali koncem vrstice). Celica ostane, kot je zapisana (z narekovaji).
    /// </summary>
    public static List<string> SplitRecord(string record, char delimiter)
    {
        var line = record.EndsWith('\n') ? record[..^1] : record;
        var cells = new List<string>();
        var start = 0;
        var quoted = false;
        for (var index = 0; index < line.Length; index++)
        {
            var character = line[index];
            if (character == '"') quoted = !quoted;
            else if (character == delimiter && !quoted)
            {
                cells.Add(line[start..index]);
                start = index + 1;
            }
        }
        cells.Add(line[start..]);
        return cells;
    }

    /// <summary>
    /// Sestavi datoteko po načrtu. Vrstica brez zamenjav se prenese bajt za bajtom; pri vrstici z zamenjavami se
    /// zamenjajo samo tiste celice, zapisane z isto obliko (ločilo, decimalna vejica, narekovaji) kot vse ostale.
    /// </summary>
    /// <param name="recordWritten">Šifra, odmik in dolžina vsake vrstice v novi datoteki.</param>
    /// <returns>Število vrstic brez glave.</returns>
    public static async Task<int> WriteAsync(
        string targetPath,
        IReadOnlyList<string> sourcePaths,
        IReadOnlyList<IReadOnlyList<SourceRow>> rows,
        IReadOnlyList<OutputRow> plan,
        IReadOnlyList<ExportColumnDefinition> orderedColumns,
        char delimiter,
        Action<string, long, int>? recordWritten,
        CancellationToken ct)
    {
        var encoding = new UTF8Encoding(false);
        var sources = sourcePaths.Select(path => new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 65536)).ToList();
        try
        {
            await using var target = new FileStream(targetPath, FileMode.Create, FileAccess.Write, FileShare.None, 65536);
            // Glava je v vseh datotekah ista (isti profil); vzamemo jo iz prve.
            var headerLength = rows[0].Count > 0 ? rows[0][0].Offset : sources[0].Length;
            await CopyAsync(sources[0], target, 0, headerLength, ct);
            var written = 0;
            foreach (var row in plan)
            {
                var data = rows[row.SourceIndex][row.RowIndex];
                var offset = target.Position;
                if (row.Patches.Count == 0)
                {
                    await CopyAsync(sources[row.SourceIndex], target, data.Offset, data.Length, ct);
                    recordWritten?.Invoke(row.ItemId, offset, data.Length);
                }
                else
                {
                    var buffer = new byte[data.Length];
                    sources[row.SourceIndex].Position = data.Offset;
                    await sources[row.SourceIndex].ReadExactlyAsync(buffer, ct);
                    var cells = SplitRecord(encoding.GetString(buffer), delimiter);
                    if (cells.Count != orderedColumns.Count)
                        throw new ExportContractException($"Vrstica {row.ItemId} ima {cells.Count} celic, izvozni profil pa {orderedColumns.Count} stolpcev.");
                    foreach (var (column, value) in row.Patches)
                        cells[column] = RegistryCsvWriter.Escape(ExportValueFormat.Apply(orderedColumns[column], value), delimiter);
                    var bytes = encoding.GetBytes(string.Join(delimiter, cells) + "\n");
                    await target.WriteAsync(bytes, ct);
                    recordWritten?.Invoke(row.ItemId, offset, bytes.Length);
                }
                written++;
            }
            return written;
        }
        finally
        {
            foreach (var source in sources) await source.DisposeAsync();
        }
    }

    static async Task CopyAsync(Stream source, Stream target, long offset, long length, CancellationToken ct)
    {
        source.Position = offset;
        var buffer = new byte[65536];
        while (length > 0)
        {
            var read = await source.ReadAsync(buffer.AsMemory(0, (int)Math.Min(buffer.Length, length)), ct);
            if (read == 0) throw new EndOfStreamException("Začasna izvozna datoteka je krajša, kot je bila zapisana.");
            await target.WriteAsync(buffer.AsMemory(0, read), ct);
            length -= read;
        }
    }
}
