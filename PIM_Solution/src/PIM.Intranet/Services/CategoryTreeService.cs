using System.Text.Json;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Caching.Memory;

namespace PIM.Intranet.Services;

/// <summary>
/// Drevo kategorij in prevodi imen.
///
/// Ločeno od <see cref="CategoryMappingService"/>: tam gre za vprašanje »kam sodi dobaviteljeva
/// pot«, tu za vprašanje »kako je naše drevo videti in kako se imenuje v posameznem jeziku«.
/// Prvo je preslikava vira, drugo je katalog sam.
/// </summary>
/// <param name="cache">Predpomnilnik procesa za izbirnik kategorij; neobvezen, da ga testi lahko izpustijo.</param>
public sealed class CategoryTreeService(PimDb database, IConfiguration configuration, PimWriteGuard guard, IMemoryCache? cache = null)
{
  static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true };

  string ConnectionString => ConnectionStringResolver.Resolve(configuration)
    ?? throw new InvalidOperationException("Povezava PIM ni nastavljena.");

  /// <param name="IsMatch">
  /// Ali je vrstica zadetek filtra ali samo prednik zadetka. Predniki so vedno prisotni, ker je
  /// zadetek brez njih iztrgan iz drevesa in bralec ne vidi, kje stoji.
  /// </param>
  /// <param name="Translations">Vsi zapisani prevodi te kategorije, po jeziku.</param>
  public sealed record TreeRow(
    string CategoryTreeCode,
    string CategoryCode,
    string? ParentCategoryCode,
    int LevelNo,
    string CategoryName,
    string CategoryPath,
    bool IsActive,
    int MissingLanguages,
    string? MissingLanguageList,
    IReadOnlyDictionary<string, string> Translations,
    long ProductCount,
    long DescendantProductCount,
    long ChildCount,
    bool IsMatch,
    int LanguageCount);

  public sealed record CoverageRow(string LanguageCode, string LanguageName, long Categories, long Translated, long Missing)
  {
    public int Percent => Categories == 0 ? 0 : (int)Math.Round(100.0 * Translated / Categories);
  }

  public sealed record LanguageOptionRow(string LanguageCode, string Name);

  sealed record TranslationEntry(string? Lang, string? Name);

  public Task<IReadOnlyList<TreeRow>> GetTreeAsync(
    string? categoryTreeCode, int? organizationId, string languageCode, string? search,
    string? branch, bool onlyMissingTranslation, bool onlyWithProducts, int? level,
    CancellationToken cancellationToken = default) =>
    database.QueryAsync(
      "EXEC intranet.GetCategoryTree @CategoryTreeCode, @OrganizationId, @LanguageCode, @Iskanje, @Veja, @SamoBrezPrevoda, @SamoZIzdelki, @Nivo;",
      reader => new TreeRow(
        PimDb.TextOrEmpty(reader, "CategoryTreeCode"),
        PimDb.TextOrEmpty(reader, "CategoryCode"),
        PimDb.Text(reader, "ParentCategoryCode"),
        PimDb.Int32(reader, "LevelNo"),
        PimDb.TextOrEmpty(reader, "CategoryName"),
        PimDb.TextOrEmpty(reader, "CategoryPath"),
        PimDb.Bool(reader, "IsActive"),
        PimDb.Int32(reader, "MissingLanguages"),
        PimDb.Text(reader, "MissingLanguageList"),
        ParseTranslations(PimDb.Text(reader, "TranslationsJson")),
        PimDb.Int64(reader, "ProductCount"),
        PimDb.Int64(reader, "DescendantProductCount"),
        PimDb.Int64(reader, "ChildCount"),
        PimDb.Int32(reader, "JeZadetek") == 1,
        PimDb.Int32(reader, "Jezikov")),
      command =>
      {
        command.Parameters.AddWithValue("@CategoryTreeCode", Nullable(categoryTreeCode));
        command.Parameters.AddWithValue("@OrganizationId", organizationId is null ? DBNull.Value : organizationId.Value);
        command.Parameters.AddWithValue("@LanguageCode", languageCode);
        command.Parameters.AddWithValue("@Iskanje", Nullable(search));
        command.Parameters.AddWithValue("@Veja", Nullable(branch));
        command.Parameters.AddWithValue("@SamoBrezPrevoda", onlyMissingTranslation);
        command.Parameters.AddWithValue("@SamoZIzdelki", onlyWithProducts);
        command.Parameters.AddWithValue("@Nivo", level is null ? DBNull.Value : level.Value);
      }, cancellationToken);

  public Task<IReadOnlyList<CoverageRow>> GetCoverageAsync(
    string? categoryTreeCode, CancellationToken cancellationToken = default) =>
    database.QueryAsync(
      "EXEC intranet.GetCategoryTranslationCoverage @CategoryTreeCode;",
      reader => new CoverageRow(
        PimDb.TextOrEmpty(reader, "LanguageCode"),
        PimDb.TextOrEmpty(reader, "LanguageName"),
        PimDb.Int64(reader, "Categories"),
        PimDb.Int64(reader, "Translated"),
        PimDb.Int64(reader, "Missing")),
      command => command.Parameters.AddWithValue("@CategoryTreeCode", Nullable(categoryTreeCode)),
      cancellationToken);

  public Task<IReadOnlyList<LanguageOptionRow>> GetLanguagesAsync(CancellationToken cancellationToken = default) =>
    database.QueryAsync(
      "SELECT DISTINCT LanguageCode, Name FROM canon.Language WHERE IsActive = 1 ORDER BY LanguageCode;",
      reader => new LanguageOptionRow(PimDb.TextOrEmpty(reader, "LanguageCode"), PimDb.TextOrEmpty(reader, "Name")),
      null, cancellationToken);

  public Task<IReadOnlyList<string>> GetTreeCodesAsync(CancellationToken cancellationToken = default) =>
    database.QueryAsync(
      "SELECT DISTINCT CategoryTreeCode FROM canon.Category ORDER BY CategoryTreeCode;",
      reader => PimDb.TextOrEmpty(reader, "CategoryTreeCode"), null, cancellationToken);

  /// <param name="CategoryPath">Slovenska pot; človek izbira po tem, kar vidi v trgovini.</param>
  /// <param name="ProductCount">Izdelki v tej kategoriji in pod njo.</param>
  /// <param name="AttributeCount">Koliko atributov ima učinkovit nabor te kategorije.</param>
  public sealed record CategoryPickRow(
    string CategoryTreeCode, string CategoryCode, string CategoryName, int LevelNo,
    string? CategoryPath, long ProductCount, int AttributeCount);

  /// <summary>
  /// Izbirnik kategorije za filter na seznamu izdelkov. Poleg imena pove dvoje, kar odloči, ali
  /// je izbira smiselna: koliko izdelkov je pod kategorijo in koliko atributov ima njen nabor.
  /// Brez tega bi uporabnik izbiral naslepo in šele po izvozu videl prazno datoteko.
  /// </summary>
  public async Task<IReadOnlyList<CategoryPickRow>> GetCategoryPickerAsync(
    string categoryTreeCode, CancellationToken cancellationToken = default)
  {
    // Izbirnik se spremeni sele ob urejanju kategorij ali uvrstitev, stran /izdelki pa ga bere ob
    // VSAKEM nalaganju za vsako drevo (2026-09-17: 1,3-1,8 s na drevo tudi po prepisu poizvedbe
    // spodaj, prej 6 s). Proces ga zato drzi pet minut v pomnilniku; brez predpomnilnika (testi,
    // ki servis sestavijo rocno) gre naravnost v bazo.
    if (cache is null) return await LoadCategoryPickerAsync(categoryTreeCode, cancellationToken);
    var rows = await cache.GetOrCreateAsync("category-picker:" + categoryTreeCode, async entry =>
    {
      entry.AbsoluteExpirationRelativeToNow = TimeSpan.FromMinutes(5);
      return await LoadCategoryPickerAsync(categoryTreeCode, cancellationToken);
    });
    return rows ?? [];
  }

  Task<IReadOnlyList<CategoryPickRow>> LoadCategoryPickerAsync(
    string categoryTreeCode, CancellationToken cancellationToken) =>
    database.QueryAsync(
      """
      /* 2026-09-17: prevedene poti drevesa se izracunajo ENKRAT (#Pot), uvrstitve izdelkov enkrat
         (#Uvrstitev), stevilo izdelkov v poddrevesu pa prek zaprtja prednik-potomec po poti
         (#Poddrevo). Prej je OUTER APPLY za vsako vozlisce znova izracunal rekurzivni pogled
         canon.CategoryPathTranslated - izmerjeno 6 s na drevo, dve drevesi ob VSAKEM nalaganju
         strani /izdelki. Uvrstitev na jezikovni razlicici strani se zdaj steje prek kode kategorije
         (prej samo, kadar se je pot v tujem jeziku slucajno ujela s slovensko predpono). */
      SELECT prevod.CategoryCode, prevod.LanguageCode, prevod.CategoryPath, spletna.SortOrder
      INTO #Pot
      FROM canon.CategoryPathTranslated AS prevod
      INNER JOIN canon.WebSite AS spletna
        ON spletna.CategoryTreeCode = prevod.CategoryTreeCode AND spletna.LanguageCode = prevod.LanguageCode
       AND spletna.IsActive = 1
      WHERE prevod.CategoryTreeCode = @CategoryTreeCode;

      SELECT CategoryCode, CategoryPath
      INTO #Prikaz
      FROM (SELECT CategoryCode, CategoryPath, ROW_NUMBER() OVER (PARTITION BY CategoryCode ORDER BY SortOrder) AS Vrsta FROM #Pot) AS izbor
      WHERE Vrsta = 1;

      SELECT DISTINCT productCategory.ProductId, prevod.CategoryCode
      INTO #Uvrstitev
      FROM canon.ProductCategory AS productCategory
      INNER JOIN canon.WebSite AS spletna
        ON spletna.WebSiteCode = productCategory.WebSite AND spletna.CategoryTreeCode = @CategoryTreeCode
      INNER JOIN #Pot AS prevod
        ON prevod.LanguageCode = spletna.LanguageCode AND prevod.CategoryPath = productCategory.CategoryPath;

      SELECT prednik.CategoryCode AS Prednik, potomec.CategoryCode AS Potomec
      INTO #Poddrevo
      FROM #Prikaz AS prednik
      INNER JOIN #Prikaz AS potomec
        ON potomec.CategoryCode = prednik.CategoryCode OR potomec.CategoryPath LIKE prednik.CategoryPath + N' > %';

      SELECT
        node.CategoryTreeCode, node.CategoryCode, node.CategoryName, node.LevelNo,
        CategoryPath = prikaz.CategoryPath,
        ProductCount = ISNULL(izdelki.Stevilo, 0),
        AttributeCount = ISNULL(nabor.Stevilo, 0)
      FROM canon.Category AS node
      LEFT JOIN #Prikaz AS prikaz ON prikaz.CategoryCode = node.CategoryCode
      LEFT JOIN
      (
        SELECT poddrevo.Prednik AS CategoryCode, Stevilo = COUNT_BIG(DISTINCT uvrstitev.ProductId)
        FROM #Poddrevo AS poddrevo
        INNER JOIN #Uvrstitev AS uvrstitev ON uvrstitev.CategoryCode = poddrevo.Potomec
        GROUP BY poddrevo.Prednik
      ) AS izdelki ON izdelki.CategoryCode = node.CategoryCode
      OUTER APPLY
      (
        SELECT Stevilo = COUNT(*)
        FROM canon.CategoryAttributeEffective(node.CategoryTreeCode, node.CategoryCode) AS ucinkovit
        WHERE ucinkovit.Level <> N'EXCLUDED'
      ) AS nabor
      WHERE node.CategoryTreeCode = @CategoryTreeCode AND node.IsActive = 1
      ORDER BY prikaz.CategoryPath, node.CategoryName;

      DROP TABLE #Poddrevo; DROP TABLE #Uvrstitev; DROP TABLE #Prikaz; DROP TABLE #Pot;
      """,
      reader => new CategoryPickRow(
        PimDb.TextOrEmpty(reader, "CategoryTreeCode"), PimDb.TextOrEmpty(reader, "CategoryCode"),
        PimDb.TextOrEmpty(reader, "CategoryName"), PimDb.Int32(reader, "LevelNo"),
        PimDb.Text(reader, "CategoryPath"), PimDb.Int64(reader, "ProductCount"),
        PimDb.Int32(reader, "AttributeCount")),
      command => command.Parameters.AddWithValue("@CategoryTreeCode", categoryTreeCode),
      cancellationToken);

  /// <param name="Changed">Število spremenjenih jezikov.</param>
  /// <param name="CategoryCode">
  /// Koda kategorije po shranjevanju. Če se je slovensko ime spremenilo, migracija 223 preimenuje
  /// tudi kodo (in pot) vozlišča ter vse potomce, zato ta koda ni nujno enaka vhodni.
  /// </param>
  public sealed record SaveTranslationsResult(int Changed, string CategoryCode);

  /// <summary>
  /// Zapiše prevode ene kategorije v več jezikih hkrati. Če en jezik pade na pravilu, ne obvelja
  /// noben — delno shranjen prevod izgleda opravljen. Sprememba slovenskega imena preimenuje tudi
  /// kodo in pot kategorije (glej 223), zato klicatelj po klicu uporabi vrnjeno CategoryCode.
  /// </summary>
  public async Task<SaveTranslationsResult> SaveTranslationsAsync(
    string categoryTreeCode, string categoryCode, IReadOnlyDictionary<string, string> translations,
    string actor, CancellationToken cancellationToken = default)
  {
    await guard.RequireAsync(PimPolicies.CatalogWrite);
    var payload = JsonSerializer.Serialize(
      translations.Select(pair => new { lang = pair.Key, name = pair.Value }));

    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand(
      "EXEC canon.SaveCategoryTranslations @CategoryTreeCode, @CategoryCode OUTPUT, @TranslationsJson, @Actor;",
      connection);
    command.Parameters.AddWithValue("@CategoryTreeCode", categoryTreeCode);
    var categoryCodeParameter = command.Parameters.Add("@CategoryCode", System.Data.SqlDbType.NVarChar, 400);
    categoryCodeParameter.Direction = System.Data.ParameterDirection.InputOutput;
    categoryCodeParameter.Value = categoryCode;
    command.Parameters.AddWithValue("@TranslationsJson", payload);
    command.Parameters.AddWithValue("@Actor", actor);
    var value = await command.ExecuteScalarAsync(cancellationToken);
    var changed = value is null or DBNull ? 0 : Convert.ToInt32(value);
    if (changed > 0) ClearPickerCache([categoryTreeCode]);
    return new SaveTranslationsResult(changed, (string)categoryCodeParameter.Value);
  }

  // --- Nabor atributov po kategoriji (migracija 147) -------------------------------------

  /// <param name="IsInherited">Vrstica je podedovana od prednika (DefinedAtCategoryCode).</param>
  public sealed record AttributeSetRow(
    string AttributeCode, string AttributeName, string Level, int SortOrder, string? Note,
    string DefinedAtCategoryCode, string? DefinedAtCategoryName, bool IsInherited,
    long ProductCount, long ProductsWithValue);

  /// <summary>Atribut, ki ga izdelki kategorije ze nosijo, a ga nabor ne omenja — predlog za dodajanje.</summary>
  public sealed record AttributeSuggestionRow(string AttributeCode, string AttributeName, long ProductsWithValue, bool InRegister);

  public sealed record AttributeOptionRow(string AttributeCode, string Name);

  public sealed record AttributeSetView(IReadOnlyList<AttributeSetRow> Rows, IReadOnlyList<AttributeSuggestionRow> Suggestions);

  public async Task<AttributeSetView> GetAttributeSetAsync(
    string categoryTreeCode, string categoryCode, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.GetCategoryAttributeSet", connection)
    {
      CommandType = System.Data.CommandType.StoredProcedure, CommandTimeout = 60,
    };
    command.Parameters.AddWithValue("@CategoryTreeCode", categoryTreeCode);
    command.Parameters.AddWithValue("@CategoryCode", categoryCode);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    var rows = new List<AttributeSetRow>();
    while (await reader.ReadAsync(cancellationToken))
      rows.Add(new(
        PimDb.TextOrEmpty(reader, "AttributeCode"), PimDb.TextOrEmpty(reader, "AttributeName"),
        PimDb.TextOrEmpty(reader, "Level"), PimDb.Int32(reader, "SortOrder"), PimDb.Text(reader, "Note"),
        PimDb.TextOrEmpty(reader, "DefinedAtCategoryCode"), PimDb.Text(reader, "DefinedAtCategoryName"),
        PimDb.Bool(reader, "IsInherited"), PimDb.Int64(reader, "ProductCount"), PimDb.Int64(reader, "ProductsWithValue")));
    var suggestions = new List<AttributeSuggestionRow>();
    if (await reader.NextResultAsync(cancellationToken))
      while (await reader.ReadAsync(cancellationToken))
        suggestions.Add(new(
          PimDb.TextOrEmpty(reader, "AttributeCode"), PimDb.TextOrEmpty(reader, "AttributeName"),
          PimDb.Int64(reader, "ProductsWithValue"), PimDb.Bool(reader, "InRegister")));
    return new(rows, suggestions);
  }

  public Task<IReadOnlyList<AttributeOptionRow>> GetAttributeOptionsAsync(CancellationToken cancellationToken = default) =>
    database.QueryAsync(
      """
      SELECT definition.AttributeCode, Name = COALESCE(translation.Name, definition.AttributeCode)
      FROM canon.AttributeDefinition AS definition
      LEFT JOIN canon.AttributeTranslation AS translation
        ON translation.AttributeCode = definition.AttributeCode AND translation.LanguageCode = N'sl'
      WHERE definition.IsActive = 1
      ORDER BY Name;
      """,
      reader => new AttributeOptionRow(PimDb.TextOrEmpty(reader, "AttributeCode"), PimDb.TextOrEmpty(reader, "Name")),
      null, cancellationToken);

  /// <summary>Raven null odstrani atribut iz nabora te kategorije. Pravilo in revizija sta v proceduri.</summary>
  public async Task SaveAttributeSetAsync(
    string categoryTreeCode, string categoryCode, string attributeCode, string? level, string actor,
    CancellationToken cancellationToken = default)
  {
    await guard.RequireAsync(PimPolicies.CatalogWrite);
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand(
      "EXEC canon.SaveCategoryAttributeSet @CategoryTreeCode, @CategoryCode, @AttributeCode, @Level, @Actor, NULL;", connection);
    command.Parameters.AddWithValue("@CategoryTreeCode", categoryTreeCode);
    command.Parameters.AddWithValue("@CategoryCode", categoryCode);
    command.Parameters.AddWithValue("@AttributeCode", attributeCode);
    command.Parameters.AddWithValue("@Level", Nullable(level));
    command.Parameters.AddWithValue("@Actor", actor);
    await command.ExecuteNonQueryAsync(cancellationToken);
    ClearPickerCache([categoryTreeCode]);
  }

  // --- Pregled naborov po kategorijah (migracija 170) ------------------------------------

  /// <param name="WebProfileCode">Spletni profil drevesa; brez njega shranjevanje nabora ni mogoce (147).</param>
  public sealed record TreeSummaryRow(
    string CategoryTreeCode, long Categories, long CategoriesWithOwnSet, long ProductCount,
    string? WebSites, string? WebProfileCode);

  /// <param name="EffectiveNames">Imena atributov v ucinkovitem naboru; obvezni imajo zvezdico.</param>
  /// <param name="UsedNotInSetCount">Razlicni atributi, ki jih izdelki poddrevesa nosijo, nabor pa jih ne omenja.</param>
  public sealed record OverviewRow(
    string CategoryTreeCode, string CategoryCode, string? ParentCategoryCode, int LevelNo,
    string CategoryName, string CategoryPath, bool IsActive,
    long ProductCount, long DescendantProductCount, long ChildCount,
    int OwnRequired, int OwnRecommended, int OwnExcluded,
    int EffectiveRequired, int EffectiveRecommended, int EffectiveExcluded, int InheritedCount,
    string? EffectiveNames, int UsedAttributeCount, int UsedNotInSetCount)
  {
    public int OwnCount => OwnRequired + OwnRecommended + OwnExcluded;
    public int EffectiveCount => EffectiveRequired + EffectiveRecommended;
    public bool HasOwnSet => OwnCount > 0;
    public bool HasEffectiveSet => EffectiveCount > 0;
  }

  public sealed record OverviewSummary(
    long Categories, long CategoriesWithOwnSet, long CategoriesWithEffectiveSet, long OwnRows,
    long ProductCount, long ProductsUnderSet, long AttributesInRegister, string? WebProfileCode);

  public sealed record OverviewView(IReadOnlyList<OverviewRow> Rows, OverviewSummary Summary);

  public Task<IReadOnlyList<TreeSummaryRow>> GetAttributeSetTreesAsync(CancellationToken cancellationToken = default) =>
    database.QueryAsync(
      "EXEC intranet.GetCategoryAttributeSetTrees;",
      reader => new TreeSummaryRow(
        PimDb.TextOrEmpty(reader, "CategoryTreeCode"), PimDb.Int64(reader, "Categories"),
        PimDb.Int64(reader, "CategoriesWithOwnSet"), PimDb.Int64(reader, "ProductCount"),
        PimDb.Text(reader, "WebSites"), PimDb.Text(reader, "WebProfileCode")),
      null, cancellationToken);

  public async Task<OverviewView> GetAttributeSetOverviewAsync(
    string categoryTreeCode, string? search, bool onlyWithoutSet, bool onlyWithProducts, int? levelNo,
    CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.GetCategoryAttributeSetOverview", connection)
    {
      CommandType = System.Data.CommandType.StoredProcedure, CommandTimeout = 120,
    };
    command.Parameters.AddWithValue("@CategoryTreeCode", categoryTreeCode);
    command.Parameters.AddWithValue("@Search", Nullable(search));
    command.Parameters.AddWithValue("@OnlyWithoutSet", onlyWithoutSet);
    command.Parameters.AddWithValue("@OnlyWithProducts", onlyWithProducts);
    command.Parameters.AddWithValue("@LevelNo", levelNo is null ? DBNull.Value : levelNo.Value);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    var rows = new List<OverviewRow>();
    while (await reader.ReadAsync(cancellationToken))
      rows.Add(new(
        PimDb.TextOrEmpty(reader, "CategoryTreeCode"), PimDb.TextOrEmpty(reader, "CategoryCode"),
        PimDb.Text(reader, "ParentCategoryCode"), PimDb.Int32(reader, "LevelNo"),
        PimDb.TextOrEmpty(reader, "CategoryName"), PimDb.TextOrEmpty(reader, "CategoryPath"), PimDb.Bool(reader, "IsActive"),
        PimDb.Int64(reader, "ProductCount"), PimDb.Int64(reader, "DescendantProductCount"), PimDb.Int64(reader, "ChildCount"),
        PimDb.Int32(reader, "OwnRequired"), PimDb.Int32(reader, "OwnRecommended"), PimDb.Int32(reader, "OwnExcluded"),
        PimDb.Int32(reader, "EffectiveRequired"), PimDb.Int32(reader, "EffectiveRecommended"), PimDb.Int32(reader, "EffectiveExcluded"),
        PimDb.Int32(reader, "InheritedCount"), PimDb.Text(reader, "EffectiveNames"),
        PimDb.Int32(reader, "UsedAttributeCount"), PimDb.Int32(reader, "UsedNotInSetCount")));
    var summary = new OverviewSummary(0, 0, 0, 0, 0, 0, 0, null);
    if (await reader.NextResultAsync(cancellationToken) && await reader.ReadAsync(cancellationToken))
      summary = new(
        PimDb.Int64(reader, "Categories"), PimDb.Int64(reader, "CategoriesWithOwnSet"),
        PimDb.Int64(reader, "CategoriesWithEffectiveSet"), PimDb.Int64(reader, "OwnRows"),
        PimDb.Int64(reader, "ProductCount"), PimDb.Int64(reader, "ProductsUnderSet"),
        PimDb.Int64(reader, "AttributesInRegister"), PimDb.Text(reader, "WebProfileCode"));
    return new(rows, summary);
  }

  /// <param name="Level">REQUIRED, RECOMMENDED, EXCLUDED ali null = odstrani iz nabora.</param>
  /// <param name="CodeOrName">Koda iz registra ali slovensko ime atributa (seznami iz mastrov nosijo imena).</param>
  public sealed record AttributeSetItem(string CodeOrName, string? Level);

  /// <summary>Vec atributov ene kategorije v enem klicu. Neznane atribute postopek zavrne vse naenkrat, nic se ne shrani.</summary>
  public async Task<int> SaveAttributeSetBulkAsync(
    string categoryTreeCode, string categoryCode, IReadOnlyList<AttributeSetItem> items, string actor,
    CancellationToken cancellationToken = default)
  {
    await guard.RequireAsync(PimPolicies.CatalogWrite);
    var payload = JsonSerializer.Serialize(items.Select(item => new { code = item.CodeOrName, level = item.Level }));
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand(
      "EXEC canon.SaveCategoryAttributeSetBulk @CategoryTreeCode, @CategoryCode, @ItemsJson, @Actor, @Saved OUTPUT;", connection)
    { CommandTimeout = 120 };
    command.Parameters.AddWithValue("@CategoryTreeCode", categoryTreeCode);
    command.Parameters.AddWithValue("@CategoryCode", categoryCode);
    command.Parameters.AddWithValue("@ItemsJson", payload);
    command.Parameters.AddWithValue("@Actor", actor);
    var saved = command.Parameters.Add("@Saved", System.Data.SqlDbType.Int);
    saved.Direction = System.Data.ParameterDirection.Output;
    await command.ExecuteNonQueryAsync(cancellationToken);
    ClearPickerCache([categoryTreeCode]);
    return saved.Value is int count ? count : 0;
  }

  // --- Register iz nabora (migracija 177) -------------------------------------------------

  /// <param name="AttributeCode">Koda v registru; null = imena ni v registru.</param>
  /// <param name="ProposedCode">Koda, ki bi jo ime dobilo ob ustvarjanju (canon.AttributeCodeFromName).</param>
  public sealed record ResolvedAttributeName(string Given, string? AttributeCode, string AttributeName, string ProposedCode);

  /// <summary>Katera imena ali kode so v registru in katere ne — pred zapisom, da stran ponudi ustvarjanje.</summary>
  public Task<IReadOnlyList<ResolvedAttributeName>> ResolveAttributeNamesAsync(
    IReadOnlyCollection<string> names, CancellationToken cancellationToken = default) =>
    database.QueryAsync(
      "EXEC canon.ResolveAttributeNames @NamesJson;",
      reader => new ResolvedAttributeName(
        PimDb.TextOrEmpty(reader, "Given"), PimDb.Text(reader, "AttributeCode"),
        PimDb.TextOrEmpty(reader, "AttributeName"), PimDb.TextOrEmpty(reader, "ProposedCode")),
      command => command.Parameters.AddWithValue("@NamesJson", JsonSerializer.Serialize(names)),
      cancellationToken);

  /// <summary>Atribut po slovenskem imenu: obstojecega vrne, neaktivnega vklopi, novega ustvari. Vrne kodo.</summary>
  public async Task<string> EnsureAttributeDefinitionAsync(string name, string actor, CancellationToken cancellationToken = default)
  {
    await guard.RequireAsync(PimPolicies.CatalogWrite);
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("EXEC canon.EnsureAttributeDefinition @Name, @Actor, @AttributeCode OUTPUT;", connection);
    command.Parameters.AddWithValue("@Name", name);
    command.Parameters.AddWithValue("@Actor", actor);
    var code = command.Parameters.Add("@AttributeCode", System.Data.SqlDbType.NVarChar, 200);
    code.Direction = System.Data.ParameterDirection.Output;
    await command.ExecuteNonQueryAsync(cancellationToken);
    return code.Value as string ?? throw new InvalidOperationException($"Atributa »{name}« ni bilo mogoče ustvariti.");
  }

  /// <summary>Nova kategorija pod starsem (null = koren) — 178. Postopek zavrne isto ime pod istim starsem. Vrne kodo.</summary>
  public async Task<string> CreateCategoryAsync(string categoryTreeCode, string? parentCategoryCode, string name, string actor, CancellationToken cancellationToken = default)
  {
    await guard.RequireAsync(PimPolicies.CatalogWrite);
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("EXEC canon.SaveCategory @CategoryTreeCode, @ParentCategoryCode, @Name, @Actor, @CategoryCode OUTPUT;", connection);
    command.Parameters.AddWithValue("@CategoryTreeCode", categoryTreeCode);
    command.Parameters.AddWithValue("@ParentCategoryCode", Nullable(parentCategoryCode));
    command.Parameters.AddWithValue("@Name", name);
    command.Parameters.AddWithValue("@Actor", actor);
    var code = command.Parameters.Add("@CategoryCode", System.Data.SqlDbType.NVarChar, 200);
    code.Direction = System.Data.ParameterDirection.Output;
    await command.ExecuteNonQueryAsync(cancellationToken);
    var created = code.Value as string ?? throw new InvalidOperationException($"Kategorije »{name}« ni bilo mogoče ustvariti.");
    ClearPickerCache([categoryTreeCode]);
    return created;
  }

  // --- Premikanje in trajno brisanje kategorij (migracija 228) ---------------------------

  public sealed record CategoryRef(string CategoryTreeCode, string CategoryCode);

  /// <summary>
  /// Obseg je vedno celo poddrevo vsake izbrane korenske kategorije. Ce sta izbrana stars in
  /// njegov otrok, RootCount zato steje samo starsa, CategoryCount pa vsako vozlisce natanko enkrat.
  /// </summary>
  public sealed record CategoryChangeImpact(
    long SelectedCount, long RootCount, long CategoryCount, long DescendantCount,
    long CanonProductAssignments, long PimProductAssignments, long OverrideAssignments,
    long MappingCount, long AttributeSetCount, long ValidationRuleCount, long TitleRuleCount)
  {
    public long ProductAssignments => CanonProductAssignments + PimProductAssignments + OverrideAssignments;
  }

  public sealed record CategoryChangeResult(
    int RootCount, int CategoryCount, long AssignmentCount, long MappingCount = 0);

  /// <summary>Predogled dejanskega vpliva pred premikom ali trajnim brisanjem.</summary>
  public async Task<CategoryChangeImpact> GetChangeImpactAsync(
    IReadOnlyCollection<CategoryRef> categories, CancellationToken cancellationToken = default)
  {
    var payload = SerializeCategoryRefs(categories);
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("canon.GetCategoryChangeImpact", connection)
    {
      CommandType = System.Data.CommandType.StoredProcedure,
      CommandTimeout = 120,
    };
    command.Parameters.AddWithValue("@CategoriesJson", payload);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    if (!await reader.ReadAsync(cancellationToken))
      throw new InvalidOperationException("Predogleda vpliva kategorij ni bilo mogoče pripraviti.");
    return new(
      PimDb.Int64(reader, "SelectedCount"), PimDb.Int64(reader, "RootCount"),
      PimDb.Int64(reader, "CategoryCount"), PimDb.Int64(reader, "DescendantCount"),
      PimDb.Int64(reader, "CanonProductAssignments"), PimDb.Int64(reader, "PimProductAssignments"),
      PimDb.Int64(reader, "OverrideAssignments"), PimDb.Int64(reader, "MappingCount"),
      PimDb.Int64(reader, "AttributeSetCount"), PimDb.Int64(reader, "ValidationRuleCount"),
      PimDb.Int64(reader, "TitleRuleCount"));
  }

  /// <summary>
  /// Premakne eno ali vec vej pod istega starsa (null = koren). Kode ostanejo stabilne; baza v isti
  /// transakciji posodobi nivoje, vse jezikovne poti in uvrstitve izdelkov.
  /// </summary>
  public async Task<CategoryChangeResult> MoveCategoriesAsync(
    IReadOnlyCollection<CategoryRef> categories, string targetTreeCode, string? targetParentCategoryCode,
    string actor, CancellationToken cancellationToken = default)
  {
    await guard.RequireAsync(PimPolicies.CatalogWrite);
    var payload = SerializeCategoryRefs(categories);
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("canon.MoveCategories", connection)
    {
      CommandType = System.Data.CommandType.StoredProcedure,
      CommandTimeout = 120,
    };
    command.Parameters.AddWithValue("@CategoriesJson", payload);
    command.Parameters.AddWithValue("@TargetCategoryTreeCode", targetTreeCode);
    command.Parameters.AddWithValue("@TargetParentCategoryCode", Nullable(targetParentCategoryCode));
    command.Parameters.AddWithValue("@Actor", actor);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    if (!await reader.ReadAsync(cancellationToken))
      throw new InvalidOperationException("Premik kategorij ni vrnil rezultata.");
    var result = new CategoryChangeResult(
      PimDb.Int32(reader, "RootCount"), PimDb.Int32(reader, "CategoryCount"),
      PimDb.Int64(reader, "AssignmentCount"));
    ClearPickerCache(categories.Select(category => category.CategoryTreeCode).Append(targetTreeCode));
    return result;
  }

  /// <summary>
  /// Trajno odstrani izbrane kategorije in njihova poddrevesa. Izdelki ostanejo, odstranijo se le
  /// njihove uvrstitve v izbrisane kategorije. Postopek hrani revizijsko sled.
  /// </summary>
  public async Task<CategoryChangeResult> DeleteCategoriesAsync(
    IReadOnlyCollection<CategoryRef> categories, string actor, CancellationToken cancellationToken = default)
  {
    await guard.RequireAsync(PimPolicies.CatalogWrite);
    var payload = SerializeCategoryRefs(categories);
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("canon.DeleteCategories", connection)
    {
      CommandType = System.Data.CommandType.StoredProcedure,
      CommandTimeout = 120,
    };
    command.Parameters.AddWithValue("@CategoriesJson", payload);
    command.Parameters.AddWithValue("@Actor", actor);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    if (!await reader.ReadAsync(cancellationToken))
      throw new InvalidOperationException("Brisanje kategorij ni vrnilo rezultata.");
    var result = new CategoryChangeResult(
      PimDb.Int32(reader, "RootCount"), PimDb.Int32(reader, "CategoryCount"),
      PimDb.Int64(reader, "AssignmentCount"), PimDb.Int64(reader, "MappingCount"));
    ClearPickerCache(categories.Select(category => category.CategoryTreeCode));
    return result;
  }

  /// <param name="CategoryPath">Slovenska pot; v izbirniku je zamaknjena po ravni.</param>
  public sealed record CategoryOptionRow(string CategoryTreeCode, string CategoryCode, string? ParentCategoryCode, int LevelNo, string CategoryName, string CategoryPath);

  /// <summary>Kategorije drevesa po poti — za vecnivojski filter (izbira kategorije zajame tudi podkategorije).</summary>
  public Task<IReadOnlyList<CategoryOptionRow>> GetCategoryOptionsAsync(string categoryTreeCode, CancellationToken cancellationToken = default) =>
    database.QueryAsync(
      "SELECT CategoryTreeCode, CategoryCode, ParentCategoryCode, LevelNo, CategoryName, CategoryPath FROM canon.Category WHERE CategoryTreeCode = @Tree AND IsActive = 1 ORDER BY CategoryPath;",
      reader => new CategoryOptionRow(
        PimDb.TextOrEmpty(reader, "CategoryTreeCode"), PimDb.TextOrEmpty(reader, "CategoryCode"), PimDb.Text(reader, "ParentCategoryCode"),
        PimDb.Int32(reader, "LevelNo"), PimDb.TextOrEmpty(reader, "CategoryName"), PimDb.TextOrEmpty(reader, "CategoryPath")),
      command => command.Parameters.AddWithValue("@Tree", categoryTreeCode), cancellationToken);

  /// <summary>Ucinkoviti nabor vira postane lastni nabor cilja. Vrne stevilo prepisanih vrstic.</summary>
  public async Task<int> CopyAttributeSetAsync(
    string fromTreeCode, string fromCategoryCode, string toTreeCode, string toCategoryCode,
    bool includeInherited, bool overwrite, string actor, CancellationToken cancellationToken = default)
  {
    await guard.RequireAsync(PimPolicies.CatalogWrite);
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand(
      "EXEC canon.CopyCategoryAttributeSet @FromCategoryTreeCode, @FromCategoryCode, @ToCategoryTreeCode, @ToCategoryCode, @Actor, @IncludeInherited, @Overwrite, @Copied OUTPUT;",
      connection)
    { CommandTimeout = 120 };
    command.Parameters.AddWithValue("@FromCategoryTreeCode", fromTreeCode);
    command.Parameters.AddWithValue("@FromCategoryCode", fromCategoryCode);
    command.Parameters.AddWithValue("@ToCategoryTreeCode", toTreeCode);
    command.Parameters.AddWithValue("@ToCategoryCode", toCategoryCode);
    command.Parameters.AddWithValue("@Actor", actor);
    command.Parameters.AddWithValue("@IncludeInherited", includeInherited);
    command.Parameters.AddWithValue("@Overwrite", overwrite);
    var copied = command.Parameters.Add("@Copied", System.Data.SqlDbType.Int);
    copied.Direction = System.Data.ParameterDirection.Output;
    await command.ExecuteNonQueryAsync(cancellationToken);
    ClearPickerCache([toTreeCode]);
    return copied.Value is int count ? count : 0;
  }

  static IReadOnlyDictionary<string, string> ParseTranslations(string? json)
  {
    if (string.IsNullOrWhiteSpace(json)) return new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    try
    {
      var entries = JsonSerializer.Deserialize<TranslationEntry[]>(json, JsonOptions) ?? [];
      return entries
        .Where(entry => !string.IsNullOrWhiteSpace(entry.Lang) && !string.IsNullOrWhiteSpace(entry.Name))
        .ToDictionary(entry => entry.Lang!, entry => entry.Name!, StringComparer.OrdinalIgnoreCase);
    }
    // Pokvarjen JSON ne sme podreti celega drevesa; kategorija se pokaze brez prevodov in to je
    // vidno stanje, ne tiha izguba.
    catch (JsonException)
    {
      return new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    }
  }

  static string SerializeCategoryRefs(IReadOnlyCollection<CategoryRef> categories)
  {
    if (categories.Count == 0) throw new ArgumentException("Izberi vsaj eno kategorijo.", nameof(categories));
    return JsonSerializer.Serialize(categories
      .Where(category => !string.IsNullOrWhiteSpace(category.CategoryTreeCode) && !string.IsNullOrWhiteSpace(category.CategoryCode))
      .Distinct()
      .Select(category => new { tree = category.CategoryTreeCode, code = category.CategoryCode }));
  }

  void ClearPickerCache(IEnumerable<string> categoryTreeCodes)
  {
    if (cache is null) return;
    foreach (var treeCode in categoryTreeCodes.Where(code => !string.IsNullOrWhiteSpace(code)).Distinct(StringComparer.OrdinalIgnoreCase))
      cache.Remove("category-picker:" + treeCode);
  }

  static object Nullable(string? value) => string.IsNullOrWhiteSpace(value) ? DBNull.Value : value;
}
