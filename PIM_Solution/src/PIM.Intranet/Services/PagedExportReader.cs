namespace PIM.Intranet.Services;

/// <summary>
/// En bralni paket izvoza: glavne vrstice strani (npr. izdelki), njihove podrobnosti (npr. napake)
/// in skupno stevilo glavnih vrstic, ki ustrezajo filtru.
/// </summary>
public sealed record ExportPage<TItem, TDetail>(IReadOnlyList<TItem> Items, IReadOnlyList<TDetail> Details, long TotalCount);

/// <summary>Rezultat branja po straneh: vse prebrane vrstice in ali je izvoz dosegel zgornjo mejo.</summary>
public sealed record ExportPages<TItem, TDetail>(
  IReadOnlyList<TItem> Items, IReadOnlyList<TDetail> Details, long TotalCount, bool Truncated);

/// <summary>
/// #112: izvoz bere po straneh, ker bralna procedura omeji eno stran (intranet.GetQualityIssues
/// sprejme najvec 200 izdelkov, migracija 177). Prej je izvoz vzel samo prvo stran in v datoteki
/// je bilo "Izvozenih 200 od 9.044". Zanka bere, dokler ne prebere vseh vrstic iz TotalCount,
/// dokler stran ne pride prazna ali dokler podrobnosti ne dosezejo fizicne meje lista.
/// Glavne vrstice se ne podvojijo (kljuc), ce se podatki med branjem premaknejo.
/// </summary>
public static class PagedExportReader
{
  public static async Task<ExportPages<TItem, TDetail>> ReadAllAsync<TItem, TDetail, TKey>(
    int pageSize, int maxDetails,
    Func<int, int, CancellationToken, Task<ExportPage<TItem, TDetail>>> fetchPage,
    Func<TItem, TKey> itemKey, Func<TDetail, TKey> detailKey,
    CancellationToken cancellationToken = default) where TKey : notnull
  {
    if (pageSize < 1) throw new ArgumentOutOfRangeException(nameof(pageSize));
    if (maxDetails < 1) throw new ArgumentOutOfRangeException(nameof(maxDetails));

    var items = new List<TItem>();
    var details = new List<TDetail>();
    var seen = new HashSet<TKey>();
    long total = 0;
    var skip = 0;
    var truncated = false;

    while (true)
    {
      cancellationToken.ThrowIfCancellationRequested();
      var page = await fetchPage(skip, pageSize, cancellationToken);
      total = Math.Max(total, page.TotalCount);
      if (page.Items.Count == 0) break;

      var fresh = new HashSet<TKey>();
      foreach (var item in page.Items)
        if (seen.Add(itemKey(item))) { items.Add(item); fresh.Add(itemKey(item)); }

      foreach (var detail in page.Details)
      {
        if (!fresh.Contains(detailKey(detail))) continue;
        if (details.Count >= maxDetails) { truncated = true; break; }
        details.Add(detail);
      }

      if (truncated) break;
      skip += page.Items.Count;
      // Ne ustavi se na krajsi strani: procedura lahko stran omeji pod pageSize (meja 200).
      if (skip >= page.TotalCount) break;
    }

    return new(items, details, total, truncated);
  }
}
