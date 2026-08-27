using System.ComponentModel;

namespace PIM.Intranet.Services;

public enum PimCheckCode
{
  [Description("Manjka aktivna cena B2C")] CENA_MANJKA_B2C,
  [Description("Manjka aktivna cena B2B")] CENA_MANJKA_B2B,
  [Description("Aktivna cena je nič")] CENA_NIC,
  [Description("Manjka pričakovana stopnja DDV")] DDV_MANJKA,
  [Description("Cenik še ne velja ali je potekel")] CENIK_POTEKEL,
  [Description("Podvojen aktivni zapis cene")] PODVOJEN_ZAPIS,
  [Description("Faktor prodajne in prevzemne cene je pod pragom")] FAKTOR_MARZE,
  [Description("Prodajna cena je pod nabavno")] CENA_POD_NABAVNO,
  [Description("Ni zaloge niti napovedanega prihoda")] BREZ_ZALOGE_BREZ_PRIHODA,
  [Description("Zaloga je pod minimalnim pragom")] ZALOGA_POD_MIN,
  [Description("Zalogovni posnetek je zastarel")] POSNETEK_ZASTAREL,
  [Description("Zalogovne pozicije ni mogoče povezati z artiklom")] POZICIJA_BREZ_ARTIKLA,
}

public static class PimCheckCodes
{
  public const decimal DefaultMarginFactor = 2m;

  public static bool IsPrice(PimCheckCode code) => code <= PimCheckCode.CENA_POD_NABAVNO;

  public static string Description(PimCheckCode code)
  {
    var member = typeof(PimCheckCode).GetMember(code.ToString()).Single();
    return member.GetCustomAttributes(typeof(DescriptionAttribute), false)
      .Cast<DescriptionAttribute>().Single().Description;
  }
}
