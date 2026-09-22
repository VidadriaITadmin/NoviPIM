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
/// Izhodna mapa, kot jo vidi TA proces intraneta (242). Worker, ki datoteki izdela, lahko teče pod drugim
/// računom (Windows naloga, storitev), zato »zapisljiva« tu pove samo, ali bi vanjo lahko pisal intranet
/// (razporejevalnik v aplikaciji); za drug račun pove napaka zadnjega poskusa v out.ExportRun.
/// </summary>
/// <param name="Source">Od kod pot: okolje PIM_EXPORT_ROOT, register ops.SystemPath (EXPORT_ROOT) ali vgrajeni privzetek.</param>
public sealed record MagentoOutputFolder(string Root, string Source, bool Exists, bool WritableByThisProcess, string Account, bool HasCompletePair);

/// <summary>Bere izdelani CSV. Predogled nikoli ne sestavlja nove vsebine iz baze.</summary>
public sealed class MagentoArtifactService(IConfiguration configuration)
{
  public static string FileName(string profile) => profile switch
  {
    "MAGENTO_PRODUCTS" => "katalog.csv",
    "MAGENTO_CUSTOMERS" => "stranke.csv",
    _ => throw new ArgumentException("Neznana datoteka Magento."),
  };

  /// <summary>Isti vrstni red kot PIM.B2bWorker (Program.cs) in WorkerCycleRunner: okolje, register, privzetek.</summary>
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

  public async Task<MagentoArtifactPage> PreviewAsync(string profile, string? search, int skip, int take = 50, CancellationToken ct = default)
  {
    if (skip < 0 || take is < 1 or > 200) throw new ArgumentOutOfRangeException(nameof(take));
    var opened = await OpenAsync(profile, ct);
    await using var stream = opened.Stream;
    return await Task.Run(() =>
    {
      using var parser = new TextFieldParser(stream, new UTF8Encoding(false, true), detectEncoding: true, leaveOpen: true)
        { TextFieldType = FieldType.Delimited, HasFieldsEnclosedInQuotes = true, TrimWhiteSpace = false };
      parser.SetDelimiters(",");
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
}
