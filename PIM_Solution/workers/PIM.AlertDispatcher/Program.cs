using System.Data;
using Microsoft.Data.SqlClient;
using PIM.AlertDispatcher;

var enabled = bool.TryParse(Environment.GetEnvironmentVariable("PIM_ALERT_DELIVERY_ENABLED"), out var parsed) && parsed;
var endpointText = Environment.GetEnvironmentVariable("PIM_ALERT_WEBHOOK_URL");
if (!enabled)
{
  Console.WriteLine("Dostava opozoril je privzeto izključena; omrežni klic ni bil izveden.");
  return 0;
}
if (!Uri.TryCreate(endpointText, UriKind.Absolute, out var endpoint))
{
  Console.Error.WriteLine("Omogočena dostava zahteva veljaven PIM_ALERT_WEBHOOK_URL.");
  return 2;
}
var connectionString = Environment.GetEnvironmentVariable("PIM_CONNECTION_STRING");
if (string.IsNullOrWhiteSpace(connectionString))
{
  Console.Error.WriteLine("Omogočena dostava zahteva PIM_CONNECTION_STRING.");
  return 2;
}

var workerId = $"{Environment.MachineName}:{Environment.ProcessId}";
await using var connection = new SqlConnection(connectionString);
await connection.OpenAsync();
await using var claim = new SqlCommand("ops.ClaimAlertDelivery", connection) { CommandType = CommandType.StoredProcedure };
claim.Parameters.Add("@WorkerId", SqlDbType.NVarChar, 200).Value = workerId;
claim.Parameters.Add("@LeaseSeconds", SqlDbType.Int).Value = 60;
await using var reader = await claim.ExecuteReaderAsync();
if (!await reader.ReadAsync()) return 0;
var deliveryId = reader.GetInt64(reader.GetOrdinal("AlertDeliveryId"));
var alertId = reader.GetInt64(reader.GetOrdinal("AlertId"));
var channel = reader.GetString(reader.GetOrdinal("Channel"));
await reader.CloseAsync();

AlertSendOutcome outcome;
if (!channel.Equals("Webhook", StringComparison.OrdinalIgnoreCase))
{
  outcome = AlertSendOutcome.Dead;
}
else
{
  await using var details = new SqlCommand("SELECT Title,PayloadSummaryRedacted FROM ops.Alert WHERE AlertId=@AlertId", connection);
  details.Parameters.Add("@AlertId", SqlDbType.BigInt).Value = alertId;
  await using var detailReader = await details.ExecuteReaderAsync();
  if (!await detailReader.ReadAsync()) throw new InvalidOperationException("Opozorilo ne obstaja.");
  var envelope = new AlertEnvelope(alertId, detailReader.GetString(0), detailReader.GetString(1));
  await detailReader.CloseAsync();
  using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };
  outcome = await new WebhookAlertSender(http, new(true, endpoint)).SendAsync(envelope);
}

await using var complete = new SqlCommand("ops.CompleteAlertDelivery", connection) { CommandType = CommandType.StoredProcedure };
complete.Parameters.Add("@AlertDeliveryId", SqlDbType.BigInt).Value = deliveryId;
complete.Parameters.Add("@WorkerId", SqlDbType.NVarChar, 200).Value = workerId;
complete.Parameters.Add("@Succeeded", SqlDbType.Bit).Value = outcome == AlertSendOutcome.Delivered;
complete.Parameters.Add("@PermanentFailure", SqlDbType.Bit).Value = outcome == AlertSendOutcome.Dead;
complete.Parameters.Add("@ErrorRedacted", SqlDbType.NVarChar, 2000).Value = outcome == AlertSendOutcome.Delivered ? DBNull.Value : "Dostava opozorila ni uspela.";
await complete.ExecuteNonQueryAsync();
return outcome == AlertSendOutcome.Delivered ? 0 : 1;
