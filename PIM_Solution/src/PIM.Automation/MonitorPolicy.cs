namespace PIM.Automation;

/*
  Model stanja posla za stran Nadzor (blok 5 prenove nadzora, 2026-09-22).

  David 2026-09-22: »jaz moram vsaki korak imeti pod nadzorom in videti da se vse izvede … naredi
  pregledno in uporabno«. Prejšnji pregled je imel šest stanj in tri barve opozoril (warn, drift,
  »zastarel«), zato ni bilo jasno, kaj je treba narediti. Zdaj ima vsak posel natanko eno od treh
  barv in EN korak, ki težavo reši:

    zelena  = podatki so sveži in zadnji tek je uspel,
    siva    = izklopljeno ali še brez dela, vedno z razlogom,
    rdeča   = napaka ali prestari podatki.

  Rumene ni. »Delno padlo« in »zamuja« sta rdeča, ker je v obeh primerih nekaj treba narediti;
  kar ne zahteva ukrepa, je sivo ali zeleno.

  Čista funkcija nad vrsticami iz baze (ops.JobDefinition, ops.JobSourceState, ops.ScheduleProfile
  z ops.IntegrationHealth, ops.Alert), da jo preveri test brez baze (MonitorPolicyChecks).
*/

/// <summary>
/// Barva posla na strani Nadzor. Zaprt seznam treh vrednosti — namenoma brez »Warning«: opozorilo, ki
/// ne pove, ali je treba kaj narediti, je uporabnik zavrnil (»preveč barv z opozorili«).
/// </summary>
public enum MonitorTone { Good, Idle, Bad }

/// <summary>EN korak, ki ga stran ponudi ob poslu. Stran iz njega naredi gumb ali povezavo.</summary>
public enum MonitorAction { None, RunNow, EnableJob, EnablePipeline, OpenLog, OpenJob, CheckHost }

/// <summary>Vrstica intranet.GetJobSourceState (256): svežina enega vira posla za eno podjetje.</summary>
/// <param name="State">Fresh, Stale, Failed ali Unknown (vir še ni zapisal nobene faze).</param>
/// <param name="BasisUtc">Čas, po katerem se meri starost: zadnji novi podatki ali zadnji uspešen stik (MeasureNewData).</param>
public sealed record SourceStateRow(
  string JobKey, string Pipeline, string SourceCode, string Label,
  int? OrganizationId, string? OrganizationName, int MaxAgeSeconds, bool MeasureNewData,
  DateTime? LastContactUtc, DateTime? LastNewDataUtc, DateTime? LastFailureUtc, DateTime? BasisUtc,
  string? LastMessage, string? LastStatus, string? LastPhaseCode, long? LastItemsOut, long? LastItemsRejected, string State);

/// <summary>Vrstica intranet.GetMonitorPipelines: postopek (ops.ScheduleProfile) za eno podjetje z zdravjem (ops.IntegrationHealth).</summary>
/// <param name="OrganizationInAutomation">ops.OrganizationAutomationPolicy (privzeto vključeno).</param>
/// <param name="HealthStatus">Null, kadar postopek za to podjetje še nikoli ni tekel (ni vrstice v ops.IntegrationHealth).</param>
public sealed record PipelineHealthRow(
  string Pipeline, int OrganizationId, string OrganizationName, bool IsEnabled,
  bool OrganizationInAutomation, int IntervalSeconds, string? HealthStatus, DateTime? LastHeartbeatUtc,
  DateTime? LastSuccessfulRunUtc, string? LastError, int ConsecutiveFailures);

/// <summary>Odprt alarm (intranet.GetMonitorAlerts): brez podatkovnih vrst, z imenom podjetja.</summary>
/// <param name="Pipeline">»OPRAVILO:&lt;posel&gt;« za alarme gostitelja, ime postopka za alarme postopkov, »GOSTITELJ« …</param>
public sealed record MonitorAlertRow(
  long AlertId, string AlertKind, string Severity, string? Pipeline,
  int OrganizationId, string OrganizationName, string Title, string? Summary,
  DateTime FirstSeenUtc, DateTime LastSeenUtc, DateTime? AcknowledgedUtc);

/// <summary>Kaj je s poslom in kaj narediti.</summary>
/// <param name="Label">Kratko: »V redu«, »Podatki stari 5 dni«, »Zadnji tek padel«, »Izklopljen«.</param>
/// <param name="Reason">En stavek: kaj je narobe ali kaj je bilo narejeno.</param>
/// <param name="ActionLabel">Besedilo gumba ali povezave (»Poženi znova«); null pri <see cref="MonitorAction.None"/>.</param>
/// <param name="ActionTarget">Cilj dejanja: ključ posla (RunNow, EnableJob, OpenLog, OpenJob), »POSTOPEK|podjetje«
/// (EnablePipeline, npr. »SAOP_STOCK|2«), null pri CheckHost in None.</param>
/// <param name="DataAge">Starost podatkov: najstarejši vir z znano starostjo; posel brez virov: čas od zadnjega uspeha.</param>
/// <param name="DataAgeLabel"><see cref="MonitorPolicy.AgeLabel"/> ali »—«, kadar starost ni znana.</param>
public sealed record MonitorVerdict(
  MonitorTone Tone, string Label, string Reason, MonitorAction Action,
  string? ActionLabel, string? ActionTarget, TimeSpan? DataAge, string DataAgeLabel);

/// <summary>Povzetek faz enega koraka ali teka: koliko jih je, koliko je prineslo nove podatke, preskočilo ali padlo.</summary>
public sealed record PhaseTally(int Total, int WithNewData, int Skipped, int Failed)
{
  public static readonly PhaseTally Empty = new(0, 0, 0, 0);

  public static PhaseTally Of(IEnumerable<(string Status, bool HasNewData)> phases)
  {
    int total = 0, withNewData = 0, skipped = 0, failed = 0;
    foreach (var (status, hasNewData) in phases)
    {
      total++;
      if (status == "Succeeded" && hasNewData) withNewData++;
      else if (status == "Skipped") skipped++;
      else if (status == "Failed") failed++;
    }
    return new(total, withNewData, skipped, failed);
  }
}

public static class MonitorPolicy
{
  /// <summary>Predpona stolpca ops.Alert.Pipeline za alarme, ki jih odpre gostitelj (ops.EvaluateJobAlerts).</summary>
  public const string JobAlertPrefix = "OPRAVILO:";

  /// <summary>
  /// Alarmi o podatkih, ne o delovanju (izključena rezervacija, zavrnjen izvoz, umik s spleta, prazen ali star
  /// posnetek zaloge). Rešuje jih urednik na svoji strani, ne skrbnik s ponovnim zagonom; na Nadzoru bi
  /// 600 vrstic ReservationExcluded zakrilo edini alarm, ki pove, da posel ne teče.
  /// </summary>
  static readonly HashSet<string> DataAlertKinds = new(StringComparer.Ordinal)
  {
    "ReservationExcluded", "ExportRejected", "WebShopWithdrawn", "StockSnapshotStale", "StockSnapshotEmpty",
  };

  const string SourceFailed = "Failed";
  const string SourceStale = "Stale";
  const string CriticalSeverity = "Critical";
  const string PipelineOverdueKind = "PipelineOverdue";
  const int ReasonLimit = 1000;
  const int AlertLabelLimit = 60;

  /// <summary>
  /// Stanje enega posla. Pravila veljajo po vrsti, prvo, ki velja, določi barvo, oznako, razlog in dejanje;
  /// starost podatkov se izračuna vedno. Vire, postopke in alarme sme klicatelj podati za vse posle hkrati —
  /// funkcija sama vzame samo tiste, ki pripadajo temu poslu.
  /// </summary>
  /// <param name="saopLaneBusyWith">Oznaka posla, ki trenutno kliče SAOP (null, kadar pot do SAOP ni zasedena).
  /// Posli, ki kličejo SAOP, tečejo po eden z dvema minutama premora (JobCatalog.UsesSaop); posel, ki čaka na
  /// to pot, NI zamujen — sicer je vsak daljši tek (naročila, ponoči dobavni roki) obarval zalogo in cene rdeče.</param>
  public static MonitorVerdict Evaluate(
    JobDefinitionRow job, IReadOnlyList<SourceStateRow> sources, IReadOnlyList<PipelineHealthRow> pipelines,
    IReadOnlyList<MonitorAlertRow> alerts, bool hostLive, DateTime nowUtc, string? saopLaneBusyWith = null)
  {
    var jobPipelines = PipelinesOf(job.JobKey);
    var mySources = sources.Where(source => source.JobKey == job.JobKey).ToList();
    var myPipelines = pipelines.Where(pipeline => jobPipelines.Contains(pipeline.Pipeline)).ToList();
    var myAlerts = alerts.Where(alert => BelongsTo(alert, job.JobKey) && !IsDataAlert(alert.AlertKind)).ToList();

    var dataAge = DataAgeOf(job, mySources, nowUtc);
    var dataAgeLabel = dataAge is { } measured ? AgeLabel(measured) : "—";
    MonitorVerdict Verdict(MonitorTone tone, string label, string reason, MonitorAction action, string? actionLabel, string? actionTarget) =>
      new(tone, label, Cut(reason, ReasonLimit), action, actionLabel, actionTarget, dataAge, dataAgeLabel);

    // 1. Izklopljen posel ni napaka: skrbnik ga je izklopil (ali je privzeto izklopljen). Siv. Vklop se ponudi
    //    samo pri poslu, ki je po kodi vklopljen; privzeto izklopljenega (pisanje v SAOP, ~300 klicev SAOP na
    //    podjetje, nočna gradnja samotesta) Nadzor ne sme vabiti k vklopu z enim klikom — razlog je opis posla,
    //    vklop ali ročni zagon ostaneta na strani posla.
    if (!job.IsEnabled)
      return JobCatalog.Find(job.JobKey) is { EnabledByDefault: false } offByDefault
        ? Verdict(MonitorTone.Idle, "Izklopljen", $"Privzeto izklopljen, za ročni zagon. {offByDefault.Description}",
            MonitorAction.None, null, null)
        : Verdict(MonitorTone.Idle, "Izklopljen", "Posel je izklopljen; gostitelj ga ne poganja po urniku.",
            MonitorAction.EnableJob, "Vklopi posel", job.JobKey);

    // 2. Brez gostitelja ne teče nič: vsak vklopljen posel je rdeč, ukrep je gostitelj, ne ponovni zagon
    //    (zahteva za zagon bi čakala v bazi, dokler gostitelj ne vstane).
    if (!hostLive)
      return Verdict(MonitorTone.Bad, "Gostitelj ne teče",
        "Gostitelj avtomatike (PIM.AutomationHost) ne utripa, zato noben posel ne teče po urniku in zahteve za zagon čakajo.",
        MonitorAction.CheckHost, "Kako zagnati gostitelja", null);

    // 3. Padel zadnji tek. Med ponovnim tekom pravilo ne velja: izid bo povedal nov tek.
    if (!job.IsRunning && JobRunStatus.IsFailure(job.LastStatus))
      return Verdict(MonitorTone.Bad,
        job.LastStatus == JobRunStatus.TimedOut ? "Zadnji tek presegel časovno mejo" : "Zadnji tek padel",
        FirstText(job.LastError, job.LastSummary) ?? $"Zadnji tek se je končal s stanjem »{StatusLabel(job.LastStatus)}«.",
        MonitorAction.RunNow, "Poženi znova", job.JobKey);

    // 4. Blokiran: vzrok je pri predhodniku, zato dejanje odpre predhodnika, ne ponovi tega posla.
    if (job.LastStatus == JobRunStatus.Blocked)
    {
      var blocker = job.LastBlockedByJobKey;
      var reason = FirstText(job.LastError) ?? "Predhodnik tega posla ni uspel ali je njegov uspeh prestar.";
      return blocker is { Length: > 0 }
        ? Verdict(MonitorTone.Bad, "Blokiran", reason, MonitorAction.OpenJob, $"Odpri posel {JobLabel(blocker)}", blocker)
        : Verdict(MonitorTone.Bad, "Blokiran", reason, MonitorAction.OpenLog, "Odpri izpis", job.JobKey);
    }

    // 5. Postopek posla je izklopljen za podjetje, ki je v avtomatiki. ops.BeginRun tak zagon zavrne (51100);
    //    postopek se izklopi tudi sam po zaporednih napakah. Šteje samo postopek, ki je za to podjetje že
    //    kdaj tekel (ima vrstico zdravja): MAGENTO_PRODUCTS obstaja za vsa podjetja, izvoz kataloga pa teče
    //    samo za podjetje kataloga — izklopljena vrstica, ki je nihče ne uporablja, ni izpad.
    var disabled = myPipelines
      .Where(pipeline => !pipeline.IsEnabled && pipeline.OrganizationInAutomation && HasRun(pipeline))
      .OrderBy(pipeline => IndexOf(jobPipelines, pipeline.Pipeline)).ThenBy(pipeline => pipeline.OrganizationId)
      .ToList();
    if (disabled.Count > 0)
    {
      var first = disabled[0];
      var reason = $"Postopek {first.Pipeline} je za {first.OrganizationName} izklopljen"
        + (first.ConsecutiveFailures > 0 ? $" po {first.ConsecutiveFailures} zaporednih napakah" : "")
        + (FirstText(first.LastError) is { } error ? $"; zadnja napaka: {error}" : ".")
        + (disabled.Count > 1 ? $" Izklopljenih postopkov tega posla: {disabled.Count}." : "");
      return Verdict(MonitorTone.Bad, "Postopek izklopljen", reason, MonitorAction.EnablePipeline,
        $"Vklopi postopek {first.Pipeline} ({first.OrganizationName})", $"{first.Pipeline}|{first.OrganizationId}");
    }

    // 6. Vir je padel (zadnja faza Failed): uspešna izhodna koda ne sme skriti, da vir ni prišel.
    var failedSources = mySources.Where(source => source.State == SourceFailed).ToList();
    if (failedSources.Count > 0)
    {
      var first = failedSources[0];
      var reason = (FirstText(first.LastMessage) ?? "Zadnja faza vira se je končala z napako.")
        + (failedSources.Count > 1 ? $" Virov z napako: {failedSources.Count}." : "");
      return Verdict(MonitorTone.Bad, $"Vir padel: {first.Label}{Organization(first)}", reason, MonitorAction.RunNow, "Poženi znova", job.JobKey);
    }

    // 7. Prestari podatki. »Preskočeno ni uspeh«: posel je lahko zelen po izhodni kodi, podatki pa stari
    //    pet dni (Braytron 17.–22. 9. 2026). Pokaže se najstarejši vir. Vir, ki ga posel za to podjetje
    //    vedno samo preskoči in ga še nikoli ni dosegel (podjetje brez knjige naročil), ni prestar, ampak
    //    brez dela — pravilo 11b.
    var staleSources = mySources.Where(source => source.State == SourceStale && !IsStructuralSkip(source))
      .OrderByDescending(source => AgeOf(source, nowUtc) ?? TimeSpan.MaxValue).ToList();
    if (staleSources.Count > 0)
    {
      var oldest = staleSources[0];
      var age = AgeOf(oldest, nowUtc);
      var basis = oldest.MeasureNewData ? "zadnji novi podatki" : "zadnji uspešen stik";
      var ranIdle = RanWithoutNewData(oldest, nowUtc);
      var reason = $"{oldest.Label}{Organization(oldest)}: {basis} {(age is { } known ? $"pred {AgeLabel(known)}" : "še nikoli")}, "
        + $"meja {AgeLabel(TimeSpan.FromSeconds(oldest.MaxAgeSeconds))}."
        + (ranIdle ? " Posel teče, vir pa ne prinaša novih podatkov, zato ponovni zagon ne pomaga." : "")
        + (FirstText(oldest.LastMessage) is { } message ? $" Zadnja faza: {message.TrimEnd('.')}." : "")
        + (staleSources.Count > 1 ? $" Prestarih virov: {staleSources.Count}." : "");
      var label = age is { } shown ? $"Podatki stari {AgeLabel(shown)}" : "Podatkov še ni";
      // Posel je tekel in vir preskočil (razmik dobavitelja, isti posnetek): ponovni zagon bi le še enkrat
      // poklical dobavitelja in dobil isto. Korak je pogled v posel, kjer faza pove vzrok.
      return ranIdle
        ? Verdict(MonitorTone.Bad, label, reason, MonitorAction.OpenJob, "Odpri posel", job.JobKey)
        : Verdict(MonitorTone.Bad, label, reason, MonitorAction.RunNow, "Poženi zdaj", job.JobKey);
    }

    // 8. Zamuda: termin je minil za več, kot dovoljuje (WarnAfterMultiplier − 1) × razmik, posel pa ne teče.
    //    Isto merilo kot alarm JobOverdue v ops.EvaluateJobAlerts, da stran in zvonec ne govorita različno.
    if (!job.IsRunning && job.NextDueUtc is { } due)
    {
      var graceSeconds = Math.Max(0d, (double)(job.WarnAfterMultiplier - 1m) * (job.IntervalSeconds ?? 86400));
      if (due < nowUtc.AddSeconds(-graceSeconds) && saopLaneBusyWith is not null && JobCatalog.UsesSaop(job.JobKey))
        return Verdict(MonitorTone.Idle, "Čaka na SAOP",
          $"Termin je minil pred {AgeLabel(nowUtc - due)}, ker posli, ki kličejo SAOP, tečejo po eden. Zdaj teče »{saopLaneBusyWith}«; ta posel pride na vrsto takoj za njim.",
          MonitorAction.None, null, null);
      if (due < nowUtc.AddSeconds(-graceSeconds))
        return Verdict(MonitorTone.Bad, "Zamuja",
          $"Termin je minil pred {AgeLabel(nowUtc - due)}, posel pa se ni začel, čeprav gostitelj utripa. Zadnji tek pove, ali posel čaka na predhodnika ali visi.",
          job.LastJobRunId is not null ? MonitorAction.OpenLog : MonitorAction.RunNow,
          job.LastJobRunId is not null ? "Odpri zadnji tek" : "Poženi zdaj", job.JobKey);
    }

    // 9. Delno padlo (Warning): nekaj korakov je uspelo, nekaj ne. Rdeče, ker je treba pogledati izpis.
    if (job.LastStatus == JobRunStatus.Warning)
      return Verdict(MonitorTone.Bad, "Delno padlo",
        FirstText(job.LastSummary, job.LastError) ?? "Zadnji tek je uspel le delno; nekateri koraki so padli.",
        MonitorAction.OpenLog, "Odpri izpis", job.JobKey);

    // 10. Odprt kritičen alarm tega posla ali njegovega postopka (npr. PipelineOverdue).
    //     Alarm PipelineOverdue, ki ga nihče ni potrdil po zadnjem teku posla (ostanek starega motorja, zadnji
    //     utrip 17. 9.), posla ne obarva: posel je od takrat tekel, alarm pa samo še ni zaprt. Posel, ki
    //     sploh še ni tekel, pokaže pravilo 11 (»Še ni teklo«, Poženi zdaj), ne surovega naslova alarma.
    var critical = myAlerts
      .Where(alert => alert.Severity == CriticalSeverity && !IsLeftoverOverdue(alert, job))
      .OrderByDescending(alert => alert.LastSeenUtc).FirstOrDefault();
    if (critical is not null)
    {
      var reason = WithoutSelfLink(FirstText(critical.Summary)) ?? critical.Title;
      if (critical.AlertKind == PipelineOverdueKind)
      {
        // Naslov alarma ima surove minute (»ni tekel 7233 min«); starost iz zadnjega utripa postopka je berljiva.
        var heartbeat = myPipelines.FirstOrDefault(pipeline => pipeline.Pipeline == critical.Pipeline && pipeline.OrganizationId == critical.OrganizationId)?.LastHeartbeatUtc;
        var label = heartbeat is { } beat
          ? $"Postopek {critical.Pipeline} ni tekel {AgeLabel(nowUtc - beat)}"
          : Cut(critical.Title, AlertLabelLimit);
        return Verdict(MonitorTone.Bad, Cut(label, AlertLabelLimit), reason, MonitorAction.RunNow, "Poženi zdaj", job.JobKey);
      }
      return Verdict(MonitorTone.Bad, Cut(critical.Title, AlertLabelLimit), reason, MonitorAction.OpenLog, "Odpri izpis", job.JobKey);
    }

    // 11. Še ni teklo ali še ni uspelo (prvi tek teče, zadnji je bil ročno ustavljen): sivo, ni napaka.
    if (job.LastStartedUtc is null)
      return Verdict(MonitorTone.Idle, "Še ni teklo", NextRunText(job, nowUtc), MonitorAction.RunNow, "Poženi zdaj", job.JobKey);
    if (job.LastSucceededUtc is null)
      return Verdict(MonitorTone.Idle, "Še ni uspelo",
        job.IsRunning ? "Prvi tek teče." : $"Posel še nima uspešnega teka; zadnji tek: {StatusLabel(job.LastStatus)}.",
        MonitorAction.RunNow, "Poženi zdaj", job.JobKey);

    // 11b. Vsi viri z znanim stanjem so taki, ki jih posel samo preskoči (npr. podjetje nima nastavljene
    //     knjige naročil): ni napaka, ki bi jo rešil zagon, ampak nastavitev. Sivo, z razlogom iz faze.
    var structural = mySources.Where(IsStructuralSkip).ToList();
    if (structural.Count > 0 && mySources.All(source => IsStructuralSkip(source) || source.State == "Unknown"))
    {
      var first = structural[0];
      return Verdict(MonitorTone.Idle, "Brez dela",
        $"{first.Label}{Organization(first)}: posel vir vedno preskoči"
        + (FirstText(first.LastMessage) is { } message ? $" ({message.TrimEnd('.')})" : "")
        + (structural.Count > 1 ? $". Takih virov: {structural.Count}." : "."),
        MonitorAction.OpenJob, "Odpri posel", job.JobKey);
    }

    // 12. V redu.
    // Vir, ki se meri po stiku (cene: dolgo brez sprememb je normalno), ne pove starosti podatkov, ampak
    // kdaj je posel nazadnje dosegel vir; beseda mora to povedati.
    var withBasis = mySources.Where(source => source.BasisUtc is not null).ToList();
    var sourceAge = withBasis.Count == 0 ? ""
      : withBasis.Any(source => source.MeasureNewData) ? $", podatki stari {dataAgeLabel}"
      : $", zadnji stik z virom pred {dataAgeLabel}";
    return Verdict(MonitorTone.Good, "V redu", $"Zadnji uspeh pred {AgeLabel(nowUtc - job.LastSucceededUtc.Value)}{sourceAge}.",
      MonitorAction.None, null, null);
  }

  /// <summary>Postopki (ops.ScheduleProfile.Pipeline), ki jih posel odpira; prazno za posel, ki ga koda ne pozna.</summary>
  public static IReadOnlyList<string> PipelinesOf(string jobKey) => JobCatalog.Find(jobKey)?.Pipelines ?? [];

  /// <summary>Alarm o podatkih (rešuje ga urednik), ne o delovanju avtomatike; Nadzor ga ne prikaže.</summary>
  public static bool IsDataAlert(string alertKind) => DataAlertKinds.Contains(alertKind);

  /// <summary>
  /// Alarm pripada poslu, kadar ga je odprl gostitelj za ta posel (»OPRAVILO:&lt;posel&gt;«) ali kadar je o
  /// postopku, ki ga posel odpira. En postopek ima lahko več poslov (SAOP_STOCK: zaloga in nočna uskladitev).
  /// </summary>
  public static bool BelongsTo(MonitorAlertRow alert, string jobKey) =>
    alert.Pipeline is { Length: > 0 } pipeline
    && (pipeline == JobAlertPrefix + jobKey || PipelinesOf(jobKey).Contains(pipeline));

  /// <summary>
  /// Starost po človeško: »45 s«, »12 min«, »3 h 10 min«, »1 dan 12 h«, »5 dni«. Pod tremi dnevi ostanejo ure,
  /// sicer bi meja 36 h pisala »1 dan« in zakrila polovico.
  /// </summary>
  public static string AgeLabel(TimeSpan age)
  {
    if (age < TimeSpan.Zero) age = TimeSpan.Zero;
    if (age.TotalSeconds < 60) return $"{(int)age.TotalSeconds} s";
    if (age.TotalMinutes < 60) return $"{(int)age.TotalMinutes} min";
    if (age.TotalHours < 24)
    {
      var hours = (int)age.TotalHours;
      return age.Minutes == 0 ? $"{hours} h" : $"{hours} h {age.Minutes} min";
    }
    var days = (int)age.TotalDays;
    var dayWord = days switch { 1 => "dan", 2 => "dneva", _ => "dni" };
    return days < 3 && age.Hours > 0 ? $"{days} {dayWord} {age.Hours} h" : $"{days} {dayWord}";
  }

  /// <summary>
  /// Barva uspešnega koraka ali teka po njegovih fazah. »Preskočeno ni uspeh«: korak z izhodno kodo 0, čigar
  /// vse faze so preskočile (Braytron: »razmik dobavitelja še teče«, »isti posnetek je že v bazi«), ni zelen,
  /// ampak siv; faza z napako ga obarva rdeče. Null, kadar stanje ni Succeeded ali korak faz nima —
  /// tedaj velja izhodna koda.
  /// </summary>
  public static (string Label, MonitorTone Tone)? SucceededByPhases(string? status, PhaseTally? phases)
  {
    if (status != JobRunStatus.Succeeded || phases is not { Total: > 0 } tally) return null;
    if (tally.Failed > 0) return ($"Faza padla ({tally.Failed})", MonitorTone.Bad);
    if (tally.WithNewData > 0) return ("Uspešno", MonitorTone.Good);
    return tally.Skipped == tally.Total ? ("Preskočeno", MonitorTone.Idle) : ("Brez novih podatkov", MonitorTone.Idle);
  }

  /// <summary>Razred za PimChip.Tone: »good«, null (nevtralno sivo) ali »bad«. Nikoli »warn«.</summary>
  public static string? ToneCss(MonitorTone tone) => tone switch
  {
    MonitorTone.Good => "good",
    MonitorTone.Bad => "bad",
    _ => null,
  };

  // ─── Pomočniki ─────────────────────────────────────────────────────────────

  /// <summary>
  /// Najstarejši vir z znano starostjo. Posel z viri, ki še niso zapisali faze, nima znane starosti (»—«):
  /// čas zadnjega uspeha bi trdil, da so podatki sveži, čeprav tega nihče ni izmeril. Posel brez virov
  /// (validacija, objava) meri starost od zadnjega uspeha.
  /// </summary>
  static TimeSpan? DataAgeOf(JobDefinitionRow job, IReadOnlyList<SourceStateRow> sources, DateTime nowUtc)
  {
    if (sources.Count > 0)
    {
      var ages = sources.Select(source => AgeOf(source, nowUtc)).Where(age => age is not null).Select(age => age!.Value).ToList();
      return ages.Count == 0 ? null : ages.Max();
    }
    return job.LastSucceededUtc is { } success ? NonNegative(nowUtc - success) : null;
  }

  /// <summary>Zamuda postopka, ki je nadzornik ni potrdil po zadnjem teku posla, ali posel še nikoli ni tekel.</summary>
  static bool IsLeftoverOverdue(MonitorAlertRow alert, JobDefinitionRow job) =>
    alert.AlertKind == PipelineOverdueKind && (job.LastStartedUtc is not { } started || alert.LastSeenUtc < started);

  /// <summary>Povzetek alarma brez stavkov, ki pošiljajo na /sistem — uporabnik je že tam.</summary>
  static string? WithoutSelfLink(string? summary)
  {
    if (summary is null) return null;
    var sentences = summary.Split(". ", StringSplitOptions.RemoveEmptyEntries)
      .Where(sentence => !sentence.Contains("/sistem", StringComparison.OrdinalIgnoreCase)).ToList();
    var text = string.Join(". ", sentences).Trim();
    if (text.Length == 0) return null;
    return text.EndsWith('.') ? text : text + ".";
  }

  /// <summary>Vir, ki ga posel doslej samo preskakuje (nikoli uspešnega stika, zadnja faza Skipped).</summary>
  static bool IsStructuralSkip(SourceStateRow source) =>
    source.LastContactUtc is null && source.LastStatus == "Skipped";

  /// <summary>
  /// Posel je vir nedavno obiskal, a ga je preskočil ali dobil iste podatke: zadnja faza Skipped ali uspeh
  /// brez novih podatkov z nedavnim stikom. Tedaj vzrok ni v tem, da posel ni tekel.
  /// </summary>
  static bool RanWithoutNewData(SourceStateRow source, DateTime nowUtc) =>
    source.LastStatus == "Skipped"
    || (source.LastStatus == "Succeeded" && source.MeasureNewData && source.LastContactUtc is { } contact
        && (source.LastNewDataUtc is not { } newData || newData < contact)
        && nowUtc - contact <= TimeSpan.FromSeconds(source.MaxAgeSeconds));

  static TimeSpan? AgeOf(SourceStateRow source, DateTime nowUtc) => source.BasisUtc is { } basis ? NonNegative(nowUtc - basis) : null;

  static TimeSpan NonNegative(TimeSpan value) => value < TimeSpan.Zero ? TimeSpan.Zero : value;

  static bool HasRun(PipelineHealthRow pipeline) =>
    pipeline.HealthStatus is not null || pipeline.LastHeartbeatUtc is not null || pipeline.LastSuccessfulRunUtc is not null;

  static int IndexOf(IReadOnlyList<string> values, string value)
  {
    for (var index = 0; index < values.Count; index++)
      if (values[index] == value) return index;
    return int.MaxValue;
  }

  static string Organization(SourceStateRow source) => source.OrganizationName is { Length: > 0 } name ? $" ({name})" : "";

  static string JobLabel(string jobKey) => JobCatalog.Find(jobKey)?.Label ?? jobKey;

  static string NextRunText(JobDefinitionRow job, DateTime nowUtc) => job.NextDueUtc switch
  {
    { } due when due > nowUtc => $"Prvi tek je na vrsti čez {AgeLabel(due - nowUtc)}.",
    not null => "Prvi tek je na vrsti zdaj; gostitelj ga pobere ob naslednjem tiku.",
    null => "Gostitelj določi prvi termin ob naslednjem tiku.",
  };

  static string StatusLabel(string? status) => status switch
  {
    JobRunStatus.Running => "teče",
    JobRunStatus.Succeeded => "uspešno",
    JobRunStatus.Warning => "delno padlo",
    JobRunStatus.Failed => "napaka",
    JobRunStatus.TimedOut => "presežena časovna meja",
    JobRunStatus.Cancelled => "ustavljeno",
    JobRunStatus.Abandoned => "zapuščeno",
    JobRunStatus.Blocked => "blokirano",
    null or "" => "—",
    _ => status,
  };

  static string? FirstText(params string?[] values) =>
    values.Select(value => value?.Trim()).FirstOrDefault(value => !string.IsNullOrEmpty(value));

  static string Cut(string text, int max) => text.Length <= max ? text : text[..(max - 1)].TrimEnd() + "…";
}
