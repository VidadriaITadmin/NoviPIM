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
