using System.Data;
using System.Text.Json;
using Microsoft.Data.SqlClient;

namespace PIM.SaopAnalyticsWorker;

/// <summary>Zapis v shemo ana (migracija 284). Vse gre skozi postopke; worker sam ne piše SQL stavkov v tabele.</summary>
public sealed class AnalyticsStore(string connectionString)
{
  const int ChunkRows = 2000;
  static readonly JsonSerializerOptions Json = new() { DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull };

  public async Task<DateTime?> ReadWatermarkAsync(int organizationId, string stream, CancellationToken ct)
  {
    await using var connection = await OpenAsync(ct);
    await using var command = new SqlCommand("SELECT WatermarkUtc FROM ana.StreamState WHERE OrganizationId=@o AND Stream=@s;", connection);
    command.Parameters.AddWithValue("@o", organizationId);
    command.Parameters.AddWithValue("@s", stream);
    return await command.ExecuteScalarAsync(ct) is DateTime value ? DateTime.SpecifyKind(value, DateTimeKind.Utc) : null;
  }

  public async Task SetStreamStateAsync(int organizationId, string stream, bool succeeded, int? rows, DateTime? watermarkUtc, string? error, CancellationToken ct)
  {
    await using var connection = await OpenAsync(ct);
    await using var command = Procedure(connection, "ana.SetStreamState");
    command.Parameters.AddWithValue("@OrganizationId", organizationId);
    command.Parameters.AddWithValue("@Stream", stream);
    command.Parameters.AddWithValue("@Succeeded", succeeded);
    command.Parameters.AddWithValue("@RowCount", (object?)rows ?? DBNull.Value);
    command.Parameters.AddWithValue("@WatermarkUtc", (object?)watermarkUtc ?? DBNull.Value);
    command.Parameters.AddWithValue("@Error", (object?)error?[..Math.Min(2000, error.Length)] ?? DBNull.Value);
    await command.ExecuteNonQueryAsync(ct);
  }

  public async Task SavePageAsync(int organizationId, string stream, Guid? runId, int page, string url, string xml, int records, CancellationToken ct)
  {
    await using var connection = await OpenAsync(ct);
    await using var command = Procedure(connection, "ana.SaveSourcePage");
    command.Parameters.AddWithValue("@OrganizationId", organizationId);
    command.Parameters.AddWithValue("@Stream", stream);
    command.Parameters.AddWithValue("@RunId", (object?)runId ?? DBNull.Value);
    command.Parameters.AddWithValue("@PageNumber", page);
    command.Parameters.AddWithValue("@RequestUrl", url.Length > 1000 ? url[..1000] : url);
    command.Parameters.Add("@PayloadXml", SqlDbType.NVarChar, -1).Value = xml;
    command.Parameters.AddWithValue("@RecordCount", records);
    await command.ExecuteNonQueryAsync(ct);
  }

  /// <summary>Surove strani toka iz zadnjih dni (za --razcleni-znova), od najstarejše do najnovejše.</summary>
  public async IAsyncEnumerable<(string Url, string Xml)> ReadPagesAsync(int organizationId, string stream, int days,
    [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken ct)
  {
    await using var connection = await OpenAsync(ct);
    await using var command = new SqlCommand(
      "SELECT RequestUrl, PayloadXml FROM ana.SourcePage WHERE OrganizationId=@o AND Stream=@s AND FetchedUtc >= DATEADD(day, -@d, SYSUTCDATETIME()) ORDER BY SourcePageId;",
      connection) { CommandTimeout = 600 };
    command.Parameters.AddWithValue("@o", organizationId);
    command.Parameters.AddWithValue("@s", stream);
    command.Parameters.AddWithValue("@d", days);
    await using var reader = await command.ExecuteReaderAsync(CommandBehavior.SequentialAccess, ct);
    while (await reader.ReadAsync(ct)) yield return (reader.GetString(0), reader.GetString(1));
  }

  /// <summary>Vrstice računov: vse vrstice istega računa gredo v isti kos (postopek račun zamenja v celoti).</summary>
  public async Task<int> UpsertInvoiceLinesAsync(int organizationId, IReadOnlyList<InvoiceLineRow> lines, CancellationToken ct)
  {
    var written = 0;
    var chunk = new List<InvoiceLineRow>();
    foreach (var invoice in lines.GroupBy(l => (l.InvoiceYear, l.InvoiceBook, l.InvoiceNumber)))
    {
      chunk.AddRange(invoice);
      if (chunk.Count >= ChunkRows) { written += await ExecuteJsonAsync("ana.UpsertSalesInvoiceLines", organizationId, chunk, ct); chunk.Clear(); }
    }
    if (chunk.Count > 0) written += await ExecuteJsonAsync("ana.UpsertSalesInvoiceLines", organizationId, chunk, ct);
    return written;
  }

  public Task<int> UpsertCustomerOrderLinesAsync(int organizationId, IReadOnlyList<CustomerOrderLineRow> rows, CancellationToken ct) =>
    ChunkedAsync("ana.UpsertCustomerOrderLines", organizationId, rows, ct);

  public Task<int> UpsertPurchaseOrderLinesAsync(int organizationId, IReadOnlyList<PurchaseOrderLineRow> rows, CancellationToken ct) =>
    ChunkedAsync("ana.UpsertPurchaseOrderLines", organizationId, rows, ct);

  public Task<int> UpsertItemPurchaseInfoAsync(int organizationId, IReadOnlyList<ItemPurchaseInfoRow> rows, CancellationToken ct) =>
    ChunkedAsync("ana.UpsertItemPurchaseInfo", organizationId, rows, ct);

  /// <summary>Preračun kazalnikov (ana.RefreshAnalytics); vrne povzetek zadnjega rezultata.</summary>
  public async Task<RefreshSummary> RefreshAsync(int organizationId, CancellationToken ct)
  {
    await using var connection = await OpenAsync(ct);
    await using var command = Procedure(connection, "ana.RefreshAnalytics");
    command.CommandTimeout = 1800;
    command.Parameters.AddWithValue("@OrganizationId", organizationId);
    await using var reader = await command.ExecuteReaderAsync(ct);
    RefreshSummary? summary = null;
    do
    {
      while (await reader.ReadAsync(ct))
      {
        if (reader.FieldCount >= 6 && reader.GetName(0) == "DemandSource")
          summary = new RefreshSummary(reader.GetString(0), reader.GetInt32(1), reader.GetInt32(2), reader.GetInt32(3), reader.GetInt32(4), reader.GetInt32(5));
      }
    } while (await reader.NextResultAsync(ct));
    return summary ?? throw new InvalidOperationException("ana.RefreshAnalytics ni vrnil povzetka.");
  }

  async Task<int> ChunkedAsync<T>(string procedure, int organizationId, IReadOnlyList<T> rows, CancellationToken ct)
  {
    var written = 0;
    foreach (var chunk in rows.Chunk(ChunkRows)) written += await ExecuteJsonAsync(procedure, organizationId, chunk, ct);
    return written;
  }

  async Task<int> ExecuteJsonAsync<T>(string procedure, int organizationId, IReadOnlyCollection<T> rows, CancellationToken ct)
  {
    await using var connection = await OpenAsync(ct);
    await using var command = Procedure(connection, procedure);
    command.CommandTimeout = 600;
    command.Parameters.AddWithValue("@OrganizationId", organizationId);
    command.Parameters.Add("@Json", SqlDbType.NVarChar, -1).Value = JsonSerializer.Serialize(rows, Json);
    await command.ExecuteNonQueryAsync(ct);
    return rows.Count;
  }

  async Task<SqlConnection> OpenAsync(CancellationToken ct)
  {
    var connection = new SqlConnection(connectionString);
    await connection.OpenAsync(ct);
    return connection;
  }

  static SqlCommand Procedure(SqlConnection connection, string name) =>
    new(name, connection) { CommandType = CommandType.StoredProcedure, CommandTimeout = 120 };
}

public sealed record RefreshSummary(string DemandSource, int Items, int ToOrder, int Stockouts, int Dead, int Overstock);
