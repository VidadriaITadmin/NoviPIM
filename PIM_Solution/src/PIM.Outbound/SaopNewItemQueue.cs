namespace PIM.Outbound;

/// <summary>Od kod je prišla vrednost, ki gre v odhodno vrsto za nov artikel.</summary>
public enum SaopQueuedChangeSource
{
  /// <summary>Urednik jo je vpisal (ali potrdil) v obrazcu.</summary>
  Input,
  /// <summary>Prepisana iz kanoničnega stanja artikla v PIM (npr. EAN iz dobaviteljevega XML).</summary>
  Canonical,
}

/// <param name="FieldKey">Ključ polja v obliki <c>Entiteta.Stolpec</c>, kot ga pozna <c>out.SaopXmlField</c>.</param>
public sealed record SaopQueuedChange(string FieldKey, string Value, SaopQueuedChangeSource Source);

/// <summary>
/// Kaj gre v odhodno vrsto za artikel, ki ga SAOP še ne pozna — nov artikel, ki ga je ustvaril PIM
/// (kandidat iz dobaviteljevega XML, migracije 219/240/241).
///
/// Zakaj svoja pravila poleg <see cref="SaopItemPlanner"/>: načrt pove, KAJ bi šlo v dokument in ali
/// je popoln. Vrsta pa mora vedeti, KATERA sporočila naj nastanejo, da bo dokument ob prevzemu
/// (<c>out.ClaimItemDocument</c>) sploh obstajal — brez vsaj enega sporočila artikla v vrsti ni.
/// Za spremembo obstoječega artikla gre v vrsto SAMO vpisano (vsako poslano polje SAOP prepiše);
/// za nov artikel pa SAOP nima česa prepisati, zato gre v vrsto vse, kar PIM o artiklu ve in sme
/// pisati: vpisano ima prednost, prazno vpisano pomeni »vzemi kanonično«, ne »izprazni«.
///
/// Tako vrsta (/outbound, prekrivka na kartici) pokaže cel dokument, ki bo šel ven, in ne samo
/// polj, ki jih je urednik ravnokar tipkal — in kanonična vrednost, ki bi se do pošiljanja
/// spremenila, ne bi tiho zamenjala tistega, kar je urednik videl in potrdil.
///
/// Čista logika brez baze, da jo test (F8) preveri brez spletnega projekta.
/// </summary>
public static class SaopNewItemQueue
{
  /// <param name="writableFieldKeys">Ključi polj, ki jih PIM sme pisati (<c>intranet.GetWritableSaopFields</c>);
  /// ključ dokumenta (<c>Product.ItemID</c>) ni med njimi in ga ta metoda nikoli ne vrne.</param>
  /// <param name="canonical">Trenutne kanonične vrednosti artikla po ključu polja (<c>out.GetSaopItemWriteState</c>).</param>
  /// <param name="inputs">Kar je urednik vpisal; prazno pomeni »vzemi kanonično«.</param>
  public static IReadOnlyList<SaopQueuedChange> Changes(
    IEnumerable<string> writableFieldKeys,
    IReadOnlyDictionary<string, string?> canonical,
    IReadOnlyDictionary<string, string?> inputs)
  {
    ArgumentNullException.ThrowIfNull(writableFieldKeys);
    ArgumentNullException.ThrowIfNull(canonical);
    ArgumentNullException.ThrowIfNull(inputs);

    var result = new List<SaopQueuedChange>();
    var seen = new HashSet<string>(StringComparer.Ordinal);
    foreach (var key in writableFieldKeys)
    {
      if (string.IsNullOrWhiteSpace(key) || !seen.Add(key)) continue;
      if (string.Equals(key, "Product.ItemID", StringComparison.OrdinalIgnoreCase)) continue;

      if (inputs.TryGetValue(key, out var typed) && !string.IsNullOrWhiteSpace(typed))
        result.Add(new(key, typed.Trim(), SaopQueuedChangeSource.Input));
      else if (canonical.TryGetValue(key, out var stored) && !string.IsNullOrWhiteSpace(stored))
        result.Add(new(key, stored.Trim(), SaopQueuedChangeSource.Canonical));
    }

    return result;
  }

  /// <summary>Isti izbor kot <see cref="Changes"/>, v obliki, ki jo pričakuje <see cref="SaopItemPlanner"/>.</summary>
  public static IReadOnlyDictionary<string, string?> AsPlannerChanges(IReadOnlyList<SaopQueuedChange> changes)
  {
    ArgumentNullException.ThrowIfNull(changes);
    var result = new Dictionary<string, string?>(StringComparer.Ordinal);
    foreach (var change in changes) result[change.FieldKey] = change.Value;
    return result;
  }

  /// <summary>
  /// Polja, ki so pri vsakem artiklu drugačna (nazivi, EAN, teže, mere, pakiranje) — pri paketnem
  /// vnosu jih ni mogoče vpisati enkrat za vse; ostala (šifranti ERP: enota, skupina, oddelek,
  /// dobavitelj …) so pri artiklih iste dobave praviloma enaka in se vpišejo enkrat.
  /// </summary>
  public static bool IsPerItemField(string fieldKey)
  {
    ArgumentNullException.ThrowIfNull(fieldKey);
    if (fieldKey.StartsWith("ProductText.", StringComparison.OrdinalIgnoreCase)) return true;
    if (string.Equals(fieldKey, "Product.EAN", StringComparison.OrdinalIgnoreCase)) return true;
    return fieldKey.StartsWith("ProductCommercial.", StringComparison.OrdinalIgnoreCase)
      && !string.Equals(fieldKey, "ProductCommercial.CountryOfOrigin", StringComparison.OrdinalIgnoreCase)
      && !string.Equals(fieldKey, "ProductCommercial.DimensionUnit", StringComparison.OrdinalIgnoreCase)
      && !string.Equals(fieldKey, "ProductCommercial.CustomsTariff", StringComparison.OrdinalIgnoreCase);
  }
}
