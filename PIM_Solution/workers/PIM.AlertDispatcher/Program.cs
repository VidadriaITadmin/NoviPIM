using System.Data;
using Microsoft.Data.SqlClient;
using PIM.AlertDispatcher;
using PIM.Operations;

// Dostava opozoril in stopnjevanje odhodnih napak.
//
// Dvoje, kar tu ni bilo prej:
//
// 1. Stopnjevanje. Napaka odhodne poti, ki je uporabnik ne potrdi v dogovorjenem času, mora
//    postati opozorilo in oditi po e-pošti. Do zdaj se ta ura ni nikjer merila.
// 2. Kanal Email. Shema ga dovoljuje že od migracije 025, poslati pa ga ni znal nihče —
//    dispatcher je poznal samo spletni kavelj in vsako e-pošto označil kot Dead.
//
// Poleg tega je zanka: prej je vsak zagon obdelal eno samo dostavo, zato se vrsta ni praznila
// brez toliko zagonov, kolikor je bilo dostav. Isto napako je imel odhodni dispatcher.

var arguments = args.ToList();
var connectionString = Environment.GetEnvironmentVariable("PIM_CONNECTION_STRING");
if (string.IsNullOrWhiteSpace(connectionString))
{
  Console.Error.WriteLine("PIM_CONNECTION_STRING ni nastavljen.");
  return 2;
}

await using var connection = new SqlConnection(connectionString);
await connection.OpenAsync();

// Prejemniki se izpeljejo iz uporabnikov z naslovom in vlogo; vzdrževanje na dveh mestih bi
// pomenilo, da nekdo dobi pravico in ne dobi obvestil.
if (arguments.Contains("--sync-recipients"))
{
  var role = Value("--role") ?? "ADMIN";
  await using var sync = new SqlCommand("ops.SyncAlertRecipientsFromUsers", connection) { CommandType = CommandType.StoredProcedure };
  sync.Parameters.Add("@RoleName", SqlDbType.NVarChar, 100).Value = role;
  var recipients = Convert.ToInt32(await sync.ExecuteScalarAsync() ?? 0);
  Console.WriteLine($"Prejemnikov e-pošte za vlogo {role}: {recipients}.");
}

// Stopnjevanje teče vedno in ne potrebuje omogočene dostave: vrsta se sme napolniti, tudi če
// pošiljanje še ni vklopljeno. Tako se ob vklopu vidi, kaj bi bilo poslano.
var escalationSeconds = int.TryParse(Value("--escalate-after"), out var parsedSeconds) ? parsedSeconds : 300;
await using (var escalate = new SqlCommand("ops.EscalateOutboundEvents", connection) { CommandType = CommandType.StoredProcedure })
{
  escalate.Parameters.Add("@AfterSeconds", SqlDbType.Int).Value = escalationSeconds;
  var escalated = Convert.ToInt32(await escalate.ExecuteScalarAsync() ?? 0);
  if (escalated > 0)
    Console.WriteLine($"Stopnjevanih nepotrjenih napak (starejših od {escalationSeconds} s): {escalated}.");
}

var deliveryEnabled = string.Equals(Environment.GetEnvironmentVariable("PIM_ALERT_DELIVERY_ENABLED"), "true", StringComparison.OrdinalIgnoreCase);
if (!deliveryEnabled)
{
  Console.WriteLine("Dostava opozoril je privzeto izključena; omrežni klic ni bil izveden.");
  return 0;
}

var webhookOptions = Uri.TryCreate(Environment.GetEnvironmentVariable("PIM_ALERT_WEBHOOK_URL"), UriKind.Absolute, out var webhookUri)
  ? new AlertDeliveryOptions(true, webhookUri)
  : new AlertDeliveryOptions(false, null);
var emailOptions = EmailAlertSender.FromEnvironment();

if (!webhookOptions.Enabled && !emailOptions.Enabled)
{
  Console.Error.WriteLine("Omogočena dostava zahteva PIM_ALERT_WEBHOOK_URL ali vklopljeno e-pošto (PIM_ALERT_EMAIL_ENABLED).");
  return 2;
}

var workerId = $"{Environment.MachineName}:{Environment.ProcessId}";
var maxDeliveries = int.TryParse(Value("--max"), out var parsedMax) ? parsedMax : 50;
using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };
var webhookSender = new WebhookAlertSender(http, webhookOptions);
var emailSender = new EmailAlertSender(emailOptions);

await using var operationsRun = await OperationsRun.BeginAsync(connectionString, 2, "ALERT_DISPATCH", workerId);
var delivered = 0;
var failed = 0;
var skipped = 0;

try
{
  for (var handled = 0; handled < maxDeliveries; handled++)
  {
    var claimed = await ClaimAsync();
    if (claimed is null) break;

    // Utrip na dostavo: brez tega bi daljša vrsta izgledala kot zastal zagon.
    await operationsRun.HeartbeatAsync();

    var envelope = await ReadAlertAsync(claimed.AlertId);
    var outcome = claimed.Channel.ToLowerInvariant() switch
    {
      "webhook" => await webhookSender.SendAsync(envelope),
      "email" => await emailSender.SendAsync(envelope, claimed.RecipientKey),
      // Neznanega kanala ne poskušamo peteršiljiti: to je napaka nastavitve, ne omrežja.
      _ => AlertSendOutcome.Dead
    };

    // Izklopljen kanal ni napaka dostave. Vrstica ostane v vrsti za takrat, ko bo vklopljen.
    if (outcome == AlertSendOutcome.Disabled) { await ReleaseAsync(claimed.AlertDeliveryId); skipped++; continue; }

    await CompleteAsync(claimed.AlertDeliveryId, outcome);
    if (outcome == AlertSendOutcome.Delivered) delivered++; else failed++;
  }

  Console.WriteLine($"Dostav: uspešnih {delivered}, neuspešnih {failed}, preskočenih (kanal izključen) {skipped}.");
  await operationsRun.CompleteAsync(failed == 0, failed == 0 ? null : "Dostava opozorila ni uspela.");
  return failed == 0 ? 0 : 1;
}
catch
{
  await operationsRun.CompleteAsync(false, "Dostava opozoril se je končala z napako.");
  throw;
}

string? Value(string name)
{
  var index = arguments.IndexOf(name);
  return index >= 0 && index + 1 < arguments.Count ? arguments[index + 1] : null;
}

async Task<ClaimedDelivery?> ClaimAsync()
{
  await using var claim = new SqlCommand("ops.ClaimAlertDelivery", connection) { CommandType = CommandType.StoredProcedure };
  claim.Parameters.Add("@WorkerId", SqlDbType.NVarChar, 200).Value = workerId;
  claim.Parameters.Add("@LeaseSeconds", SqlDbType.Int).Value = 60;
  await using var reader = await claim.ExecuteReaderAsync();
  if (!await reader.ReadAsync()) return null;
  return new(
    reader.GetInt64(reader.GetOrdinal("AlertDeliveryId")),
    reader.GetInt64(reader.GetOrdinal("AlertId")),
    reader.GetString(reader.GetOrdinal("Channel")),
    reader.GetString(reader.GetOrdinal("RecipientKey")));
}

async Task<AlertEnvelope> ReadAlertAsync(long alertId)
{
  await using var details = new SqlCommand("SELECT Title,PayloadSummaryRedacted FROM ops.Alert WHERE AlertId=@AlertId", connection);
  details.Parameters.Add("@AlertId", SqlDbType.BigInt).Value = alertId;
  await using var reader = await details.ExecuteReaderAsync();
  if (!await reader.ReadAsync()) throw new InvalidOperationException("Opozorilo ne obstaja.");
  return new(alertId, reader.GetString(0), reader.GetString(1));
}

async Task CompleteAsync(long deliveryId, AlertSendOutcome outcome)
{
  await using var complete = new SqlCommand("ops.CompleteAlertDelivery", connection) { CommandType = CommandType.StoredProcedure };
  complete.Parameters.Add("@AlertDeliveryId", SqlDbType.BigInt).Value = deliveryId;
  complete.Parameters.Add("@WorkerId", SqlDbType.NVarChar, 200).Value = workerId;
  complete.Parameters.Add("@Succeeded", SqlDbType.Bit).Value = outcome == AlertSendOutcome.Delivered;
  complete.Parameters.Add("@PermanentFailure", SqlDbType.Bit).Value = outcome == AlertSendOutcome.Dead;
  complete.Parameters.Add("@ErrorRedacted", SqlDbType.NVarChar, 2000).Value =
    outcome == AlertSendOutcome.Delivered ? DBNull.Value : "Dostava opozorila ni uspela.";
  await complete.ExecuteNonQueryAsync();
}

/// <summary>Vrne dostavo v vrsto brez porabe poskusa; uporablja se, kadar je kanal izključen.</summary>
async Task ReleaseAsync(long deliveryId)
{
  await using var release = new SqlCommand(
    "UPDATE ops.AlertDelivery SET Status=N'Pending',AttemptCount=CASE WHEN AttemptCount>0 THEN AttemptCount-1 ELSE 0 END,"
    + "LeaseOwner=NULL,LeaseUntilUtc=NULL,NextAttemptUtc=SYSUTCDATETIME(),UpdatedUtc=SYSUTCDATETIME() "
    + "WHERE AlertDeliveryId=@Id AND LeaseOwner=@WorkerId;", connection);
  release.Parameters.Add("@Id", SqlDbType.BigInt).Value = deliveryId;
  release.Parameters.Add("@WorkerId", SqlDbType.NVarChar, 200).Value = workerId;
  await release.ExecuteNonQueryAsync();
}

sealed record ClaimedDelivery(long AlertDeliveryId, long AlertId, string Channel, string RecipientKey);
