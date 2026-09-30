using System.Data;
using System.Globalization;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using PIM.Operations;

namespace PIM.Intranet.Services;

/// <summary>Pravilo varovalke (<c>ops.SafeguardRule</c>, migracija 277): besedila, prag in ali zadrži artikel.</summary>
/// <param name="RequiresConfirmation">Artikel z ugotovitvijo je zadržan (ni v datoteki), dokler ga nekdo ne potrdi.</param>
/// <param name="CanHold">Pravilo govori o artiklu, ki ga je mogoče zadržati; sicer je samo opozorilo.</param>
public sealed record SafeguardRule(
  string RuleCode, string AreaCode, string Title, string ShortLabel, string Explanation, string WhatToDo,
  bool RequiresConfirmation, bool CanHold, bool IsInformational, bool IsEnabled, decimal? ThresholdValue, string? ThresholdLabel,
  int MinCount, int SortOrder, DateTime UpdatedUtc, string UpdatedBy);

/// <summary>Koliko kljukic ne gre na spletišče iz določenega razloga (povzetek preverjanja).</summary>
public sealed record SafeguardBlockedCount(string Site, string Reason, int Count);

/// <summary>Števila iz <c>ops.SafeguardCheck.SummaryJson</c>; manjkajoče število je null.</summary>
public sealed record SafeguardSummary(
  int? Rows, int? PreviousPublished, int? Published, int? WithdrawalRows, int? LostItems, int? NewItems,
  int? PriceFindings, int? CheckedNotPublished, IReadOnlyList<SafeguardBlockedCount> Blocked)
{
  public static SafeguardSummary Empty { get; } = new(null, null, null, null, null, null, null, null, []);

  public static SafeguardSummary Parse(string? json)
  {
    if (string.IsNullOrWhiteSpace(json)) return Empty;
    try
    {
      using var document = JsonDocument.Parse(json);
      var root = document.RootElement;
      var blocked = new List<SafeguardBlockedCount>();
      if (root.TryGetProperty("blocked", out var list) && list.ValueKind == JsonValueKind.Array)
        foreach (var item in list.EnumerateArray())
          blocked.Add(new(
            item.TryGetProperty("site", out var site) ? site.GetString() ?? "" : "",
            item.TryGetProperty("reason", out var reason) ? reason.GetString() ?? "" : "",
            item.TryGetProperty("count", out var count) && count.TryGetInt32(out var number) ? number : 0));
      return new(Int(root, "rows"), Int(root, "previousPublished"), Int(root, "published"), Int(root, "withdrawalRows"),
        Int(root, "lostItems"), Int(root, "newItems"), Int(root, "priceFindings"), Int(root, "checkedNotPublished"), blocked);
    }
    catch (JsonException) { return Empty; }

    static int? Int(JsonElement root, string name) =>
      root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var number) ? number : null;
  }
}

/// <summary>Eno preverjanje (<c>ops.SafeguardCheck</c>): kaj je varovalka ugotovila ob enem izvozu.</summary>
/// <param name="HeldCount">Artikli, ki jih ni v objavljeni datoteki, ker čakajo potrditev.</param>
/// <param name="PublishedRows">Artikli s spletno stranjo v objavljeni datoteki (brez zadržanih).</param>
public sealed record SafeguardCheckRow(
  long SafeguardCheckId, string AreaCode, int OrganizationId, string OrganizationName, string Status, string SubjectLabel,
  int? RowCountValue, int? PublishedRows, int? PreviousPublishedRows, int HeldCount, int FindingCount, int ConfirmCount,
  string? Headline, SafeguardSummary Summary, int EvaluationCount, DateTime CreatedUtc, DateTime LastEvaluatedUtc,
  string CreatedBy, DateTime? PublishedUtc, DateTime? DecidedUtc, string? DecidedBy, string? DecisionNote,
  long? SupersededByCheckId, long? LatestCheckId = null)
{
  public bool IsWaiting => Status == SafeguardText.Waiting;
}

/// <summary>Ena ugotovitev: artikel, polje, prej → zdaj, razlog, ali je artikel zadržan in ali je potrjena.</summary>
/// <param name="RequiresConfirmation">Ob preverjanju je bil artikel zaradi te ugotovitve zadržan.</param>
/// <param name="ApprovedBy">Kdo je ugotovitev potrdil (tudi po tem preverjanju); null = ni potrjena.</param>
public sealed record SafeguardFindingRow(
  long SafeguardFindingId, string RuleCode, string? ItemId, long? ProductId, string ProductName, string? FieldCode,
  string? FieldLabel, string? OldValue, string? NewValue, string? ChangeText, string? SiteLabel, string? ReasonCode,
  string? ReasonFields, string? ReasonActor, DateTime? ReasonUtc, bool RequiresConfirmation, long? ApprovalId,
  string? ApprovedBy, DateTime? ApprovedUtc)
{
  /// <summary>Razlog v besedah uporabnika (umik s spleta, kljukica brez objave).</summary>
  public string? ReasonText => ReasonCode is null ? null : SafeguardText.Reason(ReasonCode, SiteLabel, ReasonFields, ReasonActor, ReasonUtc);

  public bool IsApproved => ApprovedUtc is not null;

  /// <summary>Artikel čaka potrditev: zadržan in (še) ni potrjen.</summary>
  public bool IsPending => RequiresConfirmation && !IsApproved;
}

public sealed record SafeguardCheckDetail(SafeguardCheckRow Check, IReadOnlyList<SafeguardFindingRow> Findings, IReadOnlyList<SafeguardRule> Rules);

/// <param name="ApprovedCount">Koliko ugotovitev je bilo potrjenih s tem klikom.</param>
/// <param name="RemainingCount">Koliko zadržanih ugotovitev preverjanja še čaka.</param>
/// <param name="RunRequested">Ali je bila oddana zahteva za takojšen zagon izvoza.</param>
public sealed record SafeguardApproveOutcome(int ApprovedCount, int RemainingCount, bool RunRequested);

/// <summary>281: sprememba v vrsti za SAOP, ki čaka potrditev (sporočilo × pravilo) — vrstica seznama na strani odobritve.</summary>
public sealed record SaopHeldRow(
  long OutboxMessageId, int OrganizationId, string OrganizationName, string RuleCode, string RuleTitle, string RuleShort, int RuleOrder,
  string ItemId, string? PriceList, string Title, string FieldKey, string? OldValue, string? NewValue, string? ChangeText,
  string Source, long? OutboundBatchId, string CreatedBy, DateTime CreatedUtc)
{
  public bool IsDeactivation => RuleCode == "SAOP_NEAKTIVEN";

  /// <summary>Polje v besedah uporabnika.</summary>
  public string FieldLabel => FieldKey switch
  {
    "Product.IsActive" => "Aktiven",
    "Price.Net" => PriceList is null ? "Cena" : $"Cena ({PriceList})",
    "Price.Active" => PriceList is null ? "Cena aktivna" : $"Cena aktivna ({PriceList})",
    "Product.EAN" => "EAN",
    "Product.UoM" => "Enota mere",
    "Product.ItemGroup" => "Skupina artikla",
    _ => FieldKey.Split('.').Last(),
  };
}

/// <summary>Sprememba pravila na /varovalke (samo skrbnik).</summary>
public sealed record SafeguardRuleChange(string RuleCode, bool IsEnabled, bool RequiresConfirmation, decimal? ThresholdValue, int MinCount);

/// <summary>Besedila varovalk — ista na /varovalke, na /splet in v Excelu.</summary>
public static class SafeguardText
{
  public const string Clean = "CLEAN";
  public const string Warned = "WARNED";
  public const string Waiting = "WAITING";
  public const string Confirmed = "CONFIRMED";
  public const string Superseded = "SUPERSEDED";
  public const string CatalogArea = "KATALOG_CSV";
  public const string SaopArea = "SAOP";
  public const string StockArea = "ZALOGA_CSV";
  public const string FeedArea = "ZALOGA_VIR";

  public static string Area(string area) => area switch
  {
    CatalogArea => "Katalog za splet (katalog.csv)",
    SaopArea => "Pošiljanje v SAOP",
    StockArea => "Cene in zaloga za splet",
    FeedArea => "Zaloga virov (dobavitelji, SAOP)",
    _ => area,
  };

  /// <summary>»1 artikel bo neaktiven«, »2 artikla bosta neaktivna«, »3 artikli bodo neaktivni«, »5 artiklov bo neaktivnih«.</summary>
  public static string ItemsInactive(int count) => (count % 100) switch
  {
    1 => $"{count} artikel bo neaktiven",
    2 => $"{count} artikla bosta neaktivna",
    3 or 4 => $"{count} artikli bodo neaktivni",
    _ => $"{count} artiklov bo neaktivnih",
  };

  public static string Status(string status) => status switch
  {
    Clean => "Brez ugotovitev",
    Warned => "Objavljeno z opozorili",
    Waiting => "Artikli čakajo potrditev",
    Confirmed => "Potrjeno",
    Superseded => "Nadomeščeno",
    _ => status,
  };

  /// <summary>Ton čipa: čakajoče je edino, kar zahteva dejanje.</summary>
  public static string? Tone(string status) => status switch
  {
    Clean or Confirmed => "good",
    Waiting => "bad",
    Warned => "warn",
    _ => null,
  };

  /// <summary>Kaj se je z datoteko zgodilo, v enem stavku.</summary>
  public static string StatusExplain(SafeguardCheckRow check) => check.AreaCode == SaopArea ? SaopExplain(check)
    : check.AreaCode == FeedArea ? FeedExplain(check) : check.Status switch
  {
    Waiting => $"{Published(check.PublishedUtc)}brez {Items(check.HeldCount)}, ki {Waits(check.HeldCount)} potrditev. "
      + "Zadržani artikli na spletu ostanejo s prejšnjimi podatki (nov artikel tja še ne pride), dokler jih ne potrdiš ali popraviš.",
    Confirmed => check.DecidedUtc is { } decided
      ? $"Vse zadržane artikle je potrdil {check.DecidedBy} {decided.ToPimLocal():g}. Na splet gredo z naslednjim izvozom."
      : "Potrjeno. Zadržani artikli gredo na splet z naslednjim izvozom.",
    Superseded => "Nadomestil ga je novejši izvoz — odpri najnovejše preverjanje.",
    Warned => check.PublishedUtc is { } published ? $"Objavljeno {published.ToPimLocal():g}, z opozorili spodaj." : "Z opozorili; objava ni zabeležena.",
    _ => check.PublishedUtc is { } clean ? $"Objavljeno {clean.ToPimLocal():g}." : "Brez ugotovitev.",
  };

  /// <summary>Kratko ime razloga za stolpec in vrstice s števili.</summary>
  public static string ReasonShort(string reason) => reason switch
  {
    "UNCHECKED" => "Odkljukano",
    "INACTIVE" => "Artikel ni aktiven",
    "EXCLUDED" => "Izključen iz kataloga",
    "HOLD" => "Ročno zadržan",
    "NO_CATEGORY" => "Brez kategorije spletišča",
    "BLOCKED_ERRORS" => "Ni veljaven za splet",
    "NOT_VALIDATED" => "Še ni validiran",
    "NOT_PROMOTED" => "Še ni objavljen v PIM",
    "NOT_IN_PIM" => "Artikla ni več v PIM",
    "NOT_IN_FILE" => "Ni v datoteki",
    "PUBLISHED" => "Spet gre na splet",
    _ => reason,
  };

  /// <summary>Ton razloga: kar lahko uredi urednik (kategorija, polja) je opozorilo, odločitev (odkljukano, zadržano) nevtralna.</summary>
  public static string? ReasonTone(string reason) => reason switch
  {
    "NO_CATEGORY" or "BLOCKED_ERRORS" or "NOT_IN_FILE" or "NOT_IN_PIM" => "bad",
    "INACTIVE" or "NOT_VALIDATED" or "NOT_PROMOTED" => "warn",
    "PUBLISHED" => "good",
    _ => null,
  };

  /// <summary>Razlog v enem stavku — kaj je narobe in kje se popravi.</summary>
  public static string Reason(string reason, string? site, string? fields, string? actor, DateTime? changedUtc)
  {
    var siteText = string.IsNullOrWhiteSpace(site) ? "tem spletišču" : $"spletišču {site}";
    return reason switch
    {
      "UNCHECKED" => actor is { Length: > 0 } && actor.StartsWith("SISTEM", StringComparison.OrdinalIgnoreCase)
        ? $"kljukico je samodejno odstranil PIM (artikel ni bil veljaven za splet){When(changedUtc)}"
        : $"kljukica je odstranjena{(actor is { Length: > 0 } ? $" — {actor}" : "")}{When(changedUtc)}",
      "INACTIVE" => "artikel ni aktiven (SAOP)",
      "EXCLUDED" => "izključen iz kataloga (Nadzor kataloga)",
      "HOLD" => "ročno zadržan za splet",
      "NO_CATEGORY" => $"nima kategorije na {siteText} — dodaj jo na kartici artikla",
      "BLOCKED_ERRORS" => Fields(fields) is { Length: > 0 } missing ? $"ni veljaven za splet — manjka: {missing}" : "ni veljaven za splet",
      "NOT_VALIDATED" => "še ni validiran (validacija teče vsako uro)",
      "NOT_PROMOTED" => "še ni objavljen v PIM — objava sledi uspešni validaciji",
      "NOT_IN_PIM" => "artikla ni več v PIM",
      "NOT_IN_FILE" => "artikla ni v datoteki — Magento ga ne bo umaknil sam, ostal bi na spletu",
      "PUBLISHED" => "po trenutnem stanju spet gre na splet (spremenjeno med izvozom)",
      _ => reason,
    };
  }

  /// <summary>283: posnetek zaloge vira — ni uporabljen, dokler ga kdo ne potrdi.</summary>
  static string FeedExplain(SafeguardCheckRow check) => check.Status switch
  {
    Waiting => $"Nov posnetek zaloge vira {check.SubjectLabel} ni uporabljen ({check.Headline}). Velja prejšnji posnetek.",
    Confirmed => $"Potrjeno — naslednji zajem vira {check.SubjectLabel} posnetek uporabi.",
    Superseded => "Medtem je prišel drugačen posnetek — odpri najnovejše preverjanje.",
    _ => "Brez ugotovitev.",
  };

  /// <summary>281: pošiljanje v SAOP — deaktivacije čakajo, vse ostalo gre normalno.</summary>
  static string SaopExplain(SafeguardCheckRow check) => check.Status switch
  {
    Waiting => $"V SAOP čaka potrditev {check.HeldCount:N0} sprememb ({check.Headline}). Ne pošljejo se, dokler ne potrdiš, da so prav; "
      + "ostale spremembe iz istih skupin gredo v SAOP normalno. Potrdiš lahko tudi kar na strani, kjer odobravaš pošiljanje.",
    Confirmed => check.DecidedUtc is { } decided
      ? $"Potrdil {check.DecidedBy} {decided.ToPimLocal():g} — potrjene spremembe so odobrene za pošiljanje v SAOP."
      : "Potrjeno — spremembe so odobrene za pošiljanje v SAOP.",
    Superseded => "Seznam se je medtem spremenil (nova sprememba ali preklic) — odpri najnovejše preverjanje.",
    _ => "Nič ne čaka potrditve.",
  };

  static string When(DateTime? utc) => utc is { } value ? $", {value.ToPimLocal():g}" : "";

  static string Published(DateTime? utc) => utc is { } value ? $"Datoteka je objavljena {value.ToPimLocal():g}, " : "Datoteka je objavljena ";

  /// <summary>»1 artikla«, »2 artiklov« … — rodilnik za »brez N artiklov«.</summary>
  public static string Items(int count) => count % 100 == 1 ? $"{count} artikla" : $"{count} artiklov";

  /// <summary>»čaka«, »čakata«, »čakajo« — glagol za število artiklov.</summary>
  public static string Waits(int count) => (count % 100) switch { 1 => "čaka", 2 => "čakata", 3 or 4 => "čakajo", _ => "čaka" };

  /// <summary>»1 vrstica«, »2 vrstici«, »3 vrstice«, »5 vrstic«.</summary>
  public static string Rows(int count) => (count % 100) switch
  {
    1 => $"{count:N0} vrstica",
    2 => $"{count:N0} vrstici",
    3 or 4 => $"{count:N0} vrstice",
    _ => $"{count:N0} vrstic",
  };

  /// <summary>Slovenska dvojina in množina: »1 artikel čaka«, »2 artikla čakata«, »3 artikli čakajo«, »5 artiklov čaka«.</summary>
  public static string ItemsWaiting(int count) => (count % 100) switch
  {
    1 => $"{count} artikel čaka",
    2 => $"{count} artikla čakata",
    3 or 4 => $"{count} artikli čakajo",
    _ => $"{count} artiklov čaka",
  };

  /// <summary>Stanje ugotovitve v nekaj besedah: zadržan (ni v datoteki), potrjen ali samo opozorilo.</summary>
  public static string FindingState(SafeguardFindingRow finding, string? area = null) => finding switch
  {
    { IsPending: true } => area == SaopArea ? "čaka potrditev — ni poslano" : "zadržan — ni v datoteki",
    { IsApproved: true } => finding.ApprovedBy is { Length: > 0 } by ? $"potrjeno ({by})" : "potrjeno",
    _ => "opozorilo",
  };

  static string Fields(string? fields) => string.Join(", ", (fields ?? "")
    .Split('|', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
    .Where(code => !code.StartsWith("ProductCategory.", StringComparison.Ordinal))
    .Select(WebWithdrawalText.FieldLabel)
    .Distinct(StringComparer.OrdinalIgnoreCase));

  /// <summary>
  /// Cena je shranjena s piko (strojna oblika); uporabnik jo bere z vejico, kot v datoteki — in brez pike
  /// za tisočice, da se »1.302« ne bere kot 1,302 (prav za to napako gre).
  /// </summary>
  public static string Value(string? value) =>
    value is null ? "prazno"
    : decimal.TryParse(value, NumberStyles.AllowLeadingSign | NumberStyles.AllowDecimalPoint, CultureInfo.InvariantCulture, out var number)
      ? number.ToString("0.####", Slovenian)
      : value;

  static readonly CultureInfo Slovenian = CultureInfo.GetCultureInfo("sl-SI");

  /// <summary>Spletne strani prej/zdaj: prazno pomeni odjavo z vseh spletišč.</summary>
  public static string Sites(string? value) => string.IsNullOrWhiteSpace(value) ? "umaknjen z vseh" : value.Replace("|", ", ");
}

/// <summary>
/// Varovalke (migracija 277). Izvoz katalog.csv pred objavo primerja datoteko z zadnjo objavo; kar je
/// sumljivo, počaka potrditev tu. Procedure so v migraciji, tu so klici, preslikava in pravica.
/// </summary>
public sealed class SafeguardService(IConfiguration configuration, PimWriteGuard guard)
{
  string ConnectionString => ConnectionStringResolver.Resolve(configuration)
    ?? throw new InvalidOperationException("Povezava PIM ni nastavljena.");

  public async Task<IReadOnlyList<SafeguardRule>> GetRulesAsync(string? area = null, CancellationToken cancellationToken = default)
  {
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.GetSafeguardRules", connection) { CommandType = CommandType.StoredProcedure, CommandTimeout = 30 };
    command.Parameters.Add("@AreaCode", SqlDbType.NVarChar, 50).Value = (object?)area ?? DBNull.Value;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    return await ReadRulesAsync(reader, cancellationToken);
  }

  public async Task<IReadOnlyList<SafeguardCheckRow>> GetChecksAsync(
    string? area = null, int? organizationId = null, bool onlyWithFindings = false, int take = 50, CancellationToken cancellationToken = default)
  {
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.GetSafeguardChecks", connection) { CommandType = CommandType.StoredProcedure, CommandTimeout = 30 };
    command.Parameters.Add("@AreaCode", SqlDbType.NVarChar, 50).Value = (object?)area ?? DBNull.Value;
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = (object?)organizationId ?? DBNull.Value;
    command.Parameters.Add("@OnlyWithFindings", SqlDbType.Bit).Value = onlyWithFindings;
    command.Parameters.Add("@Take", SqlDbType.Int).Value = take;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    var rows = new List<SafeguardCheckRow>();
    while (await reader.ReadAsync(cancellationToken)) rows.Add(ReadCheck(reader, hasLatest: false));
    return rows;
  }

  /// <summary>
  /// 281: osveži seznam deaktivacij, ki čakajo potrditev (ops.EvaluateSaopSafeguards), in vrne čakajoča preverjanja
  /// področja SAOP. Prazno, kadar ni nič zadržanega ali migracija 281 ni nameščena.
  /// </summary>
  public async Task<IReadOnlyList<SafeguardCheckRow>> EvaluateSaopAsync(string actor = "SISTEM", CancellationToken cancellationToken = default)
  {
    try
    {
      await using (var connection = await OpenAsync(cancellationToken))
      await using (var command = new SqlCommand("ops.EvaluateSaopSafeguards", connection) { CommandType = CommandType.StoredProcedure, CommandTimeout = 60 })
      {
        command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = actor;
        command.Parameters.Add("@Silent", SqlDbType.Bit).Value = true;
        await command.ExecuteNonQueryAsync(cancellationToken);
      }
      return (await GetChecksAsync(SafeguardText.SaopArea, null, onlyWithFindings: true, take: 20, cancellationToken))
        .Where(check => check.IsWaiting).ToList();
    }
    catch (SqlException exception) when (exception.Number == 2812) { return []; }
  }

  /// <summary>
  /// 281: spremembe za SAOP, ki čakajo potrditev — za skupino, za artikle ali vse. Stran odobritve jih pokaže na mestu
  /// (uporabnik 2026-09-24: »nisem mislil, da moraš na druge strani skakati«). Prazno pred migracijo 281.
  /// </summary>
  public async Task<IReadOnlyList<SaopHeldRow>> GetSaopHeldAsync(
    long? outboundBatchId = null, int? organizationId = null, IReadOnlyCollection<string>? itemIds = null, CancellationToken cancellationToken = default)
  {
    try
    {
      await using var connection = await OpenAsync(cancellationToken);
      await using var command = new SqlCommand("intranet.GetSaopHeldMessages", connection) { CommandType = CommandType.StoredProcedure, CommandTimeout = 15 };
      // 46: pasica na strani ne sme čakati minute (na mirni bazi ~1 s); ob izteku pasica pokaže prazno —
      // pošiljanje je vseeno varno, ker zadržana sprememba brez potrditve ne gre v SAOP.
      command.Parameters.Add("@OutboundBatchId", SqlDbType.BigInt).Value = (object?)outboundBatchId ?? DBNull.Value;
      command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = (object?)organizationId ?? DBNull.Value;
      command.Parameters.Add("@EntityKeysJson", SqlDbType.NVarChar, -1).Value = itemIds is null ? DBNull.Value : JsonSerializer.Serialize(itemIds);
      await using var reader = await command.ExecuteReaderAsync(cancellationToken);
      var rows = new List<SaopHeldRow>();
      while (await reader.ReadAsync(cancellationToken))
        rows.Add(new(PimDb.Int64(reader, "OutboxMessageId"), PimDb.Int32(reader, "OrganizationId"), PimDb.TextOrEmpty(reader, "OrganizationName"),
          PimDb.TextOrEmpty(reader, "RuleCode"), PimDb.TextOrEmpty(reader, "RuleTitle"), PimDb.TextOrEmpty(reader, "RuleShort"),
          PimDb.Int32(reader, "RuleOrder"), PimDb.TextOrEmpty(reader, "ItemID"), PimDb.Text(reader, "PriceList"),
          PimDb.TextOrEmpty(reader, "Title"), PimDb.TextOrEmpty(reader, "FieldSummary"), PimDb.Text(reader, "OldValue"),
          PimDb.Text(reader, "NewValue"), PimDb.Text(reader, "ChangeText"), PimDb.TextOrEmpty(reader, "Source"),
          PimDb.NullableInt64(reader, "OutboundBatchId"), PimDb.TextOrEmpty(reader, "CreatedBy"), PimDb.DateTimeValue(reader, "CreatedUtc")));
      return rows;
    }
    catch (SqlException exception) when (exception.Number == 2812) { return []; }
  }

  /// <summary>281: uporabnik je seznam videl in potrdil, da je prav — spremembe so odobrene za pošiljanje v SAOP.</summary>
  public async Task<int> ConfirmSaopHeldAsync(IReadOnlyCollection<long> outboxMessageIds, string actor, CancellationToken cancellationToken = default)
  {
    await guard.RequireAsync(PimPolicies.SaopWrite);
    RequireRealIntranet();
    if (outboxMessageIds.Count == 0) return 0;
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand("ops.ConfirmSaopHeldMessages", connection) { CommandType = CommandType.StoredProcedure, CommandTimeout = 60 };
    command.Parameters.Add("@OutboxMessageIdsJson", SqlDbType.NVarChar, -1).Value = JsonSerializer.Serialize(outboxMessageIds.Distinct());
    command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = actor;
    command.Parameters.Add("@Approve", SqlDbType.Bit).Value = true;
    return await command.ExecuteScalarAsync(cancellationToken) is { } value and not DBNull ? Convert.ToInt32(value, CultureInfo.InvariantCulture) : 0;
  }

  /// <summary>Stanje za pasico na /splet: čakajoče preverjanje, sicer zadnje. null = varovalka še ni tekla (ali ni nameščena).</summary>
  public async Task<SafeguardCheckRow?> GetCurrentAsync(string area, int organizationId, CancellationToken cancellationToken = default)
  {
    try { return (await GetChecksAsync(area, organizationId, onlyWithFindings: false, take: 1, cancellationToken)).FirstOrDefault(); }
    catch (SqlException exception) when (exception.Number == 2812) { return null; }
  }

  public async Task<SafeguardCheckDetail?> GetCheckAsync(long checkId, CancellationToken cancellationToken = default)
  {
    SafeguardCheckRow? check = null;
    var findings = new List<SafeguardFindingRow>();
    await using (var connection = await OpenAsync(cancellationToken))
    await using (var command = new SqlCommand("intranet.GetSafeguardCheck", connection) { CommandType = CommandType.StoredProcedure, CommandTimeout = 60 })
    {
      command.Parameters.Add("@SafeguardCheckId", SqlDbType.BigInt).Value = checkId;
      await using var reader = await command.ExecuteReaderAsync(cancellationToken);
      if (await reader.ReadAsync(cancellationToken)) check = ReadCheck(reader, hasLatest: true);
      if (check is null) return null;
      await reader.NextResultAsync(cancellationToken);
      while (await reader.ReadAsync(cancellationToken))
        findings.Add(new(
          PimDb.Int64(reader, "SafeguardFindingId"), PimDb.TextOrEmpty(reader, "RuleCode"), PimDb.Text(reader, "ItemID"),
          PimDb.NullableInt64(reader, "ProductId"), PimDb.TextOrEmpty(reader, "ProductName"), PimDb.Text(reader, "FieldCode"),
          PimDb.Text(reader, "FieldLabel"), PimDb.Text(reader, "OldValue"), PimDb.Text(reader, "NewValue"), PimDb.Text(reader, "ChangeText"),
          PimDb.Text(reader, "SiteLabel"), PimDb.Text(reader, "ReasonCode"), PimDb.Text(reader, "ReasonFields"),
          PimDb.Text(reader, "ReasonActor"), PimDb.NullableDateTime(reader, "ReasonUtc"), PimDb.Bool(reader, "RequiresConfirmation"),
          PimDb.NullableInt64(reader, "ApprovalId"), PimDb.Text(reader, "ApprovedBy"), PimDb.NullableDateTime(reader, "ApprovedUtc")));
    }
    return new(check, findings, await GetRulesAsync(check.AreaCode, cancellationToken));
  }

  /// <summary>
  /// Uporabnik je zadržane artikle pregledal in jih spusti ven — vse (<paramref name="findingIds"/> null) ali izbrane.
  /// Potrditev velja za isto ugotovitev (artikel, polje, prej → zdaj) 14 dni; baza takoj odda zahtevo za zagon
  /// izvoza, da potrjeni artikli ne čakajo na naslednji cikel. Ko ni več nepotrjenih, je preverjanje potrjeno.
  /// </summary>
  public async Task<SafeguardApproveOutcome> ApproveAsync(
    long checkId, IReadOnlyCollection<long>? findingIds, string actor, string? note, CancellationToken cancellationToken = default)
  {
    await guard.RequireAsync(PimPolicies.SafeguardConfirm);
    RequireRealIntranet();
    if (findingIds is { Count: 0 }) return new(0, -1, false);
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand("ops.ApproveSafeguardFindings", connection) { CommandType = CommandType.StoredProcedure, CommandTimeout = 60 };
    command.Parameters.Add("@SafeguardCheckId", SqlDbType.BigInt).Value = checkId;
    command.Parameters.Add("@FindingIdsJson", SqlDbType.NVarChar, -1).Value =
      findingIds is null ? DBNull.Value : JsonSerializer.Serialize(findingIds);
    command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = actor;
    command.Parameters.Add("@Note", SqlDbType.NVarChar, 1000).Value = string.IsNullOrWhiteSpace(note) ? DBNull.Value : note.Trim();
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    return await reader.ReadAsync(cancellationToken)
      ? new(PimDb.Int32(reader, "ApprovedCount"), PimDb.Int32(reader, "RemainingCount"), PimDb.Bool(reader, "RunRequested"))
      : new(0, -1, false);
  }

  /// <summary>
  /// Naloga #73: potrditev na /varovalke/{id} v bazi takoj odda zahtevo za zagon izvoza (ops.RequestJobRun:
  /// katalog.csv, zaloga, SAOP), potrditev zadržanih SAOP sprememb pa sporočila spusti iz vrste. Na testnem
  /// intranetu (klikalnik, preverjalec; <see cref="MonitorService.TestIntranetWithoutJobsKey"/>) je oboje
  /// zavrnjeno PRED klicem baze — nič se ne zapiše in nič ne gre ven. Pravi intranet ključa nima.
  /// </summary>
  void RequireRealIntranet()
  {
    if (MonitorService.IsTestIntranetWithoutJobs(configuration))
      throw new UnauthorizedAccessException(TestIntranetMessage);
  }

  public const string TestIntranetMessage =
    "Testni intranet: potrjevanje varovalk je izklopljeno, ker bi sprožilo izvoz ali pošiljanje v SAOP. Potrdi na pravem intranetu.";

  public async Task<IReadOnlyList<SafeguardRule>> SaveRuleAsync(SafeguardRuleChange change, string actor, CancellationToken cancellationToken = default)
  {
    await guard.RequireAsync(PimPolicies.SafeguardSettings);
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand("ops.SaveSafeguardRule", connection) { CommandType = CommandType.StoredProcedure, CommandTimeout = 30 };
    command.Parameters.Add("@RuleCode", SqlDbType.NVarChar, 50).Value = change.RuleCode;
    command.Parameters.Add("@IsEnabled", SqlDbType.Bit).Value = change.IsEnabled;
    command.Parameters.Add("@RequiresConfirmation", SqlDbType.Bit).Value = change.RequiresConfirmation;
    var threshold = command.Parameters.Add("@ThresholdValue", SqlDbType.Decimal);
    threshold.Precision = 19; threshold.Scale = 4;
    threshold.Value = (object?)change.ThresholdValue ?? DBNull.Value;
    command.Parameters.Add("@MinCount", SqlDbType.Int).Value = change.MinCount;
    command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = actor;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    return await ReadRulesAsync(reader, cancellationToken);
  }

  /// <summary>Ugotovitve preverjanja kot zvezek za Excel — za daljše sezname (npr. prvo preverjanje po uvedbi).</summary>
  public async Task<(byte[] Bytes, string FileName)?> ExcelAsync(long checkId, CancellationToken cancellationToken = default)
  {
    if (await GetCheckAsync(checkId, cancellationToken) is not { } detail) return null;
    var rules = detail.Rules.ToDictionary(rule => rule.RuleCode, StringComparer.Ordinal);
    var columns = new WorkbookColumn[]
    {
      new("Ugotovitev", Width: 34), new("Stanje", Width: 22), new("Šifra artikla", Width: 20), new("Naziv ERP (sl)", Width: 40),
      new("Polje", Width: 16), new("Prej", Width: 18), new("Zdaj", Width: 18), new("Sprememba", Width: 12),
      new("Spletišče", Width: 12), new("Razlog", Width: 60),
    };
    var rows = detail.Findings.Select(finding => (IReadOnlyList<object?>)new object?[]
    {
      rules.TryGetValue(finding.RuleCode, out var rule) ? rule.Title : finding.RuleCode,
      SafeguardText.FindingState(finding, detail.Check.AreaCode),
      finding.ItemId, finding.ProductName, finding.FieldLabel ?? finding.FieldCode,
      IsSites(finding) ? SafeguardText.Sites(finding.OldValue) : finding.OldValue is null && finding.ItemId is null ? null : SafeguardText.Value(finding.OldValue),
      IsSites(finding) ? SafeguardText.Sites(finding.NewValue) : finding.ItemId is null ? finding.NewValue : SafeguardText.Value(finding.NewValue),
      finding.ChangeText, finding.SiteLabel, finding.ReasonText,
    }).ToList();
    var bytes = WorkbookWriter.Write("Varovalka", columns, rows,
      [$"{SafeguardText.Area(detail.Check.AreaCode)} · preverjanje {detail.Check.SafeguardCheckId} · {detail.Check.CreatedUtc.ToPimLocal():g} · {SafeguardText.Status(detail.Check.Status)}"]);
    return (bytes, $"varovalka_{detail.Check.SafeguardCheckId}.xlsx");

    static bool IsSites(SafeguardFindingRow finding) => finding.FieldCode == "Product.WebSites";
  }

  async Task<SqlConnection> OpenAsync(CancellationToken cancellationToken)
  {
    var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    return connection;
  }

  static async Task<IReadOnlyList<SafeguardRule>> ReadRulesAsync(SqlDataReader reader, CancellationToken cancellationToken)
  {
    var rules = new List<SafeguardRule>();
    while (await reader.ReadAsync(cancellationToken))
      rules.Add(new(
        PimDb.TextOrEmpty(reader, "RuleCode"), PimDb.TextOrEmpty(reader, "AreaCode"), PimDb.TextOrEmpty(reader, "Title"),
        PimDb.TextOrEmpty(reader, "ShortLabel"), PimDb.TextOrEmpty(reader, "Explanation"), PimDb.TextOrEmpty(reader, "WhatToDo"),
        PimDb.Bool(reader, "RequiresConfirmation"), PimDb.Bool(reader, "CanHold"), PimDb.Bool(reader, "IsInformational"), PimDb.Bool(reader, "IsEnabled"),
        PimDb.NullableDecimal(reader, "ThresholdValue"), PimDb.Text(reader, "ThresholdLabel"), PimDb.Int32(reader, "MinCount"),
        PimDb.Int32(reader, "SortOrder"), PimDb.DateTimeValue(reader, "UpdatedUtc"), PimDb.TextOrEmpty(reader, "UpdatedBy")));
    return rules;
  }

  static SafeguardCheckRow ReadCheck(SqlDataReader reader, bool hasLatest) => new(
    PimDb.Int64(reader, "SafeguardCheckId"), PimDb.TextOrEmpty(reader, "AreaCode"), PimDb.Int32(reader, "OrganizationId"),
    PimDb.TextOrEmpty(reader, "OrganizationName"), PimDb.TextOrEmpty(reader, "Status"), PimDb.TextOrEmpty(reader, "SubjectLabel"),
    NullableInt(reader, "RowCountValue"), NullableInt(reader, "PublishedRows"), NullableInt(reader, "PreviousPublishedRows"),
    PimDb.Int32(reader, "HeldCount"), PimDb.Int32(reader, "FindingCount"), PimDb.Int32(reader, "ConfirmCount"),
    PimDb.Text(reader, "Headline"), SafeguardSummary.Parse(PimDb.Text(reader, "SummaryJson")),
    PimDb.Int32(reader, "EvaluationCount"), PimDb.DateTimeValue(reader, "CreatedUtc"), PimDb.DateTimeValue(reader, "LastEvaluatedUtc"),
    PimDb.TextOrEmpty(reader, "CreatedBy"), PimDb.NullableDateTime(reader, "PublishedUtc"), PimDb.NullableDateTime(reader, "DecidedUtc"),
    PimDb.Text(reader, "DecidedBy"), PimDb.Text(reader, "DecisionNote"), PimDb.NullableInt64(reader, "SupersededByCheckId"),
    hasLatest ? PimDb.NullableInt64(reader, "LatestCheckId") : null);

  static int? NullableInt(SqlDataReader reader, string column) =>
    PimDb.NullableInt64(reader, column) is { } value ? (int)value : null;
}
