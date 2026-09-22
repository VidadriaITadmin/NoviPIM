using System.Data;
using Microsoft.Data.SqlClient;

namespace PIM.Intranet.Services;


public sealed record SupplierSourceReprocessResult(int Runs, int Pages, string? Errors);

public sealed class SupplierCandidateWriteService(IConfiguration configuration, PimWriteGuard guard)
{
  string ConnectionString => ConnectionStringResolver.Resolve(configuration)
    ?? throw new InvalidOperationException("Povezava PIM ni nastavljena.");

  public async Task RejectAsync(long candidateId, string? reason, string actor, CancellationToken cancellationToken = default)
  {
    await guard.RequireAsync(PimPolicies.CatalogWrite);
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("map.RejectSupplierProductCandidate", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.Add("@SupplierProductCandidateId", SqlDbType.BigInt).Value = candidateId;
    command.Parameters.Add("@Reason", SqlDbType.NVarChar, 500).Value = string.IsNullOrWhiteSpace(reason) ? DBNull.Value : reason.Trim();
    command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = actor;
    await command.ExecuteNonQueryAsync(cancellationToken);
  }

  /// <summary>
  /// Isto surovo XML vira še enkrat skozi preslikavo (244), brez ponovnega nalaganja datoteke in brez
  /// odobritve kandidatov — tudi že uvoženi artikli dobijo kategorije/atribute iz dopolnjenih map.
  /// </summary>
  public async Task<SupplierSourceReprocessResult> ReprocessSourceAsync(int organizationId, string sourceCode, string actor, CancellationToken cancellationToken = default)
  {
    await guard.RequireAsync(PimPolicies.CatalogWrite);
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("map.ReprocessSupplierSource", connection)
    { CommandType = CommandType.StoredProcedure, CommandTimeout = 1800 };
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@SourceCode", SqlDbType.NVarChar, 100).Value = sourceCode;
    command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = actor;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    if (!await reader.ReadAsync(cancellationToken))
      throw new InvalidOperationException("Ponovna preslikava vira ni vrnila rezultata.");
    return new(PimDb.Int32(reader, "Runs"), PimDb.Int32(reader, "Pages"), PimDb.Text(reader, "Errors"));
  }
}
