using System.Data;
using Microsoft.Data.SqlClient;

namespace PIM.Intranet.Services;

/// <summary>
/// Pravila za sestavo spletnih nazivov (migracija 149). SQL je v migraciji; servis kliče
/// register, predogled in zapis ter stolpce preslika po imenu.
/// </summary>
public sealed class TitleRuleService(PimDb database, IConfiguration configuration)
{
  string ConnectionString => ConnectionStringResolver.Resolve(configuration)
    ?? throw new InvalidOperationException("Povezava PIM ni nastavljena.");

  public sealed record RuleRow(
    int TitleRuleId, string RuleCode, string Name, string? CategoryTreeCode, string? CategoryCode,
    string? CategoryName, string? CategoryPath, string? LanguageCode, string Template, string Separator,
    bool IsActive, int SortOrder, string? Note, DateTime UpdatedUtc, string UpdatedBy);

  public sealed record PreviewRow(long ProductId, string ItemID, string? CurrentTitle, string? ErpTitle, string? RuleCode, string? ComposedTitle);

  public sealed record CategoryOption(string CategoryTreeCode, string CategoryCode, string CategoryPath);

  public sealed record ApplyResult(int Written, int Candidates);

  public Task<IReadOnlyList<RuleRow>> GetRulesAsync(CancellationToken cancellationToken = default) =>
    database.QueryAsync("EXEC intranet.GetTitleRules;",
      reader => new RuleRow(
        PimDb.Int32(reader, "TitleRuleId"), PimDb.TextOrEmpty(reader, "RuleCode"), PimDb.TextOrEmpty(reader, "Name"),
        PimDb.Text(reader, "CategoryTreeCode"), PimDb.Text(reader, "CategoryCode"), PimDb.Text(reader, "CategoryName"),
        PimDb.Text(reader, "CategoryPath"), PimDb.Text(reader, "LanguageCode"), PimDb.TextOrEmpty(reader, "Template"),
        PimDb.TextOrEmpty(reader, "Separator"), PimDb.Bool(reader, "IsActive"), PimDb.Int32(reader, "SortOrder"),
        PimDb.Text(reader, "Note"), PimDb.DateTimeValue(reader, "UpdatedUtc"), PimDb.TextOrEmpty(reader, "UpdatedBy")),
      null, cancellationToken);

  public Task<IReadOnlyList<CategoryOption>> GetCategoriesAsync(CancellationToken cancellationToken = default) =>
    database.QueryAsync(
      "SELECT CategoryTreeCode, CategoryCode, CategoryPath FROM canon.Category WHERE IsActive = 1 ORDER BY CategoryTreeCode, CategoryPath;",
      reader => new CategoryOption(PimDb.TextOrEmpty(reader, "CategoryTreeCode"), PimDb.TextOrEmpty(reader, "CategoryCode"), PimDb.TextOrEmpty(reader, "CategoryPath")),
      null, cancellationToken);

  public async Task<int> SaveRuleAsync(
    string ruleCode, string name, string? categoryTreeCode, string? categoryCode, string? languageCode,
    string template, string separator, bool isActive, int sortOrder, string? note, string actor,
    CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("pim.SaveTitleRule", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.Add("@RuleCode", SqlDbType.NVarChar, 100).Value = ruleCode;
    command.Parameters.Add("@Name", SqlDbType.NVarChar, 200).Value = name;
    command.Parameters.Add("@CategoryTreeCode", SqlDbType.NVarChar, 50).Value = Nullable(categoryTreeCode);
    command.Parameters.Add("@CategoryCode", SqlDbType.NVarChar, 200).Value = Nullable(categoryCode);
    command.Parameters.Add("@LanguageCode", SqlDbType.NVarChar, 20).Value = Nullable(languageCode);
    command.Parameters.Add("@Template", SqlDbType.NVarChar, 1000).Value = template;
    command.Parameters.Add("@Separator", SqlDbType.NVarChar, 10).Value = string.IsNullOrEmpty(separator) ? " " : separator;
    command.Parameters.Add("@IsActive", SqlDbType.Bit).Value = isActive;
    command.Parameters.Add("@SortOrder", SqlDbType.Int).Value = sortOrder;
    command.Parameters.Add("@Note", SqlDbType.NVarChar, 400).Value = Nullable(note);
    command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = actor;
    var value = await command.ExecuteScalarAsync(cancellationToken);
    return value is null or DBNull ? 0 : Convert.ToInt32(value);
  }

  /// <param name="template">Nesprejeta predloga za poskus; null pomeni predlogo pravila.</param>
  public Task<IReadOnlyList<PreviewRow>> PreviewAsync(
    int organizationId, string languageCode, int? titleRuleId, string? template, string? categoryTreeCode,
    string? categoryCode, bool onlyMissing, int take, CancellationToken cancellationToken = default) =>
    database.QueryAsync(
      "EXEC pim.PreviewTitleRules @OrganizationId, @LanguageCode, @TitleRuleId, @Template, @CategoryTreeCode, @CategoryCode, @OnlyMissing, @Take;",
      reader => new PreviewRow(
        PimDb.Int64(reader, "ProductId"), PimDb.TextOrEmpty(reader, "ItemID"), PimDb.Text(reader, "CurrentTitle"),
        PimDb.Text(reader, "ErpTitle"), PimDb.Text(reader, "RuleCode"), PimDb.Text(reader, "ComposedTitle")),
      command =>
      {
        command.Parameters.AddWithValue("@OrganizationId", organizationId);
        command.Parameters.AddWithValue("@LanguageCode", languageCode);
        command.Parameters.AddWithValue("@TitleRuleId", titleRuleId is null ? DBNull.Value : titleRuleId.Value);
        command.Parameters.AddWithValue("@Template", Nullable(template));
        command.Parameters.AddWithValue("@CategoryTreeCode", Nullable(categoryTreeCode));
        command.Parameters.AddWithValue("@CategoryCode", Nullable(categoryCode));
        command.Parameters.AddWithValue("@OnlyMissing", onlyMissing);
        command.Parameters.AddWithValue("@Take", take);
      }, cancellationToken);

  public async Task<ApplyResult> ApplyAsync(
    int organizationId, string languageCode, int? titleRuleId, string? categoryTreeCode, string? categoryCode,
    bool onlyMissing, string actor, string? note, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("pim.ApplyTitleRules", connection)
    {
      CommandType = CommandType.StoredProcedure,
      // Validacija celega podjetja po zapisu lahko traja vec kot privzetih 30 sekund.
      CommandTimeout = 600,
    };
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@LanguageCode", SqlDbType.NVarChar, 20).Value = languageCode;
    command.Parameters.Add("@TitleRuleId", SqlDbType.Int).Value = titleRuleId is null ? DBNull.Value : titleRuleId.Value;
    command.Parameters.Add("@CategoryTreeCode", SqlDbType.NVarChar, 50).Value = Nullable(categoryTreeCode);
    command.Parameters.Add("@CategoryCode", SqlDbType.NVarChar, 200).Value = Nullable(categoryCode);
    command.Parameters.Add("@OnlyMissing", SqlDbType.Bit).Value = onlyMissing;
    command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = actor;
    command.Parameters.Add("@Note", SqlDbType.NVarChar, 400).Value = Nullable(note);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    if (!await reader.ReadAsync(cancellationToken)) return new(0, 0);
    return new(PimDb.Int32(reader, "Written"), PimDb.Int32(reader, "Candidates"));
  }

  static object Nullable(string? value) => string.IsNullOrWhiteSpace(value) ? DBNull.Value : value.Trim();
}
