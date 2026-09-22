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
