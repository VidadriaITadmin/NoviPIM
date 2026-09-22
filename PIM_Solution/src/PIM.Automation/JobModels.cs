namespace PIM.Automation;

/*
  Enotni model opravil (migracija 237). Tu so zapisi, ki jih bereta gostitelj avtomatike in
  intranet: definicija posla z zadnjim stanjem, odvisnost, zagon, korak, artefakt in stanje
  gostitelja. Vsi časi so UTC, tako kot v bazi; v našo uro jih pretvori šele pogled.
*/

/// <summary>Zaprt seznam stanj zagona (ops.JobRun.Status). Running vedno konča v enem od ostalih.</summary>
public static class JobRunStatus
{
  public const string Running = "Running";
  public const string Succeeded = "Succeeded";
  public const string Warning = "Warning";
  public const string Failed = "Failed";
  public const string TimedOut = "TimedOut";
  public const string Cancelled = "Cancelled";
  public const string Abandoned = "Abandoned";
  public const string Blocked = "Blocked";

  public static bool IsSuccess(string? status) => status is Succeeded or Warning;
  public static bool IsFailure(string? status) => status is Failed or TimedOut or Abandoned;
  public static bool IsFinal(string? status) => status is not (null or Running);
}

/// <summary>Stanje koraka (ops.JobStepRun.Status).</summary>
public static class JobStepStatus
{
  public const string Succeeded = "Succeeded";
  public const string Failed = "Failed";
  public const string Skipped = "Skipped";
  public const string Cancelled = "Cancelled";
  public const string TimedOut = "TimedOut";
  public const string Blocked = "Blocked";
}

/// <summary>Vrstica ops.JobDefinition z zadnjim stanjem (intranet.GetJobDefinitions, prvi nabor).</summary>
public sealed record JobDefinitionRow(
  string JobKey, string Label, string Description, string Flow, bool IsFlowResult, int SortOrder, string Reach, bool IsEnabled,
  int? IntervalSeconds, TimeOnly? DailyAtLocal, int TimeoutSeconds, int? SlaSeconds, decimal WarnAfterMultiplier,
  DateTime? NextDueUtc, DateTime? RequestedRunUtc, string? RequestedBy, string? TriggerSource,
  long? RunningJobRunId, long? LastJobRunId, DateTime? LastStartedUtc, DateTime? LastEndedUtc, string? LastStatus,
  DateTime? LastSucceededUtc, long? LastSucceededJobRunId, string? LastError, DateTime UpdatedUtc, string UpdatedBy,
  string? RunningStep, DateTime? RunningHeartbeatUtc, DateTime? RunningSinceUtc, string? RunningHost, DateTime? CancelRequestedUtc, bool RunningIsStale,
  int OpenAlerts, string? LastSummary, int? LastStepsTotal, int? LastStepsFailed, int? LastStepsBlocked, string? LastTriggeredBy,
  string? LastBlockedByJobKey, string? LastHost, int? LastDurationMs)
{
  public bool IsRunning => RunningJobRunId is not null;
  public bool IsRequested => RequestedRunUtc is not null;
}

public sealed record JobDependencyRow(string JobKey, string DependsOnJobKey, bool IsGate, int? MaxAgeSeconds, bool TriggersDependent, string? Note);

public sealed record ArtifactRow(
  long ArtifactId, string JobKey, long? JobRunId, int? OrganizationId, string Kind, string FilePath, string FileName,
  long ByteCount, long? RowCountValue, string? Sha256, DateTime? FileModifiedUtc, DateTime CreatedUtc);

public sealed record JobRunRow(
  long JobRunId, string JobKey, string? Label, string? Flow, DateTime StartedUtc, DateTime? EndedUtc, string Status, string EffectiveStatus,
  int? ExitCode, string TriggeredBy, string StartedBy, string HostName, string? HostOwner, string? LogPath, DateTime HeartbeatUtc, string? CurrentStep,
  int StepsTotal, int StepsFailed, int StepsBlocked, int ErrorLines, string? Summary, int? TimeoutSeconds,
  DateTime? CancelRequestedUtc, string? CancelRequestedBy, string? BlockedByJobKey, int Occurrences)
{
  public TimeSpan Duration => (EndedUtc ?? DateTime.UtcNow) - StartedUtc;
}

public sealed record JobStepRunRow(
  int StepOrder, string StepName, int? OrganizationId, string? Command, DateTime StartedUtc, DateTime? EndedUtc,
  int? ExitCode, string Status, string? Note);

/// <summary>Kdo drži najem in kako živ je gostitelj (intranet.GetAutomationHost).</summary>
public sealed record AutomationHostRow(
  string? Owner, string? HostName, int? ProcessId, string? Application, DateTime? AcquiredUtc, DateTime? HeartbeatUtc, DateTime? ExpiresUtc,
  long? TickCount, bool? CanRunCycles, int? Priority, DateTime NowUtc, bool IsAutomationHostLive,
  int RunningJobs, int StaleRunningJobs, int RunsLast24h, int FailedLast24h, int BlockedLast24h, int EnabledJobs, int PendingRequests, int OpenHostAlerts)
{
  public bool HasLease => Owner is not null;
  public bool LeaseIsLive => ExpiresUtc is { } expires && expires > NowUtc;
  public TimeSpan? HeartbeatAge => HeartbeatUtc is { } beat ? NowUtc - beat : null;
}

/// <summary>Vrstica ops.SchedulerLease po klicu ops.AcquireSchedulerLease.</summary>
public sealed record SchedulerLeaseInfo(
  bool IsOwner, string Owner, string HostName, int ProcessId, string Application,
  DateTime AcquiredUtc, DateTime HeartbeatUtc, DateTime ExpiresUtc, long TickCount, bool CanRunCycles, int Priority)
{
  public bool IsLive(DateTime nowUtc) => ExpiresUtc > nowUtc;
  public bool IsAutomationHost => Application.StartsWith(AutomationApplications.Prefix, StringComparison.Ordinal);
}

/// <summary>Vrednosti stolpca ops.SchedulerLease.Application; po predponi baza loči gostitelja od intraneta.</summary>
public static class AutomationApplications
{
  public const string Prefix = "AutomationHost";
  public const string Service = "AutomationHost:service";
  public const string Console = "AutomationHost:console";

  /// <summary>Gostitelj vzame uro vsakemu z nižjo prednostjo (intranet: 0).</summary>
  public const int HostPriority = 10;
}

/// <summary>Izid ops.ClaimJobRun.</summary>
public sealed record JobClaim(long? JobRunId, string Reason, string? TriggeredBy)
{
  public bool Claimed => JobRunId is not null && Reason == "Claimed";
}
