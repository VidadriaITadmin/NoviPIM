using System.Data;
using Microsoft.Data.SqlClient;

namespace PIM.Intranet.Services;

public sealed record BusinessCheckRow(
  long ProductId, string ItemId, string Name, string CheckCode, string Context,
  string Detail, DateTime? ObservedUtc, decimal? SalesPrice, decimal? PurchasePrice,
  decimal? MarginFactor, string? UnitBasis);


public sealed record AttributeValueRow(
  string AttributeCode, string Value, long ProductCount, string? Translation,
  string? SourceCode, bool UsedOnWeb, long MissingTranslationCount);

public sealed record ExportPreview(IReadOnlyList<string> Columns, IReadOnlyList<IReadOnlyList<string?>> Rows);

/// <summary>
/// Bralni modeli naslednje bazne faze. Manjkajoča procedura je pričakovano stanje in se vrne
/// posebej; druge SQL napake ostanejo napake, da jih vmesnik ne bi prikril kot načrtovano vrzel.
/// </summary>
public sealed class IntranetFeatureReadService(IConfiguration configuration)
{
  string ConnectionString => ConnectionStringResolver.Resolve(configuration)
    ?? throw new InvalidOperationException("Povezava PIM ni nastavljena.");

  public Task<PimReadResult<BusinessCheckRow>> GetPriceChecksAsync(
    int organizationId, long? productId = null, string? checkCode = null, string? context = null,
    string? search = null, int skip = 0, int take = 50, CancellationToken cancellationToken = default) =>
    GetChecksAsync("intranet.GetPriceChecks", organizationId, productId, checkCode, context, search, skip, take, cancellationToken);

  public Task<PimReadResult<BusinessCheckRow>> GetStockChecksAsync(
    int organizationId, long? productId = null, string? checkCode = null, string? context = null,
    string? search = null, int skip = 0, int take = 50, CancellationToken cancellationToken = default) =>
    GetChecksAsync("intranet.GetStockChecks", organizationId, productId, checkCode, context, search, skip, take, cancellationToken);

  async Task<PimReadResult<BusinessCheckRow>> GetChecksAsync(
    string procedure, int organizationId, long? productId, string? checkCode, string? context,
    string? search, int skip, int take, CancellationToken cancellationToken)
  {
    try
    {
      await using var connection = await OpenAsync(cancellationToken);
      await using var command = Procedure(procedure, connection);
      command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
      command.Parameters.Add("@ProductId", SqlDbType.BigInt).Value = productId ?? (object)DBNull.Value;
      command.Parameters.Add("@CheckCode", SqlDbType.NVarChar, 60).Value = Optional(checkCode);
      command.Parameters.Add("@Context", SqlDbType.NVarChar, 100).Value = Optional(context);
      command.Parameters.Add("@Search", SqlDbType.NVarChar, 200).Value = Optional(search);
      command.Parameters.Add("@Skip", SqlDbType.Int).Value = skip;
      command.Parameters.Add("@Take", SqlDbType.Int).Value = take;
      await using var reader = await command.ExecuteReaderAsync(cancellationToken);
      var rows = await ReadAsync(reader, row => new BusinessCheckRow(
        PimDb.Int64(row, "ProductId"), PimDb.TextOrEmpty(row, "ItemID"), PimDb.TextOrEmpty(row, "Name"),
        PimDb.TextOrEmpty(row, "CheckCode"), PimDb.TextOrEmpty(row, "Context"), PimDb.TextOrEmpty(row, "Detail"),
        PimDb.NullableDateTime(row, "ObservedUtc"), PimDb.NullableDecimal(row, "SalesPrice"),
        PimDb.NullableDecimal(row, "PurchasePrice"), PimDb.NullableDecimal(row, "MarginFactor"),
        PimDb.Text(row, "UnitBasis")), cancellationToken);
      var total = await ReadTotalAsync(reader, cancellationToken);
      return new(rows, total);
    }
    catch (SqlException error) when (PimReadModel.IsMissingReadModel(error))
    {
      return PimReadResult<BusinessCheckRow>.Missing(procedure);
    }
  }

  public async Task<PimReadResult<AttributeValueRow>> GetAttributeValuesAsync(
    int organizationId, string attributeCode, int skip = 0, int take = 50,
    CancellationToken cancellationToken = default)
  {
    const string procedure = "intranet.GetAttributeValues";
    try
    {
      await using var connection = await OpenAsync(cancellationToken);
      await using var command = Procedure(procedure, connection);
      command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
      command.Parameters.Add("@AttributeCode", SqlDbType.NVarChar, 200).Value = attributeCode;
      command.Parameters.Add("@Skip", SqlDbType.Int).Value = skip;
      command.Parameters.Add("@Take", SqlDbType.Int).Value = take;
      await using var reader = await command.ExecuteReaderAsync(cancellationToken);
      var rows = await ReadAsync(reader, row => new AttributeValueRow(
        PimDb.TextOrEmpty(row, "AttributeCode"), PimDb.TextOrEmpty(row, "Value"),
        PimDb.Int64(row, "ProductCount"), PimDb.Text(row, "Translation"),
        PimDb.Text(row, "SourceCode"), PimDb.Bool(row, "UsedOnWeb"),
        PimDb.Int64(row, "MissingTranslationCount")), cancellationToken);
      return new(rows, await ReadTotalAsync(reader, cancellationToken));
    }
    catch (SqlException error) when (PimReadModel.IsMissingReadModel(error))
    {
      return PimReadResult<AttributeValueRow>.Missing(procedure);
    }
  }

  public async Task<(ExportPreview? Preview, string? MissingObject)> GetExportPreviewAsync(
    int organizationId, int exportProfileId, int take = 20, CancellationToken cancellationToken = default)
  {
    const string procedure = "intranet.GetExportPreview";
    try
    {
      await using var connection = await OpenAsync(cancellationToken);
      await using var command = Procedure(procedure, connection);
      command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
      command.Parameters.Add("@ExportProfileId", SqlDbType.Int).Value = exportProfileId;
      command.Parameters.Add("@Take", SqlDbType.Int).Value = take;
      await using var reader = await command.ExecuteReaderAsync(cancellationToken);
      var columns = Enumerable.Range(0, reader.FieldCount).Select(reader.GetName).ToArray();
      var rows = new List<IReadOnlyList<string?>>();
      while (await reader.ReadAsync(cancellationToken))
        rows.Add(Enumerable.Range(0, reader.FieldCount)
          .Select(index => reader.IsDBNull(index) ? null : Convert.ToString(reader.GetValue(index)))
          .ToArray());
      return (new(columns, rows), null);
    }
    catch (SqlException error) when (PimReadModel.IsMissingReadModel(error))
    {
      return (null, procedure);
    }
  }

  async Task<SqlConnection> OpenAsync(CancellationToken cancellationToken)
  {
    var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    return connection;
  }

  static SqlCommand Procedure(string name, SqlConnection connection) => new(name, connection)
  {
    CommandType = CommandType.StoredProcedure,
    CommandTimeout = 60,
  };

  static object Optional(string? value) => string.IsNullOrWhiteSpace(value) ? DBNull.Value : value.Trim();

  static async Task<long> ReadTotalAsync(SqlDataReader reader, CancellationToken cancellationToken) =>
    await reader.NextResultAsync(cancellationToken) && await reader.ReadAsync(cancellationToken)
      ? Convert.ToInt64(reader.GetValue(0))
      : 0;

  static async Task<IReadOnlyList<T>> ReadAsync<T>(
    SqlDataReader reader, Func<SqlDataReader, T> map, CancellationToken cancellationToken)
  {
    var rows = new List<T>();
    while (await reader.ReadAsync(cancellationToken)) rows.Add(map(reader));
    return rows;
  }
}
