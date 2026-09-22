namespace PIM.Intranet.Services;

/// <summary>
/// Nedokončane spremembe razmika (v minutah) za tabelo urejanja postopkov/urnikov — vsaka vrstica
/// ima svoj vnos, ki velja, dokler uporabnik ne pritisne "Shrani razmik" ali stran znova ne naloži
/// podatkov (<see cref="Clear"/>). Isto obnašanje je bilo doslej ročno podvojeno v System.razor
/// (Postopki) in SystemSchedules.razor (Urniki obdelav).
/// </summary>
public sealed class MinuteEditState
{
  readonly Dictionary<string, int> edited = [];

  /// Vrednost v polju: kar je uporabnik vpisal, sicer trenutni razmik vrstice.
  public int Value(string key, int currentMinutes) =>
    edited.TryGetValue(key, out var value) ? value : currentMinutes;

  /// Ali se vpisana vrednost razlikuje od trenutnega razmika — gumb "Shrani" je omogočen samo takrat.
  public bool Changed(string key, int currentMinutes) =>
    edited.TryGetValue(key, out var value) && value != currentMinutes;

  public void Set(string key, string? input)
  {
    if (int.TryParse(input, out var minutes) && minutes is >= 1 and <= 1440) edited[key] = minutes;
  }

  public void Clear() => edited.Clear();
}
