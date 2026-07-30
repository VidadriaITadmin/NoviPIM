using System.Data;
using Microsoft.Data.SqlClient;

namespace PIM.KatalogWorker;

public sealed class RawInboxWriter(string connectionString)
{
  public async Task WriteAsync(
    IReadOnlyList<RawPage> pages,
    Guid runId,
    int organizationId,
    string sourceCode,
    CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(connectionString);
    await connection.OpenAsync(cancellationToken);
    foreach (var page in pages)
    {
      await using var command = CreateCommand(connection, page, runId, organizationId, sourceCode);
      await command.ExecuteNonQueryAsync(cancellationToken);
    }
  }

  public static SqlCommand CreateCommand(
    SqlConnection connection,
    RawPage page,
    Guid runId,
    int organizationId,
    string sourceCode)
  {
    // MERGE namesto golega pogojnega vstavljanja: en sam obstoječi zapis na (Organizacija, Vir, Entiteta,
    // Stran, PayloadHash) je lahko Pending/Processed (pusti pri miru — brez podvajanja) ali Quarantined
    // (varno vrni v čakalno vrsto pod novim RunId; surov PayloadXml/PayloadHash se ne spremeni).
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
    var command = new SqlCommand(sql, connection);
    command.Parameters.Add("@RunId", SqlDbType.UniqueIdentifier).Value = runId;
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@SourceCode", SqlDbType.NVarChar, 100).Value = sourceCode;
    command.Parameters.Add("@EntityType", SqlDbType.NVarChar, 100).Value = page.Endpoint;
    command.Parameters.Add("@PageNumber", SqlDbType.Int).Value = page.PageNumber;
    command.Parameters.Add("@PayloadXml", SqlDbType.NVarChar, -1).Value = page.PayloadXml;
    return command;
  }
}
