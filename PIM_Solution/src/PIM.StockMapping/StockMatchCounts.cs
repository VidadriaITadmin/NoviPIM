using Microsoft.Data.SqlClient;

namespace PIM.StockMapping;

/// <summary>
/// Koliko vrstic zaloge se je res ujelo z artiklom v PIM in koliko jih visi brez njega.
///
/// Zakaj sploh obstaja: <c>stock.LandingRecord.Status = 'Applied'</c> ne pomeni, da je bil artikel
/// najden — <c>stock.ApplyLandingRecord</c> zapiše pozicijo tudi, kadar šifre ali EAN ni v katalogu
/// (<c>MatchKey = 'Unmatched'</c>, <c>MatchedProductId</c> prazen). Tako je bilo mogoče, da je bila
/// zaloga »uporabljena«, a je ni bilo na nobenem artiklu; iz števila zapisanih vrstic se to ni videlo.
/// Blok 3 prenove nadzora (2026-09-22) to loči v fazo UJEMANJE.
/// </summary>
public static class StockMatchCounts
{
  /// <param name="syncRunId">Zagon iz <c>stock.SyncRun</c> (isti ključ kot posnetek).</param>
  /// <returns>Ujete in neujete pozicije tega zagona.</returns>
  public static async Task<(long Matched, long Unmatched)> ReadAsync(
    string connectionString, Guid syncRunId, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(connectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("""
      SELECT Matched = SUM(CASE WHEN position.MatchedProductId IS NOT NULL THEN 1 ELSE 0 END),
             Unmatched = SUM(CASE WHEN position.MatchedProductId IS NULL THEN 1 ELSE 0 END)
      FROM stock.Position position
      INNER JOIN stock.Snapshot snapshotValue ON snapshotValue.SnapshotId = position.SnapshotId
      WHERE snapshotValue.SyncRunId = @SyncRunId;
      """, connection);
    command.Parameters.AddWithValue("@SyncRunId", syncRunId);

    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    if (!await reader.ReadAsync(cancellationToken)) return (0, 0);
    var matched = reader.IsDBNull(0) ? 0 : reader.GetInt32(0);
    var unmatched = reader.IsDBNull(1) ? 0 : reader.GetInt32(1);
    return (matched, unmatched);
  }
}
