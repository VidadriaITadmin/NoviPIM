using System.Data;
using Microsoft.Data.SqlClient;

var connectionString = Environment.GetEnvironmentVariable("PIM_CONNECTION_STRING");
if (string.IsNullOrWhiteSpace(connectionString))
{
  Console.WriteLine("PIM_CONNECTION_STRING ni nastavljen; watchdog ni spremenil podatkov.");
  return 0;
}
await using var connection = new SqlConnection(connectionString);
await connection.OpenAsync();
await using var command = new SqlCommand("ops.RunWatchdog", connection) { CommandType = CommandType.StoredProcedure };
command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = $"PIM.Watchdog:{Environment.MachineName}";
await command.ExecuteNonQueryAsync();
await using var queue = new SqlCommand("ops.QueueAlertDeliveries", connection) { CommandType = CommandType.StoredProcedure };
await queue.ExecuteNonQueryAsync();
Console.WriteLine("Watchdog pregled je končan.");
return 0;
