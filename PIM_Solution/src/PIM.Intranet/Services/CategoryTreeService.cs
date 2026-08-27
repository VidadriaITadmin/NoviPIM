using System.Text.Json;
using Microsoft.Data.SqlClient;

namespace PIM.Intranet.Services;

/// <summary>
/// Drevo kategorij in prevodi imen.
///
/// Ločeno od <see cref="CategoryMappingService"/>: tam gre za vprašanje »kam sodi dobaviteljeva
/// pot«, tu za vprašanje »kako je naše drevo videti in kako se imenuje v posameznem jeziku«.
/// Prvo je preslikava vira, drugo je katalog sam.
/// </summary>
public sealed class CategoryTreeService(PimDb database, IConfiguration configuration)
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

  /// <summary>
  /// Zapiše prevode ene kategorije v več jezikih hkrati. Vrne število spremenjenih jezikov.
  /// Če en jezik pade na pravilu, ne obvelja noben — delno shranjen prevod izgleda opravljen.
  /// </summary>
  public async Task<int> SaveTranslationsAsync(
    string categoryTreeCode, string categoryCode, IReadOnlyDictionary<string, string> translations,
    string actor, CancellationToken cancellationToken = default)
  {
    var payload = JsonSerializer.Serialize(
      translations.Select(pair => new { lang = pair.Key, name = pair.Value }));

    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand(
      "EXEC canon.SaveCategoryTranslations @CategoryTreeCode, @CategoryCode, @TranslationsJson, @Actor;",
      connection);
    command.Parameters.AddWithValue("@CategoryTreeCode", categoryTreeCode);
    command.Parameters.AddWithValue("@CategoryCode", categoryCode);
    command.Parameters.AddWithValue("@TranslationsJson", payload);
    command.Parameters.AddWithValue("@Actor", actor);
    var value = await command.ExecuteScalarAsync(cancellationToken);
    return value is null or DBNull ? 0 : Convert.ToInt32(value);
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

  static object Nullable(string? value) => string.IsNullOrWhiteSpace(value) ? DBNull.Value : value;
}
