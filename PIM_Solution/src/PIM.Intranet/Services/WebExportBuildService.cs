using System.Data;
using System.Globalization;
using System.Text;
using Microsoft.Data.SqlClient;

namespace PIM.Intranet.Services;

public sealed record WebExportPage(
  IReadOnlyList<string> Columns,
  IReadOnlyList<IReadOnlyList<string?>> Rows,
  int TotalCount,
  int Skip,
  int Take);

/// <summary>
/// Predogled in pretočni CSV istega registrskega nabora <c>intranet.GetWebExportRows</c>.
/// Predogled zadrži največ eno stran; prenos nikoli ne sestavi cele datoteke v pomnilniku.
/// </summary>
public sealed class WebExportBuildService(IConfiguration configuration)
{
  string ConnectionString => ConnectionStringResolver.Resolve(configuration)
    ?? throw new InvalidOperationException("Povezava PIM ni nastavljena.");

  public async Task<WebExportPage> PreviewAsync(
    int organizationId, int exportProfileId, string? webSite, bool onlyPublished,
    string? search, int skip = 0, int take = 200, CancellationToken cancellationToken = default)
  {
    if (take is < 1 or > 200)
      throw new ArgumentOutOfRangeException(nameof(take), "Predogled ima lahko od 1 do 200 vrstic.");

    await using var connection = await OpenAsync(cancellationToken);
    await using var command = Command(connection, organizationId, exportProfileId, webSite,
      onlyPublished, search, skip, take);
    var total = command.Parameters["@TotalCount"];
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    var columns = Enumerable.Range(0, reader.FieldCount).Select(reader.GetName).ToArray();
    var rows = new List<IReadOnlyList<string?>>();
    while (await reader.ReadAsync(cancellationToken))
      rows.Add(ReadRow(reader));
    await reader.CloseAsync();

    return new(columns, rows, total.Value is DBNull ? 0 : Convert.ToInt32(total.Value), skip, take);
  }

  public async Task WriteCsvAsync(
    int organizationId, int exportProfileId, string? webSite, bool onlyPublished,
    string? search, Stream output, CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(output);
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = Command(connection, organizationId, exportProfileId, webSite,
      onlyPublished, search, skip: 0, take: 0);
    command.CommandTimeout = 600;

    await using var reader = await command.ExecuteReaderAsync(CommandBehavior.SequentialAccess, cancellationToken);
    await using var writer = new StreamWriter(output, new UTF8Encoding(true), 65_536, leaveOpen: true);
    await writer.WriteLineAsync(string.Join(';', Enumerable.Range(0, reader.FieldCount)
      .Select(index => Escape(reader.GetName(index)))).AsMemory(), cancellationToken);

    while (await reader.ReadAsync(cancellationToken))
    {
      var cells = new string[reader.FieldCount];
      for (var index = 0; index < reader.FieldCount; index++)
        cells[index] = Escape(reader.IsDBNull(index)
          ? null
          : Convert.ToString(reader.GetValue(index), CultureInfo.InvariantCulture));
      await writer.WriteLineAsync(string.Join(';', cells).AsMemory(), cancellationToken);
    }
    await writer.FlushAsync(cancellationToken);
  }

  public static string FileName(string profileCode, DateTime utcNow)
  {
    ArgumentException.ThrowIfNullOrWhiteSpace(profileCode);
    var safeProfile = new string(profileCode.Trim().Select(character => char.IsLetterOrDigit(character) || character is '-' or '_'
      ? character : '_').ToArray());
    return $"PIM_splet_{safeProfile}_{utcNow:yyyyMMdd_HHmm}.csv";
  }

  public static string Escape(string? value)
  {
    if (string.IsNullOrEmpty(value)) return string.Empty;
    var escaped = value.Replace("\"", "\"\"", StringComparison.Ordinal);
    return value.IndexOfAny([';', '"', '\r', '\n']) >= 0 ? $"\"{escaped}\"" : escaped;
  }

  SqlCommand Command(
    SqlConnection connection, int organizationId, int exportProfileId, string? webSite,
    bool onlyPublished, string? search, int skip, int take)
  {
    var command = new SqlCommand("intranet.GetWebExportRows", connection)
    {
      CommandType = CommandType.StoredProcedure,
      CommandTimeout = 120,
    };
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@ExportProfileId", SqlDbType.Int).Value = exportProfileId;
    command.Parameters.Add("@WebSite", SqlDbType.NVarChar, 100).Value = Optional(webSite);
    command.Parameters.Add("@OnlyPublished", SqlDbType.Bit).Value = onlyPublished;
    command.Parameters.Add("@Search", SqlDbType.NVarChar, 200).Value = Optional(search);
    command.Parameters.Add("@Skip", SqlDbType.Int).Value = skip;
    command.Parameters.Add("@Take", SqlDbType.Int).Value = take;
    command.Parameters.Add("@TotalCount", SqlDbType.Int).Direction = ParameterDirection.Output;
    return command;
  }

  async Task<SqlConnection> OpenAsync(CancellationToken cancellationToken)
  {
    var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    return connection;
  }

  static IReadOnlyList<string?> ReadRow(SqlDataReader reader) =>
    Enumerable.Range(0, reader.FieldCount)
      .Select(index => reader.IsDBNull(index)
        ? null
        : Convert.ToString(reader.GetValue(index), CultureInfo.CurrentCulture))
      .ToArray();

  static object Optional(string? value) => string.IsNullOrWhiteSpace(value) ? DBNull.Value : value.Trim();
}
