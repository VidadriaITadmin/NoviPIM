using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Net.Mail;

namespace PIM.StockReplenishmentWorker;

/// <summary>
/// Isti prevoznik (SMTP/Resend) in ista okoljska imena kot workers/PIM.AlertDispatcher/EmailAlertSender.cs
/// — namenoma podvojeno (delavci so samostojni), a ne ponovno izumljeno: enaka razmejitev
/// trajna/začasna napaka, enaka izbira prevoznika. Razlika: ta pošilja HTML in poljuben naslov/telo,
/// ne fiksno oblikovano opozorilo (AlertEnvelope) — ta delavec ne pošilja ops.Alert opozoril, pošilja
/// dnevni povzetek zaloge.
/// </summary>
public sealed record DigestEmailOptions(
  bool Enabled = false,
  string Provider = "Smtp",
  string? Host = null,
  int Port = 25,
  bool UseStartTls = false,
  string? Username = null,
  string? Password = null,
  string? From = null,
  string? ResendApiKey = null)
{
  public static DigestEmailOptions FromEnvironment() => new(
    Enabled: string.Equals(Environment.GetEnvironmentVariable("PIM_ALERT_EMAIL_ENABLED"), "true", StringComparison.OrdinalIgnoreCase),
    Provider: Environment.GetEnvironmentVariable("PIM_ALERT_EMAIL_PROVIDER") is { Length: > 0 } provider ? provider : "Smtp",
    Host: Environment.GetEnvironmentVariable("PIM_SMTP_HOST"),
    Port: int.TryParse(Environment.GetEnvironmentVariable("PIM_SMTP_PORT"), out var port) ? port : 25,
    UseStartTls: string.Equals(Environment.GetEnvironmentVariable("PIM_SMTP_STARTTLS"), "true", StringComparison.OrdinalIgnoreCase),
    Username: Environment.GetEnvironmentVariable("PIM_SMTP_USERNAME"),
    Password: Environment.GetEnvironmentVariable("PIM_SMTP_PASSWORD"),
    From: Environment.GetEnvironmentVariable("PIM_SMTP_FROM"),
    ResendApiKey: Environment.GetEnvironmentVariable("PIM_RESEND_API_KEY"));
}

public enum DigestSendOutcome { Disabled, Delivered, Dead, Retry }

public sealed class DigestEmailSender(DigestEmailOptions options, HttpClient? http = null)
{
  public Task<DigestSendOutcome> SendAsync(string subject, string htmlBody, string recipient, CancellationToken cancellationToken = default)
  {
    if (!options.Enabled || string.IsNullOrWhiteSpace(options.From)) return Task.FromResult(DigestSendOutcome.Disabled);
    if (!IsPlausibleAddress(recipient)) return Task.FromResult(DigestSendOutcome.Dead);

    return string.Equals(options.Provider, "Resend", StringComparison.OrdinalIgnoreCase)
      ? SendViaResendAsync(subject, htmlBody, recipient, cancellationToken)
      : SendViaSmtpAsync(subject, htmlBody, recipient, cancellationToken);
  }

  async Task<DigestSendOutcome> SendViaResendAsync(string subject, string htmlBody, string recipient, CancellationToken cancellationToken)
  {
    if (string.IsNullOrWhiteSpace(options.ResendApiKey) || http is null) return DigestSendOutcome.Disabled;

    try
    {
      using var request = new HttpRequestMessage(HttpMethod.Post, "https://api.resend.com/emails");
      request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", options.ResendApiKey);
      request.Content = JsonContent.Create(new { from = options.From, to = new[] { recipient }, subject, html = htmlBody });
      using var response = await http.SendAsync(request, cancellationToken);
      if (response.IsSuccessStatusCode) return DigestSendOutcome.Delivered;
      return (int)response.StatusCode is >= 400 and < 500 ? DigestSendOutcome.Dead : DigestSendOutcome.Retry;
    }
    catch (Exception exception) when (exception is HttpRequestException or TaskCanceledException)
    {
      return DigestSendOutcome.Retry;
    }
  }

  async Task<DigestSendOutcome> SendViaSmtpAsync(string subject, string htmlBody, string recipient, CancellationToken cancellationToken)
  {
    if (string.IsNullOrWhiteSpace(options.Host)) return DigestSendOutcome.Disabled;

    using var client = new SmtpClient(options.Host, options.Port)
    {
      EnableSsl = options.UseStartTls,
      DeliveryMethod = SmtpDeliveryMethod.Network,
      Timeout = 30_000
    };
    if (!string.IsNullOrWhiteSpace(options.Username))
      client.Credentials = new NetworkCredential(options.Username, options.Password ?? string.Empty);

    using var message = new MailMessage(options.From!, recipient) { Subject = subject, Body = htmlBody, IsBodyHtml = true };

    try
    {
      await client.SendMailAsync(message, cancellationToken);
      return DigestSendOutcome.Delivered;
    }
    catch (SmtpFailedRecipientException)
    {
      return DigestSendOutcome.Dead;
    }
    catch (SmtpException exception)
    {
      return exception.StatusCode is SmtpStatusCode.MailboxNameNotAllowed
        or SmtpStatusCode.MailboxUnavailable or SmtpStatusCode.UserNotLocalWillForward
        ? DigestSendOutcome.Dead
        : DigestSendOutcome.Retry;
    }
    catch (Exception exception) when (exception is IOException or TaskCanceledException or InvalidOperationException)
    {
      return DigestSendOutcome.Retry;
    }
  }

  static bool IsPlausibleAddress(string? value)
  {
    if (string.IsNullOrWhiteSpace(value)) return false;
    try { _ = new MailAddress(value); return true; }
    catch (FormatException) { return false; }
  }
}
