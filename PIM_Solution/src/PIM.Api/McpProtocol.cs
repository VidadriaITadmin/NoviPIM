using System.Text.Json;
using System.Text.Json.Nodes;

namespace PIM.Api;

/// <summary>Izid orodja MCP: besedilo (JSON odgovora ali opis napake) in ali je napaka.</summary>
public sealed record McpToolResult(string Text, bool IsError);

/// <summary>Odgovor na sporočilo MCP: HTTP status in telo (null = brez telesa, npr. 202 za obvestilo).</summary>
public sealed record McpReply(int Status, JsonObject? Body);

/// <summary>Izvede končno točko kataloga z argumenti orodja (bere bazo prek QueryRunner).</summary>
public delegate Task<McpToolResult> McpToolRunner(EndpointDef endpoint, Dictionary<string, string?> input, CancellationToken cancellationToken);

/// <summary>
/// MCP (Model Context Protocol) prek HTTP brez seje, ločen od ASP.NET in baze, da ga test F12 preveri brez strežnika:
/// initialize, ping, tools/list (samo orodja iz področij ključa, vsa samo za branje), tools/call. Branje baze
/// dobi od klicatelja (<see cref="McpToolRunner"/>), zato ta razred sam ne more nič spremeniti.
/// </summary>
public static class McpProtocol
{
  /// <summary>Različice protokola, ki jih strežnik sprejme; prva je privzeta.</summary>
  public static readonly string[] SupportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"];

  public const int ParseError = -32700;
  public const int InvalidRequest = -32600;
  public const int MethodNotFound = -32601;
  public const int InvalidParams = -32602;

  /// <summary>Razčleni telo zahtevka in odgovori. Neveljaven JSON = 400 z napako -32700.</summary>
  public static async Task<McpReply> HandleAsync(Stream body, Func<string, bool> hasScope, string instructions,
    McpToolRunner runTool, CancellationToken cancellationToken)
  {
    JsonNode? message;
    try { message = await JsonNode.ParseAsync(body, cancellationToken: cancellationToken); }
    catch (JsonException) { return new(400, RpcError(null, ParseError, "Neveljaven JSON.")); }
    return await HandleAsync(message, hasScope, instructions, runTool, cancellationToken);
  }

  public static async Task<McpReply> HandleAsync(JsonNode? message, Func<string, bool> hasScope, string instructions,
    McpToolRunner runTool, CancellationToken cancellationToken)
  {
    // Paketov (JSON seznam) MCP 2025-06-18 ne predvideva več; vse, kar ni en objekt, je neveljaven zahtevek.
    if (message is not JsonObject request)
      return new(400, RpcError(null, InvalidRequest, "Zahtevek mora biti en objekt JSON-RPC 2.0."));

    var id = request["id"]?.DeepClone();
    var method = Text(request["method"]);
    if (id is null) return new(202, null); // obvestilo (npr. notifications/initialized) nima odgovora
    if (method is null) return new(200, RpcError(id, InvalidRequest, "Manjka method."));

    switch (method)
    {
      case "initialize":
        var requestedVersion = Text(request["params"]?["protocolVersion"]);
        return new(200, RpcResult(id, new JsonObject
        {
          ["protocolVersion"] = requestedVersion is not null && SupportedVersions.Contains(requestedVersion) ? requestedVersion : SupportedVersions[0],
          ["capabilities"] = new JsonObject { ["tools"] = new JsonObject { ["listChanged"] = false } },
          ["serverInfo"] = new JsonObject { ["name"] = "pim-api", ["version"] = Catalog.Version },
          ["instructions"] = instructions,
        }));

      case "ping":
        return new(200, RpcResult(id, new JsonObject()));

      case "tools/list":
        var tools = new JsonArray();
        foreach (var endpoint in Catalog.Endpoints.Where(e => hasScope(e.Scope)))
          tools.Add(new JsonObject
          {
            ["name"] = endpoint.Tool,
            ["title"] = endpoint.Summary,
            ["description"] = endpoint.Description,
            ["inputSchema"] = ApiDocs.InputSchema(endpoint),
            ["annotations"] = new JsonObject { ["readOnlyHint"] = true, ["openWorldHint"] = false },
          });
        return new(200, RpcResult(id, new JsonObject { ["tools"] = tools }));

      case "tools/call":
        var name = Text(request["params"]?["name"]) ?? "";
        var endpointForTool = Catalog.ByTool(name);
        if (endpointForTool is null) return new(200, RpcError(id, InvalidParams, $"Neznano orodje: {name}."));
        // Področje ključa preveri QueryRunner (napaka »Ključ nima področja …« kot isError, ne kot napaka protokola).
        var arguments = request["params"]?["arguments"] as JsonObject ?? new JsonObject();
        var input = arguments.ToDictionary(pair => pair.Key, pair => pair.Value switch
        {
          null => null,
          JsonValue value when value.TryGetValue<string>(out var text) => text,
          var other => other.ToJsonString(),
        }, StringComparer.OrdinalIgnoreCase);
        var result = await runTool(endpointForTool, input, cancellationToken);
        return new(200, RpcResult(id, ToolText(result.Text, result.IsError)));

      default:
        return new(200, RpcError(id, MethodNotFound, $"Metoda ni podprta: {method}."));
    }
  }

  static string? Text(JsonNode? node) =>
    node is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;

  static JsonObject RpcResult(JsonNode id, JsonNode result) => new() { ["jsonrpc"] = "2.0", ["id"] = id, ["result"] = result };

  static JsonObject RpcError(JsonNode? id, int code, string text) => new()
    { ["jsonrpc"] = "2.0", ["id"] = id?.DeepClone(), ["error"] = new JsonObject { ["code"] = code, ["message"] = text } };

  static JsonObject ToolText(string text, bool isError) => new()
    { ["content"] = new JsonArray(new JsonObject { ["type"] = "text", ["text"] = text }), ["isError"] = isError };
}
