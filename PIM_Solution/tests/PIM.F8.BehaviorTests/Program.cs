using PIM.Outbound;

var pimFields = new[]
{
  new OwnershipRule("Product", "ERP_DESCRIPTION", Ownership.Pim),
  new OwnershipRule("Product", "PRICE", Ownership.Pim, ConstraintKind.PriceList, "RETAIL"),
  new OwnershipRule("Product", "PLANNING_EXCLUDED", Ownership.Pim, ConstraintKind.ExactValue, "0")
};
var policy = new OwnershipPolicy(pimFields);
var builder = new OutboundPayloadBuilder(policy);

var description = builder.Build(new OutboundChange("SAOP_PRODUCT", "PATCH", "Product", "A-1", "ERP_DESCRIPTION", "Nova luč"));
Equal("{\"entityKey\":\"A-1\",\"field\":\"ERP_DESCRIPTION\",\"value\":\"Nova luč\"}", description.CanonicalJson, "Kanonični JSON");
Equal("5261ac16121e86059172435b4a01d59e4250a61a8e3bf4aebb69c8ff3f5974de", description.PayloadHash, "SHA-256");
Equal(description.PayloadHash, description.DedupKey, "Dedup temelji na payloadu");

foreach (var forbidden in new[] { "ItemID", "VAT", "ACCOUNTING_GROUP", "INVENTORY_ACCOUNT", "MEDIA", "CATEGORY", "WEB_TITLE", "STOCK", "DELIVERY" })
  Throws<OwnershipViolationException>(() => builder.Build(new("SAOP_PRODUCT", "PATCH", "Product", "A-1", forbidden, "x")), forbidden);

builder.Build(new("SAOP_PRICE", "PATCH", "Product", "A-1", "PRICE", "12.30", "RETAIL"));
Throws<OwnershipViolationException>(() => builder.Build(new("SAOP_PRICE", "PATCH", "Product", "A-1", "PRICE", "12.30", "ACCOUNTING")), "Računovodski cenik");
builder.Build(new("SAOP_PRODUCT", "PATCH", "Product", "A-1", "PLANNING_EXCLUDED", "0"));
Throws<OwnershipViolationException>(() => builder.Build(new("SAOP_PRODUCT", "PATCH", "Product", "A-1", "PLANNING_EXCLUDED", "1")), "Planning samo 0");

Equal(QueueGate.PendingApproval, QueueGateResolver.Resolve(new IntegrationGate(true, ApprovalMode.ManualApproval)), "Ročni gate");
Equal(QueueGate.Pending, QueueGateResolver.Resolve(new IntegrationGate(true, ApprovalMode.Automatic)), "Samodejni gate");
Equal(QueueGate.Disabled, QueueGateResolver.Resolve(new IntegrationGate(false, ApprovalMode.Automatic)), "Izklopljen gate");
Equal(false, EchoAntiLoop.ShouldEnqueue(description.PayloadHash, description.PayloadHash), "Potrjeni hash se ne enqueue-a");
Equal(true, EchoAntiLoop.ShouldEnqueue(description.PayloadHash, new string('0', 64)), "Kasnejša sprememba se enqueue-a");
Console.WriteLine("F8 behavior: ownership, payload, gate in anti-loop PASS.");

static void Equal<T>(T expected, T actual, string message)
{
  if (!EqualityComparer<T>.Default.Equals(expected, actual)) throw new InvalidOperationException($"{message}: pričakovano {expected}, dejansko {actual}.");
}
static void Throws<T>(Action action, string message) where T : Exception
{
  try { action(); } catch (T) { return; }
  throw new InvalidOperationException(message);
}
