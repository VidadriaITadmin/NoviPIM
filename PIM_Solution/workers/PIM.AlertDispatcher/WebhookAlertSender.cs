using System.Net.Http.Json;

namespace PIM.AlertDispatcher;

public sealed record AlertDeliveryOptions(bool Enabled = false, Uri? WebhookUri = null);
public sealed record AlertEnvelope(long AlertId, string Title, string PayloadSummaryRedacted);
public enum AlertSendOutcome { Disabled, Delivered, Retry, Dead }

public sealed class WebhookAlertSender(HttpClient client, AlertDeliveryOptions options)
{
  public async Task<AlertSendOutcome> SendAsync(AlertEnvelope alert, CancellationToken cancellationToken = default)
  {
    if (!options.Enabled || options.WebhookUri is null) return AlertSendOutcome.Disabled;
    try
    {
      using var response = await client.PostAsJsonAsync(options.WebhookUri, alert, cancellationToken);
      if (response.IsSuccessStatusCode) return AlertSendOutcome.Delivered;
      return (int)response.StatusCode is >= 400 and < 500 ? AlertSendOutcome.Dead : AlertSendOutcome.Retry;
    }
    catch (Exception exception) when (exception is HttpRequestException or TaskCanceledException)
    {
      return AlertSendOutcome.Retry;
    }
  }
}
