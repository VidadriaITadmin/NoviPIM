namespace PIM.Operations;

/// <summary>
/// Normalizacija naslova stolpca — edino mesto, kjer je zapisano, kdaj sta dva naslova isti
/// stolpec.
///
/// Zakaj svoj razred: pravilo je bilo doslej zasebno v <see cref="WorkbookChangeMapper"/>,
/// zdaj pa ga potrebujeta se bralnik zvezka (da najde naslovno vrstico pod vrstico skupin) in
/// pogodba delovnega lista izdelkov. Tri kopije istega pravila bi se slej ko prej razsle in
/// uvoz bi prepoznal stolpec, ki ga izvoz ne pise vec.
/// </summary>
public static class WorkbookHeader
{
  /// <summary>Male crke brez presledkov in sumnikov; »Sifra artikla« in »sifraArtikla« sta isto.</summary>
  public static string Normalize(string? value) =>
    new string((value ?? string.Empty).Trim().ToLowerInvariant().Where(character => !char.IsWhiteSpace(character)).ToArray())
      .Replace("š", "s").Replace("č", "c").Replace("ž", "z").Replace("ć", "c").Replace("đ", "d");

  /// <summary>Ali sta naslova ista celica pogodbe.</summary>
  public static bool Same(string? left, string? right) =>
    Normalize(left).Length > 0 && Normalize(left) == Normalize(right);
}
