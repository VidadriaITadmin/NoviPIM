using System.Data;
using System.Xml;
using System.Xml.XPath;
using Microsoft.Data.SqlClient;

namespace PIM.XmlMapping;

public sealed class SqlMappingPipeline(string connectionString, XPathMappingExtractor? extractor = null)
{
  private readonly XPathMappingExtractor extractor = extractor ?? new XPathMappingExtractor();

  /// <summary>Meja za en klic apply postopka; prek PIM_MAPPING_TIMEOUT_SECONDS, privzeto 900.</summary>
  private static int ApplyCommandTimeoutSeconds =>
    int.TryParse(Environment.GetEnvironmentVariable("PIM_MAPPING_TIMEOUT_SECONDS"), out var parsed) && parsed > 0
      ? parsed
      : 900;

  public async Task ExtractAndApplyAsync(
    Guid runId,
    int organizationId,
    string sourceCode,
    CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(connectionString);
    await connection.OpenAsync(cancellationToken);
    await SetChangeContextAsync(connection, runId, sourceCode, cancellationToken);
    try
    {
      var inboxes = await ReadInboxesAsync(connection, runId, organizationId, sourceCode, cancellationToken);

      foreach (var inbox in inboxes)
      {
        try
        {
          var values = extractor.Extract(inbox.PayloadXml, inbox.RecordXPath, inbox.Mappings);
          await WriteValuesAsync(connection, inbox.InboxId, values, cancellationToken);
        }
        catch (XmlException exception)
        {
          await QuarantineAsync(connection, inbox.InboxId, exception.Message, cancellationToken);
        }
        catch (XPathException exception)
        {
          await QuarantineAsync(connection, inbox.InboxId, exception.Message, cancellationToken);
        }
      }

      // map.ProcessRawInbox gre čez zapise s kurzorjem in na vsakem izvede pet MERGE stavkov.
      // Ena zajeta stran nosi do tisoč zapisov, zato en klic redno preseže privzetih 30 sekund;
      // to ni znak blokade, ampak obseg dela. Meja ostane nastavljiva, da se ne izgubi zaznava
      // pravega zastoja.
      await using var apply = new SqlCommand(
        "EXEC map.ProcessRawInbox @RunId,@OrganizationId,@SourceCode;",
        connection)
      {
        CommandTimeout = ApplyCommandTimeoutSeconds
      };
      apply.Parameters.Add("@RunId", SqlDbType.UniqueIdentifier).Value = runId;
      apply.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
      apply.Parameters.Add("@SourceCode", SqlDbType.NVarChar, 100).Value = sourceCode;
      await apply.ExecuteNonQueryAsync(cancellationToken);
    }
    finally
    {
      await ClearChangeContextAsync(connection, cancellationToken);
    }
  }

  private static async Task SetChangeContextAsync(SqlConnection connection, Guid runId, string sourceCode, CancellationToken cancellationToken)
  {
    await using var command = new SqlCommand("pim.SetChangeContext", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.Add("@ChangeSource", SqlDbType.NVarChar, 32).Value = "XML_FEED";
    command.Parameters.Add("@ChangedBy", SqlDbType.NVarChar, 128).Value = $"PIM.XmlMapping:{sourceCode}";
    command.Parameters.Add("@BatchId", SqlDbType.UniqueIdentifier).Value = runId;
    command.Parameters.Add("@Note", SqlDbType.NVarChar, 400).Value = $"Raw mapping run {runId}";
    await command.ExecuteNonQueryAsync(cancellationToken);
  }

  private static async Task ClearChangeContextAsync(SqlConnection connection, CancellationToken cancellationToken)
  {
    await using var command = new SqlCommand("pim.ClearChangeContext", connection) { CommandType = CommandType.StoredProcedure };
    await command.ExecuteNonQueryAsync(cancellationToken);
  }

  private static async Task<IReadOnlyList<InboxMapping>> ReadInboxesAsync(
    SqlConnection connection,
    Guid runId,
    int organizationId,
    string sourceCode,
    CancellationToken cancellationToken)
  {
    const string sql = """
      SELECT inbox.InboxId,inbox.PayloadXml,entityMapping.RecordXPath,
        fieldMapping.FieldMappingId,fieldMapping.MappingVersion,fieldMapping.SourceElement,
        fieldMapping.TargetFieldCode,fieldMapping.IsRequired
      FROM raw.Inbox inbox
      INNER JOIN map.SourceConnector connector
        ON connector.SourceCode=inbox.SourceCode AND connector.OrganizationId=inbox.OrganizationId AND connector.IsActive=1
      INNER JOIN map.EntityMapping entityMapping
        ON entityMapping.SourceConnectorId=connector.SourceConnectorId AND entityMapping.EntityType=inbox.EntityType AND entityMapping.IsActive=1
      INNER JOIN map.FieldMapping fieldMapping
        ON fieldMapping.SourceConnectorId=connector.SourceConnectorId AND fieldMapping.EntityType=inbox.EntityType AND fieldMapping.IsActive=1
      WHERE inbox.RunId=@RunId AND inbox.OrganizationId=@OrganizationId AND inbox.SourceCode=@SourceCode
        AND inbox.Status=N'Pending'
      ORDER BY inbox.InboxId,fieldMapping.FieldMappingId;
      """;
    await using var command = new SqlCommand(sql, connection);
    command.Parameters.Add("@RunId", SqlDbType.UniqueIdentifier).Value = runId;
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@SourceCode", SqlDbType.NVarChar, 100).Value = sourceCode;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    var grouped = new Dictionary<long, InboxMapping>();
    while (await reader.ReadAsync(cancellationToken))
    {
      var inboxId = reader.GetInt64(0);
      if (!grouped.TryGetValue(inboxId, out var inbox))
      {
        inbox = new InboxMapping(inboxId, reader.GetString(1), reader.GetString(2), []);
        grouped.Add(inboxId, inbox);
      }
      inbox.Mappings.Add(new FieldMapping(
        reader.GetInt32(3),
        reader.GetInt32(4),
        reader.GetString(5),
        reader.GetString(6),
        reader.GetBoolean(7)));
    }
    return grouped.Values.ToArray();
  }

  private static async Task WriteValuesAsync(
    SqlConnection connection,
    long inboxId,
    IReadOnlyList<ExtractedValue> values,
    CancellationToken cancellationToken)
  {
    await using var transaction = (SqlTransaction)await connection.BeginTransactionAsync(cancellationToken);
    foreach (var value in values)
    {
      const string sql = """
        IF NOT EXISTS
        (
          SELECT 1 FROM map.ExtractedValue
          WHERE InboxId=@InboxId AND FieldMappingId=@FieldMappingId
            AND MappingVersion=@MappingVersion AND RecordOrdinal=@RecordOrdinal
        )
          INSERT map.ExtractedValue(InboxId,FieldMappingId,MappingVersion,RecordOrdinal,TargetFieldCode,Value)
          VALUES(@InboxId,@FieldMappingId,@MappingVersion,@RecordOrdinal,@TargetFieldCode,@Value);
        """;
      await using var command = new SqlCommand(sql, connection, transaction);
      command.Parameters.Add("@InboxId", SqlDbType.BigInt).Value = inboxId;
      command.Parameters.Add("@FieldMappingId", SqlDbType.Int).Value = value.FieldMappingId;
      command.Parameters.Add("@MappingVersion", SqlDbType.Int).Value = value.MappingVersion;
      command.Parameters.Add("@RecordOrdinal", SqlDbType.Int).Value = value.RecordOrdinal;
      command.Parameters.Add("@TargetFieldCode", SqlDbType.NVarChar, 200).Value = value.TargetFieldCode;
      command.Parameters.Add("@Value", SqlDbType.NVarChar, -1).Value = (object?)value.Value ?? DBNull.Value;
      await command.ExecuteNonQueryAsync(cancellationToken);
    }
    await transaction.CommitAsync(cancellationToken);
  }

  private static async Task QuarantineAsync(
    SqlConnection connection,
    long inboxId,
    string reason,
    CancellationToken cancellationToken)
  {
    await using var command = new SqlCommand("""
      UPDATE raw.Inbox SET Status=N'Quarantined',ProcessedUtc=SYSUTCDATETIME(),FailureReason=LEFT(@Reason,2000)
      WHERE InboxId=@InboxId AND Status=N'Pending';
      """, connection);
    command.Parameters.Add("@InboxId", SqlDbType.BigInt).Value = inboxId;
    command.Parameters.Add("@Reason", SqlDbType.NVarChar, 2000).Value = reason;
    await command.ExecuteNonQueryAsync(cancellationToken);
  }

  private sealed record InboxMapping(
    long InboxId,
    string PayloadXml,
    string RecordXPath,
    List<FieldMapping> Mappings);
}
