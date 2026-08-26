namespace PIM.Intranet.Components.Shared;

/// <param name="Label">Vidno besedilo.</param>
/// <param name="Href">Base-relativna pot; null pomeni trenutno stran.</param>
public sealed record PimCrumb(string Label, string? Href = null);
