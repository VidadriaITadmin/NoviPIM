namespace PIM.Intranet.Components.Shared;

/// <param name="Key">Kljuc aktivnega zavihka; ujema se z <c>Active</c> na <c>PimTabs</c>.</param>
/// <param name="Label">Vidno ime zavihka.</param>
/// <param name="Href">Base-relativna pot brez zacetne posevnice (zaradi IIS /PIM).</param>
/// <param name="Description">Kratek opis; null ohrani ozek zavihek.</param>
/// <param name="Count">Stevilo za zavihkom, ze oblikovano; vedno iz baze.</param>
public sealed record PimTab(string Key, string Label, string Href, string? Description = null, string? Count = null);
