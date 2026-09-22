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

// Faza IZRACUN (blok 6 prenove nadzora, 2026-09-22): koliko alarmov je pregled odprl in zaprl ter
// koliko jih je šlo v vrsto za dostavo. Brez tega je bil pregled na strani Nadzor viden le kot
// izhodna koda 0 — enako, ali je odprl deset alarmov ali nobenega. Alarmi veljajo za vsa podjetja,
// zato faza nima podjetja.
const string WatchdogPipeline = "WATCHDOG";
var actor = $"PIM.Watchdog:{Environment.MachineName}";
var phases = PhaseLog.FromEnvironment(connectionString, $"{Environment.MachineName}:{Environment.ProcessId}");
var zacetek = await ServerNowAsync(connection);
await using var izracun = await phases.BeginAsync(PhaseCodes.Compute, WatchdogPipeline, null, WatchdogPipeline);
try
{
  await using var command = new SqlCommand("ops.RunWatchdog", connection) { CommandType = CommandType.StoredProcedure };
  command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = $"PIM.Watchdog:{Environment.MachineName}";
  await command.ExecuteNonQueryAsync();

  // Zaostanek postopkov (ops.RaiseOverdueAlerts, migracija 221/226) odpira IN zapira alarme
  // PipelineOverdue po dejanskem utripu; alarmov CycleOverdue od migracije 254 ni več (starih ciklov ni,
  // zamujanje poslov javlja gostitelj z ops.EvaluateJobAlerts). Do 2026-09-21 je proceduro klical samo tik
  // razporejevalnika v intranetu: ko ta ni tekel (najem potekel 11:26 UTC), Windows naloge pa so postopke
  // poganjale naprej, je alarm "Postopek MAGENTO_STOCK_PRICES ni tekel 4250 min" ostal odprt kljub uspešnim
  // zagonom ob 15:03 in 15:23 UTC — uporabnik: »nadzor je preveč hrupen«. Nadzornik teče vsakih
  // 5 minut ne glede na to, kdo je ura, zato uskladitev sodi sem.
  await using var overdue = new SqlCommand("ops.RaiseOverdueAlerts", connection) { CommandType = CommandType.StoredProcedure };
  overdue.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = $"PIM.Watchdog:{Environment.MachineName}";
  await overdue.ExecuteNonQueryAsync();

  await using var queue = new SqlCommand("ops.QueueAlertDeliveries", connection) { CommandType = CommandType.StoredProcedure };
  await queue.ExecuteNonQueryAsync();
}
catch (Exception exception) when (exception is not OperationCanceledException)
{
  await izracun.FailedAsync($"pregled je padel: {exception.Message}");
  throw;
}

var stevila = zacetek is { } od ? await CountAlertsAsync(connection, od, actor) : null;
if (stevila is { } s)
{
  await izracun.SucceededAsync(itemsOut: s.Opened + s.Resolved, hasNewData: s.Opened + s.Resolved > 0,
    message: $"novih alarmov {s.Opened}, zaprtih {s.Resolved}, odprtih skupaj {s.OpenNow}, v vrsto za dostavo {s.Queued}");
}
else
{
  await izracun.SucceededAsync(hasNewData: false, message: "pregled je končan; števil alarmov ni bilo mogoče prebrati");
}
await operationsRun.CompleteAsync(true);
Console.WriteLine("Watchdog pregled je končan.");
return 0;

// Čas strežnika pred pregledom: alarmi se primerjajo z uro baze, ne z uro workerja.
static async Task<DateTime?> ServerNowAsync(SqlConnection connection)
{
  try
  {
    await using var now = new SqlCommand("SELECT DATEADD(millisecond, -5, SYSUTCDATETIME());", connection);
    return await now.ExecuteScalarAsync() is DateTime value ? value : null;
  }
  catch (Exception exception) when (exception is SqlException or InvalidOperationException)
  {
    return null;
  }
}

// Števila za fazo; napaka pri štetju ne sme podreti pregleda, ki je že uspel.
static async Task<(int Opened, int Resolved, int OpenNow, int Queued)?> CountAlertsAsync(SqlConnection connection, DateTime since, string actor)
{
  try
  {
    await using var count = new SqlCommand("""
      SELECT (SELECT COUNT(*) FROM ops.Alert WHERE FirstSeenUtc >= @Since AND UpdatedBy = @Actor),
             (SELECT COUNT(*) FROM ops.Alert WHERE ResolvedUtc >= @Since AND ResolvedBy = @Actor),
             (SELECT COUNT(*) FROM ops.Alert WHERE ResolvedUtc IS NULL),
             (SELECT COUNT(*) FROM ops.AlertDelivery WHERE NextAttemptUtc >= @Since AND AttemptCount = 0);
      """, connection);
    count.Parameters.Add("@Since", SqlDbType.DateTime2).Value = since;
    count.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = actor;
    await using var reader = await count.ExecuteReaderAsync();
    if (!await reader.ReadAsync()) return null;
    return (reader.GetInt32(0), reader.GetInt32(1), reader.GetInt32(2), reader.GetInt32(3));
  }
  catch (Exception exception) when (exception is SqlException or InvalidOperationException)
  {
    return null;
  }
}
