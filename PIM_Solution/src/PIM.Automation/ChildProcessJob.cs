using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace PIM.Automation;

/// <summary>
/// Windows Job Object z JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE za vse procese, ki jih zažene ta proces.
/// Ročica se ne zapre nikoli sama: ko proces gostitelja umre na kakršenkoli način (sesutje, taskkill /F,
/// ustavitev storitve, recikel IIS), jo zapre Windows in s tem ubije vse otroke in njihove potomce.
/// Prej je worker po padcu gostitelja tekel naprej kot sirota in klical SAOP (2026-09-22).
/// </summary>
public static class ChildProcessJob
{
  const int ExtendedLimitInformationClass = 9;
  const uint JobObjectLimitKillOnJobClose = 0x2000;

  static readonly Lazy<IntPtr> job = new(Create, LazyThreadSafetyMode.ExecutionAndPublication);

  /// <summary>
  /// Proces doda v job. Vrne false (in razlog), kadar to ni mogoče; zagon zato ne pade, sirota pa je
  /// spet možna — klicatelj razlog zapiše v dnevnik.
  /// </summary>
  public static bool TryAssign(Process process, out string? reason)
  {
    reason = null;
    if (!OperatingSystem.IsWindows()) { reason = "ni Windows"; return false; }
    try
    {
      var handle = job.Value;
      if (handle == IntPtr.Zero) { reason = "Job Object ni na voljo"; return false; }
      if (AssignProcessToJobObject(handle, process.Handle)) return true;
      reason = new Win32Exception(Marshal.GetLastWin32Error()).Message;
      return false;
    }
    catch (Exception exception) when (exception is InvalidOperationException or Win32Exception)
    {
      reason = exception.Message;
      return false;
    }
  }

  static IntPtr Create()
  {
    if (!OperatingSystem.IsWindows()) return IntPtr.Zero;
    var handle = CreateJobObject(IntPtr.Zero, null);
    if (handle == IntPtr.Zero) return IntPtr.Zero;
    var info = new JobObjectExtendedLimitInformation
    {
      BasicLimitInformation = new JobObjectBasicLimitInformation { LimitFlags = JobObjectLimitKillOnJobClose },
    };
    if (!SetInformationJobObject(handle, ExtendedLimitInformationClass, ref info, (uint)Marshal.SizeOf<JobObjectExtendedLimitInformation>()))
    {
      CloseHandle(handle);
      return IntPtr.Zero;
    }
    return handle;
  }

  [StructLayout(LayoutKind.Sequential)]
  struct JobObjectBasicLimitInformation
  {
    public long PerProcessUserTimeLimit;
    public long PerJobUserTimeLimit;
    public uint LimitFlags;
    public UIntPtr MinimumWorkingSetSize;
    public UIntPtr MaximumWorkingSetSize;
    public uint ActiveProcessLimit;
    public UIntPtr Affinity;
    public uint PriorityClass;
    public uint SchedulingClass;
  }

  [StructLayout(LayoutKind.Sequential)]
  struct IoCounters
  {
    public ulong ReadOperationCount;
    public ulong WriteOperationCount;
    public ulong OtherOperationCount;
    public ulong ReadTransferCount;
    public ulong WriteTransferCount;
    public ulong OtherTransferCount;
  }

  [StructLayout(LayoutKind.Sequential)]
  struct JobObjectExtendedLimitInformation
  {
    public JobObjectBasicLimitInformation BasicLimitInformation;
    public IoCounters IoInfo;
    public UIntPtr ProcessMemoryLimit;
    public UIntPtr JobMemoryLimit;
    public UIntPtr PeakProcessMemoryUsed;
    public UIntPtr PeakJobMemoryUsed;
  }

  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  static extern IntPtr CreateJobObject(IntPtr jobAttributes, string? name);

  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref JobObjectExtendedLimitInformation info, uint length);

  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool CloseHandle(IntPtr handle);
}
