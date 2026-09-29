namespace PIM.Intranet.Services;

/// <summary>
/// Kaj čaka človeka (nadzorna plošča »Moj dan«, prenova 2026-09-26): števci vrst dela čez vsa aktivna podjetja.
/// </summary>
/// <param name="ProductPendingMessages">Spremembe artiklov za SAOP, ki čakajo odobritev (sporočila).</param>
/// <param name="ProductPendingItems">Od tega različnih artiklov.</param>
/// <param name="ProductPendingMine">Od tega sporočil, ki jih je pripravil prijavljeni uporabnik.</param>
/// <param name="ProductFailed">Spremembe artiklov, ki jih SAOP ni sprejel (Dead, Error, Drift).</param>
/// <param name="PricePending">Cene in ceniki (dokumenti), ki čakajo odobritev za SAOP.</param>
/// <param name="PriceFailed">Cene in ceniki, ki jih SAOP ni sprejel.</param>
/// <param name="OutboundOpen">Nepotrjene napake odhodne poti (ops.OutboundEvent, Severity Error).</param>
/// <param name="CandidatesPending">Novi artikli dobaviteljev, ki čakajo odločitev.</param>
/// <param name="WithdrawnUnreviewed">Artikli, ki jih je PIM umaknil s spleta in jih še nihče ni pregledal.</param>
public sealed record DayQueues(
  long ProductPendingMessages, long ProductPendingItems, long ProductPendingMine, long ProductFailed,
  long PricePending, long PriceFailed, long OutboundOpen, long CandidatesPending, long WithdrawnUnreviewed)
{
  public static DayQueues Empty { get; } = new(0, 0, 0, 0, 0, 0, 0, 0, 0);
}

/// <summary>
/// Ena poizvedba za vse vrste dela na nadzorni plošči. Zakaj ne klici obstoječih servisov: vsak od njih
/// bere cel seznam (skupine SAOP, kandidate s stanjem SAOP, umike …), plošča pa rabi samo število — devet
/// COUNT-ov v enem obisku baze je izmerjeno 2026-09-26 pod 10 ms. Stanja so ista, kot jih uporabljajo
/// strani, na katere plošča vodi (Saop.razor, Prices.razor zavihek saop, SupplierCandidates, WebWithdrawals,
/// ExportEvents), da se število na plošči ujema s seznamom, ki se odpre.
/// </summary>
public static class DayQueueReader
{
  const string Sql = """
    WITH org AS (SELECT OrganizationId FROM dbo.OrganizationConfig WHERE IsActive = 1)
    SELECT
      ProductPendingMessages = (SELECT COUNT_BIG(*) FROM out.OutboxMessage m JOIN org ON org.OrganizationId = m.OrganizationId
                                 WHERE m.TargetKind = N'SAOP_PRODUCT' AND m.Status = N'PendingApproval'),
      ProductPendingItems = (SELECT COUNT_BIG(DISTINCT m.EntityKey) FROM out.OutboxMessage m JOIN org ON org.OrganizationId = m.OrganizationId
                              WHERE m.TargetKind = N'SAOP_PRODUCT' AND m.Status = N'PendingApproval'),
      ProductPendingMine = (SELECT COUNT_BIG(*) FROM out.OutboxMessage m JOIN org ON org.OrganizationId = m.OrganizationId
                             WHERE m.TargetKind = N'SAOP_PRODUCT' AND m.Status = N'PendingApproval' AND m.CreatedBy = @User),
      ProductFailed = (SELECT COUNT_BIG(*) FROM out.OutboxMessage m JOIN org ON org.OrganizationId = m.OrganizationId
                        WHERE m.TargetKind = N'SAOP_PRODUCT' AND m.Status IN (N'Dead', N'Error', N'Drift')),
      PricePending = (SELECT COUNT_BIG(DISTINCT m.EntityKey) FROM out.OutboxMessage m JOIN org ON org.OrganizationId = m.OrganizationId
                       WHERE m.TargetKind IN (N'SAOP_PRICE', N'SAOP_PRICELIST') AND m.Status = N'PendingApproval'),
      PriceFailed = (SELECT COUNT_BIG(DISTINCT m.EntityKey) FROM out.OutboxMessage m JOIN org ON org.OrganizationId = m.OrganizationId
                      WHERE m.TargetKind IN (N'SAOP_PRICE', N'SAOP_PRICELIST') AND m.Status IN (N'Dead', N'Error', N'Drift')),
      OutboundOpen = (SELECT COUNT_BIG(*) FROM ops.OutboundEvent e JOIN org ON org.OrganizationId = e.OrganizationId
                       WHERE e.AcknowledgedUtc IS NULL AND e.Severity = N'Error'),
      CandidatesPending = (SELECT COUNT_BIG(*) FROM map.SupplierProductCandidate c JOIN org ON org.OrganizationId = c.OrganizationId
                            WHERE c.Status = N'PENDING' AND c.IsActive = 1),
      WithdrawnUnreviewed = (SELECT COUNT_BIG(*) FROM pim.WebShopWithdrawal w JOIN org ON org.OrganizationId = w.OrganizationId
                              WHERE w.ReviewedUtc IS NULL AND w.RestoredUtc IS NULL);
    """;

  public static async Task<DayQueues> ReadAsync(PimDb db, string user, CancellationToken cancellationToken = default)
  {
    var rows = await db.QueryAsync(Sql,
      reader => new DayQueues(
        PimDb.Int64(reader, "ProductPendingMessages"), PimDb.Int64(reader, "ProductPendingItems"),
        PimDb.Int64(reader, "ProductPendingMine"), PimDb.Int64(reader, "ProductFailed"),
        PimDb.Int64(reader, "PricePending"), PimDb.Int64(reader, "PriceFailed"),
        PimDb.Int64(reader, "OutboundOpen"), PimDb.Int64(reader, "CandidatesPending"),
        PimDb.Int64(reader, "WithdrawnUnreviewed")),
      command => command.Parameters.Add("@User", System.Data.SqlDbType.NVarChar, 200).Value = user,
      cancellationToken);
    return rows.Count > 0 ? rows[0] : DayQueues.Empty;
  }
}
