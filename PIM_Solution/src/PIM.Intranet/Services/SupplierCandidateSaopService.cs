using PIM.Outbound;

namespace PIM.Intranet.Services;

/// <summary>
/// Vse, kar stran kandidatov potrebuje, da za en uvožen artikel sestavi dokument za SAOP: pogodba
/// (katera polja, katera so obvezna, katera sme PIM pisati), stanje kanala in kanonično stanje
/// artikla. Načrt se sestavi z <see cref="SaopItemWriteService.BuildPlan"/> — z istim gradnikom
/// kot pri pošiljanju.
/// </summary>
public sealed record CandidateSaopPreparation(
  int OrganizationId, string ItemId, SaopItemContract Contract, SaopItemState State, SaopChannelState Channel)
{
  /// <summary>Polja, ki jih urednik sme vpisati: v lasti PIM, niso ključ, imajo kanonični ključ.</summary>
  public IReadOnlyList<SaopItemFieldRow> Editable { get; } =
    Contract.Fields.Where(field => field.IsEditable).OrderBy(field => field.SortOrder).ToArray();

  /// <summary>Obvezna polja ob ustvarjanju, ki jih PIM ne hrani (npr. tip artikla) — pridejo iz privzetkov <c>out.SaopAddDefault</c>.</summary>
  public IReadOnlyList<SaopItemFieldRow> DefaultOnly { get; } =
    Contract.Fields.Where(field => field.FieldKey is null && field.IsAddMandatory).OrderBy(field => field.SortOrder).ToArray();

  public string? Canonical(string fieldKey) => State.Values.TryGetValue(fieldKey, out var value) ? value : null;

  public string? Default(SaopItemFieldRow field) =>
    State.Defaults.TryGetValue($"{field.Section}/{field.ElementName}", out var value) ? value : null;

  /// <summary>Kar bi šlo v vrsto ob teh vpisih: vpisano ima prednost, sicer kanonično.</summary>
  public IReadOnlyList<SaopQueuedChange> Changes(IReadOnlyDictionary<string, string?> inputs) =>
    SaopNewItemQueue.Changes(Editable.Select(field => field.FieldKey!), State.Values, inputs);

  /// <summary>Načrt dokumenta z natanko tistim, kar bi šlo v vrsto — predogled, ki bi gradil po svoje, bi lagal.</summary>
  public SaopItemPlan Plan(IReadOnlyDictionary<string, string?> inputs) =>
    SaopItemWriteService.BuildPlan(Contract, State, SaopNewItemQueue.AsPlannerChanges(Changes(inputs)));
}

/// <param name="Preparation">Že prebrano stanje, kadar ga ima stran; sicer ga storitev prebere sama.</param>
public sealed record CandidateSaopQueueItem(long SupplierProductCandidateId, string ItemId, IReadOnlyDictionary<string, string?> Inputs, CandidateSaopPreparation? Preparation = null);

/// <param name="OutboundBatchId">Skupina v <c>out.OutboundBatch</c>; null, kadar ni šlo v vrsto nič.</param>
/// <param name="Approved">Sporočil, odobrenih takoj po uvrstitvi (samo ob <c>approve</c>).</param>
/// <param name="Ready">Artikli, ki so šli v vrsto.</param>
/// <param name="Skipped">Artikli, ki niso šli, z razlogom (manjkajoča obvezna polja, napaka gradnje).</param>
/// <param name="Rejected">Polja, ki jih je baza zavrnila (lastništvo, kanal), z razlogom.</param>
public sealed record CandidateSaopQueueOutcome(
  long? OutboundBatchId, int Queued, int Duplicates, int Approved,
  IReadOnlyList<string> Ready, IReadOnlyList<string> Skipped, IReadOnlyList<string> Rejected)
{
  public bool QueuedAnything => OutboundBatchId is not null && (Queued > 0 || Duplicates > 0);
}

/// <summary>
/// Potisk uvoženega kandidata (artikla, ki ga je ustvaril PIM in ga SAOP še ne pozna) v odhodno
/// vrsto za SAOP — zadnji korak poti »XML → kandidat → PIM → SAOP« (uporabnik 2026-09-21).
///
/// Ničesar ne piše mimo obstoječih poti: sporočila nastanejo prek <see cref="SaopWriteService.EnqueueAsync"/>
/// (<c>out.EnqueueSaopItemChanges</c>, vir <c>XML</c>), odobritev prek <c>out.ApproveItemDocument</c>
/// (po artiklu, ne po skupini — tako gredo skupaj tudi sporočila, ki jih je isti artikel dobil s
/// kartice), takojšnje pošiljanje prek <see cref="SaopWriteService.TrySendArticleAsync"/>. Kaj gre v
/// vrsto, določa <see cref="SaopNewItemQueue"/>; ali je dokument popoln, <see cref="SaopItemPlanner"/>.
/// Nepopoln dokument ne gre v vrsto: SAOP bi ga zavrnil, poskus bi bil porabljen, v pregledu pa bi
/// izgledal kot napaka SAOP, čeprav je manjkal podatek na naši strani.
/// </summary>
public sealed class SupplierCandidateSaopService(
  SaopItemWriteService documents, SaopWriteService write, IntranetDataService data,
  ILogger<SupplierCandidateSaopService> logger)
{
  readonly Dictionary<int, SaopItemContract> contracts = new();
  readonly Dictionary<int, SaopChannelState> channels = new();

  public async Task<CandidateSaopPreparation> PrepareAsync(int organizationId, long supplierProductCandidateId, CancellationToken cancellationToken = default)
  {
    if (!contracts.TryGetValue(organizationId, out var contract))
      contracts[organizationId] = contract = await documents.GetContractAsync(organizationId, cancellationToken);
    if (!channels.TryGetValue(organizationId, out var channel))
      channels[organizationId] = channel = await documents.GetChannelStateAsync(organizationId, cancellationToken);
    var state = await documents.GetSupplierCandidateStateAsync(organizationId, supplierProductCandidateId, cancellationToken);
    return new(organizationId, state.ItemId, contract, state, channel);
  }

  /// <summary>
  /// Uvrsti pripravljene artikle v vrsto; nepopolne preskoči in pove, kaj jim manjka. Ena skupina
  /// za vse artikle klica (isto podjetje), kot pri /saop/artikli.
  /// </summary>
  public async Task<CandidateSaopQueueOutcome> QueueAsync(
    int organizationId, IReadOnlyList<CandidateSaopQueueItem> items, string actor, bool approve,
    CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(items);
    if (items.Count == 0) throw new ArgumentException("Izberi vsaj en artikel.", nameof(items));

    var changes = new List<(string ItemId, string FieldKey, string? Value)>();
    var ready = new List<string>();
    var skipped = new List<string>();

    foreach (var item in items)
    {
      var preparation = item.Preparation ?? await PrepareAsync(organizationId, item.SupplierProductCandidateId, cancellationToken);
      if (preparation.State.ExistsInSaop)
      {
        skipped.Add($"{item.ItemId}: SAOP artikel že pozna (CONFIRMED_IN_ERP); spremembe gredo s kartice artikla.");
        continue;
      }

      var plan = preparation.Plan(item.Inputs);
      if (!plan.CanSend)
      {
        skipped.Add($"{item.ItemId}: {DescribeBlock(plan)}");
        continue;
      }

      ready.Add(item.ItemId);
      changes.AddRange(preparation.Changes(item.Inputs).Select(change => (item.ItemId, change.FieldKey, (string?)change.Value)));
    }

    if (changes.Count == 0)
    {
      logger.LogInformation("Novi artikli iz XML: nic za uvrstiti (organizacija {Organizacija}, preskocenih {Preskocenih}).", organizationId, skipped.Count);
      return new(null, 0, 0, 0, ready, skipped, []);
    }

    var note = $"Novi artikli iz XML: {ready.Count} artiklov (POST), {changes.Count} polj.";
    logger.LogInformation(
      "Novi artikli iz XML: uvrscam {Polj} polj za {Artiklov} artiklov (organizacija {Organizacija}, odobri takoj: {Odobri}).",
      changes.Count, ready.Count, organizationId, approve);

    var outcome = await write.EnqueueAsync(organizationId, changes, actor, "XML", note, cancellationToken);
    var rejected = outcome.Rows
      .Where(row => row.Status == "Rejected")
      .Select(row => $"{row.ItemId} / {row.FieldKey}: {row.Reason}")
      .ToArray();
    foreach (var reason in rejected)
      logger.LogWarning("Novi artikli iz XML: zavrnjeno {Razlog}.", reason);

    var approved = 0;
    if (approve && outcome.Queued > 0)
    {
      foreach (var itemId in ready)
      {
        // Po artiklu (152), ne po skupini: odobrijo se tudi sporocila, ki jih je isti artikel medtem
        // dobil s kartice, sicer bi worker sestavil dokument brez njih.
        try { approved += await data.ApproveItemAsync(organizationId, "Product", itemId, actor, cancellationToken); }
        catch (Exception exception) { logger.LogWarning(exception, "Novi artikli iz XML: odobritev {Artikel} ni uspela.", itemId); }
      }
    }

    return new(outcome.OutboundBatchId, outcome.Queued, outcome.Duplicates, approved, ready, skipped, rejected);
  }

  /// <summary>Takoj poskusi poslati en artikel (isti mehanizem kot gumb »Pošlji zdaj« na /outbound).</summary>
  public Task<SaopSendBatchResult> SendNowAsync(int organizationId, string itemId, CancellationToken cancellationToken = default) =>
    write.TrySendArticleAsync(organizationId, itemId, cancellationToken);

  /// <summary>Zakaj dokument ne sme oditi, v besedah urednika (»manjka Naziv 1, Merska enota«).</summary>
  public static string DescribeBlock(SaopItemPlan plan)
  {
    ArgumentNullException.ThrowIfNull(plan);
    if (plan.Error is not null) return plan.Error;
    if (plan.MissingMandatory.Count > 0)
      return "manjka " + string.Join(", ", plan.MissingMandatory.Select(missing =>
      {
        var slash = missing.LastIndexOf('/');
        return SaopFieldLabels.For(slash < 0 ? missing : missing[(slash + 1)..]);
      }));
    if (plan.ChangeCount == 0) return "ni nobene vrednosti za poslati";
    return "dokument ni pripravljen";
  }
}
