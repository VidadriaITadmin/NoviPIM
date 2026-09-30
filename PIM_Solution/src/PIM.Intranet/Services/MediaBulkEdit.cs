using System.Globalization;
using PIM.Operations;

namespace PIM.Intranet.Services;

/// <summary>
/// Paketno urejanje na strani Mediji (/mediji, naloga #32): za izbrane vrstice (medije) ali njihove izdelke
/// »odstrani ta naslov«, »postavi sliko na prvo mesto« ali »dodaj isto sliko / isti dokument vsem«.
///
/// Pot je ista kot pri paketnem urejanju izdelkov (#10, <see cref="ProductBulkEdit"/>): majhen navidezen zvezek
/// (Podjetje | Šifra artikla | Slike | Dokumenti) gre skozi uvoz delovnega lista. Tako nastane zapis v
/// ops.ImportRun s celotnim prej → potem, zapis gre po paketih skozi pim.SaveProductMediaBulk (245, z
/// zgodovino in ponovno validacijo spremenjenih izdelkov), povratek pa je na /uvozi/{Id}. Brez nove
/// migracije in brez druge pisne poti, ki bi se z uvozom razšla.
///
/// Celica slik/dokumentov je CEL seznam izdelka v vrstnem redu (prva slika je glavna). Zato predogled najprej
/// prebere trenutni seznam vsakega izdelka (v zvezku je »-«, ki ga uvoz vedno vidi kot spremembo in zato
/// vrne »prej«), nato ga ta pomočnica preračuna: brez odstranjenih, z izbranimi naprej ali z dodanim na koncu.
/// Izdelek, ki se mu seznam ne spremeni, odpade. Tako se nič, česar uporabnik ni izbral, ne izbriše.
///
/// PRIVZETO ZA NOČ 2026-09-29 (lastnik lahko spremeni):
///   - dodajanje obstoječe slike in dokumente ohrani (seznam + novo na koncu);
///   - odstranjena slika, ki jo dobavitelj še pošilja v XML, se ob naslednjem zajemu vrne — stran to pove
///     pred potrditvijo; trajni umik je naloga preslikave vira;
///   - delo po podjetjih ločeno (šifra je enolična samo v podjetju), največ <see cref="MaxProducts"/> izdelkov.
/// </summary>
public static class MediaBulkEdit
{
  /// <summary>Naslov zapisa v zgodovini uvozov (/uvozi).</summary>
  public const string HistoryTitle = "Mediji – paketno";

  /// <summary>Največ izdelkov v eni potrditvi (PRIVZETO ZA NOČ).</summary>
  public const int MaxProducts = 5_000;

  /// <summary>Največ medijev, ki jih »vse, ki ustrezajo filtru« prebere s strežnika.</summary>
  public const int MaxRows = 5_000;

  /// <summary>Naslova stolpcev iz pogodbe delovnega lista (ProductWorkbookContract.Build, skupina Splet).</summary>
  public const string ImagesHeader = "Slike";
  public const string DocumentsHeader = "Dokumenti";

  /// <summary>Najdaljši naslov, ki ga pim.SaveProductMediaBulk sprejme (daljšega tiho izpusti).</summary>
  public const int MaxUrlLength = 1_000;

  public enum Operation
  {
    /// <summary>Odstrani izbrane naslove pri njihovih izdelkih.</summary>
    Remove,
    /// <summary>Izbrane slike postavi na prvo mesto (prva je glavna slika).</summary>
    MoveFirst,
    /// <summary>Doda isto sliko na konec galerije vsakega izdelka izbranih vrstic.</summary>
    AddImage,
    /// <summary>Doda isti dokument (npr. navodila) vsakemu izdelku izbranih vrstic.</summary>
    AddDocument,
  }

  /// <summary>Izbrana vrstica strani (medij): šifra je enolična samo znotraj podjetja.</summary>
  public sealed record Item(int OrganizationId, string OrganizationName, string ItemId, string Url, string Kind);

  public sealed record Product(int OrganizationId, string OrganizationName, string ItemId);

  /// <param name="Products">Izdelkov, ki se jim seznam res spremeni.</param>
  /// <param name="Unchanged">Izbranih izdelkov brez spremembe (naslov je že tak ali izdelka ni).</param>
  /// <param name="Removed">Naslovov, ki jih izdelki izgubijo.</param>
  /// <param name="Added">Naslovov, ki jih izdelki dobijo.</param>
  public sealed record Summary(
    int Products, int Unchanged, int Removed, int Added,
    IReadOnlyList<(string Organization, int Products)> ByOrganization, IReadOnlyList<Sample> Samples);

  public sealed record Sample(string OrganizationName, string ItemId, string Field, IReadOnlyList<string> Before, IReadOnlyList<string> After);

  public static Item From(MediaRow row) => new(row.OrganizationId, row.OrganizationName, row.ItemId, row.Url, row.Kind);

  /// <summary>Kaj dejanje naredi — za gumb in vprašanje potrditve.</summary>
  public static string Label(Operation operation) => operation switch
  {
    Operation.Remove => "Odstrani izbrane medije",
    Operation.MoveFirst => "Postavi izbrane slike na prvo mesto",
    Operation.AddImage => "Dodaj sliko izdelkom",
    Operation.AddDocument => "Dodaj dokument izdelkom",
    _ => operation.ToString(),
  };

  public static bool IsAdd(Operation operation) => operation is Operation.AddImage or Operation.AddDocument;

  /// <summary>Izdelki izbranih vrstic, vsak enkrat (podjetje + šifra, brez razlike v velikosti črk).</summary>
  public static IReadOnlyList<Product> Products(IEnumerable<Item> items) =>
    items.DistinctBy(item => (item.OrganizationId, item.ItemId.ToUpperInvariant()))
      .Select(item => new Product(item.OrganizationId, item.OrganizationName, item.ItemId))
      .ToList();

  /// <summary>
  /// Preverjanje naslova ob vnosu (null = v redu). Naslov mora biti celoten http(s) naslov: celico seznama
  /// loči »|«, zato ga naslov ne sme vsebovati; predolgega procedura tiho izpusti, zato ga zavrnemo tu.
  /// </summary>
  public static string? ValidateUrl(string? url)
  {
    var value = url?.Trim() ?? "";
    if (value.Length == 0) return "Vpiši naslov (URL) datoteke.";
    if (value.Length > MaxUrlLength) return $"Naslov je predolg (največ {MaxUrlLength:N0} znakov).";
    if (value.Contains(ProductWorkbookContract.ListSeparator, StringComparison.Ordinal))
      return $"Naslov ne sme vsebovati znaka »{ProductWorkbookContract.ListSeparator}«.";
    if (!Uri.TryCreate(value, UriKind.Absolute, out var parsed) || parsed.Scheme is not ("http" or "https") || string.IsNullOrEmpty(parsed.Host))
      return "Naslov mora biti celoten spletni naslov, ki se začne s https:// (ali http://).";
    return null;
  }

  /// <summary>Stolpec delovnega lista, v katerem je naslov te vrste (enako kot izvoz: slika ali vse drugo).</summary>
  public static string FieldFor(string kind) =>
    kind == MediaKindPolicy.ImageCode ? ProductWorkbookContract.ImagesField : ProductWorkbookContract.DocumentsField;

  /// <summary>Polja, ki jih dejanje bere in piše.</summary>
  public static IReadOnlyList<string> Fields(Operation operation) => operation switch
  {
    // Odstranitev bere oba seznama: vrsta na strani (MediaKindPolicy v SQL) in razvrstitev izvoza se lahko
    // pri robnem naslovu razideta; naslov se zato odstrani iz seznama, v katerem je, ne iz ugibanega.
    Operation.Remove => [ProductWorkbookContract.ImagesField, ProductWorkbookContract.DocumentsField],
    Operation.MoveFirst or Operation.AddImage => [ProductWorkbookContract.ImagesField],
    Operation.AddDocument => [ProductWorkbookContract.DocumentsField],
    _ => [],
  };

  /// <summary>
  /// Nov seznam izdelka. <paramref name="urls"/> so naslovi dejanja za ta izdelek (izbrani ali dodani).
  /// Primerjava je brez razlike v velikosti črk — tako kot pri zapisu (ProductWorkbookService).
  /// </summary>
  public static IReadOnlyList<string> Apply(Operation operation, IReadOnlyList<string> before, IReadOnlyCollection<string> urls)
  {
    var set = new HashSet<string>(urls.Select(url => url.Trim()), StringComparer.OrdinalIgnoreCase);
    return operation switch
    {
      Operation.Remove => before.Where(url => !set.Contains(url)).ToList(),
      // Izbrane v svojem dosedanjem vrstnem redu naprej, ostale za njimi.
      Operation.MoveFirst => before.Where(set.Contains).Concat(before.Where(url => !set.Contains(url))).ToList(),
      Operation.AddImage or Operation.AddDocument => before
        .Concat(urls.Select(url => url.Trim()).Where(url => url.Length > 0))
        .Distinct(StringComparer.OrdinalIgnoreCase).ToList(),
      _ => before,
    };
  }

  /// <summary>Nova celica ali null, kadar se seznam ne spremeni. Prazen seznam je »-« (izprazni).</summary>
  public static string? NewCell(Operation operation, string? beforeCell, IReadOnlyCollection<string> urls)
  {
    var before = ProductWorkbookContract.SplitList(beforeCell);
    var after = Apply(operation, before, urls);
    if (after.SequenceEqual(before, StringComparer.Ordinal)) return null;
    return ProductWorkbookContract.JoinList(after) ?? ProductWorkbookContract.ClearToken;
  }

  /// <summary>
  /// Zvezek za predogled: vsak izdelek enkrat. Pri odstrani / na prvo mesto je v stolpcih »-«: uvoz ga pri
  /// izdelku, ki seznam ima, vidi kot spremembo in vrne trenutni seznam (OldValues), iz katerega
  /// <see cref="Transform"/> izračuna novega. Pri dodajanju je v celici dodani naslov — tudi izdelek brez
  /// seznama je tako sprememba (»-« pri praznem seznamu uvoz izpusti). Zvezek se nikoli ne zapiše tak, kot je.
  /// </summary>
  public static byte[] BuildWorkbook(Operation operation, IReadOnlyCollection<Product> products, string? addUrl = null)
  {
    ArgumentNullException.ThrowIfNull(products);
    if (products.Count > MaxProducts)
      throw new InvalidOperationException(TooMany(products.Count));
    var fields = Fields(operation);
    var cell = IsAdd(operation)
      ? (ValidateUrl(addUrl) is { } invalid ? throw new InvalidOperationException(invalid) : addUrl!.Trim())
      : ProductWorkbookContract.ClearToken;
    var columns = new List<WorkbookColumn>
    {
      new("Podjetje", Group: ProductWorkbookContract.GroupKey),
      new("Šifra artikla", Group: ProductWorkbookContract.GroupKey),
    };
    columns.AddRange(fields.Select(field => new WorkbookColumn(
      field == ProductWorkbookContract.ImagesField ? ImagesHeader : DocumentsHeader, Group: ProductWorkbookContract.GroupWeb)));
    var rows = products
      .DistinctBy(product => (product.OrganizationId, product.ItemId.ToUpperInvariant()))
      .Select(product => (IReadOnlyList<object?>)
      [
        product.OrganizationId.ToString(CultureInfo.InvariantCulture), product.ItemId,
        .. fields.Select(_ => (object?)cell),
      ]);
    return WorkbookWriter.Write("Mediji", columns, rows);
  }

  public static string TooMany(int count) =>
    $"Izbranih je {count:N0} izdelkov; paketno urejanje medijev jih sme naenkrat zajeti največ {MaxProducts:N0}. Zoži filter (npr. podjetje, strežnik ali iskanje).";

  /// <summary>Naslovi dejanja za izdelek (podjetje, šifra) in polje.</summary>
  public delegate IReadOnlyCollection<string> UrlsFor(int organizationId, string itemId, string field);

  /// <summary>
  /// Predogled uvoza (kjer so v celicah »-«) preračuna v prave nove sezname. Polje brez spremembe odpade,
  /// izdelek brez spremembe odpade.
  /// </summary>
  public static ProductWorkbookPreview Transform(ProductWorkbookPreview preview, Operation operation, UrlsFor urlsFor)
  {
    ArgumentNullException.ThrowIfNull(preview);
    ArgumentNullException.ThrowIfNull(urlsFor);
    var fields = Fields(operation);
    var rows = new List<ProductWorkbookRowChange>(preview.Rows.Count);
    foreach (var row in preview.Rows)
    {
      var values = new Dictionary<string, string>(StringComparer.Ordinal);
      foreach (var field in fields)
      {
        if (!row.PimValues.ContainsKey(field)) continue;
        var before = row.OldValues is not null && row.OldValues.TryGetValue(field, out var old) ? old : null;
        if (NewCell(operation, before, urlsFor(row.OrganizationId, row.ItemId, field)) is { } cell) values[field] = cell;
      }
      // Varovalka: ta pot piše samo sezname slik in dokumentov (nikoli SAOP ali drugih polj).
      if (values.Count > 0) rows.Add(row with { PimValues = values, SaopValues = new Dictionary<string, string>(StringComparer.Ordinal) });
    }
    return preview with { Rows = rows };
  }

  /// <summary>Predogled: pravica, zvezek skozi uvoz (samo branje), preračun seznamov.</summary>
  public static async Task<ProductWorkbookPreview> PreviewAsync(
    PimWriteGuard guard, ProductWorkbookService workbook, Operation operation, IReadOnlyCollection<Item> items,
    string? addUrl, CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(guard);
    ArgumentNullException.ThrowIfNull(workbook);
    ArgumentNullException.ThrowIfNull(items);
    await guard.RequireAsync(PimPolicies.CatalogWrite);
    if (IsAdd(operation) && ValidateUrl(addUrl) is { } invalid) throw new InvalidOperationException(invalid);

    var products = Products(items);
    if (products.Count > MaxProducts) throw new InvalidOperationException(TooMany(products.Count));

    var selected = new Dictionary<(int, string), List<Item>>();
    foreach (var item in items)
    {
      var key = (item.OrganizationId, item.ItemId.ToUpperInvariant());
      if (!selected.TryGetValue(key, out var list)) selected[key] = list = [];
      list.Add(item);
    }

    using var file = new MemoryStream(BuildWorkbook(operation, products, addUrl));
    var preview = await workbook.PreviewAsync(file, null, cancellationToken);
    if (preview.UnknownColumns.Count > 0)
      return preview with
      {
        Rows = [],
        Problems = [.. preview.Problems, $"Stolpcev {string.Join(", ", preview.UnknownColumns)} uvoz ne prepozna; nič se ne zapiše."],
      };

    IReadOnlyCollection<string> UrlsFor(int organizationId, string itemId, string field)
    {
      if (IsAdd(operation)) return [addUrl!.Trim()];
      if (!selected.TryGetValue((organizationId, itemId.ToUpperInvariant()), out var list)) return [];
      return operation == Operation.MoveFirst
        ? list.Where(item => item.Kind == MediaKindPolicy.ImageCode).Select(item => item.Url).ToList()
        : list.Select(item => item.Url).ToList();
    }

    return Transform(preview, operation, UrlsFor);
  }

  /// <summary>Kaj bo paket naredil — za potrditev (koliko izdelkov, koliko naslovov, prej → potem).</summary>
  public static Summary Summarize(ProductWorkbookPreview preview, int selectedProducts, int sampleSize = ProductBulkEdit.SampleSize)
  {
    ArgumentNullException.ThrowIfNull(preview);
    var removed = 0; var added = 0;
    var samples = new List<Sample>();
    foreach (var row in preview.Rows)
      foreach (var pair in row.PimValues)
      {
        var before = ProductWorkbookContract.SplitList(row.OldValues is not null && row.OldValues.TryGetValue(pair.Key, out var old) ? old : null);
        var after = pair.Value == ProductWorkbookContract.ClearToken ? [] : ProductWorkbookContract.SplitList(pair.Value);
        removed += before.Count(url => !after.Contains(url, StringComparer.OrdinalIgnoreCase));
        added += after.Count(url => !before.Contains(url, StringComparer.OrdinalIgnoreCase));
        if (samples.Count < sampleSize)
          samples.Add(new(row.OrganizationName, row.ItemId, pair.Key == ProductWorkbookContract.ImagesField ? ImagesHeader : DocumentsHeader, before, after));
      }
    var byOrganization = preview.Rows.GroupBy(row => row.OrganizationName)
      .Select(group => (group.Key, group.Count()))
      .OrderByDescending(pair => pair.Item2).ToList();
    return new(preview.Rows.Count, Math.Max(0, selectedProducts - preview.Rows.Count), removed, added, byOrganization, samples);
  }

  /// <summary>
  /// Zapis skozi <see cref="ProductBulkEdit.ApplyAsync"/>: pravica (CatalogWrite), najprej zgodovina na /uvozi,
  /// nato paketi z napredkom in preklicem med paketi. Tu samo še ena varovalka: v predogledu so smeli ostati
  /// le seznami slik in dokumentov.
  /// </summary>
  public static Task<ProductBulkEdit.Result> ApplyAsync(
    PimWriteGuard guard, ProductWorkbookService workbook, ImportHistoryService history, WebWithdrawalService withdrawals,
    ProductWorkbookPreview preview, string actor, string? note, IProgress<string>? progress = null,
    CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(preview);
    if (preview.Rows.Any(row => row.SaopValues.Count > 0
      || row.PimValues.Keys.Any(key => key is not (ProductWorkbookContract.ImagesField or ProductWorkbookContract.DocumentsField))))
      throw new InvalidOperationException("Paketno urejanje medijev piše samo slike in dokumente.");
    return ProductBulkEdit.ApplyAsync(guard, workbook, history, withdrawals, preview, actor, note, progress, cancellationToken, HistoryTitle);
  }

  /// <summary>Kratko ime datoteke za prikaz v predogledu.</summary>
  public static string Short(string url) => MediaKindPolicy.FileName(url) is { Length: > 0 } name ? name : url;
}
