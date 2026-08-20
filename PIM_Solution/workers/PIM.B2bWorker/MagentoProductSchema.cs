using PIM.B2b;

namespace PIM.B2bWorker;

public static class MagentoProductSchema
{
    /// <summary>
    /// Glave so ena sama definicija: <see cref="MagentoCsvContract.ProductHeaders"/> v PIM.B2b.
    /// Prej je bil tu podvojen seznam 215 nizov. Bil je znakovno enak, a nic ga ni vezalo na
    /// pogodbo — razsla bi se ob prvi spremembi ene same strani, in test, ki preverja pogodbo,
    /// tega ne bi opazil, ker izvozni ukaz uporablja to shemo in ne pogodbe.
    /// </summary>
    public static readonly string[] Headers = [.. MagentoCsvContract.ProductHeaders];

    public static ExportColumnDefinition[] BuildColumns()
    {
        return Enumerable.Range(0, Headers.Length)
            .Select(i => new ExportColumnDefinition($"COL{i + 1:D3}", Headers[i], GetCanonicalCode(i), i + 1, false, true))
            .ToArray();
    }

    internal static string GetCanonicalCode(int index) => index switch
    {
        0 => "Product.ItemID",
        1 => "Product.EAN",
        2 => "Product.WebSites",
        3 => "Product.WebTitleEn",
        4 => "Product.WebTitleSl",
        5 => "Product.Manufacturer",
        // Kategoriji "vid" sledita vzoru, ki v repozitoriju ze obstaja (MagentoExportRunner in
        // out.ExportB2bCustomersCsv): WebSite B2C je slovenska, B2C_EN angleska pot.
        // Stolpca "Kategorije svetila ANG/SLO" (23, 24) namenoma ostaneta nepreslikana — zanju
        // v repozitoriju ni nobenega vzora in katera pot jima pripada, je poslovna odlocitev.
        25 => "Product.CategoryEn",
        26 => "Product.CategorySl",
        9 => "Product.CustomsTariff",
        10 => "Product.CountryOfOrigin",
        11 => "Product.GrossWeight",
        13 => "Product.NetWeight",
        27 => "Product.PriceB2B",
        28 => "Product.PriceB2C",
        31 => "Product.VatRate",
        32 => "Product.Pak2",
        34 => "Product.PackagingDiscountCode",
        35 => "Product.PackagingDiscountPercent",
        37 => "Product.MainImage",
        38 => "Product.OtherImages",
        // Stolpci od 54 naprej so atributi. Kanonicna koda je namenoma kar glava iz predloge:
        // preslikave so v tem sistemu vrstice registra (map.FieldMapping), ne veje v kodi.
        // Da se stolpec napolni, mora obstajati preslikava s TargetFieldCode
        // N'ProductAttribute.<glava>' — na primer N'ProductAttribute.Grlo ANG'.
        //
        // STANJE 2026-08-20: taka preslikava ni nastavljena za nobenega od 162 atributnih
        // stolpcev. Edina obstojeca koda v bazi je CategoryRequired, zato ti stolpci v izvozu
        // ostanejo prazni. To ni napaka v kodi, ampak manjkajoca konfiguracija; katera SAOP/NW
        // lastnost pripada kateremu stolpcu, je poslovna odlocitev in je zapisana v TASKBOARD.md.
        // Mehanizem sam je dokazan v PIM.F7.MagentoExportTests.
        >= 53 => "Attr." + Headers[index].Trim(),
        _ => "",
    };
}
