using System.Runtime.CompilerServices;
using PIM.Intranet.Services;

/// <summary>
/// Stanje uvoza v zgodovini (naloga #66). Preverjalec je na /uvozi/12 videl paketno spremembo cen, katere serija v vrsti
/// za SAOP je bila v celoti preklicana, pa je stala kot »uveljavljen«, ponujala povratek, stolpec Kam je kazal
/// »PIM + vrsta za SAOP« in števec je štel 12 sporočil namesto 3 cen.
///
/// Zažene se kot inicializator modula (pred Program.cs), da ta datoteka ne posega v Program.cs, ki ga ureja druga naloga.
/// </summary>
static class ImportRunStatusChecks
{
  [ModuleInitializer]
  internal static void Run()
  {
    ImportRunRow Row(string kind, long? undoOf = null, long? undoneBy = null) =>
      new(12, kind, "Paketna sprememba cen", null, "test", DateTime.UtcNow, 3, 6, 3, "230", undoOf, undoneBy, null, null, null);

    var cancelledPrices = ImportKinds.StatusOf(Row(ImportKinds.Prices), new ImportQueueState(0, 0, 3));
    Check(cancelledPrices.Text == "preklican" && !cancelledPrices.UndoOffered,
      "Cene, v celoti preklicane v vrsti: stanje »preklican«, brez povratka.");
    Check(cancelledPrices.Explanation?.Contains("3 cene", StringComparison.Ordinal) == true
      && cancelledPrices.Explanation.Contains("povratek ni potreben", StringComparison.Ordinal),
      "Preklican uvoz cen pove, koliko cen in da povratek ni potreben.");

    var cancelledProducts = ImportKinds.StatusOf(Row(ImportKinds.Products), new ImportQueueState(0, 0, 5));
    Check(cancelledProducts.UndoOffered && cancelledProducts.Text.StartsWith("uveljavljen", StringComparison.Ordinal),
      "Izdelki so zapisani v PIM: preklic SAOP dela ne sme skriti povratka.");

    var partly = ImportKinds.StatusOf(Row(ImportKinds.Prices), new ImportQueueState(0, 1, 2));
    Check(partly.Text == "delno preklican" && partly.UndoOffered, "Del v SAOP, del preklican: »delno preklican«, povratek ostane.");

    var waiting = ImportKinds.StatusOf(Row(ImportKinds.Prices), new ImportQueueState(1, 0, 2));
    Check(waiting.Text == "uveljavljen" && waiting.UndoOffered, "Dokler kaj čaka, uvoz ni preklican.");

    var dead = ImportKinds.StatusOf(Row(ImportKinds.Prices), new ImportQueueState(0, 0, 2, Failed: 1));
    Check(dead.UndoOffered && dead.Text != "preklican", "Neuspelo sporočilo ni preklic — ne razglasi »preklican«.");

    Check(ImportKinds.StatusOf(Row(ImportKinds.Prices), null).Text == "uveljavljen", "Brez vrste ostane »uveljavljen«.");
    Check(ImportKinds.StatusOf(Row(ImportKinds.Prices, undoneBy: 13), new ImportQueueState(0, 0, 3)) is { UndoOffered: false } undone
      && undone.Text.StartsWith("povrnjen", StringComparison.Ordinal), "Povrnjen uvoz ostane »povrnjen«.");

    Check(ImportKinds.Where(ImportKinds.Prices, "SAOP") == "vrsta za SAOP", "Cene v PIM ne pišejo: Kam = »vrsta za SAOP«.");
    Check(ImportKinds.Where(ImportKinds.Products, "SAOP") == "PIM + vrsta za SAOP", "Izdelki SAOP polja zapišejo tudi v PIM.");
    Check(ImportKinds.Where(ImportKinds.Products, "PIM") == "PIM", "PIM polje ostane »PIM«.");
    Check(ImportKinds.QueueUnit(ImportKinds.Prices, 3) == "3 cene" && ImportKinds.QueueUnit(ImportKinds.Prices, 1) == "1 cena"
      && ImportKinds.QueueUnit(ImportKinds.Products, 5) == "5 artiklov", "Števec v vrsti šteje cene / artikle s sklanjatvijo.");

    var root = SolutionRoot();
    var pages = Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages");
    var view = File.ReadAllText(Path.Combine(pages, "ImportRunView.razor"));
    var list = File.ReadAllText(Path.Combine(pages, "ImportHistory.razor"));
    var service = File.ReadAllText(Path.Combine(root, "src", "PIM.Intranet", "Services", "ImportHistoryService.cs"));
    Check(!view.Contains("Text=\"uveljavljen\"", StringComparison.Ordinal) && view.Contains("ImportKinds.StatusOf(", StringComparison.Ordinal),
      "/uvozi/{Id} ne sme izpisati »uveljavljen« brez stanja v vrsti.");
    Check(view.Contains("Status.UndoOffered", StringComparison.Ordinal), "/uvozi/{Id} skrije povratek, ko ni potreben.");
    Check(!view.Contains("\"PIM + vrsta za SAOP\" : \"PIM\"", StringComparison.Ordinal), "Kam se ne sme več trdo izpisati za vse vrste.");
    Check(!view.Contains("sporočil tega uvoza", StringComparison.Ordinal), "Števec ne šteje sporočil po polju.");
    Check(list.Contains("GetQueueStatesAsync(Runs)", StringComparison.Ordinal) && !list.Contains("GetQueueStateAsync(", StringComparison.Ordinal),
      "/uvozi dobi stanje vrste z eno poizvedbo za vse vrstice, ne na vrstico.");
    Check(service.Contains("message.EntityKey", StringComparison.Ordinal) && service.Contains("OPENJSON(@Pairs)", StringComparison.Ordinal),
      "Stanje vrste šteje zapise (ključ sporočila), za vse uvoze naenkrat.");
    Console.WriteLine("Stanje uvoza v zgodovini (#66) PASS.");
  }

  static string SolutionRoot()
  {
    var directory = new DirectoryInfo(AppContext.BaseDirectory);
    while (directory is not null && !File.Exists(Path.Combine(directory.FullName, "PIM.sln"))) directory = directory.Parent;
    return directory?.FullName ?? throw new InvalidOperationException("PIM.sln ni najden.");
  }

  static void Check(bool condition, string message)
  {
    if (!condition) throw new InvalidOperationException("Stanje uvoza (#66): " + message);
  }
}
