namespace PIM.Intranet.Components.Shared;

/// <summary>Hitri izbor na seznamu (PimSegments): ime, povezava z izbranim filtrom in število iz baze.</summary>
/// <param name="Label">Vidno ime, npr. »Za dopolniti«.</param>
/// <param name="Href">Base-relativna povezava, ki izbor nastavi v URL-ju (deljiva, nazaj deluje).</param>
/// <param name="Active">Ali je izbor trenutno izbran.</param>
/// <param name="Count">Število zadetkov; null pomeni, da se še bere (ali ni na voljo) — nikoli izmišljena ničla.</param>
/// <param name="Hint">Razlaga v title.</param>
/// <param name="Tone">null, "warn" ali "bad": število, ki pomeni delo, dobi opozorilno barvo.</param>
public sealed record PimSegment(string Label, string Href, bool Active, long? Count = null, string? Hint = null, string? Tone = null);
