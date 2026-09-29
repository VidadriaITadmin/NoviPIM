using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading.RateLimiting;
using Microsoft.Data.SqlClient;
using PIM.Api;

// Skrbniški ukazi (ključi odjemalcev) tečejo brez spletnega strežnika: PIM.Api.exe odjemalec ...
if (args.Length > 0 && string.Equals(args[0], "odjemalec", StringComparison.OrdinalIgnoreCase))
  return await ClientCli.RunAsync(args[1..]);

var builder = WebApplication.CreateBuilder(args);
ApiSettings.AddLocalFiles(builder.Configuration, builder.Environment.ContentRootPath);
var settings = ApiSettings.Load(builder.Configuration);

builder.Services.AddSingleton(settings);
builder.Services.AddMemoryCache();
builder.Services.AddSingleton<ClientAccess>();
builder.Services.AddSingleton<QueryRunner>();
builder.Services.AddHostedService<RequestLogCleanup>();
builder.Services.ConfigureHttpJsonOptions(options =>
{
  options.SerializerOptions.PropertyNamingPolicy = JsonNamingPolicy.CamelCase;
  options.SerializerOptions.Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping;
});
builder.Services.AddRateLimiter(options =>
{
  options.RejectionStatusCode = StatusCodes.Status429TooManyRequests;
  options.GlobalLimiter = PartitionedRateLimiter.Create<HttpContext, string>(context =>
    context.Items["client"] is ApiClient client
      ? RateLimitPartition.GetFixedWindowLimiter("c" + client.ClientId, _ => new FixedWindowRateLimiterOptions
        { PermitLimit = client.RequestsPerMinute, Window = TimeSpan.FromMinutes(1), QueueLimit = 0 })
      : RateLimitPartition.GetNoLimiter("anonymous"));
  options.OnRejected = (rejected, _) =>
  {
    rejected.HttpContext.Response.Headers.RetryAfter = "60";
    return new ValueTask(WriteError(rejected.HttpContext, 429, "Preveč klicev na minuto za ta ključ. Počakaj minuto."));
  };
});

var app = builder.Build();
// Šumniki in znaki kot > ostanejo berljivi (AI bere surov JSON); odgovor je vedno application/json, ne HTML.
var json = new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };
string BaseUrl(HttpRequest request) => settings.PublicBaseUrl ?? $"{request.Scheme}://{request.Host}{request.PathBase}";
string[] anonymousPaths = ["/", "/health", "/openapi.json", "/api/v1/guide"];

// 1) Omejitev omrežja, dnevnik in prijava s ključem.
app.Use(async (context, next) =>
{
  var access = context.RequestServices.GetRequiredService<ClientAccess>();
  var started = Stopwatch.StartNew();
  var requestUtc = DateTime.UtcNow;
  var remote = context.Connection.RemoteIpAddress;

  context.Response.OnCompleted(async () =>
  {
    if (context.Request.Path.StartsWithSegments("/health")) return;
    try
    {
      await access.LogAsync((context.Items["client"] as ApiClient)?.ClientId, requestUtc, context.Request.Method,
        context.Request.Path.Value ?? "/", context.Request.QueryString.HasValue ? context.Request.QueryString.Value : null,
        context.Items["org"] as int?, context.Response.StatusCode, (int)started.ElapsedMilliseconds, context.Items["rows"] as int?, remote?.ToString());
    }
    catch (Exception exception)
    {
      app.Logger.LogWarning(exception, "Zapis klica v api.RequestLog ni uspel.");
    }
  });

  if (!settings.IsAllowed(remote))
  {
    await WriteError(context, 403, "Klic iz tega omrežja ni dovoljen (Api:AllowedRemoteIps).");
    return;
  }

  var path = context.Request.Path.Value?.TrimEnd('/') ?? "";
  if (anonymousPaths.Contains(path == "" ? "/" : path, StringComparer.OrdinalIgnoreCase))
  {
    await next();
    return;
  }

  var key = ClientAccess.ReadKey(context.Request);
  ApiClient? client = null;
  if (!string.IsNullOrEmpty(key))
  {
    try { client = await access.AuthenticateAsync(key, remote?.ToString(), context.RequestAborted); }
    catch (SqlException exception)
    {
      app.Logger.LogError(exception, "Prijava ključa ni uspela (baza).");
      await WriteError(context, 503, "Baza trenutno ni dosegljiva.");
      return;
    }
  }
  if (client is null)
  {
    await Task.Delay(300);
    context.Response.Headers.WWWAuthenticate = "ApiKey header=\"X-Api-Key\"";
    await WriteError(context, 401, string.IsNullOrEmpty(key)
      ? "Manjka ključ. Pošlji ga v glavi X-Api-Key."
      : "Ključ ni veljaven, je potekel ali je bil preklican.");
    return;
  }

  context.Items["client"] = client;
  await next();
});
app.UseRateLimiter();

// 2) Javne poti: opis in zdravje.
app.MapGet("/", (HttpRequest request) => Results.Json(new
{
  name = "PIM bralni API",
  version = Catalog.Version,
  guide = BaseUrl(request) + "/api/v1/guide",
  openApi = BaseUrl(request) + "/openapi.json",
  mcp = BaseUrl(request) + "/mcp",
  auth = "Glava X-Api-Key: pim_...",
}));
app.MapGet("/health", async (CancellationToken cancellationToken) =>
{
  try
  {
    await using var connection = new SqlConnection(settings.ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("SELECT 1", connection);
    await command.ExecuteScalarAsync(cancellationToken);
    return Results.Json(new { status = "ok", database = "ok", utc = DateTime.UtcNow });
  }
  catch (Exception exception)
  {
    app.Logger.LogError(exception, "Zdravje: baza ni dosegljiva.");
    return Results.Json(new { status = "napaka", database = "ni dosegljiva" }, statusCode: 503);
  }
});
app.MapGet("/openapi.json", (HttpRequest request) => Results.Text(ApiDocs.OpenApi(BaseUrl(request)).ToJsonString(json), "application/json", Encoding.UTF8));
app.MapGet("/api/v1/guide", (HttpRequest request) => Results.Text(ApiDocs.Guide(BaseUrl(request)), "text/markdown; charset=utf-8", Encoding.UTF8));

app.MapGet("/api/v1", async (HttpContext context) =>
{
  var client = (ApiClient)context.Items["client"]!;
  var access = context.RequestServices.GetRequiredService<ClientAccess>();
  var organizations = await access.AllowedOrganizationsAsync(client, context.RequestAborted);
  return Results.Json(new
  {
    client = client.Name,
    organizations,
    scopes = client.Scopes.Order(),
    requestsPerMinute = client.RequestsPerMinute,
    endpoints = Catalog.Endpoints.Where(e => client.HasScope(e.Scope)).Select(e => new { path = e.Path, e.Summary }),
  });
});

// 3) Bralne končne točke iz kataloga.
foreach (var endpoint in Catalog.Endpoints)
{
  var definition = endpoint;
  app.MapGet(definition.Path, async (HttpContext context) =>
  {
    var client = (ApiClient)context.Items["client"]!;
    var runner = context.RequestServices.GetRequiredService<QueryRunner>();
    var input = context.Request.Query.ToDictionary(pair => pair.Key, pair => (string?)pair.Value.ToString(), StringComparer.OrdinalIgnoreCase);
    var format = input.Remove("format", out var requested) ? requested?.Trim().ToLowerInvariant() : null;
    if (format is not (null or "" or "json" or "csv"))
      return Error(400, "format mora biti json ali csv.");

    try
    {
      var result = await runner.RunAsync(definition, input, client, context.RequestAborted);
      context.Items["org"] = result.OrganizationId;
      context.Items["rows"] = result.Rows.Count;
      if (format == "csv" && definition.Kind != EndpointKind.Detail)
      {
        var name = $"PIM_{definition.Tool}_{result.OrganizationId}_{DateTime.Now:yyyyMMdd_HHmm}.csv";
        return Results.File(Csv(result.Rows), "text/csv; charset=utf-8", name);
      }
      return Results.Json(result.Body, json);
    }
    catch (ApiException exception) { return Error(exception.Status, exception.Message, exception.Details); }
    catch (SqlException exception)
    {
      app.Logger.LogError(exception, "Postopek {Procedure} ni uspel.", definition.Procedure);
      return Error(500, $"Branje iz baze ni uspelo ({context.TraceIdentifier}).");
    }
  });
}

// 4) MCP (Model Context Protocol, HTTP brez seje): Claude in drugi agenti vidijo končne točke kot orodja.
app.MapPost("/mcp", async (HttpContext context) =>
{
  var client = (ApiClient)context.Items["client"]!;
  var runner = context.RequestServices.GetRequiredService<QueryRunner>();
  JsonNode? message;
  try { message = await JsonNode.ParseAsync(context.Request.Body, cancellationToken: context.RequestAborted); }
  catch (JsonException) { return Results.Json(RpcError(null, -32700, "Neveljaven JSON."), statusCode: 400); }

  var id = message?["id"]?.DeepClone();
  var method = message?["method"]?.GetValue<string>();
  if (id is null) return Results.Accepted(); // obvestilo (npr. notifications/initialized)

  switch (method)
  {
    case "initialize":
      var requestedVersion = message?["params"]?["protocolVersion"]?.GetValue<string>();
      return Results.Json(RpcResult(id, new JsonObject
      {
        ["protocolVersion"] = requestedVersion is "2025-03-26" or "2025-06-18" or "2024-11-05" ? requestedVersion : "2025-06-18",
        ["capabilities"] = new JsonObject { ["tools"] = new JsonObject { ["listChanged"] = false } },
        ["serverInfo"] = new JsonObject { ["name"] = "pim-api", ["version"] = Catalog.Version },
        ["instructions"] = ApiDocs.Guide(BaseUrl(context.Request)),
      }));
    case "ping":
      return Results.Json(RpcResult(id, new JsonObject()));
    case "tools/list":
      var tools = new JsonArray();
      foreach (var endpoint in Catalog.Endpoints.Where(e => client.HasScope(e.Scope)))
        tools.Add(new JsonObject
        {
          ["name"] = endpoint.Tool,
          ["title"] = endpoint.Summary,
          ["description"] = endpoint.Description,
          ["inputSchema"] = ApiDocs.InputSchema(endpoint),
          ["annotations"] = new JsonObject { ["readOnlyHint"] = true, ["openWorldHint"] = false },
        });
      return Results.Json(RpcResult(id, new JsonObject { ["tools"] = tools }));
    case "tools/call":
      var name = message?["params"]?["name"]?.GetValue<string>() ?? "";
      var endpointForTool = Catalog.ByTool(name);
      if (endpointForTool is null) return Results.Json(RpcError(id, -32602, $"Neznano orodje: {name}."));
      var arguments = message?["params"]?["arguments"] as JsonObject ?? new JsonObject();
      var input = arguments.ToDictionary(pair => pair.Key, pair => pair.Value switch
      {
        null => null,
        JsonValue value when value.TryGetValue<string>(out var text) => text,
        var other => other.ToJsonString(),
      }, StringComparer.OrdinalIgnoreCase);
      try
      {
        var result = await runner.RunAsync(endpointForTool, input, client, context.RequestAborted);
        context.Items["org"] = result.OrganizationId;
        context.Items["rows"] = result.Rows.Count;
        return Results.Json(RpcResult(id, ToolText(JsonSerializer.Serialize(result.Body, json), false)));
      }
      catch (ApiException exception)
      {
        var text = exception.Message + (exception.Details.Count > 0 ? " " + string.Join(" ", exception.Details) : "");
        return Results.Json(RpcResult(id, ToolText(text, true)));
      }
      catch (SqlException exception)
      {
        app.Logger.LogError(exception, "Orodje {Tool} ni uspelo.", name);
        return Results.Json(RpcResult(id, ToolText("Branje iz baze ni uspelo.", true)));
      }
    default:
      return Results.Json(RpcError(id, -32601, $"Metoda ni podprta: {method}."));
  }
});
app.MapGet("/mcp", () => Results.StatusCode(StatusCodes.Status405MethodNotAllowed));

app.Run();
return 0;

static JsonObject RpcResult(JsonNode id, JsonNode result) => new() { ["jsonrpc"] = "2.0", ["id"] = id, ["result"] = result };
static JsonObject RpcError(JsonNode? id, int code, string text) => new()
  { ["jsonrpc"] = "2.0", ["id"] = id?.DeepClone(), ["error"] = new JsonObject { ["code"] = code, ["message"] = text } };
static JsonObject ToolText(string text, bool isError) => new()
  { ["content"] = new JsonArray(new JsonObject { ["type"] = "text", ["text"] = text }), ["isError"] = isError };

static IResult Error(int status, string message, IReadOnlyList<string>? details = null) =>
  Results.Json(new { status, error = message, details = details ?? [] }, statusCode: status);

static Task WriteError(HttpContext context, int status, string message)
{
  context.Response.StatusCode = status;
  return context.Response.WriteAsJsonAsync(new { status, error = message, details = Array.Empty<string>() });
}

/// <summary>CSV za Excel v slovenskih nastavitvah: podpičje, decimalna vejica, UTF-8 z BOM.</summary>
static byte[] Csv(IReadOnlyList<Dictionary<string, object?>> rows)
{
  var culture = CultureInfo.GetCultureInfo("sl-SI");
  var text = new StringBuilder();
  if (rows.Count > 0)
  {
    var columns = rows[0].Keys.ToArray();
    text.AppendLine(string.Join(';', columns.Select(Quote)));
    foreach (var row in rows)
      text.AppendLine(string.Join(';', columns.Select(column => Quote(row[column] switch
      {
        null => "",
        decimal number => number.ToString(culture),
        double number => number.ToString(culture),
        bool flag => flag ? "1" : "0",
        DateTime date => date.ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture),
        var value => Convert.ToString(value, culture) ?? "",
      }))));
  }
  return [.. Encoding.UTF8.GetPreamble(), .. Encoding.UTF8.GetBytes(text.ToString())];

  static string Quote(string value) =>
    value.IndexOfAny([';', '"', '\n', '\r']) >= 0 ? "\"" + value.Replace("\"", "\"\"") + "\"" : value;
}

/// <summary>Enkrat na dan pobriše dnevnik klicev, starejši od Api:RequestLogDays (privzeto 90 dni).</summary>
sealed class RequestLogCleanup(ApiSettings settings, ILogger<RequestLogCleanup> logger) : BackgroundService
{
  protected override async Task ExecuteAsync(CancellationToken stoppingToken)
  {
    while (!stoppingToken.IsCancellationRequested)
    {
      try
      {
        await using var connection = new SqlConnection(settings.ConnectionString);
        await connection.OpenAsync(stoppingToken);
        await using var command = new SqlCommand("api.PurgeRequestLog", connection) { CommandType = System.Data.CommandType.StoredProcedure };
        command.Parameters.AddWithValue("@KeepDays", settings.RequestLogDays);
        await command.ExecuteNonQueryAsync(stoppingToken);
      }
      catch (Exception exception) when (!stoppingToken.IsCancellationRequested)
      {
        logger.LogWarning(exception, "Čiščenje api.RequestLog ni uspelo.");
      }
      await Task.Delay(TimeSpan.FromHours(24), stoppingToken).ContinueWith(_ => { });
    }
  }
}
