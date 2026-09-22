using System.Text;
using System.Text.Json;
using Anthropic;
using Anthropic.Models.Messages;

namespace PIM.Intranet.Services;

/// <summary>Eno ERP besedilo (naziv, opis) kot vhod za AI.</summary>
public sealed record AiText(string TextType, string Language, string Value);
public sealed record AiCategory(string WebSite, string CategoryPath);
public sealed record AiAttribute(string Name, string Value);

/// <summary>Vse, kar AI sme vedeti o artiklu: samo podatki iz PIM-a, nic izmisljenega.</summary>
public sealed record AiWebTextRequest(
  string ItemId, string? Ean, string? Manufacturer, string? Supplier,
  IReadOnlyList<AiText> ErpTexts, IReadOnlyList<AiCategory> Categories, IReadOnlyList<AiAttribute> Attributes,
  IReadOnlyList<AiText> ExistingWebTexts, string TargetLanguage);

/// <param name="Model">Model, ki je besedilo napisal — v sporocilu uporabniku, da ve, od kod predlog.</param>
public sealed record AiWebTextSuggestion(string Language, string Title, string Description, string Model);

/// <summary>
/// Predlog spletnega naziva in opisa iz ERP podatkov artikla (uporabnik 2026-09-21: »potem moramo
/// pa nekako AI vklopiti, da bo sam zgeneriral opise in nazive za artikle«).
///
/// Klice Claude prek uradnega SDK. Kljuc pride iz nastavitve <c>Ai:ApiKey</c> (appsettings.Local.json,
/// ki ne gre v repozitorij) ali okoljske spremenljivke ANTHROPIC_API_KEY; brez kljuca servis ni
/// nastavljen in kartica gumb onemogoci z navodilom. Predlog nikoli ne gre naravnost v bazo: kartica
/// ga vpise v osnutek, urednik ga prebere in shrani z istim gumbom kot rocno spremembo.
/// </summary>
public sealed class AiTextService(IConfiguration configuration, ILogger<AiTextService> logger)
{
  public const string DefaultModel = "claude-opus-5";

  string? ApiKey =>
    FirstNonEmpty(configuration["Ai:ApiKey"], Environment.GetEnvironmentVariable("ANTHROPIC_API_KEY"));

  public string Model => FirstNonEmpty(configuration["Ai:Model"], null) ?? DefaultModel;

  public bool IsConfigured => ApiKey is not null;

  public string ConfigurationHint =>
    "AI ni nastavljen. V appsettings.Local.json ob intranetu dodaj \"Ai\": { \"ApiKey\": \"sk-ant-…\" } " +
    "(ali nastavi okoljsko spremenljivko ANTHROPIC_API_KEY) in znova zaženi intranet. Neobvezno: \"Ai\": { \"Model\": \"" + DefaultModel + "\", \"Effort\": \"medium\" }.";

  public async Task<AiWebTextSuggestion> SuggestWebTextsAsync(AiWebTextRequest request, CancellationToken cancellationToken = default)
  {
    if (!IsConfigured) throw new InvalidOperationException(ConfigurationHint);
    if (request.ErpTexts.Count == 0 && request.Attributes.Count == 0)
      throw new InvalidOperationException("Artikel nima ERP nazivov, opisov ali atributov — AI ne bi imel iz česa pisati.");

    var client = new AnthropicClient { ApiKey = ApiKey };
    var parameters = new MessageCreateParams
    {
      Model = Model,
      MaxTokens = 4096,
      System = SystemPrompt,
      OutputConfig = new OutputConfig { Effort = EffortSetting() },
      Messages = [new() { Role = Role.User, Content = BuildUserPrompt(request) }],
    };

    Message response;
    try { response = await client.Messages.Create(parameters, cancellationToken: cancellationToken); }
    catch (Exception exception) when (exception is not OperationCanceledException)
    {
      logger.LogWarning(exception, "AI predlog za artikel {ItemId} ni uspel.", request.ItemId);
      throw new InvalidOperationException($"Klic AI ni uspel: {exception.Message}", exception);
    }

    if (response.StopReason == "refusal")
      throw new InvalidOperationException("AI je zahtevo zavrnil (refusal). Preveri vhodne podatke artikla.");

    var text = string.Concat(response.Content.Select(block => block.Value).OfType<TextBlock>().Select(block => block.Text));
    var (title, description) = ParseSuggestion(text);
    return new AiWebTextSuggestion(request.TargetLanguage, title, description, Model);
  }

  Effort EffortSetting() => (configuration["Ai:Effort"] ?? "medium").Trim().ToLowerInvariant() switch
  {
    "low" => Effort.Low,
    "high" => Effort.High,
    "max" => Effort.Max,
    _ => Effort.Medium,
  };

  const string SystemPrompt =
    "Si urednik spletne trgovine s svetili in elektromaterialom (svetila.si, videlektro.si). " +
    "Iz ERP podatkov artikla napišeš prodajni spletni naziv in spletni opis v zahtevanem jeziku.\n" +
    "Pravila:\n" +
    "- Uporabi samo podatke, ki so navedeni. Ne izmišljaj lastnosti, številk, certifikatov ali uporabe, ki je podatki ne podpirajo.\n" +
    "- Naziv: do 80 znakov, brez šifre artikla in EAN, brez velikih tiskanih črk za cele besede, brez klicajev.\n" +
    "- Opis: 60 do 140 besed v enem ali dveh odstavkih navadnega besedila (brez HTML, brez alinej, brez naslovov). " +
    "Ne opisuj embalaže in ne ponavljaj naziva dobesedno. Brez superlativov brez podlage.\n" +
    "- Piši v zahtevanem jeziku (koda ISO 639-1), naravno in slovnično pravilno.\n" +
    "- Če obstajajo spletna besedila v drugih jezikih, ohrani isti pomen in ton.\n" +
    "Vrni SAMO veljaven JSON brez dodatnega besedila in brez oznak kode: {\"title\": \"...\", \"description\": \"...\"}";

  /// <summary>Vhod je izrecno naveden vrstico za vrstico, da model ne ugiba, kaj je kaj.</summary>
  static string BuildUserPrompt(AiWebTextRequest request)
  {
    var builder = new StringBuilder();
    builder.AppendLine($"Ciljni jezik: {request.TargetLanguage}");
    builder.AppendLine($"Šifra artikla: {request.ItemId}");
    if (!string.IsNullOrWhiteSpace(request.Ean)) builder.AppendLine($"EAN: {request.Ean}");
    if (!string.IsNullOrWhiteSpace(request.Manufacturer)) builder.AppendLine($"Proizvajalec: {request.Manufacturer}");
    if (!string.IsNullOrWhiteSpace(request.Supplier)) builder.AppendLine($"Dobavitelj: {request.Supplier}");

    if (request.Categories.Count > 0)
    {
      builder.AppendLine("Kategorije:");
      foreach (var category in request.Categories) builder.AppendLine($"- {category.WebSite}: {category.CategoryPath}");
    }

    if (request.ErpTexts.Count > 0)
    {
      builder.AppendLine("ERP besedila (vir: SAOP):");
      foreach (var text in request.ErpTexts.OrderBy(text => text.TextType, StringComparer.Ordinal).ThenBy(text => text.Language, StringComparer.Ordinal))
        builder.AppendLine($"- {ProductFieldLabels.TextTypeLabel(text.TextType)} [{text.Language}]: {Trim(text.Value, 1500)}");
    }

    if (request.Attributes.Count > 0)
    {
      builder.AppendLine("Atributi:");
      foreach (var attribute in request.Attributes.OrderBy(attribute => attribute.Name, StringComparer.CurrentCulture))
        builder.AppendLine($"- {attribute.Name}: {Trim(attribute.Value, 200)}");
    }

    if (request.ExistingWebTexts.Count > 0)
    {
      builder.AppendLine("Obstoječa spletna besedila v drugih jezikih (za pomen in ton, ne prevajaj dobesedno):");
      foreach (var text in request.ExistingWebTexts.OrderBy(text => text.TextType, StringComparer.Ordinal).ThenBy(text => text.Language, StringComparer.Ordinal))
        builder.AppendLine($"- {ProductFieldLabels.TextTypeLabel(text.TextType)} [{text.Language}]: {Trim(text.Value, 1500)}");
    }

    builder.AppendLine();
    builder.AppendLine($"Napiši spletni naziv in spletni opis v jeziku »{request.TargetLanguage}« in vrni JSON.");
    return builder.ToString();
  }

  /// <summary>Model vrne JSON; ce ga obda s kakim stavkom ali oznako kode, vzamemo prvi objekt.</summary>
  static (string Title, string Description) ParseSuggestion(string text)
  {
    var start = text.IndexOf('{');
    var end = text.LastIndexOf('}');
    if (start < 0 || end <= start)
      throw new InvalidOperationException("AI ni vrnil pričakovanega JSON odgovora: " + Trim(text, 200));
    try
    {
      using var document = JsonDocument.Parse(text[start..(end + 1)]);
      var root = document.RootElement;
      var title = root.TryGetProperty("title", out var titleElement) ? titleElement.GetString()?.Trim() : null;
      var description = root.TryGetProperty("description", out var descriptionElement) ? descriptionElement.GetString()?.Trim() : null;
      if (string.IsNullOrWhiteSpace(title) || string.IsNullOrWhiteSpace(description))
        throw new InvalidOperationException("AI je vrnil prazen naziv ali opis.");
      return (title, description);
    }
    catch (JsonException exception)
    {
      throw new InvalidOperationException("AI odgovora ni bilo mogoče prebrati kot JSON: " + Trim(text, 200), exception);
    }
  }

  static string Trim(string value, int max) => value.Length <= max ? value : value[..max] + " …";

  static string? FirstNonEmpty(string? first, string? second) =>
    !string.IsNullOrWhiteSpace(first) ? first.Trim() : !string.IsNullOrWhiteSpace(second) ? second.Trim() : null;
}
