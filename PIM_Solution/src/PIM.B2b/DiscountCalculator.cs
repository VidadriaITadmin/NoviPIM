namespace PIM.B2b;

public enum PromotionGateState { Unknown, Regular, Promotional }
public enum DiscountSource { Imported = 1, CustomerType = 2, Customer = 3 }

public sealed record PackagingDiscountInput(decimal Quantity, decimal PackagingQuantity, bool CustomerEnabled, string DiscountCode, PromotionGateState PromotionState);
public sealed record GroupDiscountCandidate(DiscountSource Source, decimal Percent, DateOnly? ValidFrom, DateOnly? ValidTo);
public sealed record ValueDiscountTier(decimal ThresholdGrossExVat, decimal Percent);
public sealed record DiscountComponent(string Code, decimal Percent, decimal BaseAmount, decimal ReducedAmount);
public sealed record DiscountCascade(IReadOnlyList<DiscountComponent> Components, decimal FinalAmount);

public static class DiscountPolicy
{
  public const decimal B2bWebPercent = 2m;
}

public sealed class DiscountRuleException(string message) : InvalidOperationException(message);

public sealed class DiscountCalculator
{
  public decimal ResolvePackagingPercent(string code, IReadOnlyDictionary<string, decimal> catalog)
  {
    if (!catalog.TryGetValue(code, out var percent) || percent <= 0m || !IsValidPercent(percent))
      throw new DiscountRuleException($"Stopnja popusta {code} manjka ali ni veljavna.");
    return percent;
  }

  public decimal EvaluatePackagingDiscount(PackagingDiscountInput input, IReadOnlyDictionary<string, decimal> catalog)
  {
    if (input.PackagingQuantity <= 0) throw new DiscountRuleException("PAK2 mora biti večji od nič.");
    if (input.PromotionState == PromotionGateState.Unknown)
      throw new DiscountRuleException("Vir akcijske cene ni potrjen; S-popusta ni dovoljeno uporabiti.");
    if (!input.CustomerEnabled || input.Quantity < input.PackagingQuantity || input.PromotionState == PromotionGateState.Promotional) return 0m;
    return ResolvePackagingPercent(input.DiscountCode, catalog);
  }

  public decimal ResolveGroupDiscount(IEnumerable<GroupDiscountCandidate> candidates, DateOnly effectiveDate)
  {
    var selected = candidates
      .Where(candidate => (!candidate.ValidFrom.HasValue || candidate.ValidFrom <= effectiveDate)
        && (!candidate.ValidTo.HasValue || candidate.ValidTo >= effectiveDate))
      .OrderByDescending(candidate => candidate.Source)
      .FirstOrDefault() ?? throw new DiscountRuleException("Veljavna skupinska stopnja manjka.");
    if (!IsValidPercent(selected.Percent)) throw new DiscountRuleException("Skupinska stopnja ni veljavna.");
    return selected.Percent;
  }

  public decimal ResolveValueDiscount(decimal grossExVat, bool customerEnabled, IEnumerable<ValueDiscountTier> tiers)
  {
    if (!customerEnabled) return 0m;
    var configured = tiers.OrderBy(tier => tier.ThresholdGrossExVat).ToArray();
    if (configured.Any(tier => tier.ThresholdGrossExVat < 0 || !IsValidPercent(tier.Percent)))
      throw new DiscountRuleException("Vrednostna stopnja ni veljavna.");
    return configured.Where(tier => grossExVat >= tier.ThresholdGrossExVat).Select(tier => tier.Percent).LastOrDefault();
  }

  public DiscountCascade Cascade(decimal baseAmount, decimal groupPercent, decimal packagingPercent, decimal valuePercent, decimal webPercent)
  {
    if (baseAmount < 0 || new[] { groupPercent, packagingPercent, valuePercent, webPercent }.Any(percent => !IsValidPercent(percent)))
      throw new DiscountRuleException("Kaskada vsebuje neveljavno vrednost.");
    var amount = baseAmount;
    var components = new List<DiscountComponent>();
    foreach (var component in new[] { ("GROUP", groupPercent), ("PACKAGING", packagingPercent), ("VALUE", valuePercent), ("B2B_WEB", webPercent) })
    {
      var reduced = amount * (100m - component.Item2) / 100m;
      components.Add(new(component.Item1, component.Item2, amount, reduced));
      amount = reduced;
    }
    return new(components, amount);
  }

  private static bool IsValidPercent(decimal percent) => percent >= 0m && percent <= 100m;
}
