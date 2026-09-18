using System.Data;
using Microsoft.Data.SqlClient;

namespace PIM.SaopOrdersWorker;

/// <summary>Isti vzorec kot PIM.KatalogWorker.RawInboxWriter (namenoma podvojen — delavci so samostojni).</summary>
public static class RawInboxWriter
{
  public static async Task WriteAsync(
    SqlConnection connection, Guid runId, int organizationId, string sourceCode, string entityType,
    int pageNumber, string payloadXml, CancellationToken cancellationToken = default)
  {
    const string sql = """
      MERGE raw.Inbox AS target
      USING
      (
        SELECT @OrganizationId AS OrganizationId, @SourceCode AS SourceCode, @EntityType AS EntityType, @PageNumber AS PageNumber,
               CONVERT(char(64), HASHBYTES('SHA2_256', CONVERT(varbinary(max), @PayloadXml)), 2) AS PayloadHash
      ) AS source
      ON target.OrganizationId = source.OrganizationId
        AND target.SourceCode = source.SourceCode
        AND target.EntityType = source.EntityType
        AND target.PageNumber = source.PageNumber
        AND target.PayloadHash = source.PayloadHash
      WHEN MATCHED AND target.Status = N'Quarantined' THEN
        UPDATE SET RunId = @RunId, Status = N'Pending', ReceivedUtc = SYSUTCDATETIME(), ProcessedUtc = NULL, FailureReason = NULL
      WHEN NOT MATCHED THEN
        INSERT (RunId, OrganizationId, SourceCode, EntityType, PageNumber, PayloadXml, PayloadHash, Status)
        VALUES (@RunId, source.OrganizationId, source.SourceCode, source.EntityType, source.PageNumber, @PayloadXml, source.PayloadHash, N'Pending');
      """;
    await using var command = new SqlCommand(sql, connection);
    command.Parameters.Add("@RunId", SqlDbType.UniqueIdentifier).Value = runId;
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@SourceCode", SqlDbType.NVarChar, 100).Value = sourceCode;
    command.Parameters.Add("@EntityType", SqlDbType.NVarChar, 100).Value = entityType;
    command.Parameters.Add("@PageNumber", SqlDbType.Int).Value = pageNumber;
    command.Parameters.Add("@PayloadXml", SqlDbType.NVarChar, -1).Value = payloadXml;
    await command.ExecuteNonQueryAsync(cancellationToken);
  }
}
