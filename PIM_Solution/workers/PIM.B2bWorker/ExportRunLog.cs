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
        var info = new FileInfo(filePath);
        bytes = info.Length;
        hash = await HashAsync(filePath, ct);
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
      await command.ExecuteNonQueryAsync(ct);
    }
    catch (SqlException exception)
    {
      Console.Error.WriteLine($"Opozorilo: zaključka izvoza ni bilo mogoče zabeležiti ({exception.Number}).");
    }
    catch (IOException)
    {
      // Datoteka je nastala, a je zaklenjena ali že premaknjena; velikost in hash nista dokaz,
      // brez katerega izvoz ne bi veljal.
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
