using System.Globalization;
using System.Net;
using System.Text;

namespace PIM.StockReplenishmentWorker;

/// <summary>
/// Sestavi HTML telo dnevnega maila: pregledno po dobavitelju, znotraj po kategoriji (Department —
/// isto polje, ki ga obstoječi UI že prikazuje kot "ABC klasifikacija/Oddelek", prava izračunana ABC
/// klasifikacija še ne obstaja). Prazen seznam ni napaka — mail gre ven z "danes ni nič" sporočilom,
/// po uporabnikovi izrecni zahtevi.
/// </summary>
public static class DigestHtmlBuilder
{
  public static string Build(string organizationName, DateTime generatedUtc, IReadOnlyList<ReplenishmentRow> rows)
  {
    var html = new StringBuilder();
    html.Append("""<html><body style="font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#1a1a1a;">""");
    html.Append($"<h1 style=\"font-size:18px;\">Zaloga pod MID — {Encode(organizationName)}</h1>");
    html.Append($"<p style=\"color:#555;\">Stanje na {generatedUtc:dd.MM.yyyy}. Razpoložljiva zaloga = trenutna zaloga − odprta naročila kupcev (VNK).</p>");

    if (rows.Count == 0)
    {
      html.Append("<p><strong>Danes ni artiklov pod MID mejo.</strong></p>");
      html.Append("</body></html>");
      return html.ToString();
    }

    foreach (var bySupplier in rows.GroupBy(r => r.Supplier ?? "").OrderBy(g => g.Key, StringComparer.CurrentCultureIgnoreCase))
    {
      var label = bySupplier.Key.Length == 0
        ? "Brez dobavitelja"
        : bySupplier.First().SupplierName is { Length: > 0 } name ? $"{name} ({bySupplier.Key})" : bySupplier.Key;
      html.Append($"<h2 style=\"font-size:16px;border-bottom:1px solid #ccc;padding-bottom:4px;margin-top:28px;\">{Encode(label)}</h2>");

      foreach (var byDepartment in bySupplier.GroupBy(r => string.IsNullOrWhiteSpace(r.Department) ? "Brez kategorije" : r.Department!).OrderBy(g => g.Key, StringComparer.CurrentCultureIgnoreCase))
      {
        html.Append($"<h3 style=\"font-size:14px;color:#333;margin-top:16px;\">{Encode(byDepartment.Key)}</h3>");
        html.Append("""<table style="border-collapse:collapse;width:100%;margin-bottom:8px;">""");
        html.Append("<thead><tr style=\"background:#f0f0f0;text-align:left;\">");
        foreach (var header in new[] { "Šifra", "Naziv", "ABC/Oddelek", "Razpoložljiva zaloga", "MAX", "MID", "MIN", "Prihaja (VND)" })
        {
          html.Append($"<th style=\"padding:4px 8px;border:1px solid #ddd;\">{Encode(header)}</th>");
        }
        html.Append("</tr></thead><tbody>");

        foreach (var row in byDepartment.OrderBy(r => r.ItemID, StringComparer.CurrentCultureIgnoreCase))
        {
          html.Append("<tr>");
          html.Append(Cell(row.ItemID));
          html.Append(Cell(row.ItemName ?? ""));
          html.Append(Cell(row.Department ?? ""));
          html.Append(Cell(Number(row.AvailableStock)));
          html.Append(Cell(Number(row.MaximumStock)));
          html.Append(Cell(Number(row.MidStock)));
          html.Append(Cell(Number(row.MinimumStock)));
          html.Append(Cell(row.IncomingPurchaseQty is { } incoming ? Number(incoming) : ""));
          html.Append("</tr>");
        }

        html.Append("</tbody></table>");
      }
    }

    html.Append("</body></html>");
    return html.ToString();
  }

  static string Cell(string value) => $"<td style=\"padding:4px 8px;border:1px solid #ddd;\">{Encode(value)}</td>";

  static string Number(int? value) => value is null ? "" : value.Value.ToString(CultureInfo.InvariantCulture);

  static string Encode(string value) => WebUtility.HtmlEncode(value);
}
