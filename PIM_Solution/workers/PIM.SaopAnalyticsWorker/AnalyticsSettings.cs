using System.Text.Json;
using PIM.Operations;

namespace PIM.SaopAnalyticsWorker;

/// <summary>Tokovi, ki jih worker bere iz SAOP. Imena so iste kode kot ana.StreamState.Stream.</summary>
public static class AnalyticsStreams
{
  /// <summary>Invoice/GetInvoices — dejanska prodaja (vrstice izdanih računov).</summary>
  public const string Invoices = "RACUNI";
  /// <summary>Barkawi/GetCO — naročila kupcev po vrsticah (naročeno / odpremljeno).</summary>
  public const string CustomerOrders = "NAROCILA_KUPCEV";
  /// <summary>Barkawi/GetPO — naročila dobaviteljem po vrsticah z datumom prevzema.</summary>
  public const string PurchaseOrders = "NAROCILA_DOBAVITELJEM";
  /// <summary>Barkawi/GetSKU — povprečna in zadnja nabavna cena, prednostni dobavitelj, večkratnik.</summary>
  public const string PurchaseInfo = "NABAVNI_PODATKI";

  public static IReadOnlyList<string> All { get; } = [Invoices, CustomerOrders, PurchaseOrders, PurchaseInfo];

  /// <summary>Koda vira v ops.JobPhaseRun (JobCatalog.Sources).</summary>
  public static string SourceCode(string stream) => "ANA_" + stream;

  public static string Label(string stream) => stream switch
  {
    Invoices => "Računi (prodaja)",
    CustomerOrders => "Naročila kupcev",
    PurchaseOrders => "Naročila dobaviteljem in prevzemi",
    PurchaseInfo => "Nabavni podatki artiklov",
    _ => stream,
  };
}

public sealed record AnalyticsOrganization(int Id, string Name, bool IsActive);

/// <summary>
/// Nastavitve: SAOP dostop iz iste sekcije "Saop" kot ostali SAOP workerji (ena poverilnica), parametri
/// analitike iz sekcije "Analitika" (vse neobvezno).
/// </summary>
public sealed record AnalyticsSettings
{
  public string BaseUrl { get; init; } = "";
  public string Username { get; init; } = "";
  public string Password { get; init; } = "";
  public bool AcceptUntrustedCertificate { get; init; }
  public int RetryMaxExtraAttempts { get; init; } = 3;
  public int RetryBaseDelayMilliseconds { get; init; } = 2000;

  /// <summary>Časovna meja enega klica. Računi za celo leto so en sam klic brez listanja, zato je meja visoka.</summary>
  public int TimeoutSeconds { get; init; } = 900;
  public int PageSize { get; init; } = 500;
  public int MaxPages { get; init; } = 2000;
  /// <summary>Prvi zajem (brez vodnega žiga): toliko mesecev nazaj.</summary>
  public int InitialBackfillMonths { get; init; } = 24;
  /// <summary>Prekrivanje delta zajema, da popravek v SAOP za nazaj ne uide.</summary>
  public int LookbackDays { get; init; } = 3;
  /// <summary>Obvezen parameter searchQuery.period za Barkawi/GetCO in GetPO (prvi zajem in --full).</summary>
  public int BarkawiBackfillPeriod { get; init; } = 24;
  /// <summary>Parameter period pri rednem (delta) zajemu Barkawi.</summary>
  public int BarkawiDeltaPeriod { get; init; } = 3;
  /// <summary>Največ klicev GetInvoice po računu, kadar seznam računov ne vsebuje vrstic.</summary>
  public int MaxInvoiceDetailCalls { get; init; } = 3000;
  /// <summary>Premor med zaporednimi klici (ekipa SAOP 2026-09-22: manj obremenitve).</summary>
  public int DelayBetweenCallsMilliseconds { get; init; } = 250;

  public IReadOnlyList<AnalyticsOrganization> Organizations { get; init; } = [];

  public bool HasCredentials =>
    !string.IsNullOrWhiteSpace(BaseUrl) && !string.IsNullOrWhiteSpace(Username) && !string.IsNullOrWhiteSpace(Password);

  public static AnalyticsSettings Read()
  {
    var saop = LocalSettings.Section("Saop");
    var analytics = LocalSettings.Section("Analitika");
    return new AnalyticsSettings
    {
      BaseUrl = Env("PIM_SAOP_BASE_URL") ?? Text(saop, "BaseUrl") ?? "",
      Username = Env("PIM_SAOP_USERNAME") ?? Text(saop, "Username") ?? "",
      Password = Env("PIM_SAOP_PASSWORD") ?? Text(saop, "Password") ?? "",
      AcceptUntrustedCertificate = Bool(saop, "AcceptUntrustedCertificate") ?? false,
      RetryMaxExtraAttempts = Int(saop, "RetryMaxExtraAttempts") ?? 3,
      RetryBaseDelayMilliseconds = Int(saop, "RetryBaseDelayMilliseconds") ?? 2000,
      TimeoutSeconds = Int(analytics, "TimeoutSeconds") ?? 900,
      PageSize = Int(analytics, "PageSize") ?? 500,
      MaxPages = Int(analytics, "MaxPages") ?? 2000,
      InitialBackfillMonths = Int(analytics, "InitialBackfillMonths") ?? 24,
      LookbackDays = Int(analytics, "LookbackDays") ?? 3,
      BarkawiBackfillPeriod = Int(analytics, "BarkawiBackfillPeriod") ?? 24,
      BarkawiDeltaPeriod = Int(analytics, "BarkawiDeltaPeriod") ?? 3,
      MaxInvoiceDetailCalls = Int(analytics, "MaxInvoiceDetailCalls") ?? 3000,
      DelayBetweenCallsMilliseconds = Int(analytics, "DelayBetweenCallsMilliseconds") ?? 250,
      Organizations = ReadOrganizations(saop),
    };
  }

  static IReadOnlyList<AnalyticsOrganization> ReadOrganizations(JsonElement? saop)
  {
    if (saop is null || !saop.Value.TryGetProperty("Organizations", out var array) || array.ValueKind != JsonValueKind.Array) return [];
    var list = new List<AnalyticsOrganization>();
    foreach (var element in array.EnumerateArray())
    {
      var id = element.TryGetProperty("Id", out var idElement) && idElement.TryGetInt32(out var parsed) ? parsed : 0;
      if (id <= 0) continue;
      var name = element.TryGetProperty("Name", out var nameElement) ? nameElement.GetString() ?? "" : "";
      var isActive = !element.TryGetProperty("IsActive", out var activeElement) || activeElement.ValueKind != JsonValueKind.False;
      list.Add(new AnalyticsOrganization(id, name, isActive));
    }
    return list;
  }

  static string? Env(string name) => Environment.GetEnvironmentVariable(name) is { Length: > 0 } value ? value : null;

  static string? Text(JsonElement? element, string name) =>
    element is not null && element.Value.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

  static int? Int(JsonElement? element, string name) =>
    element is not null && element.Value.TryGetProperty(name, out var value) && value.TryGetInt32(out var parsed) ? parsed : null;

  static bool? Bool(JsonElement? element, string name) =>
    element is not null && element.Value.TryGetProperty(name, out var value) && value.ValueKind is JsonValueKind.True or JsonValueKind.False
      ? value.GetBoolean() : null;
}
