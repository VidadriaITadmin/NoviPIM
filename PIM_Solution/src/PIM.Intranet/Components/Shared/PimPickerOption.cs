namespace PIM.Intranet.Components.Shared;

/// <param name="Key">Vrednost, ki se shrani (koda kategorije, koda atributa).</param>
/// <param name="Label">Ime, ki ga clovek isce.</param>
/// <param name="Detail">Celotna pot ali koda, prikazana pod imenom (npr. »Notranja svetila > Viseča svetila«).</param>
/// <param name="Level">Raven v drevesu; zamik v seznamu. 0 = brez zamika.</param>
/// <param name="Badge">Kratka oznaka na desni (npr. stevilo izdelkov).</param>
/// <param name="Group">Naslov skupine, pod katero se moznost izpise (npr. drevo).</param>
public sealed record PimPickerOption(string Key, string Label, string? Detail = null, int Level = 0, string? Badge = null, string? Group = null);
