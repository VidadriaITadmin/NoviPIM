using System.Data;
using System.Security.Cryptography;
using Microsoft.Data.SqlClient;

namespace PIM.B2bWorker;

/// <summary>
/// Zapis o eni sestavljeni izvozni datoteki (<c>out.ExportRun</c>, migracija 172).
///
/// Zakaj: do te migracije po izvozu ni ostalo nič. <c>out.ExportProfile</c> pove, kakšna naj bi
/// datoteka bila, ne pa ali je kdaj nastala, koliko vrstic je imela, kako dolgo je trajalo in
/// ali je padla. Vprašanje »ali je Magento zjutraj dobil svež CSV« je bilo vprašanje za
/// Raziskovalca datotek, ne za sistem.
///
/// Zapis ne sme podreti izvoza. Datoteka, ki je nastala, je pomembnejša od zapisa o njej —
/// zato so vse napake tu požrte in samo izpisane. Nasprotno bi pomenilo, da nedosegljiva
/// tabela dnevnika ustavi dostavo na splet.
/// </summary>
internal static class ExportRunLog
{
  public static async Task<Guid?> BeginAsync(
    SqlConnection connection, string profileCode, int organizationId, CancellationToken ct)
  {
    try
    {
      await using var command = new SqlCommand("out.BeginExportRun", connection) { CommandType = CommandType.StoredProcedure };
      command.Parameters.Add("@ProfileCode", SqlDbType.NVarChar, 100).Value = profileCode;
      command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
      command.Parameters.Add("@TriggeredBy", SqlDbType.NVarChar, 30).Value = TriggeredBy();
      command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = Actor();
      var key = command.Parameters.Add("@RunKey", SqlDbType.UniqueIdentifier);
      key.Direction = ParameterDirection.Output;
      await command.ExecuteNonQueryAsync(ct);
      return (Guid)key.Value;
    }
    catch (SqlException exception)
    {
      Console.Error.WriteLine($"Opozorilo: zagona izvoza ni bilo mogoče zabeležiti ({exception.Number}).");
      return null;
    }
  }

  public static async Task CompleteAsync(
    SqlConnection connection, Guid? runKey, bool succeeded,
    long? rowCount = null, int? columnCount = null, string? filePath = null, string? error = null,
    CancellationToken ct = default)
  {
    if (runKey is null) return;

    try
    {
      long? bytes = null;
      string? hash = null;
      if (succeeded && filePath is not null && File.Exists(filePath))
      {
        // Velikost in hash sta ločena: velikost pove tudi, kadar hasha ni bilo mogoče prebrati.
        try { bytes = new FileInfo(filePath).Length; }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
        hash = await TryHashAsync(filePath, ct);
      }

      // Po preteku ukaza (timeout) ali pretrgani povezavi je SqlConnection zaprt oziroma pokvarjen.
      // Zaključek se mora zabeležiti kljub temu: sicer vrstica ostane v Running, v finally klicatelja
      // pa nova izjema ("requires an open and available Connection") prekrije pravi vzrok. Izmerjeno
      // 2026-09-21: izvoz podjetja 2 je po 635 s padel, pravi vzrok — pretek 600 s v out.GetExportRows —
      // je ostal neviden, zapisa MAGENTO_PRODUCTS/MAGENTO_CUSTOMERS pa v Running.
      if (connection.State != ConnectionState.Open)
      {
        try { connection.Close(); } catch (InvalidOperationException) { }
        await connection.OpenAsync(CancellationToken.None);
      }

      await using var command = new SqlCommand("out.CompleteExportRun", connection) { CommandType = CommandType.StoredProcedure };
      command.Parameters.Add("@RunKey", SqlDbType.UniqueIdentifier).Value = runKey.Value;
      command.Parameters.Add("@Succeeded", SqlDbType.Bit).Value = succeeded;
      command.Parameters.Add("@RowCountValue", SqlDbType.BigInt).Value = (object?)rowCount ?? DBNull.Value;
      command.Parameters.Add("@ColumnCountValue", SqlDbType.Int).Value = (object?)columnCount ?? DBNull.Value;
      command.Parameters.Add("@ByteCountValue", SqlDbType.BigInt).Value = (object?)bytes ?? DBNull.Value;
      command.Parameters.Add("@Sha256", SqlDbType.Char, 64).Value = (object?)hash ?? DBNull.Value;
      command.Parameters.Add("@FileName", SqlDbType.NVarChar, 400).Value =
        filePath is null ? DBNull.Value : Path.GetFileName(filePath);
      command.Parameters.Add("@ErrorRedacted", SqlDbType.NVarChar, 2000).Value =
        error is null ? DBNull.Value : Skrajsaj(error);
      // Zaključek ne sme biti odvisen od preklica, ki je morda ustavil sam izvoz.
      await command.ExecuteNonQueryAsync(CancellationToken.None);
    }
    catch (Exception exception) when (exception is SqlException or InvalidOperationException or IOException)
    {
      // Zapis ne sme podreti izvoza in ne sme prekriti prvotne napake (glej opis razreda).
      Console.Error.WriteLine($"Opozorilo: zaključka izvoza ni bilo mogoče zabeležiti ({exception.GetType().Name}: {exception.Message}).");
    }
  }

  /// <summary>
  /// Hash z do tremi poskusi: datoteka je pravkar objavljena in jo lahko za hip izključujoče drži
  /// protivirusni program ali bralec. Če ne uspe, se zaključek zabeleži brez hasha — status ostane
  /// Succeeded, ker datoteka JE objavljena (oznaka magento-export.complete obstaja); zapis ne sme
  /// ostati v Running, izid pa ne sme biti prikazan kot padec. Velikost datoteke ostane zapisana.
  /// </summary>
  internal static async Task<string?> TryHashAsync(string path, CancellationToken ct)
  {
    for (var attempt = 1; ; attempt++)
    {
      try { return await HashAsync(path, ct); }
      catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
      {
        if (attempt >= 3)
        {
          Console.Error.WriteLine($"Opozorilo: kontrolne vsote izvoza ni bilo mogoče prebrati ({exception.Message}); zaključek se zabeleži brez nje.");
          return null;
        }
        await Task.Delay(TimeSpan.FromMilliseconds(250 * attempt), CancellationToken.None);
      }
    }
  }

  /// <summary>Hash je edini način, da se dve dostavi ločita brez odpiranja datoteke.</summary>
  static async Task<string> HashAsync(string path, CancellationToken ct)
  {
    await using var stream = File.OpenRead(path);
    var hash = await SHA256.HashDataAsync(stream, ct);
    return Convert.ToHexString(hash).ToLowerInvariant();
  }

  /// <summary>Enaka pogodba kot pri <c>ops.BeginRun</c> (migracija 144): kdo je zagon sprožil.</summary>
  static string TriggeredBy()
  {
    var value = Environment.GetEnvironmentVariable("PIM_TRIGGERED_BY");
    return value is "Scheduler" or "Human" or "Task" ? value : "Human";
  }

  static string Actor()
  {
    var value = Environment.GetEnvironmentVariable("PIM_ACTOR");
    return string.IsNullOrWhiteSpace(value) ? Environment.UserName : value;
  }

  static string Skrajsaj(string value) => value.Length <= 2000 ? value : value[..2000];
}
