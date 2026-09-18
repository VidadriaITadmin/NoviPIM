using System.Data;
using Microsoft.Data.SqlClient;

namespace PIM.Intranet.Services;

public sealed record CatalogControlRow(long ProductId, string ItemId, string? Department,
    string? ItemGroup, string? DiscountGroup, bool Active, bool Selected, bool Excluded,
    decimal ClearancePercent, decimal? OwnAvailable, decimal? SupplierAvailable,
    DateTime? OwnSnapshotUtc, DateTime? SupplierSnapshotUtc, bool ReviewPending, string ValidationStatus);

public sealed class CatalogControlService(IConfiguration configuration, PimWriteGuard guard)
{
    async Task<SqlConnection> OpenAsync()
    {
        var connection = new SqlConnection(ConnectionStringResolver.Resolve(configuration)
            ?? throw new InvalidOperationException("Povezava PIM ni nastavljena."));
        try { await connection.OpenAsync(); return connection; }
        catch { await connection.DisposeAsync(); throw; }
    }

    public async Task<IReadOnlyList<CatalogControlRow>> ReadAsync(int organizationId, string search, bool reviewOnly)
    {
        await using var connection = await OpenAsync();
        await using var command = new SqlCommand("""
            SELECT TOP(100) p.ProductId,p.ItemID,p.Department,p.ItemGroup,p.DiscountGroup,p.IsActive,
              CAST(CASE WHEN EXISTS(SELECT 1 FROM pim.ProductWebShop shop WHERE shop.ProductId=p.ProductId AND shop.IsPublished=1) THEN 1 ELSE 0 END AS bit),
              ISNULL(policy.IsExcluded,CAST(0 AS bit)),ISNULL(policy.ClearancePercent,0),
              stock.OwnAvailable,stock.SupplierAvailable,stock.OwnSnapshotUtc,stock.SupplierSnapshotUtc,
              CAST(CASE WHEN review.ProductId IS NOT NULL AND review.ResolvedUtc IS NULL THEN 1 ELSE 0 END AS bit),p.ValidationStatus
            FROM canon.Product p
            LEFT JOIN pim.CatalogPolicy policy ON policy.ProductId=p.ProductId
            LEFT JOIN pim.CatalogReview review ON review.ProductId=p.ProductId
            LEFT JOIN out.CatalogStock stock ON stock.OrganizationId=p.OrganizationId AND stock.ItemID=p.ItemID
            WHERE p.OrganizationId=@OrganizationId
              AND (@Search=N'' OR p.ItemID LIKE @SearchLike OR p.EAN=@Search)
              AND (@ReviewOnly=0 OR (review.ProductId IS NOT NULL AND review.ResolvedUtc IS NULL))
            ORDER BY p.ItemID
            """, connection) { CommandTimeout = 120 };
        command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
        command.Parameters.Add("@Search", SqlDbType.NVarChar, 200).Value = search.Trim();
        command.Parameters.Add("@SearchLike", SqlDbType.NVarChar, 201).Value = search.Trim() + "%";
        command.Parameters.Add("@ReviewOnly", SqlDbType.Bit).Value = reviewOnly;
        await using var reader = await command.ExecuteReaderAsync();
        var rows = new List<CatalogControlRow>();
        while (await reader.ReadAsync())
            rows.Add(new(reader.GetInt64(0), reader.GetString(1), Text(2), Text(3), Text(4),
                reader.GetBoolean(5), reader.GetBoolean(6), reader.GetBoolean(7), reader.GetDecimal(8),
                Number(9), Number(10), Date(11), Date(12), reader.GetBoolean(13), reader.GetString(14)));
        return rows;
        string? Text(int i) => reader.IsDBNull(i) ? null : reader.GetString(i);
        decimal? Number(int i) => reader.IsDBNull(i) ? null : reader.GetDecimal(i);
        DateTime? Date(int i) => reader.IsDBNull(i) ? null : reader.GetDateTime(i);
    }

    public async Task<IReadOnlyList<string>> UnmappedAsync()
    {
        await using var connection = await OpenAsync();
        await using var command = new SqlCommand("""
            SELECT c.OutputColumnName FROM out.ExportColumn c
            JOIN out.ExportProfile p ON p.ExportProfileId=c.ExportProfileId
            WHERE p.ProfileCode=N'MAGENTO_PRODUCTS' AND c.IsActive=1
              AND NULLIF(c.CanonicalFieldCode,N'') IS NULL ORDER BY c.SortOrder
            """, connection);
        await using var reader = await command.ExecuteReaderAsync();
        var rows = new List<string>();
        while (await reader.ReadAsync()) rows.Add(reader.GetString(0));
        return rows;
    }

    public async Task SaveAsync(int organizationId, long productId, bool excluded, decimal percent)
    {
        var actor = await guard.RequireAsync(PimPolicies.CatalogWrite);
        if (percent is < 0 or > 100) throw new ArgumentOutOfRangeException(nameof(percent));
        await using var connection = await OpenAsync();
        await using var command = Procedure(connection, "pim.SaveCatalogPolicy", organizationId);
        command.Parameters.Add("@ProductId", SqlDbType.BigInt).Value = productId;
        command.Parameters.Add("@IsExcluded", SqlDbType.Bit).Value = excluded;
        var discount = command.Parameters.Add("@ClearancePercent", SqlDbType.Decimal);
        discount.Precision = 5; discount.Scale = 2; discount.Value = percent;
        command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = actor;
        await command.ExecuteNonQueryAsync();
    }

    public async Task RefreshAsync(int organizationId)
    {
        await guard.RequireAsync(PimPolicies.CatalogWrite);
        await using var connection = await OpenAsync();
        await using var command = Procedure(connection, "pim.RefreshCatalogReview", organizationId);
        await command.ExecuteNonQueryAsync();
    }

    public async Task ResolveAsync(int organizationId, long productId, string resolution)
    {
        var actor = await guard.RequireAsync(PimPolicies.CatalogWrite);
        await using var connection = await OpenAsync();
        await using var command = Procedure(connection, "pim.ResolveCatalogReview", organizationId);
        command.Parameters.Add("@ProductId", SqlDbType.BigInt).Value = productId;
        command.Parameters.Add("@Resolution", SqlDbType.NVarChar, 1000).Value = resolution;
        command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = actor;
        await command.ExecuteNonQueryAsync();
    }

    static SqlCommand Procedure(SqlConnection connection, string name, int organizationId)
    {
        var command = new SqlCommand(name, connection) { CommandType = CommandType.StoredProcedure, CommandTimeout = 120 };
        command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
        return command;
    }
}
