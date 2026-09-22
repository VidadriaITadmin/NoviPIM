using System.Data;
using Microsoft.Data.SqlClient;
using PIM.Operations;

namespace PIM.Automation;

/// <summary>
/// Dostop do tabel enotnega modela opravil (migracija 237) in najema (221/237). Vsak klic odpre svojo
/// povezavo: gostitelj teče v ozadju, korak posla lahko traja minute — držati povezavo odprto čez ves
/// tek bi pomenilo eno mrtvo sejo na posel ob vsakem ponovnem zagonu. Isti razred uporablja intranet za
/// branje in za zahteve (zagon, ustavitev, urnik).
/// </summary>
public sealed class AutomationStore(string connectionString)
{
  public string ConnectionString { get; } = connectionString;

  async Task<SqlConnection> OpenAsync(CancellationToken cancellationToken)
  {
    var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    return connection;
  }

  // ─── Najem ────────────────────────────────────────────────────────────────

  public async Task<SchedulerLeaseInfo?> AcquireLeaseAsync(
    string owner, string hostName, int processId, string application, int ttlSeconds, bool canRunCycles, int priority, CancellationToken cancellationToken)
  {
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand("ops.AcquireSchedulerLease", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.Add("@Owner", SqlDbType.NVarChar, 200).Value = owner;
    command.Parameters.Add("@HostName", SqlDbType.NVarChar, 200).Value = hostName;
    command.Parameters.Add("@ProcessId", SqlDbType.Int).Value = processId;
    command.Parameters.Add("@Application", SqlDbType.NVarChar, 200).Value = application;
    command.Parameters.Add("@TtlSeconds", SqlDbType.Int).Value = ttlSeconds;
    command.Parameters.Add("@CanRunCycles", SqlDbType.Bit).Value = canRunCycles;
    command.Parameters.Add("@Priority", SqlDbType.Int).Value = priority;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    return await reader.ReadAsync(cancellationToken) ? ReadLease(reader, reader.GetBoolean(reader.GetOrdinal("IsOwner"))) : null;
  }

  public async Task ReleaseLeaseAsync(string owner, CancellationToken cancellationToken)
  {
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand("ops.ReleaseSchedulerLease", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.Add("@Owner", SqlDbType.NVarChar, 200).Value = owner;
    await command.ExecuteNonQueryAsync(cancellationToken);
  }

  public async Task<SchedulerLeaseInfo?> ReadLeaseAsync(CancellationToken cancellationToken = default)
  {
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand(
      "SELECT Owner, HostName, ProcessId, Application, AcquiredUtc, HeartbeatUtc, ExpiresUtc, TickCount, CanRunCycles, Priority FROM ops.SchedulerLease WHERE LeaseKey = N'PIM';",
      connection);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    return await reader.ReadAsync(cancellationToken) ? ReadLease(reader, false) : null;
  }

  static SchedulerLeaseInfo ReadLease(SqlDataReader reader, bool isOwner) => new(
    isOwner, Text(reader, "Owner"), Text(reader, "HostName"), Int(reader, "ProcessId"), Text(reader, "Application"),
    Date(reader, "AcquiredUtc"), Date(reader, "HeartbeatUtc"), Date(reader, "ExpiresUtc"), reader.GetInt64(reader.GetOrdinal("TickCount")),
    reader.GetBoolean(reader.GetOrdinal("CanRunCycles")), Int(reader, "Priority"));

  // ─── Definicije ───────────────────────────────────────────────────────────

  /// <summary>Koda je vir opisov in odvisnosti; urnik, vklop, časovna meja in SLA obstoječih vrstic ostanejo skrbnikovi.</summary>
  public async Task EnsureDefinitionsAsync(IEnumerable<JobDefinition> jobs, CancellationToken cancellationToken)
  {
    await using var connection = await OpenAsync(cancellationToken);
    foreach (var job in jobs)
    {
      await using var command = new SqlCommand("ops.EnsureJobDefinition", connection) { CommandType = CommandType.StoredProcedure };
      command.Parameters.Add("@JobKey", SqlDbType.NVarChar, 60).Value = job.Key;
      command.Parameters.Add("@Label", SqlDbType.NVarChar, 120).Value = job.Label;
      command.Parameters.Add("@Description", SqlDbType.NVarChar, 600).Value = job.Description;
      command.Parameters.Add("@Flow", SqlDbType.NVarChar, 30).Value = job.Flow;
      command.Parameters.Add("@IsFlowResult", SqlDbType.Bit).Value = job.IsFlowResult;
      command.Parameters.Add("@SortOrder", SqlDbType.Int).Value = job.SortOrder;
      command.Parameters.Add("@Reach", SqlDbType.NVarChar, 20).Value = job.ReachCode;
      command.Parameters.Add("@IntervalSeconds", SqlDbType.Int).Value = (object?)job.IntervalSeconds ?? DBNull.Value;
      command.Parameters.Add("@DailyAtLocal", SqlDbType.Time).Value = job.DailyAtLocal is { } at ? at.ToTimeSpan() : DBNull.Value;
      command.Parameters.Add("@TimeoutSeconds", SqlDbType.Int).Value = job.TimeoutSeconds;
      command.Parameters.Add("@SlaSeconds", SqlDbType.Int).Value = (object?)job.SlaSeconds ?? DBNull.Value;
      command.Parameters.Add("@IsEnabledDefault", SqlDbType.Bit).Value = job.EnabledByDefault;
      await command.ExecuteNonQueryAsync(cancellationToken);
    }
    // Viri s pragom svežine (256): katalog v kodi je vir resnice, vrstice v ops.JobSource pa bere stran Nadzor
    // in ops.EvaluateJobAlerts (SourceStale). Odstranjen vir iz kode se v bazi izklopi, ne izbriše.
    foreach (var job in jobs)
    {
      var order = 0;
      foreach (var source in job.Sources)
      {
        await using var command = new SqlCommand("ops.EnsureJobSource", connection) { CommandType = CommandType.StoredProcedure };
        command.Parameters.Add("@JobKey", SqlDbType.NVarChar, 60).Value = job.Key;
        command.Parameters.Add("@SourceCode", SqlDbType.NVarChar, 100).Value = source.SourceCode;
        command.Parameters.Add("@Pipeline", SqlDbType.NVarChar, 100).Value = source.Pipeline;
        command.Parameters.Add("@Label", SqlDbType.NVarChar, 120).Value = source.Label;
        command.Parameters.Add("@MaxAgeSeconds", SqlDbType.Int).Value = source.MaxAgeSeconds;
        command.Parameters.Add("@PerOrganization", SqlDbType.Bit).Value = source.PerOrganization;
        command.Parameters.Add("@MeasureNewData", SqlDbType.Bit).Value = source.MeasureNewData;
        command.Parameters.Add("@SortOrder", SqlDbType.Int).Value = ++order;
        await command.ExecuteNonQueryAsync(cancellationToken);
      }
      await using (var prune = new SqlCommand("ops.RetireJobSources", connection) { CommandType = CommandType.StoredProcedure })
      {
        prune.Parameters.Add("@JobKey", SqlDbType.NVarChar, 60).Value = job.Key;
        prune.Parameters.Add("@KeepSourceCodes", SqlDbType.NVarChar, -1).Value =
          string.Join(",", job.Sources.Select(source => $"{source.Pipeline}|{source.SourceCode}"));
        await prune.ExecuteNonQueryAsync(cancellationToken);
      }
    }

    foreach (var job in jobs)
      foreach (var dependency in job.Dependencies)
      {
        await using var command = new SqlCommand("ops.EnsureJobDependency", connection) { CommandType = CommandType.StoredProcedure };
        command.Parameters.Add("@JobKey", SqlDbType.NVarChar, 60).Value = job.Key;
        command.Parameters.Add("@DependsOnJobKey", SqlDbType.NVarChar, 60).Value = dependency.DependsOnJobKey;
        command.Parameters.Add("@IsGate", SqlDbType.Bit).Value = dependency.IsGate;
        command.Parameters.Add("@MaxAgeSeconds", SqlDbType.Int).Value = (object?)dependency.MaxAgeSeconds ?? DBNull.Value;
        command.Parameters.Add("@TriggersDependent", SqlDbType.Bit).Value = dependency.TriggersDependent;
        command.Parameters.Add("@Note", SqlDbType.NVarChar, 300).Value = dependency.Note;
        await command.ExecuteNonQueryAsync(cancellationToken);
      }
  }

  public async Task<(IReadOnlyList<JobDefinitionRow> Jobs, IReadOnlyList<JobDependencyRow> Dependencies, IReadOnlyList<ArtifactRow> Artifacts)> GetDefinitionsAsync(
    CancellationToken cancellationToken = default)
  {
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.GetJobDefinitions", connection) { CommandType = CommandType.StoredProcedure };
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);

    var jobs = new List<JobDefinitionRow>();
    while (await reader.ReadAsync(cancellationToken))
      jobs.Add(new(
        Text(reader, "JobKey"), Text(reader, "Label"), Text(reader, "Description"), Text(reader, "Flow"), Bool(reader, "IsFlowResult"),
        Int(reader, "SortOrder"), Text(reader, "Reach"), Bool(reader, "IsEnabled"), NullableInt(reader, "IntervalSeconds"), Time(reader, "DailyAtLocal"),
        Int(reader, "TimeoutSeconds"), NullableInt(reader, "SlaSeconds"), reader.GetDecimal(reader.GetOrdinal("WarnAfterMultiplier")),
        NullableDate(reader, "NextDueUtc"), NullableDate(reader, "RequestedRunUtc"), NullableText(reader, "RequestedBy"), NullableText(reader, "TriggerSource"),
        NullableLong(reader, "RunningJobRunId"), NullableLong(reader, "LastJobRunId"), NullableDate(reader, "LastStartedUtc"), NullableDate(reader, "LastEndedUtc"),
        NullableText(reader, "LastStatus"), NullableDate(reader, "LastSucceededUtc"), NullableLong(reader, "LastSucceededJobRunId"), NullableText(reader, "LastError"),
        Date(reader, "UpdatedUtc"), Text(reader, "UpdatedBy"),
        NullableText(reader, "RunningStep"), NullableDate(reader, "RunningHeartbeatUtc"), NullableDate(reader, "RunningSinceUtc"), NullableText(reader, "RunningHost"),
        NullableDate(reader, "CancelRequestedUtc"), Bool(reader, "RunningIsStale"),
        Int(reader, "OpenAlerts"), NullableText(reader, "LastSummary"), NullableInt(reader, "LastStepsTotal"), NullableInt(reader, "LastStepsFailed"),
        NullableInt(reader, "LastStepsBlocked"), NullableText(reader, "LastTriggeredBy"), NullableText(reader, "LastBlockedByJobKey"), NullableText(reader, "LastHost"),
        NullableInt(reader, "LastDurationMs")));

    var dependencies = new List<JobDependencyRow>();
    if (await reader.NextResultAsync(cancellationToken))
      while (await reader.ReadAsync(cancellationToken))
        dependencies.Add(new(Text(reader, "JobKey"), Text(reader, "DependsOnJobKey"), Bool(reader, "IsGate"), NullableInt(reader, "MaxAgeSeconds"),
          Bool(reader, "TriggersDependent"), NullableText(reader, "Note")));

    var artifacts = new List<ArtifactRow>();
    if (await reader.NextResultAsync(cancellationToken))
      while (await reader.ReadAsync(cancellationToken))
        artifacts.Add(ReadArtifact(reader));

    return (jobs, dependencies, artifacts);
  }

  public async Task SetNextDueAsync(string jobKey, DateTime nextDueUtc, bool onlyIfNull, CancellationToken cancellationToken)
  {
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand("ops.SetJobNextDue", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.Add("@JobKey", SqlDbType.NVarChar, 60).Value = jobKey;
    command.Parameters.Add("@NextDueUtc", SqlDbType.DateTime2).Value = nextDueUtc;
    command.Parameters.Add("@OnlyIfNull", SqlDbType.Bit).Value = onlyIfNull;
    await command.ExecuteNonQueryAsync(cancellationToken);
  }

  /// <summary>Koliko zadnjih končanih zagonov posla je padlo (Failed, TimedOut) od zadnjega uspeha naprej.</summary>
  public async Task<int> CountConsecutiveFailuresAsync(string jobKey, CancellationToken cancellationToken)
  {
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand("""
      DECLARE @lastSuccess bigint = (
        SELECT MAX(JobRunId) FROM ops.JobRun WHERE JobKey = @JobKey AND Status IN (N'Succeeded', N'Warning'));
      SELECT COUNT(*) FROM ops.JobRun
      WHERE JobKey = @JobKey AND Status IN (N'Failed', N'TimedOut') AND JobRunId > COALESCE(@lastSuccess, 0);
      """, connection);
    command.Parameters.Add("@JobKey", SqlDbType.NVarChar, 60).Value = jobKey;
    return await command.ExecuteScalarAsync(cancellationToken) is int count ? count : 0;
  }

  public async Task SaveScheduleAsync(string jobKey, bool isEnabled, int? intervalSeconds, TimeOnly? dailyAtLocal, int? timeoutSeconds, string actor, CancellationToken cancellationToken = default)
  {
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.SaveJobSchedule", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.Add("@JobKey", SqlDbType.NVarChar, 60).Value = jobKey;
    command.Parameters.Add("@IsEnabled", SqlDbType.Bit).Value = isEnabled;
    command.Parameters.Add("@IntervalSeconds", SqlDbType.Int).Value = (object?)intervalSeconds ?? DBNull.Value;
    command.Parameters.Add("@DailyAtLocal", SqlDbType.Time).Value = dailyAtLocal is { } at ? at.ToTimeSpan() : DBNull.Value;
    command.Parameters.Add("@TimeoutSeconds", SqlDbType.Int).Value = (object?)timeoutSeconds ?? DBNull.Value;
    command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = actor;
    await command.ExecuteNonQueryAsync(cancellationToken);
  }

  // ─── Zahteve iz konzole ───────────────────────────────────────────────────

  public async Task RequestRunAsync(string jobKey, string actor, CancellationToken cancellationToken = default)
  {
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand("ops.RequestJobRun", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.Add("@JobKey", SqlDbType.NVarChar, 60).Value = jobKey;
    command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = actor;
    await command.ExecuteNonQueryAsync(cancellationToken);
  }

  public async Task RequestCancelAsync(long jobRunId, string actor, CancellationToken cancellationToken = default)
  {
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand("ops.RequestJobCancel", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.Add("@JobRunId", SqlDbType.BigInt).Value = jobRunId;
    command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = actor;
    await command.ExecuteNonQueryAsync(cancellationToken);
  }

  // ─── Zagoni ───────────────────────────────────────────────────────────────

  public async Task<JobClaim> ClaimAsync(
    string jobKey, DateTime nextDueUtc, string startedBy, string hostName, string? hostOwner, string? logPath, bool force, CancellationToken cancellationToken)
  {
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand("ops.ClaimJobRun", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.Add("@JobKey", SqlDbType.NVarChar, 60).Value = jobKey;
    command.Parameters.Add("@NextDueUtc", SqlDbType.DateTime2).Value = nextDueUtc;
    command.Parameters.Add("@StartedBy", SqlDbType.NVarChar, 200).Value = startedBy;
    command.Parameters.Add("@HostName", SqlDbType.NVarChar, 200).Value = hostName;
    command.Parameters.Add("@HostOwner", SqlDbType.NVarChar, 200).Value = (object?)hostOwner ?? DBNull.Value;
    command.Parameters.Add("@LogPath", SqlDbType.NVarChar, 800).Value = (object?)logPath ?? DBNull.Value;
    command.Parameters.Add("@Force", SqlDbType.Bit).Value = force;
    var runId = command.Parameters.Add("@JobRunId", SqlDbType.BigInt);
    runId.Direction = ParameterDirection.Output;
    var reason = command.Parameters.Add("@Reason", SqlDbType.NVarChar, 200);
    reason.Direction = ParameterDirection.Output;
    var triggeredBy = command.Parameters.Add("@TriggeredBy", SqlDbType.NVarChar, 30);
    triggeredBy.Direction = ParameterDirection.Output;
    await command.ExecuteNonQueryAsync(cancellationToken);
    return new(runId.Value is long id ? id : null, reason.Value as string ?? "", triggeredBy.Value as string);
  }

  /// <returns>Ali je kdo zahteval ustavitev tega zagona in kdo.</returns>
  public async Task<(bool CancelRequested, string? By)> HeartbeatAsync(long jobRunId, string? currentStep, CancellationToken cancellationToken)
  {
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand("ops.HeartbeatJobRun", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.Add("@JobRunId", SqlDbType.BigInt).Value = jobRunId;
    command.Parameters.Add("@CurrentStep", SqlDbType.NVarChar, 200).Value = (object?)Cut(currentStep, 200) ?? DBNull.Value;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    if (!await reader.ReadAsync(cancellationToken)) return (false, null);
    return (reader.GetBoolean(reader.GetOrdinal("CancelRequested")), NullableText(reader, "CancelRequestedBy"));
  }

  public async Task RecordStepAsync(
    long jobRunId, int order, string name, int? organizationId, string? command, DateTime startedUtc, DateTime endedUtc,
    int? exitCode, string status, string? note, CancellationToken cancellationToken)
  {
    await using var connection = await OpenAsync(cancellationToken);
    await using var sql = new SqlCommand("ops.RecordJobStepRun", connection) { CommandType = CommandType.StoredProcedure };
    sql.Parameters.Add("@JobRunId", SqlDbType.BigInt).Value = jobRunId;
    sql.Parameters.Add("@StepOrder", SqlDbType.Int).Value = order;
    sql.Parameters.Add("@StepName", SqlDbType.NVarChar, 200).Value = Cut(name, 200)!;
    sql.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = (object?)organizationId ?? DBNull.Value;
    sql.Parameters.Add("@Command", SqlDbType.NVarChar, 1000).Value = (object?)Cut(command, 1000) ?? DBNull.Value;
    sql.Parameters.Add("@StartedUtc", SqlDbType.DateTime2).Value = startedUtc;
    sql.Parameters.Add("@EndedUtc", SqlDbType.DateTime2).Value = endedUtc;
    sql.Parameters.Add("@ExitCode", SqlDbType.Int).Value = (object?)exitCode ?? DBNull.Value;
    sql.Parameters.Add("@Status", SqlDbType.NVarChar, 20).Value = status;
    sql.Parameters.Add("@Note", SqlDbType.NVarChar, 2000).Value = (object?)Cut(note, 2000) ?? DBNull.Value;
    await sql.ExecuteNonQueryAsync(cancellationToken);
  }

  public async Task CompleteAsync(long jobRunId, JobRunOutcome outcome, string actor, CancellationToken cancellationToken)
  {
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand("ops.CompleteJobRun", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.Add("@JobRunId", SqlDbType.BigInt).Value = jobRunId;
    command.Parameters.Add("@Status", SqlDbType.NVarChar, 20).Value = outcome.Status;
    command.Parameters.Add("@ExitCode", SqlDbType.Int).Value = outcome.ExitCode;
    command.Parameters.Add("@StepsTotal", SqlDbType.Int).Value = outcome.StepsTotal;
    command.Parameters.Add("@StepsFailed", SqlDbType.Int).Value = outcome.StepsFailed;
    command.Parameters.Add("@StepsBlocked", SqlDbType.Int).Value = outcome.StepsBlocked;
    command.Parameters.Add("@ErrorLines", SqlDbType.Int).Value = outcome.ErrorLines;
    command.Parameters.Add("@Summary", SqlDbType.NVarChar, 2000).Value = (object?)Cut(outcome.Summary, 2000) ?? DBNull.Value;
    command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = actor;
    await command.ExecuteNonQueryAsync(cancellationToken);
  }

  public async Task<int> AbandonStaleAsync(string actor, int staleMinutes, string? hostName, CancellationToken cancellationToken)
  {
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand("ops.AbandonStaleJobRuns", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = actor;
    command.Parameters.Add("@StaleMinutes", SqlDbType.Int).Value = staleMinutes;
    command.Parameters.Add("@HostName", SqlDbType.NVarChar, 200).Value = (object?)hostName ?? DBNull.Value;
    return Convert.ToInt32(await command.ExecuteScalarAsync(cancellationToken) ?? 0);
  }

  public async Task EvaluateAlertsAsync(string actor, CancellationToken cancellationToken)
  {
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand("ops.EvaluateJobAlerts", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = actor;
    await command.ExecuteNonQueryAsync(cancellationToken);
  }

  public async Task<IReadOnlyList<JobRunRow>> GetRunsAsync(int take = 60, string? jobKey = null, string? status = null, int? days = 7, CancellationToken cancellationToken = default)
  {
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.GetJobRuns", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.Add("@Take", SqlDbType.Int).Value = take;
    command.Parameters.Add("@JobKey", SqlDbType.NVarChar, 60).Value = (object?)jobKey ?? DBNull.Value;
    command.Parameters.Add("@Status", SqlDbType.NVarChar, 20).Value = (object?)status ?? DBNull.Value;
    command.Parameters.Add("@Days", SqlDbType.Int).Value = (object?)days ?? DBNull.Value;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    var rows = new List<JobRunRow>();
    while (await reader.ReadAsync(cancellationToken))
      rows.Add(new(
        reader.GetInt64(reader.GetOrdinal("JobRunId")), Text(reader, "JobKey"), NullableText(reader, "Label"), NullableText(reader, "Flow"),
        Date(reader, "StartedUtc"), NullableDate(reader, "EndedUtc"), Text(reader, "Status"), Text(reader, "EffectiveStatus"),
        NullableInt(reader, "ExitCode"), Text(reader, "TriggeredBy"), Text(reader, "StartedBy"), Text(reader, "HostName"), NullableText(reader, "HostOwner"),
        NullableText(reader, "LogPath"), Date(reader, "HeartbeatUtc"), NullableText(reader, "CurrentStep"),
        Int(reader, "StepsTotal"), Int(reader, "StepsFailed"), Int(reader, "StepsBlocked"), Int(reader, "ErrorLines"), NullableText(reader, "Summary"),
        NullableInt(reader, "TimeoutSeconds"), NullableDate(reader, "CancelRequestedUtc"), NullableText(reader, "CancelRequestedBy"),
        NullableText(reader, "BlockedByJobKey"), Int(reader, "Occurrences")));
    return rows;
  }

  public async Task<IReadOnlyList<JobStepRunRow>> GetStepsAsync(long jobRunId, CancellationToken cancellationToken = default)
  {
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.GetJobStepRuns", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.Add("@JobRunId", SqlDbType.BigInt).Value = jobRunId;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    var rows = new List<JobStepRunRow>();
    while (await reader.ReadAsync(cancellationToken))
      rows.Add(new(Int(reader, "StepOrder"), Text(reader, "StepName"), NullableInt(reader, "OrganizationId"), NullableText(reader, "Command"),
        Date(reader, "StartedUtc"), NullableDate(reader, "EndedUtc"), NullableInt(reader, "ExitCode"), Text(reader, "Status"), NullableText(reader, "Note")));
    return rows;
  }

  public async Task<AutomationHostRow?> GetHostAsync(CancellationToken cancellationToken = default)
  {
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.GetAutomationHost", connection) { CommandType = CommandType.StoredProcedure };
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    if (!await reader.ReadAsync(cancellationToken)) return null;
    return new(
      NullableText(reader, "Owner"), NullableText(reader, "HostName"), NullableInt(reader, "ProcessId"), NullableText(reader, "Application"),
      NullableDate(reader, "AcquiredUtc"), NullableDate(reader, "HeartbeatUtc"), NullableDate(reader, "ExpiresUtc"), NullableLong(reader, "TickCount"),
      NullableBool(reader, "CanRunCycles"), NullableInt(reader, "Priority"), Date(reader, "NowUtc"), Bool(reader, "IsAutomationHostLive"),
      Int(reader, "RunningJobs"), Int(reader, "StaleRunningJobs"), Int(reader, "RunsLast24h"), Int(reader, "FailedLast24h"), Int(reader, "BlockedLast24h"),
      Int(reader, "EnabledJobs"), Int(reader, "PendingRequests"), Int(reader, "OpenHostAlerts"));
  }

  // ─── Kontrolne točke in artefakti ─────────────────────────────────────────

  public async Task SetCheckpointAsync(string checkpointKey, int organizationId, string jobKey, long? jobRunId, string? detail, CancellationToken cancellationToken)
  {
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand("ops.SetDataCheckpoint", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.Add("@CheckpointKey", SqlDbType.NVarChar, 80).Value = checkpointKey;
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@JobKey", SqlDbType.NVarChar, 60).Value = jobKey;
    command.Parameters.Add("@JobRunId", SqlDbType.BigInt).Value = (object?)jobRunId ?? DBNull.Value;
    command.Parameters.Add("@Detail", SqlDbType.NVarChar, 400).Value = (object?)Cut(detail, 400) ?? DBNull.Value;
    await command.ExecuteNonQueryAsync(cancellationToken);
  }

  public async Task<(long? ArtifactId, bool IsNew)> RegisterArtifactAsync(
    long? jobRunId, string jobKey, int? organizationId, string kind, string filePath, long byteCount, long? rowCount, string? sha256, DateTime? fileModifiedUtc,
    CancellationToken cancellationToken)
  {
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand("ops.RegisterArtifact", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.Add("@JobRunId", SqlDbType.BigInt).Value = (object?)jobRunId ?? DBNull.Value;
    command.Parameters.Add("@JobKey", SqlDbType.NVarChar, 60).Value = jobKey;
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = (object?)organizationId ?? DBNull.Value;
    command.Parameters.Add("@Kind", SqlDbType.NVarChar, 60).Value = kind;
    command.Parameters.Add("@FilePath", SqlDbType.NVarChar, 800).Value = Cut(filePath, 800)!;
    command.Parameters.Add("@FileName", SqlDbType.NVarChar, 200).Value = Cut(Path.GetFileName(filePath), 200)!;
    command.Parameters.Add("@ByteCount", SqlDbType.BigInt).Value = byteCount;
    command.Parameters.Add("@RowCountValue", SqlDbType.BigInt).Value = (object?)rowCount ?? DBNull.Value;
    command.Parameters.Add("@Sha256", SqlDbType.Char, 64).Value = (object?)sha256 ?? DBNull.Value;
    command.Parameters.Add("@FileModifiedUtc", SqlDbType.DateTime2).Value = (object?)fileModifiedUtc ?? DBNull.Value;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    if (!await reader.ReadAsync(cancellationToken)) return (null, false);
    return (NullableLong(reader, "ArtifactId"), reader.GetBoolean(reader.GetOrdinal("IsNew")));
  }

  static ArtifactRow ReadArtifact(SqlDataReader reader) => new(
    reader.GetInt64(reader.GetOrdinal("ArtifactId")), Text(reader, "JobKey"), NullableLong(reader, "JobRunId"), NullableInt(reader, "OrganizationId"),
    Text(reader, "Kind"), Text(reader, "FilePath"), Text(reader, "FileName"), reader.GetInt64(reader.GetOrdinal("ByteCount")),
    NullableLong(reader, "RowCountValue"), NullableText(reader, "Sha256"), NullableDate(reader, "FileModifiedUtc"), Date(reader, "CreatedUtc"));

  // ─── Kar posel potrebuje od baze med tekom ────────────────────────────────

  /// <summary>Aktivna podjetja, ki niso izključena iz avtomatike (226).</summary>
  public async Task<IReadOnlyList<int>> GetActiveOrganizationsAsync(CancellationToken cancellationToken)
  {
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand("""
      SELECT organizationValue.OrganizationId
      FROM dbo.OrganizationConfig organizationValue
      LEFT JOIN ops.OrganizationAutomationPolicy policy ON policy.OrganizationId = organizationValue.OrganizationId
      WHERE organizationValue.IsActive = 1 AND COALESCE(policy.IsEnabled, CONVERT(bit, 1)) = 1
      ORDER BY organizationValue.OrganizationId;
      """, connection);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    var ids = new List<int>();
    while (await reader.ReadAsync(cancellationToken)) ids.Add(reader.GetInt32(0));
    return ids;
  }

  public Task<string?> ResolveSystemPathAsync(string key, CancellationToken cancellationToken) =>
    SystemPaths.ResolveAsync(ConnectionString, key, null, cancellationToken);

  /// <summary>
  /// Števila za fazo IZRACUN validacije in objave (pregled bloka 6): brez njih je faza pisala le
  /// »opravljeno« in objava 0 artiklov je bila videti enako kot objava tisočih. Merilo je profil
  /// ERP_L1_SLO, ker po njem val.Promote izbira artikle za objavo. Null podjetje = vsa podjetja.
  /// </summary>
  public async Task<CatalogCounts> ReadCatalogCountsAsync(int? organizationId, CancellationToken cancellationToken)
  {
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand("""
      SELECT
        Products = (SELECT COUNT_BIG(*) FROM canon.Product product
                    WHERE product.IsActive = 1 AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)),
        Valid = SUM(CASE WHEN state.Status = N'VALID' THEN 1 ELSE 0 END),
        Invalid = SUM(CASE WHEN state.Status <> N'VALID' THEN 1 ELSE 0 END),
        Published = (SELECT COUNT_BIG(*) FROM pim.Product published
                     WHERE @OrganizationId IS NULL OR published.OrganizationId = @OrganizationId)
      FROM val.ProductValidationState state
      INNER JOIN val.ValidationProfile profile ON profile.ValidationProfileId = state.ValidationProfileId
      INNER JOIN canon.Product product ON product.ProductId = state.ProductId
      WHERE profile.ProfileCode = N'ERP_L1_SLO' AND product.IsActive = 1
        AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId);
      """, connection) { CommandTimeout = 120 };
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = (object?)organizationId ?? DBNull.Value;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    await reader.ReadAsync(cancellationToken);
    static long Value(SqlDataReader reader, int ordinal) => reader.IsDBNull(ordinal) ? 0 : Convert.ToInt64(reader.GetValue(ordinal));
    return new(Value(reader, 0), Value(reader, 1), Value(reader, 2), Value(reader, 3));
  }

  /// <summary>
  /// SQL korak posla (validacija, objava). Zastoj (Msg 1205) je pričakovan dogodek, ne okvara: do
  /// trije poskusi z naraščajočim in naključnim počitkom, preden obupamo (isto kot Sql.ps1 in 221).
  /// </summary>
  public async Task ExecuteSqlStepAsync(IReadOnlyList<string> statements, int? organizationId, int commandTimeoutSeconds, CancellationToken cancellationToken)
  {
    const int attempts = 3;
    for (var attempt = 1; ; attempt++)
    {
      try
      {
        await using var connection = await OpenAsync(cancellationToken);
        foreach (var statement in statements)
        {
          await using var command = new SqlCommand(statement, connection) { CommandTimeout = commandTimeoutSeconds };
          command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = (object?)organizationId ?? DBNull.Value;
          await command.ExecuteNonQueryAsync(cancellationToken);
        }
        return;
      }
      catch (SqlException exception) when (exception.Number == 1205 && attempt < attempts)
      {
        await Task.Delay(TimeSpan.FromMilliseconds(500 * attempt + Random.Shared.Next(500)), cancellationToken);
      }
    }
  }

  /// <summary>Varovalka nočne uskladitve: živ zajem (utrip mlajši od 15 min) blokira nov nočni zagon.</summary>
  public async Task<(int Live, int Orphans)> CountIngestRunsAsync(int hours, CancellationToken cancellationToken)
  {
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand("""
      SELECT
        (SELECT COUNT(*)
           FROM ops.PipelineRun zagon
           INNER JOIN ops.IntegrationHealth zdravje
             ON zdravje.OrganizationId = zagon.OrganizationId AND zdravje.Pipeline = zagon.Pipeline AND zdravje.RunId = zagon.RunId
          WHERE zagon.Pipeline IN (N'SAOP_PRODUCTS', N'GENERIC_XML') AND zagon.Status = N'Running'
            AND zagon.StartedUtc > DATEADD(hour, -@Hours, SYSUTCDATETIME())
            AND zdravje.LastHeartbeatUtc > DATEADD(minute, -15, SYSUTCDATETIME())) AS Live,
        (SELECT COUNT(*) FROM ops.PipelineRun
          WHERE Status = N'Running' AND StartedUtc < DATEADD(hour, -1, SYSUTCDATETIME())) AS Orphans;
      """, connection);
    command.Parameters.Add("@Hours", SqlDbType.Int).Value = hours;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    return await reader.ReadAsync(cancellationToken) ? (reader.GetInt32(0), reader.GetInt32(1)) : (0, 0);
  }

  public async Task<(int Pending, int Quarantined)> RawInboxCountsAsync(CancellationToken cancellationToken)
  {
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand(
      "SELECT (SELECT COUNT(*) FROM raw.Inbox WHERE Status = N'Pending'), (SELECT COUNT(*) FROM raw.Inbox WHERE Status = N'Quarantined');", connection);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    return await reader.ReadAsync(cancellationToken) ? (reader.GetInt32(0), reader.GetInt32(1)) : (0, 0);
  }

  /// <summary>Alarmi gostitelja gredo v isto vrsto kot vsi drugi (ops.QueueAlertDeliveries), da jih dostavi razpošiljalec.</summary>
  public async Task QueueAlertDeliveriesAsync(CancellationToken cancellationToken)
  {
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand("ops.QueueAlertDeliveries", connection) { CommandType = CommandType.StoredProcedure };
    await command.ExecuteNonQueryAsync(cancellationToken);
  }

  // ─── Branje po imenu stolpca ──────────────────────────────────────────────

  static string Text(SqlDataReader reader, string column) => reader.GetString(reader.GetOrdinal(column));
  static string? NullableText(SqlDataReader reader, string column)
  {
    var ordinal = reader.GetOrdinal(column);
    return reader.IsDBNull(ordinal) ? null : reader.GetString(ordinal);
  }
  static int Int(SqlDataReader reader, string column) => Convert.ToInt32(reader.GetValue(reader.GetOrdinal(column)));
  static int? NullableInt(SqlDataReader reader, string column)
  {
    var ordinal = reader.GetOrdinal(column);
    return reader.IsDBNull(ordinal) ? null : Convert.ToInt32(reader.GetValue(ordinal));
  }
  static long? NullableLong(SqlDataReader reader, string column)
  {
    var ordinal = reader.GetOrdinal(column);
    return reader.IsDBNull(ordinal) ? null : Convert.ToInt64(reader.GetValue(ordinal));
  }
  static bool Bool(SqlDataReader reader, string column) => reader.GetBoolean(reader.GetOrdinal(column));
  static bool? NullableBool(SqlDataReader reader, string column)
  {
    var ordinal = reader.GetOrdinal(column);
    return reader.IsDBNull(ordinal) ? null : reader.GetBoolean(ordinal);
  }
  static DateTime Date(SqlDataReader reader, string column) => reader.GetDateTime(reader.GetOrdinal(column));
  static DateTime? NullableDate(SqlDataReader reader, string column)
  {
    var ordinal = reader.GetOrdinal(column);
    return reader.IsDBNull(ordinal) ? null : reader.GetDateTime(ordinal);
  }
  static TimeOnly? Time(SqlDataReader reader, string column)
  {
    var ordinal = reader.GetOrdinal(column);
    return reader.IsDBNull(ordinal) ? null : TimeOnly.FromTimeSpan(reader.GetTimeSpan(ordinal));
  }
  static string? Cut(string? value, int max) => value is null ? null : value.Length <= max ? value : value[..max];
}
