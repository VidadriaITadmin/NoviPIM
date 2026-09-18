using System.Text.Json;
using PIM.Operations;

namespace PIM.StockFileWorker;

/// <summary>
/// Kaj naj worker prebere in kam naj to zapiše. Ločeno od <c>Program.cs</c>, ker je to edini
/// del, ki se da preveriti brez baze — in ker je bil prav ta del doslej nezapisan: worker je
/// znal prebrati datoteko, ni pa vedel, čigava zaloga je in v kateri vir gre.
/// </summary>
public sealed record StockFileWorkerOptions(
  string FilePath,
  string SourceCode,
  int OrganizationId,
  string Endpoint,
  string DateFormat,
  bool ReadOnly,
  /// <summary>Nacrtovani zagon spostuje razpored iz baze; rocni ga namenoma obide.</summary>
  bool BySchedule = false)
{
  public const int DefaultOrganizationId = 2;

  /// <summary>Braytron piše datume po ISO, Nowodvorski po evropsko — privzetek sledi viru.</summary>
  public static string DefaultDateFormat(string sourceCode) =>
    sourceCode.StartsWith("BT", StringComparison.OrdinalIgnoreCase) ? "yyyy-MM-dd" : "dd/MM/yyyy";

  /// <summary>XML je Braytron, vse ostalo je Nowodvorski CSV; pove se lahko tudi z --source.</summary>
  public static string SourceFromExtension(string filePath) =>
    filePath.EndsWith(".xml", StringComparison.OrdinalIgnoreCase) ? "BT_STOCK" : "NW_STOCK";

  public static StockFileWorkerOptions Parse(IReadOnlyList<string> args)
  {
    string? file = null, source = null, endpoint = null, dateFormat = null;
    var organizationId = DefaultOrganizationId;
    var readOnly = false;
    var bySchedule = false;

    for (var index = 0; index < args.Count; index++)
    {
      var name = args[index].ToLowerInvariant();
      switch (name)
      {
        case "--file":
        case "--fixture":
          file = Next(args, ref index, name);
          break;
        case "--source":
          source = Next(args, ref index, name);
          break;
        case "--organization-id":
          var text = Next(args, ref index, name);
          if (!int.TryParse(text, out organizationId) || organizationId <= 0)
            throw new ArgumentException($"--organization-id mora biti pozitivno celo število, dobil sem '{text}'.");
          break;
        case "--endpoint":
          endpoint = Next(args, ref index, name);
          break;
        case "--date-format":
          dateFormat = Next(args, ref index, name);
          break;
        case "--samo-preberi":
          readOnly = true;
          break;
        case "--po-urniku":
          bySchedule = true;
          break;
        default:
          throw new ArgumentException($"Neznan argument: {args[index]}.");
      }
    }

    if (string.IsNullOrWhiteSpace(file)) throw new ArgumentException("--file je obvezen.");
    source ??= SourceFromExtension(file);
    dateFormat ??= DefaultDateFormat(source);
    endpoint ??= $"file://{Path.GetFileName(file)}";
    return new(Path.GetFullPath(file), source, organizationId, endpoint, dateFormat, readOnly, bySchedule);
  }

  static string Next(IReadOnlyList<string> args, ref int index, string name)
  {
    if (index + 1 >= args.Count) throw new ArgumentException($"{name} potrebuje vrednost.");
    return args[++index];
  }

  /// <summary>Povezava: najprej okolje, nato skupna lokalna nastavitev rešitve.</summary>
  public static string? ReadConnectionString() => LocalSettings.ConnectionString();
}
