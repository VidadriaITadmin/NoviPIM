using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace PIM.Automation;

/*
  Postavitev, zagon procesa workerja in dnevniki zagonov: skupno gostitelju avtomatike
  (PIM.AutomationHost), ki posle poganja, in intranetu, ki njihove dnevnike samo bere.

  Datoteka je nastala za ročni zagon workerjev iz intraneta (/sistem/workerji, 2026-09-15).
  Uporabnik: »v aplikaciji mi omogoči da ročno poženem in spremljam potem kaj se zgodi in da
  vidim loge od vsakega workerja«. Doslej so bili dnevniki datoteke v mapi logs, ki jih ni gledal
  nihče — zato je zaloga lahko šest dni stala, ne da bi kdo opazil.

  V bloku 1 prenove nadzora (2026-09-22, migracija 254) sta stran /sistem/workerji in razporejevalnik
  v intranetu odšla: posle, tudi ročne zahteve z Nadzora (/sistem, /sistem/posel/<posel>), poganja samo še
  PIM.AutomationHost. Z njima so odšli katalog ročnih poslov, vrste dnevnikov in branje izpisa schtasks.

  Ostalo je, kar potrebuje gostitelj: postavitev (izvorna koda ali objavljeni workerji), sestava ukaza
  workerja, čiščenje okolja otroka, glava in noga dnevnika zagona, razvrstitev vrstice in branje konca
  datoteke. Vse se da preveriti brez procesa in brez baze (PIM.F10.IntranetLogicTests), zato tu ni
  odvisnosti izven BCL.
*/

/// <summary>Kako daleč seže zagon. Od tega je odvisno, ali ga mora skrbnik posebej potrditi.</summary>
public enum WorkerJobReach
{
  /// <summary>Bere in piše samo našo bazo in datoteke.</summary>
  Internal,
  /// <summary>Kliče SAOP ali dobavitelja v živo (AGENTS.md §4.5: to je odločitev človeka).</summary>
  ExternalCall,
  /// <summary>Pošlje e-pošto pravim prejemnikom.</summary>
  SendsEmail,
}

/// <summary>En proces, ki ga zagon požene. Posel na podjetje ima en korak na podjetje.</summary>
public sealed record WorkerLaunchStep(
  string FileName, IReadOnlyList<string> Arguments, string WorkingDirectory, string Display, int? OrganizationId);

/// <param name="PublishedWorker">Pot do objavljenega .exe ali null; na razvojnem računalniku ga ni
/// in worker teče z <c>dotnet run --no-build</c>, enako kot iz skript.</param>
/// <param name="ExportDirectory">Izvozna mapa podjetja (samo za izvoze, ki jih worker sam ne razreši).</param>
/// <param name="PublishedWorkersRoot">Mapa objavljenih workerjev (<c>&lt;mapa&gt;\&lt;Worker&gt;\&lt;Worker&gt;.exe</c>); null na razvoju.</param>
public sealed record WorkerPaths(
  string RepositoryRoot, string SolutionRoot,
  Func<string, string?> PublishedWorker, Func<int, string> ExportDirectory, string? PublishedWorkersRoot = null);

/// <param name="Available">Ali se na tem strežniku da kaj pognati: z izvorno kodo (razvoj) ali z
/// objavljenimi workerji (strežnik). Kaj od tega je, pove <paramref name="HasSource"/>.</param>
/// <param name="RepositoryRoot">Koren, ob katerem so dnevniki, izvozi in prevzem: repozitorij (razvoj) ali
/// mapa intraneta (objava v eno mapo); prazno, kadar sta znana samo objavljena workerja.</param>
/// <param name="LogRoot">Mapa dnevnikov (<c>&lt;koren&gt;\logs</c>); gostitelj jo ob zagonu lahko zamenja z registrom
/// LOG_ROOT ali z rezervno mapo, kadar ta ni zapisljiva (AutomationEnvironment.PrepareLogRootAsync).</param>
/// <param name="PublishedWorkersRoot">Mapa <c>&lt;mapa&gt;\&lt;Worker&gt;\&lt;Worker&gt;.exe</c>, kot jo naredi
/// objava intraneta (PIM.Intranet.csproj, cilj PimPublishWorkersAndScripts); null, kadar ni nastavljena ali je ni.</param>
/// <param name="HasSource">PIM.sln je najden: worker brez objavljenega .exe teče z <c>dotnet run</c>.</param>
public sealed record WorkerConsoleSetup(
  bool Available, string? Reason, string RepositoryRoot, string SolutionRoot,
  string LogRoot, string? PublishedWorkersRoot, bool HasSource = false);

/// <summary>
/// Kaj je na tem računalniku za zagon: izvorna koda ali objavljeni workerji. Čista funkcija nad
/// potmi, da se da preveriti brez IIS in brez konfiguracije (F10).
///
/// Do 2026-09-16 je bil PIM.sln pogoj za vse. Objavljen intranet (dotnet publish v IIS) ga nad
/// sabo nima, zato je stran na strežniku pisala »izvorne kode ni«, čeprav so bili workerji
/// objavljeni poleg. Zdaj zadošča eno od dvojega: izvorna koda (dotnet run) ali objavljeni .exe.
/// </summary>
public static class WorkerConsoleLayout
{
  /// <param name="repositoryRoot">Automation:RepositoryRoot pri gostitelju (prej WorkerConsole:RepositoryRoot v intranetu) —
  /// koren z <c>logs\</c> (in na razvoju <c>PIM_Solution\PIM.sln</c>).</param>
  /// <param name="publishedWorkersRoot">Automation:PublishedWorkersRoot — mapa <c>&lt;mapa&gt;\&lt;Worker&gt;\&lt;Worker&gt;.exe</c>.</param>
  /// <param name="logRoot">Automation:LogRoot; privzeto <c>&lt;koren&gt;\logs</c>, brez korena <c>&lt;objavljeni&gt;\logs</c>.</param>
  /// <param name="findSolutionRoot">Kje je PIM.sln nad aplikacijo (razvoj); null izven rešitve.</param>
  /// <param name="applicationDirectory">Mapa intraneta; objavljen gostitelj jo najde kot mapo nad svojim <c>Workerji\</c>
  /// (AutomationEnvironment.ResolveSetup), sicer je to mapa programa. Objava intraneta odloži ob njo <c>Workerji\</c>
  /// (in <c>scripts\</c>); ta postavitev velja brez ključev, ključi jo le prepišejo.</param>
  public static WorkerConsoleSetup Resolve(
    string? repositoryRoot, string? publishedWorkersRoot, string? logRoot, Func<string?> findSolutionRoot,
    string? applicationDirectory = null)
  {
    if (string.IsNullOrWhiteSpace(publishedWorkersRoot) && applicationDirectory is { Length: > 0 }
        && Directory.Exists(Path.Combine(applicationDirectory, "Workerji")))
      publishedWorkersRoot = Path.Combine(applicationDirectory, "Workerji");
    var hasPublished = !string.IsNullOrWhiteSpace(publishedWorkersRoot) && Directory.Exists(publishedWorkersRoot);

    var solution = !string.IsNullOrWhiteSpace(repositoryRoot)
      ? Path.Combine(repositoryRoot, "PIM_Solution")
      : findSolutionRoot();
    var hasSource = solution is not null && File.Exists(Path.Combine(solution, "PIM.sln"));

    // Brez izvorne kode in brez ključa je koren mapa intraneta, če so ob njej objavljeni workerji ali
    // skripte (objava v eno mapo): dnevniki in izvozi gredo ob aplikacijo, ne ob posamezen .exe.
    if (string.IsNullOrWhiteSpace(repositoryRoot) && !hasSource && applicationDirectory is { Length: > 0 }
        && (Directory.Exists(Path.Combine(applicationDirectory, "scripts")) || Directory.Exists(Path.Combine(applicationDirectory, "Workerji"))))
      repositoryRoot = applicationDirectory;

    if (!hasSource && !hasPublished)
      return new(false,
        "izvorne kode ni (PIM.sln ni najden nad mapo aplikacije) in ob intranetu ni mape Workerji z objavljenimi workerji. "
        + "Objavi intranet skupaj z workerji (dotnet publish PIM.Intranet — cilj PimPublishWorkersAndScripts, deploy\\Publish-All.ps1) "
        + "ali v appsettings.Local.json ob intranetu nastavi WorkerConsole:PublishedWorkersRoot (strežnik) oziroma WorkerConsole:RepositoryRoot (razvoj).",
        "", "", "", publishedWorkersRoot);

    var repository = !string.IsNullOrWhiteSpace(repositoryRoot) ? repositoryRoot
      : hasSource ? Directory.GetParent(solution!)!.FullName
      : "";

    var logs = logRoot is { Length: > 0 } ? logRoot
      : repository.Length > 0 ? Path.Combine(repository, "logs")
      : Path.Combine(publishedWorkersRoot!, "logs");
    return new(true, null, repository, hasSource ? solution! : "", logs, hasPublished ? publishedWorkersRoot : null, hasSource);
  }

  /// <summary>Pot do objavljenega .exe ali null; na razvojnem računalniku ga ni in worker teče z dotnet run.</summary>
  public static string? PublishedWorker(string? root, string worker)
  {
    if (string.IsNullOrWhiteSpace(root)) return null;
    var exe = Path.Combine(root, worker, worker + ".exe");
    return File.Exists(exe) ? exe : null;
  }
}

public enum LogLineTone { Normal, Header, Success, Warning, Error }

/// <summary>Sestava ukaza workerja in okolje otroka; ukaze korakov poslov sestavi JobCatalog prek WorkerCycles.Worker.</summary>
public static class WorkerJobs
{
  /// <summary>
  /// Spremenljivke starša, ki jih otrok ne sme podedovati. Gostitelj, pognan iz Visual Studia, dobi
  /// DOTNET_STARTUP_HOOKS za vroče nalaganje, ki bi se sicer naložil v vsak worker; ASPNETCORE_*
  /// (okolje IIS ali intraneta, iz katerega je bil proces pognan) pa workerju, ki ni spletna
  /// aplikacija, ne povedo ničesar.
  /// </summary>
  public static bool IsInheritedHostVariable(string name) =>
    name.StartsWith("ASPNETCORE_", StringComparison.OrdinalIgnoreCase)
    || name.StartsWith("DOTNET_STARTUP_HOOKS", StringComparison.OrdinalIgnoreCase)
    || name.StartsWith("DOTNET_MODIFIABLE_ASSEMBLIES", StringComparison.OrdinalIgnoreCase)
    || name.StartsWith("DOTNET_HOTRELOAD", StringComparison.OrdinalIgnoreCase)
    || name.StartsWith("DOTNET_WATCH", StringComparison.OrdinalIgnoreCase);

  /// <summary>En proces workerja: objavljen .exe, sicer <c>dotnet run --no-build</c> iz izvorne kode (isto kot skripte).</summary>
  public static WorkerLaunchStep LaunchWorker(string worker, IReadOnlyList<string> arguments, WorkerPaths paths, int? organizationId)
  {
    var display = arguments.Count > 0 ? $"{worker} {string.Join(" ", arguments)}" : worker;
    if (paths.PublishedWorker(worker) is { } exe)
      return new(exe, arguments, Path.GetDirectoryName(exe) ?? paths.SolutionRoot, display, organizationId);

    // Isto kot skripte: dotnet run --no-build. Če worker ni zgrajen, to pove dotnet sam, in to
    // sporočilo pristane v izpisu, ne v tihem padcu.
    var project = Path.Combine(paths.SolutionRoot, "workers", worker);
    return new("dotnet", ["run", "--project", project, "--no-build", "--", .. arguments], paths.SolutionRoot, display, organizationId);
  }
}

/// <summary>Dnevniki zagonov: ime datoteke, glava in noga, razvrstitev vrstic in branje konca datoteke.</summary>
public static partial class WorkerLogs
{
  public const string HeaderPrefix = "=== ZAČETEK: ";
  public const string FooterPrefix = "=== KONEC: izhod ";

  /// <summary>Ime dnevnika enega zagona posla (<c>&lt;POSEL&gt;_&lt;datum&gt;_&lt;ura&gt;.log</c>) v mapi opravila\.</summary>
  public static string RunLogFileName(string jobKey, DateTime startedLocal) =>
    $"{jobKey}_{startedLocal.ToString("yyyy-MM-dd_HHmmss", CultureInfo.InvariantCulture)}.log";

  public static string Footer(int exitCode, TimeSpan duration, bool cancelled) =>
    $"{FooterPrefix}{exitCode.ToString(CultureInfo.InvariantCulture)}"
    + (cancelled ? " (ustavljeno ročno)" : "")
    + $", trajanje {(int)duration.TotalHours:00}:{duration.Minutes:00}:{duration.Seconds:00}";

  /// <summary>
  /// Kaj vrstica pomeni človeku, ki išče, zakaj nekaj ne dela. Napaka ima prednost pred vsem:
  /// vrstica "NAPAKA v koraku …" ostane rdeča, četudi vsebuje tudi "konec".
  /// </summary>
  public static LogLineTone Classify(string line)
  {
    if (string.IsNullOrWhiteSpace(line)) return LogLineTone.Normal;
    if (ErrorPattern().IsMatch(line)) return LogLineTone.Error;
    if (WarningPattern().IsMatch(line)) return LogLineTone.Warning;
    if (HeaderPattern().IsMatch(line)) return LogLineTone.Header;
    if (SuccessPattern().IsMatch(line)) return LogLineTone.Success;
    return LogLineTone.Normal;
  }

  static readonly UTF8Encoding StrictUtf8 = new(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);
  static readonly Lazy<Encoding> ConsoleCodePage = new(() =>
  {
    Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
    return Encoding.GetEncoding(852);
  });

  /// <summary>
  /// Vrstica izpisa v besedilo. Skripte izpis preklopijo v UTF-8, worker, pognan naravnost, pa piše
  /// v kodni strani konzole, ki je na tem računalniku 852. Ena napačna izbira je že enkrat
  /// naredila "kon-Zcan" iz "končan" (glej Zaloga-cikel.ps1), zato se izbere po vsebini vrstice.
  /// </summary>
  public static string DecodeLine(ReadOnlySpan<byte> bytes)
  {
    while (bytes.Length > 0 && (bytes[^1] == (byte)'\r' || bytes[^1] == (byte)'\n')) bytes = bytes[..^1];
    if (bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) bytes = bytes[3..];
    try { return StrictUtf8.GetString(bytes); }
    catch (DecoderFallbackException) { return ConsoleCodePage.Value.GetString(bytes); }
  }

  /// <summary>
  /// Zadnjih največ <paramref name="maxBytes"/> bajtov datoteke kot vrstice. Datoteka se odpre z
  /// deljenim pisanjem, ker jo skripta morda ravno piše; delna prva vrstica se zavrže.
  /// </summary>
  public static IReadOnlyList<string> ReadTail(string path, int maxBytes)
  {
    using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
    var start = Math.Max(0, stream.Length - maxBytes);
    stream.Seek(start, SeekOrigin.Begin);
    var buffer = new byte[stream.Length - start];
    var read = 0;
    while (read < buffer.Length)
    {
      var count = stream.Read(buffer, read, buffer.Length - read);
      if (count == 0) break;
      read += count;
    }

    ReadOnlySpan<byte> span = buffer.AsSpan(0, read);
    if (start > 0)
    {
      var firstBreak = span.IndexOf((byte)'\n');
      span = firstBreak < 0 ? [] : span[(firstBreak + 1)..];
    }

    var lines = new List<string>();
    while (span.Length > 0)
    {
      var end = span.IndexOf((byte)'\n');
      var line = end < 0 ? span : span[..end];
      lines.Add(DecodeLine(line));
      span = end < 0 ? [] : span[(end + 1)..];
    }
    return lines;
  }

  /// <summary>
  /// Pot znotraj mape dnevnikov ali null. Stran pošlje relativno ime, ki ga je sama prebrala iz
  /// seznama; kljub temu se preveri, da ne pobegne iz mape in da je dnevnik.
  /// </summary>
  public static string? ResolveInside(string root, string relativePath)
  {
    if (string.IsNullOrWhiteSpace(relativePath) || Path.IsPathRooted(relativePath)) return null;
    var rootFull = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
    var full = Path.GetFullPath(Path.Combine(rootFull, relativePath));
    return full.StartsWith(rootFull, StringComparison.OrdinalIgnoreCase)
      && full.EndsWith(".log", StringComparison.OrdinalIgnoreCase) ? full : null;
  }

  /// <summary>Vrstica z uro na začetku. Skripte uro pišejo same (nočni tok tudi datum); worker,
  /// pognan naravnost, je ne — brez nje se v dnevniku ne vidi, kje je čakal.</summary>
  public static string Stamp(string line, DateTime local) =>
    StampedLine().IsMatch(line) ? line : $"{local.ToString("HH:mm:ss", CultureInfo.InvariantCulture)}  {line}";

  [GeneratedRegex(@"^(\d{4}-\d{2}-\d{2} )?\d{2}:\d{2}:\d{2}\s")]
  private static partial Regex StampedLine();

  [GeneratedRegex(@"NAPAKA|STDERR|Exception|Unhandled|\bFailed\b|padlih korakov: [1-9]|padlih [1-9]|izhodno kodo [1-9]|=== KONEC: izhod -?[1-9]|\bfail:|\bError:|\bERROR\b")]
  private static partial Regex ErrorPattern();

  [GeneratedRegex(@"OPOZORILO|preskoceno|preskočeno|ni omogocen|ni omogočen|ze tece|že teče|umaknil|ni na vrsti|zastarel|\bwarn:|\bWarning\b", RegexOptions.IgnoreCase)]
  private static partial Regex WarningPattern();

  [GeneratedRegex(@"(^|\s)==\s.+\s==\s*$|^=== ZAČETEK")]
  private static partial Regex HeaderPattern();

  [GeneratedRegex(@"padlih korakov: 0|padlih 0|=== KONEC: izhod 0|\bPASS\b|koncan|končan|konec:", RegexOptions.IgnoreCase)]
  private static partial Regex SuccessPattern();
}
