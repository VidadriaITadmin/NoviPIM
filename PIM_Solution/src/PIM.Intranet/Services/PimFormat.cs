namespace PIM.Intranet.Services;

public static class PimFormat
{
  public static string Ago(DateTime? valueUtc, DateTime? nowUtc = null)
  {
    if (valueUtc is null) return "—";
    var value = AsUtc(valueUtc.Value);
    var now = AsUtc(nowUtc ?? DateTime.UtcNow);
    var age = now - value;
    if (age < TimeSpan.Zero) return "pravkar";
    if (age.TotalMinutes < 1) return "pred manj kot minuto";
    if (age.TotalHours < 1) return $"pred {(int)age.TotalMinutes:N0} min";
    if (age.TotalDays < 1) return $"pred {(int)age.TotalHours:N0} h";
    if (age.TotalDays < 31) return $"pred {(int)age.TotalDays:N0} d";
    if (age.TotalDays < 365) return $"pred {(int)(age.TotalDays / 30):N0} mes";
    return $"pred {(int)(age.TotalDays / 365):N0} let";
  }

  /// <summary>
  /// Število s slovensko sklanjatvijo: <c>Count(2, "napaka", "napaki", "napake", "napak")</c> → »2 napaki«.
  /// Oblike so ednina, dvojina, množina (3, 4) in rodilnik množine (0, 5 …); šteje zadnja dva mesta (101 = ednina).
  /// </summary>
  public static string Count(long value, string one, string two, string few, string many)
  {
    var form = (Math.Abs(value) % 100) switch { 1 => one, 2 => two, 3 or 4 => few, _ => many };
    return $"{value:N0} {form}";
  }

  static DateTime AsUtc(DateTime value) => value.Kind switch
  {
    DateTimeKind.Utc => value,
    DateTimeKind.Local => value.ToUniversalTime(),
    _ => DateTime.SpecifyKind(value, DateTimeKind.Utc),
  };
}
