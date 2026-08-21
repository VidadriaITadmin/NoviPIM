using System.Net;
using System.Text;
using PIM.KatalogWorker;

// ----------------------------------------------------------------------------
// F3 SaopApiClient fixture-only tests — no external HTTP, no real DB.
// Every test uses the internal SaopApiClient(SaopSettings, HttpMessageHandler)
// constructor to inject a fake handler.
// ----------------------------------------------------------------------------

static SaopSettings TestSettings(
  int pageSize = 10,
  int maxPages = 100,
  int retryExtra = 0,
  int retryDelayMs = 0) =>
  new()
  {
    BaseUrl = "http://saop.test.local/",
    Username = "testuser",
    Password = "testpass",
    PageSize = pageSize,
    MaxPagesPerEndpoint = maxPages,
    RetryMaxExtraAttempts = retryExtra,
    RetryBaseDelayMilliseconds = retryDelayMs,
    DelayAfterSuccessMilliseconds = 0,
    AcceptUntrustedCertificate = false,
  };

static void Assert(bool condition, string message)
{
  if (!condition) throw new InvalidOperationException(message);
}

// ── 1. EntityType mapping ─────────────────────────────────────────────────
{
  var generalData = SaopEndpoints.Find(SaopEndpoints.GetItemsGeneralData)!;
  Assert(generalData.EntityType == "ItemGeneralData",
    $"GetItemsGeneralData.EntityType must be 'ItemGeneralData', got '{generalData.EntityType}'.");

  var prices = SaopEndpoints.Find(SaopEndpoints.GetPrices)!;
  Assert(prices.EntityType == "Prices",
    $"GetPrices.EntityType must be 'Prices', got '{prices.EntityType}'.");

  var descriptions = SaopEndpoints.Find(SaopEndpoints.GetItemsDescriptions)!;
  Assert(descriptions.EntityType == "Descriptions",
    $"GetItemsDescriptions.EntityType must be 'Descriptions', got '{descriptions.EntityType}'.");

  // Endpoints where Key == EntityType must default to Key.
  var currencies = SaopEndpoints.Find(SaopEndpoints.Currencies)!;
  Assert(currencies.EntityType == currencies.Key,
    $"Currencies.EntityType must default to Key, got '{currencies.EntityType}'.");

  Console.WriteLine("1. EntityType mapping: OK");
}

// ── 2. Basic auth header shape ────────────────────────────────────────────
{
  HttpRequestMessage? captured = null;
  using var client = new SaopApiClient(TestSettings(), new LambdaHandler(req =>
  {
    captured = req;
    return OkXml("<root />");
  }));

  var endpoint = SaopEndpoints.Find(SaopEndpoints.GetLanguages)!;
  await foreach (var _ in client.ReadAsync(endpoint, 42, null, null, null)) { }

  Assert(captured is not null, "No HTTP request was made.");
  var auth = captured!.Headers.Authorization;
  Assert(auth is not null, "Authorization header is missing.");
  Assert(auth!.Scheme == "Basic", $"Expected Basic scheme, got '{auth.Scheme}'.");
  var decoded = Encoding.ASCII.GetString(Convert.FromBase64String(auth.Parameter!));
  Assert(decoded == "testuser:testpass", $"Decoded credentials wrong: '{decoded}'.");

  Console.WriteLine("2. Basic auth header: OK");
}

// ── 3. OrganisationId header + Accept header ──────────────────────────────
{
  HttpRequestMessage? captured = null;
  using var client = new SaopApiClient(TestSettings(), new LambdaHandler(req =>
  {
    captured = req;
    return OkXml("<root />");
  }));

  var endpoint = SaopEndpoints.Find(SaopEndpoints.GetLanguages)!;
  await foreach (var _ in client.ReadAsync(endpoint, 99, null, null, null)) { }

  Assert(captured!.Headers.Contains("OrganisationId"), "OrganisationId header is missing.");
  Assert(captured.Headers.GetValues("OrganisationId").Single() == "99",
    "OrganisationId header has wrong value.");
  Assert(captured.Headers.Accept.Any(h => h.MediaType == "application/xml"),
    "Accept: application/xml header is missing.");

  Console.WriteLine("3. OrganisationId + Accept headers: OK");
}

// ── 4. Paged endpoint query parameters ────────────────────────────────────
{
  var requests = new List<Uri>();
  using var client = new SaopApiClient(TestSettings(pageSize: 50), new LambdaHandler(req =>
  {
    requests.Add(req.RequestUri!);
    return OkXml("<root />");  // 0 records → first page is last
  }));

  var endpoint = SaopEndpoints.Find(SaopEndpoints.GetItemsGeneralData)!;
  await foreach (var _ in client.ReadAsync(endpoint, 1, null, null, null)) { }

  Assert(requests.Count == 1, $"Expected 1 request, got {requests.Count}.");
  var query = requests[0].Query;
  Assert(query.Contains("searchQuery.page=1"), $"Missing page param in '{query}'.");
  Assert(query.Contains("searchQuery.pageSize=50"), $"Missing pageSize param in '{query}'.");

  Console.WriteLine("4. Paged query params: OK");
}

// ── 5. Prices endpoint includes priceListID + priceListDate ───────────────
{
  var requests = new List<Uri>();
  using var client = new SaopApiClient(TestSettings(pageSize: 10), new LambdaHandler(req =>
  {
    requests.Add(req.RequestUri!);
    return OkXml("<root />");
  }));

  var endpoint = SaopEndpoints.Find(SaopEndpoints.GetPrices)!;
  await foreach (var _ in client.ReadAsync(endpoint, 1, null, "PL-001", new DateTime(2026, 1, 15), default)) { }

  Assert(requests.Count == 1, "Expected 1 request.");
  var query = Uri.UnescapeDataString(requests[0].Query);
  Assert(query.Contains("searchQuery.priceListID=PL-001"),
    $"Missing priceListID in '{query}'.");
  Assert(query.Contains("searchQuery.priceListDate=2026-01-15"),
    $"Missing priceListDate in '{query}'.");

  Console.WriteLine("5. Prices query params: OK");
}

// ── 6. Retry on transient error (503 × 2, then 200) ──────────────────────
{
  var callCount = 0;
  using var client = new SaopApiClient(
    TestSettings(retryExtra: 2, retryDelayMs: 1),
    new LambdaHandler(_ =>
    {
      callCount++;
      return callCount <= 2
        ? new HttpResponseMessage(HttpStatusCode.ServiceUnavailable)
        : OkXml("<root />");
    }));

  var endpoint = SaopEndpoints.Find(SaopEndpoints.GetLanguages)!;
  await foreach (var _ in client.ReadAsync(endpoint, 1, null, null, null)) { }

  Assert(callCount == 3, $"Expected 3 attempts (2 retries + 1 success), got {callCount}.");

  Console.WriteLine("6. Retry on 503: OK");
}

// ── 7. Malformed XML on HTTP 200 — fails endpoint, preserves raw payload ──
{
  const string malformedXml = "<not-closed";
  using var client = new SaopApiClient(TestSettings(), new LambdaHandler(_ =>
    new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(malformedXml) }));

  var endpoint = SaopEndpoints.Find(SaopEndpoints.GetItemsGeneralData)!;
  var yielded = new List<SaopPage>();
  Exception? thrown = null;
  try
  {
    await foreach (var page in client.ReadAsync(endpoint, 1, null, null, null))
    {
      yielded.Add(page);
    }
  }
  catch (Exception ex)
  {
    thrown = ex;
  }

  Assert(thrown is not null, "Malformed XML was silently treated as empty — no exception thrown.");
  Assert(yielded.Count == 1,
    $"Malformed page must be yielded for raw.Inbox preservation (got {yielded.Count} pages).");
  Assert(yielded[0].PayloadXml == malformedXml,
    "Malformed payload must not be modified before preservation.");

  Console.WriteLine("7. Malformed XML behavior: OK");
}

// ── 8. Max page guard — throws when final page is full ────────────────────
{
  var fullXml = "<root>" + string.Concat(Enumerable.Range(1, 5).Select(i => $"<item>{i}</item>")) + "</root>";
  using var client = new SaopApiClient(TestSettings(pageSize: 5, maxPages: 2), new LambdaHandler(_ => OkXml(fullXml)));

  var endpoint = SaopEndpoints.Find(SaopEndpoints.GetItemsGeneralData)!;
  Exception? thrown = null;
  var pageCount = 0;
  try
  {
    await foreach (var _ in client.ReadAsync(endpoint, 1, null, null, null))
    {
      pageCount++;
    }
  }
  catch (Exception ex)
  {
    thrown = ex;
  }

  Assert(thrown is not null,
    $"MaxPagesPerEndpoint guard did not throw (got {pageCount} pages, no exception).");
  Assert(pageCount == 2, $"Expected exactly 2 pages yielded before guard fires, got {pageCount}.");

  Console.WriteLine("8. MaxPagesPerEndpoint guard: OK");
}

// ── 9. Currencies-only: exactly 1 HTTP request, no priceListID ───────────
{
  var requests = new List<Uri>();
  using var client = new SaopApiClient(TestSettings(), new LambdaHandler(req =>
  {
    requests.Add(req.RequestUri!);
    return OkXml("<ArrayOfCurrency />");
  }));

  var endpoint = SaopEndpoints.Find(SaopEndpoints.Currencies)!;
  await foreach (var _ in client.ReadAsync(endpoint, 1, null, null, null)) { }

  Assert(requests.Count == 1,
    $"Currencies-only must make exactly 1 HTTP request, made {requests.Count}.");
  Assert(!requests[0].Query.Contains("priceListID"),
    "Currencies request must not include priceListID.");

  Console.WriteLine("9. Currencies-only: 1 request, no priceListID: OK");
}

// ── 10. TLS default secure ────────────────────────────────────────────────
{
  var defaults = new SaopSettings();
  Assert(!defaults.AcceptUntrustedCertificate,
    "SaopSettings.AcceptUntrustedCertificate must default to false.");

  Console.WriteLine("10. TLS default (AcceptUntrustedCertificate=false): OK");
}

// ── 11. NeedsPriceListResolution logic ────────────────────────────────────
{
  var currencies = SaopEndpoints.Find(SaopEndpoints.Currencies)!;
  var pricesEndpoint = SaopEndpoints.Find(SaopEndpoints.GetPrices)!;
  var generalData = SaopEndpoints.Find(SaopEndpoints.GetItemsGeneralData)!;

  Assert(!SaopIngestRunner.NeedsPriceListResolution([]),
    "Empty endpoint list must not need PriceLists.");
  Assert(!SaopIngestRunner.NeedsPriceListResolution([currencies]),
    "Currencies-only must not need PriceLists.");
  Assert(!SaopIngestRunner.NeedsPriceListResolution([generalData, currencies]),
    "Paged+Lookup without GetPrices must not need PriceLists.");
  Assert(SaopIngestRunner.NeedsPriceListResolution([pricesEndpoint]),
    "GetPrices endpoint must need PriceLists.");
  Assert(SaopIngestRunner.NeedsPriceListResolution([currencies, pricesEndpoint, generalData]),
    "Mixed list with GetPrices must need PriceLists.");

  Console.WriteLine("11. NeedsPriceListResolution: OK");
}

// ── 12. WorkerArguments — valid parsing ──────────────────────────────────
{
  var parsed = WorkerArguments.Parse(["--endpoints", "GetPrices,Currencies", "--organizations", "2", "--full", "--only-ingest"]);
  Assert(parsed.EndpointKeys.Count == 2, $"Expected 2 endpoint keys, got {parsed.EndpointKeys.Count}.");
  Assert(parsed.EndpointKeys.Contains("GetPrices"), "Expected 'GetPrices' in endpoint keys.");
  Assert(parsed.EndpointKeys.Contains("Currencies"), "Expected 'Currencies' in endpoint keys.");
  Assert(parsed.OrganizationIds.Contains(2), "Expected org ID 2.");
  Assert(parsed.FullSync, "Expected FullSync=true.");
  Assert(parsed.SkipMapping, "Expected SkipMapping=true.");
  Assert(!parsed.ShowHelp, "Expected ShowHelp=false.");

  Console.WriteLine("12. WorkerArguments valid parse: OK");
}

// ── 13. WorkerArguments — unknown flag rejected ───────────────────────────
{
  Exception? thrown = null;
  try { WorkerArguments.Parse(["--bogus"]); }
  catch (ArgumentException ex) { thrown = ex; }
  Assert(thrown is not null, "Unknown flag '--bogus' must throw ArgumentException.");

  Console.WriteLine("13. WorkerArguments unknown flag: OK");
}

// ── 14. WorkerArguments — missing value after --endpoints ─────────────────
{
  Exception? thrown = null;
  try { WorkerArguments.Parse(["--endpoints"]); }
  catch (ArgumentException ex) { thrown = ex; }
  Assert(thrown is not null, "'--endpoints' with no following value must throw.");

  Exception? thrown2 = null;
  try { WorkerArguments.Parse(["--organizations"]); }
  catch (ArgumentException ex) { thrown2 = ex; }
  Assert(thrown2 is not null, "'--organizations' with no following value must throw.");

  Console.WriteLine("14. WorkerArguments missing value: OK");
}

// ── 15. WorkerArguments — invalid org ID rejected ─────────────────────────
{
  Exception? thrown = null;
  try { WorkerArguments.Parse(["--organizations", "abc"]); }
  catch (ArgumentException ex) { thrown = ex; }
  Assert(thrown is not null, "Non-integer org ID 'abc' must throw.");

  Exception? thrown2 = null;
  try { WorkerArguments.Parse(["--organizations", "0"]); }
  catch (ArgumentException ex) { thrown2 = ex; }
  Assert(thrown2 is not null, "Zero org ID must throw.");

  Console.WriteLine("15. WorkerArguments invalid org ID: OK");
}

// ── 16. WorkerArguments — positional token rejected ───────────────────────
{
  Exception? thrown = null;
  try { WorkerArguments.Parse(["GetPrices"]); }
  catch (ArgumentException ex) { thrown = ex; }
  Assert(thrown is not null, "Positional token 'GetPrices' (no --) must throw.");

  Console.WriteLine("16. WorkerArguments positional token: OK");
}

// ── 17. GetPrices — empty price-list IDs yields failed EndpointResult ─────
{
  var pricesEndpoint = SaopEndpoints.Find(SaopEndpoints.GetPrices)!;
  var currencies = SaopEndpoints.Find(SaopEndpoints.Currencies)!;

  // Empty price list → error message returned, watermark guard triggered.
  var err = SaopIngestRunner.PricesUnavailableError(pricesEndpoint.Kind, []);
  Assert(err is not null, "PricesUnavailableError must return an error for Prices + empty list.");
  Assert(err!.Contains("GetPrices"), $"Error message must mention 'GetPrices', got: '{err}'.");

  // Non-Prices endpoint → no error regardless of price list.
  var noErr = SaopIngestRunner.PricesUnavailableError(currencies.Kind, []);
  Assert(noErr is null, "PricesUnavailableError must return null for a non-Prices endpoint.");

  // Prices with actual IDs → no error.
  var withIds = SaopIngestRunner.PricesUnavailableError(pricesEndpoint.Kind, ["PL-001", "PL-002"]);
  Assert(withIds is null, "PricesUnavailableError must return null when price list IDs are provided.");

  Console.WriteLine("17. GetPrices empty-price-list failure guard: OK");
}

// ── 18. Mejnik se ne premakne za zajem brez preslikave ────────────────────
// Zajeta stran brez aktivne map.EntityMapping/map.FieldMapping ostane v raw.Inbox
// (SqlMappingPipeline.ReadInboxesAsync jo veže z INNER JOIN). Če bi se mejnik kljub temu
// premaknil, bi ob pozneje dodani preslikavi to obdobje ostalo trajno preskočeno.
{
  var mapped = new EndpointResult("GetItemsGeneralData", "ItemGeneralData", 3, 2500, null);
  Assert(mapped.Succeeded, "Zajem brez napake mora biti uspešen.");
  Assert(mapped.WatermarkAdvanced, "Preslikana končna točka mora premakniti mejnik.");
  Assert(!mapped.AwaitingMapping, "Preslikana končna točka ne čaka na preslikavo.");

  var awaiting = new EndpointResult("GetItemsPlanningData", "GetItemsPlanningData", 4, 1200, null, WatermarkAdvanced: false);
  Assert(awaiting.Succeeded, "Zajem brez preslikave je vseeno uspel — to ni napaka zajema.");
  Assert(!awaiting.WatermarkAdvanced, "Brez preslikave se mejnik NE sme premakniti.");
  Assert(awaiting.AwaitingMapping, "Uspešen zajem brez premika mejnika pomeni čakanje na preslikavo.");

  var failedResult = new EndpointResult("GetPrices", "Prices", 0, 0, "HTTP 503", WatermarkAdvanced: false);
  Assert(!failedResult.Succeeded, "Rezultat z napako ne sme biti uspešen.");
  Assert(!failedResult.AwaitingMapping, "Padli zajem ni 'čaka na preslikavo'.");

  var summary = new IngestSummary(2, Guid.NewGuid(), [mapped, awaiting, failedResult]);
  Assert(summary.AwaitingMappingCount == 1,
    $"Natanko ena končna točka čaka na preslikavo, dobil {summary.AwaitingMappingCount}.");

  // Zajem brez preslikave sam po sebi ne sme obarvati zagona rdeče.
  var cleanSummary = new IngestSummary(2, Guid.NewGuid(), [mapped, awaiting]);
  Assert(cleanSummary.AllSucceeded, "Zajem brez preslikave ne sme šteti kot padec zagona.");
  Assert(cleanSummary.AwaitingMappingCount == 1, "Tudi brez napake se dolg preslikave prešteje.");

  Console.WriteLine("18. Mejnik ostane na mestu brez preslikave: OK");
}

// ── 19. Manjkajoč cenik ne premakne mejnika ───────────────────────────────
// PricesUnavailableError vrne napako pred zajemom; rezultat mora to pokazati tudi na mejniku.
{
  var pricesEndpoint = SaopEndpoints.Find(SaopEndpoints.GetPrices)!;
  var error = SaopIngestRunner.PricesUnavailableError(pricesEndpoint.Kind, []);
  var result = new EndpointResult(pricesEndpoint.Key, pricesEndpoint.EntityType, 0, 0, error, WatermarkAdvanced: false);
  Assert(!result.WatermarkAdvanced, "Brez cenika se mejnik ne sme premakniti.");
  Assert(!result.Succeeded, "Brez cenika je rezultat napaka.");

  Console.WriteLine("19. Manjkajoč cenik ne premakne mejnika: OK");
}

// ── 20. Padec enega podjetja ne ustavi ostalih ────────────────────────────
// Prej je ops.BeginRun stal zunaj try: podjetje brez razporeda (51100) je ubilo worker in
// podjetja za njim sploh niso prišla na vrsto.
{
  var organizations = new List<SaopOrganization>
  {
    new(1, "Prvo", "SAOP_PRVO"),
    new(2, "Drugo", "SAOP_DRUGO"),
    new(3, "Tretje", "SAOP_TRETJE")
  };

  // (a) beginAsync pade za drugo podjetje — prvo in tretje morata vseeno opraviti delo.
  {
    var begun = new List<int>();
    var worked = new List<int>();
    var reported = new List<int>();

    var failed = await OrganizationLoop.RunAsync<object>(
      organizations,
      beginAsync: organization =>
      {
        begun.Add(organization.Id);
        return organization.Id == 2
          ? throw new InvalidOperationException("51100 Razpored ni omogočen.")
          : Task.FromResult<object>(new object());
      },
      workAsync: (organization, _) => { worked.Add(organization.Id); return Task.FromResult(true); },
      completeAsync: (_, _, _) => Task.CompletedTask,
      disposeAsync: _ => Task.CompletedTask,
      reportFailure: (organization, _) => reported.Add(organization.Id));

    Assert(begun.SequenceEqual([1, 2, 3]), $"Vsa tri podjetja morajo biti poskušana, dobil [{string.Join(",", begun)}].");
    Assert(worked.SequenceEqual([1, 3]), $"Delo mora teči za 1 in 3, dobil [{string.Join(",", worked)}].");
    Assert(reported.SequenceEqual([2]), $"Napaka mora biti javljena samo za 2, dobil [{string.Join(",", reported)}].");
    Assert(failed, "Padec enega podjetja mora obarvati celoten zagon kot neuspešen.");
  }

  // (b) workAsync pade za prvo podjetje — zagon se vseeno zaključi in ostala se izvedejo.
  {
    var worked = new List<int>();
    var completedAs = new List<bool>();
    var disposed = new List<string>();
    var index = 0;

    var failed = await OrganizationLoop.RunAsync<string>(
      organizations,
      beginAsync: _ => Task.FromResult($"r{++index}"),
      workAsync: (organization, _) =>
      {
        worked.Add(organization.Id);
        return organization.Id == 1
          ? throw new InvalidOperationException("Zajem je padel.")
          : Task.FromResult(true);
      },
      completeAsync: (_, succeeded, _) => { completedAs.Add(succeeded); return Task.CompletedTask; },
      disposeAsync: run => { disposed.Add(run); return Task.CompletedTask; },
      reportFailure: (_, _) => { });

    Assert(worked.SequenceEqual([1, 2, 3]), $"Vsa tri podjetja morajo priti do dela, dobil [{string.Join(",", worked)}].");
    Assert(completedAs.SequenceEqual([false, true, true]), "Padlo podjetje mora zagon zaključiti kot neuspešen, ostali kot uspešna.");
    Assert(disposed.SequenceEqual(["r1", "r2", "r3"]), "Vsak nastali zagon mora biti pospravljen.");
    Assert(failed, "Padec dela mora obarvati zagon kot neuspešen.");
  }

  // (c) Če beginAsync pade, ni česa zaključiti — completeAsync se za to podjetje ne sme klicati.
  {
    var completeCalls = 0;
    var disposeCalls = 0;

    await OrganizationLoop.RunAsync<object>(
      [new SaopOrganization(9, "Brez razporeda", "SAOP_X")],
      beginAsync: _ => throw new InvalidOperationException("51100"),
      workAsync: (_, _) => Task.FromResult(true),
      completeAsync: (_, _, _) => { completeCalls++; return Task.CompletedTask; },
      disposeAsync: _ => { disposeCalls++; return Task.CompletedTask; },
      reportFailure: (_, _) => { });

    Assert(completeCalls == 0, $"Neobstoječega zagona ni mogoče zaključiti; klicev={completeCalls}.");
    Assert(disposeCalls == 0, $"Neobstoječega zagona ni mogoče pospraviti; klicev={disposeCalls}.");
  }

  // (d) Vsa podjetja uspejo → zagon je zelen.
  {
    var failed = await OrganizationLoop.RunAsync<object>(
      organizations,
      beginAsync: _ => Task.FromResult<object>(new object()),
      workAsync: (_, _) => Task.FromResult(true),
      completeAsync: (_, _, _) => Task.CompletedTask,
      disposeAsync: _ => Task.CompletedTask,
      reportFailure: (_, _) => { });

    Assert(!failed, "Brez napak mora zanka javiti uspeh.");
  }

  // (e) Vzporedno: ista zaveza mora veljati tudi, kadar podjetja tecejo hkrati, hkratnost pa
  //     ne sme preseci dane meje. To je pomembno navzven — meja je edino, kar SAOP varuje
  //     pred tem, da bi mu poslali stiri hkratne polne zajeme.
  {
    var worked = new List<int>();
    var reported = new List<int>();
    var running = 0;
    var peak = 0;
    var gate = new object();

    var failed = await OrganizationLoop.RunAsync<object>(
      organizations,
      beginAsync: _ => Task.FromResult<object>(new object()),
      workAsync: async (organization, _) =>
      {
        lock (gate) { running++; peak = Math.Max(peak, running); }
        await Task.Delay(30);
        lock (gate) { worked.Add(organization.Id); running--; }
        if (organization.Id == 2) throw new InvalidOperationException("Zajem drugega podjetja je padel.");
        return true;
      },
      completeAsync: (_, _, _) => Task.CompletedTask,
      disposeAsync: _ => Task.CompletedTask,
      reportFailure: (organization, _) => { lock (gate) { reported.Add(organization.Id); } },
      maxParallel: 2);

    Assert(worked.Count == 3, $"Vsa tri podjetja morajo priti do dela, dobil {worked.Count}.");
    Assert(reported.SequenceEqual([2]), $"Napaka mora biti javljena samo za 2, dobil [{string.Join(",", reported)}].");
    Assert(failed, "Padec enega podjetja mora obarvati celoten zagon kot neuspesen tudi vzporedno.");
    Assert(peak > 1, $"Pri maxParallel = 2 morata vsaj dve podjetji teci hkrati, najvec hkratnih je bilo {peak}.");
    Assert(peak <= 2, $"Hkratnost je presegla mejo: {peak} > 2. SAOP bi dobil vec zahtevkov, kot je dovoljeno.");
  }

  // (f) maxParallel = 1 ostane natanko to, kar je bilo prej: eno podjetje naenkrat.
  {
    var running = 0;
    var peak = 0;
    var gate = new object();

    await OrganizationLoop.RunAsync<object>(
      organizations,
      beginAsync: _ => Task.FromResult<object>(new object()),
      workAsync: async (_, _) =>
      {
        lock (gate) { running++; peak = Math.Max(peak, running); }
        await Task.Delay(10);
        lock (gate) { running--; }
        return true;
      },
      completeAsync: (_, _, _) => Task.CompletedTask,
      disposeAsync: _ => Task.CompletedTask,
      reportFailure: (_, _) => { },
      maxParallel: 1);

    Assert(peak == 1, $"Privzeto mora teci eno podjetje naenkrat, najvec hkratnih je bilo {peak}.");
  }

  Console.WriteLine("20. Padec enega podjetja ne ustavi ostalih, tudi vzporedno: OK");
}

Console.WriteLine("\nF3 SaopClient testi so uspešni.");
return 0;

static HttpResponseMessage OkXml(string xml) =>
  new(HttpStatusCode.OK) { Content = new StringContent(xml) };

sealed class LambdaHandler(Func<HttpRequestMessage, HttpResponseMessage> response) : HttpMessageHandler
{
  protected override Task<HttpResponseMessage> SendAsync(
    HttpRequestMessage request, CancellationToken cancellationToken) =>
    Task.FromResult(response(request));
}
