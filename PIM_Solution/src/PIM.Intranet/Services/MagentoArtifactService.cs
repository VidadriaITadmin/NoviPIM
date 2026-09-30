using System.Globalization;
using System.Text;
using Microsoft.Data.SqlClient;
using Microsoft.VisualBasic.FileIO;
using PIM.Automation;
using PIM.Operations;

namespace PIM.Intranet.Services;

public sealed record MagentoArtifact(string FileName, DateTime PublishedUtc, long Bytes, string Generation);
public sealed record MagentoArtifactPage(MagentoArtifact Artifact, WebExportPage Page, int FileRows);

/// <summary>
/// Izhodna mapa, kot jo vidi TA proces intraneta (242). Worker, ki datoteki izdela, teče pod računom
/// gostitelja avtomatike (storitev PIM.AutomationHost), zato »zapisljiva« tu pove samo, ali bi vanjo lahko
/// pisal intranet; za račun gostitelja pove napaka zadnjega poskusa v out.ExportRun.
/// </summary>
/// <param name="Source">Od kod pot: okolje PIM_EXPORT_ROOT, register ops.SystemPath (EXPORT_ROOT) ali vgrajeni privzetek.</param>
public sealed record MagentoOutputFolder(string Root, string Source, bool Exists, bool WritableByThisProcess, string Account, bool HasCompletePair);

/// <summary>Podjetje, iz katerega se sestavlja katalog.csv (out.CatalogSource, 285), v vrstnem redu prednosti.</summary>
/// <param name="WebSiteLabels">Spletišča, ki jih vir sme prispevati; null = vsa.</param>
public sealed record MagentoCatalogSource(int OrganizationId, string Name, int Priority, string? WebSiteLabels, string? Note);

/// <summary>Urnik posla, ki izdela katalog.csv in stranke.csv (ops.JobDefinition), kot ga vidi stran /splet.</summary>
/// <param name="SlaSeconds">Meja svežine, ki jo uporablja tudi Nadzor; datoteka, starejša od nje, je »stara«.</param>
/// <param name="RequestedRunUtc">Oddana ročna zahteva, ki je gostitelj še ni prevzel.</param>
public sealed record MagentoCatalogJob(bool IsEnabled, int? IntervalSeconds, int? SlaSeconds, DateTime? NextDueUtc, DateTime? RequestedRunUtc, bool IsRunning);

/// <summary>Bere izdelani CSV. Predogled nikoli ne sestavlja nove vsebine iz baze.</summary>
public sealed class MagentoArtifactService(IConfiguration configuration)
{
  /// <summary>
  /// Urnik posla WEB_CATALOG_EXPORT (#25): stran meri starost datoteke po meji svežine posla (SlaSeconds),
  /// ne po vpisani konstanti — prej je čip »starejša od 30 minut« gorel ob urnem razmiku brez napake.
  /// Samo branje; null, če posla (še) ni v bazi.
  /// </summary>
  public async Task<MagentoCatalogJob?> CatalogJobAsync(CancellationToken ct = default)
  {
    await using var connection = new SqlConnection(ConnectionStringResolver.Resolve(configuration)
      ?? throw new InvalidOperationException("Povezava PIM ni nastavljena."));
    await connection.OpenAsync(ct);
    await using var command = new SqlCommand("""
      IF OBJECT_ID(N'ops.JobDefinition', N'U') IS NOT NULL
        SELECT IsEnabled, IntervalSeconds, SlaSeconds, NextDueUtc, RequestedRunUtc, CAST(CASE WHEN RunningJobRunId IS NULL THEN 0 ELSE 1 END AS bit)
        FROM ops.JobDefinition WHERE JobKey = @JobKey;
      """, connection);
    command.Parameters.Add("@JobKey", System.Data.SqlDbType.NVarChar, 100).Value = JobCatalog.WebCatalogExport;
    await using var reader = await command.ExecuteReaderAsync(ct);
    if (!await reader.ReadAsync(ct)) return null;
    return new(reader.GetBoolean(0), reader.IsDBNull(1) ? null : reader.GetInt32(1), reader.IsDBNull(2) ? null : reader.GetInt32(2),
      reader.IsDBNull(3) ? null : DateTime.SpecifyKind(reader.GetDateTime(3), DateTimeKind.Utc),
      reader.IsDBNull(4) ? null : DateTime.SpecifyKind(reader.GetDateTime(4), DateTimeKind.Utc), reader.GetBoolean(5));
  }

  /// <summary>
  /// Podjetja, ki skupaj sestavljajo katalog.csv (#25): od 285 datoteka ni več samo IQ, zato pregled na /splet
  /// razloge kaže po podjetju. Brez tabele (baza pred 285) je vir samo podjetje kataloga.
  /// </summary>
  public async Task<IReadOnlyList<MagentoCatalogSource>> CatalogSourcesAsync(CancellationToken ct = default)
  {
    await using var connection = new SqlConnection(ConnectionStringResolver.Resolve(configuration)
      ?? throw new InvalidOperationException("Povezava PIM ni nastavljena."));
    await connection.OpenAsync(ct);
    await using var command = new SqlCommand("""
      IF OBJECT_ID(N'out.CatalogSource', N'U') IS NULL
        SELECT o.OrganizationId, o.Name, CAST(10 AS int) AS Priority, CAST(NULL AS nvarchar(400)) AS WebSiteLabels, CAST(NULL AS nvarchar(400)) AS Note
        FROM dbo.OrganizationConfig o WHERE o.OrganizationId = @Catalog;
      ELSE
        SELECT s.SourceOrganizationId AS OrganizationId, o.Name, s.Priority, s.WebSiteLabels, s.Note
        FROM out.CatalogSource s
        INNER JOIN dbo.OrganizationConfig o ON o.OrganizationId = s.SourceOrganizationId
        WHERE s.CatalogOrganizationId = @Catalog AND s.IsActive = 1 AND o.IsActive = 1
        ORDER BY s.Priority;
      """, connection);
    command.Parameters.Add("@Catalog", System.Data.SqlDbType.Int).Value = WorkerCycles.CatalogOrganization;
    var result = new List<MagentoCatalogSource>();
    await using var reader = await command.ExecuteReaderAsync(ct);
    while (await reader.ReadAsync(ct))
      result.Add(new(reader.GetInt32(0), reader.GetString(1), reader.GetInt32(2),
        reader.IsDBNull(3) ? null : reader.GetString(3), reader.IsDBNull(4) ? null : reader.GetString(4)));
    return result;
  }

  public static string FileName(string profile) => profile switch
  {
    "MAGENTO_PRODUCTS" => "katalog.csv",
    "MAGENTO_CUSTOMERS" => "stranke.csv",
    _ => throw new ArgumentException("Neznana datoteka Magento."),
  };

  /// <summary>Isti vrstni red kot PIM.B2bWorker (Program.cs) in gostitelj avtomatike PIM.AutomationHost (AutomationEnvironment): okolje, register, privzetek.</summary>
  async Task<(string Root, string Source)> ResolveRootAsync(CancellationToken ct)
  {
    var root = Environment.GetEnvironmentVariable("PIM_EXPORT_ROOT");
    if (!string.IsNullOrWhiteSpace(root)) return (root, "okolje PIM_EXPORT_ROOT");
    await using var connection = new SqlConnection(ConnectionStringResolver.Resolve(configuration)
      ?? throw new InvalidOperationException("Povezava PIM ni nastavljena."));
    await connection.OpenAsync(ct);
    root = await SystemPaths.ResolveAsync(connection, SystemPaths.Export, WorkerCycles.CatalogOrganization, ct);
    if (!string.IsNullOrWhiteSpace(root)) return (root, "register ops.SystemPath (EXPORT_ROOT)");
    root = Path.Combine(LocalSettings.FindSolutionRoot(AppContext.BaseDirectory)
      ?? Directory.GetCurrentDirectory(), "izvoz", "magento", WorkerCycles.CatalogOrganization.ToString(CultureInfo.InvariantCulture));
    return (root, "vgrajeni privzetek (EXPORT_ROOT ni nastavljen)");
  }

  /// <summary>Kam gre izvoz in ali bi ta proces lahko pisal vanjo — da stran /splet pove vzrok, preden pade prvi tek.</summary>
  public async Task<MagentoOutputFolder> FolderAsync(CancellationToken ct = default)
  {
    var (root, source) = await ResolveRootAsync(ct);
    var exists = Directory.Exists(root);
    var writable = false;
    if (exists)
    {
      var probe = Path.Combine(root, $".pim-probe-{Guid.NewGuid():N}");
      try { File.WriteAllText(probe, ""); File.Delete(probe); writable = true; }
      catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { writable = false; }
    }
    return new(root, source, exists, writable, $"{Environment.UserDomainName}\\{Environment.UserName}",
      exists && File.Exists(Path.Combine(root, "magento-export.complete")));
  }

  public async Task<(FileStream Stream, MagentoArtifact Artifact)> OpenAsync(string profile, CancellationToken ct = default)
  {
    var fileName = FileName(profile);
    var (root, _) = await ResolveRootAsync(ct);
    var marker = Path.Combine(root, "magento-export.complete");
    if (!File.Exists(marker))
      throw new InvalidOperationException("Dokončan par CSV ni na voljo ali se ravno zamenjuje. Osveži stanje po koncu izvoza.");
    var generation = await File.ReadAllTextAsync(marker, ct);
    var lines = generation.Split('\n');
    if (lines.Length < 4 || !DateTime.TryParse(lines[1], CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var published))
      throw new InvalidOperationException("Oznaka dokončanega izvoza ni veljavna. Ponovno izdelaj CSV.");
    var stream = new FileStream(Path.Combine(root, fileName), FileMode.Open, FileAccess.Read,
      FileShare.Read | FileShare.Delete, 65536, FileOptions.SequentialScan);
    try
    {
      // Handle ostane vezan na isto generacijo tudi, če worker nato zamenja imeni datotek.
      if (generation != await File.ReadAllTextAsync(marker, ct))
        throw new InvalidOperationException("CSV se je med branjem zamenjal. Ponovi predogled ali prenos.");
      return (stream, new(fileName, published.ToUniversalTime(), stream.Length, lines[0]));
    }
    catch { await stream.DisposeAsync(); throw; }
  }

  public async Task<MagentoArtifact> StatusAsync(string profile, CancellationToken ct = default)
  {
    var opened = await OpenAsync(profile, ct);
    await using var stream = opened.Stream;
    return opened.Artifact;
  }

  /// <summary>
  /// Ločilo stolpcev iz glave: katalog.csv ima od 277 podpičje (cene z decimalno vejico brez narekovajev),
  /// stranke.csv in starejše datoteke vejico. Šteje se zunaj narekovajev; tok se vrne na začetek.
  /// </summary>
  internal static string SniffDelimiter(Stream stream)
  {
    if (!stream.CanSeek) return ",";
    var start = stream.Position;
    var buffer = new byte[65_536];
    var read = stream.Read(buffer, 0, buffer.Length);
    stream.Position = start;
    int commas = 0, semicolons = 0;
    var quoted = false;
    for (var index = 0; index < read; index++)
    {
      var value = buffer[index];
      if (value == (byte)'"') quoted = !quoted;
      else if (quoted) continue;
      else if (value == (byte)'\n') break;
      else if (value == (byte)',') commas++;
      else if (value == (byte)';') semicolons++;
    }
    return semicolons > commas ? ";" : ",";
  }

  public async Task<MagentoArtifactPage> PreviewAsync(string profile, string? search, int skip, int take = 50, CancellationToken ct = default)
  {
    if (skip < 0 || take is < 1 or > 200) throw new ArgumentOutOfRangeException(nameof(take));
    var opened = await OpenAsync(profile, ct);
    await using var stream = opened.Stream;
    var delimiter = SniffDelimiter(stream);
    return await Task.Run(() =>
    {
      using var parser = new TextFieldParser(stream, new UTF8Encoding(false, true), detectEncoding: true, leaveOpen: true)
        { TextFieldType = FieldType.Delimited, HasFieldsEnclosedInQuotes = true, TrimWhiteSpace = false };
      parser.SetDelimiters(delimiter);
      var columns = parser.ReadFields() ?? throw new InvalidDataException("CSV nima glave.");
      var rows = new List<IReadOnlyList<string?>>();
      var matched = 0;
      var total = 0;
      while (!parser.EndOfData)
      {
        ct.ThrowIfCancellationRequested();
        var row = parser.ReadFields()!;
        total++;
        if (row.Length != columns.Length) throw new InvalidDataException($"Vrstica {total} nima pravilnega števila stolpcev.");
        if (!string.IsNullOrWhiteSpace(search) && !row.Any(value => value.Contains(search.Trim(), StringComparison.OrdinalIgnoreCase))) continue;
        if (matched >= skip && rows.Count < take) rows.Add(row);
        matched++;
      }
      return new MagentoArtifactPage(opened.Artifact, new(columns, rows, matched, skip, take), total);
    }, ct);
  }

  /// <summary>
  /// Izdelani CSV kot zvezek za Excel. CSV ostane za Magento (UTF-8 brez BOM; cene od 277 z decimalno vejico, ostala števila s piko);
  /// slovenski Excel iz njega naredi »koliÄŤina« in iz 29.78 število 2978. Zvezek nosi tip celice
  /// s sabo, zato so šumniki in decimalke pravilni ne glede na nastavitve računalnika.
  /// Vrednosti so iste kot v izdelani datoteki, le zapisane drugače — nič se ne sestavlja znova iz baze.
  /// </summary>
  public async Task<(byte[] Bytes, string FileName)> ExcelAsync(string profile, CancellationToken ct = default)
  {
    var opened = await OpenAsync(profile, ct);
    await using var stream = opened.Stream;
    var delimiter = SniffDelimiter(stream);
    return await Task.Run(() =>
    {
      using var parser = new TextFieldParser(stream, new UTF8Encoding(false, true), detectEncoding: true, leaveOpen: true)
        { TextFieldType = FieldType.Delimited, HasFieldsEnclosedInQuotes = true, TrimWhiteSpace = false };
      parser.SetDelimiters(delimiter);
      var header = parser.ReadFields() ?? throw new InvalidDataException("CSV nima glave.");
      var rows = new List<string[]>();
      while (!parser.EndOfData)
      {
        ct.ThrowIfCancellationRequested();
        var row = parser.ReadFields()!;
        if (row.Length != header.Length) throw new InvalidDataException($"Vrstica {rows.Count + 1} nima pravilnega števila stolpcev.");
        rows.Add(row);
      }

      // Stolpec je številski samo, če je VSAKA neprazna vrednost število brez vodilne ničle in
      // z največ deset celimi mesti. Tako EAN (13 mest) in šifre z vodilnimi ničlami (00001625)
      // ostanejo besedilo in jih Excel ne pokvari v 5,9E+12 ali 1625.
      var numeric = Enumerable.Range(0, header.Length)
        .Select(index => rows.Any(row => row[index].Length > 0) && rows.All(row => row[index].Length == 0 || IsPlainNumber(row[index])))
        .ToArray();
      var columns = header.Select((name, index) => new WorkbookColumn(name, numeric[index] ? WorkbookCellKind.Number : WorkbookCellKind.Text)).ToArray();
      // 277: cene so v datoteki z decimalno vejico (13,02), ostala števila s piko — oboje je isto število.
      var cells = rows.Select(row => (IReadOnlyList<object?>)row.Select((value, index) => (object?)(value.Length == 0 ? null
        : numeric[index] ? decimal.Parse(value.Replace(',', '.'), NumberStyles.AllowLeadingSign | NumberStyles.AllowDecimalPoint, CultureInfo.InvariantCulture) : value)).ToArray());
      var sheet = Path.GetFileNameWithoutExtension(opened.Artifact.FileName);
      return (WorkbookWriter.Write(sheet, columns, cells), sheet + ".xlsx");
    }, ct);
  }

  /// <summary>Število brez ločila tisočic, z decimalno piko ali (277, cene) decimalno vejico — nikoli z obema.</summary>
  static bool IsPlainNumber(string value)
  {
    var digits = value.StartsWith('-') ? value[1..] : value;
    if (digits.Contains('.') && digits.Contains(',')) return false;
    var dot = digits.IndexOfAny(['.', ',']);
    var whole = dot < 0 ? digits : digits[..dot];
    var fraction = dot < 0 ? "0" : digits[(dot + 1)..];
    return whole.Length is > 0 and <= 10 && (whole.Length == 1 || whole[0] != '0')
      && whole.All(char.IsAsciiDigit) && fraction.Length > 0 && fraction.All(char.IsAsciiDigit);
  }
}
