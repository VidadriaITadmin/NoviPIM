using System.Net;
using System.Net.Mail;

namespace PIM.AlertDispatcher;

/// <param name="Enabled">Privzeto izklopljeno; brez izrecnega vklopa se ne pošlje nobena e-pošta.</param>
/// <param name="From">Naslov pošiljatelja; brez njega SMTP strežnik zavrne sporočilo.</param>
public sealed record EmailDeliveryOptions(
  bool Enabled = false,
  string? Host = null,
  int Port = 25,
  bool UseStartTls = false,
  string? Username = null,
  string? Password = null,
  string? From = null);

/// <summary>
/// Pošlje opozorilo po e-pošti.
///
/// Zakaj obstaja: stopnjevanje iz migracije 090 uvrsti napako, ki je uporabnik pet minut ni
/// potrdil, v <c>ops.AlertDelivery</c> s kanalom <c>Email</c>. Kanal je bil v shemi dovoljen že
/// od migracije 025, poslati pa ga ni znal nihče — dispatcher je poznal samo spletni kavelj in
/// je vsako e-pošto označil kot <c>Dead</c>.
///
/// Vsebina je namenoma navodilo in ne izpis napake: naslov pove, kaj se je zgodilo, telo pa,
/// kaj naj uporabnik naredi. Uporabnik, ki dobi surov HTTP izpis, ne ve, kaj se od njega
/// pričakuje, in bo naslednje sporočilo prezrl.
/// </summary>
public sealed class EmailAlertSender(EmailDeliveryOptions options)
{
  public async Task<AlertSendOutcome> SendAsync(AlertEnvelope alert, string recipient, CancellationToken cancellationToken = default)
  {
    if (!options.Enabled || string.IsNullOrWhiteSpace(options.Host) || string.IsNullOrWhiteSpace(options.From))
      return AlertSendOutcome.Disabled;

    // Naslov, ki ni naslov, se ne sme poskušati pošiljati petkrat zapored — to je trajna napaka.
    if (!IsPlausibleAddress(recipient)) return AlertSendOutcome.Dead;

    using var client = new SmtpClient(options.Host, options.Port)
    {
      EnableSsl = options.UseStartTls,
      DeliveryMethod = SmtpDeliveryMethod.Network,
      Timeout = 20_000
    };
    if (!string.IsNullOrWhiteSpace(options.Username))
      client.Credentials = new NetworkCredential(options.Username, options.Password ?? string.Empty);

    using var message = new MailMessage(options.From!, recipient)
    {
      Subject = $"PIM — {Trim(alert.Title, 150)}",
      Body = Body(alert),
      IsBodyHtml = false
    };

    try
    {
      await client.SendMailAsync(message, cancellationToken);
      return AlertSendOutcome.Delivered;
    }
    catch (SmtpFailedRecipientException)
    {
      // Strežnik pravi, da tega prejemnika ni. Ponavljanje ne bo pomagalo.
      return AlertSendOutcome.Dead;
    }
    catch (SmtpException exception)
    {
      // 5xx je trajna zavrnitev, vse ostalo (nedosegljiv strežnik, iztek časa) je začasno.
      return exception.StatusCode is SmtpStatusCode.MailboxNameNotAllowed
        or SmtpStatusCode.MailboxUnavailable or SmtpStatusCode.UserNotLocalWillForward
        ? AlertSendOutcome.Dead
        : AlertSendOutcome.Retry;
    }
    catch (Exception exception) when (exception is IOException or TaskCanceledException or InvalidOperationException)
    {
      return AlertSendOutcome.Retry;
    }
  }

  static string Body(AlertEnvelope alert) =>
    $"""
     {alert.Title}

     {alert.PayloadSummaryRedacted}

     ---
     To sporočilo je nastalo, ker napaka v odhodni poti v SAOP ni bila potrjena v dogovorjenem
     času. Odpri PIM → Izvozi → Obvestila, preberi navodilo in ga potrdi. Dokler obvestilo ni
     potrjeno, se bo opozorilo ponovilo.

     Opozorilo številka {alert.AlertId}.
     """;

  /// <summary>Groba preverba oblike; namen ni potrditi naslova, ampak ločiti očitno napako od začasne.</summary>
  static bool IsPlausibleAddress(string? value)
  {
    if (string.IsNullOrWhiteSpace(value)) return false;
    try { _ = new MailAddress(value); return true; }
    catch (FormatException) { return false; }
  }

  static string Trim(string value, int length) => value.Length <= length ? value : value[..length] + "…";

  /// <summary>Nastavitve iz okolja. Poverilnice nikoli ne gredo v repozitorij.</summary>
  public static EmailDeliveryOptions FromEnvironment() => new(
    Enabled: string.Equals(Environment.GetEnvironmentVariable("PIM_ALERT_EMAIL_ENABLED"), "true", StringComparison.OrdinalIgnoreCase),
    Host: Environment.GetEnvironmentVariable("PIM_SMTP_HOST"),
    Port: int.TryParse(Environment.GetEnvironmentVariable("PIM_SMTP_PORT"), out var port) ? port : 25,
    UseStartTls: string.Equals(Environment.GetEnvironmentVariable("PIM_SMTP_STARTTLS"), "true", StringComparison.OrdinalIgnoreCase),
    Username: Environment.GetEnvironmentVariable("PIM_SMTP_USERNAME"),
    Password: Environment.GetEnvironmentVariable("PIM_SMTP_PASSWORD"),
    From: Environment.GetEnvironmentVariable("PIM_SMTP_FROM"));
}
