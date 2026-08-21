namespace PIM.Outbound;

/// <summary>Kako je bila šifra artikla v SAOP povezana z zapisom v PIM.</summary>
public enum SaopItemMatchMethod { Response, RequestedIdentifier, Ean, Manual, Unresolved }

/// <param name="ResponseItemId">Šifra, ki jo je vrnil SAOP v odgovoru, če jo je.</param>
/// <param name="RequestedIdentifier">Šifra, ki jo je PIM zahteval ob pošiljanju.</param>
/// <param name="Ean">EAN artikla, če ga ima.</param>
/// <param name="EanMatchCount">Koliko artiklov podjetja ima ta EAN.</param>
/// <param name="EanMatchItemId">Šifra edinega ujemajočega artikla, kadar je ujemanje enolično.</param>
public sealed record SaopItemAssignmentInput(
  string? ResponseItemId,
  string? RequestedIdentifier,
  string? Ean,
  int EanMatchCount,
  string? EanMatchItemId);

public sealed record SaopItemAssignmentResult(SaopItemMatchMethod Method, string? AssignedSaopItemId, string Detail);

/// <summary>
/// Vrzel O19: SAOP ob ustvarjanju artikla dodeli svojo šifro, povezava nazaj pa se je iskala
/// izključno po EAN. To odpove, kadar EAN manjka, ni globalno enoličen ali ga SAOP normalizira —
/// artikel ostane nepovezan ali, kar je huje, se poveže na napačnega.
///
/// Vrstni red je zato: odgovor SAOP → zahtevana šifra → EAN → človek. Dvoumen EAN namenoma
/// <em>ni</em> ujemanje: napačna povezava je slabša od nobene, ker je ni videti.
///
/// Ista pravila v enaki obliki izvaja <c>out.ResolveSaopItemAssignment</c>; ta razred je
/// njihova izvedba brez baze, da se dajo preveriti brez nje.
/// </summary>
public static class SaopItemAssignmentResolver
{
  public static SaopItemAssignmentResult Resolve(SaopItemAssignmentInput input)
  {
    ArgumentNullException.ThrowIfNull(input);

    var response = Trim(input.ResponseItemId);
    if (response is not null)
      return new(SaopItemMatchMethod.Response, response, "Šifra iz odgovora SAOP.");

    var requested = Trim(input.RequestedIdentifier);
    if (requested is not null)
      return new(SaopItemMatchMethod.RequestedIdentifier, requested,
        "Odgovor ni vseboval šifre; uporabljena je zahtevana šifra.");

    var ean = Trim(input.Ean);
    if (ean is not null)
    {
      if (input.EanMatchCount == 1 && Trim(input.EanMatchItemId) is { } matched)
        return new(SaopItemMatchMethod.Ean, matched, "Enolično ujemanje po EAN.");
      if (input.EanMatchCount > 1)
        return new(SaopItemMatchMethod.Unresolved, null,
          $"EAN ustreza {input.EanMatchCount} artiklom; samodejna uskladitev bi lahko povezala napačnega.");
      return new(SaopItemMatchMethod.Unresolved, null, "Za ta EAN ni artikla.");
    }

    return new(SaopItemMatchMethod.Unresolved, null, "Ni odgovora, ni zahtevane šifre, ni EAN.");
  }

  static string? Trim(string? value) => string.IsNullOrWhiteSpace(value) ? null : value.Trim();
}
