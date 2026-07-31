using PIM.B2b;

var calculator = new DiscountCalculator();
var catalog = new Dictionary<string, decimal> { ["S1"] = 3m, ["S2"] = 5m, ["S3"] = 10m, ["S4"] = 15m };
foreach (var pair in catalog)
  Equal(pair.Value, calculator.ResolvePackagingPercent(pair.Key, catalog), pair.Key);

Throws<DiscountRuleException>(() => calculator.ResolvePackagingPercent("S5", catalog), "Neznana S stopnja mora biti vidna napaka.");
Throws<DiscountRuleException>(() => calculator.ResolvePackagingPercent("S1", new Dictionary<string, decimal> { ["S1"] = 0 }), "Neveljavna S stopnja mora biti vidna napaka.");

var eligible = new PackagingDiscountInput(5, 5, true, "S2", PromotionGateState.Regular);
Equal(5m, calculator.EvaluatePackagingDiscount(eligible, catalog), "Na PAK2");
Equal(0m, calculator.EvaluatePackagingDiscount(eligible with { Quantity = 4 }, catalog), "Pod PAK2");
Equal(5m, calculator.EvaluatePackagingDiscount(eligible with { Quantity = 500 }, catalog), "Nad PAK2 brez zgornje meje");
Equal(0m, calculator.EvaluatePackagingDiscount(eligible with { CustomerEnabled = false }, catalog), "Brez customer zastavice");
Equal(0m, calculator.EvaluatePackagingDiscount(eligible with { PromotionState = PromotionGateState.Promotional }, catalog), "Akcija izključi S");
Throws<DiscountRuleException>(() => calculator.EvaluatePackagingDiscount(eligible with { PromotionState = PromotionGateState.Unknown }, catalog), "Unknown gate ne sme potiho pomeniti Regular.");

var day = new DateOnly(2026, 7, 31);
var imported = new GroupDiscountCandidate(DiscountSource.Imported, 11, null, null);
var type = new GroupDiscountCandidate(DiscountSource.CustomerType, 22, day.AddDays(-1), day.AddDays(1));
var customer = new GroupDiscountCandidate(DiscountSource.Customer, 33, day, day);
Equal(33m, calculator.ResolveGroupDiscount(new[] { imported, type, customer }, day), "Customer override ima prednost.");
Equal(22m, calculator.ResolveGroupDiscount(new[] { imported, type, customer with { ValidTo = day.AddDays(-1) } }, day), "Tip override ima drugo prednost.");
Equal(11m, calculator.ResolveGroupDiscount(new[] { imported, type with { ValidFrom = day.AddDays(1) } }, day), "Imported fallback.");

var tiers = new[] { new ValueDiscountTier(800, 1), new ValueDiscountTier(1500, 2), new ValueDiscountTier(3000, 3) };
Equal(0m, calculator.ResolveValueDiscount(799.99m, true, tiers), "Pod prvim pragom");
Equal(1m, calculator.ResolveValueDiscount(800m, true, tiers), "Prvi prag je inkluziven");
Equal(2m, calculator.ResolveValueDiscount(1500m, true, tiers), "Drugi prag je inkluziven");
Equal(3m, calculator.ResolveValueDiscount(3000m, true, tiers), "Tretji prag je inkluziven");
Equal(0m, calculator.ResolveValueDiscount(5000m, false, tiers), "Customer flag izključi vrednostni rabat");

var cascade = calculator.Cascade(100m, 10m, 5m, 2m, 2m);
Equal(82.1142m, cascade.FinalAmount, "Kaskada uporablja zmanjšano osnovo.");
Equal(new[] { "GROUP", "PACKAGING", "VALUE", "B2B_WEB" }, cascade.Components.Select(x => x.Code).ToArray(), "Vrstni red komponent");
Equal(2m, DiscountPolicy.B2bWebPercent, "Globalni B2B spletni metapodatek");
Console.WriteLine("F7 behavior: deterministični popustni motor PASS.");

static void Equal<T>(T expected, T actual, string message)
{
  if (expected is Array expectedArray && actual is Array actualArray)
  {
    if (!expectedArray.Cast<object>().SequenceEqual(actualArray.Cast<object>())) throw new InvalidOperationException(message);
    return;
  }
  if (!EqualityComparer<T>.Default.Equals(expected, actual)) throw new InvalidOperationException($"{message}: pričakovano {expected}, dejansko {actual}.");
}
static void Throws<T>(Action action, string message) where T : Exception
{
  try { action(); } catch (T) { return; }
  throw new InvalidOperationException(message);
}
