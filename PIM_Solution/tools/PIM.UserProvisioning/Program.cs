using System.Text.Json;
using Microsoft.Data.SqlClient;
using PIM.Intranet.Services;
using PIM.Operations;

var userName = ReadOption(args, "--user") ?? "admin";
var displayName = ReadOption(args, "--name") ?? "Administrator";
var connectionString = ReadConnectionString();
if (string.IsNullOrWhiteSpace(connectionString))
{
  Console.Error.WriteLine("Manjka PIM_CONNECTION_STRING oziroma appsettings.Local.json.");
  return 2;
}

Console.WriteLine($"Ustvarjanje lokalnega uporabnika '{userName}' z vlogo ADMIN v bazi PIM.");
Console.Write("Geslo: ");
var password = ReadPassword();
Console.WriteLine();
Console.Write("Ponovi geslo: ");
var confirmation = ReadPassword();
Console.WriteLine();
if (string.IsNullOrWhiteSpace(password) || password != confirmation)
{
  Console.Error.WriteLine("Gesli se ne ujemata ali sta prazni; baza ni bila spremenjena.");
  return 2;
}

// Dolzina je samo priporocilo, enako kot na /sistem/uporabniki; racun se ustvari vseeno.
if (IntranetUserAdministrationService.PasswordAdvice(password) is { } advice)
  Console.WriteLine(advice);

var passwordHash = PasswordHasher.Hash(password);
await using var connection = new SqlConnection(connectionString);
await connection.OpenAsync();
await using var command = new SqlCommand("sec.CreateLocalUser", connection) { CommandType = System.Data.CommandType.StoredProcedure };
command.Parameters.AddWithValue("@UserName", userName);
command.Parameters.AddWithValue("@DisplayName", displayName);
command.Parameters.AddWithValue("@PasswordHash", passwordHash);
command.Parameters.AddWithValue("@RoleCode", "ADMIN");
var userId = await command.ExecuteScalarAsync();
Console.WriteLine($"Administrator '{userName}' je ustvarjen (LocalUserId={userId}).");
return 0;

static string? ReadOption(string[] arguments, string name)
{
  var index = Array.FindIndex(arguments, argument => string.Equals(argument, name, StringComparison.OrdinalIgnoreCase));
  return index >= 0 && index + 1 < arguments.Length ? arguments[index + 1].Trim() : null;
}

static string ReadPassword()
{
  var buffer = new List<char>();
  while (true)
  {
    var key = Console.ReadKey(intercept: true);
    if (key.Key == ConsoleKey.Enter) break;
    if (key.Key == ConsoleKey.Backspace)
    {
      if (buffer.Count > 0) buffer.RemoveAt(buffer.Count - 1);
      continue;
    }

    if (!char.IsControl(key.KeyChar)) buffer.Add(key.KeyChar);
  }

  return new string(buffer.ToArray());
}

static string? ReadConnectionString() => LocalSettings.ConnectionString();
