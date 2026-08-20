using PIM.B2b;

namespace PIM.B2bWorker;

public static class MagentoCustomerSchema
{
    /// <summary>
    /// Glave so ena sama definicija: <see cref="MagentoCsvContract.CustomerHeaders"/> v PIM.B2b.
    /// Razlog je enak kot pri <see cref="MagentoProductSchema.Headers"/> — podvojen seznam se
    /// razide, pogodbeni test pa tega ne opazi.
    /// </summary>
    public static readonly string[] Headers = [.. MagentoCsvContract.CustomerHeaders];

    public static ExportColumnDefinition[] BuildColumns()
    {
        return new[]
        {
            Col(0,  "Customer.Key"),
            Col(1,  "Customer.Name"),
            Col(2,  ""),
            Col(3,  ""),
            Col(4,  ""),
            Col(5,  "Customer.MagentoGroup"),
            Col(6,  "Customer.PriceList"),
            Col(7,  "Customer.Payer"),
            Col(8,  "Customer.PackagingDiscountEnabled"),
            Col(9,  "Customer.ValueDiscountEnabled"),
            Col(10, "Customer.Tier1Threshold"),
            Col(11, "Customer.Tier1Percent"),
            Col(12, "Customer.Tier2Threshold"),
            Col(13, "Customer.Tier2Percent"),
            Col(14, "Customer.Tier3Threshold"),
            Col(15, "Customer.Tier3Percent"),
            Col(16, "Customer.B2bPlus"),
            Col(17, "Customer.GroupDiscounts"),
            Col(18, "Customer.NwDiscount"),
        };
    }

    private static ExportColumnDefinition Col(int index, string canonicalCode)
        => new($"CUC{index + 1:D2}", Headers[index], canonicalCode, index + 1, false, true);
}
