using System.Globalization;

namespace PIM.Automation;

/*
  Razporejanje poslov in napoved zagona (naloga #12, 2026-09-29).

  Lastnik: »da ne basajo procesorja: med sabo vedo, kdo dela; kdor bo rabil več moči, počaka; izračuna se
  približen čas; določijo se prednosti. Ko klikne Poženi, naj takoj pove, kdaj bo zagon in kdaj je
  naslednji redni zagon.«

  Tu so VSA pravila, po katerih gostitelj odloči, ali posel ta tik začne (Gate), in simulacija istih
  pravil naprej v čas (Forecast), iz katere stran Nadzor pove »ocena začetka 14:32«. Ker oba uporabljata
  isto funkcijo, stran ne more obljubljati drugega, kot motor naredi.

  Pravila po vrsti (prvo, ki velja, zadrži posel):
    1. predhodnik po verigi odvisnosti teče (validacija med objavo, objava med izvozom);
    2. pas SAOP (ekipa SAOP 2026-09-22): ročna zahteva ima prednost pred rednimi SAOP posli; posel SAOP
       nikoli ne teče hkrati z drugim in začne šele po tišini (JobCatalog.SaopQuietSeconds) od konca zadnjega;
    3. težki posli (JobCatalog.IsHeavy: validacija, objava, izvozi, dobavni datumi, analitika, nočna
       uskladitev) ne tečejo dva hkrati; težak posel počaka največ HeavyMaxWaitSeconds, potem gre vseeno,
       da zadrževanje nikoli ne preraste v zamudo (alarm JobOverdue);
    4. največ MaxConcurrentJobs poslov hkrati; nadzornik in razpošiljanje alarmov sta lahka in gresta
       mimo te meje, da jih ročni zagon nikoli ne izrine.
  Vrstni red pregleda: ročne zahteve najprej, nato po SortOrder (Order).

  Ocena trajanja je povprečje uspešnih tekov zadnjih 14 dni (AutomationStore.GetDurationStatsAsync);
  pod MinRunsForEstimate teki ocene ni in stran to pove, simulacija pa računa s FallbackSeconds.
*/

/// <summary>Zakaj posel ta trenutek ne začne (ali da začne). Vrstni red je vrstni red pravil v <see cref="JobQueue.Gate"/>.</summary>
public enum JobWaitKind { Ready, Running, Disabled, NotDue, Predecessor, SaopYields, SaopBusy, SaopQuiet, HeavyBusy, ConcurrencyLimit, HostDown }

/// <param name="BlockingJobKey">Posel, zaradi katerega ta čaka (predhodnik, posel v pasu SAOP, težak posel, ročna zahteva).</param>
/// <param name="UntilUtc">Do kdaj traja tišina SAOP (samo pri <see cref="JobWaitKind.SaopQuiet"/>).</param>
public sealed record JobGate(JobWaitKind Kind, string? BlockingJobKey = null, DateTime? UntilUtc = null)
{
  public bool CanStart => Kind == JobWaitKind.Ready;
}

/// <summary>Kar gostitelj ve o trenutku: kaj teče, kdaj se je končal zadnji SAOP posel, katera zahteva ima pas SAOP.</summary>
/// <param name="Running">Ključi poslov, ki tečejo (v gostitelju ali po bazi).</param>
public sealed record QueueSnapshot(IReadOnlyCollection<string> Running, DateTime? LastSaopEndUtc, string? SaopRequest, int MaxConcurrent);

/// <summary>Trajanje uspešnih tekov posla v zadnjih dneh (ops.JobRun).</summary>
public sealed record JobDurationStats(string JobKey, int Runs, int AverageSeconds, int MaxSeconds);

/// <summary>Napoved za en posel.</summary>
/// <param name="Kind">Stanje zdaj: teče, na vrsti, čaka (in zakaj), še ni termin, izklopljen.</param>
/// <param name="EstimatedStartUtc">Ocena začetka (za posel, ki teče: dejanski začetek); null, kadar je ni mogoče oceniti.</param>
/// <param name="EstimatedSeconds">Ocena trajanja; pri <paramref name="HasEstimate"/> = false je to privzetek za simulacijo.</param>
/// <param name="HasEstimate">Ali je ocena trajanja iz dovolj tekov (<see cref="JobQueue.MinRunsForEstimate"/>).</param>
/// <param name="BlockingEndUtc">Ocena konca posla, ki ta posel zadržuje.</param>
/// <param name="NextRegularUtc">Naslednji redni zagon (po urniku), po ročnem ali tekočem teku šteto od ocene konca.</param>
/// <param name="IsQueued">Ročna zahteva čaka na prevzem.</param>
/// <param name="BlockingIsRunning">Ali posel, ki ta posel zadržuje, ZDAJ res teče (pri meji: ali je meja zdaj dosežena).
/// Ne, kadar razlog pride iz simulacije (posel pred njim je šele na vrsti) — takrat besedilo ne sme reči »teče«.</param>
/// <param name="BlockingStartUtc">Ocena začetka posla, ki ta posel zadržuje (samo kadar ta še ne teče).</param>
public sealed record JobForecast(
  string JobKey, JobWaitKind Kind, string? BlockingJobKey, DateTime? BlockingEndUtc, DateTime? QuietUntilUtc,
  DateTime? EstimatedStartUtc, int EstimatedSeconds, bool HasEstimate, DateTime? EstimatedEndUtc, DateTime? NextRegularUtc,
  bool IsQueued, JobDurationStats? Stats, bool BlockingIsRunning = true, DateTime? BlockingStartUtc = null)
{
  /// <summary>Posel čaka namenoma (vrsta, pas SAOP, težak posel, meja): to ni zamuda.</summary>
  public bool IsHeldByScheduler => Kind is JobWaitKind.Predecessor or JobWaitKind.SaopYields or JobWaitKind.SaopBusy
    or JobWaitKind.SaopQuiet or JobWaitKind.HeavyBusy or JobWaitKind.ConcurrencyLimit;
}

public static class JobQueue
{
  /// <summary>Največ hkratnih poslov (AutomationOptions.MaxConcurrentJobs); nadzornik in alarmi so izjema.</summary>
  public const int MaxConcurrentJobs = 3;

  /// <summary>Najdlje, kar težak posel čaka na drugega težkega; potem gre vseeno (15 min, pod vsako mejo zamude).</summary>
  public const int HeavyMaxWaitSeconds = 900;

  /// <summary>Tik gostitelja; napoved je natančna na to mero.</summary>
  public const int TickSeconds = 15;

  /// <summary>Koliko uspešnih tekov je treba, da je povprečje ocena.</summary>
  public const int MinRunsForEstimate = 3;

  /// <summary>Iz koliko dni tekov se računa ocena trajanja.</summary>
  public const int EstimateDays = 14;

  /// <summary>Trajanje, s katerim simulacija računa za posel brez ocene.</summary>
  public const int FallbackSeconds = 120;

  /// <summary>Kako daleč naprej simulacija išče začetek.</summary>
  public const int HorizonSeconds = 12 * 3600;

  /// <summary>Lahki sistemski posli: nikoli jih ne zadrži meja hkratnih poslov.</summary>
  public static bool BypassesConcurrencyLimit(string jobKey) =>
    jobKey is JobCatalog.AlertEvaluation or JobCatalog.AlertDelivery;

  /// <summary>Vrstni red pregleda v tiku: ročne zahteve najprej, sicer vrstni red iz baze (SortOrder).</summary>
  public static IReadOnlyList<JobDefinitionRow> Order(IReadOnlyList<JobDefinitionRow> jobs) =>
    jobs.Select((job, index) => (job, index))
      .OrderBy(item => item.job.IsRequested ? 0 : 1).ThenBy(item => item.index)
      .Select(item => item.job).ToList();

  /// <summary>
  /// Ali posel, ki je na vrsti (termin je minil ali je zahtevan), ta tik začne. Ne preverja termina, vklopa
  /// in tega, ali posel že teče — to naredi klicatelj.
  /// </summary>
  /// <param name="waitingSinceUtc">Od kdaj posel čaka (zahteva ali termin); omeji čakanje na težak posel.</param>
  /// <param name="force">--enkrat: prednost ročne zahteve v pasu SAOP ne velja, vse drugo pa.</param>
  public static JobGate Gate(
    string jobKey, bool isRequested, DateTime? waitingSinceUtc, IReadOnlyList<JobDefinitionRow> jobs, IReadOnlyList<JobDependencyRow> dependencies,
    QueueSnapshot snapshot, DateTime nowUtc, bool force = false)
  {
    var running = snapshot.Running;

    foreach (var upstream in AutomationOverview.Upstream(jobKey, jobs, dependencies))
      if (running.Contains(upstream.JobKey)) return new(JobWaitKind.Predecessor, upstream.JobKey);

    if (JobCatalog.UsesSaop(jobKey))
    {
      if (!force && JobCatalog.YieldsSaopLane(jobKey, isRequested, snapshot.SaopRequest)) return new(JobWaitKind.SaopYields, snapshot.SaopRequest);
      if (running.FirstOrDefault(other => other != jobKey && JobCatalog.UsesSaop(other)) is { } saopBusy) return new(JobWaitKind.SaopBusy, saopBusy);
      if (snapshot.LastSaopEndUtc?.AddSeconds(JobCatalog.SaopQuietSeconds) is { } quietUntil && quietUntil > nowUtc)
        return new(JobWaitKind.SaopQuiet, null, quietUntil);
    }

    if (JobCatalog.IsHeavy(jobKey)
        && running.FirstOrDefault(other => other != jobKey && JobCatalog.IsHeavy(other)) is { } heavy
        && (waitingSinceUtc is not { } since || nowUtc - since < TimeSpan.FromSeconds(HeavyMaxWaitSeconds)))
      return new(JobWaitKind.HeavyBusy, heavy);

    if (!BypassesConcurrencyLimit(jobKey) && running.Count(key => !BypassesConcurrencyLimit(key)) >= Math.Max(1, snapshot.MaxConcurrent))
      return new(JobWaitKind.ConcurrencyLimit);

    return new(JobWaitKind.Ready);
  }

  /// <summary>Ocena trajanja: povprečje iz dovolj tekov, sicer privzetek (in HasEstimate = false).</summary>
  public static (int Seconds, bool HasEstimate) EstimateOf(JobDurationStats? stats) =>
    stats is { Runs: >= MinRunsForEstimate } known ? (Math.Max(1, known.AverageSeconds), true) : (FallbackSeconds, false);

  /// <summary>
  /// Napoved za vse posle: ista pravila kot <see cref="Gate"/>, simulirana po tikih naprej v čas s ocenami
  /// trajanja. Uspeh predhodnika sproži odvisnega (TriggersDependent), kot v bazi. Brez gostitelja nič ne teče.
  /// </summary>
  public static IReadOnlyDictionary<string, JobForecast> Forecast(
    IReadOnlyList<JobDefinitionRow> jobs, IReadOnlyList<JobDependencyRow> dependencies, IReadOnlyDictionary<string, JobDurationStats> stats,
    bool hostLive, DateTime nowUtc, TimeZoneInfo zone, int maxConcurrent = MaxConcurrentJobs)
  {
    var known = jobs.Where(job => JobCatalog.Find(job.JobKey) is not null).ToList();
    var estimate = known.ToDictionary(job => job.JobKey, job => EstimateOf(stats.GetValueOrDefault(job.JobKey)), StringComparer.Ordinal);

    // Stanje simulacije.
    var runningEnd = new Dictionary<string, DateTime>(StringComparer.Ordinal);
    var due = new Dictionary<string, DateTime?>(StringComparer.Ordinal);
    var requested = new Dictionary<string, DateTime>(StringComparer.Ordinal);
    DateTime? lastSaopEnd = known.Where(job => JobCatalog.UsesSaop(job.JobKey) && job.LastEndedUtc is not null).Select(job => job.LastEndedUtc).Max();
    var tick = TimeSpan.FromSeconds(TickSeconds);

    foreach (var job in known)
    {
      if (job.IsRunning)
      {
        var started = job.RunningSinceUtc ?? job.LastStartedUtc ?? nowUtc;
        var end = started.AddSeconds(estimate[job.JobKey].Seconds);
        // Tek, ki traja dlje od ocene: konec ni znan, simulacija ga zaključi ob naslednjem tiku.
        runningEnd[job.JobKey] = end > nowUtc ? end : nowUtc + tick;
      }
      if (job.IsRequested) requested[job.JobKey] = job.RequestedRunUtc ?? nowUtc;
      due[job.JobKey] = job.IsEnabled ? job.NextDueUtc ?? nowUtc.AddSeconds(30) : null;
    }

    QueueSnapshot Snapshot(DateTime at) => new(
      runningEnd.Keys.ToList(), lastSaopEnd,
      JobCatalog.SaopRequestFirst(known.Select(job => (job.JobKey, requested.ContainsKey(job.JobKey), runningEnd.ContainsKey(job.JobKey)))),
      maxConcurrent);

    bool IsDue(JobDefinitionRow job, DateTime at) =>
      requested.ContainsKey(job.JobKey) || (due[job.JobKey] is { } when && when <= at);

    DateTime? WaitingSince(JobDefinitionRow job) =>
      requested.TryGetValue(job.JobKey, out var since) ? since : due[job.JobKey];

    // Stanje zdaj: zakaj posel ta trenutek ne začne.
    var nowSnapshot = Snapshot(nowUtc);
    var gateNow = new Dictionary<string, JobGate>(StringComparer.Ordinal);
    foreach (var job in known)
    {
      gateNow[job.JobKey] =
        // Izklopljen posel brez zahteve je »izklopljen« tudi, ko gostitelj ne teče (ne »gostitelj ne teče«).
        !hostLive ? new(job.IsEnabled || job.IsRequested || job.IsRunning ? JobWaitKind.HostDown : JobWaitKind.Disabled)
        : runningEnd.ContainsKey(job.JobKey) ? new(JobWaitKind.Running)
        : !IsDue(job, nowUtc) ? new(job.IsEnabled ? JobWaitKind.NotDue : JobWaitKind.Disabled)
        : Gate(job.JobKey, requested.ContainsKey(job.JobKey), WaitingSince(job), known, dependencies, nowSnapshot, nowUtc);
    }

    // Prvi razlog, zaradi katerega simulacija posla ni spustila (npr. ta isti tik je pred njim začel drug posel
    // v pasu SAOP). Posel, ki je »zdaj« prost, a ga simulacija spusti šele kasneje, dobi ta razlog.
    var simulatedBlock = new Dictionary<string, JobGate>(StringComparer.Ordinal);
    var firstStart = new Dictionary<string, DateTime>(StringComparer.Ordinal);
    var firstEnd = new Dictionary<string, DateTime>(StringComparer.Ordinal);
    foreach (var job in known.Where(job => job.IsRunning))
    {
      firstStart[job.JobKey] = job.RunningSinceUtc ?? job.LastStartedUtc ?? nowUtc;
      firstEnd[job.JobKey] = runningEnd[job.JobKey];
    }

    if (hostLive)
    {
      var horizon = nowUtc.AddSeconds(HorizonSeconds);
      // Izklopljen posel brez zahteve nikoli ne začne; simulacija se ustavi, ko so vsi drugi začeli.
      var canStart = known.Count(job => job.IsEnabled || job.IsRequested || job.IsRunning);
      for (var at = nowUtc; at <= horizon && firstStart.Count < canStart; at += tick)
      {
        // 1. Konci tekov: tišina SAOP, naslednji termin od konca, sprožilec odvisnih.
        foreach (var (key, end) in runningEnd.Where(item => item.Value <= at).OrderBy(item => item.Value).ToList())
        {
          runningEnd.Remove(key);
          requested.Remove(key);
          var job = known.First(row => row.JobKey == key);
          if (JobCatalog.UsesSaop(key)) lastSaopEnd = lastSaopEnd is { } last && last > end ? last : end;
          due[key] = job.IsEnabled ? JobCatalog.NextAfterEnd(job.IntervalSeconds, job.DailyAtLocal, end, zone, 0) : null;
          foreach (var link in dependencies.Where(link => link.DependsOnJobKey == key && link.TriggersDependent))
            if (due.TryGetValue(link.JobKey, out var dependentDue) && known.First(row => row.JobKey == link.JobKey).IsEnabled)
              due[link.JobKey] = dependentDue is { } current && current < end ? current : end;
        }

        // 2. Kdo začne ta tik: isti vrstni red in ista vrata kot gostitelj.
        var ordered = known.Select((job, index) => (job, index))
          .OrderBy(item => requested.ContainsKey(item.job.JobKey) ? 0 : 1).ThenBy(item => item.index)
          .Select(item => item.job).ToList();
        foreach (var job in ordered)
        {
          if (runningEnd.ContainsKey(job.JobKey) || !IsDue(job, at)) continue;
          var gate = Gate(job.JobKey, requested.ContainsKey(job.JobKey), WaitingSince(job), known, dependencies, Snapshot(at), at);
          if (!gate.CanStart)
          {
            if (!firstStart.ContainsKey(job.JobKey)) simulatedBlock.TryAdd(job.JobKey, gate);
            continue;
          }
          var end = at.AddSeconds(estimate[job.JobKey].Seconds);
          runningEnd[job.JobKey] = end;
          requested.Remove(job.JobKey);
          firstStart.TryAdd(job.JobKey, at);
          firstEnd.TryAdd(job.JobKey, end);
        }
      }
    }

    // Kar zdaj res teče (brez gostitelja nič): razlog iz simulacije ne sme trditi, da posel pred njim »teče«.
    var runningNow = hostLive ? known.Where(job => job.IsRunning).Select(job => job.JobKey).ToHashSet(StringComparer.Ordinal) : [];
    var result = new Dictionary<string, JobForecast>(StringComparer.Ordinal);
    foreach (var job in known)
    {
      var gate = gateNow[job.JobKey];
      // »Na vrsti« zdaj, a simulacija ga spusti šele čez več kot en tik (ali sploh ne v obzorju): pred njim so
      // posli, ki jih gostitelj ta tik spusti prej. Razlog in ocena pridejo iz simulacije, ne iz stanja zdaj.
      if (gate.Kind == JobWaitKind.Ready
          && (!firstStart.TryGetValue(job.JobKey, out var readyStart) || readyStart > nowUtc + tick)
          && simulatedBlock.TryGetValue(job.JobKey, out var queued))
        gate = queued;
      var (seconds, hasEstimate) = estimate[job.JobKey];
      DateTime? start = firstStart.TryGetValue(job.JobKey, out var s) ? s
        : gate.Kind == JobWaitKind.NotDue ? job.NextDueUtc
        : null;
      DateTime? end = firstEnd.TryGetValue(job.JobKey, out var e) ? e : start?.AddSeconds(seconds);
      // Konec posla, ki ta posel zadržuje (tekoči posli imajo konec iz ocene že v firstEnd).
      DateTime? blockingEnd = gate.BlockingJobKey is { } blocking && firstEnd.TryGetValue(blocking, out var be) ? be : null;
      DateTime? blockingStart = gate.BlockingJobKey is { } blocker && firstStart.TryGetValue(blocker, out var bs) ? bs : null;
      var blockingIsRunning = gate.Kind == JobWaitKind.ConcurrencyLimit
        ? runningNow.Count(key => !BypassesConcurrencyLimit(key)) >= Math.Max(1, maxConcurrent)
        : gate.BlockingJobKey is { } holder && runningNow.Contains(holder);

      // Naslednji redni zagon: po teku, ki teče, je zahtevan ali čaka v vrsti, šteje od ocene konca (gostitelj
      // termin računa od konca teka); posel, ki še ni na vrsti, ima termin iz baze. Brez gostitelja ni ocene.
      DateTime? nextRegular = !job.IsEnabled ? null
        : gate.Kind == JobWaitKind.NotDue ? job.NextDueUtc
        : gate.Kind != JobWaitKind.HostDown && end is { } endUtc ? JobCatalog.NextAfterEnd(job.IntervalSeconds, job.DailyAtLocal, endUtc, zone, 0)
        : job.NextDueUtc;

      result[job.JobKey] = new(job.JobKey, gate.Kind, gate.BlockingJobKey, blockingEnd, gate.UntilUtc,
        start, seconds, hasEstimate, end, nextRegular, job.IsRequested && !job.IsRunning, stats.GetValueOrDefault(job.JobKey),
        blockingIsRunning, blockingIsRunning ? null : blockingStart);
    }
    return result;
  }

  /// <summary>
  /// Napoved po domače, npr. »SAOP zdaj uporablja posel »Cene iz SAOP«; konec čez ~1 min; zagon sledi po 2 min tišine SAOP.
  /// Ocena začetka 14:32 · trajanje ~1 min · naslednji redni zagon 15:33.«
  /// </summary>
  /// <param name="label">Ključ posla → ime za človeka.</param>
  /// <param name="time">Čas UTC → naša ura (HH:mm).</param>
  public static string Explain(JobForecast forecast, Func<string, string> label, Func<DateTime, string> time, DateTime nowUtc)
  {
    string In(DateTime at) => at <= nowUtc ? "zdaj" : "čez ~" + Span(at - nowUtc);
    string Name(string? key) => key is null ? "drug posel" : $"»{label(key)}«";
    var quiet = $"{JobCatalog.SaopQuietSeconds / 60} min tišine SAOP";

    var cause = forecast.Kind switch
    {
      JobWaitKind.HostDown => "Gostitelj avtomatike ne teče; zagon počaka, da se zažene.",
      JobWaitKind.Running => forecast.HasEstimate && forecast.EstimatedEndUtc is { } runEnd
        ? $"Teče od {Time(forecast.EstimatedStartUtc)}; ocena konca {time(runEnd)} ({In(runEnd)})."
        : $"Teče od {Time(forecast.EstimatedStartUtc)}; ocene trajanja še ni (premalo tekov).",
      JobWaitKind.Disabled => "Izklopljen: po urniku ne teče, ročni zagon deluje.",
      JobWaitKind.NotDue => forecast.NextRegularUtc is { } next ? $"Naslednji redni zagon ob {time(next)} ({In(next)})." : "Termin določi gostitelj ob naslednjem tiku.",
      JobWaitKind.Ready => forecast.IsQueued ? "Na vrsti takoj: gostitelj ga prevzame ob naslednjem tiku (do 15 s)." : "Na vrsti ob naslednjem tiku gostitelja.",
      // Posel pred njim ZDAJ teče: »ravno teče; konec čez ~44 s«. Sicer je šele na vrsti (razlog iz simulacije):
      // »(na vrsti ob ~14:32, traja ~44 s)« — nikoli »teče«, kadar nič ne teče (preverjalec #12).
      JobWaitKind.Predecessor => forecast.BlockingIsRunning
        ? $"Čaka predhodnika {Name(forecast.BlockingJobKey)}, ki ravno teče{Ends(forecast.BlockingEndUtc)}."
        : $"Čaka predhodnika {Name(forecast.BlockingJobKey)}{Queued()}.",
      JobWaitKind.SaopYields => $"Prednost v pasu SAOP ima ročni zagon {Name(forecast.BlockingJobKey)}; ta posel pride na vrsto za njim.",
      JobWaitKind.SaopBusy => forecast.BlockingIsRunning
        ? $"SAOP zdaj uporablja posel {Name(forecast.BlockingJobKey)}{Ends(forecast.BlockingEndUtc)}; zagon sledi po {quiet}."
        : $"V pasu SAOP je pred njim posel {Name(forecast.BlockingJobKey)}{Queued()}; zagon sledi po {quiet}.",
      JobWaitKind.SaopQuiet => $"Posli, ki kličejo SAOP, imajo med seboj {quiet}; tišina traja do {Time(forecast.QuietUntilUtc)}.",
      JobWaitKind.HeavyBusy => forecast.BlockingIsRunning
        ? $"Ravno teče težak posel {Name(forecast.BlockingJobKey)}{Ends(forecast.BlockingEndUtc)}; dva težka posla ne gresta hkrati (čaka največ {HeavyMaxWaitSeconds / 60} min)."
        : $"Za težkim poslom {Name(forecast.BlockingJobKey)}{Queued()}; dva težka posla ne gresta hkrati (čaka največ {HeavyMaxWaitSeconds / 60} min).",
      JobWaitKind.ConcurrencyLimit => forecast.BlockingIsRunning
        ? $"Hkrati že tečejo {MaxConcurrentJobs} posli (meja); ta pride na vrsto, ko se kateri konča."
        : $"Pred njim so na vrsti drugi posli; hkrati gredo največ {MaxConcurrentJobs}.",
      _ => "",
    };

    if (forecast.Kind is JobWaitKind.NotDue or JobWaitKind.Disabled or JobWaitKind.Running or JobWaitKind.HostDown)
      return forecast.Kind == JobWaitKind.Running && forecast.NextRegularUtc is { } after ? $"{cause} Naslednji redni zagon ob {time(after)}." : cause;

    var parts = new List<string>();
    parts.Add(forecast.EstimatedStartUtc is { } start ? $"ocena začetka {time(start)}" : "ocene začetka ni (vrsta je daljša od 12 h)");
    parts.Add(forecast.HasEstimate ? $"trajanje ~{Span(TimeSpan.FromSeconds(forecast.EstimatedSeconds))}" : "trajanje: ocene še ni (premalo tekov)");
    if (forecast.NextRegularUtc is { } regular) parts.Add($"naslednji redni zagon {time(regular)}");
    return $"{cause} {Capital(string.Join(" · ", parts))}.";

    string Ends(DateTime? end) => end is { } at ? $"; konec {In(at)}" : "";
    string Queued()
    {
      var bits = new List<string>();
      if (forecast.BlockingStartUtc is { } from) bits.Add($"na vrsti ob ~{time(from)}");
      if (forecast.BlockingStartUtc is { } s0 && forecast.BlockingEndUtc is { } e0 && e0 > s0) bits.Add($"traja ~{Span(e0 - s0)}");
      return bits.Count == 0 ? " (v vrsti pred njim)" : $" ({string.Join(", ", bits)})";
    }
    string Time(DateTime? at) => at is { } value ? time(value) : "—";
  }

  /// <summary>Kratko trajanje: »45 s«, »3 min«, »1 h 10 min«.</summary>
  public static string Span(TimeSpan span)
  {
    if (span < TimeSpan.Zero) span = TimeSpan.Zero;
    if (span.TotalSeconds < 60) return $"{Math.Max(1, (int)Math.Round(span.TotalSeconds))} s";
    if (span.TotalMinutes < 60) return $"{(int)Math.Round(span.TotalMinutes)} min";
    var hours = (int)span.TotalHours;
    return span.Minutes == 0 ? $"{hours} h" : $"{hours} h {span.Minutes} min";
  }

  /// <summary>
  /// Kratek razlog pod čipom na Nadzoru, npr. »čaka SAOP (teče Cene iz SAOP)«, ali »v vrsti za Cene iz SAOP«,
  /// kadar posel pred njim še ne teče (razlog iz simulacije).
  /// </summary>
  public static string HeldLabel(JobForecast forecast, Func<string, string> label)
  {
    var other = forecast.BlockingJobKey is { } key ? label(key) : "drugim poslom";
    return forecast.Kind switch
    {
      JobWaitKind.Predecessor => forecast.BlockingIsRunning ? $"čaka predhodnika {other}" : $"v vrsti za {other}",
      JobWaitKind.SaopBusy => forecast.BlockingIsRunning ? $"čaka SAOP (teče {other})" : $"v vrsti za {other}",
      JobWaitKind.SaopQuiet => "čaka tišino SAOP",
      JobWaitKind.SaopYields => $"prednost ima ročni zagon {other}",
      JobWaitKind.HeavyBusy => forecast.BlockingIsRunning ? $"čaka težak posel {other}" : $"v vrsti za {other}",
      JobWaitKind.ConcurrencyLimit => $"meja {MaxConcurrentJobs} hkratnih poslov",
      _ => "",
    };
  }

  /// <summary>Oznaka napovedi za stolpec »Naslednji« na Nadzoru: kratka, s časom v naši uri.</summary>
  public static string ShortLabel(JobForecast forecast, Func<DateTime, string> time) => forecast.Kind switch
  {
    JobWaitKind.HostDown => "gostitelj ne teče",
    JobWaitKind.Disabled => "—",
    JobWaitKind.Running => forecast.HasEstimate && forecast.EstimatedEndUtc is { } end ? $"teče · konec ~{time(end)}" : "teče",
    JobWaitKind.NotDue => forecast.NextRegularUtc is { } next ? time(next) : "ob naslednjem tiku",
    JobWaitKind.Ready => forecast.IsQueued ? "v vrsti · takoj" : "zdaj",
    _ => forecast.EstimatedStartUtc is { } start ? $"v vrsti · ~{time(start)}" : "v vrsti",
  };

  static string Capital(string text) => text.Length == 0 ? text : char.ToUpper(text[0], CultureInfo.GetCultureInfo("sl-SI")) + text[1..];
}
