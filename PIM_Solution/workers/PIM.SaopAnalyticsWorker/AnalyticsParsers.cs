using System.Globalization;
using System.Xml.Linq;

namespace PIM.SaopAnalyticsWorker;

// Vrstice, kot jih pričakujejo postopki ana.Upsert* (imena lastnosti = imena v OPENJSON WITH).

public sealed record InvoiceLineRow(
  int InvoiceYear, string InvoiceBook, int InvoiceNumber, int LineNumber, DateTime InvoiceDate, string? CustomerId,
  string? CustomerName, string? ClerkId, string? ItemId, decimal Quantity, string? UnitOfMeasure, decimal? Price,
  decimal? DiscountPercent, decimal? NetAmount, string? CurrencyId, decimal? ExchangeRate, decimal? ExchangeRateBase,
  string? Status, DateTime? SourceModifiedUtc);

public sealed record CustomerOrderLineRow(
  string OrderId, int LineNumber, string? OrderType, DateTime? OrderDate, string? CustomerId, string? SiteId, string ItemId,
  decimal? RequestedQty, decimal? ShippedQty, DateTime? DemandDate, DateTime? RequestedDate, DateTime? ShippedDate,
  string? LineStatus, string? UnitOfMeasure);

public sealed record PurchaseOrderLineRow(
  string PurchaseOrderId, int LineNumber, string? OrderType, string? DeliveryType, DateTime? OrderDate, string? SupplierId,
  string? SiteId, string ItemId, string? SupplierItemId, decimal? RequestedQty, decimal? ReceivedQty, DateTime? ReceivedDate,
  string? LineStatus, string? UnitOfMeasure);

public sealed record ItemPurchaseInfoRow(
  string ItemId, string? PreferredSupplier, string? Supplier, string? SupplierItemId, decimal? AveragePurchasePrice,
  decimal? LastPurchasePrice, decimal? ListPrice, decimal? OrderMultiple, string? Brand, string? Ean);

/// <summary>Ključ računa, ki ga seznam vrne brez vrstic (potreben je klic GetInvoice).</summary>
public sealed record InvoiceKey(int Year, string Book, int Number);

public sealed record InvoiceParseResult(IReadOnlyList<InvoiceLineRow> Lines, IReadOnlyList<InvoiceKey> WithoutLines, int Invoices);

/// <summary>
/// Razčlenitev SAOP XML odgovorov. Namenoma strpna: SAOP swagger poimenuje ovojnice drugače, kot jih vrne
/// živ strežnik (migracija 199), zato se zapisi iščejo po imenu elementa in po otroku, ki ga zapis mora
/// imeti — ne po korenu. Polje je lahko element ali atribut, z imenskim prostorom ali brez.
/// </summary>
public static class AnalyticsParsers
{
  public static XDocument Parse(string xml, string what)
  {
    try { return XDocument.Parse(xml); }
    catch (System.Xml.XmlException exception)
    {
      throw new InvalidOperationException($"Odgovor {what} ni veljaven XML: {exception.Message}", exception);
    }
  }

  // ─── Računi ────────────────────────────────────────────────────────────────

  public static InvoiceParseResult ParseInvoices(XDocument document)
  {
    var lines = new List<InvoiceLineRow>();
    var withoutLines = new List<InvoiceKey>();
    var invoices = Records(document, "Invoice", "InvoiceNumber").ToList();
    // GetInvoice po ključu vrne en sam račun, katerega koren je lahko drugače poimenovan.
    if (invoices.Count == 0 && document.Root is { } root && Field(root, "InvoiceNumber") is not null) invoices.Add(root);

    foreach (var invoice in invoices)
    {
      var year = Int(Field(invoice, "InvoiceYear"));
      var book = Field(invoice, "InvoiceBook");
      var number = Int(Field(invoice, "InvoiceNumber"));
      var date = Date(Field(invoice, "InvoiceDate"));
      if (year is null || string.IsNullOrWhiteSpace(book) || number is null) continue;

      var lineElements = invoice.Descendants().Where(e => e.Name.LocalName is "InvoiceLine" or "InvoiceLineDetail").ToList();
      if (lineElements.Count == 0)
      {
        withoutLines.Add(new InvoiceKey(year.Value, book.Trim(), number.Value));
        continue;
      }
      if (date is null) continue;

      var customerId = Field(invoice, "CustomerID") ?? Field(invoice, "CustomerPayerID");
      var customerName = Field(invoice, "RecipientTitle1") ?? Field(invoice, "PayerTitle1");
      var ordinal = 0;
      foreach (var line in lineElements)
      {
        ordinal++;
        var itemId = Field(line, "ItemID");
        if (string.IsNullOrWhiteSpace(itemId)) continue; // besedilna vrstica
        lines.Add(new InvoiceLineRow(
          year.Value, book.Trim(), number.Value, Int(Field(line, "LineNumber")) ?? ordinal, date.Value,
          customerId, customerName, Field(invoice, "ClerkID"), itemId.Trim(),
          Decimal(Field(line, "Quantity")) ?? 0, Field(line, "UnitOfMeasurement"), Decimal(Field(line, "Price")),
          Decimal(Field(line, "DiscountPercentage")), Decimal(Field(line, "NetAmount")),
          Field(invoice, "CurrencyID"), Decimal(Field(invoice, "ExchangeRate")), Decimal(Field(invoice, "ExchangeRateBase")),
          Field(invoice, "Status"), Date(Field(invoice, "ModifiedTime"))));
      }
    }
    return new InvoiceParseResult(lines, withoutLines, invoices.Count);
  }

  // ─── Barkawi: naročila kupcev ───────────────────────────────────────────────

  public static IReadOnlyList<CustomerOrderLineRow> ParseCustomerOrders(XDocument document, out int orders)
  {
    var result = new List<CustomerOrderLineRow>();
    var headers = Records(document, "CUSTOMER_ORDER", "CUSTOMER_ORDER_ID").ToList();
    orders = headers.Count;
    foreach (var header in headers)
    {
      var orderId = Field(header, "CUSTOMER_ORDER_ID");
      if (string.IsNullOrWhiteSpace(orderId)) continue;
      foreach (var line in header.Descendants().Where(e => Field(e, "ORDER_LINE_NUMBER") is not null && e.Elements().Any()))
      {
        var itemId = Field(line, "DEALER_ITEM_ID") ?? Field(line, "SUPPLIER_ITEM_ID");
        var lineNumber = Int(Field(line, "ORDER_LINE_NUMBER"));
        if (string.IsNullOrWhiteSpace(itemId) || lineNumber is null) continue;
        result.Add(new CustomerOrderLineRow(
          orderId.Trim(), lineNumber.Value, Field(header, "ORDER_TYPE"), Date(Field(header, "ORDER_DATE")),
          Field(header, "CUSTOMER_ID"), Field(header, "DEALER_SITE_ID"), itemId.Trim(),
          Decimal(Field(line, "REQUESTED_QUANTITY")), Decimal(Field(line, "SHIPPED_QUANTITY")),
          Date(Field(line, "DEMAND_DATE")), Date(Field(line, "REQUESTED_DATE")), Date(Field(line, "SHIPED_DATE") ?? Field(line, "SHIPPED_DATE")),
          Field(line, "LINE_STATUS"), Field(line, "UNIT_OF_MEASURE")));
      }
    }
    return result;
  }

  // ─── Barkawi: naročila dobaviteljem ─────────────────────────────────────────

  public static IReadOnlyList<PurchaseOrderLineRow> ParsePurchaseOrders(XDocument document, out int orders)
  {
    var result = new List<PurchaseOrderLineRow>();
    var headers = Records(document, "PURCHASE_ORDER", "PURCHASE_ORDER_ID").ToList();
    orders = headers.Count;
    foreach (var header in headers)
    {
      var orderId = Field(header, "PURCHASE_ORDER_ID");
      if (string.IsNullOrWhiteSpace(orderId)) continue;
      foreach (var line in header.Descendants().Where(e => Field(e, "ORDER_LINE_NUMBER") is not null && e.Elements().Any()))
      {
        var itemId = Field(line, "DEALER_ITEM_ID") ?? Field(line, "SUPPLIER_ITEM_ID");
        var lineNumber = Int(Field(line, "ORDER_LINE_NUMBER"));
        if (string.IsNullOrWhiteSpace(itemId) || lineNumber is null) continue;
        result.Add(new PurchaseOrderLineRow(
          orderId.Trim(), lineNumber.Value, Field(header, "ORDER_TYPE"), Field(header, "TYPE_OF_DELIVERY"),
          Date(Field(header, "PURCHASE_ORDER_DATE")), Field(header, "SUPPLIER"), Field(header, "DEALER_SITE_ID"), itemId.Trim(),
          Field(line, "SUPPLIER_ITEM_ID"), Decimal(Field(line, "REQUESTED_QUANTITY")), Decimal(Field(line, "RECEIVED_QUANTITY")),
          Date(Field(line, "RECEIVED_DATE")), Field(line, "LINE_STATUS"), Field(line, "UNIT_OF_MEASURE")));
      }
    }
    return result;
  }

  // ─── Barkawi: nabavni podatki artikla ───────────────────────────────────────

  public static IReadOnlyList<ItemPurchaseInfoRow> ParseSku(XDocument document)
  {
    var result = new List<ItemPurchaseInfoRow>();
    foreach (var item in document.Descendants().Where(e => Field(e, "DEALER_ITEM_ID") is not null && e.Elements().Count() > 1))
    {
      var itemId = Field(item, "DEALER_ITEM_ID");
      if (string.IsNullOrWhiteSpace(itemId)) continue;
      var multiple = Decimal(Field(item, "MULTIPLES"));
      result.Add(new ItemPurchaseInfoRow(
        itemId.Trim(), Field(item, "PREFERRED_SUPPLIER"), Field(item, "SUPPLIER"), Field(item, "SUPPLIER_ITEM_ID"),
        Decimal(Field(item, "AVARAGE_PURCHASE_PRICE") ?? Field(item, "AVERAGE_PURCHASE_PRICE")), Decimal(Field(item, "LAST_PURCHASE_PRICE")),
        Decimal(Field(item, "LIST_PRICE")), multiple is > 0 ? multiple : null, Field(item, "BRAND"), Field(item, "EAN_CODE")));
    }
    return result;
  }

  // ─── Skupno ──────────────────────────────────────────────────────────────────

  /// <summary>Zapisi z danim imenom elementa, ki imajo obvezno polje; ugnezdeni isti zapisi se ne podvojijo.</summary>
  static IEnumerable<XElement> Records(XDocument document, string localName, string requiredField) =>
    document.Descendants().Where(e => e.Name.LocalName.Equals(localName, StringComparison.OrdinalIgnoreCase)
      && Field(e, requiredField) is not null);

  /// <summary>Vrednost otroka (element) ali atributa z danim imenom; prazno = null.</summary>
  public static string? Field(XElement element, string name)
  {
    var child = element.Elements().FirstOrDefault(e => e.Name.LocalName.Equals(name, StringComparison.OrdinalIgnoreCase));
    var value = child?.Value ?? element.Attributes().FirstOrDefault(a => a.Name.LocalName.Equals(name, StringComparison.OrdinalIgnoreCase))?.Value;
    return string.IsNullOrWhiteSpace(value) ? null : value.Trim();
  }

  public static int? Int(string? value) =>
    int.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsed) ? parsed
      : Decimal(value) is { } asDecimal && asDecimal == decimal.Truncate(asDecimal) && asDecimal is >= int.MinValue and <= int.MaxValue ? (int)asDecimal : null;

  static readonly CultureInfo Slovenian = CultureInfo.GetCultureInfo("sl-SI");

  /// <summary>Število s piko (XML) ali z vejico (slovenska oblika).</summary>
  public static decimal? Decimal(string? value)
  {
    if (string.IsNullOrWhiteSpace(value)) return null;
    if (decimal.TryParse(value, NumberStyles.Number | NumberStyles.AllowExponent, CultureInfo.InvariantCulture, out var parsed)
        && !(value.Contains(',') && !value.Contains('.'))) return parsed;
    return decimal.TryParse(value, NumberStyles.Number, Slovenian, out parsed) ? parsed : null;
  }

  static readonly string[] DateFormats = ["yyyy-MM-dd", "yyyy-MM-ddTHH:mm:ss", "yyyy-MM-ddTHH:mm:ss.FFFFFFF", "yyyy-MM-ddTHH:mm:ssK",
    "yyyy-MM-ddTHH:mm:ss.FFFFFFFK", "dd.MM.yyyy", "d.M.yyyy", "dd.MM.yyyy HH:mm:ss", "yyyyMMdd", "yyyy-MM-dd HH:mm:ss"];

  /// <summary>Datum brez časovnega pasu (SAOP vrača lokalni čas); 0001-01-01 in 1900-01-01 sta »ni datuma«.</summary>
  public static DateTime? Date(string? value)
  {
    if (string.IsNullOrWhiteSpace(value)) return null;
    if (DateTime.TryParseExact(value.Trim(), DateFormats, CultureInfo.InvariantCulture, DateTimeStyles.AllowWhiteSpaces, out var parsed)
        || DateTime.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.AllowWhiteSpaces, out parsed))
      return parsed.Year <= 1900 ? null : parsed;
    return null;
  }
}
