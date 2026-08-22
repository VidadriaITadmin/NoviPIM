using PIM.OutboxDispatcher;

var connectionString = Environment.GetEnvironmentVariable("PIM_CONNECTION_STRING");
if (string.IsNullOrWhiteSpace(connectionString))
{
  Console.WriteLine("PIM_CONNECTION_STRING ni nastavljen; dispatcher ni izvedel nobenega HTTP klica.");
  return 0;
}

var workerId = $"{Environment.MachineName}:{Environment.ProcessId}";
using var http = new HttpClient();

var runner = new OutboxDispatchRunner(connectionString, workerId, async (message, cancellationToken) =>
{
  http.Timeout = TimeSpan.FromSeconds(message.TimeoutSeconds);
  return await new SaopOutboundHandler(http).SendAsync(
    new(new Uri(message.EndpointTemplate), message.HttpOperation, message.PayloadJson), cancellationToken);
});

var result = await runner.RunAsync();

if (result.ScheduleMissing)
{
  Console.Error.WriteLine($"Za pipeline {OutboxDispatchRunner.Pipeline} ni omogocenega razporeda v ops.ScheduleProfile; nobeno sporocilo ni bilo prevzeto.");
  return 1;
}

if (result.AlreadyRunning)
{
  // Prekrivanje nacrtovanega workerja s samim sabo ni napaka; prejsnji zagon se tece.
  Console.WriteLine($"Odhodna pot: prejsnji zagon se tece, ta se je umaknil.");
  return 0;
}

Console.WriteLine($"Odhodna pot: prevzeto {result.Claimed}, poslano {result.Sent}, neuspesno {result.Failed}.");
// Meja se izpise, da odrezana vrsta ne izgleda kot prazna.
if (result.Truncated) Console.WriteLine("Odhodna pot: dosezena meja sporocil na zagon; v vrsti je lahko se kaj.");
return 0;
