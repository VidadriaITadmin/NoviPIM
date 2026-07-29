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
    _logger.LogInformation("F0 worker skelet je zagnan; zajem virov še ni del te faze.");
    await Task.Delay(Timeout.InfiniteTimeSpan, stoppingToken);
  }
}
