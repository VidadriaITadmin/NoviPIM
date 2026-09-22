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

/// <summary>Ena sprememba besedila v mnozicnem zapisu (218); izdelek je del vrstice, ker gre vec izdelkov v en klic.</summary>
public sealed record ProductTextBulkEdit(long ProductId, string Language, string TextType, string? Value);
public sealed record ProductAttributeBulkEdit(long ProductId, string AttributeCode, string? Value);

/// <param name="Skipped">Izdelki, ki jih procedura ni zapisala (npr. niso v tem podjetju), z razlogom.</param>
public sealed record ProductBulkEditOutcome(long ChangedCount, long ProductCount, IReadOnlyList<ProductBulkSkip> Skipped);
public sealed record ProductBulkSkip(long ProductId, string Reason);

/// <summary>Ena ERP vrednost v mnozicnem zapisu (245); <see cref="FieldKey"/> je koda iz registra
/// <c>out.SaopXmlField</c>, npr. <c>Product.UoM</c> ali <c>Planning.ExcludeQtyReservation</c>.</summary>
public sealed record ProductErpBulkEdit(long ProductId, string FieldKey, string? Value);

/// <param name="Skipped">Polja, ki jih procedura ni zapisala, z razlogom (neznano polje, ni stevilo …).</param>
public sealed record ProductErpBulkOutcome(long ChangedCount, long ProductCount, IReadOnlyList<ProductErpBulkSkip> Skipped);
public sealed record ProductErpBulkSkip(long ProductId, string FieldKey, string Reason);

/// <summary>Celica »Slike« ali »Dokumenti« enega izdelka (245): <see cref="Urls"/> je cel seznam v
/// vrstnem redu celice, <see cref="Remove"/> so naslovi, ki jih izdelek zdaj ima, v celici pa jih ni.</summary>
/// <param name="Kind"><see cref="Images"/> ali <see cref="Documents"/>.</param>
public sealed record ProductMediaBulkEdit(long ProductId, string Kind, IReadOnlyList<string> Urls, IReadOnlyList<string> Remove)
{
  public const string Images = "IMAGES";
  public const string Documents = "DOCUMENTS";
}

public sealed record ProductMediaBulkOutcome(long AddedCount, long RemovedCount, long ProductCount, IReadOnlyList<ProductBulkSkip> Skipped);

/// <param name="WebShopCode">Koda spletišča (<c>svetila_si</c>, <c>videlektro</c>) — ista kot
/// <c>canon.WebSite.CategoryTreeCode</c> in <c>val.ValidationProfile.CategoryTreeCode</c>.</param>
/// <param name="IsPublished">Ali izdelek gre na to spletišče. To je merilo spletne validacije;
/// <c>Product.WebPublish</c> iz SAOP se za to ne uporablja več (odločitev uporabnika 2026-09-08).</param>
public sealed record ProductWebShopRow(string WebShopCode, string WebShopName, bool IsPublished, string? ChangedBy, DateTime? ChangedUtc);

/// <summary>Splošna oznaka na izdelku (233), npr. "Razstavni eksponat". Register
/// <c>pim.ProductFlagDefinition</c> pove, katere oznake obstajajo — nova oznaka je vrstica v
/// registru, ne nova migracija.</summary>
public sealed record ProductFlagRow(string FlagCode, string DisplayName, bool IsSet, string? ChangedBy, DateTime? ChangedUtc);

/// <summary>
/// Zapisovalna pot kartice izdelka za podatek, ki je last PIM: spletna besedila in lastnosti.
///
/// Kar potuje v SAOP (ERP naziv, enota mere, skupina …), s kartice tu ne gre skozi — za to je
/// odhodna vrsta z odobritvijo (<see cref="SaopWriteService"/>). Ločnica ni v tej kodi, ampak v
/// registru <c>out.SaopXmlField</c>; procedura zavrne tak zapis z napako, ne tiho. Izjema je uvoz
/// delovnega lista (245, <see cref="SaveErpFieldsBulkAsync"/>): tam gre ERP vrednost v katalog
/// takoj in hkrati v odhodno vrsto.
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
  /// se stanje kakovosti spremeni v istem klicu. Od 251 nova kljukica na spletišču, kamor artikel ne
  /// sme (neaktiven, brez kategorije tega spletišča, neveljaven za splet), ne obvelja; izid pove zakaj.
  /// </summary>
  public async Task<WebShopSaveOutcome> SaveWebShopsAsync(
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
    var published = await reader.ReadAsync(cancellationToken) ? (int)PimDb.Int64(reader, "PublishedCount") : 0;
    // Drugi nabor (251): zavrnjene nove kljukice z razlogom. Prazen je najpogostejši primer.
    var rejected = new List<WebShopRejection>();
    if (await reader.NextResultAsync(cancellationToken))
      while (await reader.ReadAsync(cancellationToken))
        rejected.Add(new(
          PimDb.TextOrEmpty(reader, "WebShopCode"), PimDb.TextOrEmpty(reader, "ShopLabel"),
          PimDb.Bool(reader, "IsActive"), PimDb.Bool(reader, "HasCategory"),
          PimDb.Text(reader, "InvalidProfiles"), PimDb.Text(reader, "MissingFields")));
    return new(published, rejected);
  }

  /// <summary>
  /// Kljukica »izloči iz rezervacije zaloge« (canon.ProductPlanning.ExcludeQuantityReservation).
  /// Bralni model kartice (canon.FieldValue) planiranja nima, zato je kartica do 245 kazala
  /// »ni v bralnem modelu« — kljukice ni bilo mogoče ne videti ne urediti. Brez vrstice planiranja: ne.
  /// </summary>
  public async Task<bool> GetReservationExclusionAsync(long productId, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand(
      "SELECT ExcludeQuantityReservation FROM canon.ProductPlanning WHERE ProductId = @ProductId;", connection);
    command.Parameters.Add("@ProductId", SqlDbType.BigInt).Value = productId;
    return await command.ExecuteScalarAsync(cancellationToken) is bool excluded && excluded;
  }

  /* ─── Oznake izdelka (233) ──────────────────────────────────────────────────────────── */

  /// <summary>Vse aktivne oznake iz registra, tudi neoznačene (isti razlog kot pri spletiščih:
  /// obrazec mora pokazati tudi prazno potrditveno polje).</summary>
  public async Task<IReadOnlyList<ProductFlagRow>> GetProductFlagsAsync(long productId, CancellationToken cancellationToken = default)
  {
    var rows = new List<ProductFlagRow>();
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.GetProductFlags", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.Add("@ProductId", SqlDbType.BigInt).Value = productId;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    while (await reader.ReadAsync(cancellationToken))
      rows.Add(new(
        PimDb.TextOrEmpty(reader, "FlagCode"), PimDb.TextOrEmpty(reader, "DisplayName"),
        PimDb.Bool(reader, "IsSet"),
        PimDb.Text(reader, "ChangedBy"), PimDb.NullableDateTime(reader, "ChangedUtc")));
    return rows;
  }

  /// <summary>Zapiše spremenjene oznake. Oznake ne vplivajo na obseg validacije, zato (za razliko
  /// od <see cref="SaveWebShopsAsync"/>) ni ponovnega klica <c>val.RunValidation</c>.</summary>
  public async Task<int> SaveProductFlagsAsync(
    int organizationId, long productId, IEnumerable<(string FlagCode, bool IsSet)> flags,
    string actor, string? note = null, CancellationToken cancellationToken = default)
  {
    await guard.RequireAsync(PimPolicies.CatalogWrite);
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("pim.SaveProductFlags", connection)
    {
      CommandType = CommandType.StoredProcedure,
      CommandTimeout = 120,
    };
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@ProductId", SqlDbType.BigInt).Value = productId;
    command.Parameters.Add("@ChangesJson", SqlDbType.NVarChar, -1).Value = JsonSerializer.Serialize(
      flags.Select(flag => new { flagCode = flag.FlagCode, isSet = flag.IsSet ? "1" : "0" }));
    command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = actor;
    command.Parameters.Add("@Note", SqlDbType.NVarChar, 400).Value = (object?)note ?? DBNull.Value;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    return await reader.ReadAsync(cancellationToken) ? (int)PimDb.Int64(reader, "SetCount") : 0;
  }

  /* ─── Mnozicni zapis (218) — uvoz delovnega lista ──────────────────────────────────── */

  /// <summary>
  /// Besedila za poljubno mnogo izdelkov v enem klicu (<c>pim.SaveProductTextsBulk</c>): en MERGE,
  /// ena serija zgodovine in ena mnozicna validacija (<c>val.RunValidationForProducts</c>) namesto
  /// ene procedure in ene validacije na vrstico. Ista pravila lastnistva kot pri
  /// <see cref="SaveTextsAsync"/>; sporna polja (Expected) tu niso podprta, ker jih uvoz ne posilja.
  /// </summary>
  public async Task<ProductBulkEditOutcome> SaveTextsBulkAsync(
    int organizationId, IEnumerable<ProductTextBulkEdit> edits,
    string actor, string? note = null, CancellationToken cancellationToken = default)
  {
    await guard.RequireAsync(PimPolicies.CatalogWrite);
    return await SaveBulkAsync("pim.SaveProductTextsBulk", organizationId,
      JsonSerializer.Serialize(edits.Select(edit => new
      {
        productId = edit.ProductId,
        lang = edit.Language,
        textType = edit.TextType,
        value = edit.Value ?? string.Empty,
      })), actor, note, cancellationToken);
  }

  /// <summary>Atributi za poljubno mnogo izdelkov v enem klicu (<c>pim.SaveProductAttributesBulk</c>); glej <see cref="SaveTextsBulkAsync"/>.</summary>
  public async Task<ProductBulkEditOutcome> SaveAttributesBulkAsync(
    int organizationId, IEnumerable<ProductAttributeBulkEdit> edits,
    string actor, string? note = null, CancellationToken cancellationToken = default)
  {
    await guard.RequireAsync(PimPolicies.CatalogWrite);
    return await SaveBulkAsync("pim.SaveProductAttributesBulk", organizationId,
      JsonSerializer.Serialize(edits.Select(edit => new
      {
        productId = edit.ProductId,
        attributeCode = edit.AttributeCode,
        value = edit.Value ?? string.Empty,
      })), actor, note, cancellationToken);
  }

  /// <summary>
  /// ERP polja za poljubno mnogo izdelkov v enem klicu (<c>pim.SaveProductErpFieldsBulk</c>, 245):
  /// zapis v katalog PIM TAKOJ, brez cakanja na SAOP. Uporabnik 2026-09-22: »ERP brez cakanja
  /// SAOPa«. Pot v SAOP s tem ne izgine — klicatelj (uvoz delovnega lista) isto spremembo prej
  /// uvrsti v odhodno vrsto (<see cref="SaopWriteService.EnqueueAsync"/>), kjer caka odobritev.
  /// Zato ista vloga kot za odhodno vrsto (<see cref="PimPolicies.SaopWrite"/>).
  /// </summary>
  public async Task<ProductErpBulkOutcome> SaveErpFieldsBulkAsync(
    int organizationId, IEnumerable<ProductErpBulkEdit> edits,
    string actor, string? note = null, CancellationToken cancellationToken = default)
  {
    await guard.RequireAsync(PimPolicies.SaopWrite);
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = BulkCommand("pim.SaveProductErpFieldsBulk", connection, organizationId,
      JsonSerializer.Serialize(edits.Select(edit => new { productId = edit.ProductId, fieldKey = edit.FieldKey, value = edit.Value ?? string.Empty })),
      actor, note);

    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    if (!await reader.ReadAsync(cancellationToken)) return new(0, 0, []);
    var changed = PimDb.Int64(reader, "ChangedCount");
    var products = PimDb.Int64(reader, "ProductCount");
    var skipped = new List<ProductErpBulkSkip>();
    if (await reader.NextResultAsync(cancellationToken))
      while (await reader.ReadAsync(cancellationToken))
        skipped.Add(new(PimDb.Int64(reader, "ProductId"), PimDb.TextOrEmpty(reader, "FieldKey"), PimDb.TextOrEmpty(reader, "Reason")));
    return new(changed, products, skipped);
  }

  /// <summary>
  /// Slike in dokumenti za poljubno mnogo izdelkov (<c>pim.SaveProductMediaBulk</c>, 245). Celica
  /// je cel seznam; kaj izbrisati, pove klicatelj (<see cref="ProductMediaBulkEdit.Remove"/>), ker
  /// le on razvrsti naslov v sliko ali dokument z isto <see cref="MediaKindPolicy"/> kot izvoz.
  /// </summary>
  public async Task<ProductMediaBulkOutcome> SaveMediaBulkAsync(
    int organizationId, IEnumerable<ProductMediaBulkEdit> edits,
    string actor, string? note = null, CancellationToken cancellationToken = default)
  {
    await guard.RequireAsync(PimPolicies.CatalogWrite);
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = BulkCommand("pim.SaveProductMediaBulk", connection, organizationId,
      JsonSerializer.Serialize(edits.Select(edit => new { productId = edit.ProductId, kind = edit.Kind, urls = edit.Urls, remove = edit.Remove })),
      actor, note);

    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    if (!await reader.ReadAsync(cancellationToken)) return new(0, 0, 0, []);
    var added = PimDb.Int64(reader, "AddedCount");
    var removed = PimDb.Int64(reader, "RemovedCount");
    var products = PimDb.Int64(reader, "ProductCount");
    var skipped = new List<ProductBulkSkip>();
    if (await reader.NextResultAsync(cancellationToken))
      while (await reader.ReadAsync(cancellationToken))
        skipped.Add(new(PimDb.Int64(reader, "ProductId"), PimDb.TextOrEmpty(reader, "Reason")));
    return new(added, removed, products, skipped);
  }

  static SqlCommand BulkCommand(
    string procedure, SqlConnection connection, int organizationId, string changesJson, string actor, string? note)
  {
    var command = new SqlCommand(procedure, connection)
    {
      CommandType = CommandType.StoredProcedure,
      // Enako kot SaveBulkAsync: paket do tisoc izdelkov z eno mnozicno validacijo.
      CommandTimeout = 600,
    };
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@ChangesJson", SqlDbType.NVarChar, -1).Value = changesJson;
    command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = actor;
    command.Parameters.Add("@Note", SqlDbType.NVarChar, 400).Value = (object?)note ?? DBNull.Value;
    return command;
  }

  async Task<ProductBulkEditOutcome> SaveBulkAsync(
    string procedure, int organizationId, string changesJson,
    string actor, string? note, CancellationToken cancellationToken)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand(procedure, connection)
    {
      CommandType = CommandType.StoredProcedure,
      // Paket ima do tisoc izdelkov; mnozicna validacija paketa je izmerjena v sekundah, ne minutah.
      CommandTimeout = 600,
    };
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@ChangesJson", SqlDbType.NVarChar, -1).Value = changesJson;
    command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = actor;
    command.Parameters.Add("@Note", SqlDbType.NVarChar, 400).Value = (object?)note ?? DBNull.Value;

    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    if (!await reader.ReadAsync(cancellationToken)) return new(0, 0, []);
    var outcome = new ProductBulkEditOutcome(PimDb.Int64(reader, "ChangedCount"), PimDb.Int64(reader, "ProductCount"), []);

    var skipped = new List<ProductBulkSkip>();
    if (await reader.NextResultAsync(cancellationToken))
      while (await reader.ReadAsync(cancellationToken))
        skipped.Add(new(PimDb.Int64(reader, "ProductId"), PimDb.TextOrEmpty(reader, "Reason")));
    return outcome with { Skipped = skipped };
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
