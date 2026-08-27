namespace PIM.Intranet.Components.Pages.ProductCardParts;

public sealed record ProductChannelField(
  string Label, string FieldKey, string? Value, string Owner, string? Source,
  DateTime? FreshnessUtc, bool Pending, bool InReadModel = true);
