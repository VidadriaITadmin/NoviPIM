using Microsoft.Data.SqlClient;

namespace PIM.ChangeTracking.Integration;

/// <summary>
/// Zaklep aplikacije (<c>sp_getapplock</c>), ki ga drzi vsak integracijski primer tega projekta,
/// dokler dela z razvojno bazo (#43).
///
/// Vrata vec nalog tecejo hkrati nad isto razvojno bazo. Pospravljanje v
/// <see cref="ChangeTrackingIntegrationTests"/> brise VSE artikle <c>CHANGE-TRACKING-*</c>, test z
/// lastnistvom polj v transakciji spremeni skupno <c>pim.FieldOwnership</c>, test predlagane
/// kategorije pa vstavi kandidata za isti zadnji zapis zajema. Dva zagona sta se zato zaklenila drug
/// na drugega (napaka 1205) ali cakala na tuje odprte transakcije. Z zaklepom tece naenkrat samo en
/// primer iz vseh zagonov tega projekta; ostali pocakajo.
///
/// Zaklep je na ravni seje: ChangeTracking ga mora drzati ze pred <c>BEGIN TRANSACTION</c>, povrnitev
/// po <c>XACT_ABORT</c> pa ga ne sme sprostiti.
/// </summary>
internal static class IntegrationDbLock
{
  public const string Resource = "PIM.ChangeTracking.Integration";

  /// <summary>
  /// Najdaljse cakanje. En primer drzi zaklep nekaj sekund, zasedena baza (druga vrata, avtomatika)
  /// ga lahko podaljsa; vrata dajo testnemu koraku 25 minut.
  /// </summary>
  public static readonly TimeSpan Timeout = TimeSpan.FromMinutes(10);

  public static async Task AcquireAsync(SqlConnection connection)
  {
    await using var command = new SqlCommand("""
      DECLARE @Rezultat int;
      EXEC @Rezultat = sp_getapplock @Resource=@Resource, @LockMode=N'Exclusive', @LockOwner=N'Session', @LockTimeout=@Timeout;
      SELECT @Rezultat;
      """, connection) { CommandTimeout = (int)Timeout.TotalSeconds + 60 };
    command.Parameters.AddWithValue("@Resource", Resource);
    command.Parameters.AddWithValue("@Timeout", (int)Timeout.TotalMilliseconds);
    var result = Convert.ToInt32(await command.ExecuteScalarAsync());
    // 0 = takoj, 1 = po cakanju; negativno = casovna meja (-1), preklic (-2), zastoj (-3), napaka (-999).
    if (result < 0)
      throw new TimeoutException(
        $"Zaklepa '{Resource}' ni bilo mogoce dobiti v {Timeout.TotalMinutes:0} min (sp_getapplock={result}). " +
        "Drug zagon testov ChangeTracking (npr. vrata druge naloge) ga drzi predolgo.");
  }

  public static async Task ReleaseAsync(SqlConnection connection)
  {
    if (connection.State != System.Data.ConnectionState.Open) return;
    try
    {
      // Zaklep seje bi sicer ostal na povezavi v bazenu, dokler je ta ne ponastavi.
      await using var command = new SqlCommand(
        "IF APPLOCK_MODE(N'public', @Resource, N'Session') <> N'NoLock' EXEC sp_releaseapplock @Resource=@Resource, @LockOwner=N'Session';",
        connection);
      command.Parameters.AddWithValue("@Resource", Resource);
      await command.ExecuteNonQueryAsync();
    }
    catch (SqlException) { /* povezava je ze prekinjena — zaklep je sproscen skupaj z njo */ }
  }
}
