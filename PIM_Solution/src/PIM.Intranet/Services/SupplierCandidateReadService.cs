using System.Data;
using Microsoft.Data.SqlClient;

namespace PIM.Intranet.Services;

public sealed record SupplierProductCandidateRow(
  long SupplierProductCandidateId, int OrganizationId, string OrganizationName, string SourceCode,
  string ItemId, string? Ean, string Status, bool IsActive, DateTime FirstSeenUtc, DateTime LastSeenUtc,
  int OccurrenceCount, DateTime? DecidedUtc, string? DecidedBy, string? DecisionReason, long? CreatedProductId);

public sealed record SupplierProductCandidateTotals(long TotalCount, long PendingCount, long ApprovedCount, long RejectedCount);

public sealed record SupplierProductCandidatePage(
  IReadOnlyList<SupplierProductCandidateRow> Rows, SupplierProductCandidateTotals Totals);

/// <summary>
/// Bralni model kandidatov za nove artikle od dobaviteljev (219). SQL ostane v migraciji;
/// tu je samo klic procedure in preslikava stolpcev po imenu.
/// </summary>
public sealed class SupplierCandidateReadService(IConfiguration configuration)
{
  string ConnectionString => ConnectionStringResolver.Resolve(configuration)
    ?? throw new InvalidOperationException("Povezava PIM ni nastavljena.");

  public async Task<SupplierProductCandidatePage> GetCandidatesAsync(
    int? organizationId, string? sourceCode, string? status, string? search, int skip, int take,
    CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.GetSupplierProductCandidates", connection)
    { CommandType = CommandType.StoredProcedure, CommandTimeout = 60 };
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = (object?)organizationId ?? DBNull.Value;
    command.Parameters.Add("@SourceCode", SqlDbType.NVarChar, 100).Value = Optional(sourceCode);
    command.Parameters.Add("@Status", SqlDbType.NVarChar, 20).Value = Optional(status);
    command.Parameters.Add("@Search", SqlDbType.NVarChar, 200).Value = Optional(search);
    command.Parameters.Add("@Skip", SqlDbType.Int).Value = skip;
    command.Parameters.Add("@Take", SqlDbType.Int).Value = take;

    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    var rows = new List<SupplierProductCandidateRow>();
    while (await reader.ReadAsync(cancellationToken))
      rows.Add(new(
        PimDb.Int64(reader, "SupplierProductCandidateId"), PimDb.Int32(reader, "OrganizationId"),
        PimDb.TextOrEmpty(reader, "OrganizationName"), PimDb.TextOrEmpty(reader, "SourceCode"),
        PimDb.TextOrEmpty(reader, "ItemID"), PimDb.Text(reader, "EAN"), PimDb.TextOrEmpty(reader, "Status"),
        PimDb.Bool(reader, "IsActive"), PimDb.DateTimeValue(reader, "FirstSeenUtc"), PimDb.DateTimeValue(reader, "LastSeenUtc"),
        PimDb.Int32(reader, "OccurrenceCount"), PimDb.NullableDateTime(reader, "DecidedUtc"), PimDb.Text(reader, "DecidedBy"),
        PimDb.Text(reader, "DecisionReason"), PimDb.NullableInt64(reader, "CreatedProductId")));

    if (!await reader.NextResultAsync(cancellationToken))
      throw new InvalidOperationException("Bralna procedura kandidatov ni vrnila povzetka.");
    var totals = new SupplierProductCandidateTotals(0, 0, 0, 0);
    if (await reader.ReadAsync(cancellationToken))
      totals = new(
        PimDb.Int64(reader, "TotalCount"), PimDb.Int64(reader, "PendingCount"),
        PimDb.Int64(reader, "ApprovedCount"), PimDb.Int64(reader, "RejectedCount"));
    return new(rows, totals);
  }

  static object Optional(string? value) => string.IsNullOrWhiteSpace(value) ? DBNull.Value : value.Trim();
}
