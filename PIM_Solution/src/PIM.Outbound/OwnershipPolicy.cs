namespace PIM.Outbound;

public enum Ownership { Pim, Saop }
public enum ConstraintKind { None, PriceList, ExactValue }
public enum ApprovalMode { ManualApproval, Automatic }
public enum QueueGate { Disabled, PendingApproval, Pending }

public sealed record OwnershipRule(
  string EntityType,
  string FieldName,
  Ownership Owner,
  ConstraintKind ConstraintKind = ConstraintKind.None,
  string? ConstraintValue = null);

public sealed record IntegrationGate(bool IsEnabled, ApprovalMode ApprovalMode);

public sealed class OwnershipViolationException(string message) : InvalidOperationException(message);

public sealed class OwnershipPolicy(IEnumerable<OwnershipRule> rules)
{
  static readonly HashSet<string> AlwaysForbidden = new(StringComparer.OrdinalIgnoreCase)
  {
    "ItemID", "VAT", "ACCOUNTING_GROUP", "INVENTORY_ACCOUNT", "MEDIA",
    "CATEGORY", "WEB_TITLE", "STOCK", "DELIVERY"
  };
  readonly IReadOnlyList<OwnershipRule> rules = rules.ToArray();

  public void DemandPimOwnership(string entityType, string fieldName, string value, string? qualifier)
  {
    if (AlwaysForbidden.Contains(fieldName)) throw new OwnershipViolationException($"Polje {fieldName} ni v lasti PIM.");
    var matching = rules.Where(rule =>
      rule.Owner == Ownership.Pim &&
      string.Equals(rule.EntityType, entityType, StringComparison.OrdinalIgnoreCase) &&
      string.Equals(rule.FieldName, fieldName, StringComparison.OrdinalIgnoreCase));
    var accepted = matching.Any(rule => rule.ConstraintKind switch
    {
      ConstraintKind.None => true,
      ConstraintKind.PriceList => string.Equals(rule.ConstraintValue, qualifier, StringComparison.OrdinalIgnoreCase),
      ConstraintKind.ExactValue => string.Equals(rule.ConstraintValue, value, StringComparison.Ordinal),
      _ => false
    });
    if (!accepted) throw new OwnershipViolationException($"Sprememba {entityType}.{fieldName} ni dovoljena za podano vrednost oziroma kvalifikator.");
  }
}

public static class QueueGateResolver
{
  public static QueueGate Resolve(IntegrationGate gate) => !gate.IsEnabled
    ? QueueGate.Disabled
    : gate.ApprovalMode == ApprovalMode.Automatic ? QueueGate.Pending : QueueGate.PendingApproval;
}

public static class EchoAntiLoop
{
  public static bool ShouldEnqueue(string candidateHash, string? exactVerifiedHash) =>
    !string.Equals(candidateHash, exactVerifiedHash, StringComparison.OrdinalIgnoreCase);
}
