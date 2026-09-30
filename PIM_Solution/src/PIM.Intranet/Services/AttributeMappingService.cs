using System.Data;
using System.Text.Json;
using Microsoft.Data.SqlClient;

namespace PIM.Intranet.Services;

/// <summary>
/// Register izvornih atributov, šifrant lastnosti in preslikava med njima.
///
/// Isti razrez kot pri kategorijah: <see cref="CategoryMappingService"/> odgovarja na »kam sodi
/// dobaviteljeva pot«, <see cref="CategoryTreeService"/> na »kako je naše drevo videti«. Tu sta
/// obe vprašanji o atributih v enem razredu, ker sta seznama dva pogleda na isto stvar — kaj je
/// vir poslal in v katero lastnost to gre.
///
/// Pravila so v bazi (121, 122, 125). Servis ne presoja ničesar: postopek zavrne neznano
/// lastnost, izvorni atribut, ki ga register ne pozna, neznan jezik in verigo enot.
/// </summary>
public sealed class AttributeMappingService(PimDb database, IConfiguration configuration, PimWriteGuard guard)
{
  static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true };

  string ConnectionString => ConnectionStringResolver.Resolve(configuration)
    ?? throw new InvalidOperationException("Povezava PIM ni nastavljena.");

  /// <param name="ProductCount">Pri koliko izdelkih je vir ta atribut poslal.</param>
  public sealed record SourceAttributeRow(
    string SourceCode,
    string SourceAttributeName,
    string? SourceLabel,
    string? SampleValue,
    string? SampleUnit,
    long ProductCount,
    DateTime? LastSeenUtc,
    string? AttributeCode,
    string? AttributeName,
    string? LanguageCode,
    bool IsUnit,
    string State,
    DateTime? UpdatedUtc,
    string? UpdatedBy);

  public sealed record DefinitionRow(
    string AttributeCode,
    string? AttributeName,
    string? AttributeGroup,
    string DataType,
    string? Unit,
    bool IsTranslatable,
    bool IsUnitCandidate,
    string? UnitOfAttributeCode,
    bool IsActive,
    int SourceCount,
    string? SourceList,
    long ProductCount,
    IReadOnlyDictionary<string, string> Translations,
    int LanguageCount);

  sealed record TranslationEntry(string? Lang, string? Name);

  public Task<IReadOnlyList<SourceAttributeRow>> GetSourceAttributesAsync(
    string? sourceCode, string? state, string? search, CancellationToken cancellationToken = default) =>
    database.QueryAsync(
      "EXEC intranet.GetSourceAttributes @SourceCode, @Stanje, @Iskanje;",
      reader => new SourceAttributeRow(
        PimDb.TextOrEmpty(reader, "SourceCode"),
        PimDb.TextOrEmpty(reader, "SourceAttributeName"),
        PimDb.Text(reader, "SourceLabel"),
        PimDb.Text(reader, "SampleValue"),
        PimDb.Text(reader, "SampleUnit"),
        PimDb.Int64(reader, "ProductCount"),
        PimDb.NullableDateTime(reader, "LastSeenUtc"),
        PimDb.Text(reader, "AttributeCode"),
        PimDb.Text(reader, "AttributeName"),
        PimDb.Text(reader, "LanguageCode"),
        !reader.IsDBNull(reader.GetOrdinal("IsUnit")) && PimDb.Bool(reader, "IsUnit"),
        PimDb.TextOrEmpty(reader, "Stanje"),
        PimDb.NullableDateTime(reader, "UpdatedUtc"),
        PimDb.Text(reader, "UpdatedBy")),
      command =>
      {
        command.Parameters.AddWithValue("@SourceCode", Nullable(sourceCode));
        command.Parameters.AddWithValue("@Stanje", Nullable(state));
        command.Parameters.AddWithValue("@Iskanje", Nullable(search));
      }, cancellationToken);

  public Task<IReadOnlyList<DefinitionRow>> GetDefinitionsAsync(
    string? search, bool onlyUnits, bool onlyWithoutSource, bool onlyWithoutPair,
    CancellationToken cancellationToken = default) =>
    database.QueryAsync(
      "EXEC intranet.GetAttributeDefinitions @Iskanje, @SamoEnote, @SamoBrezVira, @SamoBrezPara;",
      reader => new DefinitionRow(
        PimDb.TextOrEmpty(reader, "AttributeCode"),
        PimDb.Text(reader, "AttributeName"),
        PimDb.Text(reader, "AttributeGroup"),
        PimDb.TextOrEmpty(reader, "DataType"),
        PimDb.Text(reader, "Unit"),
        PimDb.Bool(reader, "IsTranslatable"),
        PimDb.Bool(reader, "IsUnitCandidate"),
        PimDb.Text(reader, "UnitOfAttributeCode"),
        PimDb.Bool(reader, "IsActive"),
        PimDb.Int32(reader, "SourceCount"),
        PimDb.Text(reader, "SourceList"),
        PimDb.Int64(reader, "ProductCount"),
        ParseTranslations(PimDb.Text(reader, "TranslationsJson")),
        PimDb.Int32(reader, "LanguageCount")),
      command =>
      {
        command.Parameters.AddWithValue("@Iskanje", Nullable(search));
        command.Parameters.AddWithValue("@SamoEnote", onlyUnits);
        command.Parameters.AddWithValue("@SamoBrezVira", onlyWithoutSource);
        command.Parameters.AddWithValue("@SamoBrezPara", onlyWithoutPair);
      }, cancellationToken);

  public Task<IReadOnlyList<string>> GetSourceCodesAsync(CancellationToken cancellationToken = default) =>
    database.QueryAsync(
      "SELECT DISTINCT SourceCode FROM map.SourceAttribute ORDER BY SourceCode;",
      reader => PimDb.TextOrEmpty(reader, "SourceCode"), null, cancellationToken);

  public async Task<string> SaveMapAsync(
    string sourceCode, string sourceAttributeName, string attributeCode, string? languageCode,
    bool isUnit, string actor, string? note, CancellationToken cancellationToken = default)
  {
    await guard.RequireAsync(PimPolicies.CatalogWrite);
    return await ScalarTextAsync(
      "EXEC map.SaveAttributeMap @SourceCode, @SourceAttributeName, @AttributeCode, @LanguageCode, @IsUnit, @Actor, @Note;",
      command =>
      {
        command.Parameters.AddWithValue("@SourceCode", sourceCode);
        command.Parameters.AddWithValue("@SourceAttributeName", sourceAttributeName);
        command.Parameters.AddWithValue("@AttributeCode", attributeCode);
        command.Parameters.AddWithValue("@LanguageCode", Nullable(languageCode));
        command.Parameters.AddWithValue("@IsUnit", isUnit);
        command.Parameters.AddWithValue("@Actor", actor);
        command.Parameters.AddWithValue("@Note", Nullable(note));
      }, cancellationToken);
  }

  public async Task<string> DeactivateMapAsync(
    string sourceCode, string sourceAttributeName, string actor, string? note,
    CancellationToken cancellationToken = default)
  {
    await guard.RequireAsync(PimPolicies.CatalogWrite);
    return await ScalarTextAsync(
      "EXEC map.DeactivateAttributeMap @SourceCode, @SourceAttributeName, @Actor, @Note;",
      command =>
      {
        command.Parameters.AddWithValue("@SourceCode", sourceCode);
        command.Parameters.AddWithValue("@SourceAttributeName", sourceAttributeName);
        command.Parameters.AddWithValue("@Actor", actor);
        command.Parameters.AddWithValue("@Note", Nullable(note));
      }, cancellationToken);
  }

  /// <summary>Poveže enoto z lastnostjo, ki ji pripada. Prazen cilj par odstrani.</summary>
  public async Task<string> SaveDefinitionAsync(
    string attributeCode, string? attributeGroup, string? dataType, string? unit,
    bool? isTranslatable, string? unitOfAttributeCode, string actor, string? note,
    CancellationToken cancellationToken = default)
  {
    await guard.RequireAsync(PimPolicies.CatalogWrite);
    return await ScalarTextAsync(
      "EXEC canon.SaveAttributeDefinition @AttributeCode, @AttributeGroup, @DataType, @Unit, @IsTranslatable, @UnitOfAttributeCode, @Actor, @Note;",
      command =>
      {
        command.Parameters.AddWithValue("@AttributeCode", attributeCode);
        command.Parameters.AddWithValue("@AttributeGroup", Nullable(attributeGroup));
        command.Parameters.AddWithValue("@DataType", Nullable(dataType));
        command.Parameters.AddWithValue("@Unit", Nullable(unit));
        command.Parameters.AddWithValue("@IsTranslatable", isTranslatable is null ? DBNull.Value : isTranslatable.Value);
        command.Parameters.AddWithValue("@UnitOfAttributeCode", Nullable(unitOfAttributeCode));
        command.Parameters.AddWithValue("@Actor", actor);
        command.Parameters.AddWithValue("@Note", Nullable(note));
      }, cancellationToken);
  }

  // --- Dodajanje, urejanje in brisanje atributa (migracija 238) --------------------------
  // Uporabnik 2026-09-21: »treba dodat da se dodaja piše briše«.

  /// <param name="ProductValues">Vrstice canon.ProductAttribute (po slovenskem imenu, ker se vrednosti hranijo po imenu — 125).</param>
  /// <param name="Requirements">Aktivne zahteve validacije za polje ProductAttribute.&lt;ime&gt;.</param>
  public sealed record AttributeUsage(
    string AttributeCode, string? SloveneName, string? Note, int SortOrder,
    long ProductValues, long ProductsWithValue, long PimValues, long CategorySets, long SourceMaps,
    long UnitPairs, long Requirements, long Translations)
  {
    public long ValueCount => ProductValues + PimValues;
  }

  /// <summary>Kje vse atribut živi — pred brisanjem in za zavihek Osnovno (opomba, ki je register ne vrača).</summary>
  public async Task<AttributeUsage?> GetUsageAsync(string attributeCode, CancellationToken cancellationToken = default)
  {
    var rows = await database.QueryAsync(
      "EXEC intranet.GetAttributeUsage @AttributeCode;",
      reader => new AttributeUsage(
        PimDb.TextOrEmpty(reader, "AttributeCode"), PimDb.Text(reader, "SloveneName"), PimDb.Text(reader, "Note"),
        PimDb.Int32(reader, "SortOrder"), PimDb.Int64(reader, "ProductValues"), PimDb.Int64(reader, "ProductsWithValue"),
        PimDb.Int64(reader, "PimValues"), PimDb.Int64(reader, "CategorySets"), PimDb.Int64(reader, "SourceMaps"),
        PimDb.Int64(reader, "UnitPairs"), PimDb.Int64(reader, "Requirements"), PimDb.Int64(reader, "Translations")),
      command => command.Parameters.AddWithValue("@AttributeCode", attributeCode), cancellationToken);
    return rows.FirstOrDefault();
  }

  /// <summary>
  /// Nov atribut: slovensko ime je obvezno (iz njega nastane koda, če je klicatelj ne poda), imena v
  /// ostalih jezikih gredo v isti transakciji. Postopek zavrne obstoječo kodo in obstoječe slovensko ime.
  /// Vrne kodo.
  /// </summary>
  public async Task<string> CreateDefinitionAsync(
    string name, string? attributeCode, string? attributeGroup, string dataType, string? unit,
    bool isTranslatable, string? note, IReadOnlyDictionary<string, string>? translations, string actor,
    CancellationToken cancellationToken = default)
  {
    await guard.RequireAsync(PimPolicies.CatalogWrite);
    var others = (translations ?? new Dictionary<string, string>())
      .Where(pair => !string.Equals(pair.Key, "sl", StringComparison.OrdinalIgnoreCase) && !string.IsNullOrWhiteSpace(pair.Value))
      .Select(pair => new { lang = pair.Key, name = pair.Value.Trim() })
      .ToList();
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand(
      "EXEC canon.CreateAttributeDefinition @Name, @AttributeCode, @AttributeGroup, @DataType, @Unit, @IsTranslatable, @Note, @TranslationsJson, @Actor, @CreatedCode OUTPUT;",
      connection);
    command.Parameters.AddWithValue("@Name", name.Trim());
    command.Parameters.AddWithValue("@AttributeCode", Nullable(attributeCode));
    command.Parameters.AddWithValue("@AttributeGroup", Nullable(attributeGroup));
    command.Parameters.AddWithValue("@DataType", Nullable(dataType));
    command.Parameters.AddWithValue("@Unit", Nullable(unit));
    command.Parameters.AddWithValue("@IsTranslatable", isTranslatable);
    command.Parameters.AddWithValue("@Note", Nullable(note));
    command.Parameters.AddWithValue("@TranslationsJson", others.Count == 0 ? DBNull.Value : JsonSerializer.Serialize(others));
    command.Parameters.AddWithValue("@Actor", actor);
    var created = command.Parameters.Add("@CreatedCode", SqlDbType.NVarChar, 200);
    created.Direction = ParameterDirection.Output;
    await command.ExecuteNonQueryAsync(cancellationToken);
    return created.Value as string ?? throw new InvalidOperationException($"Atributa »{name}« ni bilo mogoče ustvariti.");
  }

  /// <summary>
  /// Urejanje osnovnih lastnosti z izrecnim pomenom: prazna skupina, enota, opomba ali par enote se
  /// POBRIŠEJO (za razliko od <see cref="SaveDefinitionAsync"/>, kjer prazno pomeni »pusti«).
  /// </summary>
  public async Task UpdateDefinitionAsync(
    string attributeCode, string? attributeGroup, string dataType, string? unit, bool isTranslatable,
    bool isUnitCandidate, string? unitOfAttributeCode, bool isActive, string? note, string actor,
    CancellationToken cancellationToken = default)
  {
    await guard.RequireAsync(PimPolicies.CatalogWrite);
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand(
      "EXEC canon.UpdateAttributeDefinition @AttributeCode, @AttributeGroup, @DataType, @Unit, @IsTranslatable, @IsUnitCandidate, @UnitOfAttributeCode, @IsActive, @Note, @Actor;",
      connection);
    command.Parameters.AddWithValue("@AttributeCode", attributeCode);
    command.Parameters.AddWithValue("@AttributeGroup", Nullable(attributeGroup));
    command.Parameters.AddWithValue("@DataType", dataType);
    command.Parameters.AddWithValue("@Unit", Nullable(unit));
    command.Parameters.AddWithValue("@IsTranslatable", isTranslatable);
    command.Parameters.AddWithValue("@IsUnitCandidate", isUnitCandidate);
    command.Parameters.AddWithValue("@UnitOfAttributeCode", Nullable(unitOfAttributeCode));
    command.Parameters.AddWithValue("@IsActive", isActive);
    command.Parameters.AddWithValue("@Note", Nullable(note));
    command.Parameters.AddWithValue("@Actor", actor);
    await command.ExecuteNonQueryAsync(cancellationToken);
  }

  /// <summary>
  /// Trajni izbris. Brez <paramref name="force"/> postopek zavrne atribut z vrednostmi pri izdelkih;
  /// s <paramref name="force"/> izbriše tudi te. Vrne število izbrisanih vrednosti pri izdelkih.
  /// </summary>
  public async Task<long> DeleteDefinitionAsync(string attributeCode, bool force, string actor, CancellationToken cancellationToken = default)
  {
    await guard.RequireAsync(PimPolicies.CatalogWrite);
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand(
      "EXEC canon.DeleteAttributeDefinition @AttributeCode, @Actor, @Force, @DeletedValues OUTPUT;", connection) { CommandTimeout = 120 };
    command.Parameters.AddWithValue("@AttributeCode", attributeCode);
    command.Parameters.AddWithValue("@Actor", actor);
    command.Parameters.AddWithValue("@Force", force);
    var deleted = command.Parameters.Add("@DeletedValues", SqlDbType.BigInt);
    deleted.Direction = ParameterDirection.Output;
    await command.ExecuteNonQueryAsync(cancellationToken);
    return deleted.Value is long count ? count : 0;
  }

  /// <summary>
  /// Imena lastnosti v več jezikih hkrati. Če en jezik pade na pravilu, ne obvelja noben.
  /// </summary>
  public async Task<int> SaveTranslationsAsync(
    string attributeCode, IReadOnlyDictionary<string, string> translations, string actor,
    CancellationToken cancellationToken = default)
  {
    await guard.RequireAsync(PimPolicies.CatalogWrite);
    var payload = JsonSerializer.Serialize(
      translations.Select(pair => new { lang = pair.Key, name = pair.Value }));

    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand(
      "EXEC canon.SaveAttributeTranslations @AttributeCode, @TranslationsJson, @Actor;", connection);
    command.Parameters.AddWithValue("@AttributeCode", attributeCode);
    command.Parameters.AddWithValue("@TranslationsJson", payload);
    command.Parameters.AddWithValue("@Actor", actor);
    var value = await command.ExecuteScalarAsync(cancellationToken);
    return value is null or DBNull ? 0 : Convert.ToInt32(value);
  }

  // --- Čiščenje atributov (naloga #15, migracija 307) ----------------------------------------
  // Lastnik 2026-09-29: »kateri atributi pomenijo isto … seznam kandidatov za združitev, s številom
  // artiklov in primeri vrednosti; lastnik odloči, kaj se združi«. Tu je samo branje: nič se ne
  // združi, izbriše ali prepiše. Vrednosti se v pim.ProductAttribute hranijo po SLOVENSKEM IMENU
  // atributa (125), zato se primerja po imenu, koda registra je samo povezava.

  public sealed record DuplicateReport(
    IReadOnlyList<CleanupAttribute> Attributes, IReadOnlyList<DuplicateCandidate> Candidates, long ElapsedMs, DateTime ComputedUtc);

  // Pregled je težka poizvedba (~3 s podvojeni, ~9 s zapis) in se čez dan komaj spremeni, zato velja
  // izračun 10 minut za vse uporabnike; »Osveži« na strani ga izračuna znova.
  static readonly TimeSpan CleanupCacheAge = TimeSpan.FromMinutes(10);
  static readonly SemaphoreSlim CleanupGate = new(1, 1);
  static DuplicateReport? cachedDuplicates;
  static PolishPreview? cachedPolish;

  /// <summary>
  /// Kandidati za združitev atributov iz ene množične poizvedbe (brez zanke po atributih):
  /// pari, ki pri istih izdelkih nosijo isto vrednost, pari z enakim naborom vrednosti pri drugih
  /// izdelkih in pari s skoraj enakim imenom. Spremljevalni atributi »Enota …« so izpuščeni, ker po
  /// zasnovi nosijo iste enote (mm, kg) pri vseh merah. Nepomembne vrednosti (0, 1, 2, da, ne) ne
  /// štejejo kot ujemanje, sicer bi bil par vsak števec. Čista števila (50, 100, 120) ne štejejo kot
  /// skupna vrednost med različnimi izdelki (mere pomenijo različno). Samo aktivna podjetja.
  /// </summary>
  public async Task<DuplicateReport> GetDuplicateCandidatesAsync(bool refresh = false, CancellationToken cancellationToken = default)
  {
    var cached = cachedDuplicates;
    if (!refresh && cached is not null && DateTime.UtcNow - cached.ComputedUtc < CleanupCacheAge) return cached;
    await CleanupGate.WaitAsync(cancellationToken);
    try
    {
      cached = cachedDuplicates;
      if (!refresh && cached is not null && DateTime.UtcNow - cached.ComputedUtc < CleanupCacheAge) return cached;
      return cachedDuplicates = await ComputeDuplicateCandidatesAsync(cancellationToken);
    }
    finally { CleanupGate.Release(); }
  }

  async Task<DuplicateReport> ComputeDuplicateCandidatesAsync(CancellationToken cancellationToken)
  {
    const string sql = """
      SET NOCOUNT ON;
      /* Samo aktivna podjetja (DEMO je neaktiven): en prehod čez pim.ProductAttribute, vse drugo iz #r/#v. */
      SELECT value.PimProductId AS P, product.OrganizationId AS O, value.AttributeCode COLLATE DATABASE_DEFAULT AS Name,
             CASE value.LanguageCode WHEN N'sl' THEN 1 WHEN N'en' THEN 2 ELSE 0 END AS L,
             LOWER(LTRIM(RTRIM(value.Value))) COLLATE DATABASE_DEFAULT AS V,
             LEFT(value.Value, 60) COLLATE DATABASE_DEFAULT AS Sample
      INTO #r
      FROM pim.ProductAttribute AS value
      JOIN pim.Product AS product ON product.PimProductId = value.PimProductId
      JOIN dbo.OrganizationConfig AS organization ON organization.OrganizationId = product.OrganizationId AND organization.IsActive = 1
      WHERE value.Value IS NOT NULL AND value.Value <> N'' AND value.AttributeCode NOT LIKE N'Enota %';

      CREATE TABLE #n (Id int IDENTITY PRIMARY KEY, Name nvarchar(400) COLLATE DATABASE_DEFAULT NOT NULL UNIQUE);
      INSERT #n (Name) SELECT DISTINCT Name FROM #r;

      /* Informative = 0: nepomembna vrednost (0–99, da/ne). Textual = 0: čisto število (50, 100, 1,5) —
         ne šteje kot skupna vrednost med različnimi izdelki, sicer so Premer, Širina in Dolžina »podobni«. */
      CREATE TABLE #v (P int NOT NULL, O int NOT NULL, A int NOT NULL, L tinyint NOT NULL, H int NOT NULL,
                       Informative bit NOT NULL, Textual bit NOT NULL, S nvarchar(60) COLLATE DATABASE_DEFAULT NOT NULL);
      INSERT #v (P, O, A, L, H, Informative, Textual, S)
      SELECT r.P, r.O, name.Id, r.L, CHECKSUM(r.V),
             CASE WHEN (r.V NOT LIKE N'%[^0-9]%' AND LEN(r.V) <= 2)
                    OR r.V IN (N'da', N'ne', N'yes', N'no', N'true', N'false', N'-', N'/', N'x') THEN 0 ELSE 1 END,
             CASE WHEN r.V NOT LIKE N'%[^0-9.,+ -]%' THEN 0 ELSE 1 END,
             r.Sample
      FROM #r AS r JOIN #n AS name ON name.Name = r.Name;
      CREATE CLUSTERED INDEX CX_v ON #v (P, L, A);

      SELECT x.A, y.A AS B, COUNT(DISTINCT x.P) AS SharedProducts,
             COUNT(DISTINCT CASE WHEN x.H = y.H AND x.Informative = 1 THEN x.P END) AS SameValueProducts
      INTO #shared
      FROM #v AS x JOIN #v AS y ON y.P = x.P AND y.L = x.L AND y.A > x.A
      GROUP BY x.A, y.A;

      SELECT DISTINCT A, H INTO #av FROM #v WHERE Informative = 1 AND Textual = 1;
      SELECT x.A, y.A AS B, COUNT(*) AS CommonValues
      INTO #common
      FROM #av AS x JOIN #av AS y ON y.H = x.H AND y.A > x.A
      GROUP BY x.A, y.A;

      /* 1. atributi s štetjem po podjetju in tremi najpogostejšimi vrednostmi (vse iz začasnih tabel, brez
            poizvedbe na atribut) */
      SELECT A, O AS OrganizationId, COUNT(DISTINCT P) AS Products INTO #po FROM #v GROUP BY A, O;

      SELECT A, COUNT(DISTINCT P) AS Products, COUNT(DISTINCT H) AS DistinctValues,
             COUNT(DISTINCT CASE WHEN Informative = 1 AND Textual = 1 THEN H END) AS InformativeValues
      INTO #counts FROM #v GROUP BY A;

      SELECT grouped.A, grouped.Sample AS Value, grouped.Uses,
             ROW_NUMBER() OVER (PARTITION BY grouped.A ORDER BY grouped.Uses DESC, grouped.Sample) AS Position
      INTO #samples
      FROM (SELECT A, MIN(S) AS Sample, COUNT(*) AS Uses FROM #v GROUP BY A, H) AS grouped;

      SELECT name.Name,
             registry.AttributeCode,
             COALESCE(counts.Products, 0) AS Products, COALESCE(counts.DistinctValues, 0) AS DistinctValues,
             COALESCE(counts.InformativeValues, 0) AS InformativeValues,
             (SELECT STRING_AGG(COALESCE(config.Name, CONCAT(N'Podjetje ', po.OrganizationId)) + N' '
                       + FORMAT(po.Products, N'N0', N'sl-SI'), N' · ') WITHIN GROUP (ORDER BY po.Products DESC)
              FROM #po AS po LEFT JOIN dbo.OrganizationConfig AS config ON config.OrganizationId = po.OrganizationId
              WHERE po.A = name.Id) AS ByOrganization,
             (SELECT STRING_AGG(sample.Value, N' | ') WITHIN GROUP (ORDER BY sample.Position)
              FROM #samples AS sample WHERE sample.A = name.Id AND sample.Position <= 3) AS Samples
      FROM #n AS name
      LEFT JOIN #counts AS counts ON counts.A = name.Id
      OUTER APPLY (SELECT TOP (1) translation.AttributeCode FROM canon.AttributeTranslation AS translation
                   WHERE translation.LanguageCode = N'sl' AND translation.Name = name.Name ORDER BY translation.AttributeCode) AS registry;

      /* 2. pari s skupnimi izdelki ali skupnimi vrednostmi */
      SELECT first.Name AS FirstName, second.Name AS SecondName,
             COALESCE(shared.SharedProducts, 0) AS SharedProducts, COALESCE(shared.SameValueProducts, 0) AS SameValueProducts,
             COALESCE(common.CommonValues, 0) AS CommonValues
      FROM #shared AS shared
      FULL JOIN #common AS common ON common.A = shared.A AND common.B = shared.B
      JOIN #n AS first ON first.Id = COALESCE(shared.A, common.A)
      JOIN #n AS second ON second.Id = COALESCE(shared.B, common.B)
      WHERE COALESCE(shared.SameValueProducts, 0) > 0 OR COALESCE(common.CommonValues, 0) > 0;
      """;

    var watch = System.Diagnostics.Stopwatch.StartNew();
    var attributes = new List<CleanupAttribute>();
    var pairs = new List<(string First, string Second, long Shared, long Same, long Common)>();
    await using (var connection = new SqlConnection(ConnectionString))
    {
      await connection.OpenAsync(cancellationToken);
      await using var command = new SqlCommand(sql, connection) { CommandTimeout = 180 };
      await using var reader = await command.ExecuteReaderAsync(cancellationToken);
      while (await reader.ReadAsync(cancellationToken))
        attributes.Add(new CleanupAttribute(
          PimDb.TextOrEmpty(reader, "Name"), PimDb.Text(reader, "AttributeCode"), PimDb.Int64(reader, "Products"),
          PimDb.Int64(reader, "DistinctValues"), PimDb.Int64(reader, "InformativeValues"),
          PimDb.Text(reader, "ByOrganization"), PimDb.Text(reader, "Samples")));
      await reader.NextResultAsync(cancellationToken);
      while (await reader.ReadAsync(cancellationToken))
        pairs.Add((PimDb.TextOrEmpty(reader, "FirstName"), PimDb.TextOrEmpty(reader, "SecondName"),
          PimDb.Int64(reader, "SharedProducts"), PimDb.Int64(reader, "SameValueProducts"), PimDb.Int64(reader, "CommonValues")));
    }
    watch.Stop();
    return new DuplicateReport(attributes, AttributeDuplicatePolicy.Classify(attributes, pairs), watch.ElapsedMilliseconds, DateTime.UtcNow);
  }

  /// <param name="Rows">Vrstic v pim.ProductAttribute s tem zapisom.</param>
  public sealed record PolishPreviewRow(string AttributeCode, string OldValue, string NewValue, long Rows, long Products);

  public sealed record PolishPreview(IReadOnlyList<PolishPreviewRow> Changes, long DistinctValues, long ElapsedMs, DateTime ComputedUtc);

  /// <summary>
  /// Lep zapis (pim.PolishAttributeValue, 307, vklopljen s 314 — lastnik 2026-09-29): kaj pravilo še
  /// zapiše drugače. Po vklopu so to samo ročno vpisane vrednosti (kartica, delovni list), ki jih zajem
  /// ne poenoti; katalog.csv jih zapiše lepo že ob izvozu. Funkcija se kliče enkrat na RAZLIČNO vrednost
  /// (ne na vrstico); tu se nič ne zapiše.
  /// </summary>
  public async Task<PolishPreview> GetPolishPreviewAsync(bool refresh = false, CancellationToken cancellationToken = default)
  {
    var cached = cachedPolish;
    if (!refresh && cached is not null && DateTime.UtcNow - cached.ComputedUtc < CleanupCacheAge) return cached;
    await CleanupGate.WaitAsync(cancellationToken);
    try
    {
      cached = cachedPolish;
      if (!refresh && cached is not null && DateTime.UtcNow - cached.ComputedUtc < CleanupCacheAge) return cached;
      return cachedPolish = await ComputePolishPreviewAsync(cancellationToken);
    }
    finally { CleanupGate.Release(); }
  }

  async Task<PolishPreview> ComputePolishPreviewAsync(CancellationToken cancellationToken)
  {
    const string sql = """
      SET NOCOUNT ON;
      SELECT AttributeCode, Value, COUNT_BIG(*) AS Rows, COUNT_BIG(DISTINCT PimProductId) AS Products
      INTO #d
      FROM pim.ProductAttribute AS value
      WHERE Value IS NOT NULL AND Value <> N''
        AND EXISTS (SELECT 1 FROM pim.Product AS product
                    JOIN dbo.OrganizationConfig AS organization ON organization.OrganizationId = product.OrganizationId AND organization.IsActive = 1
                    WHERE product.PimProductId = value.PimProductId)
      GROUP BY AttributeCode, Value;

      SELECT COUNT_BIG(*) AS DistinctValues FROM #d;

      SELECT d.AttributeCode, d.Value AS OldValue, polished.NewValue, d.Rows, d.Products
      FROM #d AS d
      CROSS APPLY (SELECT pim.PolishAttributeValue(d.AttributeCode, d.Value) AS NewValue) AS polished
      WHERE polished.NewValue COLLATE Latin1_General_BIN <> d.Value COLLATE Latin1_General_BIN
      ORDER BY d.Rows DESC, d.AttributeCode, d.Value;
      """;

    var watch = System.Diagnostics.Stopwatch.StartNew();
    var changes = new List<PolishPreviewRow>();
    long distinctValues = 0;
    await using (var connection = new SqlConnection(ConnectionString))
    {
      await connection.OpenAsync(cancellationToken);
      await using var command = new SqlCommand(sql, connection) { CommandTimeout = 180 };
      await using var reader = await command.ExecuteReaderAsync(cancellationToken);
      if (await reader.ReadAsync(cancellationToken)) distinctValues = PimDb.Int64(reader, "DistinctValues");
      await reader.NextResultAsync(cancellationToken);
      while (await reader.ReadAsync(cancellationToken))
        changes.Add(new PolishPreviewRow(
          PimDb.TextOrEmpty(reader, "AttributeCode"), PimDb.TextOrEmpty(reader, "OldValue"), PimDb.TextOrEmpty(reader, "NewValue"),
          PimDb.Int64(reader, "Rows"), PimDb.Int64(reader, "Products")));
    }
    watch.Stop();
    return new PolishPreview(changes, distinctValues, watch.ElapsedMilliseconds, DateTime.UtcNow);
  }

  /// <summary>Eno poenotenje vrednosti v dnevniku pim.AttributeValueNormalizationLog (291, 294, 314 …).</summary>
  /// <param name="ChangedBy">Oznaka poenotenja (npr. »migracija 314« ali »povratek migracija 314 (kdo)«).</param>
  public sealed record NormalizationRun(string ChangedBy, long Rows, long Products, int Organizations, DateTime FirstUtc, DateTime LastUtc);

  /// <summary>
  /// Pregled dnevnika poenotenj: kdo (migracija ali povratek), kdaj, koliko vrstic in izdelkov.
  /// Ena združevalna poizvedba; dnevnik ima indeks po ChangedBy (314).
  /// </summary>
  public async Task<IReadOnlyList<NormalizationRun>> GetNormalizationRunsAsync(CancellationToken cancellationToken = default)
  {
    const string sql = """
      SET NOCOUNT ON;
      IF OBJECT_ID(N'pim.AttributeValueNormalizationLog', N'U') IS NULL RETURN;
      SELECT ChangedBy, COUNT_BIG(*) AS Rows,
             COUNT_BIG(DISTINCT CONCAT(OrganizationId, N'|', ItemID)) AS Products,
             COUNT(DISTINCT OrganizationId) AS Organizations,
             MIN(ChangedUtc) AS FirstUtc, MAX(ChangedUtc) AS LastUtc
      FROM pim.AttributeValueNormalizationLog
      GROUP BY ChangedBy
      ORDER BY MAX(ChangedUtc) DESC;
      """;
    var runs = new List<NormalizationRun>();
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand(sql, connection) { CommandTimeout = 60 };
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    while (await reader.ReadAsync(cancellationToken))
      runs.Add(new NormalizationRun(PimDb.TextOrEmpty(reader, "ChangedBy"), PimDb.Int64(reader, "Rows"), PimDb.Int64(reader, "Products"),
        PimDb.Int32(reader, "Organizations"), PimDb.DateTimeValue(reader, "FirstUtc"), PimDb.DateTimeValue(reader, "LastUtc")));
    return runs;
  }

  /// <summary>
  /// Vrstice enega poenotenja za izvoz (prej, potem, podjetje, šifra, kdaj). Samo branje; povratek naredi
  /// skrbnik baze s pim.RevertAttributeValueNormalization (vrne le vrednosti, ki jih od takrat nihče ni spremenil).
  /// </summary>
  public async Task<string> GetNormalizationLogCsvAsync(string changedBy, CancellationToken cancellationToken = default)
  {
    const string sql = """
      SET NOCOUNT ON;
      SELECT entry.ChangedUtc, entry.ChangedBy, entry.TableName, organization.Name AS Organization, entry.ItemID,
             entry.AttributeCode, entry.LanguageCode, entry.OldValue, entry.NewValue
      FROM pim.AttributeValueNormalizationLog AS entry
      LEFT JOIN dbo.OrganizationConfig AS organization ON organization.OrganizationId = entry.OrganizationId
      WHERE entry.ChangedBy = @ChangedBy
      ORDER BY entry.AttributeValueNormalizationLogId;
      """;
    var builder = new System.Text.StringBuilder();
    builder.AppendLine("Kdaj;Poenotenje;Plast;Podjetje;Šifra;Atribut;Jezik;Prej;Potem");
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand(sql, connection) { CommandTimeout = 120 };
    command.Parameters.Add("@ChangedBy", System.Data.SqlDbType.NVarChar, 200).Value = changedBy;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    while (await reader.ReadAsync(cancellationToken))
    {
      var layer = PimDb.TextOrEmpty(reader, "TableName") == "pim.ProductAttribute" ? "PIM" : "Vir (canon)";
      builder.AppendLine(string.Join(';', new[]
      {
        PimDb.DateTimeValue(reader, "ChangedUtc").ToPimLocal().ToString("yyyy-MM-dd HH:mm"), PimDb.TextOrEmpty(reader, "ChangedBy"), layer,
        PimDb.TextOrEmpty(reader, "Organization"), PimDb.TextOrEmpty(reader, "ItemID"), PimDb.TextOrEmpty(reader, "AttributeCode"),
        PimDb.TextOrEmpty(reader, "LanguageCode"), PimDb.TextOrEmpty(reader, "OldValue"), PimDb.TextOrEmpty(reader, "NewValue")
      }.Select(CsvCell)));
    }
    return builder.ToString();
  }

  static string CsvCell(string value) =>
    value.IndexOfAny([';', '"', '\n', '\r']) >= 0 ? "\"" + value.Replace("\"", "\"\"") + "\"" : value;

  /// <summary>Jeziki, v katere slovar prevaja angleške vrednosti atributov. IT slovar pozna, izdelek
  /// pa vrednosti hrani samo v sl/en, zato katalog.csv italijanskih vrednosti (še) ne izvozi.</summary>
  public static readonly IReadOnlyList<string> DictionaryLanguages = ["SL", "DE", "HR", "IT"];

  public sealed record DictionaryCoverage(string Language, long Total, long Covered)
  {
    public long Missing => Total - Covered;
  }

  public sealed record DictionaryGap(string AttributeCode, string Value, long Products);

  public sealed record DictionaryCoverageReport(
    IReadOnlyList<DictionaryCoverage> Languages, IReadOnlyList<DictionaryGap> Gaps, string Language);

  /// <summary>
  /// »Kaj bi slovar prevedel«: za vsako različno angleško vrednost atributa (pim.ProductAttribute,
  /// jezik en) pogleda, ali ima map.ValueLookup prevod v jezik (domena * ali ime atributa, kot jo
  /// uporablja pretvorba LOOKUP v zajemu). Samodejni prevod je obstoječa pot LOOKUP; tu je samo pregled.
  /// </summary>
  public async Task<DictionaryCoverageReport> GetDictionaryCoverageAsync(string? language, CancellationToken cancellationToken = default)
  {
    var chosen = DictionaryLanguages.FirstOrDefault(value => string.Equals(value, language?.Trim(), StringComparison.OrdinalIgnoreCase)) ?? "IT";
    const string sql = """
      SET NOCOUNT ON;
      SELECT AttributeCode COLLATE DATABASE_DEFAULT AS AttributeCode, Value COLLATE DATABASE_DEFAULT AS Value,
             LOWER(LTRIM(RTRIM(Value))) COLLATE DATABASE_DEFAULT AS SourceKey, COUNT_BIG(DISTINCT PimProductId) AS Products
      INTO #d
      FROM pim.ProductAttribute
      WHERE LanguageCode = N'en' AND Value IS NOT NULL AND Value <> N''
        /* rimske številke (Električni razred I/II/III), števila in ločila se ne prevajajo */
        AND LOWER(LTRIM(RTRIM(Value))) COLLATE Latin1_General_BIN LIKE N'%[^ivx0-9 .,/+-]%'
      GROUP BY AttributeCode, Value;

      SELECT lookup.Language COLLATE DATABASE_DEFAULT AS Language, lookup.SourceKey COLLATE DATABASE_DEFAULT AS SourceKey,
             lookup.Domain COLLATE DATABASE_DEFAULT AS Domain
      INTO #k
      FROM map.ValueLookup AS lookup
      WHERE lookup.IsActive = 1 AND lookup.Language IN (N'SL', N'DE', N'HR', N'IT');

      SELECT d.AttributeCode, d.Value, d.Products, language.Code AS Language,
             CASE WHEN EXISTS (SELECT 1 FROM #k AS k WHERE k.Language = language.Code AND k.SourceKey = d.SourceKey
                                 AND k.Domain IN (N'*', d.AttributeCode, d.AttributeCode + N' SLO')) THEN 1 ELSE 0 END AS Covered
      INTO #c
      FROM #d AS d CROSS JOIN (VALUES (N'SL'), (N'DE'), (N'HR'), (N'IT')) AS language(Code);

      SELECT Language, COUNT_BIG(*) AS Total, SUM(CONVERT(bigint, Covered)) AS Covered FROM #c GROUP BY Language;

      SELECT AttributeCode, Value, Products FROM #c
      WHERE Language = @Language AND Covered = 0
      ORDER BY Products DESC, AttributeCode, Value;
      """;

    var languages = new List<DictionaryCoverage>();
    var gaps = new List<DictionaryGap>();
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand(sql, connection) { CommandTimeout = 120 };
    command.Parameters.AddWithValue("@Language", chosen);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    while (await reader.ReadAsync(cancellationToken))
      languages.Add(new DictionaryCoverage(PimDb.TextOrEmpty(reader, "Language"), PimDb.Int64(reader, "Total"), PimDb.Int64(reader, "Covered")));
    await reader.NextResultAsync(cancellationToken);
    while (await reader.ReadAsync(cancellationToken))
      gaps.Add(new DictionaryGap(PimDb.TextOrEmpty(reader, "AttributeCode"), PimDb.TextOrEmpty(reader, "Value"), PimDb.Int64(reader, "Products")));
    var ordered = DictionaryLanguages
      .Select(code => languages.FirstOrDefault(row => row.Language == code) ?? new DictionaryCoverage(code, 0, 0))
      .ToList();
    return new DictionaryCoverageReport(ordered, gaps, chosen);
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
    // Pokvarjen JSON ne sme podreti seznama; lastnost se pokaze brez imen in to je vidno stanje.
    catch (JsonException)
    {
      return new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    }
  }

  static object Nullable(string? value) => string.IsNullOrWhiteSpace(value) ? DBNull.Value : value;
}
