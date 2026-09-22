using PIM.Automation;
using PIM.Operations;

namespace PIM.Intranet.Services;

public sealed record WorkerLogLine(string Text, LogLineTone Tone);

/// <summary>
/// Branje dnevnikov tekov poslov za stran posla na Nadzoru (/sistem/posel/{posel}). Ta razred ničesar ne
/// poganja: teke vodi gostitelj avtomatike (PIM.AutomationHost) prek ops.JobRun, intranet jih samo prikaže.
/// Stari izvajalnik v intranetu (cikli, razporejevalnik, ročni zagon workerjev) je bil odstranjen
/// v bloku 1 (2026-09-22, migracija 254).
///
/// Mapa dnevnikov mora biti ista, kot jo uporablja gostitelj (AutomationEnvironment.PrepareLogRootAsync),
/// sicer <see cref="RelativeLogPath"/> vrne null in izpisa teka ni. Vrstni red je zato isti kot pri
/// gostitelju: WorkerConsole:LogRoot, register LOG_ROOT (/administracija/mape), privzetek postavitve.
/// Do bloka 5 je intranet register preskočil in skrbnik je moral isto mapo nastaviti še enkrat.
/// </summary>
public sealed class WorkerConsoleService(IConfiguration configuration)
{
  // Uspešno branje registra velja 10 min (sprememba LOG_ROOT na /administracija/mape pride brez ponovnega
  // zagona intraneta); neuspelo (baza ob zagonu intraneta še ni gor) se ponovi po 1 min, ne obvelja za vedno.
  static readonly TimeSpan RefreshAfter = TimeSpan.FromMinutes(10);
  static readonly TimeSpan RetryAfter = TimeSpan.FromMinutes(1);

  readonly object gate = new();
  WorkerConsoleSetup? setup;
  DateTime validUntilUtc;

  /// <summary>Postavitev z mapo dnevnikov; predpomnjena (glej <see cref="RefreshAfter"/> in <see cref="RetryAfter"/>).</summary>
  public WorkerConsoleSetup Setup
  {
    get
    {
      lock (gate)
        if (setup is not null && DateTime.UtcNow < validUntilUtc) return setup;

      // Branje baze zunaj ključavnice: sicer bi vsako vezje, ki bere dnevnik, čakalo na časovno mejo povezave.
      var (resolved, definitive) = ResolveSetup(configuration);
      lock (gate)
      {
        setup = resolved;
        validUntilUtc = DateTime.UtcNow + (definitive ? RefreshAfter : RetryAfter);
        return setup;
      }
    }
  }

  /// <summary>Konec dnevnika ali null, kadar pot ne kaže na dnevnik v mapi dnevnikov.</summary>
  public IReadOnlyList<string>? ReadLog(string relativePath, int maxBytes = 512 * 1024)
  {
    // Mapa dnevnikov iz registra velja tudi tam, kjer ob intranetu ni ne izvorne kode ne objavljenih
    // workerjev (Available = false): dnevnike piše gostitelj, intranet jih samo bere.
    var current = Setup;
    if (string.IsNullOrWhiteSpace(current.LogRoot)) return null;
    var full = WorkerLogs.ResolveInside(current.LogRoot, relativePath);
    return full is null || !File.Exists(full) ? null : WorkerLogs.ReadTail(full, maxBytes);
  }

  /// <summary>Pot dnevnika teka, relativna na mapo dnevnikov (za odpiranje s strani); null, kadar ni v njej.</summary>
  public string? RelativeLogPath(string? fullPath)
  {
    if (string.IsNullOrWhiteSpace(fullPath) || string.IsNullOrWhiteSpace(Setup.LogRoot)) return null;
    var root = Path.GetFullPath(Setup.LogRoot).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
    var full = Path.GetFullPath(fullPath);
    return full.StartsWith(root, StringComparison.OrdinalIgnoreCase) ? full[root.Length..] : null;
  }

  // Na razvojnem računalniku intranet teče iz bin\ znotraj repozitorija in koren najde sam po
  // PIM.sln. Na strežniku je Workerji\ ob intranetu (objava intraneta) in ni treba nastaviti nič;
  // ključi WorkerConsole:* v appsettings.Local.json ob intranetu to prepišejo.
  /// <returns>Postavitev in ali je dokončna (izrecna nastavitev ali uspešno prebran register).</returns>
  static (WorkerConsoleSetup Setup, bool Definitive) ResolveSetup(IConfiguration configuration)
  {
    var configuredLogRoot = configuration["WorkerConsole:LogRoot"];
    var resolved = WorkerConsoleLayout.Resolve(
      configuration["WorkerConsole:RepositoryRoot"],
      configuration["WorkerConsole:PublishedWorkersRoot"],
      configuredLogRoot,
      () => LocalSettings.FindSolutionRoot(AppContext.BaseDirectory),
      AppContext.BaseDirectory);

    // Izrecna nastavitev je močnejša od registra, tako kot pri gostitelju (Automation:LogRoot). Postavitev brez
    // izvorne kode in brez objavljenih workerjev vrne prazno mapo tudi ob nastavitvi; intranet dnevnike samo
    // bere, zato nastavljena mapa velja tudi tedaj.
    if (!string.IsNullOrWhiteSpace(configuredLogRoot))
      return (string.IsNullOrWhiteSpace(resolved.LogRoot) ? resolved with { LogRoot = configuredLogRoot.Trim() } : resolved, true);
    var (registered, read) = RegisteredLogRoot(configuration);
    return (registered is { } root ? resolved with { LogRoot = root } : resolved, read);
  }

  /// <summary>
  /// Register LOG_ROOT (null: ni nastavljen) in ali je branje uspelo. Kliče se iz lastnosti, zato sinhrono;
  /// Task.Run, da čakanje ne ujame sinhronizacijskega konteksta vezja Blazor. Nedosegljiva baza tu ne sme
  /// podreti strani: do ponovnega poskusa velja privzetek.
  /// </summary>
  static (string? Root, bool Read) RegisteredLogRoot(IConfiguration configuration)
  {
    if (ConnectionStringResolver.Resolve(configuration) is not { } connectionString) return (null, true);
    try
    {
      var registered = Task.Run(() => SystemPaths.ResolveAsync(connectionString, SystemPaths.Log)).GetAwaiter().GetResult();
      return (string.IsNullOrWhiteSpace(registered) ? null : registered.Trim(), true);
    }
    catch (Exception)
    {
      return (null, false);
    }
  }
}
