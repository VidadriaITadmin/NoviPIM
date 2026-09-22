using System.Data;
using Microsoft.Data.SqlClient;

namespace PIM.Intranet.Services;

/// <param name="ItemIdFromEan">Dobavitelj sifre ne posilja; kandidat (in ob odobritvi artikel) je kljucan po EAN (240).</param>
/// <param name="SupplierTitle">Dobaviteljev naziv iz istega zajema, kadar ga vir sploh preslika; sicer null.</param>
/// <param name="ProductItemId">Trenutna sifra ustvarjenega artikla (241): po prevzemu sifre iz SAOP se razlikuje od kljuca kandidata.</param>
/// <param name="ErpExistence"><c>NOT_YET_IN_ERP</c> ali <c>CONFIRMED_IN_ERP</c> ustvarjenega artikla; null, dokler artikla ni.</param>
/// <param name="SaopState">Stanje odobrenega kandidata na poti v SAOP (241): NOT_QUEUED, QUEUED, SENT, FAILED, CONFIRMED; null za neodobrene.</param>
/// <param name="SaopLiveMessages">Sporocila artikla, ki v vrsti se cakajo (odobritev, posiljanje, ponovni poskus).</param>
/// <param name="SaopPendingApproval">Od tega taka, ki cakajo na odobritev.</param>
/// <param name="SaopLastStatus">Stanje zadnjega sporocila artikla v odhodni vrsti.</param>
/// <param name="SaopAssignedItemId">Sifra, ki jo je SAOP dodelil ob ADD; ob koliziji edino mesto, kjer jo urednik vidi.</param>
public sealed record SupplierProductCandidateRow(
  long SupplierProductCandidateId, int OrganizationId, string OrganizationName, string SourceCode,
  string ItemId, string? Ean, string Status, bool IsActive, DateTime FirstSeenUtc, DateTime LastSeenUtc,
  int OccurrenceCount, DateTime? DecidedUtc, string? DecidedBy, string? DecisionReason, long? CreatedProductId,
  bool ItemIdFromEan, Guid RunId, string EntityType, string? SupplierTitle,
  string? ProductItemId, string? ErpExistence, string? SaopState, int SaopLiveMessages, int SaopPendingApproval,
  string? SaopLastStatus, long? SaopLastBatchId, DateTime? SaopLastUpdatedUtc, string? SaopLastError, string? SaopAssignedItemId)
{
  /// <summary>Sifra, pod katero je artikel danes v PIM; pred uvozom kljuc kandidata.</summary>
  public string CurrentItemId => ProductItemId ?? ItemId;

  /// <summary>Ali je kandidat uvozen, artikla pa v SAOP se ni in v vrsti ne caka nic (241) — »porini v SAOP«.</summary>
  public bool CanQueueForSaop => Status == "PENDING" && CreatedProductId is null && SaopState is "NOT_QUEUED" or "FAILED";

  /// <summary>Ali je kandidat uvozen, SAOP pa artikla se ne pozna (ne glede na vrsto).</summary>
  public bool IsNotYetInErp => CreatedProductId is null || ErpExistence == "NOT_YET_IN_ERP";
}

/// <param name="ImportedWaitingCount">Uvozeni artikli, ki v SAOP se niso in ne cakajo v vrsti (241).</param>
/// <param name="QueuedCount">Uvozeni artikli s sporocili v vrsti (cakajo odobritev ali posiljanje).</param>
/// <param name="SentCount">Poslani, SAOP pa jih se ni potrdil (sifra/zastavica se ni prevzeta).</param>
/// <param name="FailedCount">Zadnji poskus v SAOP je bil zavrnjen.</param>
/// <param name="ConfirmedCount">Artikel obstaja v SAOP (CONFIRMED_IN_ERP).</param>
public sealed record SupplierProductCandidateTotals(
  long TotalCount, long PendingCount, long ApprovedCount, long RejectedCount,
  long ImportedWaitingCount = 0, long QueuedCount = 0, long SentCount = 0, long FailedCount = 0, long ConfirmedCount = 0);

public sealed record SupplierProductCandidatePage(
  IReadOnlyList<SupplierProductCandidateRow> Rows, SupplierProductCandidateTotals Totals);

/// <summary>Ena izluscena vrednost iz dobaviteljevega XML-ja za pregled kandidata (240).</summary>
public sealed record SupplierCandidateValueRow(string EntityType, string TargetFieldCode, int ValueOrdinal, string Value)
{
  public bool IsMedia => TargetFieldCode.StartsWith("ProductMedia.", StringComparison.OrdinalIgnoreCase);
  public bool IsDocument => TargetFieldCode.StartsWith("ProductDocument.", StringComparison.OrdinalIgnoreCase);
  public bool IsCategory => TargetFieldCode.StartsWith("ProductCategory.", StringComparison.OrdinalIgnoreCase);
  public bool IsAttribute => TargetFieldCode.StartsWith("ProductAttribute.", StringComparison.OrdinalIgnoreCase);
  public bool IsText => TargetFieldCode.StartsWith("ProductText.", StringComparison.OrdinalIgnoreCase);
  public bool IsUrl => Value.StartsWith("http://", StringComparison.OrdinalIgnoreCase) || Value.StartsWith("https://", StringComparison.OrdinalIgnoreCase) || Value.StartsWith("//", StringComparison.Ordinal);

  /// <summary>Ime brez predpone entitete: »ProductAttribute.Nazivna moč« → »Nazivna moč«.</summary>
  public string Label
  {
    get
    {
      var dot = TargetFieldCode.IndexOf('.');
      var rest = dot < 0 ? TargetFieldCode : TargetFieldCode[(dot + 1)..];
      return IsText ? ProductFieldLabels.TextTypeLabel(rest.Split('.')[0]) + (rest.Contains('.') ? " (" + rest.Split('.')[1] + ")" : "") : rest;
    }
  }

  /// <summary>Skupina za prikaz: besedila, kategorija, atributi, slike, dokumenti, ostalo.</summary>
  public string Group => IsText ? "Nazivi in opisi" : IsCategory ? "Kategorija dobavitelja" : IsAttribute ? "Atributi"
    : IsMedia ? "Slike" : IsDocument ? "Dokumenti" : "Identiteta in ostalo";
}

/// <summary>
/// Bralni model kandidatov za nove artikle od dobaviteljev (219, 240, 241). SQL ostane v migraciji;
/// tu je samo klic procedure in preslikava stolpcev po imenu.
/// </summary>
public sealed class SupplierCandidateReadService(IConfiguration configuration)
{
  string ConnectionString => ConnectionStringResolver.Resolve(configuration)
    ?? throw new InvalidOperationException("Povezava PIM ni nastavljena.");

  /// <param name="saopState">241: NOT_QUEUED, QUEUED, SENT, FAILED ali CONFIRMED; null = brez filtra. Velja samo za odobrene.</param>
  public async Task<SupplierProductCandidatePage> GetCandidatesAsync(
    int? organizationId, string? sourceCode, string? status, string? search, int skip, int take,
    string? saopState = null, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.GetSupplierProductCandidates", connection)
    { CommandType = CommandType.StoredProcedure, CommandTimeout = 60 };
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = (object?)organizationId ?? DBNull.Value;
    command.Parameters.Add("@SourceCode", SqlDbType.NVarChar, 100).Value = Optional(sourceCode);
    command.Parameters.Add("@Status", SqlDbType.NVarChar, 20).Value = Optional(status);
    command.Parameters.Add("@Search", SqlDbType.NVarChar, 200).Value = Optional(search);
    command.Parameters.Add("@Skip", SqlDbType.Int).Value = skip;
    command.Parameters.Add("@Take", SqlDbType.Int).Value = take;
    command.Parameters.Add("@SaopState", SqlDbType.NVarChar, 20).Value = Optional(saopState);

    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    var rows = new List<SupplierProductCandidateRow>();
    while (await reader.ReadAsync(cancellationToken))
      rows.Add(new(
        PimDb.Int64(reader, "SupplierProductCandidateId"), PimDb.Int32(reader, "OrganizationId"),
        PimDb.TextOrEmpty(reader, "OrganizationName"), PimDb.TextOrEmpty(reader, "SourceCode"),
        PimDb.TextOrEmpty(reader, "ItemID"), PimDb.Text(reader, "EAN"), PimDb.TextOrEmpty(reader, "Status"),
        PimDb.Bool(reader, "IsActive"), PimDb.DateTimeValue(reader, "FirstSeenUtc"), PimDb.DateTimeValue(reader, "LastSeenUtc"),
        PimDb.Int32(reader, "OccurrenceCount"), PimDb.NullableDateTime(reader, "DecidedUtc"), PimDb.Text(reader, "DecidedBy"),
        PimDb.Text(reader, "DecisionReason"), PimDb.NullableInt64(reader, "CreatedProductId"),
        PimDb.Bool(reader, "ItemIdFromEan"), reader.GetGuid(reader.GetOrdinal("RunId")),
        PimDb.TextOrEmpty(reader, "EntityType"), PimDb.Text(reader, "SupplierTitle"),
        PimDb.Text(reader, "ProductItemId"), PimDb.Text(reader, "ErpExistence"), PimDb.Text(reader, "SaopState"),
        PimDb.Int32(reader, "SaopLiveMessages"), PimDb.Int32(reader, "SaopPendingApproval"),
        PimDb.Text(reader, "SaopLastStatus"), PimDb.NullableInt64(reader, "SaopLastBatchId"),
        PimDb.NullableDateTime(reader, "SaopLastUpdatedUtc"), PimDb.Text(reader, "SaopLastError"),
        PimDb.Text(reader, "SaopAssignedItemId")));

    if (!await reader.NextResultAsync(cancellationToken))
      throw new InvalidOperationException("Bralna procedura kandidatov ni vrnila povzetka.");
    var totals = new SupplierProductCandidateTotals(0, 0, 0, 0);
    if (await reader.ReadAsync(cancellationToken))
      totals = new(
        PimDb.Int64(reader, "TotalCount"), PimDb.Int64(reader, "PendingCount"),
        PimDb.Int64(reader, "ApprovedCount"), PimDb.Int64(reader, "RejectedCount"),
        PimDb.Int64(reader, "ImportedWaitingCount"), PimDb.Int64(reader, "QueuedCount"),
        PimDb.Int64(reader, "SentCount"), PimDb.Int64(reader, "FailedCount"), PimDb.Int64(reader, "ConfirmedCount"));
    return new(rows, totals);
  }

  /// <summary>Vse, kar je dobavitelj v tem zajemu poslal za ta artikel (240) — pregled pred odlocitvijo.</summary>
  public async Task<IReadOnlyList<SupplierCandidateValueRow>> GetValuesAsync(long candidateId, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.GetSupplierProductCandidateValues", connection)
    { CommandType = CommandType.StoredProcedure, CommandTimeout = 120 };
    command.Parameters.Add("@SupplierProductCandidateId", SqlDbType.BigInt).Value = candidateId;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    var rows = new List<SupplierCandidateValueRow>();
    while (await reader.ReadAsync(cancellationToken))
      rows.Add(new(
        PimDb.TextOrEmpty(reader, "EntityType"), PimDb.TextOrEmpty(reader, "TargetFieldCode"),
        PimDb.Int32(reader, "ValueOrdinal"), PimDb.TextOrEmpty(reader, "Value")));
    return rows;
  }

  static object Optional(string? value) => string.IsNullOrWhiteSpace(value) ? DBNull.Value : value.Trim();
}
