using System.Data;
using System.Net.Sockets;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using PIM.Operations;

namespace PIM.SourceFetchWorker;

/*
  Preverjanje, ali se slika na naslovu res odpre (naloga #9, migracija 312, posel MEDIA_URL_CHECK).

  Kaj šteje kot napaka (NAPAKA — števec v val.MediaUrlCheck se poveča; pokvarjena je šele po dveh v razmiku 24 h):
    - naslov ni spletna povezava (http/https);
    - strežnik odgovori 404, 410 ali drug trajni 4xx (razen 401, 403, 408, 429);
    - strežnik namesto slike vrne spletno stran ali besedilo (text/*, JSON, XML);
    - strežnik s tem imenom ne obstaja (DNS) — vendar samo, če je v istem teku odgovoril vsaj en strežnik
      (sicer je težava pri nas, ne pri naslovu).

  Kaj NE šteje (NI_ODZIVA — števec ostane): 429, 5xx, 401/403, 408, časovna meja, prekinjena povezava.
  Strežniki dobaviteljev občasno ne odgovorijo ali omejijo zahteve; izdelki zaradi tega ne smejo pasti s spleta.

  Meja hitrosti: en zahtevek naenkrat na strežnik in premor med zahtevki istega strežnika; različni strežniki
  tečejo vzporedno. Telo slike se ne prenaša (samo glava odgovora).
*/

public static class MediaCheckOutcomes
{
  public const string Ok = "OK";
  public const string Failed = "NAPAKA";
  public const string NoResponse = "NI_ODZIVA";
}

public sealed record MediaCheckTarget(string UrlHash, string Url);

/// <param name="Outcome">OK, NAPAKA ali NI_ODZIVA (<see cref="MediaCheckOutcomes"/>).</param>
/// <param name="ErrorCode">Stabilna koda za filter na strani (NI_NAJDENA, NI_SLIKA ...); null pri OK.</param>
/// <param name="ErrorText">Napaka po domače, kot jo vidi komercialist.</param>
public sealed record MediaCheckResult(
  string UrlHash, string Outcome, int? HttpStatus, string? ContentType, string? ErrorCode, string? ErrorText, string? Host);

public sealed record MediaCheckOptions(TimeSpan PauseBetweenRequests, TimeSpan RequestTimeout, int MaxParallelHosts)
{
  public static MediaCheckOptions Default { get; } = new(TimeSpan.FromMilliseconds(500), TimeSpan.FromSeconds(20), 6);
}

public static class MediaUrlRules
{
  /// <summary>
  /// Naslov za zahtevek: obrezan, »//« in »www.« dobita https (isto kot MediaUrlPolicy v intranetu).
  /// Presledki in šumniki v poti se kodirajo (Uri). Vrne null, če naslov ni spletna povezava.
  /// </summary>
  public static Uri? ToRequestUri(string? raw)
  {
    var value = (raw ?? "").Trim();
    if (value.Length == 0) return null;
    if (value.StartsWith("//", StringComparison.Ordinal)) value = "https:" + value;
    else if (value.StartsWith("www.", StringComparison.OrdinalIgnoreCase)) value = "https://" + value;
    if (!Uri.TryCreate(value, UriKind.Absolute, out var parsed)) return null;
    return parsed.Scheme == Uri.UriSchemeHttp || parsed.Scheme == Uri.UriSchemeHttps ? parsed : null;
  }

  /// <summary>Izid po HTTP odgovoru (status po preusmeritvah in vrsta vsebine).</summary>
  public static (string Outcome, string? Code, string? Text) Classify(int status, string? contentType)
  {
    var type = (contentType ?? "").Split(';')[0].Trim().ToLowerInvariant();
    if (status is >= 200 and < 300)
    {
      if (type.StartsWith("text/", StringComparison.Ordinal) || type is "application/json" or "application/xml" or "application/xhtml+xml")
        return (MediaCheckOutcomes.Failed, "NI_SLIKA", $"strežnik namesto slike vrne {type} (npr. spletno stran z napako)");
      // image/*, octet-stream ali brez vrste: slika se odpre; neznana vrsta ni razlog za izpust s spleta.
      return (MediaCheckOutcomes.Ok, null, null);
    }
    return status switch
    {
      404 => (MediaCheckOutcomes.Failed, "NI_NAJDENA", "strežnik vrne 404 – slika ne obstaja"),
      410 => (MediaCheckOutcomes.Failed, "ODSTRANJENA", "strežnik vrne 410 – slika je odstranjena"),
      401 or 403 => (MediaCheckOutcomes.NoResponse, "DOSTOP_ZAVRNJEN", $"strežnik vrne {status} – dostop zavrnjen (ne šteje kot pokvarjena)"),
      408 => (MediaCheckOutcomes.NoResponse, "CAS_POTEKEL", "strežnik vrne 408 – ni odgovoril pravočasno"),
      429 => (MediaCheckOutcomes.NoResponse, "PREVEC_ZAHTEVKOV", "strežnik vrne 429 – omejuje zahtevke, preverimo kasneje"),
      >= 500 => (MediaCheckOutcomes.NoResponse, "NAPAKA_STREZNIKA", $"strežnik vrne {status} – začasna napaka strežnika"),
      >= 400 => (MediaCheckOutcomes.Failed, "ZAVRNJENA", $"strežnik vrne {status} – slike ni mogoče odpreti"),
      _ => (MediaCheckOutcomes.NoResponse, "PREUSMERITEV", $"strežnik vrne {status} – preusmeritev brez cilja"),
    };
  }
}

public sealed class MediaUrlChecker(HttpClient http, MediaCheckOptions options, Func<TimeSpan, CancellationToken, Task>? delay = null)
{
  readonly Func<TimeSpan, CancellationToken, Task> wait = delay ?? Task.Delay;

  /// <summary>Preveri vse naslove; strežniki vzporedno, znotraj strežnika zaporedno s premorom.</summary>
  public async Task<IReadOnlyList<MediaCheckResult>> CheckAsync(IReadOnlyList<MediaCheckTarget> targets, CancellationToken cancellationToken = default)
  {
    var results = new List<MediaCheckResult>();
    var gate = new object();
    var anyHttpResponse = false;

    var invalid = targets.Where(target => MediaUrlRules.ToRequestUri(target.Url) is null)
      .Select(target => new MediaCheckResult(target.UrlHash, MediaCheckOutcomes.Failed, null, null, "NEVELJAVEN_NASLOV",
        "naslov ni spletna povezava (http/https)", null)).ToList();
    results.AddRange(invalid);

    var byHost = targets.Select(target => (Target: target, Uri: MediaUrlRules.ToRequestUri(target.Url)))
      .Where(item => item.Uri is not null)
      .GroupBy(item => item.Uri!.Host, StringComparer.OrdinalIgnoreCase)
      .ToList();

    using var parallel = new SemaphoreSlim(Math.Max(1, options.MaxParallelHosts));
    var tasks = byHost.Select(async group =>
    {
      await parallel.WaitAsync(cancellationToken);
      try
      {
        var first = true;
        foreach (var (target, uri) in group)
        {
          if (cancellationToken.IsCancellationRequested) break;
          if (!first) await wait(options.PauseBetweenRequests, cancellationToken);
          first = false;
          var (result, responded) = await CheckOneAsync(target, uri!, cancellationToken);
          lock (gate)
          {
            results.Add(result);
            anyHttpResponse |= responded;
          }
        }
      }
      catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { }
      finally { parallel.Release(); }
    }).ToList();
    await Task.WhenAll(tasks);

    // Brez enega samega odgovora je težava v našem omrežju (DNS, povezava), ne pri naslovih.
    if (!anyHttpResponse)
      for (var index = 0; index < results.Count; index++)
        if (results[index].ErrorCode == "STREZNIK_NE_OBSTAJA")
          results[index] = results[index] with
          {
            Outcome = MediaCheckOutcomes.NoResponse,
            ErrorText = "imena strežnika ni bilo mogoče razrešiti; noben strežnik ni odgovoril, zato ne šteje",
          };

    return results;
  }

  async Task<(MediaCheckResult Result, bool Responded)> CheckOneAsync(MediaCheckTarget target, Uri uri, CancellationToken cancellationToken)
  {
    var host = uri.Host.ToLowerInvariant();
    using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
    timeout.CancelAfter(options.RequestTimeout);
    try
    {
      using var request = new HttpRequestMessage(HttpMethod.Get, uri);
      using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token);
      var status = (int)response.StatusCode;
      var contentType = response.Content.Headers.ContentType?.ToString();
      var (outcome, code, text) = MediaUrlRules.Classify(status, contentType);
      return (new(target.UrlHash, outcome, status, Trim(contentType, 200), code, text, host), true);
    }
    catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
    {
      return (new(target.UrlHash, MediaCheckOutcomes.NoResponse, null, null, "CAS_POTEKEL",
        $"strežnik ni odgovoril v {options.RequestTimeout.TotalSeconds:0} s", host), false);
    }
    catch (HttpRequestException exception) when (exception.InnerException is SocketException { SocketErrorCode: SocketError.HostNotFound })
    {
      return (new(target.UrlHash, MediaCheckOutcomes.Failed, null, null, "STREZNIK_NE_OBSTAJA",
        $"strežnik {host} ne obstaja (ime ni razrešljivo)", host), false);
    }
    catch (HttpRequestException)
    {
      return (new(target.UrlHash, MediaCheckOutcomes.NoResponse, null, null, "NI_POVEZAVE",
        "povezave s strežnikom ni bilo mogoče vzpostaviti", host), false);
    }
  }

  static string? Trim(string? value, int length) => value is null || value.Length <= length ? value : value[..length];
}

/// <summary>
/// En tek posla MEDIA_URL_CHECK: paket naslovov iz val.GetMediaUrlsToCheck, preverjanje po delih po 200 in
/// zapis izidov (val.RecordMediaUrlChecks) po vsakem delu — prekinjen tek ne izgubi opravljenega dela.
/// Faze v ops.JobPhaseRun: PRENOS (preverjanje) in ZAPIS (izidi) z viri MEDIA_URL_CHECK.
/// </summary>
public static class MediaCheckRun
{
  public const string Pipeline = "MEDIA_URL_CHECK";
  const int ChunkSize = 200;

  public static async Task<int> RunAsync(string connectionString, SqlConnection connection, int limit, TimeSpan pause, TimeSpan maxDuration)
  {
    await using (var find = new SqlCommand(
      "SELECT TOP(1) OrganizationId FROM ops.ScheduleProfile WHERE Pipeline = @Pipeline AND IsEnabled = 1 ORDER BY OrganizationId;", connection))
    {
      find.Parameters.AddWithValue("@Pipeline", Pipeline);
      if (await find.ExecuteScalarAsync() is not int organizationId)
      {
        Console.Error.WriteLine("Za MEDIA_URL_CHECK ni omogocenega razporeda v ops.ScheduleProfile (migracija 312); nic ni bilo preverjeno.");
        return 1;
      }
      return await RunForAsync(connectionString, connection, organizationId, limit, pause, maxDuration);
    }
  }

  static async Task<int> RunForAsync(string connectionString, SqlConnection connection, int organizationId, int limit, TimeSpan pause, TimeSpan maxDuration)
  {
    var workerId = $"{Environment.MachineName}:{Environment.ProcessId}";
    await using var run = await OperationsRun.BeginAsync(connectionString, organizationId, Pipeline, workerId);
    var phases = PhaseLog.FromEnvironment(connectionString, workerId);
    using var stop = new CancellationTokenSource(maxDuration);

    var targets = new List<MediaCheckTarget>();
    await using (var read = new SqlCommand("val.GetMediaUrlsToCheck", connection) { CommandType = CommandType.StoredProcedure, CommandTimeout = 300 })
    {
      read.Parameters.Add("@Limit", SqlDbType.Int).Value = limit;
      await using var reader = await read.ExecuteReaderAsync();
      while (await reader.ReadAsync()) targets.Add(new(reader.GetString(0), reader.GetString(1)));
    }

    await using var phase = await phases.BeginAsync(PhaseCodes.Fetch, Pipeline, organizationId, Pipeline, run.RunId,
      $"{targets.Count:N0} naslovov na vrsti (najvec {limit:N0}, premor {pause.TotalMilliseconds:0} ms na streznik)");
    if (targets.Count == 0)
    {
      await phase.SkippedAsync("Noben naslov ni na vrsti za preverjanje.");
      await run.CompleteAsync(true);
      Console.WriteLine("Preverjanje slik: noben naslov ni na vrsti.");
      return 0;
    }

    using var http = new HttpClient(new SocketsHttpHandler { AllowAutoRedirect = true, MaxAutomaticRedirections = 5 }) { Timeout = Timeout.InfiniteTimeSpan };
    http.DefaultRequestHeaders.Add("User-Agent", "PIM.MediaCheck/1.0 (preverjanje slik izdelkov)");
    http.DefaultRequestHeaders.Add("Accept", "image/*,*/*;q=0.5");
    var checker = new MediaUrlChecker(http, MediaCheckOptions.Default with { PauseBetweenRequests = pause });

    long ok = 0, failed = 0, noResponse = 0, newlyBroken = 0, recovered = 0, written = 0;
    try
    {
      foreach (var chunk in targets.Chunk(ChunkSize))
      {
        if (stop.IsCancellationRequested) break;
        var results = await checker.CheckAsync(chunk, stop.Token);
        if (results.Count == 0) continue;
        ok += results.Count(r => r.Outcome == MediaCheckOutcomes.Ok);
        failed += results.Count(r => r.Outcome == MediaCheckOutcomes.Failed);
        noResponse += results.Count(r => r.Outcome == MediaCheckOutcomes.NoResponse);

        var (updated, broken, back) = await RecordAsync(connection, results);
        written += updated; newlyBroken += broken; recovered += back;
        await run.HeartbeatAsync();
        Console.WriteLine($"Preverjeno {ok + failed + noResponse:N0}/{targets.Count:N0}: odpre se {ok:N0}, napaka {failed:N0}, brez odziva {noResponse:N0}.");
      }
    }
    catch (Exception exception) when (exception is SqlException or InvalidOperationException)
    {
      await phase.FailedAsync("Izidov ni bilo mogoce zapisati: " + exception.GetType().Name, itemsIn: targets.Count);
      await run.CompleteAsync(false, "Zapis izidov preverjanja slik ni uspel.");
      Console.Error.WriteLine("NAPAKA pri zapisu izidov: " + exception.Message);
      return 1;
    }

    var stopped = stop.IsCancellationRequested ? $" Tek je dosegel casovno mejo ({maxDuration.TotalMinutes:0} min); ostali naslovi pridejo na vrsto naslednjic." : "";
    var summary = $"Odpre se {ok:N0}, napaka {failed:N0}, brez odziva {noResponse:N0}; na novo pokvarjenih {newlyBroken:N0}, popravljenih {recovered:N0}.{stopped}";
    await phase.SucceededAsync(itemsIn: targets.Count, itemsOut: written, itemsRejected: failed, hasNewData: written > 0, message: summary);
    await run.CompleteAsync(true);
    Console.WriteLine("Preverjanje slik koncano. " + summary);
    return 0;
  }

  static async Task<(long Updated, long NewlyBroken, long Recovered)> RecordAsync(SqlConnection connection, IReadOnlyList<MediaCheckResult> results)
  {
    var json = JsonSerializer.Serialize(results.Select(r => new Dictionary<string, object?>
    {
      ["h"] = r.UrlHash, ["o"] = r.Outcome, ["s"] = r.HttpStatus, ["t"] = r.ContentType, ["e"] = r.ErrorCode, ["x"] = r.ErrorText, ["host"] = r.Host,
    }));
    await using var command = new SqlCommand("val.RecordMediaUrlChecks", connection) { CommandType = CommandType.StoredProcedure, CommandTimeout = 300 };
    command.Parameters.Add("@ResultsJson", SqlDbType.NVarChar, -1).Value = json;
    await using var reader = await command.ExecuteReaderAsync();
    if (!await reader.ReadAsync()) return (0, 0, 0);
    static long Number(SqlDataReader r, int i) => r.IsDBNull(i) ? 0 : Convert.ToInt64(r.GetValue(i));
    return (Number(reader, 0), Number(reader, 1), Number(reader, 2));
  }
}
