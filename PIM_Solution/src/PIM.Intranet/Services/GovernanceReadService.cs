using System.Data;
using Microsoft.Data.SqlClient;

namespace PIM.Intranet.Services;

public sealed record ExportProfileRow(int ExportProfileId, string ProfileCode, string Name, string ChannelCode, string EntityType, bool IsActive, long ColumnCount, long MappedColumnCount, DateTime UpdatedUtc);
public sealed record ExportColumnRow(int ExportColumnId, string ColumnCode, string OutputColumnName, string? CanonicalFieldCode, int SortOrder, bool IsRequired, bool IsActive);
public sealed record ValidationProfileRow(int ValidationProfileId, string ProfileCode, string Name, string? Scope, bool BlocksErp, bool BlocksWeb, bool IsActive, long RequirementCount, long ValidCount, long InvalidCount);
public sealed record ValidationLayerSummary(PimValidationLayer Layer, long ProductCount, long AffectedProductCount)
{
  public decimal ValidShare => ProductCount == 0 ? 0 : Math.Round(100m * Math.Max(0, ProductCount - AffectedProductCount) / ProductCount, 1);
}
public sealed record FieldRequirementRow(int FieldRequirementId, string FieldCode, bool IsRequired, bool IsActive, string? Severity, long OpenIssueCount);
public sealed record ValueLookupRow(long ValueLookupId, string Domain, string SourceValue, string? Language, string TargetValue, string? Note, bool IsActive);
public sealed record ValueDomainRow(string Domain, long RowCount, long ActiveCount);
public sealed record FieldMappingRow(long FieldMappingId, string SourceCode, string EntityType, string SourceElement, string TargetFieldCode, bool IsRequired, bool IsActive);
public sealed record ErrorLogRow(long ErrorLogId, DateTime OccurredUtc, string Layer, string Severity, string? ErrorCode, string Message, Guid? RunId);
public sealed record AlertRow(long AlertId, string Pipeline, string AlertKind, string Severity, string Title, string PayloadSummaryRedacted, long OccurrenceCount, DateTime FirstSeenUtc, DateTime LastSeenUtc, DateTime? AcknowledgedUtc, string? AcknowledgedBy, DateTime? ResolvedUtc, string? ResolvedBy);
public sealed record RoleRow(int RoleId, string RoleCode, string Name, long UserCount);
public sealed record ExportReadinessTotals(
  long CanonicalCount, long ActiveCount, long PublishedCount, long NotPublishedCount,
  long WebFlaggedCount, long PublishedWithOpenIssues);
public sealed record ExportBlockingReason(
  string FieldCode, string ProfileCode, bool BlocksErp, bool BlocksWeb, string Severity, long ProductCount);
public sealed record ExportProfileCoverage(
  string ProfileCode, string Name, string ChannelCode, string EntityType, bool IsActive,
  long ColumnCount, long MappedColumnCount, long UnmappedColumnCount, long RequiredUnmappedCount);
public sealed record ExportReadiness(
  ExportReadinessTotals Totals, IReadOnlyList<ExportBlockingReason> Reasons, IReadOnlyList<ExportProfileCoverage> Profiles);

/// <summary>
/// Bralni model registrov, ki dolocajo obnasanje sistema: izvozni profili, validacijski profili,
/// slovar vrednosti, preslikave polj, alarmi in dnevnik napak.
///
/// Te strani so bistvo obljube »nov kanal ni koda«: kar je tu vrstica, ni v programu.
/// </summary>
public sealed class GovernanceReadService(PimDb database, IConfiguration configuration)
{
  // ─── Izvozni profili ──────────────────────────────────────────────────────
  public Task<IReadOnlyList<ExportProfileRow>> GetExportProfilesAsync(CancellationToken cancellationToken = default) =>
    database.QueryAsync("""
      SELECT profile.ExportProfileId, profile.ProfileCode, profile.Name, profile.ChannelCode, profile.EntityType,
             profile.IsActive, profile.UpdatedUtc,
             (SELECT COUNT_BIG(*) FROM out.ExportColumn column1
              WHERE column1.ExportProfileId = profile.ExportProfileId AND column1.IsActive = 1) AS ColumnCount,
             (SELECT COUNT_BIG(*) FROM out.ExportColumn column2
              WHERE column2.ExportProfileId = profile.ExportProfileId AND column2.IsActive = 1
                AND NULLIF(column2.CanonicalFieldCode, N'') IS NOT NULL) AS MappedColumnCount
      FROM out.ExportProfile profile
      ORDER BY profile.IsActive DESC, profile.ProfileCode;
      """,
      reader => new ExportProfileRow(PimDb.Int32(reader, "ExportProfileId"), PimDb.TextOrEmpty(reader, "ProfileCode"),
        PimDb.TextOrEmpty(reader, "Name"), PimDb.TextOrEmpty(reader, "ChannelCode"), PimDb.TextOrEmpty(reader, "EntityType"),
        PimDb.Bool(reader, "IsActive"), PimDb.Int64(reader, "ColumnCount"), PimDb.Int64(reader, "MappedColumnCount"),
        PimDb.DateTimeValue(reader, "UpdatedUtc")),
      cancellationToken: cancellationToken);

  public Task<IReadOnlyList<ExportColumnRow>> GetExportColumnsAsync(int exportProfileId, bool onlyUnmapped, CancellationToken cancellationToken = default) =>
    database.QueryAsync("""
      SELECT ExportColumnId, ColumnCode, OutputColumnName, CanonicalFieldCode, SortOrder, IsRequired, IsActive
      FROM out.ExportColumn
      WHERE ExportProfileId = @ExportProfileId
        AND (@OnlyUnmapped = 0 OR NULLIF(CanonicalFieldCode, N'') IS NULL)
      ORDER BY SortOrder, ColumnCode;
      """,
      reader => new ExportColumnRow(PimDb.Int32(reader, "ExportColumnId"), PimDb.TextOrEmpty(reader, "ColumnCode"),
        PimDb.TextOrEmpty(reader, "OutputColumnName"), PimDb.Text(reader, "CanonicalFieldCode"), PimDb.Int32(reader, "SortOrder"),
        PimDb.Bool(reader, "IsRequired"), PimDb.Bool(reader, "IsActive")),
      command =>
      {
        command.Parameters.AddWithValue("@ExportProfileId", exportProfileId);
        command.Parameters.AddWithValue("@OnlyUnmapped", onlyUnmapped ? 1 : 0);
      }, cancellationToken);

  // ─── Validacijski profili ─────────────────────────────────────────────────
  public Task<IReadOnlyList<ValidationProfileRow>> GetValidationProfilesAsync(int organizationId, CancellationToken cancellationToken = default) =>
    database.QueryAsync("""
      SELECT profile.ValidationProfileId, profile.ProfileCode, profile.Name, profile.Scope,
             profile.BlocksErp, profile.BlocksWeb, profile.IsActive,
             (SELECT COUNT_BIG(*) FROM val.FieldRequirement requirement
              WHERE requirement.ValidationProfileId = profile.ValidationProfileId AND requirement.IsActive = 1) AS RequirementCount,
             (SELECT COUNT_BIG(*) FROM val.ProductValidationState state
              INNER JOIN canon.Product product ON product.ProductId = state.ProductId
              WHERE state.ValidationProfileId = profile.ValidationProfileId AND product.OrganizationId = @OrganizationId
                AND state.Status = N'VALID') AS ValidCount,
             (SELECT COUNT_BIG(*) FROM val.ProductValidationState state
              INNER JOIN canon.Product product ON product.ProductId = state.ProductId
              WHERE state.ValidationProfileId = profile.ValidationProfileId AND product.OrganizationId = @OrganizationId
                AND state.Status = N'INVALID') AS InvalidCount
      FROM val.ValidationProfile profile
      ORDER BY profile.IsActive DESC, profile.ProfileCode;
      """,
      reader => new ValidationProfileRow(PimDb.Int32(reader, "ValidationProfileId"), PimDb.TextOrEmpty(reader, "ProfileCode"),
        PimDb.TextOrEmpty(reader, "Name"), PimDb.Text(reader, "Scope"), PimDb.Bool(reader, "BlocksErp"), PimDb.Bool(reader, "BlocksWeb"),
        PimDb.Bool(reader, "IsActive"), PimDb.Int64(reader, "RequirementCount"), PimDb.Int64(reader, "ValidCount"),
        PimDb.Int64(reader, "InvalidCount")),
      command => command.Parameters.AddWithValue("@OrganizationId", organizationId), cancellationToken);

  public Task<IReadOnlyList<FieldRequirementRow>> GetFieldRequirementsAsync(int validationProfileId, int organizationId, CancellationToken cancellationToken = default) =>
    database.QueryAsync("""
      SELECT requirement.FieldRequirementId, requirement.FieldCode, requirement.IsRequired, requirement.IsActive, requirement.Severity,
             (SELECT COUNT_BIG(*) FROM val.ProductIssue issue
              INNER JOIN canon.Product product ON product.ProductId = issue.ProductId
              WHERE issue.FieldRequirementId = requirement.FieldRequirementId AND issue.IsActive = 1
                AND product.OrganizationId = @OrganizationId) AS OpenIssueCount
      FROM val.FieldRequirement requirement
      WHERE requirement.ValidationProfileId = @ValidationProfileId
      ORDER BY requirement.IsActive DESC, requirement.FieldCode;
      """,
      reader => new FieldRequirementRow(PimDb.Int32(reader, "FieldRequirementId"), PimDb.TextOrEmpty(reader, "FieldCode"),
        PimDb.Bool(reader, "IsRequired"), PimDb.Bool(reader, "IsActive"), PimDb.Text(reader, "Severity"),
        PimDb.Int64(reader, "OpenIssueCount")),
      command =>
      {
        command.Parameters.AddWithValue("@ValidationProfileId", validationProfileId);
        command.Parameters.AddWithValue("@OrganizationId", organizationId);
      }, cancellationToken);

  public async Task<IReadOnlyList<ValidationLayerSummary>> GetValidationLayerSummariesAsync(
    int organizationId, IReadOnlyList<ValidationProfileRow> profiles, string? webSite = null,
    CancellationToken cancellationToken = default)
  {
    var tasks = Enum.GetValues<PimValidationLayer>().Select(async layer =>
    {
      var profileIds = profiles
        .Where(profile => ValidationLayer.Resolve(profile.ProfileCode, profile.Scope, profile.BlocksErp, profile.BlocksWeb).Contains(layer))
        .Where(profile => layer != PimValidationLayer.Splet || string.IsNullOrWhiteSpace(webSite)
          || ValidationLayer.IsShared(profile.Scope) || SiteMatches(profile.ProfileCode, webSite))
        .Select(profile => profile.ValidationProfileId).Distinct().ToArray();
      if (profileIds.Length == 0) return new ValidationLayerSummary(layer, 0, 0);

      var parameters = string.Join(", ", profileIds.Select((_, index) => $"@Profile{index}"));
      var rows = await database.QueryAsync($"""
        SELECT
          ProductCount = (SELECT COUNT_BIG(*) FROM canon.Product WHERE OrganizationId = @OrganizationId),
          AffectedProductCount = COUNT_BIG(DISTINCT issue.ProductId)
        FROM val.ProductIssue issue
        INNER JOIN canon.Product product ON product.ProductId = issue.ProductId AND product.OrganizationId = @OrganizationId
        LEFT JOIN val.FieldRequirement requirement ON requirement.FieldRequirementId = issue.FieldRequirementId
        WHERE issue.IsActive = 1 AND issue.ValidationProfileId IN ({parameters})
          AND (@IncludeWarnings = 1 OR COALESCE(requirement.Severity, N'ERROR') = N'ERROR');
        """,
        reader => new ValidationLayerSummary(layer, PimDb.Int64(reader, "ProductCount"), PimDb.Int64(reader, "AffectedProductCount")),
        command =>
        {
          command.Parameters.AddWithValue("@OrganizationId", organizationId);
          command.Parameters.AddWithValue("@IncludeWarnings", layer == PimValidationLayer.Komerciala);
          for (var index = 0; index < profileIds.Length; index++)
            command.Parameters.AddWithValue($"@Profile{index}", profileIds[index]);
        }, cancellationToken);
      return rows.FirstOrDefault() ?? new(layer, 0, 0);
    });
    return await Task.WhenAll(tasks);
  }

  static bool SiteMatches(string profileCode, string webSite)
  {
    static string Normalize(string value) => new(value.Where(char.IsLetterOrDigit).ToArray());
    return Normalize(profileCode).Contains(Normalize(webSite), StringComparison.OrdinalIgnoreCase);
  }

  // ─── Slovar vrednosti in preslikave polj ─────────────────────────────────
  public Task<IReadOnlyList<ValueDomainRow>> GetValueDomainsAsync(CancellationToken cancellationToken = default) =>
    database.QueryAsync("""
      SELECT Domain, COUNT_BIG(*) AS RowCountValue, SUM(CASE WHEN IsActive = 1 THEN 1 ELSE 0 END) AS ActiveCount
      FROM map.ValueLookup GROUP BY Domain ORDER BY COUNT_BIG(*) DESC;
      """,
      reader => new ValueDomainRow(PimDb.TextOrEmpty(reader, "Domain"), PimDb.Int64(reader, "RowCountValue"), PimDb.Int64(reader, "ActiveCount")),
      cancellationToken: cancellationToken);

  public Task<(IReadOnlyList<ValueLookupRow> Rows, long TotalCount)> GetValueLookupsAsync(
    string? domain, string? search, int skip, int take, CancellationToken cancellationToken = default) =>
    database.PageAsync("""
      SELECT ValueLookupId, Domain, SourceValue, Language, TargetValue, Note, IsActive
      FROM map.ValueLookup
      WHERE (@Domain IS NULL OR Domain = @Domain)
        AND (@Search IS NULL OR SourceValue LIKE '%' + @Search + '%' OR TargetValue LIKE '%' + @Search + '%')
      ORDER BY Domain, SourceValue
      OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY;

      SELECT COUNT_BIG(*) FROM map.ValueLookup
      WHERE (@Domain IS NULL OR Domain = @Domain)
        AND (@Search IS NULL OR SourceValue LIKE '%' + @Search + '%' OR TargetValue LIKE '%' + @Search + '%');
      """,
      reader => new ValueLookupRow(PimDb.Int64(reader, "ValueLookupId"), PimDb.TextOrEmpty(reader, "Domain"),
        PimDb.TextOrEmpty(reader, "SourceValue"), PimDb.Text(reader, "Language"), PimDb.TextOrEmpty(reader, "TargetValue"),
        PimDb.Text(reader, "Note"), PimDb.Bool(reader, "IsActive")),
      command =>
      {
        command.Parameters.AddWithValue("@Domain", string.IsNullOrWhiteSpace(domain) ? DBNull.Value : domain);
        command.Parameters.AddWithValue("@Search", string.IsNullOrWhiteSpace(search) ? DBNull.Value : search.Trim());
        command.Parameters.AddWithValue("@Skip", skip);
        command.Parameters.AddWithValue("@Take", take);
      }, cancellationToken);

  public Task<(IReadOnlyList<FieldMappingRow> Rows, long TotalCount)> GetFieldMappingsAsync(
    int organizationId, string? entityType, string? search, int skip, int take, CancellationToken cancellationToken = default) =>
    database.PageAsync("""
      SELECT mapping.FieldMappingId, connector.SourceCode, mapping.EntityType, mapping.SourceElement,
             mapping.TargetFieldCode, mapping.IsRequired, mapping.IsActive
      FROM map.FieldMapping mapping
      INNER JOIN map.SourceConnector connector ON connector.SourceConnectorId = mapping.SourceConnectorId
      WHERE connector.OrganizationId = @OrganizationId
        AND (@EntityType IS NULL OR mapping.EntityType = @EntityType)
        AND (@Search IS NULL OR mapping.SourceElement LIKE '%' + @Search + '%' OR mapping.TargetFieldCode LIKE '%' + @Search + '%')
      ORDER BY connector.SourceCode, mapping.EntityType, mapping.TargetFieldCode
      OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY;

      SELECT COUNT_BIG(*)
      FROM map.FieldMapping mapping
      INNER JOIN map.SourceConnector connector ON connector.SourceConnectorId = mapping.SourceConnectorId
      WHERE connector.OrganizationId = @OrganizationId
        AND (@EntityType IS NULL OR mapping.EntityType = @EntityType)
        AND (@Search IS NULL OR mapping.SourceElement LIKE '%' + @Search + '%' OR mapping.TargetFieldCode LIKE '%' + @Search + '%');
      """,
      reader => new FieldMappingRow(PimDb.Int64(reader, "FieldMappingId"), PimDb.TextOrEmpty(reader, "SourceCode"),
        PimDb.TextOrEmpty(reader, "EntityType"), PimDb.TextOrEmpty(reader, "SourceElement"),
        PimDb.TextOrEmpty(reader, "TargetFieldCode"), PimDb.Bool(reader, "IsRequired"), PimDb.Bool(reader, "IsActive")),
      command =>
      {
        command.Parameters.AddWithValue("@OrganizationId", organizationId);
        command.Parameters.AddWithValue("@EntityType", string.IsNullOrWhiteSpace(entityType) ? DBNull.Value : entityType);
        command.Parameters.AddWithValue("@Search", string.IsNullOrWhiteSpace(search) ? DBNull.Value : search.Trim());
        command.Parameters.AddWithValue("@Skip", skip);
        command.Parameters.AddWithValue("@Take", take);
      }, cancellationToken);

  public Task<IReadOnlyList<PimOption>> GetMappedEntityTypesAsync(int organizationId, CancellationToken cancellationToken = default) =>
    database.QueryAsync("""
      SELECT mapping.EntityType, COUNT_BIG(*) AS RowCountValue
      FROM map.FieldMapping mapping
      INNER JOIN map.SourceConnector connector ON connector.SourceConnectorId = mapping.SourceConnectorId
      WHERE connector.OrganizationId = @OrganizationId
      GROUP BY mapping.EntityType ORDER BY mapping.EntityType;
      """,
      reader => new PimOption(PimDb.TextOrEmpty(reader, "EntityType"),
        $"{PimDb.TextOrEmpty(reader, "EntityType")} ({PimDb.Int64(reader, "RowCountValue"):N0})"),
      command => command.Parameters.AddWithValue("@OrganizationId", organizationId), cancellationToken);

  // ─── Sistem ───────────────────────────────────────────────────────────────
  public Task<IReadOnlyList<ErrorLogRow>> GetErrorLogAsync(string? severity, int take, CancellationToken cancellationToken = default) =>
    database.QueryAsync("""
      SELECT TOP (@Take) ErrorLogId, OccurredUtc, Layer, Severity, ErrorCode, Message, RunId
      FROM ops.ErrorLog
      WHERE (@Severity IS NULL OR Severity = @Severity)
      ORDER BY OccurredUtc DESC, ErrorLogId DESC;
      """,
      reader => new ErrorLogRow(PimDb.Int64(reader, "ErrorLogId"), PimDb.DateTimeValue(reader, "OccurredUtc"),
        PimDb.TextOrEmpty(reader, "Layer"), PimDb.TextOrEmpty(reader, "Severity"), PimDb.Text(reader, "ErrorCode"),
        PimDb.TextOrEmpty(reader, "Message"),
        reader.IsDBNull(reader.GetOrdinal("RunId")) ? null : reader.GetGuid(reader.GetOrdinal("RunId"))),
      command =>
      {
        command.Parameters.AddWithValue("@Take", take);
        command.Parameters.AddWithValue("@Severity", string.IsNullOrWhiteSpace(severity) ? DBNull.Value : severity);
      }, cancellationToken);

  public Task<IReadOnlyList<AlertRow>> GetAlertsAsync(int organizationId, bool onlyOpen, CancellationToken cancellationToken = default) =>
    database.QueryAsync("""
      SELECT AlertId, Pipeline, AlertKind, Severity, Title, PayloadSummaryRedacted, OccurrenceCount,
             FirstSeenUtc, LastSeenUtc, AcknowledgedUtc, AcknowledgedBy, ResolvedUtc, ResolvedBy
      FROM ops.Alert
      WHERE OrganizationId = @OrganizationId AND (@OnlyOpen = 0 OR ResolvedUtc IS NULL)
      ORDER BY CASE WHEN ResolvedUtc IS NULL THEN 0 ELSE 1 END, LastSeenUtc DESC;
      """,
      reader => new AlertRow(PimDb.Int64(reader, "AlertId"), PimDb.TextOrEmpty(reader, "Pipeline"),
        PimDb.TextOrEmpty(reader, "AlertKind"), PimDb.TextOrEmpty(reader, "Severity"), PimDb.TextOrEmpty(reader, "Title"),
        PimDb.TextOrEmpty(reader, "PayloadSummaryRedacted"), PimDb.Int64(reader, "OccurrenceCount"),
        PimDb.DateTimeValue(reader, "FirstSeenUtc"), PimDb.DateTimeValue(reader, "LastSeenUtc"),
        PimDb.NullableDateTime(reader, "AcknowledgedUtc"), PimDb.Text(reader, "AcknowledgedBy"),
        PimDb.NullableDateTime(reader, "ResolvedUtc"), PimDb.Text(reader, "ResolvedBy")),
      command =>
      {
        command.Parameters.AddWithValue("@OrganizationId", organizationId);
        command.Parameters.AddWithValue("@OnlyOpen", onlyOpen ? 1 : 0);
      }, cancellationToken);

  public Task<IReadOnlyList<RoleRow>> GetRolesAsync(CancellationToken cancellationToken = default) =>
    database.QueryAsync("""
      SELECT role.RoleId, role.RoleCode, role.Name,
             (SELECT COUNT_BIG(*) FROM sec.LocalUserRole userRole WHERE userRole.RoleId = role.RoleId) AS UserCount
      FROM sec.Role role ORDER BY role.RoleId;
      """,
      reader => new RoleRow(PimDb.Int32(reader, "RoleId"), PimDb.TextOrEmpty(reader, "RoleCode"),
        PimDb.TextOrEmpty(reader, "Name"), PimDb.Int64(reader, "UserCount")),
      cancellationToken: cancellationToken);

  // ─── Pripravljenost izvoza ────────────────────────────────────────────────
  //
  // Tri nabore vrne ena procedura (migracija 104), zato tu ni PimDb, ampak neposreden klic.
  // Predogleda datoteke namenoma ni: obliko Magento izvoza dela PIM.B2bWorker in druga
  // izvedba iste logike bi bila druga resnica.
  public async Task<ExportReadiness> GetExportReadinessAsync(
    int organizationId, CancellationToken cancellationToken = default)
  {
    var connectionString = ConnectionStringResolver.Resolve(configuration)
      ?? throw new InvalidOperationException("Povezava PIM ni nastavljena.");

    await using var connection = new SqlConnection(connectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.GetExportReadiness", connection)
    {
      CommandType = CommandType.StoredProcedure,
      CommandTimeout = 60,
    };
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;

    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    var totals = new ExportReadinessTotals(0, 0, 0, 0, 0, 0);
    if (await reader.ReadAsync(cancellationToken))
      totals = new(
        PimDb.Int64(reader, "CanonicalCount"), PimDb.Int64(reader, "ActiveCount"),
        PimDb.Int64(reader, "PublishedCount"), PimDb.Int64(reader, "NotPublishedCount"),
        PimDb.Int64(reader, "WebFlaggedCount"), PimDb.Int64(reader, "PublishedWithOpenIssues"));

    var reasons = new List<ExportBlockingReason>();
    if (await reader.NextResultAsync(cancellationToken))
      while (await reader.ReadAsync(cancellationToken))
        reasons.Add(new(
          PimDb.TextOrEmpty(reader, "FieldCode"), PimDb.TextOrEmpty(reader, "ProfileCode"),
          PimDb.Bool(reader, "BlocksErp"), PimDb.Bool(reader, "BlocksWeb"),
          PimDb.TextOrEmpty(reader, "Severity"), PimDb.Int64(reader, "ProductCount")));

    var profiles = new List<ExportProfileCoverage>();
    if (await reader.NextResultAsync(cancellationToken))
      while (await reader.ReadAsync(cancellationToken))
        profiles.Add(new(
          PimDb.TextOrEmpty(reader, "ProfileCode"), PimDb.TextOrEmpty(reader, "Name"),
          PimDb.TextOrEmpty(reader, "ChannelCode"), PimDb.TextOrEmpty(reader, "EntityType"),
          PimDb.Bool(reader, "IsActive"), PimDb.Int64(reader, "ColumnCount"),
          PimDb.Int64(reader, "MappedColumnCount"), PimDb.Int64(reader, "UnmappedColumnCount"),
          PimDb.Int64(reader, "RequiredUnmappedCount")));

    return new(totals, reasons, profiles);
  }
}
