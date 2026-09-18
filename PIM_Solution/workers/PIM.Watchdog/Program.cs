using System.Data;
using Microsoft.Data.SqlClient;
using PIM.Operations;

var connectionString = LocalSettings.ConnectionString();
if (string.IsNullOrWhiteSpace(connectionString))
{
  Console.Error.WriteLine(LocalSettings.MissingConnectionMessage());
  return 2;
}
await using var connection = new SqlConnection(connectionString);
await connection.OpenAsync();
await using var operationsRun = await OperationsRun.BeginAsync(connectionString, 2, "WATCHDOG", $"{Environment.MachineName}:{Environment.ProcessId}");
await using var command = new SqlCommand("ops.RunWatchdog", connection) { CommandType = CommandType.StoredProcedure };
command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = $"PIM.Watchdog:{Environment.MachineName}";
await command.ExecuteNonQueryAsync();
await using var queue = new SqlCommand("ops.QueueAlertDeliveries", connection) { CommandType = CommandType.StoredProcedure };
await queue.ExecuteNonQueryAsync();
await operationsRun.CompleteAsync(true);
Console.WriteLine("Watchdog pregled je končan.");
return 0;
