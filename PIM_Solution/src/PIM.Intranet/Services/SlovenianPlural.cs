namespace PIM.Intranet.Services;

/// <summary>
/// Slovenska sklanjatev samostalnika ob števniku (ednina, dvojina, množina, rodilnik množine).
/// Odloča ostanek pri deljenju s 100: 1, 101 → ednina; 2, 102 → dvojina; 3-4, 103-104 → množina;
/// ostalo (0, 5-100, 111 …) → rodilnik množine. Primer: 1 uporabnik, 2 uporabnika, 3 uporabniki, 5 uporabnikov.
/// </summary>
public static class SlovenianPlural
{
  /// <summary>Izbere pravo obliko besede za dano število.</summary>
  public static string Choose(long count, string one, string two, string few, string many)
  {
    var rest = Math.Abs(count) % 100;
    return rest switch
    {
      1 => one,
      2 => two,
      3 or 4 => few,
      _ => many
    };
  }

  /// <summary>»3 uporabniki« — število in beseda v pravi obliki.</summary>
  public static string Format(long count, string one, string two, string few, string many) =>
    $"{count} {Choose(count, one, two, few, many)}";

  /// <summary>uporabnik / uporabnika / uporabniki / uporabnikov</summary>
  public static string Users(long count) => Choose(count, "uporabnik", "uporabnika", "uporabniki", "uporabnikov");

  /// <summary>dovoljenje / dovoljenji / dovoljenja / dovoljenj</summary>
  public static string Permissions(long count) => Choose(count, "dovoljenje", "dovoljenji", "dovoljenja", "dovoljenj");

  /// <summary>sprememba / spremembi / spremembe / sprememb</summary>
  public static string Changes(long count) => Choose(count, "sprememba", "spremembi", "spremembe", "sprememb");
}
