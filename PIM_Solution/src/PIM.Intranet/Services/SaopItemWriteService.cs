using System.Data;
using Microsoft.Data.SqlClient;
using PIM.Outbound;

namespace PIM.Intranet.Services;

/// <param name="IsWritable">Ali je polje v lasti PIM; samo tako polje sme v odhodno vrsto.</param>
/// <param name="IsKey">Element naravnega ključa; vrednost pride iz šifre artikla, ne iz obrazca.</param>
public sealed record SaopItemFieldRow(
  string Section, string ElementName, string? FieldKey, int SortOrder, bool IsAddMandatory,
  string ValueFormat, string? TrueValue, string? FalseValue, bool IsKey, bool IsWritable)
{
  /// <summary>Slovenska oznaka za obrazec.</summary>
  public string Label => SaopFieldLabels.For(ElementName);

  /// <summary>Ali sme uporabnik to polje vpisati v tabelo. Ključ in tuja polja ne.</summary>
  public bool IsEditable => IsWritable && !IsKey && FieldKey is not null;
}

/// <param name="Contract">Pogodba v obliki, kot jo pričakuje <see cref="SaopDocumentBuilder"/>.</param>
/// <param name="Fields">Ista pogodba za vmesnik: z oznako, lastništvom in vrstnim redom.</param>
public sealed record SaopItemContract(
  SaopDocumentShape Shape, IReadOnlyList<SaopXmlField> Contract, IReadOnlyList<SaopItemFieldRow> Fields);

/// <param name="ExistsInSaop">Ali je artikel v kanoničnem modelu; od tega je odvisen POST ali PATCH.</param>
/// <param name="Values">Trenutne kanonične vrednosti po ključu polja; samo neprazne.</param>
/// <param name="Defaults">Privzetki iz <c>out.SaopAddDefault</c> po ključu <c>Ovoj/Element</c>.</param>
public sealed record SaopItemState(
  string ItemId, bool ExistsInSaop, string SourceKey,
  IReadOnlyDictionary<string, string?> Values, IReadOnlyDictionary<string, string> Defaults);

/// <param name="Exists">Ali profil za SAOP_PRODUCT sploh obstaja.</param>
/// <param name="ApprovalMode"><c>Automatic</c> ali <c>ManualApproval</c>.</param>
public sealed record SaopChannelState(
  bool Exists, bool IsEnabled, string ApprovalMode, string? BaseUrl, string AddPath, string UpdatePath)
{
  public bool NeedsApproval => !string.Equals(ApprovalMode, "Automatic", StringComparison.OrdinalIgnoreCase);
}

/// <summary>
/// Priprava dokumenta za SAOP z vidika urednika: kaj bo poslano, s katero metodo in zakaj.
///
/// Zakaj svoja storitev poleg <see cref="SaopWriteService"/>: ta naroči spremembo (piše v
/// <c>out.OutboxMessage</c>), ta storitev pa samo <b>pokaže</b>, kaj bo iz naročenega nastalo.
/// Predogled ne sme uporabiti prevzema (<c>out.ClaimItemDocument</c>), ker ta poveča število
/// poskusov in postavi lease — vsak pogled bi porabil en poskus in sporočilo bi umrlo od
/// poskusov, ki se niso zgodili. Isto past opisuje migracija 086.
///
/// Dokument se sestavi z <b>istim</b> gradnikom in iz <b>istih</b> virov kot pri pošiljanju
/// (<c>SaopDocumentRunner.Assemble</c> v workerju): pogodba iz <c>out.GetSaopXmlContract</c>,
/// stanje artikla iz <c>out.GetSaopItemWriteState</c>, izbira metode iz
/// <see cref="SaopIntentResolver"/>. Predogled, ki bi gradil po svoje, bi lagal.
///
/// Ločnica ADD/PATCH ni izbira uporabnika in je namenoma ni v vmesniku: v stari vrsti je
/// 118 od 130 napak natanko ta ena ročna odločitev.
/// </summary>
public sealed class SaopItemWriteService(IConfiguration configuration, ILogger<SaopItemWriteService> logger)
{
  public const string TargetKind = "SAOP_PRODUCT";

  /// <summary>Zgornja meja vrstic v enem obrazcu; nad njo je pot uvoz zvezka, ne tabela.</summary>
  public const int MaxRows = 300;

  string ConnectionString => ConnectionStringResolver.Resolve(configuration)
    ?? throw new InvalidOperationException("Povezava PIM ni nastavljena.");

  /* --- pogodba dokumenta ------------------------------------------------ */

  /// <summary>Oblika dokumenta in njegova polja, z označenim lastništvom za to organizacijo.</summary>
  public async Task<SaopItemContract> GetContractAsync(int organizationId, CancellationToken cancellationToken = default)
  {
    await using var connection = await OpenAsync(cancellationToken);

    SaopDocumentShape shape;
    var contract = new List<SaopXmlField>();
    await using (var command = new SqlCommand("EXEC out.GetSaopXmlContract @TargetKind;", connection))
    {
      command.Parameters.Add("@TargetKind", SqlDbType.NVarChar, 100).Value = TargetKind;
      await using var reader = await command.ExecuteReaderAsync(cancellationToken);

      if (!await reader.ReadAsync(cancellationToken))
        throw new InvalidOperationException($"Za cilj {TargetKind} ni zapisane oblike dokumenta.");

      shape = new SaopDocumentShape(
        reader.GetString(reader.GetOrdinal("TargetKind")),
        reader.GetString(reader.GetOrdinal("EntityType")),
        reader.GetString(reader.GetOrdinal("RootElementAdd")),
        reader.GetString(reader.GetOrdinal("RootElementUpdate")),
        PimDb.Text(reader, "ItemElement"),
        reader.GetString(reader.GetOrdinal("KeyElements")).Split(SaopDocumentShape.KeySeparator),
        reader.GetString(reader.GetOrdinal("AddPath")),
        reader.GetString(reader.GetOrdinal("AddOperation")),
        reader.GetString(reader.GetOrdinal("UpdatePath")),
        reader.GetString(reader.GetOrdinal("UpdateOperation")),
        PimDb.Text(reader, "StampAddElement"),
        PimDb.Text(reader, "StampUpdateElement"),
        PimDb.Text(reader, "SuggestCodeElement"));

      await reader.NextResultAsync(cancellationToken);
      while (await reader.ReadAsync(cancellationToken))
        contract.Add(new(
          reader.GetString(reader.GetOrdinal("Section")),
          reader.GetString(reader.GetOrdinal("ElementName")),
          PimDb.Text(reader, "FieldKey"),
          reader.GetInt32(reader.GetOrdinal("SortOrder")),
          reader.GetBoolean(reader.GetOrdinal("IsAddMandatory")),
          reader.GetString(reader.GetOrdinal("ValueFormat")),
          PimDb.Text(reader, "TrueValue"),
          PimDb.Text(reader, "FalseValue"),
          reader.GetBoolean(reader.GetOrdinal("IsKey"))));
    }

    // Lastništvo je merodajno iz istega šifranta, ki ga uporabi baza ob naročilu (51010).
    // Vmesnik zato ne ponudi polja, ki bi ga out.EnqueueMessage zavrnil.
    var writable = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    await using (var command = new SqlCommand("EXEC intranet.GetWritableSaopFields @OrganizationId, @TargetKind;", connection))
    {
      command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
      command.Parameters.Add("@TargetKind", SqlDbType.NVarChar, 100).Value = TargetKind;
      await using var reader = await command.ExecuteReaderAsync(cancellationToken);
      while (await reader.ReadAsync(cancellationToken))
        writable.Add(reader.GetString(reader.GetOrdinal("FieldKey")));
    }

    var fields = contract
      .Select(field => new SaopItemFieldRow(
        field.Section, field.ElementName, field.FieldKey, field.SortOrder, field.IsAddMandatory,
        field.ValueFormat, field.TrueValue, field.FalseValue, field.IsKey,
        field.FieldKey is not null && writable.Contains(field.FieldKey)))
      .ToArray();

    logger.LogInformation(
      "SAOP artikli: pogodba prebrana — {Elementov} elementov, od tega {Pisljivih} v lasti PIM (organizacija {Organizacija}).",
      fields.Length, fields.Count(field => field.IsEditable), organizationId);

    return new(shape, contract, fields);
  }

  /* --- stanje kanala ----------------------------------------------------- */

  /// <summary>
  /// Ali je pot v SAOP sploh odprta. Brez omogočenega profila <c>out.EnqueueMessage</c> zavrne
  /// vsako sporočilo z 51001; uporabnik mora to izvedeti pred vnosom, ne po njem.
  /// </summary>
  public async Task<SaopChannelState> GetChannelStateAsync(int organizationId, CancellationToken cancellationToken = default)
  {
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand("""
      SELECT IsEnabled, ApprovalMode, EndpointTemplate,
        AddPath = ISNULL(AddPath, N'api/Item/AddItemsGeneralData'),
        UpdatePath = ISNULL(UpdatePath, N'api/Item/UpdateItemsGeneralData')
      FROM dbo.IntegrationProfile
      WHERE OrganizationId = @OrganizationId AND TargetKind = @TargetKind;
      """, connection);
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@TargetKind", SqlDbType.NVarChar, 100).Value = TargetKind;

    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    if (!await reader.ReadAsync(cancellationToken))
    {
      logger.LogWarning("SAOP artikli: organizacija {Organizacija} nima profila {Cilj}.", organizationId, TargetKind);
      return new(false, false, "ManualApproval", null, "api/Item/AddItemsGeneralData", "api/Item/UpdateItemsGeneralData");
    }

    var state = new SaopChannelState(
      true,
      PimDb.Bool(reader, "IsEnabled"),
      PimDb.TextOrEmpty(reader, "ApprovalMode"),
      PimDb.Text(reader, "EndpointTemplate"),
      PimDb.TextOrEmpty(reader, "AddPath"),
      PimDb.TextOrEmpty(reader, "UpdatePath"));

    logger.LogInformation(
      "SAOP artikli: kanal organizacije {Organizacija} — omogočen {Omogocen}, odobritev {Odobritev}.",
      organizationId, state.IsEnabled, state.ApprovalMode);
    return state;
  }

  /* --- stanje enega artikla ---------------------------------------------- */

  /// <summary>
  /// Trenutne kanonične vrednosti, privzetki in odgovor na eno vprašanje, od katerega je
  /// odvisno vse ostalo: ali SAOP ta artikel že pozna.
  /// </summary>
  public async Task<SaopItemState> GetItemStateAsync(int organizationId, string itemId, CancellationToken cancellationToken = default)
  {
    var key = (itemId ?? string.Empty).Trim();
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand("EXEC out.GetSaopItemWriteState @OrganizationId, @ItemID;", connection);
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@ItemID", SqlDbType.NVarChar, 200).Value = key;

    await using var reader = await command.ExecuteReaderAsync(cancellationToken);

    var exists = false;
    var sourceKey = "*";
    if (await reader.ReadAsync(cancellationToken))
    {
      exists = PimDb.Bool(reader, "ExistsInSaop");
      sourceKey = PimDb.TextOrEmpty(reader, "SourceKey");
    }

    var values = new Dictionary<string, string?>(StringComparer.Ordinal);
    await reader.NextResultAsync(cancellationToken);
    while (await reader.ReadAsync(cancellationToken))
      values[PimDb.TextOrEmpty(reader, "FieldKey")] = PimDb.Text(reader, "Value");

    // Privzetek za konkreten izvor prevlada nad splošnim; procedura jih vrne v tem vrstnem redu.
    var defaults = new Dictionary<string, string>(StringComparer.Ordinal);
    await reader.NextResultAsync(cancellationToken);
    while (await reader.ReadAsync(cancellationToken))
      defaults[$"{PimDb.TextOrEmpty(reader, "Section")}/{PimDb.TextOrEmpty(reader, "ElementName")}"] =
        PimDb.TextOrEmpty(reader, "Value");

    logger.LogInformation(
      "SAOP artikli: stanje {Artikel} (organizacija {Organizacija}) — v SAOP {Obstaja}, kanoničnih vrednosti {Vrednosti}, privzetkov {Privzetkov}.",
      key, organizationId, exists, values.Count, defaults.Count);

    return new(key, exists, sourceKey, values, defaults);
  }

  /* --- predogled dokumenta ----------------------------------------------- */

  /// <summary>
  /// Sestavi dokument točno tako, kot ga bo sestavil pošiljatelj: ista pogodba, isti gradnik,
  /// ista izbira metode. Pravila so v <see cref="SaopItemPlanner"/>, ker so čista logika in
  /// morajo biti preverljiva brez baze in brez spletnega projekta.
  /// </summary>
  /// <param name="changes">Vpisane vrednosti po ključu polja; prazne se izpustijo.</param>
  public static SaopItemPlan BuildPlan(
    SaopItemContract contract, SaopItemState state, IReadOnlyDictionary<string, string?> changes,
    DateTime? stampUtc = null)
  {
    ArgumentNullException.ThrowIfNull(contract);
    ArgumentNullException.ThrowIfNull(state);

    return SaopItemPlanner.Plan(
      contract.Shape, contract.Contract, state.ItemId, state.ExistsInSaop,
      state.Values, state.Defaults, changes, stampUtc ?? DateTime.UtcNow);
  }

  async Task<SqlConnection> OpenAsync(CancellationToken cancellationToken)
  {
    var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    return connection;
  }
}
