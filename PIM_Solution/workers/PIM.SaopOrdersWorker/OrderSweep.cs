using System.Globalization;
using Microsoft.Data.SqlClient;

namespace PIM.SaopOrdersWorker;

/// <summary>
/// Zajem naročil po številkah (David 2026-09-25). Dokument v SAOP ima ključ leto/knjiga/številka; številke tečejo
/// znotraj leta in knjige od 1 naprej. GetOrderStatus za VNK ne vrne ničesar, GetOrder/leto/knjiga/številka pa dela,
/// zato: največja številka, ki jo že imamo, + 1 in naprej, dokler SAOP ne vrne toliko zaporednih »ni dokumenta«.
///
/// Enkratni zajem zgodovine (--zgodovina-od) gre po vseh letih od številke 1; kar je v bazi, preskoči (ne kliče znova).
/// Odprta naročila se enkrat na dan preberejo znova, ker se jim odpremljene/prevzete količine spreminjajo.
/// Vse gre v raw.Inbox pod isti EntityType kot doslej, zato ga preslika obstoječa pot (migracija 199).
/// </summary>
public static class OrderSweep
{
  /// <summary>Vrsta dokumenta: kje so znani ključi in kako ga dobimo po ključu.</summary>
  public sealed record Kind(
    string EntityType, string Label, string HeaderTable, string YearColumn, string BookColumn, string NumberColumn,
    string OpenFilterSql, Func<SaopOrdersApiClient, int, OrderKey, Task<DocumentProbe>> Fetch);

  public static readonly Kind Sales = new(
    "GetOrder", "Naročila kupcev", "sales.OrderHeader", "OrderYear", "OrderBook", "OrderNumber",
    "ISNULL(h.OrderStatus, N'') NOT IN (N'Zaključeno', N'Stornirano', N'Preklicano') AND EXISTS (SELECT 1 FROM sales.OrderLine AS l "
      + "WHERE l.OrderHeaderId = h.OrderHeaderId AND ISNULL(l.ClosedLine, 0) = 0 AND ISNULL(l.ShippedQTY, 0) < ISNULL(l.Qty, 0))",
    (client, organizationId, key) => client.TryGetSalesOrderAsync(organizationId, key));

  public static readonly Kind Purchase = new(
    "GetPurchaseOrder", "Naročila dobaviteljem", "purch.PurchaseOrderHeader", "PurchaseOrderYear", "PurchaseOrderBook", "PurchaseOrderNumber",
    "ISNULL(h.Status, N'') NOT IN (N'Zaključeno', N'Stornirano', N'Preklicano')",
    (client, organizationId, key) => client.TryGetPurchaseOrderAsync(organizationId, key));

  /// <summary>Vrne število pristalih dokumentov.</summary>
  public static async Task<int> SweepAsync(SaopOrdersApiClient client, SqlConnection connection, OrdersSettings settings,
    SaopOrganization organization, Guid runId, Kind kind, string book, int? historyFrom)
  {
    var today = DateTime.Today;
    IEnumerable<int> years = historyFrom is { } from
      ? Enumerable.Range(from, today.Year - from + 1)
      // Januarja še doberemo zadnja naročila lanskega leta.
      : today.Month == 1 ? [today.Year - 1, today.Year] : [today.Year];

    var landedTotal = 0;
    foreach (var year in years)
    {
      var known = await KnownNumbersAsync(connection, kind, organization.Id, year, book);
      var start = historyFrom is null && known.Count > 0 ? known.Max() + 1 : 1;
      var gap = Math.Max(1, historyFrom is null ? settings.SweepTailGap : settings.SweepHistoryGap);
      var maxCalls = historyFrom is null ? settings.SweepTailMaxCalls : settings.SweepMaxCalls;
      int misses = 0, calls = 0, landed = 0, serverErrors = 0, lastFound = known.Count > 0 ? known.Max() : 0;

      for (var number = start; misses < gap && calls < maxCalls; number++)
      {
        if (known.Contains(number)) { misses = 0; continue; }
        var probe = await kind.Fetch(client, organization.Id, new OrderKey(year, book, number));
        calls++;
        if (probe.Xml is null)
        {
          misses++;
          if (probe.Status >= 500) serverErrors++;
          continue;
        }
        misses = 0;
        lastFound = number;
        await RawInboxWriter.WriteAsync(connection, runId, organization.Id, organization.SourceCode, kind.EntityType, number, probe.Xml);
        landed++;
        if (landed % 200 == 0) Console.WriteLine($"    {kind.Label} {year}/{book}: {landed} novih, zadnja št. {number} …");
      }

      landedTotal += landed;
      Console.WriteLine($"  {kind.Label} {year}/{book} po številkah: od št. {start}, {calls} klicev, {landed} novih, "
        + $"najvišja št. {lastFound}{(calls >= maxCalls ? " — DOSEŽENA meja klicev, nadaljuje naslednji tek" : "")}");
      if (calls > 0 && landed == 0 && serverErrors == calls && known.Count == 0)
        Console.Error.WriteLine($"  OPOZORILO: za {year}/{book} je SAOP na vse klice vrnil napako strežnika — preveri knjigo in pravice uporabnika API.");
    }
    return landedTotal;
  }

  /// <summary>Enkrat na <see cref="OrdersSettings.OpenRefreshHours"/> ur znova prebere odprta naročila zadnjih dni.</summary>
  public static async Task<int> RefreshOpenAsync(SaopOrdersApiClient client, SqlConnection connection, OrdersSettings settings,
    SaopOrganization organization, int sourceConnectorId, Guid runId, Kind kind, string book)
  {
    var marker = kind.EntityType + ":ODPRTA";
    var last = await ReadMarkerAsync(connection, sourceConnectorId, marker);
    if (last is { } lastUtc && lastUtc > DateTime.UtcNow.AddHours(-Math.Max(1, settings.OpenRefreshHours))) return 0;

    var keys = new List<OrderKey>();
    await using (var command = new SqlCommand(
      $"SELECT h.{kind.YearColumn}, h.{kind.BookColumn}, h.{kind.NumberColumn} FROM {kind.HeaderTable} AS h "
      + $"WHERE h.OrganizationId = @OrganizationId AND h.{kind.BookColumn} = @Book AND h.OrderDate >= @From AND {kind.OpenFilterSql};", connection))
    {
      command.Parameters.AddWithValue("@OrganizationId", organization.Id);
      command.Parameters.AddWithValue("@Book", book);
      command.Parameters.AddWithValue("@From", DateTime.Today.AddDays(-Math.Max(1, settings.OpenRefreshDays)));
      await using var reader = await command.ExecuteReaderAsync();
      while (await reader.ReadAsync()) keys.Add(new OrderKey(reader.GetInt32(0), reader.GetString(1), reader.GetInt32(2)));
    }

    var landed = 0;
    foreach (var key in keys)
    {
      var probe = await kind.Fetch(client, organization.Id, key);
      if (probe.Xml is null) continue;
      await RawInboxWriter.WriteAsync(connection, runId, organization.Id, organization.SourceCode, kind.EntityType, key.Number, probe.Xml);
      landed++;
    }
    await WriteMarkerAsync(connection, sourceConnectorId, marker, DateTime.UtcNow);
    Console.WriteLine($"  {kind.Label}: osveženih odprtih {landed} od {keys.Count}.");
    return landed;
  }

  static async Task<HashSet<int>> KnownNumbersAsync(SqlConnection connection, Kind kind, int organizationId, int year, string book)
  {
    await using var command = new SqlCommand(
      $"SELECT {kind.NumberColumn} FROM {kind.HeaderTable} WHERE OrganizationId = @OrganizationId AND {kind.YearColumn} = @Year AND {kind.BookColumn} = @Book;",
      connection);
    command.Parameters.AddWithValue("@OrganizationId", organizationId);
    command.Parameters.AddWithValue("@Year", year);
    command.Parameters.AddWithValue("@Book", book);
    var numbers = new HashSet<int>();
    await using var reader = await command.ExecuteReaderAsync();
    while (await reader.ReadAsync()) numbers.Add(reader.GetInt32(0));
    return numbers;
  }

  static async Task<DateTime?> ReadMarkerAsync(SqlConnection connection, int sourceConnectorId, string entityType)
  {
    await using var command = new SqlCommand("SELECT WatermarkValue FROM map.Watermark WHERE SourceConnectorId=@s AND EntityType=@e;", connection);
    command.Parameters.AddWithValue("@s", sourceConnectorId);
    command.Parameters.AddWithValue("@e", entityType);
    var value = await command.ExecuteScalarAsync();
    return DateTime.TryParse(Convert.ToString(value, CultureInfo.InvariantCulture), CultureInfo.InvariantCulture,
      DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out var parsed) ? parsed : null;
  }

  static async Task WriteMarkerAsync(SqlConnection connection, int sourceConnectorId, string entityType, DateTime utc)
  {
    await using var command = new SqlCommand(
      """
      MERGE map.Watermark AS target
      USING (SELECT @s AS SourceConnectorId, @e AS EntityType, @v AS WatermarkValue) AS source
        ON target.SourceConnectorId = source.SourceConnectorId AND target.EntityType = source.EntityType
      WHEN MATCHED THEN UPDATE SET WatermarkValue = source.WatermarkValue, UpdatedUtc = SYSUTCDATETIME()
      WHEN NOT MATCHED THEN INSERT (SourceConnectorId, EntityType, WatermarkValue, UpdatedUtc)
        VALUES (source.SourceConnectorId, source.EntityType, source.WatermarkValue, SYSUTCDATETIME());
      """, connection);
    command.Parameters.AddWithValue("@s", sourceConnectorId);
    command.Parameters.AddWithValue("@e", entityType);
    command.Parameters.AddWithValue("@v", utc.ToString("O", CultureInfo.InvariantCulture));
    await command.ExecuteNonQueryAsync();
  }
}
