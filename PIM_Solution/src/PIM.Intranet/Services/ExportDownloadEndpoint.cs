using Microsoft.Net.Http.Headers;

namespace PIM.Intranet.Services;

/// <summary>
/// GET /izvoz/zvezek/{jobId}: prenos delovnega lista, ki ga odpre klik na »Izvozi Excel«.
///
/// Zakaj ne prenos ob koncu gradnje (kot do 2026-09-22): tega je sprožil skript minute po kliku,
/// ko je bil zvezek gotov. Brskalnik tak prenos brez uporabnikovega dejanja obravnava kot
/// sumljiv — Chrome ga je zadržal z »Obdrži« in ni pokazal svojega polja prenosov, uporabnik pa
/// ni vedel, da se kaj prenaša in kdaj je konec. Zdaj stran ob kliku odpre to pot, glava
/// odgovora (priponka, ime datoteke) gre ven takoj, brskalnik prenos kaže ves čas gradnje,
/// vsebina pride, ko je zvezek gotov. Napredek v vrsticah in oceno preostanka kaže okno izvozov
/// v kotu strani; brskalnik velikosti vnaprej ne pozna.
///
/// Gradnja teče naprej tudi, če uporabnik prenos v brskalniku prekliče — okno ga potem ponudi
/// s »Prenesi« (GET /izvoz/prenos/{token}).
/// </summary>
public static class ExportDownloadEndpoint
{
  public static async Task StreamWorkbookAsync(
    Guid jobId, HttpContext context, ExportJobService exports, ExportResultStore results)
  {
    var owner = context.User.Identity?.Name ?? "";
    var job = exports.Get(jobId);
    if (job is null || !string.Equals(job.Owner, owner, StringComparison.OrdinalIgnoreCase))
    {
      context.Response.StatusCode = StatusCodes.Status404NotFound;
      await context.Response.WriteAsync("Izvoz ni (vec) na voljo.", context.RequestAborted);
      return;
    }

    var response = context.Response;
    response.ContentType = ExportJobService.WorkbookContentType;
    var disposition = new ContentDispositionHeaderValue("attachment");
    disposition.SetHttpFileName(job.FileName ?? "izvoz.xlsx");
    response.Headers.ContentDisposition = disposition.ToString();
    response.Headers.CacheControl = "no-store";
    // StartAsync glavo samo zapise v izhodno cev; brez Flush bi jo Kestrel poslal sele s prvim
    // bajtom vsebine — torej ob koncu gradnje, in brskalnik bi do takrat ne kazal nicesar.
    await response.StartAsync(context.RequestAborted);
    await response.Body.FlushAsync(context.RequestAborted);

    ExportJobState? done;
    try { done = await exports.WaitForBrowserAsync(jobId, owner, context.RequestAborted); }
    catch (OperationCanceledException) { return; }

    if (done is not { Status: ExportRunStatus.Completed, DownloadToken: { } token }
      || !results.TryGet(token, out var path, out _, out _))
    {
      // Glava (200) je ze poslana, zato napake ni mogoce vec povedati s statusom. Prekinjena
      // povezava brskalniku pove, da prenos ni uspel — sicer bi shranil prazno datoteko kot
      // uspesno. Razlog pove okno izvozov.
      exports.ReleaseBrowser(jobId);
      context.Abort();
      return;
    }

    try
    {
      await response.SendFileAsync(path, context.RequestAborted);
      exports.MarkDownloaded(token);
    }
    catch (Exception failure) when (failure is OperationCanceledException or IOException)
    {
      exports.ReleaseBrowser(jobId);
    }
  }
}
