using System.Data;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using Change = (long Id, string FieldKey, string? Value);

namespace PIM.Outbound;

/// <param name="DryRun">
/// Suhi tek: dokumenti se sestavijo in zapišejo v datoteke, nič ne odide in v bazi se nič ne
/// spremeni. To je privzeto stanje — pošiljanje je treba izrecno zahtevati.
/// </param>
public sealed record SaopDocumentRunOptions(
  string TargetKind = "SAOP_PRODUCT",
  bool DryRun = true,
  string? OutputDirectory = null,
  int MaxDocuments = 100,
  int? OrganizationId = null);

/// <param name="Documents">Koliko dokumentov je bilo obdelanih.</param>
/// <param name="Incomplete">Koliko dokumentov ne bi smelo oditi, ker jim manjka obvezno polje.</param>
public sealed record SaopDocumentRunResult(
  int Documents,
  int Sent,
  int Failed,
  int Incomplete,
  IReadOnlyList<string> Notes);

/// <summary>Sestavljen dokument z vsem, kar je potrebno, da se ga pošlje ali pokaže.</summary>
public sealed record SaopBuiltDocument(
  int OrganizationId,
  string EntityKey,
  SaopIntent Intent,
  string Reason,
  string Xml,
  IReadOnlyList<long> MessageIds,
  IReadOnlyList<string> MissingMandatory,
  int ElementCount);

/// <summary>
/// Odhodna pot na ravni dokumenta: iz čakajočih sprememb sestavi en dokument na zapis in ga
/// pošlje — ali, v suhem teku, samo pokaže.
///
/// Zakaj po dokumentu in ne po polju: sporočilo v <c>out.OutboxMessage</c> je ena sprememba enega
/// polja, ker se echo, dedup in razveljavitev vodijo po polju. SAOP pa polj ne pozna — sprejme
/// dokument na zapis. Sprememba petih polj enega artikla je zato en klic, ne pet.
///
/// Suhi tek je privzet in ne uporablja prevzema: <c>out.ClaimItemDocument</c> poveča število
/// poskusov in postavi lease, zato bi vsak pregled porabil en poskus in bi sporočilo umrlo od
/// poskusov, ki se niso zgodili.
/// </summary>
public sealed class SaopDocumentRunner(
  string connectionString,
  string workerId,
  SaopDocumentRunOptions options,
  SaopDocumentSender? sender = null)
{
  public async Task<SaopDocumentRunResult> RunAsync(CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(connectionString);
    await connection.OpenAsync(cancellationToken);

    var (shape, contract) = await ReadContractAsync(connection, options.TargetKind, cancellationToken);
    var builders = CreateBuilders(shape, contract);

    return options.DryRun
      ? await DryRunAsync(connection, shape, builders, cancellationToken)
      : await SendRunAsync(connection, shape, builders, cancellationToken);
  }

  /// <summary>
  /// Pošlje TOČNO EN, DOLOČEN artikel (organizacija + šifra) — ne najstarejšega v vrsti kot
  /// <see cref="RunAsync"/>. Za interaktivno rabo v vmesniku: uporabnik klikne "Odobri" ali
  /// "Pošlji zdaj" na eni vrstici in pričakuje, da se pošlje prav ta artikel, ne kar koli
  /// drugega, kar je slučajno starejše v vrsti. Prevzame prek <c>out.ClaimItemDocumentByKey</c>
  /// (migracija 193), sicer ista pot gradnje/pošiljanja/samopopravka kot pri worker zanki.
  /// </summary>
  public async Task<SaopDocumentRunResult> SendOneAsync(
    int organizationId, string entityKey, CancellationToken cancellationToken = default)
  {
    if (sender is null) throw new InvalidOperationException("Pošiljanje je zahtevano, povezave na SAOP pa ni.");

    await using var connection = new SqlConnection(connectionString);
    await connection.OpenAsync(cancellationToken);

    var (shape, contract) = await ReadContractAsync(connection, options.TargetKind, cancellationToken);
    var builders = CreateBuilders(shape, contract);

    var claimed = await ClaimByKeyAsync(connection, organizationId, entityKey, cancellationToken);
    if (claimed is null) return new(0, 0, 0, 0, []);

    var (sent, note) = await ProcessClaimedAsync(connection, shape, builders, claimed, cancellationToken);
    return new(1, sent ? 1 : 0, sent ? 0 : 1, 0, [note]);
  }

  /* --- suhi tek --------------------------------------------------------- */

  async Task<SaopDocumentRunResult> DryRunAsync(
    SqlConnection connection, SaopDocumentShape shape, DocumentBuilders builders, CancellationToken cancellationToken)
  {
    var notes = new List<string>();
    var documents = 0;
    var incomplete = 0;

    var pending = await PeekAsync(connection, cancellationToken);
    foreach (var candidate in pending)
    {
      var (general, planning) = Partition(builders,
        await ReadChangesAsync(connection, options.TargetKind, candidate.OrganizationId, candidate.EntityKey, cancellationToken));

      if (planning.Count > 0)
      {
        var plan = BuildPlanning(builders.Planning!, candidate.EntityKey, planning);
        documents++;
        await WriteDryRunFileAsync(candidate.EntityKey, PlanningShape.Operation(SaopIntent.Update), "Planning", plan.Xml, cancellationToken);
        notes.Add($"{candidate.EntityKey}: {PlanningShape.Operation(SaopIntent.Update)} {PlanningShape.Path(SaopIntent.Update)} "
          + $"({plan.ElementCount} polj, {planning.Count} sprememb) — planski podatki gredo na svojo končno točko.");
        if (general.Count == 0) continue;
      }

      var built = await BuildAsync(connection, shape, builders.General, candidate.OrganizationId, candidate.EntityKey,
        candidate.ExistsInSaop, candidate.LastErrorKind, general, cancellationToken);
      documents++;
      if (built.MissingMandatory.Count > 0) incomplete++;

      await WriteDryRunFileAsync(built.EntityKey, shape.Operation(built.Intent), built.Intent.ToString(), built.Xml, cancellationToken);

      notes.Add($"{built.EntityKey}: {shape.Operation(built.Intent)} {shape.Path(built.Intent)} "
        + $"({built.ElementCount} polj, {built.MessageIds.Count} sprememb) — {built.Reason}"
        + (built.MissingMandatory.Count > 0 ? $" | MANJKA: {string.Join(", ", built.MissingMandatory)}" : string.Empty));
    }

    return new(documents, 0, 0, incomplete, notes);
  }

  async Task WriteDryRunFileAsync(string entityKey, string operation, string kind, string xml, CancellationToken cancellationToken)
  {
    if (options.OutputDirectory is not { } directory) return;
    Directory.CreateDirectory(directory);
    await File.WriteAllTextAsync(Path.Combine(directory, $"{Safe(entityKey)}.{operation}.{kind}.xml"), xml, cancellationToken);
  }

  /* --- pravo pošiljanje ------------------------------------------------- */

  async Task<SaopDocumentRunResult> SendRunAsync(
    SqlConnection connection, SaopDocumentShape shape, DocumentBuilders builders, CancellationToken cancellationToken)
  {
    if (sender is null) throw new InvalidOperationException("Pošiljanje je zahtevano, povezave na SAOP pa ni.");

    var notes = new List<string>();
    var documents = 0;
    var sent = 0;
    var failed = 0;

    while (documents < options.MaxDocuments && !cancellationToken.IsCancellationRequested)
    {
      var claimed = await ClaimAsync(connection, cancellationToken);
      if (claimed is null) break;
      documents++;

      var (ok, note) = await ProcessClaimedAsync(connection, shape, builders, claimed, cancellationToken);
      notes.Add(note);
      if (ok) sent++; else failed++;
    }

    return new(documents, sent, failed, 0, notes);
  }

  /// <summary>
  /// En že prevzet dokument: sestavi, pošlje, ob narobe izbrani metodi samopopravi znotraj
  /// istega prevzema, zaključi. Skupno jedro za <see cref="SendRunAsync"/> (zanka po vrsti) in
  /// <see cref="SendOneAsync"/> (en določen artikel) — pot pošiljanja mora biti ena sama, sicer
  /// bi prej ali slej pokazala drug dokument, kot bi bil poslan.
  /// </summary>
  async Task<(bool Sent, string Note)> ProcessClaimedAsync(
    SqlConnection connection, SaopDocumentShape shape, DocumentBuilders builders, ClaimedDocument claimed,
    CancellationToken cancellationToken)
  {
    var (general, planning) = Partition(builders, claimed.Changes);
    if (planning.Count == 0)
    {
      var only = await ProcessGeneralAsync(connection, shape, builders.General, claimed, cancellationToken);
      return (only.Sent, only.Note);
    }

    // 263: planski podatki (izločitev iz rezervacije) gredo na UpdateItemsPlanningData, ki pozna
    // samo PATCH — artikel mora v SAOP že obstajati. Zato gredo za splošnim dokumentom istega
    // prevzema: nov artikel se najprej ustvari, nato dobi kljukico pod šifro, ki mu jo je dal SAOP.
    var notes = new List<string>();
    var sent = true;
    var planningKey = claimed.EntityKey;
    var intent = SaopIntentResolver.Resolve(new(claimed.ExistsInSaop, ParseErrorKind(claimed.LastErrorKind))).Intent;

    if (general.Count > 0)
    {
      var outcome = await ProcessGeneralAsync(connection, shape, builders.General, claimed with { Changes = general },
        cancellationToken);
      notes.Add(outcome.Note);
      sent = outcome.Sent;
      intent = outcome.Intent;
      if (outcome.AssignedItemId is { } assigned) planningKey = assigned;

      if (!outcome.Sent && outcome.Intent == SaopIntent.Add)
      {
        // Artikel, ki ga SAOP ni sprejel, ne obstaja: planski podatki gredo z njim v ponovni poskus ali z njim obstanejo.
        await CompleteAsync(connection, planning.Select(change => change.Id).ToArray(), succeeded: false, statusCode: null,
          body: null, correlationId: null, reason: "Artikel v SAOP ni bil ustvarjen, zato planskih podatkov ni bilo kam zapisati.",
          errorClass: outcome.ErrorClass ?? nameof(OutboundErrorClass.Business), errorKind: null, retryable: false,
          assignedItemId: null, cancellationToken);
        return (false, string.Join(" ", notes));
      }
    }
    else if (intent == SaopIntent.Add)
    {
      const string reason = "Artikla SAOP še ne pozna, planske podatke (izločitev iz rezervacije) pa je mogoče samo "
        + "spremeniti, ne ustvariti. Najprej pošlji artikel, nato ponovi to spremembo.";
      await CompleteAsync(connection, planning.Select(change => change.Id).ToArray(), succeeded: false, statusCode: null,
        body: null, correlationId: null, reason, errorClass: nameof(OutboundErrorClass.Business), errorKind: null,
        retryable: false, assignedItemId: null, cancellationToken);
      return (false, $"{claimed.EntityKey}: {reason}");
    }

    var planned = await ProcessPlanningAsync(connection, builders.Planning!, claimed.OrganizationId, planningKey, planning,
      claimed.BaseUrl, cancellationToken);
    notes.Add(planned.Note);
    return (sent && planned.Sent, string.Join(" ", notes));
  }

  /// <summary>Planski podatki enega artikla: en PATCH na <see cref="SaopKnownShapes.ProductPlanning"/>, brez samopopravka metode — druge ni.</summary>
  async Task<(bool Sent, string Note)> ProcessPlanningAsync(
    SqlConnection connection, SaopDocumentBuilder builder, int organizationId, string entityKey,
    IReadOnlyList<Change> changes, string? baseUrl, CancellationToken cancellationToken)
  {
    var ids = changes.Select(change => change.Id).ToArray();
    var built = BuildPlanning(builder, entityKey, changes);
    var path = PlanningShape.Path(SaopIntent.Update);
    var outcome = await sender!.SendAsync(organizationId, path, PlanningShape.Operation(SaopIntent.Update), built.Xml,
      cancellationToken, baseUrl);

    if (outcome.Response.IsSuccess)
    {
      await CompleteAsync(connection, ids, succeeded: true, outcome.StatusCode, Redact(outcome.RawResponse),
        outcome.CorrelationId, reason: null, errorClass: null, errorKind: null, retryable: false, assignedItemId: null,
        cancellationToken);
      return (true, $"{entityKey}: planski podatki (PATCH {path}) uspešno");
    }

    var advice = SaopErrorTranslator.Translate(outcome.Response.Errors);
    var errorClass = SaopDocumentSender.Classify(outcome.StatusCode, outcome.Response);
    await CompleteAsync(connection, ids, succeeded: false, outcome.StatusCode, Redact(outcome.RawResponse),
      outcome.CorrelationId, reason: $"{advice.Summary} {advice.Instruction}".Trim(),
      errorClass: errorClass == OutboundErrorClass.None ? null : errorClass.ToString(),
      errorKind: advice.Kind.ToString(), retryable: false, assignedItemId: null, cancellationToken);
    return (false, $"{entityKey}: planski podatki — {advice.Summary} {advice.Instruction}".Trim());
  }

  async Task<GeneralOutcome> ProcessGeneralAsync(
    SqlConnection connection, SaopDocumentShape shape, SaopDocumentBuilder builder, ClaimedDocument claimed,
    CancellationToken cancellationToken)
  {
    var built = Build(shape, builder, claimed);

    // Nepopoln dokument ne gre ven. SAOP bi ga zavrnil z 409, poskus bi bil porabljen in v
    // pregledu bi izgledal kot napaka SAOP, čeprav je manjkal podatek na naši strani.
    if (built.MissingMandatory.Count > 0)
    {
      await CompleteAsync(connection, built.MessageIds, succeeded: false, statusCode: null, body: null,
        correlationId: null, reason: $"Dokument ni popoln: manjka {string.Join(", ", built.MissingMandatory)}.",
        errorClass: nameof(OutboundErrorClass.Business), errorKind: null, retryable: false, assignedItemId: null,
        cancellationToken);
      return new(false, $"{built.EntityKey}: ni poslano, manjka {string.Join(", ", built.MissingMandatory)}.",
        built.Intent, null, nameof(OutboundErrorClass.Business));
    }

    var outcome = await sender!.SendAsync(claimed.OrganizationId, shape.Path(built.Intent),
      shape.Operation(built.Intent), built.Xml, cancellationToken, claimed.BaseUrl);

    if (outcome.Response.IsSuccess)
    {
      await CompleteAsync(connection, built.MessageIds, succeeded: true, outcome.StatusCode, Redact(outcome.RawResponse),
        outcome.CorrelationId, reason: null, errorClass: null, errorKind: null, retryable: false,
        assignedItemId: outcome.Response.AssignedItemId, cancellationToken);
      return new(true, $"{built.EntityKey}: {IntentLabel(shape, built.Intent)} ({shape.Operation(built.Intent)}) uspešno"
        + (outcome.Response.AssignedItemId is { } assigned ? $", SAOP je dodelil šifro {assigned}" : string.Empty),
        built.Intent, outcome.Response.AssignedItemId, null);
    }

    var advice = SaopErrorTranslator.Translate(outcome.Response.Errors);

    // Napačno izbrana metoda ni poslovna zavrnitev: ista vsebina z drugo metodo uspe. To je
    // 118 od 130 napak stare vrste, zato se popravi TAKOJ in znotraj istega prevzema — ne
    // šele ob naslednjem zagonu. Popravek se zgodi natanko enkrat: če tudi druga metoda pade,
    // gre napaka uporabniku.
    var finalIntent = built.Intent;
    if (SaopErrorTranslator.Retry(advice) is { } correctedIntent && correctedIntent != built.Intent)
    {
      finalIntent = correctedIntent;
      var corrected = Build(shape, builder, claimed, correctedIntent);
      var correctionNote = $"{built.EntityKey}: {advice.Summary} PIM je takoj poskusil z metodo {IntentLabel(shape, correctedIntent)} ({shape.Operation(correctedIntent)}).";
      outcome = await sender.SendAsync(claimed.OrganizationId, shape.Path(corrected.Intent),
        shape.Operation(corrected.Intent), corrected.Xml, cancellationToken, claimed.BaseUrl);

      if (outcome.Response.IsSuccess)
      {
        await CompleteAsync(connection, built.MessageIds, succeeded: true, outcome.StatusCode,
          Redact(outcome.RawResponse), outcome.CorrelationId, reason: null, errorClass: null, errorKind: null,
          retryable: false, assignedItemId: outcome.Response.AssignedItemId, cancellationToken);
        return new(true, $"{correctionNote} {IntentLabel(shape, corrected.Intent)} ({shape.Operation(corrected.Intent)}) uspešno po samopopravku"
          + (outcome.Response.AssignedItemId is { } dodeljena ? $", SAOP je dodelil šifro {dodeljena}" : string.Empty),
          corrected.Intent, outcome.Response.AssignedItemId, null);
      }

      advice = SaopErrorTranslator.Translate(outcome.Response.Errors);
    }

    var errorClass = SaopDocumentSender.Classify(outcome.StatusCode, outcome.Response);
    // Vrsta zavrnitve se zapiše na sporočilo, da naslednji prevzem izbere pravo metodo brez
    // ponovnega ugibanja — tudi kadar je samopopravek že bil izveden in ni pomagal.
    var retryable = false;

    await CompleteAsync(connection, built.MessageIds, succeeded: false, outcome.StatusCode, Redact(outcome.RawResponse),
      outcome.CorrelationId, reason: $"{advice.Summary} {advice.Instruction}".Trim(),
      errorClass: errorClass == OutboundErrorClass.None ? null : errorClass.ToString(),
      errorKind: advice.Kind.ToString(), retryable, assignedItemId: null, cancellationToken);
    return new(false, $"{built.EntityKey}: {advice.Summary}"
      + (retryable ? " PIM bo poskusil znova z drugo metodo." : $" {advice.Instruction}"),
      finalIntent, null, errorClass == OutboundErrorClass.None ? null : errorClass.ToString());
  }

  /* --- sestavljanje ----------------------------------------------------- */

  async Task<SaopBuiltDocument> BuildAsync(
    SqlConnection connection, SaopDocumentShape shape, SaopDocumentBuilder builder,
    int organizationId, string entityKey, bool existsInSaop, string? lastErrorKind, IReadOnlyList<Change> changes,
    CancellationToken cancellationToken)
  {
    var (values, defaults) = await ReadEntityStateAsync(connection, organizationId, entityKey, cancellationToken);
    return Assemble(shape, builder, organizationId, entityKey, existsInSaop, lastErrorKind, changes, values, defaults);
  }

  static SaopDocumentShape PlanningShape => SaopKnownShapes.ProductPlanning;

  static DocumentBuilders CreateBuilders(SaopDocumentShape shape, IReadOnlyList<SaopXmlField> contract)
  {
    var (general, planning) = SaopPlanningDocument.Split(shape, contract);
    if (planning.Count == 0) return new(new SaopDocumentBuilder(shape, general), null, new HashSet<string>());
    return new(new SaopDocumentBuilder(shape, general), new SaopDocumentBuilder(PlanningShape, planning),
      planning.Where(field => !field.IsKey && field.FieldKey is not null).Select(field => field.FieldKey!)
        .ToHashSet(StringComparer.Ordinal));
  }

  /// <summary>Spremembe splošnih podatkov in spremembe planskih podatkov istega artikla.</summary>
  static (IReadOnlyList<Change> General, IReadOnlyList<Change> Planning) Partition(
    DocumentBuilders builders, IReadOnlyList<Change> changes) =>
    builders.PlanningKeys.Count == 0
      ? (changes, [])
      : (changes.Where(change => !builders.PlanningKeys.Contains(change.FieldKey)).ToArray(),
         changes.Where(change => builders.PlanningKeys.Contains(change.FieldKey)).ToArray());

  /// <summary>Samo spremenjena planska polja — tako, kot jih je pošiljal stari PIM, in brez privzetkov.</summary>
  static SaopXmlBuildResult BuildPlanning(SaopDocumentBuilder builder, string entityKey, IReadOnlyList<Change> changes)
  {
    var values = new Dictionary<string, string?>(StringComparer.Ordinal);
    foreach (var change in changes) values[change.FieldKey] = change.Value;
    return builder.Build(SaopIntent.Update, entityKey, values, new Dictionary<string, string>(), DateTime.UtcNow);
  }

  static SaopBuiltDocument Build(SaopDocumentShape shape, SaopDocumentBuilder builder, ClaimedDocument claimed,
    SaopIntent? forcedIntent = null) =>
    Assemble(shape, builder, claimed.OrganizationId, claimed.EntityKey, claimed.ExistsInSaop, claimed.LastErrorKind,
      claimed.Changes, claimed.Values, claimed.Defaults, forcedIntent);

  static SaopBuiltDocument Assemble(
    SaopDocumentShape shape, SaopDocumentBuilder builder, int organizationId, string entityKey,
    bool existsInSaop, string? lastErrorKind,
    IReadOnlyList<(long Id, string FieldKey, string? Value)> changes,
    IReadOnlyDictionary<string, string?> canonical,
    IReadOnlyDictionary<string, string> defaults,
    SaopIntent? forcedIntent = null)
  {
    var resolved = SaopIntentResolver.Resolve(new(existsInSaop, ParseErrorKind(lastErrorKind)));
    var decision = forcedIntent is { } forced && forced != resolved.Intent
      ? new SaopIntentDecision(forced, "SAOP je zavrnil prvo metodo; ista vsebina gre takoj z drugo.")
      : resolved;

    // Pri spremembi gre ven samo tisto, kar je urednik spremenil — vsako poslano polje SAOP
    // prepiše. Pri ustvarjanju mora dokument nositi vsa obvezna polja, zato se manjkajoča
    // dopolnijo iz kanoničnega stanja; spremembe imajo prednost pred njim.
    var values = new Dictionary<string, string?>(StringComparer.Ordinal);
    if (decision.Intent == SaopIntent.Add)
      foreach (var (key, value) in canonical) values[key] = value;
    foreach (var change in changes) values[change.FieldKey] = change.Value;

    // 243, drugi del: preverjeno na živo (NW.10018, 22.9.2026) — SAOP na PATCH z delnim gnezdenim
    // ovojem (npr. samo <PropertiesData><ItemWidth>…</PropertiesData>, brez sosednjih polj istega
    // ovoja) odgovori z uspehom, a vrednosti tiho ne shrani; isto polje, urejeno ročno v SAOP
    // aplikaciji, se shrani takoj. Zato se pri spremembi ovoj, ki ima vsaj eno spremenjeno polje,
    // dopolni s trenutnim kanoničnim stanjem OSTALIH polj ISTEGA ovoja — ne celega zapisa, da
    // polja, ki jih urednik ni nameraval spremeniti in niso v istem ovoju, ostanejo nedotaknjena.
    if (decision.Intent == SaopIntent.Update)
    {
      var changedSections = builder.Fields
        .Where(field => field.FieldKey is not null && field.Section != SaopDocumentBuilder.RootSection
          && values.ContainsKey(field.FieldKey))
        .Select(field => field.Section)
        .ToHashSet(StringComparer.Ordinal);
      if (changedSections.Count > 0)
        foreach (var field in builder.Fields)
          if (field.FieldKey is not null && changedSections.Contains(field.Section) && !values.ContainsKey(field.FieldKey)
            && canonical.TryGetValue(field.FieldKey, out var current) && !string.IsNullOrWhiteSpace(current))
            values[field.FieldKey] = current;
    }

    var built = builder.Build(decision.Intent, entityKey, values, defaults, DateTime.UtcNow,
      suggestFirstFreeCode: decision.Intent == SaopIntent.Add && shape.SuggestCodeElement is not null);

    return new(organizationId, entityKey, decision.Intent, decision.Reason, built.Xml,
      changes.Select(change => change.Id).ToArray(), built.MissingMandatory, built.ElementCount);
  }

  static SaopErrorKind? ParseErrorKind(string? value) =>
    Enum.TryParse<SaopErrorKind>(value, ignoreCase: true, out var parsed) ? parsed : null;

  /// <summary>Bralcu razumljiva beseda namesto HTTP metode (POST/PATCH) v sporočilih o pošiljanju.</summary>
  static string IntentLabel(SaopDocumentShape shape, SaopIntent intent) => intent == SaopIntent.Update
    ? "Posodobitev"
    : shape.EntityType switch { "Price" => "Nova cena", "PriceList" => "Nov cenik", "Customer" => "Nova stranka", _ => "Nov artikel" };

  /// <summary>
  /// Artikli imajo svoj prevzem (<c>out.ClaimItemDocument</c>, s privzetki in dodeljeno šifro); cene in
  /// ceniki gredo prek <c>out.ClaimSaopDocument</c> (265), ki vrne izid iste oblike.
  /// </summary>
  bool IsProduct => string.Equals(options.TargetKind, SaopKnownShapes.Product.TargetKind, StringComparison.OrdinalIgnoreCase);

  /* --- branje iz baze --------------------------------------------------- */

  static async Task<(SaopDocumentShape Shape, List<SaopXmlField> Contract)> ReadContractAsync(
    SqlConnection connection, string targetKind, CancellationToken cancellationToken)
  {
    await using var command = new SqlCommand("EXEC out.GetSaopXmlContract @TargetKind;", connection);
    command.Parameters.Add("@TargetKind", SqlDbType.NVarChar, 100).Value = targetKind;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);

    if (!await reader.ReadAsync(cancellationToken))
      throw new InvalidOperationException($"Za cilj {targetKind} ni zapisane oblike dokumenta.");

    var shape = new SaopDocumentShape(
      reader.GetString(reader.GetOrdinal("TargetKind")),
      reader.GetString(reader.GetOrdinal("EntityType")),
      reader.GetString(reader.GetOrdinal("RootElementAdd")),
      reader.GetString(reader.GetOrdinal("RootElementUpdate")),
      Text(reader, "ItemElement"),
      reader.GetString(reader.GetOrdinal("KeyElements")).Split(SaopDocumentShape.KeySeparator),
      reader.GetString(reader.GetOrdinal("AddPath")),
      reader.GetString(reader.GetOrdinal("AddOperation")),
      reader.GetString(reader.GetOrdinal("UpdatePath")),
      reader.GetString(reader.GetOrdinal("UpdateOperation")),
      Text(reader, "StampAddElement"),
      Text(reader, "StampUpdateElement"),
      Text(reader, "SuggestCodeElement"));

    await reader.NextResultAsync(cancellationToken);
    var contract = new List<SaopXmlField>();
    while (await reader.ReadAsync(cancellationToken))
      contract.Add(new(
        reader.GetString(reader.GetOrdinal("Section")),
        reader.GetString(reader.GetOrdinal("ElementName")),
        Text(reader, "FieldKey"),
        reader.GetInt32(reader.GetOrdinal("SortOrder")),
        reader.GetBoolean(reader.GetOrdinal("IsAddMandatory")),
        reader.GetString(reader.GetOrdinal("ValueFormat")),
        Text(reader, "TrueValue"),
        Text(reader, "FalseValue"),
        reader.GetBoolean(reader.GetOrdinal("IsKey"))));
    return (shape, contract);
  }

  async Task<List<PendingDocument>> PeekAsync(SqlConnection connection, CancellationToken cancellationToken)
  {
    await using var command = new SqlCommand("EXEC out.PeekItemDocuments @OrganizationId, @TargetKind, @Top;", connection);
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = (object?)options.OrganizationId ?? DBNull.Value;
    command.Parameters.Add("@TargetKind", SqlDbType.NVarChar, 100).Value = options.TargetKind;
    command.Parameters.Add("@Top", SqlDbType.Int).Value = options.MaxDocuments;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    var pending = new List<PendingDocument>();
    while (await reader.ReadAsync(cancellationToken))
      pending.Add(new(
        reader.GetInt32(reader.GetOrdinal("OrganizationId")),
        reader.GetString(reader.GetOrdinal("EntityKey")),
        reader.GetBoolean(reader.GetOrdinal("ExistsInSaop")),
        Text(reader, "ZadnjaNapaka")));
    return pending;
  }

  static async Task<List<(long Id, string FieldKey, string? Value)>> ReadChangesAsync(
    SqlConnection connection, string targetKind, int organizationId, string entityKey, CancellationToken cancellationToken)
  {
    await using var command = new SqlCommand("EXEC out.GetSaopEntityChanges @OrganizationId, @TargetKind, @EntityKey;", connection);
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@TargetKind", SqlDbType.NVarChar, 100).Value = targetKind;
    command.Parameters.Add("@EntityKey", SqlDbType.NVarChar, 450).Value = entityKey;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    var changes = new List<(long, string, string?)>();
    while (await reader.ReadAsync(cancellationToken))
      changes.Add((reader.GetInt64(0), reader.GetString(1), Text(reader, "Value")));
    return changes;
  }

  async Task<(Dictionary<string, string?> Values, Dictionary<string, string> Defaults)> ReadEntityStateAsync(
    SqlConnection connection, int organizationId, string entityKey, CancellationToken cancellationToken)
  {
    await using var command = new SqlCommand("EXEC out.GetSaopEntityValues @OrganizationId, @TargetKind, @EntityKey;", connection);
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@TargetKind", SqlDbType.NVarChar, 100).Value = options.TargetKind;
    command.Parameters.Add("@EntityKey", SqlDbType.NVarChar, 450).Value = entityKey;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    return await ReadStateResultsAsync(reader, cancellationToken);
  }

  static async Task<(Dictionary<string, string?>, Dictionary<string, string>)> ReadStateResultsAsync(
    SqlDataReader reader, CancellationToken cancellationToken)
  {
    while (await reader.ReadAsync(cancellationToken)) { /* glava; zanima nas samo naslednji nabor */ }

    var values = new Dictionary<string, string?>(StringComparer.Ordinal);
    await reader.NextResultAsync(cancellationToken);
    while (await reader.ReadAsync(cancellationToken)) values[reader.GetString(0)] = reader.GetString(1);

    var defaults = new Dictionary<string, string>(StringComparer.Ordinal);
    await reader.NextResultAsync(cancellationToken);
    // Prva vrstica za isti element zmaga: privzetek za konkreten izvor pride pred splošnim.
    while (await reader.ReadAsync(cancellationToken))
    {
      var key = $"{reader.GetString(0)}/{reader.GetString(1)}";
      if (!defaults.ContainsKey(key)) defaults[key] = reader.GetString(2);
    }
    return (values, defaults);
  }

  async Task<ClaimedDocument?> ClaimAsync(SqlConnection connection, CancellationToken cancellationToken)
  {
    if (!IsProduct) return await ClaimSaopDocumentAsync(connection, options.OrganizationId, null, cancellationToken);
    await using var command = new SqlCommand("EXEC out.ClaimItemDocument @WorkerId, @LeaseSeconds;", connection);
    command.Parameters.Add("@WorkerId", SqlDbType.NVarChar, 200).Value = workerId;
    command.Parameters.Add("@LeaseSeconds", SqlDbType.Int).Value = 90;
    return await ReadClaimedAsync(connection, command, cancellationToken);
  }

  /// <summary>Prevzem cene ali cenika (265); cena za cenik, ki ga SAOP še ne pozna, počaka.</summary>
  async Task<ClaimedDocument?> ClaimSaopDocumentAsync(
    SqlConnection connection, int? organizationId, string? entityKey, CancellationToken cancellationToken)
  {
    await using var command = new SqlCommand(
      "EXEC out.ClaimSaopDocument @WorkerId, @LeaseSeconds, @TargetKind, @OrganizationId, @EntityKey;", connection);
    command.Parameters.Add("@WorkerId", SqlDbType.NVarChar, 200).Value = workerId;
    command.Parameters.Add("@LeaseSeconds", SqlDbType.Int).Value = 90;
    command.Parameters.Add("@TargetKind", SqlDbType.NVarChar, 100).Value = options.TargetKind;
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = (object?)organizationId ?? DBNull.Value;
    command.Parameters.Add("@EntityKey", SqlDbType.NVarChar, 450).Value = (object?)entityKey ?? DBNull.Value;
    return await ReadClaimedAsync(connection, command, cancellationToken);
  }

  /// <summary>Isto kot <see cref="ClaimAsync"/>, samo za en določen artikel — glej <see cref="SendOneAsync"/>.</summary>
  async Task<ClaimedDocument?> ClaimByKeyAsync(
    SqlConnection connection, int organizationId, string entityKey, CancellationToken cancellationToken)
  {
    if (!IsProduct) return await ClaimSaopDocumentAsync(connection, organizationId, entityKey, cancellationToken);
    await using var command = new SqlCommand(
      "EXEC out.ClaimItemDocumentByKey @WorkerId, @LeaseSeconds, @OrganizationId, @EntityKey;", connection);
    command.Parameters.Add("@WorkerId", SqlDbType.NVarChar, 200).Value = workerId;
    command.Parameters.Add("@LeaseSeconds", SqlDbType.Int).Value = 90;
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@EntityKey", SqlDbType.NVarChar, 450).Value = entityKey;
    return await ReadClaimedAsync(connection, command, cancellationToken);
  }

  async Task<ClaimedDocument?> ReadClaimedAsync(SqlConnection connection, SqlCommand command, CancellationToken cancellationToken)
  {
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);

    if (!await reader.ReadAsync(cancellationToken)) return null;
    var organizationId = reader.GetInt32(reader.GetOrdinal("OrganizationId"));
    var entityKey = reader.GetString(reader.GetOrdinal("ItemID"));
    var existsInSaop = reader.GetBoolean(reader.GetOrdinal("ExistsInSaop"));
    var lastErrorKind = Text(reader, "LastErrorKind");
    var baseUrl = Text(reader, "BaseUrl");

    var changes = new List<(long, string, string?)>();
    await reader.NextResultAsync(cancellationToken);
    while (await reader.ReadAsync(cancellationToken))
      changes.Add((reader.GetInt64(reader.GetOrdinal("OutboxMessageId")),
        reader.GetString(reader.GetOrdinal("FieldKey")), Text(reader, "Value")));

    var defaults = new Dictionary<string, string>(StringComparer.Ordinal);
    await reader.NextResultAsync(cancellationToken);
    while (await reader.ReadAsync(cancellationToken))
    {
      var key = $"{reader.GetString(0)}/{reader.GetString(1)}";
      if (!defaults.ContainsKey(key)) defaults[key] = reader.GetString(2);
    }
    await reader.CloseAsync();

    // Kanonično stanje se prebere šele zdaj in samo takrat, kadar bo šlo za ustvarjanje:
    // pri spremembi ga ne rabimo in bi bilo eno branje na dokument zastonj.
    var values = new Dictionary<string, string?>(StringComparer.Ordinal);
    if (!existsInSaop || string.Equals(lastErrorKind, nameof(SaopErrorKind.ItemNotFound), StringComparison.OrdinalIgnoreCase))
      (values, _) = await ReadEntityStateAsync(connection, organizationId, entityKey, cancellationToken);

    return new(organizationId, entityKey, existsInSaop, lastErrorKind, changes, values, defaults, baseUrl);
  }

  async Task CompleteAsync(
    SqlConnection connection, IReadOnlyList<long> messageIds, bool succeeded, int? statusCode, string? body,
    string? correlationId, string? reason, string? errorClass, string? errorKind, bool retryable,
    string? assignedItemId, CancellationToken cancellationToken)
  {
    await using var command = new SqlCommand(
      "EXEC out.CompleteItemDocument @OutboxMessageIdsJson,@WorkerId,@Succeeded,@ResponseStatusCode,"
      + "@ResponseBodyRedacted,@ResponseCorrelationId,@FailureReason,@ErrorClass,@SaopErrorKind,@Retryable,@AssignedItemId;",
      connection);
    command.Parameters.AddWithValue("@OutboxMessageIdsJson", JsonSerializer.Serialize(messageIds));
    // Isti workerId kot ob prevzemu: out.CompleteItemDocument namenoma zavrne zakljucek,
    // ki ga je prevzel nekdo drug.
    command.Parameters.AddWithValue("@WorkerId", workerId);
    command.Parameters.AddWithValue("@Succeeded", succeeded);
    command.Parameters.AddWithValue("@ResponseStatusCode", (object?)statusCode ?? DBNull.Value);
    command.Parameters.AddWithValue("@ResponseBodyRedacted", (object?)body ?? DBNull.Value);
    command.Parameters.AddWithValue("@ResponseCorrelationId", (object?)correlationId ?? DBNull.Value);
    command.Parameters.AddWithValue("@FailureReason", (object?)reason ?? DBNull.Value);
    command.Parameters.AddWithValue("@ErrorClass", (object?)errorClass ?? DBNull.Value);
    command.Parameters.AddWithValue("@SaopErrorKind", (object?)errorKind ?? DBNull.Value);
    command.Parameters.AddWithValue("@Retryable", retryable);
    command.Parameters.AddWithValue("@AssignedItemId", (object?)assignedItemId ?? DBNull.Value);
    await command.ExecuteNonQueryAsync(cancellationToken);
  }

  /// <summary>Odgovor gre v bazo obrezan; celoten je lahko dolg in nosi vsebino, ki je ne rabimo.</summary>
  static string Redact(string body) => body.Length <= 4000 ? body : body[..4000];

  static string Safe(string value) =>
    string.Concat(value.Select(character => Path.GetInvalidFileNameChars().Contains(character) ? '_' : character));

  static string? Text(SqlDataReader reader, string column)
  {
    var ordinal = reader.GetOrdinal(column);
    return reader.IsDBNull(ordinal) ? null : reader.GetString(ordinal);
  }

  sealed record DocumentBuilders(
    SaopDocumentBuilder General, SaopDocumentBuilder? Planning, IReadOnlySet<string> PlanningKeys);

  sealed record GeneralOutcome(bool Sent, string Note, SaopIntent Intent, string? AssignedItemId, string? ErrorClass);

  sealed record PendingDocument(int OrganizationId, string EntityKey, bool ExistsInSaop, string? LastErrorKind);

  sealed record ClaimedDocument(
    int OrganizationId,
    string EntityKey,
    bool ExistsInSaop,
    string? LastErrorKind,
    IReadOnlyList<(long Id, string FieldKey, string? Value)> Changes,
    Dictionary<string, string?> Values,
    Dictionary<string, string> Defaults,
    string? BaseUrl);
}
