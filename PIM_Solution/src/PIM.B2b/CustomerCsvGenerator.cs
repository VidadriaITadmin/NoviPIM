using System.Globalization;
using System.Text;

namespace PIM.B2b;

public sealed record ExportColumnDefinition(string ColumnCode, string OutputColumnName, string CanonicalFieldCode, int SortOrder, bool IsRequired, bool IsActive);
public sealed class ExportContractException(string message) : InvalidOperationException(message);

public sealed record CustomerValueTier(byte TierNumber, decimal ThresholdGrossExVat, decimal Percent);
public sealed record CustomerGroupDiscount(string ItemGroupCode, decimal Percent, string SourceCode);

public sealed record CustomerExportRow(
  string CustomerKey,
  string MagentoGroupKey,
  string? CustomerTypeCode,
  bool PackagingDiscountEnabled,
  bool ValueDiscountEnabled,
  bool B2bPlusEnabled,
  DateOnly? B2bPlusValidFrom,
  DateOnly? B2bPlusValidTo,
  string? PriceListCode,
  string? DiscountPriceListCode,
  string? PayerCode,
  string? PayerName,
  IReadOnlyList<CustomerValueTier> ValueTiers,
  IReadOnlyList<CustomerGroupDiscount> GroupDiscounts);

public sealed record ProductExportRow(
  string ItemId,
  string MagentoGroupKey,
  decimal Pak2,
  string? PackagingDiscountCode,
  decimal? PackagingDiscountPercent,
  PromotionGateState PromotionGateState);

public sealed record ShippingPolicyExportRow(
  string RuleCode,
  decimal? OrderThreshold,
  decimal? PackageLengthMeters,
  decimal ShippingNet,
  bool IsFree,
  int Priority);

public static class CustomerCsvGenerator
{
  public static Task WriteAsync(string path, IEnumerable<ExportColumnDefinition> columns, IEnumerable<CustomerExportRow> customers, CancellationToken cancellationToken = default)
    => ConfiguredCsvWriter.WriteAsync(path, columns, customers.Select(ToFields), cancellationToken);

  public static Task WriteAsync(string path, IEnumerable<ExportColumnDefinition> columns, IEnumerable<IReadOnlyDictionary<string, string?>> rows, CancellationToken cancellationToken = default)
    => ConfiguredCsvWriter.WriteAsync(path, columns, rows, cancellationToken);

  private static IReadOnlyDictionary<string, string?> ToFields(CustomerExportRow customer)
  {
    var group = RequiredKey(customer.MagentoGroupKey, "Magento customer group");
    var tiers = customer.ValueTiers.OrderBy(tier => tier.TierNumber).ToArray();
    if (tiers.Select(tier => tier.TierNumber).Distinct().Count() != tiers.Length || tiers.Any(tier => tier.ThresholdGrossExVat < 0 || tier.Percent is < 0 or > 100))
      throw new ExportContractException($"Stranka {customer.CustomerKey} ima neveljavne vrednostne stopnje.");

    return new Dictionary<string, string?>(StringComparer.Ordinal)
    {
      ["Customer.Key"] = RequiredKey(customer.CustomerKey, "Customer key"),
      ["Customer.MagentoGroupKey"] = group,
      ["Customer.Type"] = customer.CustomerTypeCode,
      ["Customer.Flags"] = JoinComponents(
        ("PAK2", customer.PackagingDiscountEnabled),
        ("VALUE", customer.ValueDiscountEnabled),
        ("B2B_PLUS", customer.B2bPlusEnabled)),
      ["Customer.B2bPlusValidFrom"] = Date(customer.B2bPlusValidFrom),
      ["Customer.B2bPlusValidTo"] = Date(customer.B2bPlusValidTo),
      ["Customer.PriceList"] = customer.PriceListCode,
      ["Customer.DiscountPriceList"] = customer.DiscountPriceListCode,
      ["Customer.Payer"] = JoinValues(customer.PayerCode, customer.PayerName),
      ["Customer.ValueTiers"] = string.Join('|', tiers.Select(tier => $"{tier.TierNumber}:{Number(tier.ThresholdGrossExVat)}:{Number(tier.Percent)}")),
      ["Customer.GroupDiscounts"] = string.Join('|', customer.GroupDiscounts.OrderBy(discount => discount.ItemGroupCode, StringComparer.Ordinal).Select(discount => $"{discount.ItemGroupCode}:{Number(discount.Percent)}:{discount.SourceCode}")),
      ["Policy.B2bWebPercent"] = Number(DiscountPolicy.B2bWebPercent),
      ["Policy.Shipping"] = customer.B2bPlusEnabled ? "B2B_PLUS" : "STANDARD"
    };
  }

  private static string JoinComponents(params (string Name, bool Enabled)[] components)
    => string.Join('|', components.Where(component => component.Enabled).Select(component => component.Name));

  private static string JoinValues(params string?[] values) => string.Join('|', values.Select(value => value ?? ""));
  private static string? Date(DateOnly? value) => value?.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
  private static string Number(decimal value) => value.ToString("0.####", CultureInfo.InvariantCulture);
  private static string RequiredKey(string value, string name) => string.IsNullOrWhiteSpace(value) ? throw new ExportContractException($"{name} manjka.") : value.Trim();
}

public static class B2bProductCsvGenerator
{
  public static Task WriteAsync(string path, IEnumerable<ExportColumnDefinition> columns, IEnumerable<ProductExportRow> products, CancellationToken cancellationToken = default)
    => ConfiguredCsvWriter.WriteAsync(path, columns, products.Select(ToFields), cancellationToken);

  public static Task WriteAsync(string path, IEnumerable<ExportColumnDefinition> columns, IEnumerable<IReadOnlyDictionary<string, string?>> rows, CancellationToken cancellationToken = default)
    => ConfiguredCsvWriter.WriteAsync(path, columns, rows, cancellationToken);

  private static IReadOnlyDictionary<string, string?> ToFields(ProductExportRow product)
  {
    if (product.Pak2 <= 0) throw new ExportContractException($"Izdelek {product.ItemId} nima veljavnega PAK2.");
    if ((product.PackagingDiscountCode is null) != (product.PackagingDiscountPercent is null) || product.PackagingDiscountPercent is < 0 or > 100)
      throw new ExportContractException($"Izdelek {product.ItemId} nima usklajene S-šifre in odstotka.");

    return new Dictionary<string, string?>(StringComparer.Ordinal)
    {
      ["Product.ItemID"] = product.ItemId,
      ["Customer.MagentoGroupKey"] = string.IsNullOrWhiteSpace(product.MagentoGroupKey) ? throw new ExportContractException("Magento customer group manjka.") : product.MagentoGroupKey.Trim(),
      ["Product.Pak2"] = Number(product.Pak2),
      ["Product.PackagingDiscountCode"] = product.PackagingDiscountCode,
      ["Product.PackagingDiscountPercent"] = product.PackagingDiscountPercent is null ? null : Number(product.PackagingDiscountPercent.Value),
      ["Product.PromotionGateState"] = product.PromotionGateState.ToString()
    };
  }

  private static string Number(decimal value) => value.ToString("0.####", CultureInfo.InvariantCulture);
}

public static class ShippingPolicyCsvGenerator
{
  public static Task WriteAsync(string path, IEnumerable<ExportColumnDefinition> columns, IEnumerable<ShippingPolicyExportRow> policies, CancellationToken cancellationToken = default)
    => ConfiguredCsvWriter.WriteAsync(path, columns, policies.OrderBy(policy => policy.Priority).Select(ToFields), cancellationToken);

  private static IReadOnlyDictionary<string, string?> ToFields(ShippingPolicyExportRow policy) => new Dictionary<string, string?>(StringComparer.Ordinal)
  {
    ["Shipping.RuleCode"] = policy.RuleCode,
    ["Shipping.OrderThreshold"] = policy.OrderThreshold?.ToString("0.####", CultureInfo.InvariantCulture),
    ["Shipping.PackageLengthMeters"] = policy.PackageLengthMeters?.ToString("0.####", CultureInfo.InvariantCulture),
    ["Shipping.Net"] = policy.ShippingNet.ToString("0.####", CultureInfo.InvariantCulture),
    ["Shipping.IsFree"] = policy.IsFree ? "1" : "0",
    ["Shipping.Priority"] = policy.Priority.ToString(CultureInfo.InvariantCulture)
  };
}

/// <summary>
/// Zapis vrstic, ki jih je po registru zložila že baza: vrednost na mestu <c>i</c> pripada
/// stolpcu na mestu <c>i</c>. Vrstice tečejo skozi, zato izvoz s 100.000 vrsticami nikoli
/// ne stoji cel v pomnilniku — prej je vsaka vrstica najprej postala slovar z 213 vnosi.
/// </summary>
public static class RegistryCsvWriter
{
  /// <returns>Število zapisanih vrstic brez glave.</returns>
  public static async Task<int> WriteAsync(
    string path,
    IEnumerable<ExportColumnDefinition> definitions,
    IAsyncEnumerable<IReadOnlyList<string?>> rows,
    CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(rows);
    var columns = ConfiguredCsvWriter.Ordered(definitions);

    await using var writer = new StreamWriter(path, false, new UTF8Encoding(false)) { NewLine = "\n" };
    await writer.WriteLineAsync(string.Join(',', columns.Select(column => ConfiguredCsvWriter.Escape(column.OutputColumnName))));

    var written = 0;
    await foreach (var row in rows.WithCancellation(cancellationToken))
    {
      // Vrstica pride iz procedure, ki bere isti register kot glava. Ce se stevili razideta,
      // je datoteka premaknjena za en stolpec in tega Magento ne bi opazil — zato pade tu.
      if (row.Count != columns.Length)
        throw new ExportContractException($"Vrstica ima {row.Count} vrednosti, izvozni profil pa {columns.Length} stolpcev.");

      for (var index = 0; index < columns.Length; index++)
        if (columns[index].IsRequired && string.IsNullOrWhiteSpace(row[index]))
          throw new ExportContractException($"Obvezna vrednost {columns[index].CanonicalFieldCode} je prazna.");

      await writer.WriteLineAsync(string.Join(',', row.Select(ConfiguredCsvWriter.Escape)));
      written++;
    }

    return written;
  }
}

internal static class ConfiguredCsvWriter
{
  public static ExportColumnDefinition[] Ordered(IEnumerable<ExportColumnDefinition> definitions)
  {
    var columns = definitions.Where(column => column.IsActive).OrderBy(column => column.SortOrder).ThenBy(column => column.ColumnCode, StringComparer.Ordinal).ToArray();
    if (columns.Length == 0 || columns.Select(column => column.SortOrder).Distinct().Count() != columns.Length)
      throw new ExportContractException("Izvozni profil nima enoličnih aktivnih stolpcev.");
    return columns;
  }

  public static async Task WriteAsync(string path, IEnumerable<ExportColumnDefinition> definitions, IEnumerable<IReadOnlyDictionary<string, string?>> rows, CancellationToken cancellationToken)
  {
    var columns = Ordered(definitions);
    await using var writer = new StreamWriter(path, false, new UTF8Encoding(false)) { NewLine = "\n" };
    await writer.WriteLineAsync(string.Join(',', columns.Select(column => Escape(column.OutputColumnName))));
    foreach (var row in rows)
    {
      cancellationToken.ThrowIfCancellationRequested();
      var values = new string?[columns.Length];
      for (var index = 0; index < columns.Length; index++)
      {
        var column = columns[index];
        if (!row.TryGetValue(column.CanonicalFieldCode, out var value) && column.IsRequired)
          throw new ExportContractException($"Manjka obvezna vrednost {column.CanonicalFieldCode}.");
        if (column.IsRequired && string.IsNullOrWhiteSpace(value)) throw new ExportContractException($"Obvezna vrednost {column.CanonicalFieldCode} je prazna.");
        values[index] = value;
      }
      await writer.WriteLineAsync(string.Join(',', values.Select(Escape)));
    }
  }

  public static string Escape(string? value)
  {
    value ??= "";
    return value.IndexOfAny([',', '"', '\r', '\n']) < 0 ? value : '"' + value.Replace("\"", "\"\"") + '"';
  }
}
