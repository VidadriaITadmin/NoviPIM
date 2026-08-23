using System.Data;
using System.Globalization;
using Microsoft.Data.SqlClient;
using PIM.Outbound;

// Predogled dokumentov za SAOP.
//
// Zakaj obstaja: preden gre v SAOP karkoli v živo, mora biti mogoče videti točno tisto, kar bi
// šlo — za resnične artikle, ne za izmišljene. Orodje samo bere: odpre povezavo na razvojno
// bazo PIM, sestavi dokument in ga zapiše v datoteko. Nobenega HTTP klica ne naredi in v bazo
// ne piše ničesar.
//
//   dotnet run --project tools\PIM.SaopXmlPreview -- --org 2 --items NW.12603,NW.0010
//   dotnet run --project tools\PIM.SaopXmlPreview -- --org 2 --sample 5 --out C:\pot\do\mape

var options = Options.Parse(args);
if (options is null) return 2;

var connectionString = Environment.GetEnvironmentVariable("PIM_CONNECTION_STRING");
if (string.IsNullOrWhiteSpace(connectionString))
{
  Console.Error.WriteLine("PIM_CONNECTION_STRING ni nastavljen.");
  return 2;
}

await using var connection = new SqlConnection(connectionString);
await connection.OpenAsync();

var contract = await ReadContractAsync(connection);
var builder = new SaopItemXmlBuilder(contract);
var items = options.Items.Count > 0 ? options.Items : await ReadSampleAsync(connection, options.OrganizationId, options.Sample);

if (items.Count == 0)
{
  Console.Error.WriteLine($"Za organizacijo {options.OrganizationId} ni artiklov za predogled.");
  return 1;
}

Directory.CreateDirectory(options.OutputDirectory);
Console.WriteLine($"Organizacija {options.OrganizationId}, artiklov {items.Count}, mapa {options.OutputDirectory}");
Console.WriteLine($"{"Artikel",-24}{"Metoda",-9}{"Polj",-6}{"Manjka za ADD",-40}Datoteka");

// Žig je za vse artikle isti, da sta dva zaporedna predogleda istega artikla primerljiva;
// pri pravem pošiljanju ga postavi pošiljatelj.
var stamp = DateTime.UtcNow;
var withProblems = 0;
var zeroed = new List<string>();

foreach (var itemId in items)
{
  var state = await ReadStateAsync(connection, options.OrganizationId, itemId);
  if (state is null)
  {
    Console.WriteLine($"{itemId,-24}{"—",-9}{"—",-6}{"artikla v organizaciji ni",-40}");
    withProblems++;
    continue;
  }

  var decision = SaopIntentResolver.Resolve(new(state.ExistsInSaop));
  var built = builder.Build(decision.Intent, itemId, state.Values, state.Defaults, stamp,
    suggestFirstFreeCode: decision.Intent == SaopIntent.Add && options.SuggestFirstFreeCode);

  var fileName = $"{Safe(itemId)}.{(decision.Intent == SaopIntent.Add ? "ADD" : "PATCH")}.xml";
  await File.WriteAllTextAsync(Path.Combine(options.OutputDirectory, fileName), built.Xml);

  var missing = built.MissingMandatory.Count == 0 ? "—" : string.Join(", ", built.MissingMandatory);
  if (built.MissingMandatory.Count > 0) withProblems++;
  Console.WriteLine($"{itemId,-24}{SaopIntentResolver.HttpOperation(decision.Intent),-9}{built.ElementCount,-6}{Shorten(missing),-40}{fileName}");

  foreach (var zero in Zeros(built.Xml)) zeroed.Add($"{itemId}: {zero}");
}

Console.WriteLine();
Console.WriteLine(withProblems == 0
  ? "Vsi dokumenti so popolni. Nič ni bilo poslano — to je samo predogled."
  : $"Dokumentov s pomanjkljivostjo: {withProblems}. Nič ni bilo poslano — to je samo predogled.");

if (zeroed.Count > 0)
{
  // Predogled sestavi CEL dokument iz vseh trenutnih vrednosti. Pri PATCH bi številčna ničla
  // v SAOP prepisala pravo vrednost z nič — SAOP namreč prepiše vsako poslano polje. Prava
  // odhodna pot zato pošlje samo polja, ki jih je urednik spremenil; tu je to opozorilo, da
  // se pri branju predogleda ve, katera polja bi bila prepisana.
  Console.WriteLine();
  Console.WriteLine($"POZOR: {zeroed.Count} številčnih polj ima vrednost nič. V PATCH bi ta polja v SAOP prepisala z nič:");
  foreach (var entry in zeroed.Take(20)) Console.WriteLine("  " + entry);
  if (zeroed.Count > 20) Console.WriteLine($"  … in še {zeroed.Count - 20}.");
}
return 0;

// Številčni element, katerega vsebina je same ničle in ločila.
static IEnumerable<string> Zeros(string xml) =>
  System.Text.RegularExpressions.Regex.Matches(xml, @"<(Item\w+)>(0(?:[.,]0+)?)</\1>")
    .Select(match => $"{match.Groups[1].Value} = {match.Groups[2].Value}");

static string Safe(string value) => string.Concat(value.Select(c => Path.GetInvalidFileNameChars().Contains(c) ? '_' : c));

static string Shorten(string value) => value.Length <= 38 ? value : value[..37] + "…";

static async Task<List<SaopXmlField>> ReadContractAsync(SqlConnection connection)
{
  await using var command = new SqlCommand("EXEC out.GetSaopXmlContract;", connection);
  await using var reader = await command.ExecuteReaderAsync();
  var fields = new List<SaopXmlField>();
  while (await reader.ReadAsync())
    fields.Add(new(
      reader.GetString(reader.GetOrdinal("Section")),
      reader.GetString(reader.GetOrdinal("ElementName")),
      Text(reader, "FieldKey"),
      reader.GetInt32(reader.GetOrdinal("SortOrder")),
      reader.GetBoolean(reader.GetOrdinal("IsAddMandatory")),
      reader.GetString(reader.GetOrdinal("ValueFormat")),
      Text(reader, "TrueValue"),
      Text(reader, "FalseValue")));
  return fields;
}

static async Task<List<string>> ReadSampleAsync(SqlConnection connection, int organizationId, int count)
{
  // Vzorec ni naključen: vzame artikle z največ izpolnjenimi polji, ker se na njih vidi
  // največ dokumenta. Artikel s praznimi polji ne pove ničesar o obliki.
  await using var command = new SqlCommand("""
    SELECT TOP(@Count) product.ItemID
    FROM canon.Product AS product
    LEFT JOIN canon.ProductCommercial AS commercial ON commercial.ProductId = product.ProductId
    WHERE product.OrganizationId = @OrganizationId
      AND NULLIF(product.ItemGroup, N'') IS NOT NULL
      AND NULLIF(product.UoM, N'') IS NOT NULL
      AND NULLIF(product.EAN, N'') IS NOT NULL
      AND NULLIF(product.Supplier, N'') IS NOT NULL
      AND NULLIF(product.Department, N'') IS NOT NULL
      AND NULLIF(commercial.CustomsTariff, N'') IS NOT NULL
    ORDER BY product.ItemID;
    """, connection);
  command.Parameters.Add("@Count", SqlDbType.Int).Value = count;
  command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
  await using var reader = await command.ExecuteReaderAsync();
  var items = new List<string>();
  while (await reader.ReadAsync()) items.Add(reader.GetString(0));
  return items;
}

static async Task<ItemState?> ReadStateAsync(SqlConnection connection, int organizationId, string itemId)
{
  await using var command = new SqlCommand("EXEC out.GetSaopItemWriteState @OrganizationId, @ItemID;", connection);
  command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
  command.Parameters.Add("@ItemID", SqlDbType.NVarChar, 200).Value = itemId;
  await using var reader = await command.ExecuteReaderAsync();

  if (!await reader.ReadAsync()) return null;
  var exists = reader.GetBoolean(reader.GetOrdinal("ExistsInSaop"));
  if (!exists && reader.IsDBNull(reader.GetOrdinal("ProductId"))) return null;

  var values = new Dictionary<string, string?>(StringComparer.Ordinal);
  await reader.NextResultAsync();
  while (await reader.ReadAsync()) values[reader.GetString(0)] = reader.GetString(1);

  var defaults = new Dictionary<string, string>(StringComparer.Ordinal);
  await reader.NextResultAsync();
  // Prva vrstica za isti element zmaga; procedura vrne privzetek za konkreten izvor pred splošnim.
  while (await reader.ReadAsync())
  {
    var key = $"{reader.GetString(0)}/{reader.GetString(1)}";
    if (!defaults.ContainsKey(key)) defaults[key] = reader.GetString(2);
  }

  return new(exists, values, defaults);
}

static string? Text(SqlDataReader reader, string column)
{
  var ordinal = reader.GetOrdinal(column);
  return reader.IsDBNull(ordinal) ? null : reader.GetString(ordinal);
}

sealed record ItemState(bool ExistsInSaop, Dictionary<string, string?> Values, Dictionary<string, string> Defaults);

sealed record Options(int OrganizationId, IReadOnlyList<string> Items, int Sample, string OutputDirectory, bool SuggestFirstFreeCode)
{
  public static Options? Parse(string[] args)
  {
    var organizationId = 0;
    var items = new List<string>();
    var sample = 5;
    var output = Path.Combine(Directory.GetCurrentDirectory(), "saop-xml");
    var suggest = true;

    for (var index = 0; index < args.Length; index++)
    {
      switch (args[index])
      {
        case "--org" or "--organization" when index + 1 < args.Length:
          organizationId = int.Parse(args[++index], CultureInfo.InvariantCulture); break;
        case "--items" when index + 1 < args.Length:
          items.AddRange(args[++index].Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)); break;
        case "--sample" when index + 1 < args.Length:
          sample = int.Parse(args[++index], CultureInfo.InvariantCulture); break;
        case "--out" when index + 1 < args.Length:
          output = args[++index]; break;
        case "--no-suggest-code":
          suggest = false; break;
        default:
          Console.Error.WriteLine($"Neznan argument: {args[index]}");
          return null;
      }
    }

    if (organizationId <= 0)
    {
      Console.Error.WriteLine("Uporaba: --org <id> [--items A,B] [--sample <n>] [--out <mapa>] [--no-suggest-code]");
      return null;
    }

    return new(organizationId, items, sample, output, suggest);
  }
}
