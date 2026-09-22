using Microsoft.Extensions.Hosting.WindowsServices;
using PIM.AutomationHost;
using PIM.Operations;

/*
  PIM.AutomationHost — gostitelj avtomatike (migracija 237).

  Uporabnik 2026-09-21: »IIS naj bo nadzorna konzola, ne motor avtomatike.« Ta program je motor: en
  dolgoživ proces, ki drži najem v ops.SchedulerLease (s prednostjo pred intranetom), vsakih nekaj
  sekund pogleda, kateri posel iz ops.JobDefinition je na vrsti, ga prevzame (ops.ClaimJobRun) in
  požene — worker kot otroški proces (objavljen .exe ali dotnet run --no-build), validacijo in objavo
  kot SQL. Vsak zagon utripa, ima časovno mejo in vedno konča v enem od stanj Succeeded, Failed,
  TimedOut, Cancelled, Abandoned ali Blocked.

  Vloge istega programa:
    PIM.AutomationHost.exe                     storitev (New-Service; deploy\Install-AutomationHost.ps1) ali konzola
    PIM.AutomationHost.exe --preveri           zunanji nadzor: utrip gostitelja; ob molku odpre alarm
                                               AutomationHostDown in požene razpošiljalca (Windows naloga
                                               scripts\Namesti-nadzor-avtomatike.ps1, vsakih 5 minut)
    PIM.AutomationHost.exe --enkrat <POSEL>    en zagon posla zdaj (spoštuje vrata odvisnosti), nato izhod:
                                               0 uspeh, 1 padec, 3 blokiran, 4 ni bil pognan
    PIM.AutomationHost.exe --posli A,B         samo našteti posli (preizkus)
    PIM.AutomationHost.exe --samo-nadzor       najem, čiščenje visečih zagonov in alarmi, brez zagona poslov

  Nastavitve: Automation:* v appsettings.json ob programu, appsettings.Local.json (povezava, isti viri
  kot workerji: LocalSettings.Sources) in okolje PIM_CONNECTION_STRING.
*/

var mode = HostArguments.Parse(args);
if (mode.ShowHelp)
{
  Console.WriteLine(HostArguments.Help);
  return 0;
}

var connectionString = LocalSettings.ConnectionString();
if (string.IsNullOrWhiteSpace(connectionString))
{
  Console.Error.WriteLine(LocalSettings.MissingConnectionMessage());
  return 2;
}

if (mode.Check)
  return await HostCheck.RunAsync(connectionString, mode.CheckStaleMinutes, mode.DispatchAlerts);

var builder = Host.CreateApplicationBuilder(new HostApplicationBuilderSettings
{
  Args = mode.HostArgs,
  ContentRootPath = AppContext.BaseDirectory,
});
foreach (var path in LocalSettings.Sources(AppContext.BaseDirectory))
  builder.Configuration.AddJsonFile(path, optional: true, reloadOnChange: false);

builder.Services.AddWindowsService(options => options.ServiceName = "PIM.AutomationHost");
builder.Services.AddSingleton(mode);
builder.Services.AddSingleton(new HostConnection(connectionString, WindowsServiceHelpers.IsWindowsService()));
builder.Services.AddHostedService<AutomationHostService>();

using var host = builder.Build();
await host.RunAsync();
return Environment.ExitCode;

namespace PIM.AutomationHost
{
  public sealed record HostConnection(string ConnectionString, bool IsWindowsService);
}
