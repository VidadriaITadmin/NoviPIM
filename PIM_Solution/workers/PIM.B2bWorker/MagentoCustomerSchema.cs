using PIM.B2b;

namespace PIM.B2bWorker;

public static class MagentoCustomerSchema
{
    /// <summary>Profil v registru; razlog je enak kot pri <see cref="MagentoProductSchema.ProfileCode"/>.</summary>
    public const string ProfileCode = "MAGENTO_CUSTOMERS";

    /// <summary>
    /// Predloga Magenta kot zunanja pogodba: <see cref="MagentoCsvContract.CustomerHeaders"/>.
    /// Merilo za register, ne vir oblike datoteke.
    /// </summary>
    public static readonly string[] Headers = [.. MagentoCsvContract.CustomerHeaders];
}
