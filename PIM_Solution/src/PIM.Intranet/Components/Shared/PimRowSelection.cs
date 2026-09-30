namespace PIM.Intranet.Components.Shared;

/// <summary>
/// Izbira vrstic na seznamu (PIM_DOBRE_PRAKSE §9.3): tri stanja — nič, posamezne vrstice (lahko čez
/// več strani) in »vse, ki ustrezajo filtru«. Pri zadnjem izbira NI seznam ključev, ampak filter:
/// stran ob dejanju prebere nabor znova s strežnika, zato 90.000 izdelkov nikoli ne živi v pomnilniku
/// kot kljukice. Skupaj z <c>PimBulkBar</c> je to skupni gradnik za množična dejanja (CLAUDE.md §3).
/// </summary>
/// <typeparam name="T">Kar stran o izbrani vrstici potrebuje za dejanje (npr. podjetje + šifra).</typeparam>
public sealed class PimRowSelection<T>
{
  readonly Dictionary<string, T> items = new(StringComparer.OrdinalIgnoreCase);

  /// <summary>Izbrano je vse, kar ustreza filtru <see cref="FilterSignature"/>.</summary>
  public bool AllMatching { get; private set; }

  /// <summary>Koliko vrstic ustreza filtru (za »vse po filtru«); nastavi ga stran ob vsakem branju.</summary>
  public int MatchingTotal { get; private set; }

  /// <summary>Filter, na katerega se nanaša »vse po filtru«; ob spremembi filtra se ta način sprosti.</summary>
  public string? FilterSignature { get; private set; }

  /// <summary>Število izbranih: pri »vse po filtru« je to število zadetkov filtra.</summary>
  public int Count => AllMatching ? MatchingTotal : items.Count;

  public bool IsEmpty => Count == 0;

  /// <summary>Posamezno izbrane vrstice (pri »vse po filtru« prazno — nabor se prebere s strežnika).</summary>
  public IReadOnlyCollection<T> Items => items.Values;

  public bool Contains(string key) => AllMatching || items.ContainsKey(key);

  /// <summary>Stran pove, kateri filter velja in koliko vrstic mu ustreza. Drug filter = druga izbira
  /// »vse po filtru«: ta se sprosti, posamezne kljukice ostanejo (izbira živi čez filtre).</summary>
  public void UpdateFilter(string signature, long matchingTotal)
  {
    if (!string.Equals(signature, FilterSignature, StringComparison.Ordinal)) AllMatching = false;
    FilterSignature = signature;
    MatchingTotal = (int)Math.Clamp(matchingTotal, 0, int.MaxValue);
  }

  /// <summary>Kljukica na vrstici. Odkljukana vrstica pri »vse po filtru« ta način konča: ostanejo
  /// vrstice trenutne strani brez nje (<paramref name="pageRows"/>), ker izjeme od filtra ne hranimo.</summary>
  public void Toggle(string key, T item, bool selected, IEnumerable<KeyValuePair<string, T>>? pageRows = null)
  {
    if (AllMatching && !selected)
    {
      AllMatching = false;
      items.Clear();
      foreach (var row in pageRows ?? []) items[row.Key] = row.Value;
    }
    if (selected) items[key] = item;
    else items.Remove(key);
  }

  /// <summary>Ali je vsaka vrstica te strani izbrana (stanje kljukice »Označi vse na strani«).</summary>
  public bool AllSelected(IEnumerable<string> pageKeys)
  {
    if (AllMatching) return true;
    var any = false;
    foreach (var key in pageKeys)
    {
      any = true;
      if (!items.ContainsKey(key)) return false;
    }
    return any;
  }

  /// <summary>»Označi vse na strani« / odznači stran.</summary>
  public void SetPage(IEnumerable<KeyValuePair<string, T>> pageRows, bool selected)
  {
    if (AllMatching && !selected) { Clear(); return; }
    foreach (var row in pageRows)
      if (selected) items[row.Key] = row.Value; else items.Remove(row.Key);
  }

  /// <summary>»Vse, ki ustrezajo filtru (N)«.</summary>
  public void SelectAllMatching()
  {
    items.Clear();
    AllMatching = MatchingTotal > 0;
  }

  public void Clear()
  {
    items.Clear();
    AllMatching = false;
  }
}
