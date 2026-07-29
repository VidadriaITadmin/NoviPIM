using PIM.FoundationWorker;

var builder = Host.CreateApplicationBuilder(args);
builder.Configuration.AddJsonFile("appsettings.Local.json", optional: true, reloadOnChange: false);
builder.Services.AddHostedService<Worker>();

var host = builder.Build();
host.Run();
