using System.Globalization;
using System.Text;

namespace PIM.B2b;

/// <param name="DecimalSeparator">
/// »,« = število v tem stolpcu se zapiše z decimalno vejico (277: cene za Magento). null = kot ga vrne baza (pika).
/// </param>
/// <param name="GuardKind">»PRICE« = vrednost stolpca pred objavo preveri varovalka cen (277).</param>
public sealed record ExportColumnDefinition(string ColumnCode, string OutputColumnName, string CanonicalFieldCode, int SortOrder, bool IsRequired, bool IsActive,
  string? DecimalSeparator = null, string? GuardKind = null);
public sealed class ExportContractException(string message) : InvalidOperationException(message);

/// <summary>
/// Oblika vrednosti v izvozni datoteki (277). Baza vrne število vedno v strojni obliki — s piko, brez ločila
/// tisočic (<c>out.MagentoNumber</c>) — in po njej računa tudi varovalka. Decimalno vejico postavi šele zapis
/// datoteke, samo v stolpcih, ki jo v registru zahtevajo (<c>out.ExportColumn.DecimalSeparator</c>).
/// Uporabnik 2026-09-24: »cene morajo imeti vejico, ne piko za ločilo« — Magento na svetilih je ceno s piko
/// prebral napačno. Vrednost, ki ni število, ostane nespremenjena; ujame jo varovalka (KAT_CENA_OBLIKA).
/// </summary>
public static class ExportValueFormat
{
  public static string? Apply(ExportColumnDefinition column, string? value) =>
    column.DecimalSeparator == "," ? WithDecimalComma(value) : value;

  /// <summary>Število v strojni obliki z decimalno vejico; vse drugo ostane, kot je.</summary>
  public static string? WithDecimalComma(string? value) =>
    value is { Length: > 0 } && IsInvariantNumber(value) ? value.Replace('.', ',') : value;

  /// <summary>Število v strojni obliki: neobvezen minus, števke, neobvezna pika z decimalkami.</summary>
  public static bool IsInvariantNumber(string value)
  {
    var digits = value.StartsWith('-') ? value.AsSpan(1) : value.AsSpan();
    var dot = digits.IndexOf('.');
    var whole = dot < 0 ? digits : digits[..dot];
    var fraction = dot < 0 ? "0".AsSpan() : digits[(dot + 1)..];
    return whole.Length > 0 && fraction.Length > 0 && IsDigits(whole) && IsDigits(fraction);

    static bool IsDigits(ReadOnlySpan<char> part)
    {
      foreach (var character in part)
        if (!char.IsAsciiDigit(character)) return false;
      return true;
    }
  }
}

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
  public static string Escape(string? value) => ConfiguredCsvWriter.Escape(value);
  public static string Escape(string? value, char delimiter) => ConfiguredCsvWriter.Escape(value, delimiter);

  /// <param name="delimiter">
  /// Ločilo stolpcev iz registra (<c>out.ExportProfile.FieldDelimiter</c>). 277: katalog.csv ima podpičje, da je
  /// cena z decimalno vejico (29,78) v datoteki brez narekovajev; ostali profili vejico.
  /// </param>
  /// <param name="recordWritten">
  /// Po vsaki zapisani vrstici: vrstica, odmik zapisa v bajtih od začetka datoteke in dolžina zapisa v bajtih
  /// (s koncem vrstice). Z njima se da datoteko naknadno prepisati brez posameznih vrstic (277: zadržani artikli).
  /// </param>
  /// <returns>Število zapisanih vrstic brez glave.</returns>
  public static async Task<int> WriteAsync(
    string path,
    IEnumerable<ExportColumnDefinition> definitions,
    IAsyncEnumerable<IReadOnlyList<string?>> rows,
    CancellationToken cancellationToken = default,
    char delimiter = ',',
    Action<IReadOnlyList<string?>, long, int>? recordWritten = null)
  {
    ArgumentNullException.ThrowIfNull(rows);
    var columns = ConfiguredCsvWriter.Ordered(definitions);
    var encoding = new UTF8Encoding(false);

    await using var writer = new StreamWriter(path, false, encoding) { NewLine = "\n" };
    var header = string.Join(delimiter, columns.Select(column => ConfiguredCsvWriter.Escape(column.OutputColumnName, delimiter)));
    await writer.WriteLineAsync(header);
    long offset = encoding.GetByteCount(header) + 1;

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

      var line = string.Join(delimiter, row.Select((value, index) =>
        ConfiguredCsvWriter.Escape(ExportValueFormat.Apply(columns[index], value), delimiter)));
      await writer.WriteLineAsync(line);
      var length = encoding.GetByteCount(line) + 1;
      recordWritten?.Invoke(row, offset, length);
      offset += length;
      written++;
    }

    return written;
  }

  /// <summary>
  /// Prepiše zapisano datoteko brez izbranih vrstic (277: zadržani artikli ne gredo v objavljeno datoteko).
  /// Glava in ostale vrstice se prenesejo bajt za bajtom, zato se oblika ne more spremeniti.
  /// </summary>
  /// <param name="records">Vse vrstice datoteke po vrsti, kot jih je javil <see cref="WriteAsync"/>.</param>
  /// <param name="skip">Katere vrstice (po indeksu v <paramref name="records"/>) izpustiti.</param>
  /// <returns>Število prenesenih vrstic.</returns>
  public static async Task<int> CopyWithoutAsync(
    string sourcePath, string targetPath, IReadOnlyList<(long Offset, int Length)> records, ISet<int> skip,
    CancellationToken cancellationToken = default)
  {
    await using var source = new FileStream(sourcePath, FileMode.Open, FileAccess.Read, FileShare.Read, 65536, FileOptions.SequentialScan);
    await using var target = new FileStream(targetPath, FileMode.Create, FileAccess.Write, FileShare.None, 65536);
    var headerLength = records.Count == 0 ? source.Length : records[0].Offset;
    await CopyRangeAsync(source, target, 0, headerLength, cancellationToken);
    var copied = 0;
    for (var index = 0; index < records.Count; index++)
    {
      if (skip.Contains(index)) continue;
      await CopyRangeAsync(source, target, records[index].Offset, records[index].Length, cancellationToken);
      copied++;
    }
    return copied;
  }

  static async Task CopyRangeAsync(Stream source, Stream target, long offset, long length, CancellationToken cancellationToken)
  {
    source.Position = offset;
    var buffer = new byte[65536];
    while (length > 0)
    {
      var read = await source.ReadAsync(buffer.AsMemory(0, (int)Math.Min(buffer.Length, length)), cancellationToken);
      if (read == 0) throw new EndOfStreamException("Izvozna datoteka je krajša, kot je bila zapisana.");
      await target.WriteAsync(buffer.AsMemory(0, read), cancellationToken);
      length -= read;
    }
  }
}

internal static class ConfiguredCsvWriter
{
  public static ExportColumnDefinition[] Ordered(IEnumerable<ExportColumnDefinition> definitions)
  {
    var columns = definitions.Where(column => column.IsActive).OrderBy(column => column.SortOrder).ThenBy(column => column.ColumnCode, StringComparer.Ordinal).ToArray();
    if (columns.Length == 0 || columns.Select(column => column.SortOrder).Distinct().Count() != columns.Length
        || columns.Any(column => string.IsNullOrWhiteSpace(column.OutputColumnName) || column.OutputColumnName != column.OutputColumnName.Trim())
        || columns.Select(column => column.OutputColumnName).Distinct(StringComparer.Ordinal).Count() != columns.Length)
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
        values[index] = ExportValueFormat.Apply(column, value);
      }
      await writer.WriteLineAsync(string.Join(',', values.Select(Escape)));
    }
  }

  public static string Escape(string? value) => Escape(value, ',');

  /// <summary>V narekovaje gre samo vrednost z ločilom stolpcev, narekovajem ali koncem vrstice (RFC 4180).</summary>
  public static string Escape(string? value, char delimiter)
  {
    value ??= "";
    return value.IndexOfAny([delimiter, '"', '\r', '\n']) < 0 ? value : '"' + value.Replace("\"", "\"\"") + '"';
  }
}
