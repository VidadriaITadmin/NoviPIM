using System.Globalization;

namespace PIM.StockReplenishmentWorker;

public static class ReplenishmentQuantity
{
  // SQL ROUND uses halves away from zero. Accept both int and decimal SQL projections.
  public static int? Read(object? value) => value is null or DBNull ? null
    : checked((int)decimal.Round(Convert.ToDecimal(value, CultureInfo.InvariantCulture), 0, MidpointRounding.AwayFromZero));
}
