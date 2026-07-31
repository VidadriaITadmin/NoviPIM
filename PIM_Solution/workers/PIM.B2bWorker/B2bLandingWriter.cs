using System.Security.Cryptography;
using System.Text;
using Microsoft.Data.SqlClient;

namespace PIM.B2bWorker;

public sealed class B2bLandingWriter(string connectionString)
{
  public async Task<long> PersistAndApplyAsync(int organizationId, string sourceCode, string entityType, string sourceRecordKey, string payloadJson, CancellationToken cancellationToken = default)
  {
    if (organizationId <= 0) throw new ArgumentOutOfRangeException(nameof(organizationId));
    ArgumentException.ThrowIfNullOrWhiteSpace(sourceCode);
    ArgumentException.ThrowIfNullOrWhiteSpace(entityType);
    ArgumentException.ThrowIfNullOrWhiteSpace(sourceRecordKey);
    ArgumentException.ThrowIfNullOrWhiteSpace(payloadJson);
    var hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(payloadJson))).ToLowerInvariant();
    await using var connection = new SqlConnection(connectionString);
    await connection.OpenAsync(cancellationToken);
    await using var transaction = (SqlTransaction)await connection.BeginTransactionAsync(cancellationToken);
    const string insert = """
      INSERT b2b.LandingRecord(OrganizationId,SourceCode,EntityType,SourceRecordKey,PayloadJson,PayloadHash)
      OUTPUT INSERTED.LandingRecordId VALUES(@OrganizationId,@SourceCode,@EntityType,@SourceRecordKey,@PayloadJson,@PayloadHash);
      """;
    await using var command = new SqlCommand(insert, connection, transaction);
    command.Parameters.AddWithValue("@OrganizationId", organizationId);
    command.Parameters.AddWithValue("@SourceCode", sourceCode);
    command.Parameters.AddWithValue("@EntityType", entityType);
    command.Parameters.AddWithValue("@SourceRecordKey", sourceRecordKey);
    command.Parameters.AddWithValue("@PayloadJson", payloadJson);
    command.Parameters.AddWithValue("@PayloadHash", hash);
    var id = Convert.ToInt64(await command.ExecuteScalarAsync(cancellationToken));
    await using var apply = new SqlCommand("EXEC b2b.ApplyLandingRecord @LandingRecordId;", connection, transaction);
    apply.Parameters.AddWithValue("@LandingRecordId", id);
    await apply.ExecuteNonQueryAsync(cancellationToken);
    await transaction.CommitAsync(cancellationToken);
    return id;
  }
}
