using System.Diagnostics;

namespace PIM.Automation;

/// <summary>Zagon procesa z izpisom v živo; skupen ročnemu zagonu workerja in korakom cikla.</summary>
public static class WorkerProcess
{
  /// <param name="environment">Spremenljivke otroka poleg podedovanih; gostiteljeve (VS, IIS) se odstranijo.</param>
  /// <param name="onProcess">Kdo drži proces, da ga ustavitev lahko ubije; ob koncu dobi null.</param>
  public static async Task<int> RunAsync(
    WorkerLaunchStep step, IReadOnlyDictionary<string, string> environment, Action<string> write,
    Action<Process?> onProcess, CancellationToken cancellationToken)
  {
    var info = new ProcessStartInfo(step.FileName)
    {
      WorkingDirectory = step.WorkingDirectory,
      UseShellExecute = false,
      RedirectStandardOutput = true,
      RedirectStandardError = true,
      RedirectStandardInput = true,
      CreateNoWindow = true,
    };
    foreach (var argument in step.Arguments) info.ArgumentList.Add(argument);

    foreach (var name in info.Environment.Keys.Where(WorkerJobs.IsInheritedHostVariable).ToList())
      info.Environment.Remove(name);
    foreach (var (name, value) in environment) info.Environment[name] = value;

    using var process = new Process { StartInfo = info };
    process.Start();
    // Takoj po zagonu v Job Object gostitelja: ob smrti gostitelja Windows ubije tudi tega otroka in potomce.
    if (!ChildProcessJob.TryAssign(process, out var jobProblem))
      write($"OPOZORILO: proces ni v Job Objectu gostitelja ({jobProblem}); ob padcu gostitelja bi lahko ostal kot sirota.");
    process.StandardInput.Close();
    onProcess(process);
    try
    {
      using var registration = cancellationToken.Register(() => TryKill(process));
      if (cancellationToken.IsCancellationRequested) TryKill(process);
      var output = PumpAsync(process.StandardOutput.BaseStream, write);
      var errors = PumpAsync(process.StandardError.BaseStream, line => write("STDERR: " + line));
      await process.WaitForExitAsync(CancellationToken.None);
      await Task.WhenAll(output, errors);
      return process.ExitCode;
    }
    finally
    {
      onProcess(null);
    }
  }

  static void TryKill(Process process)
  {
    try { process.Kill(entireProcessTree: true); }
    catch (InvalidOperationException) { /* proces je ravno končal sam */ }
  }

  public static async Task PumpAsync(Stream stream, Action<string> onLine)
  {
    var buffer = new byte[8192];
    using var pending = new MemoryStream();
    int read;
    while ((read = await stream.ReadAsync(buffer)) > 0)
    {
      var start = 0;
      for (var index = 0; index < read; index++)
      {
        if (buffer[index] != (byte)'\n') continue;
        pending.Write(buffer, start, index - start);
        onLine(WorkerLogs.DecodeLine(pending.GetBuffer().AsSpan(0, (int)pending.Length)));
        pending.SetLength(0);
        start = index + 1;
      }
      pending.Write(buffer, start, read - start);
    }
    if (pending.Length > 0) onLine(WorkerLogs.DecodeLine(pending.GetBuffer().AsSpan(0, (int)pending.Length)));
  }
}
