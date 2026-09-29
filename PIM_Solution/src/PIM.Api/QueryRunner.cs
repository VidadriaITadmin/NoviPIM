using System.Data;
using System.Globalization;
using Microsoft.Data.SqlClient;

namespace PIM.Api;

/// <summary>Napaka, ki jo odjemalec lahko popravi (napačen parameter, brez pravic, ni najdeno).</summary>
public sealed class ApiException(int status, string message, IReadOnlyList<string>? details = null) : Exception(message)
{
  public int Status { get; } = status;
  public IReadOnlyList<string> Details { get; } = details ?? [];
}

/// <summary>Izid klica: telo odgovora (za JSON), vrstice (za CSV) in podjetje (za dnevnik).</summary>
public sealed record QueryResult(object Body, IReadOnlyList<Dictionary<string, object?>> Rows, int? OrganizationId);

/// <summary>
/// Preveri parametre po <see cref="Catalog"/> in izvede bralni postopek sheme api. Isto pot uporabljata
/// HTTP (/api/v1/...) in MCP (/mcp), zato se obnašata enako.
/// </summary>
public sealed class QueryRunner(ApiSettings settings, ClientAccess access)
{
  static readonly CultureInfo Invariant = CultureInfo.InvariantCulture;

  public async Task<QueryResult> RunAsync(EndpointDef endpoint, IReadOnlyDictionary<string, string?> input, ApiClient client,
    CancellationToken cancellationToken, IEnumerable<string>? extraAllowed = null)
  {
    if (!client.HasScope(endpoint.Scope))
      throw new ApiException(403, $"Ključ nima področja »{endpoint.Scope}«. Skrbnik ga doda z: PIM.Api.exe odjemalec spremeni --id {client.ClientId} --podrocja ...");

    var definitions = Catalog.AllParams(endpoint).ToList();
    var allowed = definitions.Select(p => p.Name).Concat(extraAllowed ?? []).ToHashSet(StringComparer.OrdinalIgnoreCase);
    var errors = new List<string>();
    foreach (var name in input.Keys.Where(k => !allowed.Contains(k)))
      errors.Add($"Neznan parameter »{name}«. Dovoljeni: {string.Join(", ", definitions.Select(p => p.Name))}.");

    var allowedOrganizations = await access.AllowedOrganizationsAsync(client, cancellationToken);
    var values = new List<(ParamDef Definition, object Value)>();
    int? organizationId = null;

    foreach (var definition in definitions)
    {
      var raw = input.FirstOrDefault(pair => string.Equals(pair.Key, definition.Name, StringComparison.OrdinalIgnoreCase)).Value?.Trim();
      if (string.IsNullOrEmpty(raw))
      {
        if (definition.Name == "organizationId")
        {
          if (allowedOrganizations.Length == 1) { organizationId = allowedOrganizations[0]; values.Add((definition, organizationId)); }
          else errors.Add($"Parameter organizationId je obvezen. Ključ sme brati podjetja: {string.Join(", ", allowedOrganizations)}.");
        }
        else if (definition.Required) errors.Add($"Parameter {definition.Name} je obvezen.");
        continue;
      }

      if (!TryParse(definition, raw, out var value, out var error)) { errors.Add(error!); continue; }
      if (definition.Name == "organizationId")
      {
        organizationId = (int)value;
        if (!allowedOrganizations.Contains(organizationId.Value))
          throw new ApiException(403, $"Ključ nima dostopa do podjetja {organizationId}. Dovoljena: {string.Join(", ", allowedOrganizations)}.");
      }
      values.Add((definition, value));
    }

    if (errors.Count > 0) throw new ApiException(400, "Napačni parametri.", errors);

    await using var connection = new SqlConnection(settings.ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand(endpoint.Procedure, connection)
    {
      CommandType = CommandType.StoredProcedure,
      CommandTimeout = settings.CommandTimeoutSeconds,
    };
    foreach (var (definition, value) in values) command.Parameters.Add(ToSqlParameter(definition, value));
    SqlParameter? total = null;
    if (endpoint.Kind == EndpointKind.Paged)
    {
      total = command.Parameters.Add("@TotalCount", SqlDbType.Int);
      total.Direction = ParameterDirection.Output;
    }

    var sets = new List<List<Dictionary<string, object?>>>();
    await using (var reader = await command.ExecuteReaderAsync(cancellationToken))
    {
      do sets.Add(await ReadSetAsync(reader, cancellationToken));
      while (await reader.NextResultAsync(cancellationToken));
    }

    return endpoint.Kind switch
    {
      EndpointKind.Paged => Paged(endpoint, sets[0], total?.Value is int count ? count : sets[0].Count, values, organizationId),
      EndpointKind.Rows => Rows(endpoint, sets[0], allowedOrganizations, organizationId),
      _ => Detail(endpoint, sets, client, organizationId),
    };
  }

  static QueryResult Paged(EndpointDef endpoint, List<Dictionary<string, object?>> rows, int total,
    List<(ParamDef Definition, object Value)> values, int? organizationId)
  {
    var skip = values.FirstOrDefault(v => v.Definition.Name == "skip").Value as int? ?? 0;
    var body = new Dictionary<string, object?>
    {
      ["organizationId"] = organizationId,
      ["total"] = total,
      ["skip"] = skip,
      ["count"] = rows.Count,
      ["hasMore"] = skip + rows.Count < total,
      ["items"] = rows,
    };
    return new QueryResult(body, rows, organizationId);
  }

  static QueryResult Rows(EndpointDef endpoint, List<Dictionary<string, object?>> rows, int[] allowedOrganizations, int? organizationId)
  {
    // Seznam podjetij pokaže samo podjetja, ki jih ključ sme brati.
    if (!endpoint.NeedsOrganization && endpoint.Tool == "list_organizations")
      rows = rows.Where(r => r["organizationId"] is int id && allowedOrganizations.Contains(id)).ToList();
    var body = new Dictionary<string, object?> { ["organizationId"] = organizationId, ["count"] = rows.Count, ["items"] = rows };
    if (organizationId is null) body.Remove("organizationId");
    return new QueryResult(body, rows, organizationId);
  }

  static QueryResult Detail(EndpointDef endpoint, List<List<Dictionary<string, object?>>> sets, ApiClient client, int? organizationId)
  {
    var names = endpoint.Sets ?? [];
    if (sets.Count == 0 || sets[0].Count == 0)
      throw new ApiException(404, "Ni najdeno v tem podjetju.");

    var body = new Dictionary<string, object?> { ["organizationId"] = organizationId };
    for (var i = 0; i < names.Length && i < sets.Count; i++)
    {
      if (names[i].Scope is { } scope && !client.HasScope(scope)) continue;
      body[names[i].Name] = i == 0 ? sets[0][0] : sets[i];
    }
    return new QueryResult(body, sets[0], organizationId);
  }

  static async Task<List<Dictionary<string, object?>>> ReadSetAsync(SqlDataReader reader, CancellationToken cancellationToken)
  {
    var names = Enumerable.Range(0, reader.FieldCount).Select(i => CamelCase(reader.GetName(i))).ToArray();
    var rows = new List<Dictionary<string, object?>>();
    while (await reader.ReadAsync(cancellationToken))
    {
      var row = new Dictionary<string, object?>(names.Length);
      for (var i = 0; i < names.Length; i++) row[names[i]] = Normalize(reader.GetValue(i));
      rows.Add(row);
    }
    return rows;
  }

  /// <summary>Brez repa ničel (54.0000 → 54), datum brez ure, kjer ure ni.</summary>
  static object? Normalize(object value) => value switch
  {
    DBNull => null,
    decimal number => number / 1.0000000000000000000000000000m,
    DateTime date when date.TimeOfDay == TimeSpan.Zero => date.ToString("yyyy-MM-dd", Invariant),
    DateTime date => DateTime.SpecifyKind(date, DateTimeKind.Utc),
    string text => text.Trim(),
    byte[] bytes => Convert.ToBase64String(bytes),
    _ => value,
  };

  static string CamelCase(string name) => name.Length == 0 ? name : char.ToLowerInvariant(name[0]) + name[1..];

  static bool TryParse(ParamDef definition, string raw, out object value, out string? error)
  {
    value = raw;
    error = null;
    switch (definition.Type)
    {
      case ParamType.Int when int.TryParse(raw, NumberStyles.Integer, Invariant, out var number) && number >= 0:
        value = number; break;
      case ParamType.Int:
        error = $"{definition.Name} mora biti celo število >= 0 (dobil: {raw})."; return false;
      case ParamType.Bool:
        switch (raw.ToLowerInvariant())
        {
          case "true" or "1" or "da" or "yes": value = true; break;
          case "false" or "0" or "ne" or "no": value = false; break;
          default: error = $"{definition.Name} mora biti true ali false (dobil: {raw})."; return false;
        }
        break;
      case ParamType.Date or ParamType.DateTime:
        if (!DateTime.TryParse(raw, Invariant, DateTimeStyles.AssumeLocal, out var date))
        { error = $"{definition.Name} mora biti datum yyyy-MM-dd (dobil: {raw})."; return false; }
        value = date; break;
      case ParamType.Decimal:
        if (!decimal.TryParse(raw.Replace(',', '.'), NumberStyles.Number, Invariant, out var amount))
        { error = $"{definition.Name} mora biti število (dobil: {raw})."; return false; }
        value = amount; break;
      default:
        if (raw.Length > (definition.Type == ParamType.List ? 20000 : 200))
        { error = $"{definition.Name} je predolg."; return false; }
        break;
    }

    if (definition.Values is { } allowed)
    {
      var match = allowed.FirstOrDefault(a => string.Equals(a, raw, StringComparison.OrdinalIgnoreCase));
      if (match is null) { error = $"{definition.Name} mora biti eno od: {string.Join(", ", allowed)} (dobil: {raw})."; return false; }
      value = match;
    }
    return true;
  }

  static SqlParameter ToSqlParameter(ParamDef definition, object value) => definition.Type switch
  {
    ParamType.Int => new SqlParameter(definition.Sql, SqlDbType.Int) { Value = value },
    ParamType.Bool => new SqlParameter(definition.Sql, SqlDbType.Bit) { Value = value },
    ParamType.Date => new SqlParameter(definition.Sql, SqlDbType.Date) { Value = ((DateTime)value).Date },
    ParamType.DateTime => new SqlParameter(definition.Sql, SqlDbType.DateTime2) { Value = value },
    ParamType.Decimal => new SqlParameter(definition.Sql, SqlDbType.Decimal) { Value = value, Precision = 19, Scale = 4 },
    ParamType.List => new SqlParameter(definition.Sql, SqlDbType.NVarChar, -1) { Value = value },
    _ => new SqlParameter(definition.Sql, SqlDbType.NVarChar, 200) { Value = value },
  };
}
