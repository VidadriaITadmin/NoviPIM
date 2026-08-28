using Microsoft.Data.SqlClient;

namespace PIM.Intranet.Services;

/// <param name="TargetProductId">Izdelek, ki ga cilj ujame; null pomeni, da te sifre v katalogu ni.</param>
/// <param name="TargetKey">Sifra, kot jo je poslal vir — ostane vidna tudi, kadar se ne ujame.</param>
public sealed record ProductLinkEntry(
  long SourceProductId, string SourceItemId, long? TargetProductId, string TargetItemId,
  string LinkType, string TargetKey, bool IsResolved);

/// <summary>
/// Povezave med izdelki, kot jih pošlje vir (<c>intranet.GetProductLinks</c>, migracija 131).
///
/// Svojega registra povezav sistem še nima: povezave so danes vrednosti atributov, ki jih
/// pošlje dobavitelj. Servis zato ničesar ne piše in ne izpeljuje — kar ni v
/// <c>canon.ProductAttribute</c>, tudi tu ne obstaja.
/// </summary>
public sealed class ProductLinkReadService(PimDb database)
{
  public Task<(IReadOnlyList<ProductLinkEntry> Rows, long TotalCount)> GetAsync(
    int organizationId, string? linkType, string? search, int skip, int take,
    CancellationToken cancellationToken = default) =>
    database.PageAsync("EXEC intranet.GetProductLinks @OrganizationId, @LinkType, NULL, @Search, @Skip, @Take;",
      reader => new ProductLinkEntry(
        PimDb.Int64(reader, "SourceProductId"), PimDb.TextOrEmpty(reader, "SourceItemId"),
        reader.IsDBNull(reader.GetOrdinal("TargetProductId")) ? null : PimDb.Int64(reader, "TargetProductId"),
        PimDb.TextOrEmpty(reader, "TargetItemId"), PimDb.TextOrEmpty(reader, "LinkType"),
        PimDb.TextOrEmpty(reader, "TargetKey"), PimDb.Bool(reader, "IsResolved")),
      command =>
      {
        command.Parameters.AddWithValue("@OrganizationId", organizationId);
        command.Parameters.AddWithValue("@LinkType", string.IsNullOrWhiteSpace(linkType) ? DBNull.Value : linkType);
        command.Parameters.AddWithValue("@Search", string.IsNullOrWhiteSpace(search) ? DBNull.Value : search);
        command.Parameters.AddWithValue("@Skip", skip);
        command.Parameters.AddWithValue("@Take", take);
      }, cancellationToken);
}
