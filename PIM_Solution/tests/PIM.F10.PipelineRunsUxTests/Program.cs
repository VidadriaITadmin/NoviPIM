// Pogodbeni test strani /teki-obdelave.
// Pregled strani 2026-09-22: stran je bila starejsi, ozji dvojnik strani »Teki vhodnih podatkov«
// (/zajem/teki) — isti ops.PipelineRun, ena organizacija, brez zalogovnih tekov. Uporabnik je
// potrdil nacrt »podvojene strani odstrani ali zdruzi«. Pot je bila najprej preusmeritev, da stari
// zaznamki ne koncajo s 404 — uporabnik je preusmeritev zavrnil, zato je stran izbrisana.

var root = FindRoot();
var pages = Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages");
// Stran je izbrisana (uporabnik 2026-09-23: »preusmeritev je bv — ena stran«), ne preusmerjena.
Assert(!File.Exists(Path.Combine(pages, "PipelineRuns.razor")), "Stran /teki-obdelave ne sme obstajati; teki so na /zajem/teki.");
Assert(!File.Exists(Path.Combine(pages, "PipelineRuns.razor.css")), "Slog odstranjene strani ne sme ostati.");

foreach (var file in Directory.EnumerateFiles(Path.Combine(root, "src", "PIM.Intranet", "Components"), "*.razor", SearchOption.AllDirectories))
{
  Assert(!File.ReadAllText(file).Contains("href=\"teki-obdelave", StringComparison.Ordinal), Path.GetFileName(file) + " ne sme voditi na /teki-obdelave.");
}

Console.WriteLine("F10 pipeline runs UX contract PASS.");

static void Assert(bool condition, string message)
{
  if (!condition) throw new InvalidOperationException(message);
}

// Koren se poišče iz delovne mape in iz mape sestave, da je test neodvisen od načina zagona.
static string FindRoot()
{
  foreach (var start in new[] { Directory.GetCurrentDirectory(), AppContext.BaseDirectory })
  {
    var current = new DirectoryInfo(start);
    while (current is not null)
    {
      if (File.Exists(Path.Combine(current.FullName, "PIM.sln"))) return current.FullName;
      current = current.Parent;
    }
  }

  throw new InvalidOperationException("PIM_Solution ni najden.");
}
