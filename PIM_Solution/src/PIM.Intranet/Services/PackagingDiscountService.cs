using System.Data;
using System.Globalization;
using System.Text.Json;
using Microsoft.Data.SqlClient;

namespace PIM.Intranet.Services;

/// <summary>S koda iz šifranta (S1 = 3 % …).</summary>
public sealed record PackagingCode(string Code, decimal Percent);

/// <summary>
/// Pravilo posebnega S (migracija 274, <c>b2b.PackagingDiscountRule</c>).
/// <paramref name="TargetKind"/> TYPE (tip stranke) ali CUSTOMER (stranka);
/// <paramref name="ScopeKind"/> ITEM, ITEM_GROUP (rabatna skupina), S_CODE (vsi z dano privzeto S kodo) ali ALL.
/// </summary>
public sealed record PackagingRule(
  long RuleId, string TargetKind, string ScopeKind, string? TargetCode, string? TargetName, string? MagentoGroupKey,
  string? ItemId, string? ItemGroupCode, string? FromDiscountCode, string DiscountCode, decimal? Percent,
  DateTime? ValidFrom, DateTime? ValidTo, bool IsActive, string? Note, DateTime? UpdatedUtc, string? UpdatedBy,
  int ProductCount, int CustomerCount)
{
  public string TargetLabel => TargetKind == PackagingDiscountService.TargetType
    ? $"Tip: {TargetName ?? TargetCode}" : $"Stranka: {TargetName} ({TargetCode})";

  public string ScopeLabel => PackagingDiscountService.ScopeLabel(ScopeKind, ItemId, ItemGroupCode, FromDiscountCode);
}

/// <summary>Vnos pravila iz obrazca ali uvoza. Stranka je podana s šifro (<paramref name="CustomerKey"/>) ali z Id.</summary>
public sealed record PackagingRuleInput(
  string TargetKind, string? CustomerTypeCode, long? CustomerId, string? CustomerKey,
  string ScopeKind, string? ItemId, string? ItemGroupCode, string? FromDiscountCode,
  string DiscountCode, DateTime? ValidFrom = null, DateTime? ValidTo = null, string? Note = null);

/// <summary>Posebni S, ki danes velja za izdelek (kartica izdelka).</summary>
public sealed record ProductSpecial(
  long RuleId, string TargetKind, string ScopeKind, string? TargetCode, string? TargetName,
  string DiscountCode, decimal? Percent, string? ItemGroupCode, string? FromDiscountCode, DateTime? ValidFrom, DateTime? ValidTo)
{
  public string ScopeLabel => PackagingDiscountService.ScopeLabel(ScopeKind, null, ItemGroupCode, FromDiscountCode);
}

public sealed record ProductPackagingState(
  bool IsPromoted, string? DiscountCode, decimal? Percent, decimal? Pak2, DateTime? UpdatedUtc,
  string? DiscountGroup, int OrganizationId,
  IReadOnlyList<PackagingCode> Catalog, IReadOnlyList<ProductSpecial> Specials);

public sealed record CustomerPackagingItem(
  string ItemId, string? Name, decimal? Pak2, string? DefaultCode, decimal? DefaultPercent,
  string DiscountCode, decimal? Percent, string Source, string ScopeKind, long RuleId, string? DiscountGroup, long? ProductId);

public sealed record CustomerPackagingView(
  string? CustomerTypeCode, string? TypeName, bool PackagingDiscountEnabled, int SpecialProductCount, int DefaultProductCount,
  IReadOnlyList<PackagingRule> Rules, IReadOnlyList<CustomerPackagingItem> Items);

/// <summary>Obseg ene celice »ARTIKEL\S2«, »SKUPINA:BRAYTRON\S3«, »S:S2\S3«, »*\S3«.</summary>
public sealed record PackagingScope(string ScopeKind, string? ItemId, string? ItemGroupCode, string? FromDiscountCode)
{
  /// <summary>Ključ za primerjavo (velike črke), da »skupina:x« in »SKUPINA:X« nista dve pravili.</summary>
  public string Key => ScopeKind + "|" + (ItemId ?? ItemGroupCode ?? FromDiscountCode ?? "").ToUpperInvariant();

  public string Text => PackagingDiscountService.ScopeText(ScopeKind, ItemId, ItemGroupCode, FromDiscountCode);
}

public sealed record PackagingBulkOutcome(int Changed, IReadOnlyList<(string ItemId, string Reason)> Skipped);

/// <summary>
/// S-popust na polno pakiranje (Magento_Pravila_Cene_Popusti_Postnine §4.4, §4.5, §4.8; migraciji 214 in 274).
///
/// Trije sloji, en vir resnice:
///   1. privzeti S izdelka (<c>pim.ProductPackagingDiscount</c>) — velja za vse stranke s kljukico
///      »Popust polno pakiranje«; v katalog.csv stolpca »Skupina popusta« in »S popust %«;
///   2. posebni S po tipu stranke (<c>b2b.PackagingDiscountRule</c>, TYPE) — v katalog.csv stolpec
///      »Posebni S za skupino strank« kot MAGENTO_SKUPINA\S3;
///   3. posebni S po stranki (CUSTOMER) — stolpec »Posebni popust za stranko« kot ŠIFRA\S2.
/// Pravilo velja za en izdelek, rabatno skupino, vse izdelke z dano privzeto S kodo ali vse izdelke;
/// zmaga najbolj specifično (izdelek, S koda, skupina, vsi), stranka pred svojim tipom.
/// </summary>
public sealed class PackagingDiscountService(IConfiguration configuration)
{
  public const string TargetType = "TYPE";
  public const string TargetCustomer = "CUSTOMER";
  public const string ScopeItem = "ITEM";
  public const string ScopeGroup = "ITEM_GROUP";
  public const string ScopeCode = "S_CODE";
  public const string ScopeAll = "ALL";

  /// <summary>Predpona obsega »rabatna skupina« v celici.</summary>
  public const string GroupPrefix = "SKUPINA:";
  /// <summary>Predpona obsega »vsi izdelki s privzeto S kodo« v celici.</summary>
  public const string CodePrefix = "S:";
  /// <summary>Obseg »vsi izdelki« v celici.</summary>
  public const string AllToken = "*";

  string ConnectionString => ConnectionStringResolver.Resolve(configuration)
    ?? throw new InvalidOperationException("Povezava PIM ni nastavljena.");

  /* --- Zapis obsega ------------------------------------------------------------------------- */

  public static string ScopeLabel(string scopeKind, string? itemId, string? itemGroup, string? fromCode) => scopeKind switch
  {
    ScopeItem => $"artikel {itemId}",
    ScopeGroup => $"rabatna skupina {itemGroup}",
    ScopeCode => $"vsi artikli s privzetim {fromCode}",
    ScopeAll => "vsi artikli",
    _ => scopeKind,
  };

  public static string ScopeText(string scopeKind, string? itemId, string? itemGroup, string? fromCode) => scopeKind switch
  {
    ScopeItem => itemId ?? "",
    ScopeGroup => GroupPrefix + itemGroup,
    ScopeCode => CodePrefix + fromCode,
    _ => AllToken,
  };

  /// <summary>Levi del celice (pred »\«) v obseg; null, kadar je prazen.</summary>
  public static PackagingScope? ParseScope(string? text)
  {
    var value = (text ?? "").Trim();
    if (value.Length == 0) return null;
    if (value == AllToken) return new(ScopeAll, null, null, null);
    if (value.StartsWith(GroupPrefix, StringComparison.OrdinalIgnoreCase))
    {
      var group = value[GroupPrefix.Length..].Trim();
      return group.Length == 0 ? null : new(ScopeGroup, null, group, null);
    }
    if (value.StartsWith(CodePrefix, StringComparison.OrdinalIgnoreCase))
    {
      var code = value[CodePrefix.Length..].Trim().ToUpperInvariant();
      return code.Length == 0 ? null : new(ScopeCode, null, null, code);
    }
    return new(ScopeItem, value, null, null);
  }

  /// <summary>
  /// Celica »LEVO\S2 | LEVO\S3« v seznam (levo, S koda). Levo je obseg (stranka) ali tip/stranka
  /// (izdelek) — pomen da klicatelj. Napako vrne v <paramref name="error"/> in prekine.
  /// </summary>
  public static List<(string Left, string Code)> ParsePairs(string? text, out string? error)
  {
    error = null;
    var result = new List<(string, string)>();
    if (string.IsNullOrWhiteSpace(text)) return result;
    var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    foreach (var item in text.Split('|', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
    {
      var separator = item.LastIndexOf('\\');
      var left = separator > 0 ? item[..separator].Trim() : "";
      var code = separator > 0 ? item[(separator + 1)..].Trim().ToUpperInvariant() : "";
      if (left.Length == 0 || code.Length == 0) { error = $"»{item}« ni v obliki LEVO\\S2."; return result; }
      if (!seen.Add(left)) { error = $"»{left}« je v celici dvakrat."; return result; }
      result.Add((left, code));
    }
    return result;
  }

  /* --- Šifrant ------------------------------------------------------------------------------ */

  public async Task<IReadOnlyList<PackagingCode>> GetCatalogAsync(bool includeInactive = false, CancellationToken cancellationToken = default) =>
    await QueryAsync($"SELECT DiscountCode, PercentValue FROM pim.PackagingDiscountCatalog {(includeInactive ? "" : "WHERE IsActive = 1")} ORDER BY PercentValue, DiscountCode;",
      reader => new PackagingCode(PimDb.TextOrEmpty(reader, "DiscountCode"), PimDb.Decimal(reader, "PercentValue")), null, cancellationToken);

  public Task SavePercentAsync(int organizationId, string code, decimal percent, string actor, CancellationToken cancellationToken = default) =>
    ExecAsync("pim.SavePackagingDiscountPercent", command =>
    {
      command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
      command.Parameters.Add("@DiscountCode", SqlDbType.NVarChar, 10).Value = code.Trim().ToUpperInvariant();
      AddDecimal(command, "@PercentValue", percent);
      command.Parameters.Add("@ChangedBy", SqlDbType.NVarChar, 200).Value = actor;
    }, cancellationToken);

  /* --- Pravila ------------------------------------------------------------------------------ */

  public async Task<IReadOnlyList<PackagingRule>> GetRulesAsync(int organizationId, bool includeInactive = false, CancellationToken cancellationToken = default) =>
    await QueryAsync("intranet.GetPackagingDiscountRules", ReadRule, command =>
    {
      command.CommandType = CommandType.StoredProcedure;
      command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
      command.Parameters.Add("@IncludeInactive", SqlDbType.Bit).Value = includeInactive;
    }, cancellationToken);

  public async Task<long> SaveRuleAsync(int organizationId, PackagingRuleInput input, string actor,
    CancellationToken cancellationToken = default, SqlConnection? connection = null)
  {
    long id = 0;
    await RunAsync(connection, async open =>
    {
      await using var command = new SqlCommand("b2b.SavePackagingDiscountRule", open) { CommandType = CommandType.StoredProcedure };
      command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
      command.Parameters.Add("@TargetKind", SqlDbType.NVarChar, 10).Value = input.TargetKind;
      command.Parameters.Add("@CustomerTypeCode", SqlDbType.NVarChar, 60).Value = Db(input.CustomerTypeCode);
      command.Parameters.Add("@CustomerId", SqlDbType.BigInt).Value = (object?)input.CustomerId ?? DBNull.Value;
      command.Parameters.Add("@CustomerKey", SqlDbType.NVarChar, 100).Value = Db(input.CustomerKey);
      command.Parameters.Add("@ScopeKind", SqlDbType.NVarChar, 12).Value = input.ScopeKind;
      command.Parameters.Add("@ItemID", SqlDbType.NVarChar, 100).Value = Db(input.ItemId);
      command.Parameters.Add("@ItemGroupCode", SqlDbType.NVarChar, 100).Value = Db(input.ItemGroupCode);
      command.Parameters.Add("@FromDiscountCode", SqlDbType.NVarChar, 10).Value = Db(input.FromDiscountCode);
      command.Parameters.Add("@DiscountCode", SqlDbType.NVarChar, 10).Value = input.DiscountCode;
      command.Parameters.Add("@ValidFrom", SqlDbType.Date).Value = (object?)input.ValidFrom?.Date ?? DBNull.Value;
      command.Parameters.Add("@ValidTo", SqlDbType.Date).Value = (object?)input.ValidTo?.Date ?? DBNull.Value;
      command.Parameters.Add("@Note", SqlDbType.NVarChar, 400).Value = Db(input.Note);
      command.Parameters.Add("@ChangedBy", SqlDbType.NVarChar, 200).Value = actor;
      id = Convert.ToInt64(await command.ExecuteScalarAsync(cancellationToken), CultureInfo.InvariantCulture);
    }, cancellationToken);
    return id;
  }

  public Task RemoveRuleAsync(int organizationId, long ruleId, string actor,
    CancellationToken cancellationToken = default, SqlConnection? connection = null) =>
    RunAsync(connection, async open =>
    {
      await using var command = new SqlCommand("b2b.RemovePackagingDiscountRule", open) { CommandType = CommandType.StoredProcedure };
      command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
      command.Parameters.Add("@RuleId", SqlDbType.BigInt).Value = ruleId;
      command.Parameters.Add("@ChangedBy", SqlDbType.NVarChar, 200).Value = actor;
      await command.ExecuteNonQueryAsync(cancellationToken);
    }, cancellationToken);

  /* --- Izdelek ------------------------------------------------------------------------------ */

  public async Task<ProductPackagingState?> GetProductAsync(long productId, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.GetProductPackagingDiscount", connection) { CommandType = CommandType.StoredProcedure, CommandTimeout = 120 };
    command.Parameters.Add("@ProductId", SqlDbType.BigInt).Value = productId;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    if (!await reader.ReadAsync(cancellationToken)) return null;
    var isPromoted = PimDb.Bool(reader, "IsPromoted");
    var code = PimDb.Text(reader, "DiscountCode");
    var percent = PimDb.NullableDecimal(reader, "PercentValue");
    var pak2 = PimDb.NullableDecimal(reader, "Pak2");
    var updated = PimDb.NullableDateTime(reader, "UpdatedUtc");
    var group = PimDb.Text(reader, "DiscountGroup");
    var organizationId = PimDb.Int32(reader, "OrganizationId");
    var catalog = new List<PackagingCode>();
    if (await reader.NextResultAsync(cancellationToken))
      while (await reader.ReadAsync(cancellationToken))
        catalog.Add(new(PimDb.TextOrEmpty(reader, "DiscountCode"), PimDb.Decimal(reader, "PercentValue")));
    var specials = new List<ProductSpecial>();
    if (await reader.NextResultAsync(cancellationToken))
      while (await reader.ReadAsync(cancellationToken))
        specials.Add(new(PimDb.Int64(reader, "RuleId"), PimDb.TextOrEmpty(reader, "TargetKind"), PimDb.TextOrEmpty(reader, "ScopeKind"),
          PimDb.Text(reader, "TargetCode"), PimDb.Text(reader, "TargetName"), PimDb.TextOrEmpty(reader, "DiscountCode"),
          PimDb.NullableDecimal(reader, "PercentValue"), PimDb.Text(reader, "ItemGroupCode"), PimDb.Text(reader, "FromDiscountCode"),
          PimDb.NullableDateTime(reader, "ValidFrom"), PimDb.NullableDateTime(reader, "ValidTo")));
    return new(isPromoted, code, percent, pak2, updated, group, organizationId, catalog, specials);
  }

  /// <summary>Privzeti S enega izdelka; prazna koda pomeni »brez S«. Vrne, ali se je kaj spremenilo.</summary>
  public async Task<bool> SaveProductDefaultAsync(int organizationId, long productId, string? code, string actor,
    CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("pim.SaveProductPackagingDiscount", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@ProductId", SqlDbType.BigInt).Value = productId;
    command.Parameters.Add("@DiscountCode", SqlDbType.NVarChar, 10).Value = Db(code);
    command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = actor;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    return await reader.ReadAsync(cancellationToken) && PimDb.Bool(reader, "Changed");
  }

  /// <summary>Privzeti S več izdelkom naenkrat (šifra → koda; null ali prazno = brez S).</summary>
  public async Task<PackagingBulkOutcome> SaveDefaultsBulkAsync(int organizationId,
    IReadOnlyCollection<(string ItemId, string? Code)> items, string actor, string? note, string source,
    CancellationToken cancellationToken = default)
  {
    if (items.Count == 0) return new(0, []);
    var json = JsonSerializer.Serialize(items.Select(item => new { i = item.ItemId, s = item.Code ?? "" }));
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("pim.SaveProductPackagingDiscountsBulk", connection)
    {
      CommandType = CommandType.StoredProcedure,
      CommandTimeout = 600,
    };
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@ItemsJson", SqlDbType.NVarChar, -1).Value = json;
    command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = actor;
    command.Parameters.Add("@Note", SqlDbType.NVarChar, 400).Value = Db(note);
    command.Parameters.Add("@ChangeSource", SqlDbType.NVarChar, 40).Value = source;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    var changed = await reader.ReadAsync(cancellationToken) ? PimDb.Int32(reader, "ChangedCount") : 0;
    var skipped = new List<(string, string)>();
    if (await reader.NextResultAsync(cancellationToken))
      while (await reader.ReadAsync(cancellationToken))
        skipped.Add((PimDb.TextOrEmpty(reader, "ItemID"), PimDb.TextOrEmpty(reader, "Reason")));
    return new(changed, skipped);
  }

  /// <summary>Delovni list: privzeti S, PAK2 in posebni S na izdelku (tipi, stranke) po canon ProductId.</summary>
  public async Task<IReadOnlyDictionary<long, (string? Code, decimal? Pak2, string? Types, string? Customers)>> GetSheetAsync(
    IReadOnlyCollection<long> productIds, CancellationToken cancellationToken = default)
  {
    var result = new Dictionary<long, (string?, decimal?, string?, string?)>();
    if (productIds.Count == 0) return result;
    foreach (var chunk in productIds.Chunk(5_000))
    {
      var rows = await QueryAsync("intranet.GetProductPackagingDiscountSheet", reader => (
          Id: PimDb.Int64(reader, "ProductId"), Code: PimDb.Text(reader, "DiscountCode"), Pak2: PimDb.NullableDecimal(reader, "Pak2"),
          Types: PimDb.Text(reader, "TypeSpecials"), Customers: PimDb.Text(reader, "CustomerSpecials")),
        command =>
        {
          command.CommandType = CommandType.StoredProcedure;
          command.CommandTimeout = 300;
          command.Parameters.Add("@ProductIdsJson", SqlDbType.NVarChar, -1).Value = JsonSerializer.Serialize(chunk);
        }, cancellationToken);
      foreach (var row in rows) result[row.Id] = (row.Code, row.Pak2, row.Types, row.Customers);
    }
    return result;
  }

  /* --- Stranka ------------------------------------------------------------------------------ */

  public async Task<CustomerPackagingView> GetCustomerAsync(int organizationId, long customerId, int take = 500,
    CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.GetCustomerPackagingDiscounts", connection) { CommandType = CommandType.StoredProcedure, CommandTimeout = 120 };
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@CustomerId", SqlDbType.BigInt).Value = customerId;
    command.Parameters.Add("@Take", SqlDbType.Int).Value = take;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);

    string? typeCode = null, typeName = null; var enabled = false; var special = 0; var defaults = 0;
    if (await reader.ReadAsync(cancellationToken))
    {
      typeCode = PimDb.Text(reader, "CustomerTypeCode");
      typeName = PimDb.Text(reader, "TypeName");
      enabled = PimDb.Bool(reader, "PackagingDiscountEnabled");
      special = PimDb.Int32(reader, "SpecialProductCount");
      defaults = PimDb.Int32(reader, "DefaultProductCount");
    }
    var rules = new List<PackagingRule>();
    if (await reader.NextResultAsync(cancellationToken))
      while (await reader.ReadAsync(cancellationToken))
        rules.Add(new(PimDb.Int64(reader, "RuleId"), PimDb.TextOrEmpty(reader, "TargetKind"), PimDb.TextOrEmpty(reader, "ScopeKind"),
          PimDb.Text(reader, "TargetCode"), PimDb.Text(reader, "TargetName"), null, PimDb.Text(reader, "ItemID"),
          PimDb.Text(reader, "ItemGroupCode"), PimDb.Text(reader, "FromDiscountCode"), PimDb.TextOrEmpty(reader, "DiscountCode"),
          PimDb.NullableDecimal(reader, "PercentValue"), PimDb.NullableDateTime(reader, "ValidFrom"), PimDb.NullableDateTime(reader, "ValidTo"),
          true, null, null, null, PimDb.Int32(reader, "ProductCount"), 1));
    var items = new List<CustomerPackagingItem>();
    if (await reader.NextResultAsync(cancellationToken))
      while (await reader.ReadAsync(cancellationToken))
        items.Add(new(PimDb.TextOrEmpty(reader, "ItemID"), PimDb.Text(reader, "Name"), PimDb.NullableDecimal(reader, "Pak2"),
          PimDb.Text(reader, "DefaultCode"), PimDb.NullableDecimal(reader, "DefaultPercent"), PimDb.TextOrEmpty(reader, "DiscountCode"),
          PimDb.NullableDecimal(reader, "EffectivePercent"), PimDb.TextOrEmpty(reader, "Source"), PimDb.TextOrEmpty(reader, "ScopeKind"),
          PimDb.Int64(reader, "RuleId"), PimDb.Text(reader, "DiscountGroup"), PimDb.NullableInt64(reader, "ProductId")));
    return new(typeCode, typeName, enabled, special, defaults, rules, items);
  }

  /* --- Pomožno ------------------------------------------------------------------------------ */

  static PackagingRule ReadRule(SqlDataReader reader) => new(
    PimDb.Int64(reader, "RuleId"), PimDb.TextOrEmpty(reader, "TargetKind"), PimDb.TextOrEmpty(reader, "ScopeKind"),
    PimDb.Text(reader, "TargetCode"), PimDb.Text(reader, "TargetName"), PimDb.Text(reader, "MagentoGroupKey"),
    PimDb.Text(reader, "ItemID"), PimDb.Text(reader, "ItemGroupCode"), PimDb.Text(reader, "FromDiscountCode"),
    PimDb.TextOrEmpty(reader, "DiscountCode"), PimDb.NullableDecimal(reader, "PercentValue"),
    PimDb.NullableDateTime(reader, "ValidFrom"), PimDb.NullableDateTime(reader, "ValidTo"), PimDb.Bool(reader, "IsActive"),
    PimDb.Text(reader, "Note"), PimDb.NullableDateTime(reader, "UpdatedUtc"), PimDb.Text(reader, "UpdatedBy"),
    PimDb.Int32(reader, "ProductCount"), PimDb.Int32(reader, "CustomerCount"));

  async Task<IReadOnlyList<T>> QueryAsync<T>(string sql, Func<SqlDataReader, T> map, Action<SqlCommand>? bind,
    CancellationToken cancellationToken)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand(sql, connection) { CommandTimeout = 120 };
    bind?.Invoke(command);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    var rows = new List<T>();
    while (await reader.ReadAsync(cancellationToken)) rows.Add(map(reader));
    return rows;
  }

  async Task ExecAsync(string procedure, Action<SqlCommand> bind, CancellationToken cancellationToken)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand(procedure, connection) { CommandType = CommandType.StoredProcedure };
    bind(command);
    await command.ExecuteNonQueryAsync(cancellationToken);
  }

  /// <summary>Uvozi pišejo veliko pravil zapored: ena odprta povezava namesto ene na pravilo.</summary>
  async Task RunAsync(SqlConnection? connection, Func<SqlConnection, Task> action, CancellationToken cancellationToken)
  {
    if (connection is not null) { await action(connection); return; }
    await using var owned = new SqlConnection(ConnectionString);
    await owned.OpenAsync(cancellationToken);
    await action(owned);
  }

  /// <summary>Odprta povezava za zaporedne zapise (uvoz).</summary>
  public async Task<SqlConnection> OpenAsync(CancellationToken cancellationToken = default)
  {
    var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    return connection;
  }

  static object Db(string? value) => string.IsNullOrWhiteSpace(value) ? DBNull.Value : value.Trim();

  static void AddDecimal(SqlCommand command, string name, decimal value)
  {
    var parameter = command.Parameters.Add(name, SqlDbType.Decimal);
    parameter.Precision = 9;
    parameter.Scale = 4;
    parameter.Value = value;
  }
}
