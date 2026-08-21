using System.Data;
using System.Globalization;
using System.Runtime.CompilerServices;
using System.Xml.Linq;
using Microsoft.Data.SqlClient;

[assembly: InternalsVisibleTo("PIM.F3.SaopClientTests")]
[assembly: InternalsVisibleTo("PIM.F3.Integration")]

namespace PIM.KatalogWorker;

/// <param name="WatermarkAdvanced">
/// Ali je bil po tej končni točki mejnik premaknjen. False pomeni, da mora naslednji zagon
/// isto obdobje zajeti znova — bodisi ker je zajem padel, bodisi ker zajetega podatka
/// (še) ni mogoče preslikati.
/// </param>
public sealed record EndpointResult(
  string EndpointKey,
  string EntityType,
  int Pages,
  int Records,
  string? Error,
  bool WatermarkAdvanced = true,
  string? WatermarkHold = null,
  int PendingBacklog = 0,
  long DurationMs = 0)
{
  public bool Succeeded => Error is null;

  /// <summary>Zajem je uspel, a mejnik ni šel naprej — podatek leži v raw.Inbox in čaka.</summary>
  public bool AwaitingMapping => Succeeded && !WatermarkAdvanced;
}

public sealed record IngestSummary(int OrganizationId, Guid RunId, IReadOnlyList<EndpointResult> Endpoints, DateTime StartedUtc = default)
{
  public int TotalRecords => Endpoints.Sum(endpoint => endpoint.Records);
  public int TotalPages => Endpoints.Sum(endpoint => endpoint.Pages);
  public bool AllSucceeded => Endpoints.All(endpoint => endpoint.Succeeded);

  /// <summary>Koliko končnih točk je zajetih, a nepreslikanih. Ni napaka, je pa dolg.</summary>
  public int AwaitingMappingCount => Endpoints.Count(endpoint => endpoint.AwaitingMapping);
}

/// <summary>
/// Zajem ene organizacije: strani gredo v <c>raw.Inbox</c> sproti, ne najprej v spomin — pri
/// 200.000 artiklih je razlika med nekaj megabajti in nekaj sto.
///
/// Napaka enega endpointa ne ustavi ostalih. Zajeti trije endpointi od štirih so uporaben
/// rezultat; tiho zamolčana napaka ni. Vsaka se pojavi v izpisu, v <c>ops.PipelineRun.RowsFailed</c>
/// in v izhodni kodi.
/// </summary>
/// <param name="handlerForTests">
/// Testni šiv, enak kot ga že ima <see cref="SaopApiClient"/>: dovoli zagon celotnega zajema
/// proti lažnemu HTTP odgovoru, brez živega SAOP. V produkciji ostane null.
/// </param>
public sealed class SaopIngestRunner(
  string connectionString,
  SaopSettings settings,
  HttpMessageHandler? handlerForTests = null)
{
  /// <summary>
  /// Kako pogosto se javi znak zivljenja med branjem strani. Mora biti obcutno manj od
  /// najmanjsega ops.ScheduleProfile.StaleAfterSeconds (danes 900 s), sicer se dolg klic
  /// koncne tocke razglasi za zastalega sam od sebe.
  /// </summary>
  private static readonly TimeSpan HeartbeatInterval = TimeSpan.FromSeconds(60);

  public async Task<IngestSummary> RunAsync(
    SaopOrganization organization,
    IReadOnlyList<SaopEndpoint> endpoints,
    bool fullSync,
    Func<Task>? heartbeatAsync = null,
    CancellationToken cancellationToken = default,
    bool skipMapping = false,
    Action<string>? log = null,
    int maxParallelEndpoints = 1)
  {
    // Ko podjetja tecejo vzporedno, se izpisi prepletajo v kaso. Klicatelj zato lahko poda
    // svoj zapisovalnik in izpis enega podjetja izpise v enem kosu, ko je koncano.
    var write = log ?? Console.WriteLine;
    var runId = Guid.NewGuid();
    var startedUtc = DateTime.UtcNow;
    var results = new List<EndpointResult>(endpoints.Count);

    await using var connection = new SqlConnection(connectionString);
    await connection.OpenAsync(cancellationToken);

    var sourceConnectorId = await ReadSourceConnectorIdAsync(connection, organization, cancellationToken)
      ?? throw new InvalidOperationException(
        $"V map.SourceConnector ni aktivnega vira {organization.SourceCode} za podjetje {organization.Id}. "
        + "Brez njega zajete strani ostanejo v raw.Inbox in se nikoli ne preslikajo.");

    await InsertPipelineRunAsync(connection, runId, organization, cancellationToken);

    using var client = handlerForTests is null
      ? new SaopApiClient(settings)
      : new SaopApiClient(settings, handlerForTests);
    var priceListIds = NeedsPriceListResolution(endpoints)
      ? await ResolvePriceListIdsAsync(connection, organization, client, cancellationToken)
      : [];

    /*
      Vzporednost po koncnih tockah je privzeto izklopljena (1). Vsaka hkratna koncna tocka je
      dodaten hkraten zahtevek na SAOP za isto podjetje, zato je to stikalo namenjeno merjenju
      in ne slepemu pospesevanju: 4 podjetja krat 16 tock bi bilo 64 hkratnih zahtevkov.
    */
    var endpointSlots = new SemaphoreSlim(Math.Max(1, maxParallelEndpoints));
    var ordered = new EndpointResult?[endpoints.Count];

    async Task RunOneEndpointAsync(int index)
    {
      await endpointSlots.WaitAsync(cancellationToken);
      try
      {
        ordered[index] = await RunEndpointAsync(
          client, endpoints[index], organization, sourceConnectorId, runId, startedUtc, fullSync, skipMapping,
          priceListIds, heartbeatAsync, cancellationToken);
      }
      finally { endpointSlots.Release(); }
    }

    if (maxParallelEndpoints > 1)
    {
      await Task.WhenAll(Enumerable.Range(0, endpoints.Count).Select(RunOneEndpointAsync));
    }
    else
    {
      for (var index = 0; index < endpoints.Count; index++)
      {
        cancellationToken.ThrowIfCancellationRequested();
        await RunOneEndpointAsync(index);
      }
    }

    for (var index = 0; index < endpoints.Count; index++)
    {
      var endpoint = endpoints[index];
      var result = ordered[index]!;
      results.Add(result);
      var cas = result.Pages > 0
        ? $" [{result.DurationMs / 1000.0:0.0} s, {result.DurationMs / 1000.0 / result.Pages:0.00} s/stran]"
        : $" [{result.DurationMs / 1000.0:0.0} s]";
      write(result switch
      {
        { Succeeded: false } => $"  {endpoint.Key}: NAPAKA{cas} — {result.Error}",
        { AwaitingMapping: true } =>
          $"  {endpoint.Key}: strani={result.Pages} zapisov={result.Records} — MEJNIK STOJI "
          + $"({result.WatermarkHold}); zapisi ostanejo v raw.Inbox in jih bo naslednji zagon zajel znova",
        _ => $"  {endpoint.Key}: strani={result.Pages} zapisov={result.Records}{cas}"
      });
    }

    if (heartbeatAsync is not null)
    {
      await heartbeatAsync();
    }

    var summary = new IngestSummary(organization.Id, runId, results, startedUtc);
    await FinishPipelineRunAsync(connection, summary, cancellationToken);
    return summary;
  }

  private async Task<EndpointResult> RunEndpointAsync(
    SaopApiClient client,
    SaopEndpoint endpoint,
    SaopOrganization organization,
    int sourceConnectorId,
    Guid runId,
    DateTime startedUtc,
    bool fullSync,
    bool skipMapping,
    IReadOnlyList<string> priceListIds,
    Func<Task>? heartbeatAsync,
    CancellationToken cancellationToken)
  {
    var pages = 0;
    var records = 0;
    var lastHeartbeatUtc = DateTime.UtcNow;
    var stopwatch = System.Diagnostics.Stopwatch.StartNew();

    // Svoja povezava na koncno tocko: en SqlConnection ne prenese hkratne uporabe iz vec nalog.
    await using var connection = new SqlConnection(connectionString);
    await connection.OpenAsync(cancellationToken);
    try
    {
      var modifiedFromUtc = fullSync
        ? null
        : await ReadWatermarkAsync(connection, sourceConnectorId, endpoint.EntityType, cancellationToken);

      // Prekrivanje: beremo malo nazaj, da se vrstice, zapisane med prejšnjim zajemom, ne izgubijo.
      if (modifiedFromUtc is not null && settings.LookbackDays > 0)
      {
        modifiedFromUtc = modifiedFromUtc.Value.AddDays(-settings.LookbackDays);
      }

      var priceLists = endpoint.Kind == SaopEndpointKind.Prices ? priceListIds : [string.Empty];
      var pricesError = PricesUnavailableError(endpoint.Kind, priceListIds);
      if (pricesError is not null)
      {
        return new EndpointResult(endpoint.Key, endpoint.EntityType, 0, 0, pricesError, WatermarkAdvanced: false, DurationMs: stopwatch.ElapsedMilliseconds);
      }

      foreach (var priceListId in priceLists)
      {
        await foreach (var page in client.ReadAsync(
          endpoint,
          organization.Id,
          modifiedFromUtc,
          string.IsNullOrEmpty(priceListId) ? null : priceListId,
          priceListDate: DateTime.Today,
          cancellationToken))
        {
          // Cenike ločimo po številki strani, sicer bi drugi cenik prepisal prvega pri MERGE
          // na (organizacija, vir, entiteta, stran, hash).
          var pageNumber = endpoint.Kind == SaopEndpointKind.Prices
            ? PriceListPageNumber(priceLists, priceListId, page.PageNumber)
            : page.PageNumber;

          await using var command = RawInboxWriter.CreateCommand(
            connection,
            new RawPage(endpoint.EntityType, pageNumber, page.PayloadXml),
            runId,
            organization.Id,
            organization.SourceCode);
          await command.ExecuteNonQueryAsync(cancellationToken);
          pages++;
          records += page.RecordCount;

          /*
            Znak zivljenja po vsaki strani, ne sele po koncani koncni tocki.

            Zakaj: izmerjeno 2026-08-21 je GetItemsGeneralData za IQLighting 112 strani ob
            ~51 s na stran, torej ura in 40 minut v enem samem klicu koncne tocke. Okno
            zastalosti (ops.ScheduleProfile.StaleAfterSeconds) je 900 sekund. Zagon je zato
            sam sebe razglasil za zastalega in ops.RecordHeartbeat je vrgel 51102
            "Aktivno izvajanje ne obstaja" — podjetje je padlo po prvi koncni tocki in
            preostalih 15 sploh ni prislo na vrsto.

            Utrip je omejen, da ne posilja po enega na vsako stran pri hitrih podjetjih,
            kjer je stran opravljena v dveh sekundah.
          */
          if (heartbeatAsync is not null && DateTime.UtcNow - lastHeartbeatUtc >= HeartbeatInterval)
          {
            await heartbeatAsync();
            lastHeartbeatUtc = DateTime.UtcNow;
          }
        }
      }

      // Zajem je uspel, a brez aktivne preslikave zapisi iz raw.Inbox nikoli ne pridejo v canon:
      // SqlMappingPipeline.ReadInboxesAsync jih veže z INNER JOIN na map.EntityMapping in
      // map.FieldMapping, zato ostanejo Pending. Če bi mejnik kljub temu premaknili, bi ob
      // pozneje dodani preslikavi to obdobje ostalo trajno preskočeno — delta zajem ga ne bi
      // več prinesel. Velja isto pravilo kot pri napaki in pri manjkajočem ceniku: mejnik se
      // ne premakne, dokler zajetega podatka ni mogoče uporabiti.
      if (!await HasActiveMappingAsync(connection, sourceConnectorId, endpoint.EntityType, cancellationToken))
      {
        return new EndpointResult(endpoint.Key, endpoint.EntityType, pages, records, null, WatermarkAdvanced: false,
          WatermarkHold: $"za entiteto {endpoint.EntityType} ni aktivne preslikave v map.EntityMapping/map.FieldMapping",
          DurationMs: stopwatch.ElapsedMilliseconds);
      }

      // Zajem brez preslikave po definiciji ničesar ne preslika. Če bi mejnik kljub temu
      // premaknili, bi bilo zajeto obdobje trajno preskočeno — natanko tista tiha izguba, ki jo
      // prepoveduje pravilo zgoraj, samo z drugim sprožilcem. Izmerjeno 2026-08-21 na živem
      // zajemu: --only-ingest je premaknil mejnik, 183 artiklov pa je ostalo Pending.
      if (skipMapping)
      {
        return new EndpointResult(endpoint.Key, endpoint.EntityType, pages, records, null, WatermarkAdvanced: false,
          WatermarkHold: "zagon je bil --only-ingest, torej ni bilo kaj preslikati",
          DurationMs: stopwatch.ElapsedMilliseconds);
      }

      // Drugi sprožilec iste izgube: če je SAOP vrnil isto vsebino kot prej, jo raw.Inbox
      // prepozna po (podjetje, vir, entiteta, stran, hash) in je ne vstavi znova. Ta zagon
      // potem nima svoje vrstice, preslikava nima kaj obdelati, mejnik pa bi vseeno šel
      // naprej — in podatek, ki leži Pending iz prejšnjega zagona, bi ostal za mejnikom.
      // Izmerjeno 2026-08-21: prav to se je zgodilo s 183 artikli.
      var landed = await CountRunRowsAsync(connection, organization, endpoint.EntityType, runId, cancellationToken);
      var backlog = await CountUnmappedBacklogAsync(
        connection, organization, endpoint.EntityType, runId, cancellationToken);
      if (records > 0 && landed == 0)
      {
        return new EndpointResult(endpoint.Key, endpoint.EntityType, pages, records, null, WatermarkAdvanced: false,
          WatermarkHold: $"SAOP je vrnil {records} zapisov, a so bili enaki že zajetim (dedup po hashu) — ta zagon nima česa preslikati",
          PendingBacklog: backlog, DurationMs: stopwatch.ElapsedMilliseconds);
      }

      /*
        Mejnika tu NE zapisemo, ceprav je koncna tocka upravicena. Preslikava tece sele, ko
        so vse koncne tocke podjetja koncane; ce podjetje med tem pade, bi bil mejnik pred
        podatkom, ki ni nikoli prisel v katalog.

        Izmerjeno 2026-08-21: prav to se je zgodilo. IQLighting je zajel 112 strani
        (111.065 artiklov), mejnik se je premaknil na 08:37:00, nato je podjetje padlo pri
        znaku zivljenja — in delta teh artiklov ne bi vec prinesla. Zdaj mejnik zapise sele
        AdvanceWatermarksAsync, po preslikavi in samo, ce za to entiteto ni ostalo nic
        nepreslikanega.
      */
      return new EndpointResult(endpoint.Key, endpoint.EntityType, pages, records, null, PendingBacklog: backlog,
        DurationMs: stopwatch.ElapsedMilliseconds);
    }
    catch (Exception exception) when (exception is not OperationCanceledException)
    {
      // Watermarka namenoma ne premaknemo — naslednji zagon mora isto obdobje poskusiti znova.
      return new EndpointResult(endpoint.Key, endpoint.EntityType, pages, records, exception.Message, WatermarkAdvanced: false,
        DurationMs: stopwatch.ElapsedMilliseconds);
    }
  }

  private static int PriceListPageNumber(IReadOnlyList<string> priceLists, string priceListId, int page)
  {
    var index = priceLists.ToList().IndexOf(priceListId);
    return (Math.Max(0, index) * 10_000) + page;
  }

  /// <summary>
  /// GetPrices zahteva cenik. Če ga nastavitev ne našteje, jih preberemo iz živega odgovora
  /// <c>api/pricelists</c> — tako se nov cenik v ERP zajame sam od sebe, brez posega v konfiguracijo.
  /// </summary>
  private async Task<IReadOnlyList<string>> ResolvePriceListIdsAsync(
    SqlConnection connection,
    SaopOrganization organization,
    SaopApiClient client,
    CancellationToken cancellationToken)
  {
    if (settings.PriceListIds.Count > 0)
    {
      return settings.PriceListIds;
    }

    try
    {
      var endpoint = SaopEndpoints.Find(SaopEndpoints.PriceLists)!;
      await foreach (var page in client.ReadAsync(endpoint, organization.Id, null, null, null, cancellationToken))
      {
        var ids = XDocument.Parse(page.PayloadXml).Root?.Elements()
          .Select(element => element.Elements().FirstOrDefault(child => child.Name.LocalName == "PriceListId")?.Value)
          .Where(value => !string.IsNullOrWhiteSpace(value))
          .Select(value => value!)
          .Distinct(StringComparer.OrdinalIgnoreCase)
          .ToArray() ?? [];
        if (ids.Length > 0)
        {
          return ids;
        }
      }
    }
    catch (Exception exception)
    {
      Console.Error.WriteLine($"  Cenikov ni bilo mogoče prebrati ({exception.Message}); GetPrices bo preskočen.");
    }

    return [];
  }

  /// <summary>
  /// Vrne true, če seznam končnih točk vsebuje vsaj eno Prices končno točko in je zato
  /// treba razrešiti cenike pred zajemom. Currencies-only in podobne kombinacije brez
  /// GetPrices ne smejo sprožiti API klica za PriceLists.
  /// </summary>
  internal static bool NeedsPriceListResolution(IReadOnlyList<SaopEndpoint> endpoints) =>
    endpoints.Any(endpoint => endpoint.Kind == SaopEndpointKind.Prices);

  /// <summary>
  /// Vrne sporočilo o napaki, če je endpoint vrste Prices in ni na voljo nobenega cenika.
  /// Watermark se v tem primeru ne sme premakniti — naslednji zagon mora isto obdobje poskusiti znova.
  /// </summary>
  internal static string? PricesUnavailableError(SaopEndpointKind kind, IReadOnlyList<string> priceListIds) =>
    kind == SaopEndpointKind.Prices && priceListIds.Count == 0
      ? "GetPrices: ni razpoložljivih cenikov (api/pricelists je vrnil prazen seznam ali ga ni bilo mogoče doseči) — zajem preskočen, mejnik nespremenjen."
      : null;

  private static async Task<int?> ReadSourceConnectorIdAsync(
    SqlConnection connection,
    SaopOrganization organization,
    CancellationToken cancellationToken)
  {
    await using var command = new SqlCommand(
      "SELECT SourceConnectorId FROM map.SourceConnector WHERE SourceCode=@SourceCode AND OrganizationId=@OrganizationId AND IsActive=1;",
      connection);
    command.Parameters.Add("@SourceCode", SqlDbType.NVarChar, 100).Value = organization.SourceCode;
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organization.Id;
    var value = await command.ExecuteScalarAsync(cancellationToken);
    return value is null or DBNull ? null : Convert.ToInt32(value, CultureInfo.InvariantCulture);
  }

  /// <summary>
  /// Ali ima ta par (vir, entiteta) aktivno preslikavo? Pogoj mora ostati enak kot v
  /// <c>SqlMappingPipeline.ReadInboxesAsync</c>: potrebna sta aktiven <c>map.EntityMapping</c>
  /// in vsaj ena aktivna <c>map.FieldMapping</c>. Če manjka katerokoli od tega, INNER JOIN
  /// tam ne vrne vrstice in zajeti zapis ostane <c>Pending</c>.
  ///
  /// Poizvedba namenoma ponovi ta pogoj namesto da bi preverjala samo eno od tabel — sicer bi
  /// se merili dve različni stvari in mejnik bi se premaknil pri polovično nastavljeni preslikavi.
  /// </summary>
  /// <summary>
  /// Premakne mejnike za koncne tocke, ki so do tega upravicene — a sele potem, ko je za
  /// njihovo entiteto v tem zagonu vse preslikano. Klice se PO preslikavi.
  ///
  /// To je edino mesto, ki mejnik zapise. Pravilo je eno samo in ga je mogoce preveriti:
  /// <b>mejnik ne sme nikoli pokazati na obdobje, katerega podatek ni v katalogu.</b>
  /// </summary>
  /// <returns>Imena entitet, katerih mejnik je bil premaknjen.</returns>
  public async Task<IReadOnlyList<string>> AdvanceWatermarksAsync(
    IngestSummary summary,
    SaopOrganization organization,
    CancellationToken cancellationToken = default)
  {
    var advanced = new List<string>();

    await using var connection = new SqlConnection(connectionString);
    await connection.OpenAsync(cancellationToken);

    var sourceConnectorId = await ReadSourceConnectorIdAsync(connection, organization, cancellationToken);
    if (sourceConnectorId is null) return advanced;

    foreach (var endpoint in summary.Endpoints.Where(result => result.WatermarkAdvanced))
    {
      var pendingFromThisRun = await CountRunPendingRowsAsync(
        connection, organization, endpoint.EntityType, summary.RunId, cancellationToken);
      if (pendingFromThisRun > 0) continue;

      await UpdateWatermarkAsync(
        connection, sourceConnectorId.Value, endpoint.EntityType, summary.StartedUtc, cancellationToken);
      advanced.Add(endpoint.EntityType);
    }

    return advanced;
  }

  /// <summary>Koliko vrstic te entitete iz tega zagona je se vedno <c>Pending</c>.</summary>
  internal static async Task<int> CountRunPendingRowsAsync(
    SqlConnection connection,
    SaopOrganization organization,
    string entityType,
    Guid runId,
    CancellationToken cancellationToken)
  {
    await using var command = new SqlCommand(
      "SELECT COUNT(*) FROM raw.Inbox WHERE RunId=@RunId AND OrganizationId=@OrganizationId "
      + "AND SourceCode=@SourceCode AND EntityType=@EntityType AND Status=N'Pending';",
      connection);
    command.Parameters.Add("@RunId", SqlDbType.UniqueIdentifier).Value = runId;
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organization.Id;
    command.Parameters.Add("@SourceCode", SqlDbType.NVarChar, 100).Value = organization.SourceCode;
    command.Parameters.Add("@EntityType", SqlDbType.NVarChar, 100).Value = entityType;
    return Convert.ToInt32(await command.ExecuteScalarAsync(cancellationToken), CultureInfo.InvariantCulture);
  }

  /// <summary>Koliko vrstic te entitete je ta zagon dejansko zapisal v raw.Inbox.</summary>
  internal static async Task<int> CountRunRowsAsync(
    SqlConnection connection,
    SaopOrganization organization,
    string entityType,
    Guid runId,
    CancellationToken cancellationToken)
  {
    await using var command = new SqlCommand(
      "SELECT COUNT(*) FROM raw.Inbox WHERE RunId=@RunId AND OrganizationId=@OrganizationId "
      + "AND SourceCode=@SourceCode AND EntityType=@EntityType;",
      connection);
    command.Parameters.Add("@RunId", SqlDbType.UniqueIdentifier).Value = runId;
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organization.Id;
    command.Parameters.Add("@SourceCode", SqlDbType.NVarChar, 100).Value = organization.SourceCode;
    command.Parameters.Add("@EntityType", SqlDbType.NVarChar, 100).Value = entityType;
    return Convert.ToInt32(await command.ExecuteScalarAsync(cancellationToken), CultureInfo.InvariantCulture);
  }

  /// <summary>
  /// Koliko vrstic te entitete je še vedno <c>Pending</c> iz <em>prejšnjih</em> zagonov.
  /// To ne zadržuje mejnika — sicer bi bil zajem odvisen od nepovezanih ostankov v skupni
  /// bazi — je pa opozorilo: nekje leži podatek, ki ni bil nikoli preslikan.
  /// </summary>
  internal static async Task<int> CountUnmappedBacklogAsync(
    SqlConnection connection,
    SaopOrganization organization,
    string entityType,
    Guid runId,
    CancellationToken cancellationToken)
  {
    await using var command = new SqlCommand(
      "SELECT COUNT(*) FROM raw.Inbox WHERE OrganizationId=@OrganizationId AND SourceCode=@SourceCode "
      + "AND EntityType=@EntityType AND Status=N'Pending' AND RunId<>@RunId;",
      connection);
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organization.Id;
    command.Parameters.Add("@SourceCode", SqlDbType.NVarChar, 100).Value = organization.SourceCode;
    command.Parameters.Add("@EntityType", SqlDbType.NVarChar, 100).Value = entityType;
    command.Parameters.Add("@RunId", SqlDbType.UniqueIdentifier).Value = runId;
    return Convert.ToInt32(await command.ExecuteScalarAsync(cancellationToken), CultureInfo.InvariantCulture);
  }

  internal static async Task<bool> HasActiveMappingAsync(
    SqlConnection connection,
    int sourceConnectorId,
    string entityType,
    CancellationToken cancellationToken)
  {
    await using var command = new SqlCommand("""
      SELECT CASE WHEN EXISTS
      (
        SELECT 1 FROM map.EntityMapping
        WHERE SourceConnectorId=@SourceConnectorId AND EntityType=@EntityType AND IsActive=1
      )
      AND EXISTS
      (
        SELECT 1 FROM map.FieldMapping
        WHERE SourceConnectorId=@SourceConnectorId AND EntityType=@EntityType AND IsActive=1
      )
      THEN 1 ELSE 0 END;
      """, connection);
    command.Parameters.Add("@SourceConnectorId", SqlDbType.Int).Value = sourceConnectorId;
    command.Parameters.Add("@EntityType", SqlDbType.NVarChar, 100).Value = entityType;
    var value = await command.ExecuteScalarAsync(cancellationToken);
    return value is not (null or DBNull) && Convert.ToInt32(value, CultureInfo.InvariantCulture) == 1;
  }

  private static async Task<DateTime?> ReadWatermarkAsync(
    SqlConnection connection,
    int sourceConnectorId,
    string entityType,
    CancellationToken cancellationToken)
  {
    await using var command = new SqlCommand(
      "SELECT WatermarkValue FROM map.Watermark WHERE SourceConnectorId=@SourceConnectorId AND EntityType=@EntityType;",
      connection);
    command.Parameters.Add("@SourceConnectorId", SqlDbType.Int).Value = sourceConnectorId;
    command.Parameters.Add("@EntityType", SqlDbType.NVarChar, 100).Value = entityType;
    var value = await command.ExecuteScalarAsync(cancellationToken);
    if (value is null or DBNull)
    {
      return null;
    }

    return DateTime.TryParse(
      Convert.ToString(value, CultureInfo.InvariantCulture),
      CultureInfo.InvariantCulture,
      DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal,
      out var parsed)
      ? parsed
      : null;
  }

  private static async Task UpdateWatermarkAsync(
    SqlConnection connection,
    int sourceConnectorId,
    string entityType,
    DateTime watermarkUtc,
    CancellationToken cancellationToken)
  {
    await using var command = new SqlCommand("""
      MERGE map.Watermark AS target
      USING (SELECT @SourceConnectorId AS SourceConnectorId, @EntityType AS EntityType) AS source
        ON target.SourceConnectorId = source.SourceConnectorId AND target.EntityType = source.EntityType
      WHEN MATCHED THEN
        UPDATE SET WatermarkValue = @WatermarkValue, UpdatedUtc = SYSUTCDATETIME()
      WHEN NOT MATCHED THEN
        INSERT (SourceConnectorId, EntityType, WatermarkValue, UpdatedUtc)
        VALUES (source.SourceConnectorId, source.EntityType, @WatermarkValue, SYSUTCDATETIME());
      """, connection);
    command.Parameters.Add("@SourceConnectorId", SqlDbType.Int).Value = sourceConnectorId;
    command.Parameters.Add("@EntityType", SqlDbType.NVarChar, 100).Value = entityType;
    command.Parameters.Add("@WatermarkValue", SqlDbType.NVarChar, 200).Value =
      watermarkUtc.ToString("yyyy-MM-ddTHH:mm:ss", CultureInfo.InvariantCulture);
    await command.ExecuteNonQueryAsync(cancellationToken);
  }

  private static async Task InsertPipelineRunAsync(
    SqlConnection connection,
    Guid runId,
    SaopOrganization organization,
    CancellationToken cancellationToken)
  {
    await using var command = new SqlCommand("""
      INSERT ops.PipelineRun (RunId, Pipeline, OrganizationId, SourceCode, Status)
      VALUES (@RunId, N'SAOP_PRODUCTS', @OrganizationId, @SourceCode, N'Running');
      """, connection);
    command.Parameters.Add("@RunId", SqlDbType.UniqueIdentifier).Value = runId;
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organization.Id;
    command.Parameters.Add("@SourceCode", SqlDbType.NVarChar, 100).Value = organization.SourceCode;
    await command.ExecuteNonQueryAsync(cancellationToken);
  }

  private static async Task FinishPipelineRunAsync(
    SqlConnection connection,
    IngestSummary summary,
    CancellationToken cancellationToken)
  {
    await using var command = new SqlCommand("""
      UPDATE ops.PipelineRun
      SET Status = CASE WHEN @Failed = 0 THEN N'Succeeded' ELSE N'Failed' END,
          EndedUtc = SYSUTCDATETIME(),
          RowsRead = @RowsRead,
          RowsSucceeded = @RowsRead,
          RowsFailed = @Failed
      WHERE RunId = @RunId;
      """, connection);
    command.Parameters.Add("@RunId", SqlDbType.UniqueIdentifier).Value = summary.RunId;
    command.Parameters.Add("@RowsRead", SqlDbType.BigInt).Value = (long)summary.TotalRecords;
    command.Parameters.Add("@Failed", SqlDbType.BigInt).Value =
      (long)summary.Endpoints.Count(endpoint => !endpoint.Succeeded);
    await command.ExecuteNonQueryAsync(cancellationToken);
  }
}
