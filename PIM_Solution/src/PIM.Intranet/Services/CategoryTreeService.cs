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
  string ConnectionString => ConnectionStringResolver.Resolve(configuration)
    ?? throw new InvalidOperationException("Povezava PIM ni nastavljena.");

  /// <param name="IsMatch">
  /// Ali je vrstica zadetek filtra ali samo prednik zadetka. Predniki so vedno prisotni, ker je
  /// zadetek brez njih iztrgan iz drevesa in bralec ne vidi, kje stoji.
  /// </param>
  public sealed record TreeRow(
    string CategoryTreeCode,
    string CategoryCode,
    string? ParentCategoryCode,
    int LevelNo,
    string CategoryName,
    string CategoryPath,
    bool IsActive,
    string? TranslatedName,
    int MissingLanguages,
    string? MissingLanguageList,
    long ProductCount,
    long DescendantProductCount,
    bool IsMatch,
    int LanguageCount);

  public sealed record TranslationGap(string CategoryTreeCode, string LanguageCode, long Categories, long Missing);

  public sealed record LanguageOptionRow(string LanguageCode, string Name);

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
        PimDb.Text(reader, "TranslatedName"),
        PimDb.Int32(reader, "MissingLanguages"),
        PimDb.Text(reader, "MissingLanguageList"),
        PimDb.Int64(reader, "ProductCount"),
        PimDb.Int64(reader, "DescendantProductCount"),
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

  public Task<IReadOnlyList<TranslationGap>> GetTranslationGapsAsync(
    string? categoryTreeCode, CancellationToken cancellationToken = default) =>
    database.QueryAsync(
      "EXEC intranet.GetCategoryTranslationGaps @CategoryTreeCode;",
      reader => new TranslationGap(
        PimDb.TextOrEmpty(reader, "CategoryTreeCode"),
        PimDb.TextOrEmpty(reader, "LanguageCode"),
        PimDb.Int64(reader, "Kategorij"),
        PimDb.Int64(reader, "BrezPrevoda")),
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

  /// <summary>Zapiše prevod imena kategorije. Vrne Created / Updated / Unchanged.</summary>
  public async Task<string> SaveTranslationAsync(
    string categoryTreeCode, string categoryCode, string languageCode, string categoryName,
    string actor, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand(
      "EXEC canon.SaveCategoryTranslation @CategoryTreeCode, @CategoryCode, @LanguageCode, @CategoryName, @Actor;",
      connection);
    command.Parameters.AddWithValue("@CategoryTreeCode", categoryTreeCode);
    command.Parameters.AddWithValue("@CategoryCode", categoryCode);
    command.Parameters.AddWithValue("@LanguageCode", languageCode);
    command.Parameters.AddWithValue("@CategoryName", categoryName);
    command.Parameters.AddWithValue("@Actor", actor);
    var value = await command.ExecuteScalarAsync(cancellationToken);
    return value is null or DBNull ? string.Empty : Convert.ToString(value) ?? string.Empty;
  }

  static object Nullable(string? value) => string.IsNullOrWhiteSpace(value) ? DBNull.Value : value;
}
