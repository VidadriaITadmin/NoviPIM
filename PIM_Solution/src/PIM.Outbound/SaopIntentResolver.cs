namespace PIM.Outbound;

/// <param name="ExistsInSaop">
/// Ali artikel v SAOP že obstaja. Izpeljano je iz <c>canon.Product.ErpExistence</c>
/// (migracija 169): <c>CONFIRMED_IN_ERP</c> pomeni, da ga SAOP pozna, <c>NOT_YET_IN_ERP</c>, da
/// je artikel zaenkrat samo v PIM. Do 169 je bila merilo prisotnost vrstice v
/// <c>canon.Product</c>, kar je držalo le, dokler je artikle smel ustvarjati izključno SAOP
/// (<c>CanCreateProducts = 1</c>); z viri, ki artikle ustvarijo mimo ERP, bi tako merilo za
/// artikel, ki ga v SAOP ni, izbralo PATCH.
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
      ? new(SaopIntent.Update, "Artikel je v SAOP potrjen (ErpExistence = CONFIRMED_IN_ERP).")
      : new(SaopIntent.Add, "Artikla SAOP še ne pozna (ni ga v canon.Product ali je NOT_YET_IN_ERP).");
  }

  /// <summary>Končna točka za izbrano metodo; pot je relativna na naslov integracije.</summary>
  public static string Endpoint(SaopIntent intent) => intent == SaopIntent.Add
    ? "api/Item/AddItemsGeneralData"
    : "api/Item/UpdateItemsGeneralData";

  /// <summary>HTTP metoda za izbrano metodo. ADD je POST, sprememba je PATCH.</summary>
  public static string HttpOperation(SaopIntent intent) => intent == SaopIntent.Add ? "POST" : "PATCH";
}
