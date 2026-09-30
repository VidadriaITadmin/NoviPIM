using PIM.Operations;

namespace PIM.Intranet.Services;

/// <summary>
/// Izvoz odprtih napak validacije v delovni zvezek — isti filtri kot na /kakovost/napake, ista
/// oblika zvezka kot na /izdelki (WorkbookWriter). Uporabnikova zahteva 2026-09-10: "izvoz naj bo
/// enak kot pri izdelkih ... filtrirajo, potem se jim izpišejo artikli kot so filtrirali".
///
/// Ena vrstica je ena odprta napaka (ne izdelek): isti izdelek ima lahko vec napak z razlicno
/// resnostjo, zato bi ena vrstica na izdelek pomenila eno barvo za vec resnosti. Vrstica nosi
/// barvo cele vrstice: rdeca (WorkbookCellTone.Missing) za napako, ki blokira, bleda oranzna
/// (WorkbookCellTone.Warning) za opozorilo — enako kot zaslonski prikaz (.issue-severity).
/// </summary>
public sealed class QualityIssueExportService(
  QualityReadService quality, GovernanceReadService governance, IConfiguration configuration)
{
  string ConnectionString => ConnectionStringResolver.Resolve(configuration)
    ?? throw new InvalidOperationException("Povezava PIM ni nastavljena.");

  /// <summary>Fizična meja lista .xlsx, ne poslovna — glej WorkbookTable.MaxRows (2026-09-17).</summary>
  public const int MaxRows = WorkbookTable.MaxRows;

  /// <summary>Največ izdelkov, ki jih intranet.GetQualityIssues vrne v enem klicu (migracija 177).</summary>
  public const int ProcedurePageSize = 200;

  static readonly WorkbookColumn[] Columns =
  [
    new("Šifra artikla", Width: 18),
    new("EAN", Width: 16),
    // #99: dva ločena naziva kot pri cenah (prej en stolpec »spletni, sicer ERP« iz GetQualityIssues).
    new(ProductTitleLookup.WebHeader, Width: 46),
    new(ProductTitleLookup.ErpHeader, Width: 46),
    new("Nivo", Width: 16),
    new("Profil", Width: 16),
    new("Polje", Width: 24),
    new("Resnost", Width: 12),
    new("Blokira", Width: 16),
    new("Sporočilo", Width: 60),
    new("Popolnost", WorkbookCellKind.Percent, 12),
    new("Zadnji pojav", WorkbookCellKind.DateTime, 18),
  ];

  public async Task<byte[]> BuildAsync(
    QualityIssueFilter filter, string? layer, string? webSite, CancellationToken cancellationToken = default)
  {
    QualityIssuePage page;
    var truncated = false;
    if (string.IsNullOrWhiteSpace(layer))
    {
      // #112: intranet.GetQualityIssues vrne najvec ProcedurePageSize izdelkov na klic (177),
      // zato izvoz bere po straneh, dokler ne prebere vseh izdelkov iz filtra.
      var read = await PagedExportReader.ReadAllAsync(
        ProcedurePageSize, MaxRows,
        async (skip, size, token) =>
        {
          var part = await quality.GetIssuesAsync(filter with { Skip = skip, Take = size }, token);
          return new ExportPage<QualityProductRow, QualityIssueRow>(part.Products, part.Issues, part.TotalCount);
        },
        product => product.ProductId, issue => issue.ProductId, cancellationToken);
      page = new QualityIssuePage(read.Items, read.Details, read.TotalCount);
      truncated = read.Truncated;
    }
    else
    {
      // Pot z nivojem je vgrajen SQL brez meje strani: en klic prebere vse (do MaxRows izdelkov).
      var profiles = await governance.GetValidationProfilesAsync(filter.OrganizationId);
      var layerProfiles = ProfilesForLayer(profiles, layer, webSite).Select(profile => profile.ProfileCode).ToArray();
      page = await quality.GetIssuesForProfilesAsync(filter with { Skip = 0, Take = MaxRows }, layerProfiles, cancellationToken);
      if (page.Issues.Count > MaxRows)
      {
        page = page with { Issues = page.Issues.Take(MaxRows).ToArray() };
        truncated = true;
      }
    }

    var products = page.Products.ToDictionary(product => product.ProductId);
    var titles = await ProductTitleLookup.ByProductIdAsync(ConnectionString, page.Products.Select(product => product.ProductId), cancellationToken);
    var profileByCode = (await governance.GetValidationProfilesAsync(filter.OrganizationId))
      .ToDictionary(profile => profile.ProfileCode, StringComparer.OrdinalIgnoreCase);

    var rows = page.Issues.Select(issue =>
    {
      var product = products.TryGetValue(issue.ProductId, out var found) ? found : null;
      var scope = profileByCode.TryGetValue(issue.ProfileCode, out var profile) ? profile.Scope : null;
      var layers = ValidationLayer.Resolve(issue.ProfileCode, scope, issue.BlocksErp, issue.BlocksWeb);
      var tone = string.Equals(issue.Severity, "WARNING", StringComparison.OrdinalIgnoreCase)
        ? WorkbookCellTone.Warning : WorkbookCellTone.Missing;

      IReadOnlyList<object?> line =
      [
        Cell(product?.ItemId, tone), Cell(product?.Ean, tone),
        Cell(ProductTitleLookup.Find(titles, issue.ProductId).WebTitle, tone), Cell(ProductTitleLookup.Find(titles, issue.ProductId).ErpTitle, tone),
        Cell(layers.Count == 0 ? "—" : string.Join(" · ", layers.Select(ValidationLayer.Label)), tone),
        Cell(issue.ProfileCode, tone), Cell(issue.FieldCode ?? issue.IssueCode, tone),
        Cell(SeverityLabel(issue.Severity), tone), Cell(BlocksLabel(issue.BlocksErp, issue.BlocksWeb), tone),
        Cell(issue.Message, tone), Cell(product?.Completeness, tone), Cell(issue.LastDetectedUtc, tone),
      ];
      return line;
    }).ToArray();

    var notes = new List<string> { "Rdeča vrstica: napaka (blokira). Bleda oranžna vrstica: opozorilo (ne blokira)." };
    // TotalCount šteje IZDELKE (kot "9.044 izdelkov" na strani), vrstica v zvezku pa je ena napaka.
    var exportedProducts = rows.Length == 0 ? 0 : page.Issues.Select(issue => issue.ProductId).Distinct().Count();
    notes.Add($"Izdelkov v izvozu: {exportedProducts:N0} od {page.TotalCount:N0} po filtru; vrstic (napak): {rows.Length:N0}.");
    if (truncated || page.Products.Count < page.TotalCount)
      notes.Add($"Izvoz ni popoln: zgornja meja lista je {MaxRows:N0} vrstic. Zožite filter in izvozite po delih.");

    return WorkbookWriter.Write("Napake validacije", Columns, rows, notes);
  }

  static object? Cell(object? value, WorkbookCellTone tone) => new WorkbookCell(value, tone);

  static IEnumerable<ValidationProfileRow> ProfilesForLayer(
    IReadOnlyList<ValidationProfileRow> profiles, string? layerValue, string? webSiteValue)
  {
    if (!Enum.TryParse<PimValidationLayer>(NormalizeLayer(layerValue), true, out var layer)) return profiles;
    return profiles.Where(profile => ValidationLayer.Resolve(profile.ProfileCode, profile.Scope, profile.BlocksErp, profile.BlocksWeb).Contains(layer))
      .Where(profile => layer != PimValidationLayer.Splet || string.IsNullOrWhiteSpace(webSiteValue)
        || ValidationLayer.IsShared(profile.Scope) || SiteMatches(profile.ProfileCode, webSiteValue));
  }

  static bool SiteMatches(string profileCode, string site)
  {
    static string Normalize(string value) => new(value.Where(char.IsLetterOrDigit).ToArray());
    return Normalize(profileCode).Contains(Normalize(site), StringComparison.OrdinalIgnoreCase);
  }

  static string NormalizeLayer(string? value) => value?.Replace("/", "", StringComparison.Ordinal).Replace("_", "", StringComparison.Ordinal) switch
  {
    "ERPSLO" => nameof(PimValidationLayer.ErpSlo),
    "ERPEUTHIRD" => nameof(PimValidationLayer.ErpEuThird),
    "KOMERCIALA" => nameof(PimValidationLayer.Komerciala),
    "SPLET" => nameof(PimValidationLayer.Splet),
    _ => value ?? "",
  };

  static string SeverityLabel(string? severity) => severity switch
  {
    "ERROR" => "Napaka",
    "WARNING" => "Opozorilo",
    _ => severity ?? "—",
  };

  static string BlocksLabel(bool blocksErp, bool blocksWeb) => (blocksErp, blocksWeb) switch
  {
    (true, true) => "ERP in splet",
    (true, false) => "ERP",
    (false, true) => "Splet",
    _ => "Ne blokira",
  };

  public static string FileName(DateTime nowUtc) =>
    "kakovost-napake-" + nowUtc.ToPimLocal().ToString("yyyyMMdd-HHmm", System.Globalization.CultureInfo.InvariantCulture) + ".xlsx";
}
