using System.Data;
using Microsoft.Data.SqlClient;

namespace PIM.Intranet.Services;

/// <param name="FieldKnown">Ali <c>canon.FieldValue</c> to kodo sploh pozna.</param>
/// <param name="IsActive">Ali je zahteva dejansko aktivna; neznano polje ostane neaktivno.</param>
public sealed record SavedRequirement(int FieldRequirementId, bool FieldKnown, bool IsActive);

/// <summary>
/// Urejanje pravil: validacijske zahteve, preslikave polj in skupni slovar vrednosti.
///
/// Uporabnik je 2026-08-28 povedal, da sta obe strani mišljeni tako, da jih ureja on, ne pa
/// da sta samo za branje. Merila validacije se s tem ne spremenijo — spremeni se, kdo jih
/// sme nastaviti. Obe poti pišeta revizijo v <c>b2b.AuditLog</c>.
/// </summary>
/// <summary>Prag poslovne preverbe (migracija 150); OrganizationId null = privzeto za vsa podjetja.</summary>
public sealed record CheckThresholdRow(
  int CheckThresholdId, string CheckCode, int? OrganizationId, string? OrganizationName,
  decimal Threshold, bool IsActive, string? Note, DateTime UpdatedUtc, string UpdatedBy);

public sealed class RulesWriteService(IConfiguration configuration, PimWriteGuard guard)
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
    await guard.RequireAsync(PimPolicies.AlertWrite);
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
    await guard.RequireAsync(PimPolicies.BusinessWrite);
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.SaveFieldRequirement", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.Add("@ValidationProfileId", SqlDbType.Int).Value = validationProfileId;
    command.Parameters.Add("@FieldCode", SqlDbType.NVarChar, 200).Value = fieldCode;
    command.Parameters.Add("@Severity", SqlDbType.NVarChar, 20).Value = severity;
    command.Parameters.Add("@IsRequired", SqlDbType.Bit).Value = isRequired;
    command.Parameters.Add("@IsActive", SqlDbType.Bit).Value = isActive;
    command.Parameters.Add("@ChangedBy", SqlDbType.NVarChar, 200).Value = actor;

    SavedRequirement saved;
    await using (var reader = await command.ExecuteReaderAsync(cancellationToken))
    {
      if (!await reader.ReadAsync(cancellationToken))
        throw new InvalidOperationException("Shranjevanje zahteve ni vrnilo rezultata.");
      saved = new(PimDb.Int32(reader, "FieldRequirementId"), PimDb.Bool(reader, "FieldKnown"), PimDb.Bool(reader, "IsActive"));
    }

    // Sprememba pravila ne sme pustiti starih rezultatov do naslednjega urnika. Validacija
    // tece na isti povezavi sele po zaprtju rezultata shranjevanja; napake se zato odprejo
    // oziroma zaprejo takoj. Daljsi klic je nameren in uporabniku daje resnicno stanje.
    await using var validation = new SqlCommand("val.RunValidation", connection)
    { CommandType = CommandType.StoredProcedure, CommandTimeout = 600 };
    await validation.ExecuteNonQueryAsync(cancellationToken);
    return saved;
  }

  /// <param name="fieldMappingId">null pomeni novo preslikavo.</param>
  public async Task SaveMappingAsync(
    long? fieldMappingId, int organizationId, string? sourceCode, string? entityType,
    string? sourceElement, string? targetFieldCode, bool isRequired, bool isActive, string actor,
    CancellationToken cancellationToken = default)
  {
    await guard.RequireAsync(PimPolicies.BusinessWrite);
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

  /// <summary>
  /// Doda ali uredi eno vrstico skupnega slovarja. Slovar velja za vsa podjetja, zato revizijska
  /// vrstica uporablja OrganizationId 0 enako kot globalne validacijske zahteve.
  /// </summary>
  public async Task<long> SaveValueLookupAsync(
    long? valueLookupId, string domain, string sourceValue, string language, string targetValue,
    string? note, bool isActive, string actor, CancellationToken cancellationToken = default)
  {
    await guard.RequireAsync(PimPolicies.BusinessWrite);
    domain = string.IsNullOrWhiteSpace(domain) ? "*" : domain.Trim();
    sourceValue = sourceValue.Trim();
    language = language.Trim().ToUpperInvariant();
    targetValue = targetValue.Trim();
    note = string.IsNullOrWhiteSpace(note) ? null : note.Trim();

    if (sourceValue.Length == 0) throw new InvalidOperationException("Izvorna vrednost je obvezna.");
    if (language.Length == 0) throw new InvalidOperationException("Jezik je obvezen.");
    if (targetValue.Length == 0) throw new InvalidOperationException("Ciljna vrednost je obvezna.");

    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("""
      SET XACT_ABORT ON;
      BEGIN TRAN;

      DECLARE @EffectiveId int = CONVERT(int, @ValueLookupId);
      DECLARE @OldJson nvarchar(max);
      IF @EffectiveId IS NOT NULL
      BEGIN
        SELECT @OldJson = (SELECT Domain, SourceValue, Language, TargetValue, Note, IsActive
          FROM map.ValueLookup WHERE ValueLookupId = @EffectiveId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        IF @OldJson IS NULL THROW 51107, N'Vrstica slovarja ne obstaja.', 1;

        UPDATE map.ValueLookup
        SET Domain = @Domain, SourceValue = @SourceValue, Language = @Language,
            TargetValue = @TargetValue, Note = @Note, IsActive = @IsActive
        WHERE ValueLookupId = @EffectiveId;
      END
      ELSE
      BEGIN
        INSERT map.ValueLookup (Domain, SourceValue, Language, TargetValue, Note, IsActive)
        VALUES (@Domain, @SourceValue, @Language, @TargetValue, @Note, @IsActive);
        SET @EffectiveId = SCOPE_IDENTITY();
      END;

      DECLARE @NewJson nvarchar(max) = (SELECT Domain, SourceValue, Language, TargetValue, Note, IsActive
        FROM map.ValueLookup WHERE ValueLookupId = @EffectiveId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
      INSERT b2b.AuditLog
        (OrganizationId, EntityType, EntityKey, ActionCode, OldValueJson, NewValueJson, ChangedBy, ChangedUtc)
      VALUES
        (0, N'ValueLookup', CONVERT(nvarchar(200), @EffectiveId),
         CASE WHEN @OldJson IS NULL THEN N'ADD' ELSE N'UPDATE' END,
         @OldJson, @NewJson, @ChangedBy, SYSUTCDATETIME());

      COMMIT;
      SELECT CONVERT(bigint, @EffectiveId);
      """, connection);
    command.Parameters.Add("@ValueLookupId", SqlDbType.BigInt).Value = (object?)valueLookupId ?? DBNull.Value;
    command.Parameters.Add("@Domain", SqlDbType.NVarChar, 200).Value = domain;
    command.Parameters.Add("@SourceValue", SqlDbType.NVarChar, 400).Value = sourceValue;
    command.Parameters.Add("@Language", SqlDbType.NVarChar, 10).Value = language;
    command.Parameters.Add("@TargetValue", SqlDbType.NVarChar, 400).Value = targetValue;
    command.Parameters.Add("@Note", SqlDbType.NVarChar, 400).Value = (object?)note ?? DBNull.Value;
    command.Parameters.Add("@IsActive", SqlDbType.Bit).Value = isActive;
    command.Parameters.Add("@ChangedBy", SqlDbType.NVarChar, 200).Value = actor;
    return Convert.ToInt64(await command.ExecuteScalarAsync(cancellationToken));
  }
}
