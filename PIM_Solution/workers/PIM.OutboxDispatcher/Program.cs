using Microsoft.Data.SqlClient;
using PIM.OutboxDispatcher;
using PIM.Operations;

var connectionString = Environment.GetEnvironmentVariable("PIM_CONNECTION_STRING");
if (string.IsNullOrWhiteSpace(connectionString))
{
  Console.WriteLine("PIM_CONNECTION_STRING ni nastavljen; dispatcher ni izvedel nobenega HTTP klica.");
  return;
}

var workerId = $"{Environment.MachineName}:{Environment.ProcessId}";
await using var connection = new SqlConnection(connectionString);
await connection.OpenAsync();
await using var claim = new SqlCommand("EXEC out.ClaimMessage @WorkerId;", connection);
claim.Parameters.AddWithValue("@WorkerId", workerId);
await using var reader = await claim.ExecuteReaderAsync();
if (!await reader.ReadAsync()) return;
var messageId = reader.GetInt64(reader.GetOrdinal("OutboxMessageId"));
var organizationId = reader.GetInt32(reader.GetOrdinal("OrganizationId"));
var payload = reader.GetString(reader.GetOrdinal("PayloadJson"));
var endpointTemplate = reader.GetString(reader.GetOrdinal("EndpointTemplate"));
var operation = reader.GetString(reader.GetOrdinal("HttpOperation"));
var timeout = reader.GetInt32(reader.GetOrdinal("TimeoutSeconds"));
var attempt = reader.GetInt32(reader.GetOrdinal("AttemptCount"));
var maxAttempts = reader.GetInt32(reader.GetOrdinal("MaxAttempts"));
await reader.CloseAsync();
await using var operationsRun = await OperationsRun.BeginAsync(connectionString, organizationId, "OUTBOUND", workerId);

DispatchResult result;
try
{
  using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(timeout) };
  result = await new SaopOutboundHandler(http).SendAsync(new(new Uri(endpointTemplate), operation, payload), CancellationToken.None);
}
catch (Exception exception) when (exception is HttpRequestException or TaskCanceledException)
{
  var outcome = attempt >= maxAttempts ? DispatchOutcome.Dead : DispatchOutcome.Retry;
  result = new(outcome, 0, string.Empty, null);
}

await using var complete = new SqlCommand("EXEC out.CompleteAttempt @OutboxMessageId,@WorkerId,@Succeeded,@PermanentFailure,@ResponseStatusCode,@ResponseBodyRedacted,@ResponseCorrelationId,@FailureReason;", connection);
complete.Parameters.AddWithValue("@OutboxMessageId", messageId);
complete.Parameters.AddWithValue("@WorkerId", workerId);
complete.Parameters.AddWithValue("@Succeeded", result.Outcome == DispatchOutcome.Sent);
complete.Parameters.AddWithValue("@PermanentFailure", result.Outcome == DispatchOutcome.Dead);
complete.Parameters.AddWithValue("@ResponseStatusCode", result.StatusCode == 0 ? DBNull.Value : result.StatusCode);
complete.Parameters.AddWithValue("@ResponseBodyRedacted", result.RedactedBody);
complete.Parameters.AddWithValue("@ResponseCorrelationId", (object?)result.CorrelationId ?? DBNull.Value);
complete.Parameters.AddWithValue("@FailureReason", result.Outcome == DispatchOutcome.Sent ? DBNull.Value : $"HTTP dispatch: {result.Outcome}");
await complete.ExecuteNonQueryAsync();
await operationsRun.CompleteAsync(result.Outcome == DispatchOutcome.Sent, result.Outcome == DispatchOutcome.Sent ? null : "Odhodna dostava ni uspela.");
