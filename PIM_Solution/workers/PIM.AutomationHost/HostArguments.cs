namespace PIM.AutomationHost;

/// <summary>Stikala ukazne vrstice gostitelja. Čista funkcija, da se da preveriti brez procesa.</summary>
public sealed record HostArguments(
  bool ShowHelp, bool Check, int CheckStaleMinutes, bool DispatchAlerts, string? RunOnceJob,
  IReadOnlySet<string>? AllowedJobs, bool MonitorOnly, string[] HostArgs)
{
  public const string Help = """
    PIM.AutomationHost — gostitelj avtomatike (migracija 237)

      (brez stikal)              teče kot Windows storitev ali konzola: najem, posli po urniku
      --preveri [--brez-alarma]  zunanji nadzor utripa gostitelja (izhod 0 = utripa, 1 = molči, 2 = baza ni dosegljiva);
                                 ob molku odpre alarm AutomationHostDown in požene PIM.AlertDispatcher
      --meja-min <n>             koliko minut molka je še sprejemljivo pri --preveri (privzeto 10)
      --enkrat <POSEL>           en zagon posla zdaj (spoštuje vrata odvisnosti), nato izhod 0/1/3/4
      --posli A,B                samo našteti posli
      --samo-nadzor              najem, čiščenje visečih zagonov in alarmi, brez zagona poslov
      --pomoc                    ta izpis
    """;

  public static HostArguments Parse(string[] args)
  {
    var showHelp = false;
    var check = false;
    var staleMinutes = 10;
    var dispatch = true;
    string? runOnce = null;
    HashSet<string>? allowed = null;
    var monitorOnly = false;
    var passThrough = new List<string>();

    for (var index = 0; index < args.Length; index++)
    {
      switch (args[index].ToLowerInvariant())
      {
        case "--pomoc":
        case "--help":
        case "-h":
        case "/?":
          showHelp = true;
          break;
        case "--preveri":
          check = true;
          break;
        case "--brez-alarma":
          dispatch = false;
          break;
        case "--meja-min":
          if (index + 1 < args.Length && int.TryParse(args[index + 1], out var minutes) && minutes > 0) { staleMinutes = minutes; index++; }
          break;
        case "--enkrat":
          if (index + 1 < args.Length) runOnce = args[++index].Trim().ToUpperInvariant();
          break;
        case "--posli":
          if (index + 1 < args.Length)
            allowed = args[++index].Split([',', ';'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
              .Select(value => value.ToUpperInvariant()).ToHashSet(StringComparer.Ordinal);
          break;
        case "--samo-nadzor":
          monitorOnly = true;
          break;
        default:
          passThrough.Add(args[index]);
          break;
      }
    }

    if (runOnce is not null) allowed = new HashSet<string>(StringComparer.Ordinal) { runOnce };
    return new(showHelp, check, staleMinutes, dispatch, runOnce, allowed, monitorOnly, passThrough.ToArray());
  }
}
