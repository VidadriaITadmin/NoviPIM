namespace PIM.Outbound;

/// <param name="ExistsInSaop">
/// Ali artikel v SAOP že obstaja. V <c>canon.Product</c> artikel lahko ustvari samo konektor
/// z <c>CanCreateProducts = 1</c>, kar je danes izključno SAOP; dobaviteljevi feedi obstoječe
/// artikle samo dopolnijo. Prisotnost v kanoničnem modelu je zato dokaz obstoja v SAOP.
/// </param>
/// <param name="PreviousRejection">
/// Vrsta zavrnitve prejšnjega poskusa, če je bil. SAOP je najzanesljivejši vir resnice o tem,
/// kaj ima in česa nima — njegova zavrnitev prevlada nad tem, kar sklepamo iz baze.
/// </param>
public sealed record SaopIntentInput(bool ExistsInSaop, SaopErrorKind? PreviousRejection = null);

public sealed record SaopIntentDecision(SaopIntent Intent, string Reason);

/// <summary>
/// Odloči, ali gre artikel v SAOP kot nov (ADD) ali kot sprememba (PATCH).
///
/// Zakaj je to sploh svoj razred: v stari vrsti je <b>118 od 130</b> napak natanko ta ena
/// odločitev — »Zapis za artikel že obstaja« (poslan ADD namesto PATCH) in »šifra artikla ne
/// obstaja« (poslan PATCH namesto ADD). V starem sistemu jo je izbral človek ob vnosu v vrsto.
/// Tu je izpeljana in zapisana z razlogom, tako da se da pri pregledu videti, zakaj je bila
/// izbrana prav ta metoda.
/// </summary>
public static class SaopIntentResolver
{
  public static SaopIntentDecision Resolve(SaopIntentInput input)
  {
    ArgumentNullException.ThrowIfNull(input);

    // Zavrnitev SAOP prevlada: če pravi, da artikel ima, ga ima, tudi če v naši bazi ni.
    if (input.PreviousRejection == SaopErrorKind.ItemAlreadyExists)
      return new(SaopIntent.Update, "SAOP je pri prejšnjem poskusu odgovoril, da artikel že obstaja.");

    if (input.PreviousRejection == SaopErrorKind.ItemNotFound)
      return new(SaopIntent.Add, "SAOP je pri prejšnjem poskusu odgovoril, da artikla ne pozna.");

    return input.ExistsInSaop
      ? new(SaopIntent.Update, "Artikel je v kanoničnem modelu, kamor pride samo iz zajema SAOP.")
      : new(SaopIntent.Add, "Artikla v kanoničnem modelu ni, zato ga SAOP še ne pozna.");
  }

  /// <summary>Končna točka za izbrano metodo; pot je relativna na naslov integracije.</summary>
  public static string Endpoint(SaopIntent intent) => intent == SaopIntent.Add
    ? "api/Item/AddItemsGeneralData"
    : "api/Item/UpdateItemsGeneralData";

  /// <summary>HTTP metoda za izbrano metodo. ADD je POST, sprememba je PATCH.</summary>
  public static string HttpOperation(SaopIntent intent) => intent == SaopIntent.Add ? "POST" : "PATCH";
}
