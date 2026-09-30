using System.Text;
using System.Text.Json.Nodes;

namespace PIM.Api;

/// <summary>Opis API-ja iz <see cref="Catalog"/>: OpenAPI 3.0 (za orodja in GPT akcije) in navodila za AI.</summary>
public static class ApiDocs
{
  public static JsonObject OpenApi(string baseUrl)
  {
    var paths = new JsonObject();
    foreach (var endpoint in Catalog.Endpoints)
    {
      var parameters = new JsonArray();
      foreach (var parameter in Catalog.AllParams(endpoint))
        parameters.Add(new JsonObject
        {
          ["name"] = parameter.Name,
          ["in"] = "query",
          ["required"] = parameter.Required,
          ["description"] = parameter.Description,
          ["schema"] = Schema(parameter),
        });
      if (endpoint.Kind != EndpointKind.Detail)
        parameters.Add(new JsonObject
        {
          ["name"] = "format", ["in"] = "query", ["required"] = false,
          ["description"] = "json (privzeto) ali csv (za Excel: podpičje, decimalna vejica, UTF-8).",
          ["schema"] = new JsonObject { ["type"] = "string", ["enum"] = new JsonArray("json", "csv") },
        });

      paths[endpoint.Path] = new JsonObject
      {
        ["get"] = new JsonObject
        {
          ["operationId"] = endpoint.Tool,
          ["summary"] = endpoint.Summary,
          ["description"] = endpoint.Description + (endpoint.Scope.Length > 0 ? $" Področje ključa: {endpoint.Scope}." : ""),
          ["tags"] = new JsonArray(endpoint.Scope.Length > 0 ? endpoint.Scope : "splošno"),
          ["parameters"] = parameters,
          ["responses"] = new JsonObject
          {
            ["200"] = new JsonObject
            {
              ["description"] = endpoint.Kind switch
              {
                EndpointKind.Paged => "{ organizationId, total, skip, count, hasMore, items: [...] }",
                EndpointKind.Rows => "{ organizationId, count, items: [...] }",
                _ => "{ organizationId, " + string.Join(", ", (endpoint.Sets ?? []).Select(s => s.Name)) + " }",
              },
              ["content"] = new JsonObject { ["application/json"] = new JsonObject { ["schema"] = new JsonObject { ["type"] = "object" } } },
            },
            ["400"] = new JsonObject { ["description"] = "Napačni parametri (seznam v details)." },
            ["401"] = new JsonObject { ["description"] = "Manjka ali napačen ključ." },
            ["403"] = new JsonObject { ["description"] = "Ključ nima področja ali podjetja." },
            ["404"] = new JsonObject { ["description"] = "Ni najdeno." },
            ["429"] = new JsonObject { ["description"] = "Preveč klicev na minuto." },
          },
        },
      };
    }

    return new JsonObject
    {
      ["openapi"] = "3.0.3",
      ["info"] = new JsonObject
      {
        ["title"] = "PIM bralni API (ViD Adria)",
        ["version"] = Catalog.Version,
        ["description"] = "Samo branje: izdelki, cene, zaloga, stranke, naročila dobaviteljem in analitika iz PIM. Ključ v glavi X-Api-Key. Navodila: /api/v1/guide.",
      },
      ["servers"] = new JsonArray(new JsonObject { ["url"] = baseUrl }),
      ["security"] = new JsonArray(new JsonObject { ["ApiKey"] = new JsonArray() }),
      ["components"] = new JsonObject
      {
        ["securitySchemes"] = new JsonObject
        {
          ["ApiKey"] = new JsonObject { ["type"] = "apiKey", ["in"] = "header", ["name"] = ClientAccess.KeyHeader },
        },
      },
      ["paths"] = paths,
    };
  }

  /// <summary>JSON Schema vhodov orodja MCP.</summary>
  public static JsonObject InputSchema(EndpointDef endpoint)
  {
    var properties = new JsonObject();
    var required = new JsonArray();
    foreach (var parameter in Catalog.AllParams(endpoint))
    {
      var schema = Schema(parameter);
      schema["description"] = parameter.Description;
      properties[parameter.Name] = schema;
      if (parameter.Required) required.Add(parameter.Name);
    }
    var result = new JsonObject { ["type"] = "object", ["properties"] = properties };
    if (required.Count > 0) result["required"] = required;
    return result;
  }

  static JsonObject Schema(ParamDef parameter)
  {
    var schema = parameter.Type switch
    {
      ParamType.Int => new JsonObject { ["type"] = "integer" },
      ParamType.Bool => new JsonObject { ["type"] = "boolean" },
      ParamType.Decimal => new JsonObject { ["type"] = "number" },
      ParamType.Date => new JsonObject { ["type"] = "string", ["format"] = "date" },
      ParamType.DateTime => new JsonObject { ["type"] = "string", ["format"] = "date-time" },
      _ => new JsonObject { ["type"] = "string" },
    };
    if (parameter.Values is { } values) schema["enum"] = new JsonArray(values.Select(v => (JsonNode)v!).ToArray());
    return schema;
  }

  /// <summary>Navodila za AI (Markdown): kaj je v podatkih, kako jih brati, pasti.</summary>
  public static string Guide(string baseUrl)
  {
    var text = new StringBuilder();
    text.AppendLine("# PIM bralni API — navodila za AI");
    text.AppendLine();
    text.AppendLine("Podatki ViD Adrie iz PIM (izvor: ERP SAOP in katalogi dobaviteljev). API samo bere; nič ne more spremeniti.");
    text.AppendLine();
    text.AppendLine("## Pravila");
    text.AppendLine($"- Vsak klic nosi ključ v glavi `{ClientAccess.KeyHeader}: pim_...` (ali `Authorization: Bearer pim_...`).");
    text.AppendLine("- Podatki so ločeni po podjetjih. Vsak klic potrebuje `organizationId`; številke in imena podjetij, ki jih ključ sme brati, vrne `/api/v1/organizations` (pokliči ga najprej). Ne seštevaj podjetij, razen če uporabnik to izrecno želi — ista šifra artikla je lahko v več podjetjih z različno zalogo in cenami.");
    text.AppendLine("- Pred poročilom pokliči `/api/v1/freshness` in povej, kako stari so podatki (zaloga se osvežuje večkrat na dan; če je starejša od 24 ur, to omeni).");
    text.AppendLine("- Seznami so listani: `skip`, `take`; odgovor ima `total` in `hasMore`. Za popoln seznam listaj, dokler `hasMore` ni false.");
    text.AppendLine("- Cene so brez DDV (`netPrice`), `grossPrice` je z DDV. Valuta je EUR.");
    text.AppendLine("- Ceniki: B2C = maloprodajni, B2B = veleprodajni, NAB = nabavni (osnova za vrednost zaloge in maržo), PRC = prevzemni, ostali so ceniki dobaviteljev. Seznam: `/api/v1/prices/lists`.");
    text.AppendLine("- Zaloga: `erpQuantity` = lastna trenutna zaloga v SAOP, `erpCustomerOrdered` = rezervirano za kupce, `erpAvailable` = razpoložljivo, `erpSupplierOrdered` = naročeno pri dobaviteljih, `supplierQuantity` = zaloga pri dobavitelju (Nowodvorski, Braytron), ne naša. `minimumStock`/`maximumStock` sta iz SAOP.");
    text.AppendLine("- Šifre dobaviteljev in proizvajalcev dobiš z `/api/v1/partners` (iskanje po imenu).");
    text.AppendLine("- Iskanje (`search`) ne loči šumnikov in velikih črk; več besed pomeni, da morajo biti najdene vse.");
    text.AppendLine("- Kakovost podatkov: `validationStatus` in `completeness` v iskanju sta shranjeno stanje zadnje validacije in sta lahko zastarela (PENDING = še ni preverjeno, ne pomeni napake). Merodajen je nabor `validation` na kartici izdelka (`/api/v1/products/detail`); ko govoriš o napakah izdelka, se opri nanj.");
    text.AppendLine("- Za Excel dodaj `format=csv` (podpičje, decimalna vejica).");
    text.AppendLine("- Napaka 400 v `details` pove, kateri parameter je napačen in kateri so dovoljeni.");
    text.AppendLine();
    text.AppendLine("## Končne točke");
    foreach (var endpoint in Catalog.Endpoints)
    {
      text.AppendLine();
      text.AppendLine($"### GET {baseUrl}{endpoint.Path}  (orodje MCP: `{endpoint.Tool}`{(endpoint.Scope.Length > 0 ? $", področje: {endpoint.Scope}" : "")})");
      text.AppendLine(endpoint.Description);
      foreach (var parameter in Catalog.AllParams(endpoint))
        text.AppendLine($"- `{parameter.Name}`{(parameter.Required ? " (obvezno)" : "")}: {parameter.Description}");
    }
    text.AppendLine();
    text.AppendLine("## Primeri vprašanj in klicev");
    text.AppendLine("- »Koliko je vredna zaloga Vidadrie po dobaviteljih?« → `/api/v1/stock/summary?organizationId=3&groupBy=dobavitelj`");
    text.AppendLine("- »Kateri artikli so pod minimalno zalogo?« → `/api/v1/stock?organizationId=3&belowMinimum=true`");
    text.AppendLine("- »Katere cene so se ta mesec spremenile v B2C?« → `/api/v1/prices?organizationId=3&priceList=B2C&changedSince=2026-09-01`");
    text.AppendLine("- »Kje je marža prenizka?« → `/api/v1/prices/comparison?organizationId=3&belowThreshold=true`");
    text.AppendLine("- »Kdaj pride roba od dobavitelja X?« → `/api/v1/partners?organizationId=3&search=X`, nato `/api/v1/purchase-orders?organizationId=3&supplier=<šifra>`");
    text.AppendLine("- »Vse o artiklu BA.BA13.00921« → `/api/v1/products/detail?organizationId=3&itemId=BA.BA13.00921`");
    return text.ToString();
  }
}
