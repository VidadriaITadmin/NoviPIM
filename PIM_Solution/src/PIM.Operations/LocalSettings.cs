using System.Text.Json;

namespace PIM.Operations;

/// <summary>
/// Ena sama lokalna nastavitvena datoteka za celo rešitev: <c>PIM_Solution\appsettings.Local.json</c>.
///
/// Zakaj to obstaja. Rešitev ima okoli deset izvršljivih projektov, ki gredo vsi na isto bazo.
/// Datoteka na projekt (tako, kot jo naredi <c>dotnet publish</c>) bi pomenila deset prepisov
/// istega connection stringa; ob zamenjavi strežnika se popravi devetkrat in enkrat pozabi.
/// Zato ena datoteka v korenu rešitve, ki jo vsi najdejo z iskanjem navzgor.
///
/// Prej je isto iskanje obstajalo v šestih kopijah s tremi različnimi strategijami — ena je
/// gledala samo trenutno mapo, druga prvo najdeno navzgor, tretja koren repozitorija. Ker je
/// vsaka našla drugo datoteko, so v drevesu zrasle tri <c>appsettings.Local.json</c> z različnimi
/// strežniki in nihče ni vedel, katera velja. To je edino mesto, ki to ve.
///
/// Vrstni red virov, od šibkejšega k močnejšemu:
///
///   1. mapa aplikacije (ob <c>.exe</c>)  — produkcija; tako datoteko ohranja <c>Publish-Intranet.ps1</c>
///   1a. mapa intraneta nad <c>Workerji\</c> — objava v eno mapo: ena datoteka za intranet in vse workerje
///   2. koren rešitve (mapa s <c>PIM.sln</c>) — razvoj; skupna datoteka za vse projekte
///   2a. koren repozitorija (mapa nad rešitvijo) — isti vir kot skripte ciklov (<c>Sql.ps1</c>)
///   3. <c>PIM_CONNECTION_STRING</c>      — samo za povezavo; okolje mora zmagati nad datoteko
///
/// Koren rešitve na strežniku ne obstaja, zato tam ostane samo (1) — in obratno, na razvojnem
/// računalniku (2) prepiše morebitno pozabljeno datoteko v izhodni mapi projekta.
/// </summary>
public static class LocalSettings
{
  public const string FileName = "appsettings.Local.json";

  /// <summary>Okoljska spremenljivka s povezavo; edina stvar, ki sme prepisati datoteko.</summary>
  public const string ConnectionVariable = "PIM_CONNECTION_STRING";

  /// <summary>Datoteka, ki pove, da smo v korenu rešitve. Ne <c>PIM_Solution\PIM.sln</c>:
  /// sidro mora delovati tudi, kadar je <c>PIM_Solution</c> sam koren kloniranega repozitorija.</summary>
  const string SolutionFile = "PIM.sln";

  /// <summary>
  /// Mapa s <c>PIM.sln</c> nad danim izhodiščem ali <c>null</c> izven rešitve. Neodvisno od
  /// globine: deluje iz korena, iz mape projekta in iz <c>bin\...\publish</c> katerekoli globine.
  /// </summary>
  public static string? FindSolutionRoot(string startDirectory)
  {
    for (var directory = new DirectoryInfo(startDirectory); directory is not null; directory = directory.Parent)
      if (File.Exists(Path.Combine(directory.FullName, SolutionFile)))
        return directory.FullName;

    return null;
  }

  /// <summary>
  /// Datoteka ob intranetu, kadar program tece iz objavljene mape <c>&lt;intranet&gt;\Workerji\&lt;Worker&gt;\</c>
  /// (PIM.Intranet.csproj, cilj PimPublishWorkersAndScripts); sicer <c>null</c>.
  /// </summary>
  public static string? FindPublishedRootPath(string startDirectory)
  {
    var directory = new DirectoryInfo(startDirectory.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
    var parent = directory.Parent;
    return parent is not null && parent.Name.Equals("Workerji", StringComparison.OrdinalIgnoreCase) && parent.Parent is { } root
      ? Path.Combine(root.FullName, FileName)
      : null;
  }

  /// <summary>Skupna datoteka v korenu rešitve ali <c>null</c>, kadar korena ni (strežnik).</summary>
  public static string? FindPath(string startDirectory)
  {
    var root = FindSolutionRoot(startDirectory);
    return root is null ? null : Path.Combine(root, FileName);
  }

  /// <summary>Datoteka v korenu repozitorija (mapa nad rešitvijo) ali <c>null</c>, kadar rešitve ni ali je sama koren.</summary>
  public static string? FindRepositoryRootPath(string startDirectory)
  {
    var root = FindSolutionRoot(startDirectory);
    var parent = root is null ? null : Directory.GetParent(root);
    return parent is null ? null : Path.Combine(parent.FullName, FileName);
  }

  /// <summary>
  /// Vse obstoječe datoteke, urejene od šibkejše k močnejši — tak vrstni red pričakuje
  /// <c>IConfigurationBuilder.AddJsonFile</c>, kjer zadnji vir prepiše prejšnje.
  /// </summary>
  public static IReadOnlyList<string> Sources(string applicationDirectory)
  {
    // Namenoma samo iz podane mape in ne tudi iz trenutne: trenutna mapa je odvisna od tega, od
    // kod je kdo pognal skripto, in prav to je prej pomenilo, da je isti worker enkrat bral eno
    // in drugič drugo datoteko. Izhodne mape vseh projektov ležijo pod korenom rešitve, zato
    // iskanje navzgor pokrije vsak zagon znotraj rešitve brez ugibanja po trenutni mapi.
    var paths = new List<string>();
    Add(Path.Combine(applicationDirectory, FileName));
    // Objava v eno mapo (2026-09-17): worker tece iz <mapa intraneta>\Workerji\<Worker>\, skupna
    // lokalna nastavitev (povezava, SAOP poverilnice) pa je ena sama, ob intranetu. Brez tega bi vsak
    // od trinajstih workerjev na strezniku potreboval svojo kopijo datoteke s SAOP geslom - in
    // razporejevalnik v aplikaciji bi klical SAOP z workerjem, ki "nima nastavitve Saop".
    Add(FindPublishedRootPath(applicationDirectory));
    Add(FindPath(applicationDirectory));
    // Koren repozitorija (mapa nad PIM_Solution): tja bereta skripte ciklov (Sql.ps1, PimPovezava) in
    // stari iskalnik intraneta (LocalSettingsLocator), in tam na razvojnem racunalniku dejansko lezijo
    // SAOP in FTP poverilnice. Brez tega vira je 2026-09-17 razporejevalnik v aplikaciji pognal
    // SaopStockWorker, ki je koncal z "Manjka nastavitev Saop", ceprav je ista skripta uro prej klicala SAOP.
    Add(FindRepositoryRootPath(applicationDirectory));
    return paths;

    void Add(string? candidate)
    {
      if (candidate is not null
        && !paths.Contains(candidate, StringComparer.OrdinalIgnoreCase)
        && File.Exists(candidate))
        paths.Add(candidate);
    }
  }

  /// <summary>Privzeto izhodišče za program brez <c>ContentRoot</c>: mapa ob <c>.exe</c>,
  /// ne trenutna mapa — ta se spreminja glede na to, od kod je kdo pognal skripto.</summary>
  public static IReadOnlyList<string> Sources() => Sources(AppContext.BaseDirectory);

  /// <summary>
  /// Odsek iz najmočnejšega vira, ki ga sploh ima. Vrne <c>null</c>, kadar ga nima nobeden.
  /// Za programe brez <c>IConfiguration</c> (workerji, orodja), ki berejo surov JSON.
  /// </summary>
  public static JsonElement? Section(string name)
  {
    var sources = Sources();
    for (var index = sources.Count - 1; index >= 0; index--)
    {
      using var document = JsonDocument.Parse(File.ReadAllText(sources[index]));
      if (document.RootElement.TryGetProperty(name, out var section))
        return section.Clone(); // dokument se zapre; brez klona bi klicatelj dobil sproščen pomnilnik
    }

    return null;
  }

  /// <summary>
  /// Povezava na bazo: najprej okolje, nato skupna datoteka. <c>null</c> pomeni ni nastavljena,
  /// pri čemer prazen niz šteje kot ni nastavljena — <c>appsettings.Production.json</c> ima
  /// <c>"Pim": ""</c> kot mesto za izpolniti in prazna povezava ne sme priti do gonilnika.
  ///
  /// <paramref name="environmentVariable"/> je parameter, ker orodja nad testno bazo berejo
  /// svojo spremenljivko (<c>PIM_TEST_CONNECTION_STRING</c>) in svoj ključ (<c>PimTest</c>);
  /// brez tega bi izvoz fiksur po nesreči pisal v razvojno bazo.
  /// </summary>
  public static string? ConnectionString(string name = "Pim", string environmentVariable = ConnectionVariable)
  {
    var fromEnvironment = Environment.GetEnvironmentVariable(environmentVariable);
    if (!string.IsNullOrWhiteSpace(fromEnvironment))
      return fromEnvironment;

    if (Section("ConnectionStrings") is not { } connectionStrings
      || !connectionStrings.TryGetProperty(name, out var value))
      return null;

    var text = value.GetString();
    return string.IsNullOrWhiteSpace(text) ? null : text;
  }

  /// <summary>Sporočilo, ki ga izpiše program brez povezave. Pove, katero datoteko naj človek popravi.</summary>
  public static string MissingConnectionMessage(string name = "Pim", string environmentVariable = ConnectionVariable) =>
    $"Manjka {environmentVariable} oziroma ConnectionStrings:{name} v {FileName} "
    + $"(pričakovano v korenu rešitve: {FindPath(AppContext.BaseDirectory) ?? "<koren rešitve ni najden>"}).";
}
