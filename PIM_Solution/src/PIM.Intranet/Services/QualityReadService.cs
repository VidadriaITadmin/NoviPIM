using System.Data;
using Microsoft.Data.SqlClient;

namespace PIM.Intranet.Services;

public sealed record QualityProductRow(
  long ProductId, string ItemId, string? Ean, string Name, string ValidationStatus,
  decimal Completeness, bool IsActive, bool WebPublish, long IssueCount, long ErrorCount,
  long WarningCount, long BlockingErpCount, long BlockingWebCount, DateTime? LastDetectedUtc);

public sealed record QualityIssueRow(
  long ProductIssueId, long ProductId, string ProfileCode, bool BlocksErp, bool BlocksWeb,
  string? FieldCode, string Severity, string IssueCode, string Message,
  DateTime FirstDetectedUtc, DateTime LastDetectedUtc);

public sealed record QualityIssuePage(
  IReadOnlyList<QualityProductRow> Products, IReadOnlyList<QualityIssueRow> Issues, long TotalCount);

public sealed record QualityIssueFilter(
  int OrganizationId, int Skip = 0, int Take = 25, string? Search = null, string? ProfileCode = null,
  string? Severity = null, string? Blocks = null, string? FieldCode = null, string Language = "sl");

public sealed record QualityTotals(
  long OpenIssueCount, long ErrorCount, long WarningCount, long BlockingErpCount,
  long BlockingWebCount, long AdvisoryCount, long AffectedProductCount);

public sealed record QualityRuleImpact(
  string FieldCode, string ProfileCode, bool BlocksErp, bool BlocksWeb, string Severity,
  long IssueCount, long ProductCount);

public sealed record QualitySupplierImpact(
  string Supplier, long ProductCount, long WithIssuesCount, long IssueCount);

public sealed record QualityOverview(
  QualityTotals Totals, IReadOnlyList<QualityRuleImpact> Rules, IReadOnlyList<QualitySupplierImpact> Suppliers);

/// <summary>
/// Bralni model kakovosti. SQL ostane v oštevilčeni migraciji (102); tu je samo klic
/// procedure in preslikava stolpcev po imenu.
///
/// Enota strani je izdelek, ne težava: aktivnih težav je čez tri milijone, izdelkov z vsaj
/// eno pa dva reda velikosti manj. Urednik dela po izdelkih, zato je izdelek tudi enota strani.
/// </summary>
public sealed class QualityReadService(IConfiguration configuration)
{
  string ConnectionString => ConnectionStringResolver.Resolve(configuration)
    ?? throw new InvalidOperationException("Povezava PIM ni nastavljena.");

  public async Task<QualityIssuePage> GetIssuesAsync(
    QualityIssueFilter filter, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.GetQualityIssues", connection)
    {
      CommandType = CommandType.StoredProcedure,
      CommandTimeout = 60,
    };
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = filter.OrganizationId;
    command.Parameters.Add("@Skip", SqlDbType.Int).Value = filter.Skip;
    command.Parameters.Add("@Take", SqlDbType.Int).Value = filter.Take;
    command.Parameters.Add("@Search", SqlDbType.NVarChar, 200).Value = Optional(filter.Search);
    command.Parameters.Add("@ProfileCode", SqlDbType.NVarChar, 100).Value = Optional(filter.ProfileCode);
    command.Parameters.Add("@Severity", SqlDbType.NVarChar, 20).Value = Optional(filter.Severity);
    command.Parameters.Add("@Blocks", SqlDbType.NVarChar, 20).Value = Optional(filter.Blocks);
    command.Parameters.Add("@FieldCode", SqlDbType.NVarChar, 200).Value = Optional(filter.FieldCode);
    command.Parameters.Add("@Language", SqlDbType.NVarChar, 20).Value = filter.Language;

    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    var products = await ReadAsync(reader, row => new QualityProductRow(
      PimDb.Int64(row, "ProductId"), PimDb.TextOrEmpty(row, "ItemID"), PimDb.Text(row, "EAN"),
      PimDb.TextOrEmpty(row, "Name"), PimDb.TextOrEmpty(row, "ValidationStatus"),
      PimDb.Decimal(row, "Completeness"), PimDb.Bool(row, "IsActive"), PimDb.Bool(row, "WebPublish"),
      PimDb.Int64(row, "IssueCount"), PimDb.Int64(row, "ErrorCount"), PimDb.Int64(row, "WarningCount"),
      PimDb.Int64(row, "BlockingErpCount"), PimDb.Int64(row, "BlockingWebCount"),
      PimDb.NullableDateTime(row, "LastDetectedUtc")), cancellationToken);

    await NextAsync(reader, cancellationToken);
    var issues = await ReadAsync(reader, row => new QualityIssueRow(
      PimDb.Int64(row, "ProductIssueId"), PimDb.Int64(row, "ProductId"),
      PimDb.TextOrEmpty(row, "ProfileCode"), PimDb.Bool(row, "BlocksErp"), PimDb.Bool(row, "BlocksWeb"),
      PimDb.Text(row, "FieldCode"), PimDb.TextOrEmpty(row, "Severity"),
      PimDb.TextOrEmpty(row, "IssueCode"), PimDb.TextOrEmpty(row, "Message"),
      PimDb.DateTimeValue(row, "FirstDetectedUtc"), PimDb.DateTimeValue(row, "LastDetectedUtc")), cancellationToken);

    long total = 0;
    if (await reader.NextResultAsync(cancellationToken) && await reader.ReadAsync(cancellationToken))
      total = Convert.ToInt64(reader.GetValue(0));

    return new(products, issues, total);
  }

  public async Task<QualityOverview> GetOverviewAsync(
    int organizationId, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.GetQualityOverview", connection)
    {
      CommandType = CommandType.StoredProcedure,
      CommandTimeout = 60,
    };
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;

    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    var totals = new QualityTotals(0, 0, 0, 0, 0, 0, 0);
    if (await reader.ReadAsync(cancellationToken))
      totals = new(
        PimDb.Int64(reader, "OpenIssueCount"), PimDb.Int64(reader, "ErrorCount"),
        PimDb.Int64(reader, "WarningCount"), PimDb.Int64(reader, "BlockingErpCount"),
        PimDb.Int64(reader, "BlockingWebCount"), PimDb.Int64(reader, "AdvisoryCount"),
        PimDb.Int64(reader, "AffectedProductCount"));

    await NextAsync(reader, cancellationToken);
    var rules = await ReadAsync(reader, row => new QualityRuleImpact(
      PimDb.TextOrEmpty(row, "FieldCode"), PimDb.TextOrEmpty(row, "ProfileCode"),
      PimDb.Bool(row, "BlocksErp"), PimDb.Bool(row, "BlocksWeb"), PimDb.TextOrEmpty(row, "Severity"),
      PimDb.Int64(row, "IssueCount"), PimDb.Int64(row, "ProductCount")), cancellationToken);

    await NextAsync(reader, cancellationToken);
    var suppliers = await ReadAsync(reader, row => new QualitySupplierImpact(
      PimDb.TextOrEmpty(row, "Supplier"), PimDb.Int64(row, "ProductCount"),
      PimDb.Int64(row, "WithIssuesCount"), PimDb.Int64(row, "IssueCount")), cancellationToken);

    return new(totals, rules, suppliers);
  }

  static object Optional(string? value) =>
    string.IsNullOrWhiteSpace(value) ? DBNull.Value : value.Trim();

  static async Task NextAsync(SqlDataReader reader, CancellationToken cancellationToken)
  {
    if (!await reader.NextResultAsync(cancellationToken))
      throw new InvalidOperationException("Bralna procedura kakovosti ni vrnila vseh pogodbenih naborov.");
  }

  static async Task<IReadOnlyList<T>> ReadAsync<T>(
    SqlDataReader reader, Func<SqlDataReader, T> map, CancellationToken cancellationToken)
  {
    var rows = new List<T>();
    while (await reader.ReadAsync(cancellationToken)) rows.Add(map(reader));
    return rows;
  }
}
