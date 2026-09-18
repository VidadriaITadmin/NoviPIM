using System.Data;
using Microsoft.Data.SqlClient;

namespace PIM.Intranet.Services;

/// <summary>
/// Odobritev/zavrnitev kandidatov za nove artikle od dobaviteljev (219). Odobritev ustvari
/// canon.Product; obogatitev pride sama z naslednjim tekom vira, ta storitev je ne podvaja.
/// </summary>
public sealed class SupplierCandidateWriteService(IConfiguration configuration, PimWriteGuard guard)
{
  string ConnectionString => ConnectionStringResolver.Resolve(configuration)
    ?? throw new InvalidOperationException("Povezava PIM ni nastavljena.");

  public async Task ApproveAsync(long candidateId, string actor, CancellationToken cancellationToken = default)
  {
    await guard.RequireAsync(PimPolicies.CatalogWrite);
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("map.ApproveSupplierProductCandidate", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.Add("@SupplierProductCandidateId", SqlDbType.BigInt).Value = candidateId;
    command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = actor;
    await command.ExecuteNonQueryAsync(cancellationToken);
  }

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
}
