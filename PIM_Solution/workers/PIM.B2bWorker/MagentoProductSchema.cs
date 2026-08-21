using PIM.B2b;

namespace PIM.B2bWorker;

public static class MagentoProductSchema
{
    /// <summary>
    /// Profil v registru <c>out.ExportProfile</c>, ki opisuje obliko te datoteke.
    /// Od migracije 045 je vrstni red stolpcev, njihova imena in to, katera kanonična
    /// vrednost gre v kateri stolpec, zapisano tam — ne več v kodi.
    /// </summary>
    public const string ProfileCode = "MAGENTO_PRODUCTS";

    /// <summary>
    /// Predloga Magenta kot zunanja pogodba: <see cref="MagentoCsvContract.ProductHeaders"/>.
    /// Izvoz je ne uporablja več za sestavo datoteke — to počne register. Ostaja zato, ker
    /// je merilo, s katerim <c>PIM.F7.MagentoExportTests</c> preveri, da se register in
    /// predloga nista razšla.
    /// </summary>
    public static readonly string[] Headers = [.. MagentoCsvContract.ProductHeaders];
}
