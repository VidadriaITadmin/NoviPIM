using System.Data;
using System.Text.Json;
using Microsoft.Data.SqlClient;

namespace PIM.Intranet.Services;

/// <param name="Approved">Kandidati, ki so postali artikli.</param>
/// <param name="Skipped">Kandidati, ki jih ni bilo mogoce odobriti (niso vec v cakanju ipd.).</param>
/// <param name="Runs">Zajemi, ki so sli znova skozi preslikavo, da so novi artikli dobili podatke.</param>
/// <param name="Pages">Strani teh zajemov, vrnjene na Pending in obdelane.</param>
public sealed record SupplierCandidateImportResult(int Approved, int Skipped, int Runs, int Pages, string? Errors);

public sealed record SupplierSourceReprocessResult(int Runs, int Pages, string? Errors);

/// <summary>
/// Odobritev/zavrnitev kandidatov za nove artikle od dobaviteljev (219) in uvoz z obogatitvijo (240).
/// Odobritev sama ustvari canon.Product; uvoz nato isti zajem takoj pozene skozi preslikavo, da
/// artikel dobi atribute, slike, dokumente in kategorijo, ne sele ob naslednjem teku vira.
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

  /// <summary>
  /// Odobri izbrane kandidate in takoj pozene preslikavo zadevnih zajemov (240). Traja lahko vec
  /// minut — cel zajem (vse strani) gre skozi map.ProcessRawInbox, zato dolg CommandTimeout.
  /// </summary>
  public async Task<SupplierCandidateImportResult> ImportAsync(IReadOnlyCollection<long> candidateIds, string actor, CancellationToken cancellationToken = default)
  {
    await guard.RequireAsync(PimPolicies.CatalogWrite);
    if (candidateIds.Count == 0) throw new ArgumentException("Izberi vsaj enega kandidata.", nameof(candidateIds));
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("map.ImportSupplierProductCandidates", connection)
    { CommandType = CommandType.StoredProcedure, CommandTimeout = 1800 };
    command.Parameters.Add("@CandidatesJson", SqlDbType.NVarChar, -1).Value = JsonSerializer.Serialize(candidateIds.Distinct().ToArray());
    command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = actor;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    if (!await reader.ReadAsync(cancellationToken))
      throw new InvalidOperationException("Uvoz kandidatov ni vrnil rezultata.");
    return new(
      PimDb.Int32(reader, "Approved"), PimDb.Int32(reader, "Skipped"),
      PimDb.Int32(reader, "Runs"), PimDb.Int32(reader, "Pages"), PimDb.Text(reader, "Errors"));
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
