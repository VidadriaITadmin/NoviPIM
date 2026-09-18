namespace PIM.StockReplenishmentWorker;

/// <summary>Ena vrstica iz stock.GetBelowMidReplenishment — en artikel pod (ali na) MID pragu.</summary>
public sealed record ReplenishmentRow(
  string ItemID,
  string? ItemName,
  string? Supplier,
  string? SupplierName,
  string? Department,
  int CurrentStock,
  int? MaximumStock,
  int? MidStock,
  int? MinimumStock,
  int AvailableStock,
  int? IncomingPurchaseQty);
