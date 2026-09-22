using System.Data;
using Microsoft.Data.SqlClient;

namespace PIM.Intranet.Services;

public sealed class QualityWriteService(IConfiguration configuration, PimWriteGuard guard)
{
  string ConnectionString => ConnectionStringResolver.Resolve(configuration)
    ?? throw new InvalidOperationException("Povezava PIM ni nastavljena.");

  public async Task ValidateAsync(long productId, CancellationToken cancellationToken = default)
  {
    await guard.RequireAsync(PimPolicies.BusinessWrite);
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("val.RunValidationForProduct", connection)
      { CommandType = CommandType.StoredProcedure, CommandTimeout = 120 };
    command.Parameters.Add("@ProductId", SqlDbType.BigInt).Value = productId;
    await command.ExecuteNonQueryAsync(cancellationToken);
  }

  /// <summary>
  /// Skrbnik potrdi (ali prekliče), da artikel nima EAN / proizvajalca / dobavitelja (249,
  /// <c>val.SetProductFieldWaiver</c>). Baza artikel takoj ponovno validira, zato po klicu
  /// kartica ne kaže več napake za potrjeno polje. Samo vloga ADMIN (<see cref="PimPolicies.FieldWaiver"/>).
  /// </summary>
  public async Task SetFieldWaiverAsync(long productId, string fieldCode, string? reason, bool active,
    string actor, CancellationToken cancellationToken = default)
  {
    await guard.RequireAsync(PimPolicies.FieldWaiver);
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("val.SetProductFieldWaiver", connection)
      { CommandType = CommandType.StoredProcedure, CommandTimeout = 120 };
    command.Parameters.Add("@ProductId", SqlDbType.BigInt).Value = productId;
    command.Parameters.Add("@FieldCode", SqlDbType.NVarChar, 200).Value = fieldCode;
    command.Parameters.Add("@Reason", SqlDbType.NVarChar, 500).Value = string.IsNullOrWhiteSpace(reason) ? DBNull.Value : reason.Trim();
    command.Parameters.Add("@IsActive", SqlDbType.Bit).Value = active;
    command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = actor;
    await command.ExecuteNonQueryAsync(cancellationToken);
  }

  public async Task SetHoldAsync(long productId, string channel, string? reason, bool active,
    string actor, CancellationToken cancellationToken = default)
  {
    await guard.RequireAsync(PimPolicies.BusinessWrite);
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("val.SetProductHold", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.Add("@ProductId",SqlDbType.BigInt).Value=productId;
    command.Parameters.Add("@ChannelCode",SqlDbType.NVarChar,20).Value=channel;
    command.Parameters.Add("@Reason",SqlDbType.NVarChar,500).Value=string.IsNullOrWhiteSpace(reason)?DBNull.Value:reason.Trim();
    command.Parameters.Add("@IsActive",SqlDbType.Bit).Value=active;
    command.Parameters.Add("@Actor",SqlDbType.NVarChar,200).Value=actor;
    await command.ExecuteNonQueryAsync(cancellationToken);
  }
}
