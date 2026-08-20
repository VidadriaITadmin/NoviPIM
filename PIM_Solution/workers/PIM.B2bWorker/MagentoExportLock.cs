namespace PIM.B2bWorker;

/// <summary>
/// Ključavnica na izhodni mapi Magento izvoza.
///
/// Zakaj obstaja: <c>magento-products.csv</c> in <c>magento-customers.csv</c> sta par, ki ga
/// Magento uvozi skupaj. Dva sočasna zagona <c>--export-magento</c> v isto mapo bi lahko
/// prestavila vsak svojo datoteko in objavila par, sestavljen iz dveh različnih zagonov —
/// izdelke iz enega in stranke iz drugega. Enolična imena začasnih datotek to preprečijo samo
/// deloma; zamenjava sama mora biti izključujoča.
///
/// Izvedba je datoteka <c>.magento-export.lock</c> z <see cref="FileShare.None"/>. Operacijski
/// sistem jo sprosti tudi, če proces pade, zato ne more ostati obvisela.
/// <see cref="FileOptions.DeleteOnClose"/> jo ob rednem koncu tudi odstrani.
/// </summary>
internal sealed class MagentoExportLock : IDisposable
{
  private readonly FileStream stream;

  private MagentoExportLock(FileStream stream) => this.stream = stream;

  internal static MagentoExportLock Acquire(string outputDirectory)
  {
    var lockPath = Path.Combine(outputDirectory, ".magento-export.lock");
    try
    {
      return new MagentoExportLock(new FileStream(
        lockPath,
        FileMode.Create,
        FileAccess.ReadWrite,
        FileShare.None,
        bufferSize: 1,
        FileOptions.DeleteOnClose));
    }
    catch (IOException exception)
    {
      throw new InvalidOperationException(
        $"V mapi {outputDirectory} že teče Magento izvoz ({lockPath}). "
        + "Sočasna zagona bi lahko objavila par datotek iz dveh različnih izvozov. "
        + "Počakaj, da se prvi konča, ali izberi drugo izhodno mapo.",
        exception);
    }
  }

  public void Dispose() => stream.Dispose();
}
