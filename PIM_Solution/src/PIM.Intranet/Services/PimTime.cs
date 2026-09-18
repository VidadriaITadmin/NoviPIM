namespace PIM.Intranet.Services;

/// <summary>
/// Naša ura. Baza hrani UTC, uporabnik pa dela po slovenskem času — pretvorba je tu in nikjer
/// drugje.
///
/// Zakaj to ni <c>DateTime.ToLocalTime()</c>: ta vrne časovni pas <b>strežnika</b>. Na razvojnem
/// računalniku je to slučajno pravi odgovor, na IIS strežniku, ki je nastavljen na UTC, pa je
/// ista vrstica videti dve uri prej — in ker se to zgodi šele ob objavi, tega ni videti na
/// razvoju. Zato je pas izbran izrecno in ne podedovan.
///
/// Poletni in zimski čas ureja <see cref="TimeZoneInfo"/> sam; zato je pas naveden po imenu in
/// ne kot fiksni odmik +1 ali +2.
/// </summary>
public static class PimTime
{
  /// <summary>Windows ime pasu; Linux/ICU ime <c>Europe/Ljubljana</c> je sprejeto kot rezerva.</summary>
  public const string DefaultZoneId = "Central European Standard Time";

  static TimeZoneInfo zone = Resolve(DefaultZoneId);

  /// <summary>Pas, po katerem intranet kaže čas. Nastavi ga <c>Program.cs</c> ob zagonu.</summary>
  public static TimeZoneInfo Zone => zone;

  /// <summary>
  /// Prevzame <c>Pim:TimeZone</c> iz konfiguracije. Neznano ime pasu ne sme podreti aplikacije:
  /// napačno nastavljen pas je nadloga, nedosegljiv intranet pa izpad.
  /// </summary>
  public static void Configure(IConfiguration configuration)
    => zone = Resolve(configuration["Pim:TimeZone"] ?? DefaultZoneId);

  static TimeZoneInfo Resolve(string id)
  {
    foreach (var candidate in new[] { id, DefaultZoneId, "Europe/Ljubljana" })
    {
      try { return TimeZoneInfo.FindSystemTimeZoneById(candidate); }
      catch (TimeZoneNotFoundException) { }
      catch (InvalidTimeZoneException) { }
    }

    return TimeZoneInfo.Local;
  }

  /// <summary>UTC iz baze v našo uro. Vrednost brez oznake Kind je iz baze in je vedno UTC.</summary>
  public static DateTime Local(DateTime utc)
    => TimeZoneInfo.ConvertTimeFromUtc(DateTime.SpecifyKind(utc, DateTimeKind.Utc), zone);

  public static DateTime? Local(DateTime? utc) => utc is null ? null : Local(utc.Value);

  /// <summary>Datum in ura na minuto natančno: <c>8. 9. 2026 17:36</c>.</summary>
  public static string Format(DateTime? utc, string whenNull = "—")
    => utc is null ? whenNull : Local(utc.Value).ToString("d. M. yyyy HH:mm");

  /// <summary>Ura na sekundo natančno; za sled dejanj, kjer je vrstni red pomemben.</summary>
  public static string FormatExact(DateTime? utc, string whenNull = "—")
    => utc is null ? whenNull : Local(utc.Value).ToString("d. M. yyyy HH:mm:ss");

  /// <summary>Samo ura, kadar je datum že v naslovu vrstice ali skupine.</summary>
  public static string FormatTime(DateTime? utc, string whenNull = "—")
    => utc is null ? whenNull : Local(utc.Value).ToString("HH:mm:ss");

  /// <summary>Ura in koliko je od nje minilo — obe informaciji sta potrebni hkrati.</summary>
  public static string FormatWithAge(DateTime? utc, string whenNull = "—")
    => utc is null ? whenNull : $"{Format(utc)} ({PimFormat.Ago(utc)})";

  /// <summary>Oznaka pasu z veljavnim odmikom, npr. <c>CEST, UTC+2</c>.</summary>
  public static string ZoneLabel
  {
    get
    {
      var now = DateTime.UtcNow;
      var offset = zone.GetUtcOffset(now);
      var summer = zone.IsDaylightSavingTime(TimeZoneInfo.ConvertTimeFromUtc(now, zone));
      return $"{(summer ? "CEST" : "CET")}, UTC{(offset < TimeSpan.Zero ? "-" : "+")}{Math.Abs(offset.Hours)}";
    }
  }

  /// <summary>Trajanje v obliki, ki jo človek prebere brez računanja: 850 ms, 12 s, 4 min 20 s.</summary>
  public static string Duration(int? milliseconds, string whenNull = "—")
  {
    if (milliseconds is null or < 0) return whenNull;
    var value = milliseconds.Value;
    if (value < 1000) return $"{value} ms";
    if (value < 60_000) return $"{value / 1000.0:0.0} s";

    var total = TimeSpan.FromMilliseconds(value);
    if (total.TotalHours < 1) return $"{(int)total.TotalMinutes} min {total.Seconds} s";
    if (total.TotalDays < 1) return $"{(int)total.TotalHours} h {total.Minutes} min";
    return $"{(int)total.TotalDays} d {total.Hours} h";
  }

  public static string Duration(long? milliseconds, string whenNull = "—")
    => milliseconds is null ? whenNull
     : milliseconds > int.MaxValue ? Duration(int.MaxValue, whenNull)
     : Duration((int)milliseconds.Value, whenNull);
}

/// <summary>
/// Razširitvi, ki obstajata zaradi enega samega razloga: da je zamenjava na obstoječih straneh
/// zamenjava imena in ne prepis izraza. Vrstica
/// <c>@(rows.MaxBy(r =&gt; r.CreatedUtc)?.CreatedUtc.ToLocalTime().ToString("g"))</c>
/// se v <c>PimTime.Local(...)</c> ne da prepisati brez razstavljanja izraza — in prav tam se
/// pri šestdesetih mestih naredi tiha napaka.
/// </summary>
public static class PimTimeExtensions
{
  /// <summary>Naša ura namesto ure strežnika. Glej <see cref="PimTime"/>.</summary>
  public static DateTime ToPimLocal(this DateTime utc) => PimTime.Local(utc);

  public static DateTime? ToPimLocal(this DateTime? utc) => PimTime.Local(utc);
}
