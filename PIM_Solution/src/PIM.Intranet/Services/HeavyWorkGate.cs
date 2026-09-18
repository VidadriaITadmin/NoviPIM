namespace PIM.Intranet.Services;

/// <summary>
/// Vrata za težka opravila intraneta: izvoz celega kataloga v Excel in uvoz delovnega lista.
///
/// Zakaj obstajajo (analiza 2026-09-17): en sam izvoz celotnega kataloga (196.000 izdelkov, 150
/// stolpcev) drži bazo več minut, uvoz s tisoči vrstic prav tako. Deset uporabnikov, ki
/// hkrati kliknejo »Izvozi«, bi brez vrat pomenilo deset vzporednih tekov istih težkih
/// procedur — strani seznama, kartice in nadzorne plošče bi za vse čakale na iste diske in
/// procesorje, delovni pomnilnik strežnika pa bi nosil deset zvezkov hkrati. Vrata spustijo
/// naprej največ <see cref="Lane.Limit"/> opravil na vrsto; ostala čakajo po vrstnem redu
/// prihoda in uporabnik vidi, koliko jih je pred njim. Strani, ki niso izvoz ali uvoz, vrat ne
/// poznajo in ostanejo odzivne.
///
/// Meji sta nastavljivi (<c>Intranet:MaxConcurrentExports</c>, <c>Intranet:MaxConcurrentImports</c>
/// v appsettings); privzeto dva in dva — izmerjeno na razvojni bazi s štirimi jedri (MAXDOP 4):
/// dva vzporedna izvoza še pustita seznamu izdelkov odzivni čas pod dvema sekundama.
/// </summary>
public sealed class HeavyWorkGate
{
  public const int DefaultMaxConcurrentExports = 2;
  public const int DefaultMaxConcurrentImports = 2;

  public HeavyWorkGate(IConfiguration configuration)
  {
    Exports = new Lane("izvoz", Limit(configuration, "Intranet:MaxConcurrentExports", DefaultMaxConcurrentExports));
    Imports = new Lane("uvoz", Limit(configuration, "Intranet:MaxConcurrentImports", DefaultMaxConcurrentImports));
  }

  /// <summary>Izvozi (delovni list, pregled, SAOP predloga, zaloga, CSV) — v ozadju in neposredni.</summary>
  public Lane Exports { get; }

  /// <summary>Uvozi delovnega lista: predogled (branje celega nabora) in zapis.</summary>
  public Lane Imports { get; }

  static int Limit(IConfiguration configuration, string key, int fallback) =>
    int.TryParse(configuration[key], out var value) && value > 0 ? value : fallback;

  /// <summary>Ena vrsta z omejitvijo sočasnosti; vstop je po vrstnem redu prihoda.</summary>
  public sealed class Lane(string name, int limit)
  {
    readonly SemaphoreSlim slots = new(limit, limit);
    int waiting;
    int running;

    public string Name { get; } = name;
    public int Limit { get; } = limit;

    /// <summary>Koliko opravil čaka na vstop (ne šteje tistih, ki že tečejo).</summary>
    public int Waiting => Volatile.Read(ref waiting);

    /// <summary>Koliko opravil trenutno teče.</summary>
    public int Running => Volatile.Read(ref running);

    /// <summary>Vstopi takoj, če je prostor; sicer null, brez čakanja.</summary>
    public IDisposable? TryEnter()
    {
      if (!slots.Wait(0)) return null;
      Interlocked.Increment(ref running);
      return new Lease(this);
    }

    /// <summary>Počaka na prosto mesto. Vrne zapiralo; z <c>Dispose</c> se mesto sprosti.</summary>
    /// <returns>Zapiralo mesta.</returns>
    public async Task<IDisposable> EnterAsync(CancellationToken cancellationToken = default)
    {
      Interlocked.Increment(ref waiting);
      try { await slots.WaitAsync(cancellationToken); }
      finally { Interlocked.Decrement(ref waiting); }
      Interlocked.Increment(ref running);
      return new Lease(this);
    }

    void Release()
    {
      Interlocked.Decrement(ref running);
      slots.Release();
    }

    sealed class Lease(Lane lane) : IDisposable
    {
      int released;
      public void Dispose()
      {
        if (Interlocked.Exchange(ref released, 1) == 0) lane.Release();
      }
    }
  }
}
