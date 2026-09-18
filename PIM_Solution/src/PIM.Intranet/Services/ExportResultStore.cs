using System.Collections.Concurrent;

namespace PIM.Intranet.Services;

/// <summary>
/// Začasna hramba generiranih izvoznih datotek med koncem gradnje v ozadju in prenosom v
/// brskalnik. SignalR (vezje Blazor Server) ni narejen za prenos vecmegabajtnih datotek, zato
/// gre vsebina prek navadnega GET /izvoz/prenos/{token} — stran samo sproži prenos, ko je token
/// znan (ExportJobService), brskalnik pa datoteko prenese po obicajni HTTP poti.
///
/// Datoteke ležijo na disku (začasna mapa procesa), ne v pomnilniku: zvezek celega kataloga
/// meri več deset do sto megabajtov in deset hkratnih izvozov bi kot <c>byte[]</c> pojedlo
/// gigabajt delovnega pomnilnika strežnika (analiza 2026-09-17). Gradnja piše naravnost v
/// datoteko (<see cref="CreateTempFile"/>), prenos jo pretaka z diska.
///
/// Zapisi se sami pobrišejo po dveh urah, ce jih nihce ne prevzame — dovolj casa, da uporabnik
/// utegne zapreti zavihek in se vrniti, premalo, da bi neprevzeti izvozi kopičili disk. Ob
/// zagonu procesa se pobrišejo tudi ostanki prejšnjega procesa, ki so starejši od te dobe.
/// </summary>
public sealed class ExportResultStore : IDisposable
{
  sealed record Entry(string Path, string FileName, string ContentType, DateTime ExpiresUtc);

  static readonly TimeSpan Lifetime = TimeSpan.FromHours(2);
  readonly string directory = Path.Combine(Path.GetTempPath(), "PIM.Intranet", "izvozi");
  readonly ConcurrentDictionary<Guid, Entry> entries = new();
  readonly Timer sweeper;

  public ExportResultStore()
  {
    Directory.CreateDirectory(directory);
    Sweep();
    sweeper = new Timer(_ => Sweep(), null, TimeSpan.FromMinutes(10), TimeSpan.FromMinutes(10));
  }

  /// <summary>Pot nove začasne datoteke, v katero gradnja piše; ob koncu jo preda <see cref="Put(string, string, string)"/>.</summary>
  public string CreateTempFile() => Path.Combine(directory, Guid.NewGuid().ToString("N") + ".tmp");

  /// <summary>Prevzame dokončano datoteko (premakne jo pod žeton) in vrne žeton za prenos.</summary>
  public Guid Put(string path, string fileName, string contentType)
  {
    var token = Guid.NewGuid();
    var final = Path.Combine(directory, token.ToString("N") + ".bin");
    File.Move(path, final, overwrite: true);
    entries[token] = new Entry(final, fileName, contentType, DateTime.UtcNow.Add(Lifetime));
    return token;
  }

  /// <summary>Kadar je vsebina že v pomnilniku (manjši izvozi); zapiše jo na disk in preda kot zgoraj.</summary>
  public Guid Put(byte[] bytes, string fileName, string contentType)
  {
    var path = CreateTempFile();
    File.WriteAllBytes(path, bytes);
    return Put(path, fileName, contentType);
  }

  public bool TryGet(Guid token, out string path, out string fileName, out string contentType)
  {
    if (entries.TryGetValue(token, out var entry) && entry.ExpiresUtc > DateTime.UtcNow && File.Exists(entry.Path))
    {
      (path, fileName, contentType) = (entry.Path, entry.FileName, entry.ContentType);
      return true;
    }
    (path, fileName, contentType) = ("", "", "");
    return false;
  }

  void Sweep()
  {
    var now = DateTime.UtcNow;
    foreach (var pair in entries)
      if (pair.Value.ExpiresUtc <= now && entries.TryRemove(pair.Key, out var removed))
        TryDelete(removed.Path);

    // Ostanki: datoteke brez zapisa (prejšnji proces, prekinjena gradnja), starejše od dobe.
    try
    {
      var known = entries.Values.Select(entry => entry.Path).ToHashSet(StringComparer.OrdinalIgnoreCase);
      foreach (var file in Directory.EnumerateFiles(directory))
        if (!known.Contains(file) && File.GetLastWriteTimeUtc(file) < now - Lifetime)
          TryDelete(file);
    }
    catch (IOException) { }
    catch (UnauthorizedAccessException) { }
  }

  static void TryDelete(string path)
  {
    try { File.Delete(path); }
    catch (IOException) { }
    catch (UnauthorizedAccessException) { }
  }

  public void Dispose() => sweeper.Dispose();
}
