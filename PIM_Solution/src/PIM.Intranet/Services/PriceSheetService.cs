using Microsoft.Data.SqlClient;

namespace PIM.Intranet.Services;

/// <summary>Cenik za tisk (migracija 150): vrstice iz intranet.GetPriceListSheet.</summary>
public sealed class PriceSheetService(PimDb database)
{
  public sealed record SheetRow(
    long ProductId, string ItemID, string? EAN, string Title, string? CategoryPath, string? Manufacturer, string? UoM,
    string PriceList, decimal? Net, decimal? VatRate, decimal? Gross, decimal? Stock, string? ImageUrl);

  public Task<IReadOnlyList<SheetRow>> GetSheetAsync(
    int organizationId, string priceList, string languageCode, string? webSite, string? categoryPathPrefix,
    IReadOnlyList<string>? itemIds, bool onlyPublished, int take, CancellationToken cancellationToken = default) =>
    database.QueryAsync(
      "EXEC intranet.GetPriceListSheet @OrganizationId, @PriceList, @LanguageCode, @WebSite, @CategoryPathPrefix, @ItemIds, @OnlyPublished, @Take;",
      reader => new SheetRow(
        PimDb.Int64(reader, "ProductId"), PimDb.TextOrEmpty(reader, "ItemID"), PimDb.Text(reader, "EAN"),
        PimDb.TextOrEmpty(reader, "Title"), PimDb.Text(reader, "CategoryPath"), PimDb.Text(reader, "Manufacturer"),
        PimDb.Text(reader, "UoM"), PimDb.TextOrEmpty(reader, "PriceList"), PimDb.NullableDecimal(reader, "Net"),
        PimDb.NullableDecimal(reader, "VatRate"), PimDb.NullableDecimal(reader, "Gross"), PimDb.NullableDecimal(reader, "Stock"),
        PimDb.Text(reader, "ImageUrl")),
      command =>
      {
        command.Parameters.AddWithValue("@OrganizationId", organizationId);
        command.Parameters.AddWithValue("@PriceList", priceList);
        command.Parameters.AddWithValue("@LanguageCode", languageCode);
        command.Parameters.AddWithValue("@WebSite", string.IsNullOrWhiteSpace(webSite) ? DBNull.Value : webSite);
        command.Parameters.AddWithValue("@CategoryPathPrefix", string.IsNullOrWhiteSpace(categoryPathPrefix) ? DBNull.Value : categoryPathPrefix);
        command.Parameters.AddWithValue("@ItemIds", itemIds is { Count: > 0 } ? System.Text.Json.JsonSerializer.Serialize(itemIds) : DBNull.Value);
        command.Parameters.AddWithValue("@OnlyPublished", onlyPublished);
        command.Parameters.AddWithValue("@Take", take);
      }, cancellationToken);
}
