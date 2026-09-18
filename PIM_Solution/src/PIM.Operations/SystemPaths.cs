using System.Data;
using Microsoft.Data.SqlClient;

namespace PIM.Operations;

/// <summary>
/// Kam sistem shranjuje datoteke (register <c>ops.SystemPath</c>, migracija 173).
///
/// Zakaj to ne more ostati v kodi in skriptah. Vsaka pot se je doslej računala iz »korena
/// repozitorija«. To drži na razvojnem računalniku in pade na strežniku: pod IIS je koren
/// objavljena mapa spletnega mesta, ki jo naslednja objava prepiše, aplikacijski bazen pa vanjo
/// praviloma nima pravice pisati. Datoteke, ki nastanejo tam, so torej ali izgubljene ob objavi
/// ali pa sploh ne nastanejo — in oboje se pokaže šele na strežniku.
///
/// Vrstni red velja povsod enako in je namenoma tak:
///
///   1. izrecni argument ukazne vrstice  — za ročni preizkus, ki ne sme spreminjati nastavitve
///   2. okoljska spremenljivka           — za en zagon ali eno okolje (test, prenos)
///   3. register <c>ops.SystemPath</c>   — kar je nastavil skrbnik; velja za vse
///   4. vgrajeni privzetek               — razvojni računalnik, dokler ni nastavljeno nič
///
/// Register je tretji in ne prvi: ročni zagon z <c>--target</c> mora ostati močnejši od
/// nastavitve, sicer se preizkus ne da izvesti drugje kot v produkcijski mapi.
/// </summary>
public static class SystemPaths
{
  /// <summary>Kamor prevzemnik odloži dobaviteljeve datoteke (in pod njimi mapo <c>arhiv</c>).</summary>
  public const string Landing = "LANDING_ROOT";

  /// <summary>Kamor gredo izvozne datoteke za splet — katalog in stranke.</summary>
  public const string Export = "EXPORT_ROOT";

  /// <summary>Kamor pišejo dnevniki skript in workerjev.</summary>
  public const string Log = "LOG_ROOT";

  /// <summary>Kamor gredo delovni zvezki za urejanje izdelkov.</summary>
  public const string Workbook = "WORKBOOK_ROOT";

  /// <summary>Vsi veljavni ključi; zaprt seznam, ker tipkarska napaka tiho izklopi nastavitev.</summary>
  public static IReadOnlyList<string> Keys { get; } = [Landing, Export, Log, Workbook];

  /// <summary>Kaj posamezen ključ pomeni, povedano človeku.</summary>
  public static string Describe(string key) => key switch
  {
    Landing => "Prevzete datoteke dobaviteljev (XML, CSV) in njihov arhiv",
    Export => "Izvozne datoteke za splet: katalog in stranke",
    Log => "Dnevniki nočnega toka, petminutnega cikla in samotesta",
    Workbook => "Delovni zvezki za urejanje izdelkov (Excel)",
    _ => key,
  };

  /// <summary>
  /// Pot iz registra ali <c>null</c>, kadar ni nastavljena. <c>null</c> pomeni »obdrži svoj
  /// privzetek« in nikoli »ne piši nikamor«: manjkajoča nastavitev ne sme ustaviti obdelave.
  /// </summary>
  public static async Task<string?> ResolveAsync(
    SqlConnection connection, string key, int? organizationId = null, CancellationToken cancellationToken = default)
  {
    await using var command = new SqlCommand("ops.ResolveSystemPath", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.Add("@PathKey", SqlDbType.NVarChar, 60).Value = key;
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = (object?)organizationId ?? DBNull.Value;
    var value = await command.ExecuteScalarAsync(cancellationToken);
    return value is null or DBNull ? null : Convert.ToString(value);
  }

  /// <summary>
  /// Odpre svojo povezavo; za klicatelje, ki poti potrebujejo, preden odprejo svojo.
  /// Nedosegljiva baza tu ne sme pasti: brez registra velja privzetek, kot je veljal prej.
  /// </summary>
  public static async Task<string?> ResolveAsync(
    string connectionString, string key, int? organizationId = null, CancellationToken cancellationToken = default)
  {
    try
    {
      await using var connection = new SqlConnection(connectionString);
      await connection.OpenAsync(cancellationToken);
      return await ResolveAsync(connection, key, organizationId, cancellationToken);
    }
    catch (SqlException)
    {
      return null;
    }
  }

  /// <summary>
  /// Ali je mapa dosegljiva in pišljiva <b>za račun, pod katerim tečemo</b>. To je edina
  /// preverba, ki šteje: mapa lahko obstaja in je vidna, pa vanjo ne smemo pisati — pod IIS je
  /// to celo običajno, ker aplikacijski bazen ni ne skrbnik ne prijavljeni uporabnik.
  ///
  /// Preverba dejansko zapiše in pobriše datoteko; <c>Directory.Exists</c> ne pove ničesar o
  /// pravicah, obstoj mape pa je bil doslej edino, kar je kdo preveril.
  /// </summary>
  public static PathCheck Check(string? location)
  {
    if (string.IsNullOrWhiteSpace(location))
      return new(false, "Pot ni vpisana.");

    // Relativna pot se pod IIS razreši glede na mapo procesa in ne glede na to, kar je imel
    // pisec v mislih. Zahtevamo absolutno, da je nastavitev enolična.
    if (!Path.IsPathFullyQualified(location))
      return new(false, "Pot mora biti absolutna (npr. D:\\PIM\\prevzem ali \\\\streznik\\delitev\\prevzem).");

    try
    {
      Directory.CreateDirectory(location);
      var preizkus = Path.Combine(location, $".pim-preizkus-{Guid.NewGuid():N}.tmp");
      File.WriteAllText(preizkus, "preizkus pisanja");
      File.Delete(preizkus);
      return new(true, $"Mapa je dosegljiva in pišljiva za račun {Identiteta()}.");
    }
    catch (UnauthorizedAccessException)
    {
      return new(false, $"Račun {Identiteta()} v to mapo nima pravice pisati.");
    }
    catch (DirectoryNotFoundException)
    {
      return new(false, "Poti ni mogoče najti; preveri ime strežnika in delitve.");
    }
    catch (IOException exception)
    {
      // Sporočilo lahko nosi celotno pot z imenom delitve; povemo vrsto napake, ne besedila.
      return new(false, $"Do mape ni mogoče pisati ({exception.GetType().Name}).");
    }
  }

  /// <summary>Pod katerim računom proces teče; pri IIS je to identiteta aplikacijskega bazena.</summary>
  public static string Identiteta()
  {
    var domena = Environment.UserDomainName;
    var uporabnik = Environment.UserName;
    return string.IsNullOrWhiteSpace(domena) ? uporabnik : $"{domena}\\{uporabnik}";
  }
}

/// <param name="Writable">Ali je bilo v mapo mogoče dejansko zapisati, ne le ali obstaja.</param>
public sealed record PathCheck(bool Writable, string Message);
