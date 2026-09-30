using System.Globalization;

namespace PIM.Intranet.Services;

/*
  Napačni naslovi slik (naloga #9, migracija 312): stanja, kode napak in filter strani /mediji/napacni-naslovi.
  Brez baze, da jih test (F10.MediaUxTests) preveri brez povezave.
*/

/// <summary>Stanja naslova, kot jih vrne procedura; vidno ime, ton čipa in posledica za splet.</summary>
public static class MediaCheckStates
{
  public const string Broken = "POKVARJENA";
  public const string Suspect = "SUMLJIVA";
  public const string NoResponse = "NI_ODZIVA";

  public sealed record State(string Code, string Label, string Tone, string Effect);

  public static IReadOnlyList<State> All { get; } =
  [
    new(Broken, "Pokvarjena", "bad", "Dvakrat v razmiku 24 ur se ni odprla: ne gre v katalog.csv; izdelek brez druge delujoče slike ni pripravljen za splet."),
    new(Suspect, "Čaka potrditev", "warn", "Enkrat se ni odprla. Posel jo preveri znova čez 24 ur; do takrat na splet ne vpliva."),
    new(NoResponse, "Strežnik ni odgovoril", "neutral", "Strežnik je bil nedosegljiv ali je omejil zahtevke. Ne šteje kot napaka; preverimo znova."),
  ];

  public static State Find(string? code) => All.FirstOrDefault(state => state.Code == code) ?? All[^1];
}

/// <summary>Kode napak iz preverjalnika (MediaUrlChecker) po domače, za filter.</summary>
public static class MediaCheckErrors
{
  public static string Label(string? code) => code switch
  {
    "NI_NAJDENA" => "Slika ne obstaja (404)",
    "ODSTRANJENA" => "Slika odstranjena (410)",
    "NI_SLIKA" => "Namesto slike spletna stran",
    "ZAVRNJENA" => "Strežnik zavrne zahtevo (4xx)",
    "NEVELJAVEN_NASLOV" => "Naslov ni spletna povezava",
    "STREZNIK_NE_OBSTAJA" => "Strežnik ne obstaja",
    "DOSTOP_ZAVRNJEN" => "Dostop zavrnjen (401/403)",
    "PREVEC_ZAHTEVKOV" => "Strežnik omejuje zahtevke (429)",
    "NAPAKA_STREZNIKA" => "Začasna napaka strežnika (5xx)",
    "CAS_POTEKEL" => "Strežnik ni odgovoril pravočasno",
    "NI_POVEZAVE" => "Ni povezave s strežnikom",
    "PREUSMERITEV" => "Preusmeritev brez cilja",
    null or "" => "Brez kode",
    var other => other,
  };
}

public sealed record MediaCheckFilter(
  int? OrganizationId = null, string? Search = null, string? State = null, string? Host = null, string? ErrorCode = null,
  string? Sort = null, bool Reverse = false, int Skip = 0, int Take = 50);

/// <summary>Ista imena parametrov v naslovu strani in v izvozu: povezavo se da deliti, izvoz = zaslon.</summary>
public static class MediaCheckQuery
{
  public const int PageSize = 50;
  static readonly string[] States = [MediaCheckStates.Broken, MediaCheckStates.Suspect, MediaCheckStates.NoResponse];
  static readonly string[] Sorts = ["preverjeno", "sifra", "streznik", "napaka"];

  /// <summary>Čas preverjanja je privzeto najnovejši najprej, šifra/strežnik/napaka naraščajoče; »obrnjeno« zamenja smer.</summary>
  public static bool IsDescending(MediaCheckFilter filter) => (filter.Sort is null or "preverjeno") != filter.Reverse;

  public static MediaCheckFilter FromQuery(Func<string, string?> read) => new(
    OrganizationId: int.TryParse(read("podjetje"), NumberStyles.Integer, CultureInfo.InvariantCulture, out var organization) && organization > 0 ? organization : null,
    Search: string.IsNullOrWhiteSpace(read("isci")) ? null : read("isci")!.Trim(),
    State: States.Contains(read("stanje")) ? read("stanje") : null,
    Host: string.IsNullOrWhiteSpace(read("streznik")) ? null : read("streznik")!.Trim(),
    ErrorCode: string.IsNullOrWhiteSpace(read("napaka")) ? null : read("napaka")!.Trim(),
    Sort: Sorts.Contains(read("razvrsti")) ? read("razvrsti") : null,
    Reverse: read("smer") == "obrnjeno",
    Skip: int.TryParse(read("stran"), NumberStyles.Integer, CultureInfo.InvariantCulture, out var page) && page > 1 ? (page - 1) * PageSize : 0);

  public static string ToQueryString(MediaCheckFilter filter, int page = 1)
  {
    var parts = new List<string>();
    void Add(string name, string? value) { if (!string.IsNullOrWhiteSpace(value)) parts.Add($"{name}={Uri.EscapeDataString(value)}"); }
    Add("podjetje", filter.OrganizationId?.ToString(CultureInfo.InvariantCulture));
    Add("isci", filter.Search);
    Add("stanje", filter.State);
    Add("streznik", filter.Host);
    Add("napaka", filter.ErrorCode);
    Add("razvrsti", filter.Sort);
    if (filter.Reverse) Add("smer", "obrnjeno");
    if (page > 1) Add("stran", page.ToString(CultureInfo.InvariantCulture));
    return string.Join("&", parts);
  }
}
