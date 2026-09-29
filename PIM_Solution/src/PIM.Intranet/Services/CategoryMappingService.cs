using Microsoft.Data.SqlClient;

namespace PIM.Intranet.Services;

/// <summary>
/// Preslikave kategorij in ročna uvrstitev izdelka — edina zapisovalna pot intraneta za
/// kategorije.
///
/// Zakaj svoj servis in ne razširitev <see cref="PipelineReadService"/>: ta bere, ta piše.
/// Do migracije 109 je imela shema <c>intranet</c> trideset postopkov <c>Get*</c> in nobenega
/// <c>Save*</c>; mešanje branja in pisanja v en razred bi to razliko zabrisalo prav v trenutku,
/// ko je prvič postala pomembna.
///
/// Vsa pravila so v bazi (109), ne tukaj. Servis ne presoja, ali je preslikava smiselna —
/// postopek zavrne neobstoječo kategorijo, kategorijo brez prevedene poti in spremembo brez
/// akterja. Napako pokažemo uporabniku takšno, kot jo je povedala baza.
/// </summary>
public sealed class CategoryMappingService(PimDb database, IConfiguration configuration, PimWriteGuard guard)
{
  string ConnectionString => ConnectionStringResolver.Resolve(configuration)
    ?? throw new InvalidOperationException("Povezava PIM ni nastavljena.");

  /// <summary>Ena vrstica delovnega seznama: kaj je poslal vir in kam to gre pri nas.</summary>
  public sealed record MappingRow(
    string SourceCode,
    string CategoryTreeCode,
    string SourcePathKey,
    string? SourceLevel1,
    string? SourceLevel2,
    string? SourceLevel3,
    long ProductCount,
    DateTime? LastSeenUtc,
    string? CategoryCode,
    string? CategoryPath,
    string State,
    DateTime? UpdatedUtc,
    string? UpdatedBy);

  /// <summary>Vozlišče drevesa za izbirnik. Pot je tista, ki jo človek vidi v trgovini.</summary>
  public sealed record TreeNode(string CategoryCode, string CategoryName, int LevelNo, string? ParentCategoryCode, string? CategoryPath);

  /// <summary>Uvrstitev enega izdelka na eni spletni strani.</summary>
  public sealed record ProductCategoryRow(
    string WebSiteCode,
    string WebSiteName,
    string CategoryTreeCode,
    string? CategoryPaths,
    bool IsManual,
    string? SetBy,
    DateTime? SetUtc);

  public async Task<(IReadOnlyList<MappingRow> Rows, long Total)> GetMappingsAsync(
    string? sourceCode, string? categoryTreeCode, string? state, string? search,
    int page, int pageSize, CancellationToken cancellationToken = default)
  {
    long total = 0;
    var rows = await database.QueryAsync(
      "EXEC intranet.GetCategoryMappings @SourceCode, @CategoryTreeCode, @Stanje, @Iskanje, @Stran, @NaStran;",
      reader =>
      {
        // Skupno število pride iz istega branja (COUNT(*) OVER()), da položaj strani ne
        // potrebuje drugega obiska baze in ne more zaostajati za seznamom.
        total = PimDb.Int64(reader, "SkupajVrstic");
        return new MappingRow(
          PimDb.TextOrEmpty(reader, "SourceCode"),
          PimDb.TextOrEmpty(reader, "CategoryTreeCode"),
          PimDb.TextOrEmpty(reader, "SourcePathKey"),
          PimDb.Text(reader, "SourceLevel1"),
          PimDb.Text(reader, "SourceLevel2"),
          PimDb.Text(reader, "SourceLevel3"),
          PimDb.Int64(reader, "ProductCount"),
          PimDb.NullableDateTime(reader, "LastSeenUtc"),
          PimDb.Text(reader, "CategoryCode"),
          PimDb.Text(reader, "CategoryPath"),
          PimDb.TextOrEmpty(reader, "Stanje"),
          PimDb.NullableDateTime(reader, "UpdatedUtc"),
          PimDb.Text(reader, "UpdatedBy"));
      },
      command =>
      {
        command.Parameters.AddWithValue("@SourceCode", Nullable(sourceCode));
        command.Parameters.AddWithValue("@CategoryTreeCode", Nullable(categoryTreeCode));
        command.Parameters.AddWithValue("@Stanje", Nullable(state));
        command.Parameters.AddWithValue("@Iskanje", Nullable(search));
        command.Parameters.AddWithValue("@Stran", page);
        command.Parameters.AddWithValue("@NaStran", pageSize);
      }, cancellationToken);
    return (rows, total);
  }

  public Task<IReadOnlyList<TreeNode>> GetTreeNodesAsync(
    string categoryTreeCode, string? search, CancellationToken cancellationToken = default) =>
    database.QueryAsync(
      "EXEC intranet.GetCategoryTreeNodes @CategoryTreeCode, @Iskanje;",
      reader => new TreeNode(
        PimDb.TextOrEmpty(reader, "CategoryCode"),
        PimDb.TextOrEmpty(reader, "CategoryName"),
        PimDb.Int32(reader, "LevelNo"),
        PimDb.Text(reader, "ParentCategoryCode"),
        PimDb.Text(reader, "CategoryPath")),
      command =>
      {
        command.Parameters.AddWithValue("@CategoryTreeCode", categoryTreeCode);
        command.Parameters.AddWithValue("@Iskanje", Nullable(search));
      }, cancellationToken);

  /// <summary>Kategorija za izbiro na kartici: pot v jeziku spletne strani (to se shrani) in slovenska pot za iskanje.</summary>
  public sealed record SitePathOption(string CategoryCode, int LevelNo, string SlName, string SlPath, string SitePath);

  /// <summary>
  /// Poti drevesa spletne strani v njenem jeziku (canon.WebSite.LanguageCode). Uporabnik 2026-09-29: pri
  /// »Videlektro (ANG)« je izbirnik ponujal slovenske poti — isče se po slovensko, shrani pa pot v jeziku strani,
  /// ker pim.SetProductCategories preverja pot v canon.CategoryPathTranslated za jezik te strani.
  /// </summary>
  public Task<IReadOnlyList<SitePathOption>> GetSitePathOptionsAsync(string webSiteCode, CancellationToken cancellationToken = default) =>
    database.QueryAsync(
      """
      SELECT node.CategoryCode, node.LevelNo, SlName = node.CategoryName,
        SlPath = COALESCE(slPath.CategoryPath, sitePath.CategoryPath), SitePath = sitePath.CategoryPath
      FROM canon.WebSite AS site
      INNER JOIN canon.Category AS node ON node.CategoryTreeCode = site.CategoryTreeCode AND node.IsActive = 1
      INNER JOIN canon.CategoryPathTranslated AS sitePath
        ON sitePath.CategoryTreeCode = site.CategoryTreeCode AND sitePath.CategoryCode = node.CategoryCode
       AND sitePath.LanguageCode = site.LanguageCode
      LEFT JOIN canon.CategoryPathTranslated AS slPath
        ON slPath.CategoryTreeCode = site.CategoryTreeCode AND slPath.CategoryCode = node.CategoryCode AND slPath.LanguageCode = N'sl'
      WHERE site.WebSiteCode = @WebSite
      ORDER BY COALESCE(slPath.CategoryPath, sitePath.CategoryPath);
      """,
      reader => new SitePathOption(
        PimDb.TextOrEmpty(reader, "CategoryCode"),
        PimDb.Int32(reader, "LevelNo"),
        PimDb.TextOrEmpty(reader, "SlName"),
        PimDb.TextOrEmpty(reader, "SlPath"),
        PimDb.TextOrEmpty(reader, "SitePath")),
      command => command.Parameters.AddWithValue("@WebSite", webSiteCode), cancellationToken);

  public Task<IReadOnlyList<string>> GetSourceCodesAsync(CancellationToken cancellationToken = default) =>
    database.QueryAsync(
      "SELECT DISTINCT SourceCode FROM map.SourceCategory ORDER BY SourceCode;",
      reader => PimDb.TextOrEmpty(reader, "SourceCode"), null, cancellationToken);

  public Task<IReadOnlyList<string>> GetTreeCodesAsync(CancellationToken cancellationToken = default) =>
    database.QueryAsync(
      "SELECT DISTINCT CategoryTreeCode FROM canon.WebSite WHERE IsActive = 1 ORDER BY CategoryTreeCode;",
      reader => PimDb.TextOrEmpty(reader, "CategoryTreeCode"), null, cancellationToken);

  /// <summary>Zapiše ali popravi preslikavo. Vrne izid postopka (Created / Updated / Unchanged).</summary>
  public Task<string> SaveMappingAsync(
    string sourceCode, string categoryTreeCode, string sourcePathKey, string categoryCode,
    string actor, string? note, CancellationToken cancellationToken = default) =>
    ScalarTextAsync(
      "EXEC map.SaveCategoryPathMap @SourceCode, @CategoryTreeCode, @SourcePathKey, @CategoryCode, @Actor, @Note;",
      command =>
      {
        command.Parameters.AddWithValue("@SourceCode", sourceCode);
        command.Parameters.AddWithValue("@CategoryTreeCode", categoryTreeCode);
        command.Parameters.AddWithValue("@SourcePathKey", sourcePathKey);
        command.Parameters.AddWithValue("@CategoryCode", categoryCode);
        command.Parameters.AddWithValue("@Actor", actor);
        command.Parameters.AddWithValue("@Note", Nullable(note));
      }, cancellationToken);

  public Task<string> DeactivateMappingAsync(
    string sourceCode, string categoryTreeCode, string sourcePathKey,
    string actor, string? note, CancellationToken cancellationToken = default) =>
    ScalarTextAsync(
      "EXEC map.DeactivateCategoryPathMap @SourceCode, @CategoryTreeCode, @SourcePathKey, @Actor, @Note;",
      command =>
      {
        command.Parameters.AddWithValue("@SourceCode", sourceCode);
        command.Parameters.AddWithValue("@CategoryTreeCode", categoryTreeCode);
        command.Parameters.AddWithValue("@SourcePathKey", sourcePathKey);
        command.Parameters.AddWithValue("@Actor", actor);
        command.Parameters.AddWithValue("@Note", Nullable(note));
      }, cancellationToken);

  public Task<IReadOnlyList<ProductCategoryRow>> GetProductCategoriesAsync(
    int organizationId, string itemId, CancellationToken cancellationToken = default) =>
    database.QueryAsync(
      "EXEC intranet.GetProductCategories @OrganizationId, @ItemID;",
      reader => new ProductCategoryRow(
        PimDb.TextOrEmpty(reader, "WebSiteCode"),
        PimDb.TextOrEmpty(reader, "WebSiteName"),
        PimDb.TextOrEmpty(reader, "CategoryTreeCode"),
        PimDb.Text(reader, "CategoryPaths"),
        PimDb.Bool(reader, "JeRocna"),
        PimDb.Text(reader, "SetBy"),
        PimDb.NullableDateTime(reader, "SetUtc")),
      command =>
      {
        command.Parameters.AddWithValue("@OrganizationId", organizationId);
        command.Parameters.AddWithValue("@ItemID", itemId);
      }, cancellationToken);

  /// <summary>
  /// Postavi celoten nabor kategorij izdelka na eni spletni strani. Prazen seznam pomeni
  /// »namenoma brez kategorije« in ni isto kot »še ni preslikano«.
  /// </summary>
  public async Task<string> SetProductCategoriesAsync(
    int organizationId, string itemId, string webSite, IReadOnlyList<string> categoryPaths,
    string actor, string? note, CancellationToken cancellationToken = default)
  {
    // 2026-09-28: urejanje je zdaj tudi na kartici izdelka, ki jo odpre vsaka vloga — vloga se preveri tu.
    await guard.RequireAsync(PimPolicies.CatalogWrite);
    return await ScalarTextAsync(
      "EXEC pim.SetProductCategories @OrganizationId, @ItemID, @WebSite, @CategoryPathsJson, @Actor, @Note;",
      command =>
      {
        command.Parameters.AddWithValue("@OrganizationId", organizationId);
        command.Parameters.AddWithValue("@ItemID", itemId);
        command.Parameters.AddWithValue("@WebSite", webSite);
        command.Parameters.AddWithValue("@CategoryPathsJson",
          System.Text.Json.JsonSerializer.Serialize(categoryPaths));
        command.Parameters.AddWithValue("@Actor", actor);
        command.Parameters.AddWithValue("@Note", Nullable(note));
      }, cancellationToken);
  }

  public async Task<string> ClearProductCategoryOverrideAsync(
    int organizationId, string itemId, string webSite, string actor,
    CancellationToken cancellationToken = default)
  {
    await guard.RequireAsync(PimPolicies.CatalogWrite);
    return await ScalarTextAsync(
      "EXEC pim.ClearProductCategoryOverride @OrganizationId, @ItemID, @WebSite, @Actor;",
      command =>
      {
        command.Parameters.AddWithValue("@OrganizationId", organizationId);
        command.Parameters.AddWithValue("@ItemID", itemId);
        command.Parameters.AddWithValue("@WebSite", webSite);
        command.Parameters.AddWithValue("@Actor", actor);
      }, cancellationToken);
  }

  async Task<string> ScalarTextAsync(string sql, Action<SqlCommand> bind, CancellationToken cancellationToken)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand(sql, connection);
    bind(command);
    var value = await command.ExecuteScalarAsync(cancellationToken);
    return value is null or DBNull ? string.Empty : Convert.ToString(value) ?? string.Empty;
  }

  static object Nullable(string? value) =>
    string.IsNullOrWhiteSpace(value) ? DBNull.Value : value;
}
