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

  static DateTime AsUtc(DateTime value) => value.Kind switch
  {
    DateTimeKind.Utc => value,
    DateTimeKind.Local => value.ToUniversalTime(),
    _ => DateTime.SpecifyKind(value, DateTimeKind.Utc),
  };
}
