namespace PIM.KatalogWorker;

/// <summary>
/// Zanka čez podjetja z eno samo zavezo: <b>padec enega podjetja ne sme preprečiti ostalih.</b>
///
/// Zakaj obstaja kot ločena, testljiva enota. Zajem teče za štiri podjetja. Prej je klic
/// <c>ops.BeginRun</c> stal zunaj <c>try</c>, zato je manjkajoč ali izklopljen razpored (napaka
/// 51100 — točno to je odpravila migracija 043) ubil celoten worker in podjetja za njim sploh
/// niso prišla na vrsto. Napaka pri zajemu je bila obravnavana, napaka pri odpiranju zagona pa ne.
///
/// Zanka je generična glede na tip zagona (<typeparamref name="TRun"/>), da jo je mogoče dokazati
/// z lažnimi zagoni, brez baze in brez SAOP. <c>OperationsRun</c> je zapečaten razred brez
/// vmesnika, zato bi vsaka druga oblika zahtevala živo bazo, da bi preverila navadno zanko.
/// </summary>
internal static class OrganizationLoop
{
  /// <summary>
  /// Za vsako podjetje: <paramref name="beginAsync"/> → <paramref name="workAsync"/> →
  /// <paramref name="completeAsync"/>, na koncu vedno <paramref name="disposeAsync"/>.
  /// Vrne true, če je katerokoli podjetje padlo ali javilo neuspeh.
  /// </summary>
  internal static async Task<bool> RunAsync<TRun>(
    IReadOnlyList<SaopOrganization> organizations,
    Func<SaopOrganization, Task<TRun>> beginAsync,
    Func<SaopOrganization, TRun, Task<bool>> workAsync,
    Func<TRun, bool, string?, Task> completeAsync,
    Func<TRun, Task> disposeAsync,
    Action<SaopOrganization, Exception> reportFailure)
    where TRun : class
  {
    var failed = false;

    foreach (var organization in organizations)
    {
      // beginAsync stoji ZNOTRAJ try — to je bistvo tega razreda.
      TRun? run = null;
      try
      {
        run = await beginAsync(organization);
        var succeeded = await workAsync(organization, run);
        failed |= !succeeded;
        await completeAsync(run, succeeded, succeeded ? null : "Vsaj ena končna točka ni uspela.");
      }
      catch (Exception exception)
      {
        failed = true;
        reportFailure(organization, exception);

        // Zagon zaključimo samo, če je sploh nastal. Če je padel beginAsync, ni česa zaključiti.
        if (run is not null)
        {
          try { await completeAsync(run, false, exception.Message); }
          catch (Exception completeException)
          {
            // Tudi zaključevanje lahko pade (prekinjena povezava). To ne sme prekiniti zanke —
            // sicer bi napaka pri poročanju o napaki spet ustavila preostala podjetja.
            reportFailure(organization, completeException);
          }
        }
      }
      finally
      {
        if (run is not null)
        {
          try { await disposeAsync(run); }
          catch (Exception disposeException)
          {
            reportFailure(organization, disposeException);
          }
        }
      }
    }

    return failed;
  }
}
