using System.Data;
using Microsoft.Data.SqlClient;

namespace PIM.Intranet.Services;

/// <param name="FieldKnown">Ali <c>canon.FieldValue</c> to kodo sploh pozna.</param>
/// <param name="IsActive">Ali je zahteva dejansko aktivna; neznano polje ostane neaktivno.</param>
public sealed record SavedRequirement(int FieldRequirementId, bool FieldKnown, bool IsActive);

/// <summary>
/// Urejanje pravil: validacijske zahteve in preslikave polj (migracija 133).
///
/// Uporabnik je 2026-08-28 povedal, da sta obe strani mišljeni tako, da jih ureja on, ne pa
/// da sta samo za branje. Merila validacije se s tem ne spremenijo — spremeni se, kdo jih
/// sme nastaviti. Obe poti pišeta revizijo v <c>b2b.AuditLog</c>.
/// </summary>
/// <summary>Prag poslovne preverbe (migracija 150); OrganizationId null = privzeto za vsa podjetja.</summary>
public sealed record CheckThresholdRow(
  int CheckThresholdId, string CheckCode, int? OrganizationId, string? OrganizationName,
  decimal Threshold, bool IsActive, string? Note, DateTime UpdatedUtc, string UpdatedBy);

public sealed class RulesWriteService(IConfiguration configuration)
{
  string ConnectionString => ConnectionStringResolver.Resolve(configuration)
    ?? throw new InvalidOperationException("Povezava PIM ni nastavljena.");

  public async Task<IReadOnlyList<CheckThresholdRow>> GetCheckThresholdsAsync(CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.GetCheckThresholds", connection) { CommandType = CommandType.StoredProcedure };
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    var rows = new List<CheckThresholdRow>();
    while (await reader.ReadAsync(cancellationToken))
      rows.Add(new(
        PimDb.Int32(reader, "CheckThresholdId"), PimDb.TextOrEmpty(reader, "CheckCode"),
        reader.IsDBNull(reader.GetOrdinal("OrganizationId")) ? null : (int?)reader.GetInt32(reader.GetOrdinal("OrganizationId")), PimDb.Text(reader, "OrganizationName"),
        PimDb.Decimal(reader, "Threshold"), PimDb.Bool(reader, "IsActive"), PimDb.Text(reader, "Note"),
        PimDb.DateTimeValue(reader, "UpdatedUtc"), PimDb.TextOrEmpty(reader, "UpdatedBy")));
    return rows;
  }

  public async Task SaveCheckThresholdAsync(
    string checkCode, int? organizationId, decimal threshold, string actor, string? note = null,
    CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("pim.SaveCheckThreshold", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.Add("@CheckCode", SqlDbType.NVarChar, 60).Value = checkCode;
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId is null ? DBNull.Value : organizationId.Value;
    command.Parameters.Add("@Threshold", SqlDbType.Decimal).Value = threshold;
    command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = actor;
    command.Parameters.Add("@Note", SqlDbType.NVarChar, 400).Value = string.IsNullOrWhiteSpace(note) ? DBNull.Value : note;
    await command.ExecuteNonQueryAsync(cancellationToken);
  }

  public async Task<SavedRequirement> SaveRequirementAsync(
    int validationProfileId, string fieldCode, string severity, bool isRequired, bool isActive,
    string actor, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.SaveFieldRequirement", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.Add("@ValidationProfileId", SqlDbType.Int).Value = validationProfileId;
    command.Parameters.Add("@FieldCode", SqlDbType.NVarChar, 200).Value = fieldCode;
    command.Parameters.Add("@Severity", SqlDbType.NVarChar, 20).Value = severity;
    command.Parameters.Add("@IsRequired", SqlDbType.Bit).Value = isRequired;
    command.Parameters.Add("@IsActive", SqlDbType.Bit).Value = isActive;
    command.Parameters.Add("@ChangedBy", SqlDbType.NVarChar, 200).Value = actor;

    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    if (!await reader.ReadAsync(cancellationToken))
      throw new InvalidOperationException("Shranjevanje zahteve ni vrnilo rezultata.");
    return new(PimDb.Int32(reader, "FieldRequirementId"), PimDb.Bool(reader, "FieldKnown"), PimDb.Bool(reader, "IsActive"));
  }

  /// <param name="fieldMappingId">null pomeni novo preslikavo.</param>
  public async Task SaveMappingAsync(
    long? fieldMappingId, int organizationId, string? sourceCode, string? entityType,
    string? sourceElement, string? targetFieldCode, bool isRequired, bool isActive, string actor,
    CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.SaveFieldMapping", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.Add("@FieldMappingId", SqlDbType.BigInt).Value = (object?)fieldMappingId ?? DBNull.Value;
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@SourceCode", SqlDbType.NVarChar, 100).Value = (object?)sourceCode ?? DBNull.Value;
    command.Parameters.Add("@EntityType", SqlDbType.NVarChar, 100).Value = (object?)entityType ?? DBNull.Value;
    command.Parameters.Add("@SourceElement", SqlDbType.NVarChar, 400).Value = (object?)sourceElement ?? DBNull.Value;
    command.Parameters.Add("@TargetFieldCode", SqlDbType.NVarChar, 200).Value = (object?)targetFieldCode ?? DBNull.Value;
    command.Parameters.Add("@IsRequired", SqlDbType.Bit).Value = isRequired;
    command.Parameters.Add("@IsActive", SqlDbType.Bit).Value = isActive;
    command.Parameters.Add("@ChangedBy", SqlDbType.NVarChar, 200).Value = actor;
    await command.ExecuteNonQueryAsync(cancellationToken);
  }
}
