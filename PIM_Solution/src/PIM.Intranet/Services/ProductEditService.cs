using System.Data;
using System.Text.Json;
using Microsoft.Data.SqlClient;

namespace PIM.Intranet.Services;

/// <param name="ChangedCount">Koliko polj je šlo skozi; 0 pomeni, da ni bilo česa spremeniti.</param>
/// <param name="Conflicts">
/// Polja, ki jih nekdo drug spremenil, odkar jih je urednik videl (migracija 186). Niso napaka:
/// ostale spremembe se zapišejo, ta polja pa se preskočijo in kartica pokaže tujo vrednost.
/// </param>
public sealed record ProductEditOutcome(
  long ChangedCount, string ValidationStatus, decimal Completeness, long OpenIssueCount,
  IReadOnlyList<ProductEditConflict> Conflicts);

/// <param name="Expected">Vrednost, ki jo je urednik videl.</param>
/// <param name="TheirValue">Vrednost, ki je v katalogu zdaj.</param>
public sealed record ProductEditConflict(string FieldKey, string? Expected, string? TheirValue);

/// <param name="Expected">Vrednost, ki jo je urednik videl; <c>null</c> pomeni »ne preverjaj«.</param>
public sealed record ProductTextEdit(string Language, string TextType, string? Value, string? Expected = null, bool CheckExpected = false);
public sealed record ProductAttributeEdit(string AttributeCode, string? Value, string? Expected = null, bool CheckExpected = false);

/// <param name="WebShopCode">Koda spletišča (<c>svetila_si</c>, <c>videlektro</c>) — ista kot
/// <c>canon.WebSite.CategoryTreeCode</c> in <c>val.ValidationProfile.CategoryTreeCode</c>.</param>
/// <param name="IsPublished">Ali izdelek gre na to spletišče. To je merilo spletne validacije;
/// <c>Product.WebPublish</c> iz SAOP se za to ne uporablja več (odločitev uporabnika 2026-09-08).</param>
public sealed record ProductWebShopRow(string WebShopCode, string WebShopName, bool IsPublished, string? ChangedBy, DateTime? ChangedUtc);

/// <summary>
/// Zapisovalna pot kartice izdelka za podatek, ki je last PIM: spletna besedila in lastnosti.
///
/// Kar potuje v SAOP (ERP naziv, enota mere, skupina …), tu ne gre skozi — za to je odhodna
/// vrsta z odobritvijo (<see cref="SaopWriteService"/>). Ločnica ni v tej kodi, ampak v
/// registru <c>out.SaopXmlField</c>; procedura zavrne tak zapis z napako, ne tiho.
///
/// SQL ostaja v oštevilčeni migraciji (111): servis kliče <c>pim.SaveProductTexts</c> in
/// <c>pim.SaveProductAttributes</c>, ki sama poskrbita za zgodovino (sprožilci) in za takojšnjo
/// ponovno validacijo tega enega izdelka.
///
/// Vloga se preveri **tu**, pred klicem baze (ugotovitev A1, pregled 2026-09-08). Prej je bila
/// urejivost stvar komponente, zato je bralna vloga <c>VIEWER</c> dobila urejiva polja in gumb
/// »Shrani spremembe«, zapisovalna pot pa vloge sploh ni pogledala; procedure preverijo lastništvo
/// polja in pripadnost podjetju, ne pa tudi, kdo zapis naroča.
/// </summary>
public sealed class ProductEditService(IConfiguration configuration, PimWriteGuard guard)
{
  string ConnectionString => ConnectionStringResolver.Resolve(configuration)
    ?? throw new InvalidOperationException("Povezava PIM ni nastavljena.");

  public async Task<ProductEditOutcome> SaveTextsAsync(
    int organizationId, long productId, IEnumerable<ProductTextEdit> edits,
    string actor, string? note = null, CancellationToken cancellationToken = default)
  {
    await guard.RequireAsync(PimPolicies.CatalogWrite);
    return await SaveAsync("pim.SaveProductTexts", organizationId, productId,
      JsonSerializer.Serialize(edits.Select(edit => new
      {
        lang = edit.Language,
        textType = edit.TextType,
        value = edit.Value ?? string.Empty,
        expected = edit.Expected ?? string.Empty,
        hasExpected = edit.CheckExpected ? 1 : 0,
      })), actor, note, cancellationToken);
  }

  public async Task<ProductEditOutcome> SaveAttributesAsync(
    int organizationId, long productId, IEnumerable<ProductAttributeEdit> edits,
    string actor, string? note = null, CancellationToken cancellationToken = default)
  {
    await guard.RequireAsync(PimPolicies.CatalogWrite);
    return await SaveAsync("pim.SaveProductAttributes", organizationId, productId,
      JsonSerializer.Serialize(edits.Select(edit => new
      {
        attributeCode = edit.AttributeCode,
        value = edit.Value ?? string.Empty,
        expected = edit.Expected ?? string.Empty,
        hasExpected = edit.CheckExpected ? 1 : 0,
      })), actor, note, cancellationToken);
  }

  /// <summary>
  /// Spletišča, na katera gre izdelek. Vrne vsa aktivna spletišča, tudi neoznačena, ker mora
  /// obrazec pokazati tudi prazno potrditveno polje (migracija 182).
  /// </summary>
  public async Task<IReadOnlyList<ProductWebShopRow>> GetWebShopsAsync(long productId, CancellationToken cancellationToken = default)
  {
    var rows = new List<ProductWebShopRow>();
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.GetProductWebShops", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.Add("@ProductId", SqlDbType.BigInt).Value = productId;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    while (await reader.ReadAsync(cancellationToken))
      rows.Add(new(
        PimDb.TextOrEmpty(reader, "WebShopCode"), PimDb.TextOrEmpty(reader, "WebShopName"),
        PimDb.Bool(reader, "IsPublished"),
        PimDb.Text(reader, "ChangedBy"), PimDb.NullableDateTime(reader, "ChangedUtc")));
    return rows;
  }

  /// <summary>
  /// Zapiše oznake spletišč. Procedura sama zapiše zgodovino in izdelek takoj revalidira, zato
  /// se stanje kakovosti spremeni v istem klicu.
  /// </summary>
  public async Task<int> SaveWebShopsAsync(
    int organizationId, long productId, IEnumerable<(string WebShopCode, bool IsPublished)> shops,
    string actor, string? note = null, CancellationToken cancellationToken = default)
  {
    await guard.RequireAsync(PimPolicies.CatalogWrite);
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("pim.SaveProductWebShops", connection)
    {
      CommandType = CommandType.StoredProcedure,
      CommandTimeout = 120,
    };
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@ProductId", SqlDbType.BigInt).Value = productId;
    command.Parameters.Add("@ChangesJson", SqlDbType.NVarChar, -1).Value = JsonSerializer.Serialize(
      shops.Select(shop => new { webShopCode = shop.WebShopCode, isPublished = shop.IsPublished ? "1" : "0" }));
    command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = actor;
    command.Parameters.Add("@Note", SqlDbType.NVarChar, 400).Value = (object?)note ?? DBNull.Value;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    return await reader.ReadAsync(cancellationToken) ? (int)PimDb.Int64(reader, "PublishedCount") : 0;
  }

  async Task<ProductEditOutcome> SaveAsync(
    string procedure, int organizationId, long productId, string changesJson,
    string actor, string? note, CancellationToken cancellationToken)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand(procedure, connection)
    {
      CommandType = CommandType.StoredProcedure,
      // Ponovna validacija enega izdelka je merjeno 60–230 ms; meja je varovalka, ne pričakovanje.
      CommandTimeout = 120,
    };
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@ProductId", SqlDbType.BigInt).Value = productId;
    command.Parameters.Add("@ChangesJson", SqlDbType.NVarChar, -1).Value = changesJson;
    command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = actor;
    command.Parameters.Add("@Note", SqlDbType.NVarChar, 400).Value = (object?)note ?? DBNull.Value;

    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    if (!await reader.ReadAsync(cancellationToken)) return new(0, "PENDING", 0, 0, []);
    var outcome = new ProductEditOutcome(
      PimDb.Int64(reader, "ChangedCount"), PimDb.TextOrEmpty(reader, "ValidationStatus"),
      PimDb.Decimal(reader, "Completeness"), PimDb.Int64(reader, "OpenIssueCount"), []);

    // Drugi nabor so sporna polja (186). Prazen je najpogostejsi primer in ni izjema.
    var conflicts = new List<ProductEditConflict>();
    if (await reader.NextResultAsync(cancellationToken))
      while (await reader.ReadAsync(cancellationToken))
        conflicts.Add(new(
          PimDb.TextOrEmpty(reader, "FieldKey"), PimDb.Text(reader, "Expected"), PimDb.Text(reader, "TheirValue")));
    return outcome with { Conflicts = conflicts };
  }
}
