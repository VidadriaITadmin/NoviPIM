namespace PIM.Outbound;

/// <param name="Operation">HTTP metoda, ki jo bo uporabil pošiljatelj: POST ali PATCH.</param>
/// <param name="Path">Končna točka za izbrano metodo, relativna na naslov integracije.</param>
/// <param name="MissingMandatory">Obvezna polja brez vrednosti v obliki <c>Ovoj/Element</c>.</param>
/// <param name="ChangeCount">Koliko vpisanih polj bi šlo v vrsto.</param>
/// <param name="Error">Napaka gradnje (vrednost ni število, ni DA/NE …); dokumenta ni.</param>
public sealed record SaopItemPlan(
  string ItemId, SaopIntent Intent, string Reason, string Operation, string Path,
  string Xml, IReadOnlyList<string> MissingMandatory, int ElementCount, int ChangeCount, string? Error)
{
  public bool IsNew => Intent == SaopIntent.Add;

  /// <summary>Ali ima ta artikel kaj poslati in ali bi pošiljatelj dokument sploh spustil skozi.</summary>
  public bool CanSend => Error is null && MissingMandatory.Count == 0 && ChangeCount > 0;
}

/// <summary>
/// Kaj bi bilo za en artikel poslano v SAOP, s katero metodo in zakaj — brez baze in brez
/// pošiljanja.
///
/// Zakaj v domeni in ne v intranetu: to je čista logika. Dokler bi živela v spletnem projektu,
/// bi bil njen test odvisen od tega, ali se ta prevede — ista past, zaradi katere je
/// <c>WorkbookChangeMapper</c> v <c>PIM.Operations</c>.
///
/// Pravila so ista kot pri pošiljanju (<c>SaopDocumentRunner.Assemble</c>), ker jih ta razred
/// izvaja z istima gradnikoma: <see cref="SaopIntentResolver"/> izbere metodo,
/// <see cref="SaopDocumentBuilder"/> sestavi dokument. Predogled, ki bi imel svojo izvedbo,
/// bi prej ali slej pokazal drug dokument, kot bi bil poslan — in prav to bi bilo najhuje.
///
/// Dve pravili, ki ju je treba brati skupaj:
///   sprememba nosi <b>samo vpisano</b> — vsako poslano polje SAOP prepiše, zato bi vpisovanje
///     trenutnih vrednosti pomenilo tiho vračanje starih podatkov v ERP;
///   ustvarjanje mora nositi <b>vsa obvezna polja</b>, zato se manjkajoča dopolnijo iz
///     kanoničnega stanja in privzetkov, vpisano pa ima prednost pred obojim.
/// </summary>
public static class SaopItemPlanner
{
  /// <param name="canonical">Kanonične vrednosti artikla po ključu polja; upoštevajo se samo ob ustvarjanju.</param>
  /// <param name="defaults">Privzetki po ključu <c>Ovoj/Element</c>; upoštevajo se samo ob ustvarjanju.</param>
  /// <param name="changes">Vpisane vrednosti po ključu polja; prazne se izpustijo.</param>
  /// <param name="previousRejection">Zadnja zavrnitev SAOP, če je bila; prevlada nad stanjem baze.</param>
  public static SaopItemPlan Plan(
    SaopDocumentShape shape,
    IReadOnlyList<SaopXmlField> contract,
    string itemId,
    bool existsInSaop,
    IReadOnlyDictionary<string, string?> canonical,
    IReadOnlyDictionary<string, string> defaults,
    IReadOnlyDictionary<string, string?> changes,
    DateTime stampUtc,
    SaopErrorKind? previousRejection = null)
  {
    ArgumentNullException.ThrowIfNull(shape);
    ArgumentNullException.ThrowIfNull(contract);
    ArgumentNullException.ThrowIfNull(canonical);
    ArgumentNullException.ThrowIfNull(defaults);
    ArgumentNullException.ThrowIfNull(changes);

    // Prazna vrednost pomeni "tega polja se ne dotakni", ne "izprazni ga". Zvezek s stotimi
    // stolpci ima večino celic praznih in vsaka bi sicer v SAOP prepisala pravo vrednost s prazno.
    var effective = new Dictionary<string, string?>(StringComparer.Ordinal);
    foreach (var (fieldKey, value) in changes)
      if (!string.IsNullOrWhiteSpace(value)) effective[fieldKey] = value;

    var decision = SaopIntentResolver.Resolve(new(existsInSaop, previousRejection));
    var operation = shape.Operation(decision.Intent);
    var path = shape.Path(decision.Intent);

    var key = (itemId ?? string.Empty).Trim();
    if (key.Length == 0)
      return new(string.Empty, decision.Intent, decision.Reason, operation, path, string.Empty,
        ["Item/ItemID"], 0, effective.Count, "Brez šifre artikla dokumenta ni mogoče nasloviti.");

    var values = new Dictionary<string, string?>(StringComparer.Ordinal);
    if (decision.Intent == SaopIntent.Add)
      foreach (var (field, value) in canonical) values[field] = value;
    foreach (var (field, value) in effective) values[field] = value;

    try
    {
      var built = new SaopDocumentBuilder(shape, contract).Build(
        decision.Intent, key, values, defaults, stampUtc,
        // Enak pogoj kot pri pošiljanju: ob ustvarjanju šifro dodeli SAOP.
        suggestFirstFreeCode: decision.Intent == SaopIntent.Add && shape.SuggestCodeElement is not null);

      return new(key, decision.Intent, decision.Reason, operation, path, built.Xml,
        built.MissingMandatory, built.ElementCount, effective.Count, null);
    }
    catch (SaopXmlBuildException exception)
    {
      return new(key, decision.Intent, decision.Reason, operation, path, string.Empty,
        [], 0, effective.Count, exception.Message);
    }
  }
}
