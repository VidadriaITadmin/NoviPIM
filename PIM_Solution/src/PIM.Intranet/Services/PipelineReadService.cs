namespace PIM.Intranet.Services;

public sealed record SourceConnectorRow(
  int SourceConnectorId, string SourceCode, int OrganizationId, string ConnectorType, bool IsActive, bool CanCreateProducts,
  long EntityCount, long FieldCount, long PendingCount, long TotalCount, DateTime? LastWatermarkUtc, DateTime? LastReceivedUtc);

public sealed record InboxGroupRow(string SourceCode, string EntityType, string Status, long PageCount, DateTime? OldestUtc, DateTime? NewestUtc);
public sealed record InboxRow(long InboxId, Guid RunId, string SourceCode, string EntityType, int PageNumber, string Status, DateTime ReceivedUtc, DateTime? ProcessedUtc, string? FailureReason);
public sealed record UnmappedValueRow(string TargetFieldCode, string Reason, string Value, long SeenCount, DateTime LastSeenUtc);
public sealed record MissingTranslationRow(long MissingTranslationId, string Domain, string Language, string SourceValue, long SeenCount, DateTime FirstSeenUtc, DateTime LastSeenUtc);
public sealed record MissingCategoryRow(long MissingCategoryMapId, string SourceCode, string CategoryTreeCode, string SourcePathKey, long SeenCount, DateTime FirstSeenUtc, DateTime LastSeenUtc);
public sealed record IngestSummary(long PendingPages, long ProcessedPages, long QuarantinedPages, long UnmappedValues, long MissingTranslations, long MissingCategories);

public sealed record InboundFlowRow(
  int OrganizationId, string OrganizationName, int SourceConnectorId, string SourceCode, string ConnectorType,
  string FlowKind, bool IsActive, bool CanCreateProducts, string Status, Guid? LastRunId, DateTime? LastAttemptUtc,
  DateTime? LastSuccessUtc, DateTime? LastFailureUtc, DateTime? NextScheduledUtc, bool? ScheduleEnabled,
  long ReceivedLast24Hours, long PendingCount, long RejectedCount, string? LastError, string? Endpoint);

public sealed record InboundOverviewSummary(
  long PendingPages, DateTime? OldestPendingUtc, long QuarantinedPages, long UnmappedValues,
  long MappingWorkCount, long StockUnmatchedCount, long OpenTechnicalProblems);

public sealed record InboundRunRow(
  string RunKind, Guid RunId, int OrganizationId, string OrganizationName, string Pipeline, string SourceCode,
  string Status, long RowsRead, long RowsSucceeded, long RowsFailed, DateTime StartedUtc, DateTime? EndedUtc,
  Guid? CorrelationId);

public sealed record InboundRunHeader(
  string RunKind, Guid RunId, int OrganizationId, string OrganizationName, string Pipeline, string SourceCode,
  string Status, string? Endpoint, long RowsRead, long RowsSucceeded, long RowsFailed, DateTime StartedUtc,
  DateTime? EndedUtc, Guid? CorrelationId);

public sealed record InboundRunStepRow(string StepCode, int Attempt, long RowsIn, long RowsMerged, long? DurationMs, string Status, DateTime RecordedUtc);
public sealed record InboundRunPageRow(long InboxId, string EntityType, int PageNumber, string Status, DateTime ReceivedUtc, string? FailureReason);
public sealed record InboundRunErrorRow(long ErrorLogId, DateTime OccurredUtc, string Severity, string ErrorCode, string Message);
public sealed record InboundStockIssueRow(long UnmatchedPositionId, string ReasonCode, string Detail, string? ItemId, string? Ean, DateTime CreatedUtc);
public sealed record InboundRunView(InboundRunHeader Header, IReadOnlyList<InboundRunStepRow> Steps,
  IReadOnlyList<InboundRunPageRow> Pages, IReadOnlyList<InboundRunErrorRow> Errors, IReadOnlyList<InboundStockIssueRow> StockIssues);

public sealed record SourceEntityRow(
  string EntityType, bool HasActiveMapping, long FieldCount, long RequiredFieldCount, long PendingCount,
  long ProcessedCount, long QuarantinedCount, DateTime? LastReceivedUtc, DateTime? WatermarkUtc);

/// <param name="Sources">Sifre virov, ki dejansko obstajajo v registru konektorjev.</param>
/// <param name="Pipelines">Imena postopkov, ki so dejansko tekla.</param>
public sealed record InboundFilterOptions(IReadOnlyList<string> Sources, IReadOnlyList<string> Pipelines);

public sealed record InboundIssueRow(
  string IssueKind, long IssueId, int? OrganizationId, string OrganizationName, string SourceCode,
  string Severity, string Title, string Detail, long OccurrenceCount, DateTime FirstSeenUtc,
  DateTime LastSeenUtc, Guid? RunId);

public sealed record InboundIssueDetail(
  string IssueKind, long IssueId, string OrganizationName, string SourceCode, string? EntityType,
  string Status, string? ErrorCode, string Summary, DateTime FirstSeenUtc, DateTime LastSeenUtc,
  Guid? RunId, string? TechnicalDetail, string? PayloadPreview);

/// <summary>
/// Bralni model zajema in vrzeli preslikave. Vse, kar tu vidis, je posledica tega, kaj je
/// prislo v <c>raw.Inbox</c> in kaj je preslikava znala razumeti — nic ni izpeljano iz domnev.
/// </summary>
public sealed class PipelineReadService(PimDb database)
{
  /// <summary>
  /// Enotna operativna slika vseh registriranih vhodov. Zalogovni tokovi so v stock.* in jih
  /// zato ne smemo iskati v raw.Inbox; rezultat namenoma zdruzi oba dejanska sledilna modela.
  /// </summary>
  public Task<IReadOnlyList<InboundFlowRow>> GetInboundFlowsAsync(int? organizationId, CancellationToken cancellationToken = default) =>
    database.QueryAsync("""
      SELECT organization.OrganizationId, organization.Name AS OrganizationName,
             connector.SourceConnectorId, connector.SourceCode, connector.ConnectorType, connector.IsActive, connector.CanCreateProducts,
             CASE
               WHEN connector.SourceCode LIKE N'%[_]STOCK' OR lastStock.SyncRunId IS NOT NULL THEN N'STOCK'
               WHEN connector.SourceCode LIKE N'%XLSX%' OR connector.ConnectorType LIKE N'%XLS%' THEN N'WORKBOOK'
               WHEN connector.ConnectorType LIKE N'%XML%' THEN N'XML'
               WHEN connector.ConnectorType LIKE N'%SAOP%' THEN N'SAOP'
               ELSE connector.ConnectorType
             END AS FlowKind,
             CASE
               WHEN connector.SourceCode LIKE N'%[_]STOCK' OR lastStock.SyncRunId IS NOT NULL THEN
                 CASE lastStock.Status WHEN N'Completed' THEN N'Healthy' WHEN N'Running' THEN N'Running'
                   WHEN N'Failed' THEN N'Failed' WHEN NULL THEN N'NeverRun' ELSE lastStock.Status END
               ELSE COALESCE(health.Status,
                 CASE lastPipeline.Status WHEN N'Succeeded' THEN N'Healthy' WHEN N'Failed' THEN N'Failed'
                   WHEN N'Running' THEN N'Running' WHEN NULL THEN N'NeverRun' ELSE lastPipeline.Status END)
             END AS Status,
             CASE WHEN connector.SourceCode LIKE N'%[_]STOCK' OR lastStock.SyncRunId IS NOT NULL
               THEN lastStock.SyncRunId ELSE lastPipeline.RunId END AS LastRunId,
             CASE WHEN connector.SourceCode LIKE N'%[_]STOCK' OR lastStock.SyncRunId IS NOT NULL
               THEN lastStock.StartedUtc ELSE lastPipeline.StartedUtc END AS LastAttemptUtc,
             CASE WHEN connector.SourceCode LIKE N'%[_]STOCK' OR lastStock.SyncRunId IS NOT NULL
               THEN lastCompletedStock.CompletedUtc ELSE lastSuccessfulPipeline.EndedUtc END AS LastSuccessUtc,
             CASE WHEN connector.SourceCode LIKE N'%[_]STOCK' OR lastStock.SyncRunId IS NOT NULL
               THEN NULL ELSE lastFailedPipeline.EndedUtc END AS LastFailureUtc,
             schedule.NextScheduledUtc, schedule.IsEnabled AS ScheduleEnabled,
             CASE WHEN connector.SourceCode LIKE N'%[_]STOCK' OR lastStock.SyncRunId IS NOT NULL
               THEN COALESCE(stockDay.RecordsRead, 0) ELSE COALESCE(pipelineDay.RowsRead, 0) END AS ReceivedLast24Hours,
             CASE WHEN connector.SourceCode LIKE N'%[_]STOCK' OR lastStock.SyncRunId IS NOT NULL
               THEN COALESCE(stockCounts.PendingCount, 0) ELSE COALESCE(inboxCounts.PendingCount, 0) END AS PendingCount,
             CASE WHEN connector.SourceCode LIKE N'%[_]STOCK' OR lastStock.SyncRunId IS NOT NULL
               THEN COALESCE(stockCounts.RejectedCount, 0) ELSE COALESCE(inboxCounts.RejectedCount, 0) END AS RejectedCount,
             health.LastErrorRedacted AS LastError,
             CASE WHEN connector.SourceCode LIKE N'%[_]STOCK' OR lastStock.SyncRunId IS NOT NULL
               THEN lastStock.Endpoint ELSE NULL END AS Endpoint
      FROM map.SourceConnector connector
      INNER JOIN dbo.OrganizationConfig organization ON organization.OrganizationId = connector.OrganizationId
      OUTER APPLY
      (
        SELECT TOP (1) run.RunId, run.Pipeline, run.Status, run.StartedUtc, run.EndedUtc
        FROM ops.PipelineRun run
        WHERE run.OrganizationId = connector.OrganizationId AND run.SourceCode = connector.SourceCode
        ORDER BY run.StartedUtc DESC, run.RunId DESC
      ) lastPipeline
      OUTER APPLY
      (
        SELECT TOP (1) run.EndedUtc
        FROM ops.PipelineRun run
        WHERE run.OrganizationId = connector.OrganizationId AND run.SourceCode = connector.SourceCode
          AND run.Status = N'Succeeded'
        ORDER BY run.StartedUtc DESC
      ) lastSuccessfulPipeline
      OUTER APPLY
      (
        SELECT TOP (1) run.EndedUtc
        FROM ops.PipelineRun run
        WHERE run.OrganizationId = connector.OrganizationId AND run.SourceCode = connector.SourceCode
          AND run.Status = N'Failed'
        ORDER BY run.StartedUtc DESC
      ) lastFailedPipeline
      OUTER APPLY
      (
        SELECT TOP (1) run.SyncRunId, run.Status, run.Endpoint, run.StartedUtc, run.CompletedUtc
        FROM stock.SyncRun run
        WHERE run.OrganizationId = connector.OrganizationId AND run.SourceConnectorId = connector.SourceConnectorId
        ORDER BY run.StartedUtc DESC, run.SyncRunId DESC
      ) lastStock
      OUTER APPLY
      (
        SELECT TOP (1) run.CompletedUtc
        FROM stock.SyncRun run
        WHERE run.OrganizationId = connector.OrganizationId AND run.SourceConnectorId = connector.SourceConnectorId
          AND run.Status = N'Completed'
        ORDER BY run.StartedUtc DESC
      ) lastCompletedStock
      OUTER APPLY
      (
        SELECT TOP (1) value.Status, value.LastErrorRedacted, value.Pipeline
        FROM ops.IntegrationHealth value
        WHERE value.OrganizationId = connector.OrganizationId
          AND lastPipeline.Pipeline IS NOT NULL AND value.Pipeline = lastPipeline.Pipeline
        ORDER BY value.UpdatedUtc DESC
      ) health
      OUTER APPLY
      (
        SELECT TOP (1) value.NextScheduledUtc, value.IsEnabled
        FROM ops.ScheduleProfile value
        WHERE value.OrganizationId = connector.OrganizationId
          AND lastPipeline.Pipeline IS NOT NULL AND value.Pipeline = lastPipeline.Pipeline
        ORDER BY value.UpdatedUtc DESC
      ) schedule
      OUTER APPLY
      (
        SELECT SUM(run.RowsRead) AS RowsRead
        FROM ops.PipelineRun run
        WHERE run.OrganizationId = connector.OrganizationId AND run.SourceCode = connector.SourceCode
          AND run.StartedUtc >= DATEADD(hour, -24, SYSUTCDATETIME())
      ) pipelineDay
      OUTER APPLY
      (
        SELECT SUM(CONVERT(bigint, run.RecordsRead)) AS RecordsRead
        FROM stock.SyncRun run
        WHERE run.OrganizationId = connector.OrganizationId AND run.SourceConnectorId = connector.SourceConnectorId
          AND run.StartedUtc >= DATEADD(hour, -24, SYSUTCDATETIME())
      ) stockDay
      OUTER APPLY
      (
        SELECT SUM(CASE WHEN inbox.Status = N'Pending' THEN CONVERT(bigint, 1) ELSE 0 END) AS PendingCount,
               SUM(CASE WHEN inbox.Status = N'Quarantined' THEN CONVERT(bigint, 1) ELSE 0 END) AS RejectedCount
        FROM raw.Inbox inbox
        WHERE inbox.OrganizationId = connector.OrganizationId AND inbox.SourceCode = connector.SourceCode
      ) inboxCounts
      OUTER APPLY
      (
        SELECT SUM(CASE WHEN landing.Status = N'Pending' THEN CONVERT(bigint, 1) ELSE 0 END) AS PendingCount,
               SUM(CASE WHEN landing.Status = N'Quarantined' THEN CONVERT(bigint, 1) ELSE 0 END) AS RejectedCount
        FROM stock.LandingRecord landing
        WHERE landing.OrganizationId = connector.OrganizationId AND landing.SourceConnectorId = connector.SourceConnectorId
          /* 2026-09-17: samo odprta stanja - vsota CASE je ista, poizvedba pa gre po filtriranem
             indeksu IX_StockLandingRecord_Open (migracija 218) namesto cez milijone "Applied"
             vrstic na konektor (izmerjeno 25-39 s za celo stran /zajem, ki je padla na 30 s meji). */
          AND landing.Status IN (N'Pending', N'Quarantined')
      ) stockCounts
      WHERE organization.IsActive = 1
        AND (@OrganizationId IS NULL OR connector.OrganizationId = @OrganizationId)
      ORDER BY organization.OrganizationId,
        CASE WHEN connector.SourceCode LIKE N'SAOP%' THEN 0 WHEN connector.SourceCode LIKE N'%XML%' THEN 1
          WHEN connector.SourceCode LIKE N'%STOCK%' THEN 2 ELSE 3 END,
        connector.SourceCode;
      """,
      reader => new InboundFlowRow(
        PimDb.Int32(reader, "OrganizationId"), PimDb.TextOrEmpty(reader, "OrganizationName"),
        PimDb.Int32(reader, "SourceConnectorId"), PimDb.TextOrEmpty(reader, "SourceCode"),
        PimDb.TextOrEmpty(reader, "ConnectorType"), PimDb.TextOrEmpty(reader, "FlowKind"),
        PimDb.Bool(reader, "IsActive"), PimDb.Bool(reader, "CanCreateProducts"), PimDb.TextOrEmpty(reader, "Status"),
        reader.IsDBNull(reader.GetOrdinal("LastRunId")) ? null : reader.GetGuid(reader.GetOrdinal("LastRunId")),
        PimDb.NullableDateTime(reader, "LastAttemptUtc"), PimDb.NullableDateTime(reader, "LastSuccessUtc"),
        PimDb.NullableDateTime(reader, "LastFailureUtc"), PimDb.NullableDateTime(reader, "NextScheduledUtc"),
        reader.IsDBNull(reader.GetOrdinal("ScheduleEnabled")) ? null : reader.GetBoolean(reader.GetOrdinal("ScheduleEnabled")),
        PimDb.Int64(reader, "ReceivedLast24Hours"), PimDb.Int64(reader, "PendingCount"),
        PimDb.Int64(reader, "RejectedCount"), PimDb.Text(reader, "LastError"), PimDb.Text(reader, "Endpoint")),
      command => command.Parameters.AddWithValue("@OrganizationId", organizationId is null ? DBNull.Value : organizationId.Value),
      cancellationToken);

  public async Task<InboundOverviewSummary> GetInboundOverviewSummaryAsync(int? organizationId, CancellationToken cancellationToken = default)
  {
    var rows = await database.QueryAsync("""
      DECLARE @MissingCategories bigint;
      IF OBJECT_ID(N'map.SourceCategoryToMap', N'V') IS NOT NULL
        SELECT @MissingCategories = COUNT_BIG(*) FROM map.SourceCategoryToMap category
        WHERE @OrganizationId IS NULL OR EXISTS
        (
          SELECT 1 FROM map.SourceConnector connector
          WHERE connector.OrganizationId = @OrganizationId AND connector.SourceCode = category.SourceCode
        );
      ELSE
        SELECT @MissingCategories = COUNT_BIG(*) FROM map.MissingCategoryMap category
        WHERE @OrganizationId IS NULL OR EXISTS
        (
          SELECT 1 FROM map.SourceConnector connector
          WHERE connector.OrganizationId = @OrganizationId AND connector.SourceCode = category.SourceCode
        );

      SELECT
        (SELECT COUNT_BIG(*) FROM raw.Inbox inbox
         WHERE (@OrganizationId IS NULL OR inbox.OrganizationId = @OrganizationId) AND inbox.Status = N'Pending') AS PendingPages,
        (SELECT MIN(inbox.ReceivedUtc) FROM raw.Inbox inbox
         WHERE (@OrganizationId IS NULL OR inbox.OrganizationId = @OrganizationId) AND inbox.Status = N'Pending') AS OldestPendingUtc,
        (SELECT COUNT_BIG(*) FROM raw.Inbox inbox
         WHERE (@OrganizationId IS NULL OR inbox.OrganizationId = @OrganizationId) AND inbox.Status = N'Quarantined') AS QuarantinedPages,
        (SELECT COUNT_BIG(*) FROM map.UnmappedValue unmapped
         INNER JOIN map.ExtractedValue extracted ON extracted.ExtractedValueId = unmapped.ExtractedValueId
         INNER JOIN raw.Inbox inbox ON inbox.InboxId = extracted.InboxId
         WHERE @OrganizationId IS NULL OR inbox.OrganizationId = @OrganizationId) AS UnmappedValues,
        ((SELECT COUNT_BIG(*) FROM map.MissingTranslationOpen) + COALESCE(@MissingCategories, 0)) AS MappingWorkCount,
        (SELECT COUNT_BIG(*) FROM stock.UnmatchedPosition unmatched
         INNER JOIN stock.LandingRecord landing ON landing.LandingRecordId = unmatched.LandingRecordId
         WHERE @OrganizationId IS NULL OR landing.OrganizationId = @OrganizationId) AS StockUnmatchedCount,
        ((SELECT COUNT_BIG(*) FROM ops.DeadLetterQueue dead
          WHERE dead.Status <> N'Resolved' AND (@OrganizationId IS NULL OR dead.OrganizationId = @OrganizationId)
            AND EXISTS
            (
              SELECT 1 FROM map.SourceConnector connector
              WHERE connector.OrganizationId = dead.OrganizationId AND connector.SourceCode = dead.SourceCode
            ))
         +
         (SELECT COUNT_BIG(*) FROM ops.ErrorLog errorValue
          INNER JOIN ops.PipelineRun run ON run.RunId = errorValue.RunId
          WHERE errorValue.Severity IN (N'Error', N'Critical')
            AND errorValue.OccurredUtc >= DATEADD(day, -7, SYSUTCDATETIME())
            AND (@OrganizationId IS NULL OR run.OrganizationId = @OrganizationId))) AS OpenTechnicalProblems;
      """,
      reader => new InboundOverviewSummary(
        PimDb.Int64(reader, "PendingPages"), PimDb.NullableDateTime(reader, "OldestPendingUtc"),
        PimDb.Int64(reader, "QuarantinedPages"), PimDb.Int64(reader, "UnmappedValues"),
        PimDb.Int64(reader, "MappingWorkCount"), PimDb.Int64(reader, "StockUnmatchedCount"),
        PimDb.Int64(reader, "OpenTechnicalProblems")),
      command => command.Parameters.AddWithValue("@OrganizationId", organizationId is null ? DBNull.Value : organizationId.Value),
      cancellationToken);
    return rows.Count == 0 ? new(0, null, 0, 0, 0, 0, 0) : rows[0];
  }

  public Task<(IReadOnlyList<InboundRunRow> Rows, long TotalCount)> GetInboundRunsAsync(
    int? organizationId, string? status, string? search, int skip, int take, string? sourceCode = null,
    CancellationToken cancellationToken = default) => database.PageAsync("""
      CREATE TABLE #InboundRuns
      (
        RunKind nvarchar(20) NOT NULL, RunId uniqueidentifier NOT NULL, OrganizationId int NOT NULL,
        OrganizationName nvarchar(200) NOT NULL, Pipeline nvarchar(100) NOT NULL, SourceCode nvarchar(100) NOT NULL,
        Status nvarchar(30) NOT NULL, RowsRead bigint NOT NULL, RowsSucceeded bigint NOT NULL, RowsFailed bigint NOT NULL,
        StartedUtc datetime2(3) NOT NULL, EndedUtc datetime2(3) NULL, CorrelationId uniqueidentifier NULL
      );

      INSERT #InboundRuns
      SELECT N'PIPELINE', run.RunId, run.OrganizationId, organization.Name, run.Pipeline,
             COALESCE(run.SourceCode, run.Pipeline), run.Status, run.RowsRead, run.RowsSucceeded, run.RowsFailed,
             run.StartedUtc, run.EndedUtc, run.CorrelationId
      FROM ops.PipelineRun run
      INNER JOIN dbo.OrganizationConfig organization ON organization.OrganizationId = run.OrganizationId
      WHERE @OrganizationId IS NULL OR run.OrganizationId = @OrganizationId;

      INSERT #InboundRuns
      SELECT N'STOCK', run.SyncRunId, run.OrganizationId, organization.Name, N'STOCK', connector.SourceCode,
             run.Status, CONVERT(bigint, run.RecordsRead), CONVERT(bigint, run.RecordsApplied),
             CONVERT(bigint, run.RecordsQuarantined), run.StartedUtc, run.CompletedUtc, NULL
      FROM stock.SyncRun run
      INNER JOIN dbo.OrganizationConfig organization ON organization.OrganizationId = run.OrganizationId
      INNER JOIN map.SourceConnector connector ON connector.SourceConnectorId = run.SourceConnectorId
      WHERE @OrganizationId IS NULL OR run.OrganizationId = @OrganizationId;

      SELECT RunKind, RunId, OrganizationId, OrganizationName, Pipeline, SourceCode, Status,
             RowsRead, RowsSucceeded, RowsFailed, StartedUtc, EndedUtc, CorrelationId
      FROM #InboundRuns
      WHERE (@Status IS NULL OR Status = @Status)
        AND (@SourceCode IS NULL OR SourceCode = @SourceCode)
        AND (@Search IS NULL OR Pipeline LIKE N'%' + @Search + N'%' OR SourceCode LIKE N'%' + @Search + N'%'
             OR OrganizationName LIKE N'%' + @Search + N'%')
      ORDER BY StartedUtc DESC, RunId DESC
      OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY;

      SELECT COUNT_BIG(*) FROM #InboundRuns
      WHERE (@Status IS NULL OR Status = @Status)
        AND (@SourceCode IS NULL OR SourceCode = @SourceCode)
        AND (@Search IS NULL OR Pipeline LIKE N'%' + @Search + N'%' OR SourceCode LIKE N'%' + @Search + N'%'
             OR OrganizationName LIKE N'%' + @Search + N'%');
      """,
      reader => new InboundRunRow(
        PimDb.TextOrEmpty(reader, "RunKind"), reader.GetGuid(reader.GetOrdinal("RunId")),
        PimDb.Int32(reader, "OrganizationId"), PimDb.TextOrEmpty(reader, "OrganizationName"),
        PimDb.TextOrEmpty(reader, "Pipeline"), PimDb.TextOrEmpty(reader, "SourceCode"),
        PimDb.TextOrEmpty(reader, "Status"), PimDb.Int64(reader, "RowsRead"),
        PimDb.Int64(reader, "RowsSucceeded"), PimDb.Int64(reader, "RowsFailed"),
        PimDb.DateTimeValue(reader, "StartedUtc"), PimDb.NullableDateTime(reader, "EndedUtc"),
        reader.IsDBNull(reader.GetOrdinal("CorrelationId")) ? null : reader.GetGuid(reader.GetOrdinal("CorrelationId"))),
      command =>
      {
        command.Parameters.AddWithValue("@OrganizationId", organizationId is null ? DBNull.Value : organizationId.Value);
        command.Parameters.AddWithValue("@Status", string.IsNullOrWhiteSpace(status) ? DBNull.Value : status);
        command.Parameters.AddWithValue("@Search", string.IsNullOrWhiteSpace(search) ? DBNull.Value : search.Trim());
        command.Parameters.AddWithValue("@SourceCode", string.IsNullOrWhiteSpace(sourceCode) ? DBNull.Value : sourceCode);
        command.Parameters.AddWithValue("@Skip", skip);
        command.Parameters.AddWithValue("@Take", take);
      }, cancellationToken);

  public async Task<InboundRunView?> GetInboundRunAsync(
    Guid runId, int? organizationId, CancellationToken cancellationToken = default)
  {
    var headers = await database.QueryAsync("""
      SELECT TOP (1) value.RunKind, value.RunId, value.OrganizationId, value.OrganizationName,
             value.Pipeline, value.SourceCode, value.Status, value.Endpoint, value.RowsRead,
             value.RowsSucceeded, value.RowsFailed, value.StartedUtc, value.EndedUtc, value.CorrelationId
      FROM
      (
        SELECT N'PIPELINE' AS RunKind, run.RunId, run.OrganizationId, organization.Name AS OrganizationName,
               run.Pipeline, COALESCE(run.SourceCode, run.Pipeline) AS SourceCode, run.Status,
               CAST(NULL AS nvarchar(1000)) AS Endpoint, run.RowsRead, run.RowsSucceeded, run.RowsFailed,
               run.StartedUtc, run.EndedUtc, run.CorrelationId
        FROM ops.PipelineRun run
        INNER JOIN dbo.OrganizationConfig organization ON organization.OrganizationId = run.OrganizationId
        WHERE run.RunId = @RunId
          AND (@OrganizationId IS NULL OR run.OrganizationId = @OrganizationId)
        UNION ALL
        SELECT N'STOCK', run.SyncRunId, run.OrganizationId, organization.Name, N'STOCK', connector.SourceCode,
               run.Status, run.Endpoint, CONVERT(bigint, run.RecordsRead), CONVERT(bigint, run.RecordsApplied),
               CONVERT(bigint, run.RecordsQuarantined), run.StartedUtc, run.CompletedUtc, NULL
        FROM stock.SyncRun run
        INNER JOIN dbo.OrganizationConfig organization ON organization.OrganizationId = run.OrganizationId
        INNER JOIN map.SourceConnector connector ON connector.SourceConnectorId = run.SourceConnectorId
        WHERE run.SyncRunId = @RunId
          AND (@OrganizationId IS NULL OR run.OrganizationId = @OrganizationId)
      ) value;
      """,
      reader => new InboundRunHeader(
        PimDb.TextOrEmpty(reader, "RunKind"), reader.GetGuid(reader.GetOrdinal("RunId")),
        PimDb.Int32(reader, "OrganizationId"), PimDb.TextOrEmpty(reader, "OrganizationName"),
        PimDb.TextOrEmpty(reader, "Pipeline"), PimDb.TextOrEmpty(reader, "SourceCode"),
        PimDb.TextOrEmpty(reader, "Status"), PimDb.Text(reader, "Endpoint"),
        PimDb.Int64(reader, "RowsRead"), PimDb.Int64(reader, "RowsSucceeded"), PimDb.Int64(reader, "RowsFailed"),
        PimDb.DateTimeValue(reader, "StartedUtc"), PimDb.NullableDateTime(reader, "EndedUtc"),
        reader.IsDBNull(reader.GetOrdinal("CorrelationId")) ? null : reader.GetGuid(reader.GetOrdinal("CorrelationId"))),
      command =>
      {
        command.Parameters.AddWithValue("@RunId", runId);
        command.Parameters.AddWithValue("@OrganizationId", organizationId is null ? DBNull.Value : organizationId.Value);
      }, cancellationToken);
    if (headers.Count == 0) return null;

    var steps = await database.QueryAsync("""
      SELECT StepCode, Attempt, RowsIn, RowsMerged, DurationMs, Status, RecordedUtc
      FROM ops.PipelineStepLog WHERE RunId = @RunId ORDER BY RecordedUtc, PipelineStepLogId;
      """,
      reader => new InboundRunStepRow(
        PimDb.TextOrEmpty(reader, "StepCode"), PimDb.Int32(reader, "Attempt"), PimDb.Int64(reader, "RowsIn"),
        PimDb.Int64(reader, "RowsMerged"), PimDb.NullableInt64(reader, "DurationMs"),
        PimDb.TextOrEmpty(reader, "Status"), PimDb.DateTimeValue(reader, "RecordedUtc")),
      command => command.Parameters.AddWithValue("@RunId", runId), cancellationToken);

    var pages = await database.QueryAsync("""
      SELECT TOP (200) InboxId, EntityType, PageNumber, Status, ReceivedUtc, FailureReason
      FROM raw.Inbox WHERE RunId = @RunId ORDER BY PageNumber, InboxId;
      """,
      reader => new InboundRunPageRow(
        PimDb.Int64(reader, "InboxId"), PimDb.TextOrEmpty(reader, "EntityType"), PimDb.Int32(reader, "PageNumber"),
        PimDb.TextOrEmpty(reader, "Status"), PimDb.DateTimeValue(reader, "ReceivedUtc"), PimDb.Text(reader, "FailureReason")),
      command => command.Parameters.AddWithValue("@RunId", runId), cancellationToken);

    var errors = await database.QueryAsync("""
      SELECT TOP (100) ErrorLogId, OccurredUtc, Severity, ErrorCode, Message
      FROM ops.ErrorLog WHERE RunId = @RunId ORDER BY OccurredUtc DESC, ErrorLogId DESC;
      """,
      reader => new InboundRunErrorRow(
        PimDb.Int64(reader, "ErrorLogId"), PimDb.DateTimeValue(reader, "OccurredUtc"),
        PimDb.TextOrEmpty(reader, "Severity"), PimDb.TextOrEmpty(reader, "ErrorCode"), PimDb.TextOrEmpty(reader, "Message")),
      command => command.Parameters.AddWithValue("@RunId", runId), cancellationToken);

    var stockIssues = await database.QueryAsync("""
      SELECT TOP (200) unmatched.UnmatchedPositionId, unmatched.ReasonCode, unmatched.Detail,
             landing.NormalizedItemId, landing.Ean, unmatched.CreatedUtc
      FROM stock.UnmatchedPosition unmatched
      INNER JOIN stock.LandingRecord landing ON landing.LandingRecordId = unmatched.LandingRecordId
      WHERE landing.SyncRunId = @RunId ORDER BY unmatched.CreatedUtc DESC, unmatched.UnmatchedPositionId DESC;
      """,
      reader => new InboundStockIssueRow(
        PimDb.Int64(reader, "UnmatchedPositionId"), PimDb.TextOrEmpty(reader, "ReasonCode"),
        PimDb.TextOrEmpty(reader, "Detail"), PimDb.Text(reader, "NormalizedItemId"), PimDb.Text(reader, "Ean"),
        PimDb.DateTimeValue(reader, "CreatedUtc")),
      command => command.Parameters.AddWithValue("@RunId", runId), cancellationToken);

    return new(headers[0], steps, pages, errors, stockIssues);
  }

  public Task<IReadOnlyList<SourceEntityRow>> GetSourceEntitiesAsync(
    int organizationId, string sourceCode, CancellationToken cancellationToken = default) => database.QueryAsync("""
      DECLARE @ConnectorId int =
      (
        SELECT SourceConnectorId FROM map.SourceConnector
        WHERE OrganizationId = @OrganizationId AND SourceCode = @SourceCode
      );
      WITH entities AS
      (
        SELECT EntityType FROM map.FieldMapping WHERE SourceConnectorId = @ConnectorId
        UNION SELECT EntityType FROM map.Watermark WHERE SourceConnectorId = @ConnectorId
        UNION SELECT EntityType FROM raw.Inbox WHERE OrganizationId = @OrganizationId AND SourceCode = @SourceCode
        UNION SELECT N'Stock' WHERE EXISTS
        (
          SELECT 1 FROM map.SourceConnector connector
          WHERE connector.SourceConnectorId = @ConnectorId AND connector.SourceCode LIKE N'%[_]STOCK'
        )
      )
      SELECT entityValue.EntityType,
             CONVERT(bit, CASE WHEN entityValue.EntityType = N'Stock' THEN
               CASE WHEN EXISTS (SELECT 1 FROM map.StockIdentityRule ruleValue WHERE ruleValue.SourceConnectorId = @ConnectorId AND ruleValue.IsActive = 1) THEN 1 ELSE 0 END
               ELSE CASE WHEN EXISTS (SELECT 1 FROM map.FieldMapping fieldValue WHERE fieldValue.SourceConnectorId = @ConnectorId AND fieldValue.EntityType = entityValue.EntityType AND fieldValue.IsActive = 1) THEN 1 ELSE 0 END END) AS HasActiveMapping,
             CASE WHEN entityValue.EntityType = N'Stock' THEN
               (SELECT COUNT_BIG(*) FROM map.StockIdentityRule ruleValue WHERE ruleValue.SourceConnectorId = @ConnectorId AND ruleValue.IsActive = 1)
               ELSE (SELECT COUNT_BIG(*) FROM map.FieldMapping fieldValue WHERE fieldValue.SourceConnectorId = @ConnectorId AND fieldValue.EntityType = entityValue.EntityType AND fieldValue.IsActive = 1) END AS FieldCount,
             CASE WHEN entityValue.EntityType = N'Stock' THEN 0 ELSE
               (SELECT COUNT_BIG(*) FROM map.FieldMapping fieldValue WHERE fieldValue.SourceConnectorId = @ConnectorId AND fieldValue.EntityType = entityValue.EntityType AND fieldValue.IsActive = 1 AND fieldValue.IsRequired = 1) END AS RequiredFieldCount,
             CASE WHEN entityValue.EntityType = N'Stock' THEN
               (SELECT COUNT_BIG(*) FROM stock.LandingRecord landing WHERE landing.OrganizationId = @OrganizationId AND landing.SourceConnectorId = @ConnectorId AND landing.Status = N'Pending')
               ELSE (SELECT COUNT_BIG(*) FROM raw.Inbox inbox WHERE inbox.OrganizationId = @OrganizationId AND inbox.SourceCode = @SourceCode AND inbox.EntityType = entityValue.EntityType AND inbox.Status = N'Pending') END AS PendingCount,
             CASE WHEN entityValue.EntityType = N'Stock' THEN
               (SELECT COUNT_BIG(*) FROM stock.LandingRecord landing WHERE landing.OrganizationId = @OrganizationId AND landing.SourceConnectorId = @ConnectorId AND landing.Status = N'Applied')
               ELSE (SELECT COUNT_BIG(*) FROM raw.Inbox inbox WHERE inbox.OrganizationId = @OrganizationId AND inbox.SourceCode = @SourceCode AND inbox.EntityType = entityValue.EntityType AND inbox.Status = N'Processed') END AS ProcessedCount,
             CASE WHEN entityValue.EntityType = N'Stock' THEN
               (SELECT COUNT_BIG(*) FROM stock.LandingRecord landing WHERE landing.OrganizationId = @OrganizationId AND landing.SourceConnectorId = @ConnectorId AND landing.Status = N'Quarantined')
               ELSE (SELECT COUNT_BIG(*) FROM raw.Inbox inbox WHERE inbox.OrganizationId = @OrganizationId AND inbox.SourceCode = @SourceCode AND inbox.EntityType = entityValue.EntityType AND inbox.Status = N'Quarantined') END AS QuarantinedCount,
             CASE WHEN entityValue.EntityType = N'Stock' THEN
               (SELECT MAX(run.StartedUtc) FROM stock.SyncRun run WHERE run.OrganizationId = @OrganizationId AND run.SourceConnectorId = @ConnectorId)
               ELSE (SELECT MAX(inbox.ReceivedUtc) FROM raw.Inbox inbox WHERE inbox.OrganizationId = @OrganizationId AND inbox.SourceCode = @SourceCode AND inbox.EntityType = entityValue.EntityType) END AS LastReceivedUtc,
             (SELECT MAX(watermark.UpdatedUtc) FROM map.Watermark watermark WHERE watermark.SourceConnectorId = @ConnectorId AND watermark.EntityType = entityValue.EntityType) AS WatermarkUtc
      FROM entities entityValue ORDER BY entityValue.EntityType;
      """,
      reader => new SourceEntityRow(
        PimDb.TextOrEmpty(reader, "EntityType"), PimDb.Bool(reader, "HasActiveMapping"),
        PimDb.Int64(reader, "FieldCount"), PimDb.Int64(reader, "RequiredFieldCount"),
        PimDb.Int64(reader, "PendingCount"), PimDb.Int64(reader, "ProcessedCount"),
        PimDb.Int64(reader, "QuarantinedCount"), PimDb.NullableDateTime(reader, "LastReceivedUtc"),
        PimDb.NullableDateTime(reader, "WatermarkUtc")),
      command =>
      {
        command.Parameters.AddWithValue("@OrganizationId", organizationId);
        command.Parameters.AddWithValue("@SourceCode", sourceCode);
      }, cancellationToken);

  public Task<(IReadOnlyList<InboundIssueRow> Rows, long TotalCount)> GetInboundIssuesAsync(
    int? organizationId, string? issueKind, string? search, int skip, int take, string? sourceCode = null,
    CancellationToken cancellationToken = default) => database.PageAsync("""
      CREATE TABLE #InboundIssues
      (
        IssueKind nvarchar(30) NOT NULL, IssueId bigint NOT NULL, OrganizationId int NULL,
        OrganizationName nvarchar(200) NOT NULL, SourceCode nvarchar(100) NOT NULL,
        Severity nvarchar(20) NOT NULL, Title nvarchar(300) NOT NULL, Detail nvarchar(2000) NOT NULL,
        OccurrenceCount bigint NOT NULL, FirstSeenUtc datetime2(3) NOT NULL, LastSeenUtc datetime2(3) NOT NULL,
        RunId uniqueidentifier NULL
      );

      INSERT #InboundIssues
      SELECT N'INBOX', MIN(inbox.InboxId), inbox.OrganizationId, organization.Name, inbox.SourceCode,
             CASE inbox.Status WHEN N'Quarantined' THEN N'Error' ELSE N'Warning' END,
             CASE inbox.Status WHEN N'Quarantined' THEN N'Izločene vhodne strani' ELSE N'Čakajoče vhodne strani' END,
             COALESCE(NULLIF(inbox.FailureReason, N''),
               CASE inbox.Status WHEN N'Pending' THEN N'Podatek je zajet, vendar še ni obdelan ali nima preslikave.' ELSE N'Razlog ni podan.' END),
             COUNT_BIG(*), MIN(inbox.ReceivedUtc), MAX(inbox.ReceivedUtc), NULL
      FROM raw.Inbox inbox
      INNER JOIN dbo.OrganizationConfig organization ON organization.OrganizationId = inbox.OrganizationId
      WHERE inbox.Status IN (N'Pending', N'Quarantined')
        AND (@OrganizationId IS NULL OR inbox.OrganizationId = @OrganizationId)
      GROUP BY inbox.OrganizationId, organization.Name, inbox.SourceCode, inbox.Status, inbox.FailureReason;

      INSERT #InboundIssues
      SELECT N'STOCK', MIN(unmatched.UnmatchedPositionId), landing.OrganizationId, organization.Name, connector.SourceCode,
             N'Error', N'Zavrnjene pozicije zaloge', LEFT(unmatched.ReasonCode + N': ' + unmatched.Detail, 2000),
             COUNT_BIG(*), MIN(unmatched.CreatedUtc), MAX(unmatched.CreatedUtc), NULL
      FROM stock.UnmatchedPosition unmatched
      INNER JOIN stock.LandingRecord landing ON landing.LandingRecordId = unmatched.LandingRecordId
      INNER JOIN map.SourceConnector connector ON connector.SourceConnectorId = landing.SourceConnectorId
      INNER JOIN dbo.OrganizationConfig organization ON organization.OrganizationId = landing.OrganizationId
      WHERE @OrganizationId IS NULL OR landing.OrganizationId = @OrganizationId
      GROUP BY landing.OrganizationId, organization.Name, connector.SourceCode, unmatched.ReasonCode, unmatched.Detail;

      INSERT #InboundIssues
      SELECT N'DEADLETTER', MIN(dead.DeadLetterId), dead.OrganizationId,
             COALESCE(organization.Name, N'Vsa podjetja'), COALESCE(dead.SourceCode, dead.Layer),
             CASE dead.Status WHEN N'Dead' THEN N'Critical' ELSE N'Error' END,
             N'Mrtvo pismo: ' + dead.Layer, dead.FailureReason, COUNT_BIG(*),
             MIN(dead.FirstFailedUtc), MAX(dead.LastFailedUtc), NULL
      FROM ops.DeadLetterQueue dead
      LEFT JOIN dbo.OrganizationConfig organization ON organization.OrganizationId = dead.OrganizationId
      WHERE dead.Status <> N'Resolved' AND (@OrganizationId IS NULL OR dead.OrganizationId = @OrganizationId)
        AND EXISTS
        (
          SELECT 1 FROM map.SourceConnector sourceConnector
          WHERE sourceConnector.OrganizationId = dead.OrganizationId AND sourceConnector.SourceCode = dead.SourceCode
        )
      GROUP BY dead.OrganizationId, organization.Name, dead.SourceCode, dead.Layer, dead.Status, dead.FailureReason;

      INSERT #InboundIssues
      SELECT N'ERROR', errorValue.ErrorLogId, run.OrganizationId,
             COALESCE(organization.Name, N'Vsa podjetja'), COALESCE(run.SourceCode, errorValue.Layer),
             errorValue.Severity, COALESCE(NULLIF(errorValue.ErrorCode, N''), N'Sistemska napaka'),
             LEFT(errorValue.Message, 2000), 1, errorValue.OccurredUtc, errorValue.OccurredUtc, errorValue.RunId
      FROM ops.ErrorLog errorValue
      INNER JOIN ops.PipelineRun run ON run.RunId = errorValue.RunId
      INNER JOIN dbo.OrganizationConfig organization ON organization.OrganizationId = run.OrganizationId
      WHERE errorValue.Severity IN (N'Warning', N'Error', N'Critical')
        AND (@OrganizationId IS NULL OR run.OrganizationId = @OrganizationId);

      SELECT IssueKind, IssueId, OrganizationId, OrganizationName, SourceCode, Severity, Title, Detail,
             OccurrenceCount, FirstSeenUtc, LastSeenUtc, RunId
      FROM #InboundIssues
      WHERE (@IssueKind IS NULL OR IssueKind = @IssueKind)
        AND (@SourceCode IS NULL OR SourceCode = @SourceCode)
        AND (@Search IS NULL OR SourceCode LIKE N'%' + @Search + N'%' OR Title LIKE N'%' + @Search + N'%'
          OR Detail LIKE N'%' + @Search + N'%' OR OrganizationName LIKE N'%' + @Search + N'%')
      ORDER BY CASE Severity WHEN N'Critical' THEN 0 WHEN N'Error' THEN 1 WHEN N'Warning' THEN 2 ELSE 3 END,
               LastSeenUtc DESC, IssueId DESC
      OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY;

      SELECT COUNT_BIG(*) FROM #InboundIssues
      WHERE (@IssueKind IS NULL OR IssueKind = @IssueKind)
        AND (@SourceCode IS NULL OR SourceCode = @SourceCode)
        AND (@Search IS NULL OR SourceCode LIKE N'%' + @Search + N'%' OR Title LIKE N'%' + @Search + N'%'
          OR Detail LIKE N'%' + @Search + N'%' OR OrganizationName LIKE N'%' + @Search + N'%');
      """,
      reader => new InboundIssueRow(
        PimDb.TextOrEmpty(reader, "IssueKind"), PimDb.Int64(reader, "IssueId"),
        reader.IsDBNull(reader.GetOrdinal("OrganizationId")) ? null : PimDb.Int32(reader, "OrganizationId"),
        PimDb.TextOrEmpty(reader, "OrganizationName"), PimDb.TextOrEmpty(reader, "SourceCode"),
        PimDb.TextOrEmpty(reader, "Severity"), PimDb.TextOrEmpty(reader, "Title"),
        PimDb.TextOrEmpty(reader, "Detail"), PimDb.Int64(reader, "OccurrenceCount"),
        PimDb.DateTimeValue(reader, "FirstSeenUtc"), PimDb.DateTimeValue(reader, "LastSeenUtc"),
        reader.IsDBNull(reader.GetOrdinal("RunId")) ? null : reader.GetGuid(reader.GetOrdinal("RunId"))),
      command =>
      {
        command.Parameters.AddWithValue("@OrganizationId", organizationId is null ? DBNull.Value : organizationId.Value);
        command.Parameters.AddWithValue("@IssueKind", string.IsNullOrWhiteSpace(issueKind) ? DBNull.Value : issueKind);
        command.Parameters.AddWithValue("@SourceCode", string.IsNullOrWhiteSpace(sourceCode) ? DBNull.Value : sourceCode);
        command.Parameters.AddWithValue("@Search", string.IsNullOrWhiteSpace(search) ? DBNull.Value : search.Trim());
        command.Parameters.AddWithValue("@Skip", skip);
        command.Parameters.AddWithValue("@Take", take);
      }, cancellationToken);

  public async Task<InboundIssueDetail?> GetInboundIssueDetailAsync(
    string issueKind, long issueId, int? organizationId, bool includePayload,
    CancellationToken cancellationToken = default)
  {
    var normalized = issueKind.ToUpperInvariant();
    var sql = normalized switch
    {
      "INBOX" => """
        SELECT N'INBOX' AS IssueKind, inbox.InboxId AS IssueId, organization.Name AS OrganizationName,
               inbox.SourceCode, inbox.EntityType, inbox.Status, CAST(NULL AS nvarchar(100)) AS ErrorCode,
               COALESCE(NULLIF(inbox.FailureReason, N''), N'Vhodna stran čaka na obdelavo.') AS Summary,
               inbox.ReceivedUtc AS FirstSeenUtc, COALESCE(inbox.ProcessedUtc, inbox.ReceivedUtc) AS LastSeenUtc,
               inbox.RunId, CAST(NULL AS nvarchar(max)) AS TechnicalDetail,
               CASE WHEN @IncludePayload = 1 THEN LEFT(inbox.PayloadXml, 20000) ELSE NULL END AS PayloadPreview
        FROM raw.Inbox inbox
        INNER JOIN dbo.OrganizationConfig organization ON organization.OrganizationId = inbox.OrganizationId
        WHERE inbox.InboxId = @IssueId
          AND (@OrganizationId IS NULL OR inbox.OrganizationId = @OrganizationId);
        """,
      "STOCK" => """
        SELECT N'STOCK' AS IssueKind, unmatched.UnmatchedPositionId AS IssueId,
               organization.Name AS OrganizationName, connector.SourceCode, N'Stock' AS EntityType,
               landing.Status, unmatched.ReasonCode AS ErrorCode, unmatched.Detail AS Summary,
               unmatched.CreatedUtc AS FirstSeenUtc, unmatched.CreatedUtc AS LastSeenUtc, landing.SyncRunId AS RunId,
               CONCAT(N'Endpoint: ', landing.Endpoint, N'; zapis: ', landing.SourceRecordKey) AS TechnicalDetail,
               CASE WHEN @IncludePayload = 1 THEN LEFT(landing.RawPayload, 20000) ELSE NULL END AS PayloadPreview
        FROM stock.UnmatchedPosition unmatched
        INNER JOIN stock.LandingRecord landing ON landing.LandingRecordId = unmatched.LandingRecordId
        INNER JOIN map.SourceConnector connector ON connector.SourceConnectorId = landing.SourceConnectorId
        INNER JOIN dbo.OrganizationConfig organization ON organization.OrganizationId = landing.OrganizationId
        WHERE unmatched.UnmatchedPositionId = @IssueId
          AND (@OrganizationId IS NULL OR landing.OrganizationId = @OrganizationId);
        """,
      "DEADLETTER" => """
        SELECT N'DEADLETTER' AS IssueKind, dead.DeadLetterId AS IssueId,
               COALESCE(organization.Name, N'Vsa podjetja') AS OrganizationName,
               COALESCE(dead.SourceCode, dead.Layer) AS SourceCode, dead.EntityType, dead.Status,
               dead.Layer AS ErrorCode, dead.FailureReason AS Summary, dead.FirstFailedUtc AS FirstSeenUtc,
               dead.LastFailedUtc AS LastSeenUtc, CAST(NULL AS uniqueidentifier) AS RunId,
               CONCAT(N'Naravni ključ: ', COALESCE(dead.NaturalKey, N'—'), N'; ponovitev: ', dead.RetryCount) AS TechnicalDetail,
               CASE WHEN @IncludePayload = 1 THEN LEFT(dead.PayloadJson, 20000) ELSE NULL END AS PayloadPreview
        FROM ops.DeadLetterQueue dead
        LEFT JOIN dbo.OrganizationConfig organization ON organization.OrganizationId = dead.OrganizationId
        WHERE dead.DeadLetterId = @IssueId
          AND (@OrganizationId IS NULL OR dead.OrganizationId = @OrganizationId)
          AND EXISTS
          (
            SELECT 1 FROM map.SourceConnector connector
            WHERE connector.OrganizationId = dead.OrganizationId AND connector.SourceCode = dead.SourceCode
          );
        """,
      "ERROR" => """
        SELECT N'ERROR' AS IssueKind, errorValue.ErrorLogId AS IssueId,
               COALESCE(organization.Name, N'Vsa podjetja') AS OrganizationName,
               COALESCE(run.SourceCode, errorValue.Layer) AS SourceCode, errorValue.Layer AS EntityType,
               errorValue.Severity AS Status, errorValue.ErrorCode, errorValue.Message AS Summary,
               errorValue.OccurredUtc AS FirstSeenUtc, errorValue.OccurredUtc AS LastSeenUtc, errorValue.RunId,
               CASE WHEN @IncludePayload = 1 THEN LEFT(errorValue.Detail, 20000) ELSE NULL END AS TechnicalDetail,
               CAST(NULL AS nvarchar(max)) AS PayloadPreview
        FROM ops.ErrorLog errorValue
        INNER JOIN ops.PipelineRun run ON run.RunId = errorValue.RunId
        INNER JOIN dbo.OrganizationConfig organization ON organization.OrganizationId = run.OrganizationId
        WHERE errorValue.ErrorLogId = @IssueId
          AND (@OrganizationId IS NULL OR run.OrganizationId = @OrganizationId);
        """,
      _ => null,
    };
    if (sql is null) return null;

    var rows = await database.QueryAsync(sql,
      reader => new InboundIssueDetail(
        PimDb.TextOrEmpty(reader, "IssueKind"), PimDb.Int64(reader, "IssueId"),
        PimDb.TextOrEmpty(reader, "OrganizationName"), PimDb.TextOrEmpty(reader, "SourceCode"),
        PimDb.Text(reader, "EntityType"), PimDb.TextOrEmpty(reader, "Status"), PimDb.Text(reader, "ErrorCode"),
        PimDb.TextOrEmpty(reader, "Summary"), PimDb.DateTimeValue(reader, "FirstSeenUtc"),
        PimDb.DateTimeValue(reader, "LastSeenUtc"),
        reader.IsDBNull(reader.GetOrdinal("RunId")) ? null : reader.GetGuid(reader.GetOrdinal("RunId")),
        PimDb.Text(reader, "TechnicalDetail"), PimDb.Text(reader, "PayloadPreview")),
      command =>
      {
        command.Parameters.AddWithValue("@IssueId", issueId);
        command.Parameters.AddWithValue("@OrganizationId", organizationId is null ? DBNull.Value : organizationId.Value);
        command.Parameters.AddWithValue("@IncludePayload", includePayload ? 1 : 0);
      }, cancellationToken);
    return rows.Count == 0 ? null : rows[0];
  }
  public Task<IReadOnlyList<SourceConnectorRow>> GetSourcesAsync(int organizationId, CancellationToken cancellationToken = default) =>
    database.QueryAsync("""
      SELECT connector.SourceConnectorId, connector.SourceCode, connector.OrganizationId, connector.ConnectorType,
             connector.IsActive, connector.CanCreateProducts,
             (SELECT COUNT_BIG(*) FROM map.EntityMapping entity
              WHERE entity.SourceConnectorId = connector.SourceConnectorId AND entity.IsActive = 1) AS EntityCount,
             (SELECT COUNT_BIG(*) FROM map.FieldMapping field
              WHERE field.SourceConnectorId = connector.SourceConnectorId AND field.IsActive = 1) AS FieldCount,
             (SELECT COUNT_BIG(*) FROM raw.Inbox inbox
              WHERE inbox.OrganizationId = connector.OrganizationId AND inbox.SourceCode = connector.SourceCode
                AND inbox.Status = N'Pending') AS PendingCount,
             (SELECT COUNT_BIG(*) FROM raw.Inbox inbox
              WHERE inbox.OrganizationId = connector.OrganizationId AND inbox.SourceCode = connector.SourceCode) AS TotalCount,
             (SELECT MAX(watermark.UpdatedUtc) FROM map.Watermark watermark
              WHERE watermark.SourceConnectorId = connector.SourceConnectorId) AS LastWatermarkUtc,
             (SELECT MAX(inbox.ReceivedUtc) FROM raw.Inbox inbox
              WHERE inbox.OrganizationId = connector.OrganizationId AND inbox.SourceCode = connector.SourceCode) AS LastReceivedUtc
      FROM map.SourceConnector connector
      WHERE connector.OrganizationId = @OrganizationId
      ORDER BY connector.IsActive DESC, connector.SourceCode;
      """,
      reader => new SourceConnectorRow(
        PimDb.Int32(reader, "SourceConnectorId"), PimDb.TextOrEmpty(reader, "SourceCode"), PimDb.Int32(reader, "OrganizationId"),
        PimDb.TextOrEmpty(reader, "ConnectorType"), PimDb.Bool(reader, "IsActive"), PimDb.Bool(reader, "CanCreateProducts"),
        PimDb.Int64(reader, "EntityCount"), PimDb.Int64(reader, "FieldCount"), PimDb.Int64(reader, "PendingCount"),
        PimDb.Int64(reader, "TotalCount"), PimDb.NullableDateTime(reader, "LastWatermarkUtc"), PimDb.NullableDateTime(reader, "LastReceivedUtc")),
      command => command.Parameters.AddWithValue("@OrganizationId", organizationId), cancellationToken);

  /// <summary>
  /// Cakalna vrsta zajema po viru, entiteti in stanju. <c>Pending</c> pomeni: stran je zajeta,
  /// a preslikave zanjo se ni — podatek ni izgubljen, ceka na preslikavo.
  /// </summary>
  public Task<IReadOnlyList<InboxGroupRow>> GetInboxGroupsAsync(int organizationId, CancellationToken cancellationToken = default) =>
    database.QueryAsync("""
      SELECT SourceCode, EntityType, Status, COUNT_BIG(*) AS PageCount,
             MIN(ReceivedUtc) AS OldestUtc, MAX(ReceivedUtc) AS NewestUtc
      FROM raw.Inbox
      WHERE OrganizationId = @OrganizationId
      GROUP BY SourceCode, EntityType, Status
      ORDER BY CASE Status WHEN N'Pending' THEN 0 WHEN N'Quarantined' THEN 1 ELSE 2 END, COUNT_BIG(*) DESC;
      """,
      reader => new InboxGroupRow(PimDb.TextOrEmpty(reader, "SourceCode"), PimDb.TextOrEmpty(reader, "EntityType"),
        PimDb.TextOrEmpty(reader, "Status"), PimDb.Int64(reader, "PageCount"),
        PimDb.NullableDateTime(reader, "OldestUtc"), PimDb.NullableDateTime(reader, "NewestUtc")),
      command => command.Parameters.AddWithValue("@OrganizationId", organizationId), cancellationToken);

  public Task<(IReadOnlyList<InboxRow> Rows, long TotalCount)> GetInboxPagesAsync(
    int organizationId, string? status, string? entityType, int skip, int take, CancellationToken cancellationToken = default) =>
    database.PageAsync("""
      SELECT InboxId, RunId, SourceCode, EntityType, PageNumber, Status, ReceivedUtc, ProcessedUtc, FailureReason
      FROM raw.Inbox
      WHERE OrganizationId = @OrganizationId
        AND (@Status IS NULL OR Status = @Status)
        AND (@EntityType IS NULL OR EntityType = @EntityType)
      ORDER BY ReceivedUtc DESC, InboxId DESC
      OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY;

      SELECT COUNT_BIG(*) FROM raw.Inbox
      WHERE OrganizationId = @OrganizationId
        AND (@Status IS NULL OR Status = @Status)
        AND (@EntityType IS NULL OR EntityType = @EntityType);
      """,
      reader => new InboxRow(PimDb.Int64(reader, "InboxId"), reader.GetGuid(reader.GetOrdinal("RunId")),
        PimDb.TextOrEmpty(reader, "SourceCode"), PimDb.TextOrEmpty(reader, "EntityType"), PimDb.Int32(reader, "PageNumber"),
        PimDb.TextOrEmpty(reader, "Status"), PimDb.DateTimeValue(reader, "ReceivedUtc"),
        PimDb.NullableDateTime(reader, "ProcessedUtc"), PimDb.Text(reader, "FailureReason")),
      command =>
      {
        command.Parameters.AddWithValue("@OrganizationId", organizationId);
        command.Parameters.AddWithValue("@Status", string.IsNullOrWhiteSpace(status) ? DBNull.Value : status);
        command.Parameters.AddWithValue("@EntityType", string.IsNullOrWhiteSpace(entityType) ? DBNull.Value : entityType);
        command.Parameters.AddWithValue("@Skip", skip);
        command.Parameters.AddWithValue("@Take", take);
      }, cancellationToken);

  /// <summary>
  /// Vrednosti, ki jih preslikava ni znala razvrstiti. Zdruzene po polju, razlogu in vrednosti,
  /// ker je isti neznani niz obicajno prisel na tisoce zapisih.
  /// </summary>
  public Task<IReadOnlyList<UnmappedValueRow>> GetUnmappedValuesAsync(int organizationId, int take, CancellationToken cancellationToken = default) =>
    database.QueryAsync("""
      SELECT TOP (@Take) unmapped.TargetFieldCode, unmapped.Reason, unmapped.Value,
             COUNT_BIG(*) AS SeenCount, MAX(unmapped.RecordedUtc) AS LastSeenUtc
      FROM map.UnmappedValue unmapped
      INNER JOIN map.ExtractedValue extracted ON extracted.ExtractedValueId = unmapped.ExtractedValueId
      INNER JOIN raw.Inbox inbox ON inbox.InboxId = extracted.InboxId
      WHERE inbox.OrganizationId = @OrganizationId
      GROUP BY unmapped.TargetFieldCode, unmapped.Reason, unmapped.Value
      ORDER BY COUNT_BIG(*) DESC;
      """,
      reader => new UnmappedValueRow(PimDb.TextOrEmpty(reader, "TargetFieldCode"), PimDb.TextOrEmpty(reader, "Reason"),
        PimDb.TextOrEmpty(reader, "Value"), PimDb.Int64(reader, "SeenCount"), PimDb.DateTimeValue(reader, "LastSeenUtc")),
      command =>
      {
        command.Parameters.AddWithValue("@OrganizationId", organizationId);
        command.Parameters.AddWithValue("@Take", take);
      }, cancellationToken);

  public Task<IReadOnlyList<MissingTranslationRow>> GetMissingTranslationsAsync(string? language, int take, CancellationToken cancellationToken = default) =>
    database.QueryAsync("""
      SELECT TOP (@Take) CONVERT(bigint, 0) AS MissingTranslationId, Domain, Language, SourceValue, SeenCount, FirstSeenUtc, LastSeenUtc
      FROM map.MissingTranslationOpen
      WHERE (@Language IS NULL OR Language = @Language)
      ORDER BY SeenCount DESC, LastSeenUtc DESC;
      """,
      reader => new MissingTranslationRow(PimDb.Int64(reader, "MissingTranslationId"), PimDb.TextOrEmpty(reader, "Domain"),
        PimDb.TextOrEmpty(reader, "Language"), PimDb.TextOrEmpty(reader, "SourceValue"), PimDb.Int64(reader, "SeenCount"),
        PimDb.DateTimeValue(reader, "FirstSeenUtc"), PimDb.DateTimeValue(reader, "LastSeenUtc")),
      command =>
      {
        command.Parameters.AddWithValue("@Take", take);
        command.Parameters.AddWithValue("@Language", string.IsNullOrWhiteSpace(language) ? DBNull.Value : language);
      }, cancellationToken);

  /// <summary>
  /// Nepreslikane dobaviteljeve kategorije. Filtra po organizaciji ni namenoma: kategorijsko
  /// drevo je dobaviteljevo in <c>map.SourceCategory</c> organizacije nima. Prejsnja izvedba je
  /// filtrirala prek <c>map.SourceConnector</c> in bila navidezna — isti dobavitelj je registriran
  /// pri vseh stirih podjetjih, zato je pogoj vedno drzal. Resnicna razseznost je vir.
  /// </summary>
  public Task<IReadOnlyList<MissingCategoryRow>> GetMissingCategoriesAsync(string? sourceCode, int take, CancellationToken cancellationToken = default) =>
    database.QueryAsync("""
      SELECT TOP (@Take) CONVERT(bigint, 0) AS MissingCategoryMapId, missing.SourceCode,
             CAST(N'' AS nvarchar(100)) AS CategoryTreeCode, missing.SourcePath AS SourcePathKey,
             CONVERT(bigint, missing.ProductCount) AS SeenCount, missing.FirstSeenUtc, missing.LastSeenUtc
      FROM map.SourceCategoryToMap missing
      WHERE @SourceCode IS NULL OR missing.SourceCode = @SourceCode
      ORDER BY missing.ProductCount DESC, missing.LastSeenUtc DESC;
      """,
      reader => new MissingCategoryRow(PimDb.Int64(reader, "MissingCategoryMapId"), PimDb.TextOrEmpty(reader, "SourceCode"),
        PimDb.TextOrEmpty(reader, "CategoryTreeCode"), PimDb.TextOrEmpty(reader, "SourcePathKey"), PimDb.Int64(reader, "SeenCount"),
        PimDb.DateTimeValue(reader, "FirstSeenUtc"), PimDb.DateTimeValue(reader, "LastSeenUtc")),
      command =>
      {
        command.Parameters.AddWithValue("@SourceCode", string.IsNullOrWhiteSpace(sourceCode) ? DBNull.Value : sourceCode);
        command.Parameters.AddWithValue("@Take", take);
      }, cancellationToken);

  /// <summary>
  /// Vrednosti za spustne filtre. Berejo se iz registra in iz dejanskih tekov, ne iz trenutne
  /// strani rezultatov — sicer bi filter ponudil samo tisto, kar je ze vidno.
  /// </summary>
  public async Task<InboundFilterOptions> GetInboundFilterOptionsAsync(int? organizationId, CancellationToken cancellationToken = default)
  {
    var sources = await database.QueryAsync(
      "SELECT DISTINCT SourceCode FROM map.SourceConnector WHERE @OrganizationId IS NULL OR OrganizationId = @OrganizationId ORDER BY SourceCode;",
      reader => PimDb.TextOrEmpty(reader, "SourceCode"),
      command => command.Parameters.AddWithValue("@OrganizationId", (object?)organizationId ?? DBNull.Value),
      cancellationToken);

    var pipelines = await database.QueryAsync(
      """
      SELECT Pipeline FROM
      (
        SELECT DISTINCT Pipeline FROM ops.PipelineRun WHERE @OrganizationId IS NULL OR OrganizationId = @OrganizationId
        UNION
        SELECT DISTINCT N'STOCK_SYNC' FROM stock.SyncRun WHERE @OrganizationId IS NULL OR OrganizationId = @OrganizationId
      ) AS combined
      ORDER BY Pipeline;
      """,
      reader => PimDb.TextOrEmpty(reader, "Pipeline"),
      command => command.Parameters.AddWithValue("@OrganizationId", (object?)organizationId ?? DBNull.Value),
      cancellationToken);

    return new(sources, pipelines);
  }

  public async Task<IngestSummary> GetSummaryAsync(int organizationId, CancellationToken cancellationToken = default)
  {
    var rows = await database.QueryAsync("""
      SELECT
        (SELECT COUNT_BIG(*) FROM raw.Inbox WHERE OrganizationId = @OrganizationId AND Status = N'Pending') AS PendingPages,
        (SELECT COUNT_BIG(*) FROM raw.Inbox WHERE OrganizationId = @OrganizationId AND Status = N'Processed') AS ProcessedPages,
        (SELECT COUNT_BIG(*) FROM raw.Inbox WHERE OrganizationId = @OrganizationId AND Status = N'Quarantined') AS QuarantinedPages,
        (SELECT COUNT_BIG(*)
         FROM map.UnmappedValue unmapped
         INNER JOIN map.ExtractedValue extracted ON extracted.ExtractedValueId = unmapped.ExtractedValueId
         INNER JOIN raw.Inbox inbox ON inbox.InboxId = extracted.InboxId
         WHERE inbox.OrganizationId = @OrganizationId) AS UnmappedValues,
        (SELECT COUNT_BIG(*) FROM map.MissingTranslationOpen) AS MissingTranslations,
        (SELECT COUNT_BIG(*) FROM map.SourceCategoryToMap missing
         WHERE EXISTS
         (
           SELECT 1 FROM map.SourceConnector connector
           WHERE connector.OrganizationId = @OrganizationId AND connector.SourceCode = missing.SourceCode
         )) AS MissingCategories;
      """,
      reader => new IngestSummary(PimDb.Int64(reader, "PendingPages"), PimDb.Int64(reader, "ProcessedPages"),
        PimDb.Int64(reader, "QuarantinedPages"), PimDb.Int64(reader, "UnmappedValues"),
        PimDb.Int64(reader, "MissingTranslations"), PimDb.Int64(reader, "MissingCategories")),
      command => command.Parameters.AddWithValue("@OrganizationId", organizationId), cancellationToken);
    return rows.Count > 0 ? rows[0] : new(0, 0, 0, 0, 0, 0);
  }
}
