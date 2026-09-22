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

// Zaostanek ciklov in postopkov (ops.RaiseOverdueAlerts, migracija 221/226) odpira IN zapira alarme
// CycleOverdue/PipelineOverdue po dejanskem utripu. Do 2026-09-21 ga je klical samo tik razporejevalnika
// v intranetu: ko ta ni tekel (najem potekel 11:26 UTC), Windows naloge pa so postopke poganjale
// naprej, je alarm "Postopek MAGENTO_STOCK_PRICES ni tekel 4250 min" ostal odprt kljub uspešnim
// zagonom ob 15:03 in 15:23 UTC — uporabnik: »nadzor je preveč hrupen«. Nadzornik teče vsakih
// 5 minut ne glede na to, kdo je ura, zato uskladitev sodi sem.
await using var overdue = new SqlCommand("ops.RaiseOverdueAlerts", connection) { CommandType = CommandType.StoredProcedure };
overdue.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = $"PIM.Watchdog:{Environment.MachineName}";
await overdue.ExecuteNonQueryAsync();

await using var queue = new SqlCommand("ops.QueueAlertDeliveries", connection) { CommandType = CommandType.StoredProcedure };
await queue.ExecuteNonQueryAsync();
await operationsRun.CompleteAsync(true);
Console.WriteLine("Watchdog pregled je končan.");
return 0;
