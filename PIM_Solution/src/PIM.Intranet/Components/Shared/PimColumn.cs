namespace PIM.Intranet.Components.Shared;

/// <param name="Label">Naslov stolpca.</param>
/// <param name="Numeric">Ali se vrednosti poravnajo desno.</param>
public sealed record PimColumn(string Label, bool Numeric = false);
