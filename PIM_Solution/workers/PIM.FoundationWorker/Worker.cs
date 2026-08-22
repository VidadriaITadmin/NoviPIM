namespace PIM.FoundationWorker;

public class Worker : BackgroundService
{
  private readonly ILogger<Worker> _logger;

  public Worker(ILogger<Worker> logger)
  {
    _logger = logger;
  }

  protected override async Task ExecuteAsync(CancellationToken stoppingToken)
  {
    // ARHIV (odlocitev uporabnika 2026-08-22): ta worker je skelet iz faze F0 in ni v uporabi.
    // Zajem opravljata PIM.KatalogWorker (SAOP) in PIM.XmlFileWorker (dobaviteljev XML), zaloge
    // pa PIM.StockFileWorker. Projekt ostane v resitvi kot zgodovina, ne kot nacrt.
    _logger.LogInformation("F0 worker skelet je zagnan; je arhiv in ne dela nicesar. Zajem opravljata PIM.KatalogWorker in PIM.XmlFileWorker.");
    await Task.Delay(Timeout.InfiniteTimeSpan, stoppingToken);
  }
}
