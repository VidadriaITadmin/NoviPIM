using System.Diagnostics;
using System.Xml.Linq;
using Microsoft.Data.SqlClient;
using PIM.Operations;
using PIM.SaopAnalyticsWorker;

/*
  PIM.SaopAnalyticsWorker — zajem podatkov za analitiko prodaje, zalog in nabave (migracija 284).

  Iz SAOP bere SAMO z GET klici (nikoli ne piše v SAOP):
    RACUNI                 Invoice/GetInvoices      vrstice izdanih računov = dejanska prodaja
    NAROCILA_KUPCEV        Barkawi/GetCO            naročila kupcev: naročeno, odpremljeno, datumi
    NAROCILA_DOBAVITELJEM  Barkawi/GetPO            naročila dobaviteljem z datumom prevzema -> dobavni čas
    NABAVNI_PODATKI        Barkawi/GetSKU           povprečna/zadnja nabavna cena, dobavitelj, večkratnik
  nato v bazi preračuna kazalnike (ana.RefreshAnalytics: predlogi naročil, zaležana zaloga, trendi).

  Preračun ne potrebuje SAOP: brez PIM_SAOP_MODE=Live (ali brez omrežja) worker preskoči klice in vseeno
  zapiše dnevni posnetek zaloge in preračuna kazalnike iz tega, kar je v bazi. Padec enega toka ne ustavi
  ostalih; vodni žig toka se premakne samo po uspehu.

  Uporabnik 2026-09-24: »naredi worker, ki prebere vse te podatke, da se samo priklopim v omrežje in dobivam
  podatke« — prvi zagon v omrežju naj bo `--preizkus` (majhni klici, vzorci v mapo), nato redni tek.
*/

var options = WorkerOptions.Parse(args);
if (options.Help) { WorkerOptions.PrintUsage(); return 0; }

var connectionString = LocalSettings.ConnectionString();
if (string.IsNullOrWhiteSpace(connectionString) && !options.Probe)
{
  Console.Error.WriteLine(LocalSettings.MissingConnectionMessage());
  return 2;
}

var settings = AnalyticsSettings.Read();
var live = string.Equals(Environment.GetEnvironmentVariable("PIM_SAOP_MODE"), "Live", StringComparison.OrdinalIgnoreCase);
var organizations = settings.Organizations
  .Where(o => o.IsActive && (options.Organizations.Count == 0 || options.Organizations.Contains(o.Id)))
  .ToList();
// Podjetja brez SAOP nastavitve (npr. samo --samo-izracun na bazi brez poverilnic) — vzemi izbrana.
if (organizations.Count == 0 && options.Organizations.Count > 0)
  organizations = options.Organizations.Select(id => new AnalyticsOrganization(id, $"podjetje {id}", true)).ToList();
if (organizations.Count == 0)
{
  Console.Error.WriteLine("Ni nobenega podjetja: dopolni Saop:Organizations v appsettings.Local.json ali podaj --organizations.");
  return 2;
}

if (options.Probe)
{
  if (!settings.HasCredentials) { Console.Error.WriteLine("Za --preizkus manjkajo SAOP poverilnice (sekcija Saop)."); return 2; }
  return await Probe.RunAsync(settings, organizations, options.ProbeFolder);
}

var store = new AnalyticsStore(connectionString!);
var workerId = $"{Environment.MachineName}:{Environment.ProcessId}";
var phases = PhaseLog.FromEnvironment(connectionString, workerId);
const string Pipeline = "SAOP_ANALYTICS";
var fetchFromSaop = !options.ComputeOnly && !options.Reparse;
if (fetchFromSaop && !live) Console.WriteLine("PIM_SAOP_MODE ni Live — SAOP se ne kliče; preračun iz baze teče.");
if (fetchFromSaop && live && !settings.HasCredentials)
{
  Console.Error.WriteLine("Manjkajo SAOP poverilnice (Saop:BaseUrl/Username/Password ali PIM_SAOP_*).");
  return 2;
}

using var client = fetchFromSaop && live ? new SaopAnalyticsClient(settings) : null;
var failedAny = false;
// Prvi omrežni neuspeh (ni povezave, ne HTTP napaka) pomeni, da SAOP ni dosegljiv: ostali klici bi vsak
// čakali ~90 s na enak izid, zato se preskočijo z razlogom, preračun pa vseeno teče.
string? saopUnreachable = null;

foreach (var organization in organizations)
{
  Console.WriteLine($"[{organization.Id}] {organization.Name}");
  OperationsRun run;
  try
  {
    run = await OperationsRun.BeginAsync(connectionString!, organization.Id, Pipeline, workerId);
  }
  catch (SqlException exception) when (exception.Number is 51100 or 51101)
  {
    Console.Error.WriteLine(exception.Number == 51100
      ? $"  Razpored {Pipeline} za podjetje ni omogočen; preskočeno."
      : $"  {Pipeline} že teče; ta zagon se je umaknil.");
    await phases.RecordAsync(PhaseCodes.Fetch, exception.Number == 51100 ? PhaseOutcome.Failed : PhaseOutcome.Skipped,
      AnalyticsStreams.SourceCode("IZRACUN"), organization.Id, Pipeline,
      message: exception.Number == 51100 ? "razpored SAOP_ANALYTICS ni omogočen" : "tek že teče");
    if (exception.Number == 51100) failedAny = true;
    continue;
  }

  await using (run)
  {
    var organizationFailed = false;
    foreach (var stream in options.Streams)
    {
      var source = AnalyticsStreams.SourceCode(stream);
      if (!fetchFromSaop && !options.Reparse) continue;
      if (fetchFromSaop && client is null)
      {
        await phases.RecordAsync(PhaseCodes.Fetch, PhaseOutcome.Skipped, source, organization.Id, Pipeline, run.RunId,
          "PIM_SAOP_MODE ni Live; SAOP ni bil klican");
        continue;
      }
      if (fetchFromSaop && saopUnreachable is not null)
      {
        organizationFailed = true;
        await store.SetStreamStateAsync(organization.Id, stream, false, null, null, $"SAOP ni dosegljiv: {saopUnreachable}", default);
        await phases.RecordAsync(PhaseCodes.Fetch, PhaseOutcome.Failed, source, organization.Id, Pipeline, run.RunId,
          $"preskočeno, SAOP ni dosegljiv ({saopUnreachable})");
        continue;
      }

      var watch = Stopwatch.StartNew();
      try
      {
        var fetchStartedUtc = DateTime.UtcNow;
        var fetch = new StreamFetcher(client, store, settings, organization.Id, run.RunId, options.Full);
        var result = options.Reparse
          ? await fetch.ReparseAsync(stream, options.ReparseDays)
          : await fetch.RunAsync(stream);
        await store.SetStreamStateAsync(organization.Id, stream, true, result.Rows, options.Reparse ? null : fetchStartedUtc, null, default);
        await phases.RecordAsync(PhaseCodes.Fetch, PhaseOutcome.Succeeded, source, organization.Id, Pipeline, run.RunId,
          $"{AnalyticsStreams.Label(stream)}: {result.Describe()} v {watch.Elapsed.TotalSeconds:0} s",
          hasNewData: result.Rows > 0, itemsIn: result.Records, itemsOut: result.Rows);
        Console.WriteLine($"  {AnalyticsStreams.Label(stream)}: {result.Describe()} ({watch.Elapsed.TotalSeconds:0} s)");
        await run.HeartbeatAsync();
      }
      catch (Exception exception) // tudi časovna meja klica (TaskCanceledException) je napaka toka, ne prekinitev workerja
      {
        organizationFailed = true;
        if (exception is HttpRequestException) saopUnreachable = exception.Message;
        Console.Error.WriteLine($"  NAPAKA {AnalyticsStreams.Label(stream)}: {exception.Message}");
        await store.SetStreamStateAsync(organization.Id, stream, false, null, null, exception.Message, default);
        await phases.RecordAsync(PhaseCodes.Fetch, PhaseOutcome.Failed, source, organization.Id, Pipeline, run.RunId, exception.Message);
      }
    }

    // Preračun teče vedno (tudi brez SAOP): dnevni posnetek zaloge in kazalniki iz podatkov v bazi.
    var computeWatch = Stopwatch.StartNew();
    try
    {
      var summary = await store.RefreshAsync(organization.Id, default);
      var message = $"vir prodaje {summary.DemandSource}; artiklov {summary.Items}, za naročilo {summary.ToOrder}, "
        + $"brez zaloge {summary.Stockouts}, zaležanih {summary.Dead}, preveč zaloge {summary.Overstock} ({computeWatch.Elapsed.TotalSeconds:0} s)";
      Console.WriteLine($"  Preračun: {message}");
      await phases.RecordAsync(PhaseCodes.Compute, PhaseOutcome.Succeeded, AnalyticsStreams.SourceCode("IZRACUN"), organization.Id, Pipeline,
        run.RunId, message, hasNewData: true, itemsOut: summary.Items);
    }
    catch (Exception exception) // tudi časovna meja klica (TaskCanceledException) je napaka toka, ne prekinitev workerja
    {
      organizationFailed = true;
      Console.Error.WriteLine($"  NAPAKA preračuna: {exception.Message}");
      await store.SetStreamStateAsync(organization.Id, "IZRACUN", false, null, null, exception.Message, default);
      await phases.RecordAsync(PhaseCodes.Compute, PhaseOutcome.Failed, AnalyticsStreams.SourceCode("IZRACUN"), organization.Id, Pipeline,
        run.RunId, exception.Message);
    }

    await run.CompleteAsync(!organizationFailed, organizationFailed ? "Vsaj en tok analitike ali preračun je padel; glej faze." : null);
    failedAny |= organizationFailed;
  }
}

return failedAny ? 1 : 0;

/// <summary>Izid enega toka.</summary>
sealed record StreamResult(int Calls, int Records, int Rows, string Unit)
{
  public string Describe() => $"{Calls} klicev, {Records} zapisov, {Rows} {Unit}";
}

/// <summary>Zajem enega toka iz SAOP (ali ponovna razčlenitev shranjenih strani) in zapis v ana.</summary>
sealed class StreamFetcher(SaopAnalyticsClient? client, AnalyticsStore store, AnalyticsSettings settings, int organizationId, Guid runId, bool full)
{
  /// <summary>Surova stran nad to velikostjo se ne shrani (račun za celo leto je lahko več deset MB).</summary>
  const int MaxStoredPageChars = 20_000_000;

  public async Task<StreamResult> RunAsync(string stream)
  {
    if (client is null) throw new InvalidOperationException("SAOP odjemalec ni pripravljen.");
    var watermark = full ? null : await store.ReadWatermarkAsync(organizationId, stream, default);
    var modifiedFrom = watermark?.AddDays(-settings.LookbackDays);
    return stream switch
    {
      AnalyticsStreams.Invoices => await InvoicesAsync(modifiedFrom),
      AnalyticsStreams.CustomerOrders => await BarkawiOrdersAsync(stream, "api/Barkawi/GetCO", modifiedFrom),
      AnalyticsStreams.PurchaseOrders => await BarkawiOrdersAsync(stream, "api/Barkawi/GetPO", modifiedFrom),
      AnalyticsStreams.PurchaseInfo => await SkuAsync(modifiedFrom),
      _ => throw new ArgumentOutOfRangeException(nameof(stream), stream, "Neznan tok."),
    };
  }

  async Task<StreamResult> InvoicesAsync(DateTime? modifiedFrom)
  {
    var urls = new List<string>();
    if (modifiedFrom is null)
    {
      // Prvi zajem: po letih (GetInvoices nima listanja; leto je najmanjša enota, ki jo API sprejme).
      var from = DateTime.Today.AddMonths(-settings.InitialBackfillMonths).Year;
      for (var year = from; year <= DateTime.Today.Year; year++)
        urls.Add(SaopAnalyticsClient.Query("api/Invoice/GetInvoices", ("searchQuery.invoiceYear", year.ToString())));
    }
    else
    {
      urls.Add(SaopAnalyticsClient.Query("api/Invoice/GetInvoices", ("searchQuery.recordDtModifiedFrom", SaopAnalyticsClient.Stamp(modifiedFrom.Value))));
    }

    int calls = 0, invoices = 0, rows = 0, detailCalls = 0;
    var page = 0;
    foreach (var url in urls)
    {
      var xml = await client!.GetAsync(organizationId, url, default);
      calls++;
      var parsed = AnalyticsParsers.ParseInvoices(AnalyticsParsers.Parse(xml, url));
      await SaveAsync(AnalyticsStreams.Invoices, ++page, url, xml, parsed.Invoices);
      invoices += parsed.Invoices;
      rows += await store.UpsertInvoiceLinesAsync(organizationId, parsed.Lines, default);

      // Seznam brez vrstic: vrstice po računu (GetInvoice), z mejo števila klicev.
      foreach (var key in parsed.WithoutLines)
      {
        if (detailCalls >= settings.MaxInvoiceDetailCalls)
          throw new InvalidOperationException($"Dosežena meja MaxInvoiceDetailCalls ({settings.MaxInvoiceDetailCalls}); ostali računi bodo zajeti v naslednjem teku.");
        var detailUrl = $"api/Invoice/GetInvoice/{key.Year}/{Uri.EscapeDataString(key.Book)}/{key.Number}";
        var detailXml = await client.GetAsync(organizationId, detailUrl, default);
        calls++; detailCalls++;
        var detail = AnalyticsParsers.ParseInvoices(AnalyticsParsers.Parse(detailXml, detailUrl));
        rows += await store.UpsertInvoiceLinesAsync(organizationId, detail.Lines, default);
      }
    }
    return new StreamResult(calls, invoices, rows, "vrstic računov");
  }

  async Task<StreamResult> BarkawiOrdersAsync(string stream, string path, DateTime? modifiedFrom)
  {
    var period = modifiedFrom is null ? settings.BarkawiBackfillPeriod : settings.BarkawiDeltaPeriod;
    int calls = 0, orders = 0, rows = 0;
    for (var page = 1; page <= settings.MaxPages; page++)
    {
      var url = SaopAnalyticsClient.Query(path,
        ("searchQuery.period", period.ToString()),
        ("searchQuery.page", page.ToString()),
        ("searchQuery.pageSize", settings.PageSize.ToString()),
        ("searchQuery.recordDtModifiedFrom", modifiedFrom is null ? null : SaopAnalyticsClient.Stamp(modifiedFrom.Value)));
      var xml = await client!.GetAsync(organizationId, url, default);
      calls++;
      var document = AnalyticsParsers.Parse(xml, url);
      int count;
      if (stream == AnalyticsStreams.CustomerOrders)
      {
        var lines = AnalyticsParsers.ParseCustomerOrders(document, out count);
        rows += await store.UpsertCustomerOrderLinesAsync(organizationId, lines, default);
      }
      else
      {
        var lines = AnalyticsParsers.ParsePurchaseOrders(document, out count);
        rows += await store.UpsertPurchaseOrderLinesAsync(organizationId, lines, default);
      }
      await SaveAsync(stream, page, url, xml, count);
      orders += count;
      if (count < settings.PageSize) return new StreamResult(calls, orders, rows, "vrstic naročil");
    }
    throw new InvalidOperationException($"Dosežena varovalka MaxPages ({settings.MaxPages}) za {path}; podatki so verjetno nepopolni.");
  }

  async Task<StreamResult> SkuAsync(DateTime? modifiedFrom)
  {
    int calls = 0, rows = 0;
    for (var page = 1; page <= settings.MaxPages; page++)
    {
      var url = SaopAnalyticsClient.Query("api/Barkawi/GetSKU",
        ("searchQuery.page", page.ToString()),
        ("searchQuery.pageSize", settings.PageSize.ToString()),
        ("searchQuery.recordDtModifiedFrom", modifiedFrom is null ? null : SaopAnalyticsClient.Stamp(modifiedFrom.Value)));
      var xml = await client!.GetAsync(organizationId, url, default);
      calls++;
      var items = AnalyticsParsers.ParseSku(AnalyticsParsers.Parse(xml, url));
      await SaveAsync(AnalyticsStreams.PurchaseInfo, page, url, xml, items.Count);
      rows += await store.UpsertItemPurchaseInfoAsync(organizationId, items, default);
      if (items.Count < settings.PageSize) return new StreamResult(calls, rows, rows, "artiklov");
    }
    throw new InvalidOperationException($"Dosežena varovalka MaxPages ({settings.MaxPages}) za GetSKU; podatki so verjetno nepopolni.");
  }

  /// <summary>Ponovna razčlenitev shranjenih surovih strani (po popravku razčlenjevalnika), brez klica v SAOP.</summary>
  public async Task<StreamResult> ReparseAsync(string stream, int days)
  {
    int pages = 0, records = 0, rows = 0;
    await foreach (var (url, xml) in store.ReadPagesAsync(organizationId, stream, days, default))
    {
      pages++;
      var document = AnalyticsParsers.Parse(xml, url);
      switch (stream)
      {
        case AnalyticsStreams.Invoices:
          var invoices = AnalyticsParsers.ParseInvoices(document);
          records += invoices.Invoices;
          rows += await store.UpsertInvoiceLinesAsync(organizationId, invoices.Lines, default);
          break;
        case AnalyticsStreams.CustomerOrders:
          var co = AnalyticsParsers.ParseCustomerOrders(document, out var coCount);
          records += coCount;
          rows += await store.UpsertCustomerOrderLinesAsync(organizationId, co, default);
          break;
        case AnalyticsStreams.PurchaseOrders:
          var po = AnalyticsParsers.ParsePurchaseOrders(document, out var poCount);
          records += poCount;
          rows += await store.UpsertPurchaseOrderLinesAsync(organizationId, po, default);
          break;
        case AnalyticsStreams.PurchaseInfo:
          var sku = AnalyticsParsers.ParseSku(document);
          records += sku.Count;
          rows += await store.UpsertItemPurchaseInfoAsync(organizationId, sku, default);
          break;
      }
    }
    return new StreamResult(pages, records, rows, "vrstic (ponovna razčlenitev)");
  }

  Task SaveAsync(string stream, int page, string url, string xml, int records) =>
    xml.Length > MaxStoredPageChars
      ? Task.CompletedTask
      : store.SavePageAsync(organizationId, stream, runId, page, url, xml, records, default);
}

/// <summary>
/// Preizkus v omrežju: majhni klici vsake točke (pageSize 5, računi zadnjega dne), vzorci v mapo in izpis,
/// katera polja in datumi so prišli. V bazo ne piše. Iz izpisa se vidi tudi pomen parametra period pri Barkawi.
/// </summary>
static class Probe
{
  public static async Task<int> RunAsync(AnalyticsSettings settings, IReadOnlyList<AnalyticsOrganization> organizations, string folder)
  {
    using var client = new SaopAnalyticsClient(settings with { RetryMaxExtraAttempts = 0, TimeoutSeconds = 120 });
    Console.WriteLine($"SAOP: {client.BaseAddress}");
    var failed = false;
    foreach (var organization in organizations)
    {
      Console.WriteLine($"[{organization.Id}] {organization.Name}");
      var target = Path.Combine(folder, organization.Id.ToString());
      Directory.CreateDirectory(target);
      var since = SaopAnalyticsClient.Stamp(DateTime.Now.AddDays(-2));
      var calls = new (string Name, string Url, Func<XDocument, string> Describe)[]
      {
        ("racuni", SaopAnalyticsClient.Query("api/Invoice/GetInvoices", ("searchQuery.recordDtModifiedFrom", since)), d =>
        {
          var p = AnalyticsParsers.ParseInvoices(d);
          return $"računov {p.Invoices}, vrstic {p.Lines.Count}, brez vrstic {p.WithoutLines.Count}; datumi {Range(p.Lines.Select(l => (DateTime?)l.InvoiceDate))}";
        }),
        ("co-period-1", SaopAnalyticsClient.Query("api/Barkawi/GetCO", ("searchQuery.period", "1"), ("searchQuery.page", "1"), ("searchQuery.pageSize", "5")), d =>
        { var l = AnalyticsParsers.ParseCustomerOrders(d, out var n); return $"naročil {n}, vrstic {l.Count}; datumi {Range(l.Select(x => x.OrderDate))}"; }),
        ($"co-period-{settings.BarkawiBackfillPeriod}", SaopAnalyticsClient.Query("api/Barkawi/GetCO", ("searchQuery.period", settings.BarkawiBackfillPeriod.ToString()), ("searchQuery.page", "1"), ("searchQuery.pageSize", "5")), d =>
        { var l = AnalyticsParsers.ParseCustomerOrders(d, out var n); return $"naročil {n}, vrstic {l.Count}; datumi {Range(l.Select(x => x.OrderDate))}"; }),
        ("po-period-1", SaopAnalyticsClient.Query("api/Barkawi/GetPO", ("searchQuery.period", "1"), ("searchQuery.page", "1"), ("searchQuery.pageSize", "5")), d =>
        { var l = AnalyticsParsers.ParsePurchaseOrders(d, out var n); return $"naročil {n}, vrstic {l.Count}, s prevzemom {l.Count(x => x.ReceivedDate is not null)}; datumi {Range(l.Select(x => x.OrderDate))}"; }),
        ($"po-period-{settings.BarkawiBackfillPeriod}", SaopAnalyticsClient.Query("api/Barkawi/GetPO", ("searchQuery.period", settings.BarkawiBackfillPeriod.ToString()), ("searchQuery.page", "1"), ("searchQuery.pageSize", "5")), d =>
        { var l = AnalyticsParsers.ParsePurchaseOrders(d, out var n); return $"naročil {n}, vrstic {l.Count}, s prevzemom {l.Count(x => x.ReceivedDate is not null)}; datumi {Range(l.Select(x => x.OrderDate))}"; }),
        ("sku", SaopAnalyticsClient.Query("api/Barkawi/GetSKU", ("searchQuery.page", "1"), ("searchQuery.pageSize", "5")), d =>
        { var l = AnalyticsParsers.ParseSku(d); return $"artiklov {l.Count}, s povprečno nabavno ceno {l.Count(x => x.AveragePurchasePrice > 0)}"; }),
      };

      foreach (var (name, url, describe) in calls)
      {
        var watch = Stopwatch.StartNew();
        try
        {
          var xml = await client.GetAsync(organization.Id, url, default);
          await File.WriteAllTextAsync(Path.Combine(target, name + ".xml"), xml);
          var document = AnalyticsParsers.Parse(xml, url);
          var first = document.Root?.Descendants().FirstOrDefault(e => e.Elements().Count() > 3);
          var fields = first is null ? "(ni zapisov)" : string.Join(", ", first.Elements().Select(e => e.Name.LocalName).Take(25));
          Console.WriteLine($"  OK   {name,-16} {watch.ElapsedMilliseconds,6} ms  koren <{document.Root?.Name.LocalName}>  {describe(document)}");
          Console.WriteLine($"       polja: {fields}");
        }
        catch (Exception exception)
        {
          failed = true;
          Console.WriteLine($"  NAPAKA {name,-14} {watch.ElapsedMilliseconds,6} ms  {exception.Message[..Math.Min(300, exception.Message.Length)]}");
        }
      }
      Console.WriteLine($"  Vzorci: {Path.GetFullPath(target)}");
    }
    return failed ? 1 : 0;
  }

  static string Range(IEnumerable<DateTime?> dates)
  {
    var list = dates.Where(d => d is not null).Select(d => d!.Value).ToList();
    return list.Count == 0 ? "-" : $"{list.Min():yyyy-MM-dd} … {list.Max():yyyy-MM-dd}";
  }
}

sealed record WorkerOptions(
  IReadOnlyList<int> Organizations, IReadOnlyList<string> Streams, bool Full, bool ComputeOnly, bool Reparse, int ReparseDays,
  bool Probe, string ProbeFolder, bool Help)
{
  public static WorkerOptions Parse(string[] args)
  {
    string? Value(string name)
    {
      var index = Array.FindIndex(args, a => string.Equals(a, name, StringComparison.OrdinalIgnoreCase));
      return index >= 0 && index + 1 < args.Length ? args[index + 1] : null;
    }
    bool Flag(params string[] names) => args.Any(a => names.Contains(a, StringComparer.OrdinalIgnoreCase));

    var organizations = (Value("--organizations") ?? "")
      .Split([',', ';'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
      .Select(t => int.TryParse(t, out var id) ? id : 0).Where(id => id > 0).ToArray();
    var streams = (Value("--tokovi") ?? "")
      .Split([',', ';'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
      .Select(t => t.ToUpperInvariant()).ToArray();
    var unknown = streams.Except(AnalyticsStreams.All).ToArray();
    if (unknown.Length > 0) throw new ArgumentException($"Neznan tok: {string.Join(", ", unknown)}. Znani: {string.Join(", ", AnalyticsStreams.All)}.");

    return new WorkerOptions(
      organizations,
      streams.Length == 0 ? AnalyticsStreams.All : streams,
      Flag("--full"),
      Flag("--samo-izracun"),
      Flag("--razcleni-znova"),
      int.TryParse(Value("--dni"), out var days) && days > 0 ? days : 30,
      Flag("--preizkus"),
      Value("--mapa") ?? Path.Combine(Environment.CurrentDirectory, "analitika-preizkus"),
      Flag("--help", "-h"));
  }

  public static void PrintUsage() => Console.WriteLine("""
    PIM.SaopAnalyticsWorker — zajem prodaje, naročil in nabavnih podatkov iz SAOP ter preračun analitike.

      --organizations 2,3     samo našteta podjetja (privzeto vsa aktivna iz Saop:Organizations)
      --tokovi RACUNI,...     samo našteti tokovi: RACUNI, NAROCILA_KUPCEV, NAROCILA_DOBAVITELJEM, NABAVNI_PODATKI
      --full                  prezri vodni žig: prvi zajem znova (Analitika:InitialBackfillMonths, BarkawiBackfillPeriod)
      --samo-izracun          brez SAOP: posnetek zaloge in preračun kazalnikov iz baze
      --razcleni-znova [--dni 30]  brez SAOP: znova razčleni shranjene surove odgovore (ana.SourcePage)
      --preizkus [--mapa pot] majhni klici vseh točk, vzorci XML v mapo, izpis polj; v bazo ne piše
      --help                  ta izpis

    Klic v SAOP samo s PIM_SAOP_MODE=Live (človekova odločitev, AGENTS.md §4.5); sicer samo preračun.
    Worker v SAOP nikoli ne piše: vse točke so GET. Razpored: SAOP_ANALYTICS (ops.ScheduleProfile).
    """);
}
