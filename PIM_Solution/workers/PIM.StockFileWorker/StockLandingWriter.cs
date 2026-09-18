using Microsoft.Data.SqlClient;
using PIM.StockMapping;

namespace PIM.StockFileWorker;

public sealed class StockLandingWriter(string connectionString)
{
  public async Task<(Guid RunId, int Applied, int Quarantined)> PersistAsync(
    int organizationId, string sourceCode, string connectorType, string endpoint, DateTime snapshotUtc,
    string payloadHash, IReadOnlyList<ExtractedStockRow> records, string dateFormat,
    StockFieldContract? fields = null, CancellationToken cancellationToken = default)
  {
    fields ??= new();
    await using var connection = new SqlConnection(connectionString);
    await connection.OpenAsync(cancellationToken);
    await using var transaction = (SqlTransaction)await connection.BeginTransactionAsync(cancellationToken);
    var runId = Guid.NewGuid();
    try
    {
      var connectorId = await EnsureConnectorAsync(connection, transaction, organizationId, sourceCode, connectorType, cancellationToken);
      var identityRule = await LoadIdentityRuleAsync(connection, transaction, connectorId, cancellationToken);
      await ExecuteAsync(connection, transaction, """
        INSERT stock.SyncRun(SyncRunId,OrganizationId,SourceConnectorId,Status,Endpoint,StartedUtc,FetchedUtc,RecordsRead)
        VALUES(@RunId,@OrganizationId,@ConnectorId,N'Running',@Endpoint,@SnapshotUtc,@SnapshotUtc,@Count);
        INSERT stock.Snapshot(SyncRunId,OrganizationId,SourceConnectorId,Endpoint,SnapshotUtc,IsActive)
        VALUES(@RunId,@OrganizationId,@ConnectorId,@Endpoint,@SnapshotUtc,0);
        """, cancellationToken, ("@RunId",runId),("@OrganizationId",organizationId),("@ConnectorId",connectorId),("@Endpoint",endpoint),("@SnapshotUtc",snapshotUtc),("@Count",records.Count));
      var normalizer = new StockNormalizer();
      var applied=0; var quarantined=0;
      foreach (var row in records)
      {
        var result=normalizer.Normalize(row,identityRule,dateFormat,fields);
        row.Values.TryGetValue(identityRule.SourceKeyField,out var sourceItemId);
        row.Values.TryGetValue(fields.EanField,out var ean); row.Values.TryGetValue(fields.QuantityField,out var quantity);
        row.Values.TryGetValue(fields.AvailabilityDateField,out var date); row.Values.TryGetValue(fields.IncomingQuantityField,out var incoming);
        var canonicalDate=result.Position?.AvailabilityDate?.ToString("yyyy-MM-dd",System.Globalization.CultureInfo.InvariantCulture)??date;
        var landingId=await InsertLandingAsync(connection,transaction,runId,organizationId,connectorId,row.RecordOrdinal.ToString(System.Globalization.CultureInfo.InvariantCulture),snapshotUtc,endpoint,payloadHash,ean,sourceItemId,result.Position?.NormalizedItemId,quantity,canonicalDate,incoming,cancellationToken);
        await ExecuteAsync(connection,transaction,"EXEC stock.ApplyLandingRecord @LandingRecordId,@DateFormat;",cancellationToken,("@LandingRecordId",landingId),("@DateFormat","yyyy-MM-dd"));
        if(result.Position is null)quarantined++;else applied++;
      }
      await using (var counts = new SqlCommand("SELECT SUM(CASE WHEN Status=N'Applied' THEN 1 ELSE 0 END),SUM(CASE WHEN Status=N'Quarantined' THEN 1 ELSE 0 END) FROM stock.LandingRecord WHERE SyncRunId=@RunId;",connection,transaction))
      {
        counts.Parameters.AddWithValue("@RunId",runId);
        await using var reader=await counts.ExecuteReaderAsync(cancellationToken);await reader.ReadAsync(cancellationToken);
        applied=reader.IsDBNull(0)?0:reader.GetInt32(0);quarantined=reader.IsDBNull(1)?0:reader.GetInt32(1);
      }
      await ExecuteAsync(connection,transaction,"UPDATE stock.Snapshot SET IsActive=0 WHERE OrganizationId=@OrganizationId AND SourceConnectorId=@ConnectorId; UPDATE stock.Snapshot SET IsActive=1 WHERE SyncRunId=@RunId; UPDATE stock.SyncRun SET Status=N'Completed',CompletedUtc=SYSUTCDATETIME(),RecordsApplied=@Applied,RecordsQuarantined=@Quarantined WHERE SyncRunId=@RunId;",cancellationToken,("@OrganizationId",organizationId),("@ConnectorId",connectorId),("@RunId",runId),("@Applied",applied),("@Quarantined",quarantined));
      await transaction.CommitAsync(cancellationToken);
      return(runId,applied,quarantined);
    }
    catch { await transaction.RollbackAsync(cancellationToken); throw; }
  }

  static async Task<StockIdentityRule> LoadIdentityRuleAsync(SqlConnection c,SqlTransaction t,int connectorId,CancellationToken ct)
  {
    await using var cmd=new SqlCommand("SELECT TOP(1) SourceKeyField,Prefix,ReplaceOld,ReplaceNew,MatchPriority FROM map.StockIdentityRule WHERE SourceConnectorId=@ConnectorId AND IsActive=1 ORDER BY StockIdentityRuleId;",c,t);
    cmd.Parameters.AddWithValue("@ConnectorId",connectorId);
    await using var reader=await cmd.ExecuteReaderAsync(ct);
    if(!await reader.ReadAsync(ct)) throw new InvalidOperationException("Aktivno identitetno pravilo za stock konektor ni konfigurirano.");
    return new(reader.GetString(0),reader.GetString(1),reader.IsDBNull(2)?null:reader.GetString(2),reader.IsDBNull(3)?null:reader.GetString(3),reader.GetString(4));
  }

  static async Task<int> EnsureConnectorAsync(SqlConnection c,SqlTransaction t,int org,string code,string type,CancellationToken ct)
  {
    await ExecuteAsync(c,t,"IF NOT EXISTS(SELECT 1 FROM map.SourceConnector WHERE OrganizationId=@Org AND SourceCode=@Code) INSERT map.SourceConnector(SourceCode,OrganizationId,ConnectorType) VALUES(@Code,@Org,@Type);",ct,("@Org",org),("@Code",code),("@Type",type));
    await using var cmd=new SqlCommand("SELECT SourceConnectorId FROM map.SourceConnector WHERE OrganizationId=@Org AND SourceCode=@Code;",c,t);cmd.Parameters.AddWithValue("@Org",org);cmd.Parameters.AddWithValue("@Code",code);return Convert.ToInt32(await cmd.ExecuteScalarAsync(ct));
  }
  static async Task<long> InsertLandingAsync(SqlConnection c,SqlTransaction t,Guid run,int org,int connector,string key,DateTime snapshot,string endpoint,string hash,string? ean,string? source,string? normalized,string? quantity,string? date,string? incoming,CancellationToken ct)
  {
    await using var cmd=new SqlCommand("""INSERT stock.LandingRecord(SyncRunId,OrganizationId,SourceConnectorId,SourceRecordKey,SnapshotUtc,Endpoint,RawPayload,PayloadHash,Ean,SourceItemId,NormalizedItemId,QuantityText,AvailabilityDateText,IncomingQuantityText) OUTPUT INSERTED.LandingRecordId VALUES(@Run,@Org,@Connector,@Key,@Snapshot,@Endpoint,@Raw,@Hash,@Ean,@Source,@Normalized,@Quantity,@Date,@Incoming);""",c,t);
    foreach(var p in new(string,object?)[ ]{("@Run",run),("@Org",org),("@Connector",connector),("@Key",key),("@Snapshot",snapshot),("@Endpoint",endpoint),("@Raw",key),("@Hash",hash),("@Ean",ean),("@Source",source),("@Normalized",normalized),("@Quantity",quantity),("@Date",date),("@Incoming",incoming)})cmd.Parameters.AddWithValue(p.Item1,p.Item2??DBNull.Value);
    return Convert.ToInt64(await cmd.ExecuteScalarAsync(ct));
  }
  static async Task ExecuteAsync(SqlConnection c,SqlTransaction t,string sql,CancellationToken ct,params (string,object?)[] values){await using var cmd=new SqlCommand(sql,c,t);foreach(var p in values)cmd.Parameters.AddWithValue(p.Item1,p.Item2??DBNull.Value);await cmd.ExecuteNonQueryAsync(ct);}
}
