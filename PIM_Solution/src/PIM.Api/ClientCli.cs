using System.Data;
using System.Globalization;
using Microsoft.Data.SqlClient;

namespace PIM.Api;

/// <summary>
/// Skrbnik ključev API-ja iz ukazne vrstice (brez spletnega strežnika):
///
///   PIM.Api.exe odjemalec dodaj --ime "Claude analitika" --podjetja 2,3 --podrocja izdelki,cene,zaloga [--velja-do 2027-12-31] [--na-minuto 120] [--opomba "..."]
///   PIM.Api.exe odjemalec seznam
///   PIM.Api.exe odjemalec spremeni --id 3 [--podjetja vsa|2,3] [--podrocja ...] [--na-minuto N] [--velja-do yyyy-MM-dd | --brez-roka]
///   PIM.Api.exe odjemalec preklici --id 3
///
/// Povezava: --povezava "...", sicer PIM_API_ADMIN_CONNECTION_STRING, sicer ConnectionStrings:PimAdmin, sicer
/// Windows prijava trenutnega uporabnika na strežnik in bazo iz ConnectionStrings:PimApi. Skrbniški postopki
/// (api.Admin_*) so vlogi pim_api_reader prepovedani, zato ukaz poženi kot skrbnik baze, ne kot API.
/// </summary>
public static class ClientCli
{
  public static async Task<int> RunAsync(string[] args)
  {
    // Šumniki v Windows konzoli (privzeto kodna stran 852/1250).
    Console.OutputEncoding = System.Text.Encoding.UTF8;
    if (args.Length == 0 || args[0] is "-h" or "--help" or "pomoc")
    {
      PrintHelp();
      return 0;
    }

    var options = ParseOptions(args[1..]);
    try
    {
      var connectionString = AdminConnection(options);
      return args[0].ToLowerInvariant() switch
      {
        "dodaj" => await CreateAsync(connectionString, options),
        "seznam" => await ListAsync(connectionString),
        "spremeni" => await UpdateAsync(connectionString, options),
        "preklici" or "prekliči" => await RevokeAsync(connectionString, options),
        _ => Fail($"Neznan ukaz »{args[0]}«."),
      };
    }
    catch (SqlException exception) when (exception.Number == 229)
    {
      return Fail("Ta povezava nima pravice upravljati ključev (vloga pim_api_reader je samo za branje). " +
        "Poženi kot skrbnik baze ali podaj --povezava z Windows prijavo skrbnika.");
    }
    catch (SqlException exception) { return Fail(exception.Message); }
    catch (ArgumentException exception) { return Fail(exception.Message); }
  }

  static async Task<int> CreateAsync(string connectionString, Dictionary<string, string?> options)
  {
    var name = Required(options, "ime");
    var scopes = options.GetValueOrDefault("podrocja") ?? string.Join(',', Catalog.Scopes);
    var key = ClientAccess.NewKey();

    await using var connection = await OpenAsync(connectionString);
    await using var command = new SqlCommand("api.Admin_CreateClient", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.AddWithValue("@Name", name);
    command.Parameters.AddWithValue("@KeyPrefix", key[..8]);
    command.Parameters.Add("@KeyHash", SqlDbType.Binary, 32).Value = ClientAccess.Hash(key);
    command.Parameters.AddWithValue("@OrganizationIds", Organizations(options.GetValueOrDefault("podjetja")) ?? (object)DBNull.Value);
    command.Parameters.AddWithValue("@Scopes", scopes.Replace(" ", ""));
    command.Parameters.AddWithValue("@RequestsPerMinute", int.Parse(options.GetValueOrDefault("na-minuto") ?? "120", CultureInfo.InvariantCulture));
    command.Parameters.AddWithValue("@ExpiresUtc", Date(options.GetValueOrDefault("velja-do")) ?? (object)DBNull.Value);
    command.Parameters.AddWithValue("@Note", options.GetValueOrDefault("opomba") ?? (object)DBNull.Value);
    command.Parameters.AddWithValue("@CreatedBy", Actor());
    var clientId = await command.ExecuteScalarAsync();

    Console.WriteLine($"Odjemalec {clientId} »{name}« ustvarjen.");
    Console.WriteLine();
    Console.WriteLine("KLJUČ (prikaže se samo zdaj; v bazi je samo njegov odtis — shrani ga v upravitelj gesel):");
    Console.WriteLine();
    Console.WriteLine("  " + key);
    Console.WriteLine();
    Console.WriteLine("Uporaba: glava  X-Api-Key: " + key[..8] + "…");
    return 0;
  }

  static async Task<int> ListAsync(string connectionString)
  {
    await using var connection = await OpenAsync(connectionString);
    await using var command = new SqlCommand("api.Admin_ListClients", connection) { CommandType = CommandType.StoredProcedure };
    await using var reader = await command.ExecuteReaderAsync();
    Console.WriteLine($"{"Id",-4} {"Ime",-28} {"Ključ",-10} {"Podjetja",-9} {"Področja",-45} {"Stanje",-10} {"Zadnjič",-17} {"Klicev 7d",9}");
    while (await reader.ReadAsync())
    {
      var active = reader.GetBoolean(reader.GetOrdinal("IsActive"));
      var expires = reader["ExpiresUtc"] as DateTime?;
      var state = !active ? "preklican" : expires < DateTime.UtcNow ? "potekel" : "aktiven";
      var lastUsed = reader["LastUsedUtc"] as DateTime?;
      Console.WriteLine($"{reader["ClientId"],-4} {Cut(reader["Name"].ToString()!, 28),-28} {reader["KeyPrefix"] + "…",-10} " +
        $"{(reader["OrganizationIds"] as string ?? "vsa"),-9} {Cut(reader["Scopes"].ToString()!, 45),-45} {state,-10} " +
        $"{(lastUsed?.ToLocalTime().ToString("yyyy-MM-dd HH:mm") ?? "nikoli"),-17} {reader["Requests7d"],9}");
    }
    return 0;
  }

  static async Task<int> UpdateAsync(string connectionString, Dictionary<string, string?> options)
  {
    await using var connection = await OpenAsync(connectionString);
    await using var command = new SqlCommand("api.Admin_UpdateClient", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.AddWithValue("@ClientId", int.Parse(Required(options, "id"), CultureInfo.InvariantCulture));
    var organizations = options.GetValueOrDefault("podjetja");
    command.Parameters.AddWithValue("@OrganizationIds", organizations is null ? DBNull.Value : organizations == "vsa" ? "vsa" : Organizations(organizations)!);
    command.Parameters.AddWithValue("@Scopes", options.GetValueOrDefault("podrocja")?.Replace(" ", "") ?? (object)DBNull.Value);
    command.Parameters.AddWithValue("@RequestsPerMinute", options.TryGetValue("na-minuto", out var rpm) ? int.Parse(rpm!, CultureInfo.InvariantCulture) : DBNull.Value);
    command.Parameters.AddWithValue("@ExpiresUtc", Date(options.GetValueOrDefault("velja-do")) ?? (object)DBNull.Value);
    command.Parameters.AddWithValue("@ClearExpiry", options.ContainsKey("brez-roka"));
    command.Parameters.AddWithValue("@ChangedBy", Actor());
    await command.ExecuteNonQueryAsync();
    Console.WriteLine("Spremenjeno. API spremembo upošteva v največ 60 sekundah.");
    return 0;
  }

  static async Task<int> RevokeAsync(string connectionString, Dictionary<string, string?> options)
  {
    await using var connection = await OpenAsync(connectionString);
    await using var command = new SqlCommand("api.Admin_RevokeClient", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.AddWithValue("@ClientId", int.Parse(Required(options, "id"), CultureInfo.InvariantCulture));
    command.Parameters.AddWithValue("@RevokedBy", Actor());
    await command.ExecuteNonQueryAsync();
    Console.WriteLine("Ključ preklican. API ga zavrne v največ 60 sekundah.");
    return 0;
  }

  static string AdminConnection(Dictionary<string, string?> options)
  {
    if (options.GetValueOrDefault("povezava") is { Length: > 0 } explicitConnection) return explicitConnection;
    if (Environment.GetEnvironmentVariable(ApiSettings.AdminConnectionVariable) is { Length: > 0 } environment) return environment;

    var configuration = new ConfigurationManager();
    configuration.AddJsonFile(Path.Combine(AppContext.BaseDirectory, "appsettings.json"), optional: true);
    ApiSettings.AddLocalFiles(configuration, Directory.GetCurrentDirectory());
    if (configuration.GetConnectionString("PimAdmin") is { Length: > 0 } admin) return admin;

    // Isti strežnik in baza kot API, a z Windows prijavo skrbnika, ki ukaz poganja.
    var apiConnection = ApiSettings.ResolveConnectionString(configuration)
      ?? throw new ArgumentException("Ni povezave: podaj --povezava \"Server=...;Database=PIM;Integrated Security=True;TrustServerCertificate=True\".");
    var builder = new SqlConnectionStringBuilder(apiConnection) { IntegratedSecurity = true };
    builder.Remove("User ID");
    builder.Remove("Password");
    return builder.ConnectionString;
  }

  static async Task<SqlConnection> OpenAsync(string connectionString)
  {
    var connection = new SqlConnection(connectionString);
    await connection.OpenAsync();
    return connection;
  }

  static Dictionary<string, string?> ParseOptions(string[] args)
  {
    var options = new Dictionary<string, string?>(StringComparer.OrdinalIgnoreCase);
    for (var i = 0; i < args.Length; i++)
    {
      if (!args[i].StartsWith("--", StringComparison.Ordinal)) throw new ArgumentException($"Nepričakovan argument »{args[i]}«.");
      var name = args[i][2..];
      options[name] = i + 1 < args.Length && !args[i + 1].StartsWith("--", StringComparison.Ordinal) ? args[++i] : null;
    }
    return options;
  }

  static string Required(Dictionary<string, string?> options, string name) =>
    options.GetValueOrDefault(name) is { Length: > 0 } value ? value : throw new ArgumentException($"Manjka --{name}.");

  static string? Organizations(string? value)
  {
    if (string.IsNullOrWhiteSpace(value) || value == "vsa") return null;
    var ids = value.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
    if (ids.Any(id => !int.TryParse(id, out _))) throw new ArgumentException("--podjetja mora biti seznam številk, npr. 2,3, ali vsa.");
    return string.Join(',', ids);
  }

  static DateTime? Date(string? value) =>
    value is null ? null
    : DateTime.TryParseExact(value, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var date)
      ? date.Date.AddDays(1).AddSeconds(-1).ToUniversalTime()
      : throw new ArgumentException("--velja-do mora biti datum yyyy-MM-dd.");

  static string Actor() => $@"{Environment.UserDomainName}\{Environment.UserName}";
  static string Cut(string value, int length) => value.Length <= length ? value : value[..(length - 1)] + "…";

  static int Fail(string message)
  {
    Console.Error.WriteLine("Napaka: " + message);
    Console.Error.WriteLine("Pomoč: PIM.Api.exe odjemalec pomoc");
    return 1;
  }

  static void PrintHelp() => Console.WriteLine("""
    Ključi odjemalcev PIM API-ja

      PIM.Api.exe odjemalec dodaj --ime "Claude analitika" [--podjetja 2,3] [--podrocja izdelki,cene,zaloga,stranke,nabava,analitika]
                                  [--velja-do 2027-12-31] [--na-minuto 120] [--opomba "..."]
      PIM.Api.exe odjemalec seznam
      PIM.Api.exe odjemalec spremeni --id 3 [--podjetja vsa|2,3] [--podrocja ...] [--na-minuto N] [--velja-do yyyy-MM-dd | --brez-roka]
      PIM.Api.exe odjemalec preklici --id 3

    Brez --podjetja ključ bere vsa aktivna podjetja; brez --podrocja vsa področja.
    Povezava: --povezava "..." ali PIM_API_ADMIN_CONNECTION_STRING; sicer Windows prijava na strežnik iz appsettings.Local.json.
    """);
}
