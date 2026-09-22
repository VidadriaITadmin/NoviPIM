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
    if (take is < 1 or > 1000)
      throw new ArgumentOutOfRangeException(nameof(take), "Predogled ima lahko od 1 do 1000 vrstic.");

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

  /// <returns>Število zapisanih podatkovnih vrstic, brez glave; zapiše se v <c>out.ExportRun</c>.</returns>
  public async Task<long> WriteCsvAsync(
    int organizationId, int exportProfileId, string? webSite, bool onlyPublished,
    string? search, Stream output, CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(output);
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = Command(connection, organizationId, exportProfileId, webSite,
      onlyPublished, search, skip: 0, take: 0);
    command.CommandTimeout = 600;

    await using var reader = await command.ExecuteReaderAsync(CommandBehavior.SequentialAccess, cancellationToken);
    await using var writer = new StreamWriter(output, new UTF8Encoding(false), 65_536, leaveOpen: true) { NewLine = "\n" };
    await writer.WriteLineAsync(string.Join(',', Enumerable.Range(0, reader.FieldCount)
      .Select(index => Escape(reader.GetName(index)))).AsMemory(), cancellationToken);

    long rows = 0;
    while (await reader.ReadAsync(cancellationToken))
    {
      var cells = new string[reader.FieldCount];
      for (var index = 0; index < reader.FieldCount; index++)
        cells[index] = Escape(reader.IsDBNull(index)
          ? null
          : Convert.ToString(reader.GetValue(index), CultureInfo.InvariantCulture));
      await writer.WriteLineAsync(string.Join(',', cells).AsMemory(), cancellationToken);
      rows++;
    }
    await writer.FlushAsync(cancellationToken);
    return rows;
  }

  public static string FileName(string profileCode, DateTime utcNow)
  {
    ArgumentException.ThrowIfNullOrWhiteSpace(profileCode);
    var safeProfile = new string(profileCode.Trim().Select(character => char.IsLetterOrDigit(character) || character is '-' or '_'
      ? character : '_').ToArray());
    return $"PIM_splet_{safeProfile}_{utcNow:yyyyMMdd_HHmm}.csv";
  }

  /// <summary>
  /// Uveljavi predlagano ime prenesene datoteke (npr. »katalog.csv«, ki ga izbere stran /splet)
  /// namesto privzetega, casovno zigosanega imena. Ce predlog ni varen, se uporabi privzeto ime.
  /// </summary>
  public static string SafeFileName(string requested, string profileCode, DateTime utcNow)
  {
    var trimmed = requested.Trim();
    if (trimmed.Length == 0) return FileName(profileCode, utcNow);
    var safe = new string(trimmed.Select(character => char.IsLetterOrDigit(character) || character is '-' or '_' or '.'
      ? character : '_').ToArray());
    return safe.EndsWith(".csv", StringComparison.OrdinalIgnoreCase) ? safe : safe + ".csv";
  }

  public static string Escape(string? value)
  {
    return PIM.B2b.RegistryCsvWriter.Escape(value);
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
