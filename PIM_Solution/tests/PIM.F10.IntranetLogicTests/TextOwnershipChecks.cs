using PIM.Intranet.Services;

/// <summary>
/// Lastnistvo vrst besedil (239). Uporabnik 2026-09-21: »ERP opisi se pojavijo na kartici pod
/// Splet – opisi« — kartica loci ERP in spletna besedila po tem pravilu, zato ga test drzi na mestu.
/// </summary>
static class TextOwnershipChecks
{
  public static void Run()
  {
    foreach (var erp in new[] { "TITLE_ERP", "TITLE_ERP2", "TITLE_SHORT", "SEARCH_NAME", "DESCRIPTION_ERP", "DESCRIPTION_ERP_K", "DESCRIPTION_ERP_O", "description_erp_kd" })
      Check(ProductFieldLabels.IsErpTextType(erp), $"{erp} je last ERP-ja in ne sme na zavihek Splet.");

    foreach (var web in new[] { "WEB_TITLE", "DESCRIPTION", "DESCRIPTION_K", "DESCRIPTION_O", "DESCRIPTION_KK", "SHORT_DESCRIPTION" })
      Check(!ProductFieldLabels.IsErpTextType(web), $"{web} je spletno besedilo, ki ga pise PIM.");

    Check(!ProductFieldLabels.IsErpTextType(null) && !ProductFieldLabels.IsErpTextType(""), "Prazna vrsta ni ERP.");
    Check(ProductFieldLabels.CoreWebTextTypes.SequenceEqual(["WEB_TITLE", "DESCRIPTION"]), "Kartica vedno ponudi spletni naziv in spletni opis.");

    Check(ProductFieldLabels.TextTypeLabel("DESCRIPTION_ERP") == "ERP opis", "ERP opis ima svoje ime.");
    Check(ProductFieldLabels.TextTypeLabel("DESCRIPTION") == "Spletni opis", "Spletni opis ostane spletni opis.");
    Check(ProductFieldLabels.TextTypeLabel("TITLE_SHORT") == "ERP kratki naziv", "Kratki naziv iz SAOP je oznacen kot ERP.");
    Check(ProductFieldLabels.TextTypeLabel("NEZNANO_X") == "NEZNANO_X", "Neznana vrsta ostane koda, nic se ne izmislja.");
    Console.WriteLine("Lastnistvo besedil (239) PASS.");
  }

  static void Check(bool condition, string message)
  {
    if (!condition) throw new InvalidOperationException("Lastnistvo besedil: " + message);
  }
}
