using System.Data;
using Microsoft.Data.SqlClient;

namespace PIM.Operations;

public sealed class OperationsRun : IAsyncDisposable
{
  private readonly SqlConnection connection;
  private bool completed;

  private OperationsRun(SqlConnection connection, int organizationId, string pipeline, Guid runId)
  {
    this.connection = connection;
    OrganizationId = organizationId;
    Pipeline = pipeline;
    RunId = runId;
  }

  public int OrganizationId { get; }
  public string Pipeline { get; }
  public Guid RunId { get; }

  /// <summary>
  /// Ali je postopek na vrsti po razporedu iz baze.
  ///
  /// Nacrtovano opravilo Windows je ura, ki tiktaka na 5 minut in nima poslovne vednosti; ritem
  /// posameznega postopka je vrstica v <c>ops.ScheduleProfile</c>, ki jo skrbnik ureja na strani
  /// /sistem/urniki. Brez tega bi bila edina pot do spremembe ritma poseg v sistemske nastavitve
  /// streznika, do katerih uporabnik PIM-a nima dostopa.
  ///
  /// Klicejo jo samo nacrtovani zagoni (stikalo <c>--po-urniku</c>). Rocni zagon iz ukazne
  /// vrstice razpored namenoma obide, da se da stvar preizkusiti takoj.
  /// </summary>
  public static async Task<bool> IsDueAsync(string connectionString, int organizationId, string pipeline, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(connectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.IsPipelineDue", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@Pipeline", SqlDbType.NVarChar, 100).Value = pipeline;

    // Manjkajoca vrstica pomeni, da razporeda ni; takrat ne tece nic — enako kot IsEnabled = 0.
    var value = await command.ExecuteScalarAsync(cancellationToken);
    return value is bool due && due;
  }

  public static async Task<OperationsRun> BeginAsync(string connectionString, int organizationId, string pipeline, string workerId, CancellationToken cancellationToken = default)
  {
    var connection = new SqlConnection(connectionString);
    await connection.OpenAsync(cancellationToken);
    try
    {
      await using var command = new SqlCommand("ops.BeginRun", connection) { CommandType = CommandType.StoredProcedure };
      command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
      command.Parameters.Add("@Pipeline", SqlDbType.NVarChar, 100).Value = pipeline;
      command.Parameters.Add("@WorkerId", SqlDbType.NVarChar, 200).Value = workerId;
      // Kdo je zagon sprozil (144): razporejevalnik v aplikaciji in skripte nastavijo
      // PIM_TRIGGERED_BY na Scheduler oziroma Task; brez tega je vsak tek v ops.PipelineRun
      // "Human", tudi tisti ob treh ponoci — doslej ga ni podajal nihce.
      command.Parameters.Add("@TriggeredBy", SqlDbType.NVarChar, 30).Value = TriggeredBy();
      var runId = command.Parameters.Add("@RunId", SqlDbType.UniqueIdentifier);
      runId.Direction = ParameterDirection.Output;
      await command.ExecuteNonQueryAsync(cancellationToken);
      return new OperationsRun(connection, organizationId, pipeline, (Guid)runId.Value);
    }
    catch
    {
      await connection.DisposeAsync();
      throw;
    }
  }

  /// <summary>Vrednost za ops.PipelineRun.TriggeredBy iz okolja; zaprt seznam iz migracije 144.</summary>
  public static string TriggeredBy()
  {
    var value = Environment.GetEnvironmentVariable("PIM_TRIGGERED_BY");
    return value is "Scheduler" or "Human" or "Task" ? value : "Human";
  }

  public async Task HeartbeatAsync(DateTime? watermarkUtc = null, CancellationToken cancellationToken = default)
  {
    await using var command = new SqlCommand("ops.RecordHeartbeat", connection) { CommandType = CommandType.StoredProcedure };
    AddRunParameters(command);
    command.Parameters.Add("@WatermarkUtc", SqlDbType.DateTime2).Value = (object?)watermarkUtc ?? DBNull.Value;
    await command.ExecuteNonQueryAsync(cancellationToken);
  }

  public async Task CompleteAsync(bool succeeded, string? redactedError = null, CancellationToken cancellationToken = default)
  {
    await using var command = new SqlCommand("ops.CompleteRun", connection) { CommandType = CommandType.StoredProcedure };
    AddRunParameters(command);
    command.Parameters.Add("@Succeeded", SqlDbType.Bit).Value = succeeded;
    command.Parameters.Add("@ErrorRedacted", SqlDbType.NVarChar, 2000).Value = (object?)redactedError ?? DBNull.Value;
    await command.ExecuteNonQueryAsync(cancellationToken);
    completed = true;
  }

  public async ValueTask DisposeAsync()
  {
    if (!completed && connection.State == ConnectionState.Open)
    {
      try { await CompleteAsync(false, "Izvajanje je bilo prekinjeno."); }
      catch (SqlException) { }
    }
    await connection.DisposeAsync();
  }

  private void AddRunParameters(SqlCommand command)
  {
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = OrganizationId;
    command.Parameters.Add("@Pipeline", SqlDbType.NVarChar, 100).Value = Pipeline;
    command.Parameters.Add("@RunId", SqlDbType.UniqueIdentifier).Value = RunId;
  }
}
