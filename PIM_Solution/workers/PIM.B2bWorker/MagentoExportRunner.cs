using System.Globalization;
using Microsoft.Data.SqlClient;
using PIM.B2b;

namespace PIM.B2bWorker;

public sealed class MagentoExportRunner
{
  public async Task ExportAsync(string connectionString, int organizationId, string outputDirectory, CancellationToken cancellationToken = default)
  {
    Directory.CreateDirectory(outputDirectory);
    await using var connection = new SqlConnection(connectionString);
    await connection.OpenAsync(cancellationToken);

    var products = await ReadProductsAsync(connection, organizationId, cancellationToken);
    var customers = await ReadCustomersAsync(connection, organizationId, cancellationToken);
    await B2bProductCsvGenerator.WriteAsync(Path.Combine(outputDirectory, "magento-products.csv"), ProductColumns(), products, cancellationToken);
    await CustomerCsvGenerator.WriteAsync(Path.Combine(outputDirectory, "magento-customers.csv"), CustomerColumns(), customers, cancellationToken);
  }

  private static IEnumerable<ExportColumnDefinition> ProductColumns()
    => MagentoCsvContract.ProductHeaders.Select((header, index) => new ExportColumnDefinition($"MAGENTO_{index + 1:000}", header, header, index + 1, index == 0, true));

  private static IEnumerable<ExportColumnDefinition> CustomerColumns()
    => MagentoCsvContract.CustomerHeaders.Select((header, index) => new ExportColumnDefinition($"MAGENTO_CUSTOMER_{index + 1:000}", header, header, index + 1, index == 0, true));

  private static async Task<List<IReadOnlyDictionary<string, string?>>> ReadProductsAsync(SqlConnection connection, int organizationId, CancellationToken cancellationToken)
  {
    const string sql = """
      SELECT p.PimProductId,p.ItemID,p.EAN,cp.UoM,p.Manufacturer,cp.Supplier,cp.DiscountGroup,pc.CustomsTariff,pc.CountryOfOrigin,
             p.Name,cp.WebPublish,pc.NetWeight,pc.GrossWeight,pc.Pak2,pc.Dimensions,
             en.Value NameEn,sl.Value NameSl,media.PrimaryUrl,media2.OtherUrls,cat.CategorySl,cat.CategoryEn,
             b2bPrice.Net B2bNet,b2bPrice.VatRate B2bVat,b2cPrice.Net B2cNet,b2cPrice.VatRate B2cVat,
             pd.DiscountCode,dc.PercentValue,pd.PromotionGateState
      FROM pim.Product p
      LEFT JOIN canon.Product cp ON cp.OrganizationId=p.OrganizationId AND cp.ItemID=p.ItemID
      LEFT JOIN pim.ProductCommercial pc ON pc.PimProductId=p.PimProductId
      OUTER APPLY (SELECT TOP(1) Value FROM pim.ProductText WHERE PimProductId=p.PimProductId AND Lang=N'en' AND TextType IN(N'WEB_TITLE',N'TITLE_ERP') ORDER BY CASE TextType WHEN N'WEB_TITLE' THEN 0 ELSE 1 END) en
      OUTER APPLY (SELECT TOP(1) Value FROM pim.ProductText WHERE PimProductId=p.PimProductId AND Lang=N'sl' AND TextType IN(N'WEB_TITLE',N'TITLE_ERP') ORDER BY CASE TextType WHEN N'WEB_TITLE' THEN 0 ELSE 1 END) sl
      OUTER APPLY (SELECT TOP(1) Url PrimaryUrl FROM pim.ProductMedia WHERE PimProductId=p.PimProductId ORDER BY SortOrder, PimProductMediaId) media
      OUTER APPLY (SELECT STRING_AGG(CASE WHEN WebSite=N'B2C' THEN CategoryPath END,N'|') CategorySl, STRING_AGG(CASE WHEN WebSite=N'B2C_EN' THEN CategoryPath END,N'|') CategoryEn FROM pim.ProductCategory WHERE PimProductId=p.PimProductId) cat
      OUTER APPLY (SELECT STRING_AGG(Url,N'|') OtherUrls FROM pim.ProductMedia WHERE PimProductId=p.PimProductId AND NOT (Role=N'PRIMARY' AND SortOrder=1)) media2
      LEFT JOIN pim.ProductPrice b2bPrice ON b2bPrice.PimProductId=p.PimProductId AND b2bPrice.PriceList=N'B2B' AND b2bPrice.IsActive=1
      LEFT JOIN pim.ProductPrice b2cPrice ON b2cPrice.PimProductId=p.PimProductId AND b2cPrice.PriceList=N'B2C' AND b2cPrice.IsActive=1
      LEFT JOIN pim.ProductPackagingDiscount pd ON pd.PimProductId=p.PimProductId
      LEFT JOIN pim.PackagingDiscountCatalog dc ON dc.DiscountCode=pd.DiscountCode
      WHERE p.OrganizationId=@OrganizationId ORDER BY p.ItemID;
      """;
    var rows = new List<IReadOnlyDictionary<string, string?>>();
    await using var command = new SqlCommand(sql, connection) { CommandTimeout = 120 };
    command.Parameters.AddWithValue("@OrganizationId", organizationId);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    while (await reader.ReadAsync(cancellationToken))
    {
      var row = MagentoCsvContract.EmptyProductRow();
      Set(row, "Šifra artikla", reader, "ItemID"); Set(row, "EAN", reader, "EAN"); Set(row, "Merska enota", reader, "UoM");
      Set(row, "Naziv artikla EN", reader, "NameEn"); Set(row, "Naziv artikla", reader, "NameSl"); Set(row, "Proizvajalec", reader, "Manufacturer");
      Set(row, "Dobavitelj", reader, "Supplier"); Set(row, "Oznaka tarifa", reader, "CustomsTariff"); Set(row, "Država proizvoda", reader, "CountryOfOrigin");
      Set(row, "Bruto teža", reader, "GrossWeight"); Set(row, "Neto teža", reader, "NetWeight"); Set(row, "PAK2", reader, "Pak2"); Set(row, "Glavna slika", reader, "PrimaryUrl");
      Set(row, "Ostale slike", reader, "OtherUrls"); Set(row, "Kategorije vid SLO", reader, "CategorySl"); Set(row, "Kategorije vid ANG", reader, "CategoryEn");
      Set(row, "Cena B2B", reader, "B2bNet"); Set(row, "Cena B2C", reader, "B2cNet"); Set(row, "DDV", reader, "B2bVat"); Set(row, "Skupina popusta", reader, "DiscountCode"); Set(row, "S popust %", reader, "PercentValue");
      Set(row, "Spletne strani", reader, "WebPublish", value => value == "True" ? "base" : ""); Set(row, "EAN koda", reader, "EAN");
      rows.Add(row);
    }
    return rows;
  }

  private static async Task<List<IReadOnlyDictionary<string, string?>>> ReadCustomersAsync(SqlConnection connection, int organizationId, CancellationToken cancellationToken)
  {
    const string sql = """
      SELECT c.CustomerId,c.CustomerKey,c.Name,c.PriceListCode,c.PayerCode,c.PayerName,p.CustomerTypeCode,p.PackagingDiscountEnabled,p.ValueDiscountEnabled,p.B2bPlusEnabled,
             p.B2bPlusValidFrom,p.B2bPlusValidTo,g.MagentoGroupKey,
             COALESCE(t1.ThresholdGrossExVat,d1.ThresholdGrossExVat) Tier1Threshold,COALESCE(t1.PercentValue,d1.PercentValue) Tier1Percent,
             COALESCE(t2.ThresholdGrossExVat,d2.ThresholdGrossExVat) Tier2Threshold,COALESCE(t2.PercentValue,d2.PercentValue) Tier2Percent,
             COALESCE(t3.ThresholdGrossExVat,d3.ThresholdGrossExVat) Tier3Threshold,COALESCE(t3.PercentValue,d3.PercentValue) Tier3Percent,gd.GroupDiscounts,gd.NwDiscount
      FROM b2b.Customer c JOIN pim.CustomerWebProfile p ON p.CustomerId=c.CustomerId
      LEFT JOIN pim.CustomerTypeMagentoGroup g ON g.CustomerTypeCode=p.CustomerTypeCode
      JOIN pim.ValueDiscountTier d1 ON d1.TierNumber=1 JOIN pim.ValueDiscountTier d2 ON d2.TierNumber=2 JOIN pim.ValueDiscountTier d3 ON d3.TierNumber=3
      LEFT JOIN pim.CustomerValueDiscountTier t1 ON t1.CustomerId=c.CustomerId AND t1.TierNumber=1 AND t1.IsActive=1
      LEFT JOIN pim.CustomerValueDiscountTier t2 ON t2.CustomerId=c.CustomerId AND t2.TierNumber=2 AND t2.IsActive=1
      LEFT JOIN pim.CustomerValueDiscountTier t3 ON t3.CustomerId=c.CustomerId AND t3.TierNumber=3 AND t3.IsActive=1
      OUTER APPLY (SELECT STRING_AGG(CONCAT(ItemGroupCode,N':',CONVERT(nvarchar(40),PercentValue)),N'|') GroupDiscounts,
        MAX(CASE WHEN ItemGroupCode=N'NW' THEN CONVERT(nvarchar(40),PercentValue) END) NwDiscount FROM b2b.GroupDiscount WHERE CustomerId=c.CustomerId
        AND (ValidFrom IS NULL OR ValidFrom<=CONVERT(date,SYSUTCDATETIME())) AND (ValidTo IS NULL OR ValidTo>=CONVERT(date,SYSUTCDATETIME()))) gd
      WHERE c.OrganizationId=@OrganizationId AND p.WebEnabled=1 ORDER BY c.CustomerKey;
      """;
    var rows = new List<IReadOnlyDictionary<string, string?>>();
    await using var command = new SqlCommand(sql, connection) { CommandTimeout = 120 };
    command.Parameters.AddWithValue("@OrganizationId", organizationId);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    while (await reader.ReadAsync(cancellationToken))
    {
      var row = MagentoCsvContract.EmptyCustomerRow();
      Set(row, "Šifra stranke", reader, "CustomerKey"); Set(row, "Naziv", reader, "Name"); Set(row, "Skupina (Magento)", reader, "MagentoGroupKey"); Set(row, "Cenik", reader, "PriceListCode");
      Set(row, "Plačnik", reader, "PayerCode", value => Join(value, Get(reader, "PayerName"))); Set(row, "Popust polno pakiranje", reader, "PackagingDiscountEnabled", YesNo);
      Set(row, "Vrednostni rabat", reader, "ValueDiscountEnabled", YesNo); Set(row, "Rabat prag 1", reader, "Tier1Threshold"); Set(row, "Rabat % 1", reader, "Tier1Percent");
      Set(row, "Rabat prag 2", reader, "Tier2Threshold"); Set(row, "Rabat % 2", reader, "Tier2Percent"); Set(row, "Rabat prag 3", reader, "Tier3Threshold"); Set(row, "Rabat % 3", reader, "Tier3Percent");
      Set(row, "B2B+", reader, "B2bPlusEnabled", YesNo); Set(row, "Popust NW", reader, "NwDiscount");
      Set(row, "Skupine popustov", reader, "GroupDiscounts");
      rows.Add(row);
    }
    return rows;
  }

  private static string? Get(SqlDataReader reader, string name) => reader[name] is DBNull ? null : Convert.ToString(reader[name], CultureInfo.InvariantCulture);
  private static void Set(IDictionary<string, string?> row, string header, SqlDataReader reader, string source, Func<string?, string?>? convert = null) => row[header] = convert?.Invoke(Get(reader, source)) ?? Get(reader, source);
  private static string? YesNo(string? value) => value == "True" ? "1" : value == "False" ? "0" : value;
  private static string Join(string? first, string? second) => string.Join("|", new[] { first, second }.Select(x => x ?? ""));
}
