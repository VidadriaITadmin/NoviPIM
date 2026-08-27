using System.Net;
using System.Text.Json;

namespace PIM.SourceFetchWorker;

/// <summary>
/// Prevzem ene datoteke od dobavitelja. Loceno od <c>Program.cs</c>, da se da preizkusiti brez
/// baze in brez zunanjega vira — enak vzorec kot pri zalogi.
///
/// Prevzemnik samo prinese datoteko in nic vec. Branja v <c>stock.*</c> ali <c>raw.Inbox</c> ne
/// dela: to je delo zalogovnega oziroma XML workerja. Loceno zato, ker ima prevzem svoje napake
/// (omrezje, poverilnice, dobaviteljev izpad), ki niso napake preslikave in se ne smejo mesati.
/// </summary>
public sealed class SourceFetcher(HttpClient http, string targetRoot)
{
  public async Task<FetchOutcome> FetchAsync(FetchLocation location, FetchCredential? credential, CancellationToken cancellationToken = default)
  {
    try
    {
      return location.Kind.ToUpperInvariant() switch
      {
        // Datoteko v mapo polozi clovek; prevzemnik nima kaj prinesti in to ni napaka.
        "MAPA" => new(location.SourceCode, location.Kind, false, 0, location.Location, "Lokalna mapa — prevzem ni potreben.", null),
        "HTTP" => await FetchHttpAsync(location, credential, cancellationToken),
        "FTP" => await FetchFtpAsync(location, credential, cancellationToken),
        _ => new(location.SourceCode, location.Kind, false, 0, null, null, $"Neznana vrsta prevzema: {location.Kind}."),
      };
    }
    catch (Exception exception)
    {
      // Sporocilo lahko nosi naslov s skrivnim GUID-om ali poverilnico, zato gre v izpis samo
      // vrsta napake, nikoli surovo besedilo izjeme.
      return new(location.SourceCode, location.Kind, false, 0, null, null, Redact(exception));
    }
  }

  async Task<FetchOutcome> FetchHttpAsync(FetchLocation location, FetchCredential? credential, CancellationToken cancellationToken)
  {
    var url = credential?.Url ?? location.Location;
    if (string.IsNullOrWhiteSpace(url))
      return new(location.SourceCode, location.Kind, false, 0, null,
        $"Naslov ni nastavljen — vpisi ga v appsettings.Local.json pod {location.CredentialKey}.", null);

    using var response = await http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
    if (!response.IsSuccessStatusCode)
      return new(location.SourceCode, location.Kind, false, 0, null, null, $"Dobavitelj je vrnil HTTP {(int)response.StatusCode}.");

    var target = TargetPath(location);
    var temporary = target + ".prenos";
    await using (var stream = await response.Content.ReadAsStreamAsync(cancellationToken))
    await using (var file = File.Create(temporary))
      await stream.CopyToAsync(file, cancellationToken);

    // Dobavitelj lahko odgovori s HTTP 200 in vsebino, ki ni podatek. Braytron ob preseganju
    // omejitve vrne <Hata> z besedilom "Maximum Sorgu Limitine Ulastiniz" in casom naslednjega
    // dovoljenega prenosa (izmerjeno 2026-08-27: interval 180 minut). Brez te preverbe bi
    // 193 bajtov napake povozilo 1,5 MB veljavne zaloge in naslednji worker bi prebral nic.
    var refusal = SupplierRefusal(temporary);
    if (refusal is not null)
    {
      File.Delete(temporary);

      // Zavrnjen prenos ob veljavni prejsnji datoteki NI napaka zagona: dobavitelj omejuje
      // pogostost, mi pa imamo podatek. Ce bi to steli za napako, bi bilo nacrtovano opravilo
      // videti pokvarjeno ob vsakem ciklu, ki pride prezgodaj. Brez prejsnje datoteke pa smo
      // dejansko brez podatka in to je napaka.
      var imamoPrejsnjo = File.Exists(target);
      return imamoPrejsnjo
        ? new(location.SourceCode, location.Kind, false, 0, target, refusal, null)
        : new(location.SourceCode, location.Kind, false, 0, null, null, refusal + " Prejsnje datoteke ni.");
    }

    File.Move(temporary, target, overwrite: true);
    return new(location.SourceCode, location.Kind, true, new FileInfo(target).Length, target, null, null);
  }

  /// <summary>Najmanjsa velikost, pod katero odgovor ni veljaven podatek, ampak sporocilo.</summary>
  const long RefusalSizeLimit = 4096;

  /// <summary>
  /// Zavrnitev dobavitelja, ki pride kot uspesen odgovor. Prebere se samo zacetek datoteke, ker
  /// so ta sporocila kratka, veljavni odgovori pa veliki; branje 19 MB zaradi te preverbe bi bilo
  /// nesorazmerno.
  /// </summary>
  static string? SupplierRefusal(string path)
  {
    var length = new FileInfo(path).Length;
    if (length > RefusalSizeLimit) return null;
    if (length == 0) return "Dobavitelj je vrnil prazno datoteko; prejsnja je ohranjena.";

    string head;
    using (var reader = new StreamReader(path))
    {
      var buffer = new char[512];
      head = new string(buffer, 0, reader.Read(buffer, 0, buffer.Length));
    }

    if (!head.Contains("<Hata>", StringComparison.OrdinalIgnoreCase)) return null;

    var next = Between(head, "<SonrakiXmlTarihi>", "</SonrakiXmlTarihi>");
    var window = Between(head, "<XmlAraligi>", "</XmlAraligi>");
    return next is null
      ? "Dobavitelj je prenos zavrnil (omejitev pogostosti); prejsnja datoteka je ohranjena."
      : $"Dobavitelj dovoli prenos na {window ?? "?"}; naslednji mozen {next}. Prejsnja datoteka je ohranjena.";
  }

  static string? Between(string value, string start, string end)
  {
    var from = value.IndexOf(start, StringComparison.OrdinalIgnoreCase);
    if (from < 0) return null;
    from += start.Length;
    var to = value.IndexOf(end, from, StringComparison.OrdinalIgnoreCase);
    return to < 0 ? null : value[from..to].Trim();
  }

  async Task<FetchOutcome> FetchFtpAsync(FetchLocation location, FetchCredential? credential, CancellationToken cancellationToken)
  {
    if (credential is null || string.IsNullOrWhiteSpace(credential.BaseUri) || string.IsNullOrWhiteSpace(credential.UserName))
      return new(location.SourceCode, location.Kind, false, 0, null,
        $"Poverilnice niso nastavljene — vpisi jih v appsettings.Local.json pod {location.CredentialKey}.", null);

    var directory = (credential.RemoteDirectory ?? "/").Trim();
    if (!directory.StartsWith('/')) directory = "/" + directory;
    if (!directory.EndsWith('/')) directory += "/";
    var fileName = credential.RemoteFileName ?? location.FileNamePattern
      ?? throw new InvalidOperationException("Ime oddaljene datoteke ni znano.");

    // SYSLIB0014 predlaga HttpClient, ta pa FTP ne podpira. FtpWebRequest je v .NET edina pot do
    // dobaviteljevega FTP; opozorilo je zato utisano tocno tu in nikjer drugje.
#pragma warning disable SYSLIB0014
    var request = (FtpWebRequest)WebRequest.Create(new Uri(credential.BaseUri.TrimEnd('/') + directory + fileName));
#pragma warning restore SYSLIB0014
    request.Method = WebRequestMethods.Ftp.DownloadFile;
    request.Credentials = new NetworkCredential(credential.UserName, credential.Password);
    request.UsePassive = credential.UsePassive;
    request.UseBinary = true;
    request.Timeout = (int)TimeSpan.FromMinutes(5).TotalMilliseconds;

    using var response = (FtpWebResponse)await request.GetResponseAsync();
    await using var stream = response.GetResponseStream();
    var target = TargetPath(location);
    await WriteAtomicAsync(stream, target, cancellationToken);
    return new(location.SourceCode, location.Kind, true, new FileInfo(target).Length, target, null, null);
  }

  string TargetPath(FetchLocation location)
  {
    var name = string.IsNullOrWhiteSpace(location.FileNamePattern) || location.FileNamePattern.Contains('*')
      ? location.SourceCode + ".dat"
      : location.FileNamePattern;
    var directory = Path.Combine(targetRoot, location.SourceCode);
    Directory.CreateDirectory(directory);
    return Path.Combine(directory, name);
  }

  /// <summary>
  /// Pisanje prek zacasne datoteke. Prekinjen prenos sicer pusti okrnjeno datoteko, ki jo
  /// naslednji worker prebere kot veljavno in tiho zapise premalo zaloge.
  /// </summary>
  static async Task WriteAtomicAsync(Stream source, string target, CancellationToken cancellationToken)
  {
    var temporary = target + ".prenos";
    await using (var file = File.Create(temporary))
      await source.CopyToAsync(file, cancellationToken);

    File.Move(temporary, target, overwrite: true);
  }

  static string Redact(Exception exception) => exception switch
  {
    HttpRequestException => "Prevzem prek HTTP ni uspel (omrezje ali naslov).",
    WebException web => $"Prevzem prek FTP ni uspel ({web.Status}).",
    IOException => "Datoteke ni bilo mogoce zapisati.",
    UnauthorizedAccessException => "Ni pravice za pisanje v ciljno mapo.",
    _ => $"Prevzem ni uspel ({exception.GetType().Name}).",
  };

  /// <summary>Odsek <c>Fetch</c> iz lokalnih nastavitev; prazen dokument, kadar ga ni.</summary>
  public static JsonElement ReadFetchSection(string? settingsPath)
  {
    if (settingsPath is null || !File.Exists(settingsPath)) return default;
    using var document = JsonDocument.Parse(File.ReadAllText(settingsPath));
    return document.RootElement.TryGetProperty("Fetch", out var fetch) ? fetch.Clone() : default;
  }
}
