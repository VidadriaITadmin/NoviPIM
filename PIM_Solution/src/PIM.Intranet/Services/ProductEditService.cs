using System.Data;
using System.Text.Json;
using Microsoft.Data.SqlClient;

namespace PIM.Intranet.Services;

/// <param name="ChangedCount">Koliko polj je šlo skozi; 0 pomeni, da ni bilo česa spremeniti.</param>
public sealed record ProductEditOutcome(long ChangedCount, string ValidationStatus, decimal Completeness, long OpenIssueCount);

public sealed record ProductTextEdit(string Language, string TextType, string? Value);
public sealed record ProductAttributeEdit(string AttributeCode, string? Value);

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
      })), actor, note, cancellationToken);
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
    if (!await reader.ReadAsync(cancellationToken)) return new(0, "PENDING", 0, 0);
    return new(
      PimDb.Int64(reader, "ChangedCount"), PimDb.TextOrEmpty(reader, "ValidationStatus"),
      PimDb.Decimal(reader, "Completeness"), PimDb.Int64(reader, "OpenIssueCount"));
  }
}
