using System.Data;
using Microsoft.Data.SqlClient;

namespace PIM.Intranet.Services;

/// <param name="SourceTable">Iz katere tabele je posnetek; <c>null</c>, kadar posnetka ni.</param>
/// <param name="LastModifiedAtUtc">Kdaj je bil zapis nazadnje spremenjen v SAOP.</param>
/// <param name="ReceivedUtc">Kdaj ga je PIM prevzel.</param>
/// <param name="Explanation">Zakaj posnetka ni. Prazno, kadar posnetek je.</param>
public sealed record SaopSnapshotHead(
  string? SourceTable, string? SourceCode, string? EntityType, long? InboxId, int? PageNumber,
  DateTime? ReceivedUtc, DateTime? LastModifiedAtUtc, bool HasSnapshot, string? Explanation);

/// <param name="HasCanonical">Ali ima element kanonicno ustreznico v PIM-u.</param>
/// <param name="IsDifferent">Odklon: PIM in SAOP se pri tem polju ne ujemata.</param>
public sealed record SaopSnapshotRow(
  string Section, int SectionSort, string ElementName, string? Value,
  string? FieldKey, string? PimValue, bool HasCanonical, bool IsDifferent, int SortOrder);

public sealed record SaopEndpointSnapshot(SaopSnapshotHead Head, IReadOnlyList<SaopSnapshotRow> Rows);

/// <summary>
/// Celoten zapis artikla iz SAOP endpointa, tak kot je prisel (<c>intranet.GetSaopEndpointSnapshot</c>,
/// migracija 141). Sluzi enemu vprasanju: kaj SAOP dejansko ima, ko se s PIM-om ne ujemata.
///
/// Zakaj svoj servis in ne <see cref="ProductWorkbenchService"/>: ta bere kanonicni model PIM-a,
/// tu pa gre za vhodni sloj in za nabor stolpcev, ki se med organizacijami razlikuje. Skupaj bi
/// bila dva razlicna vira v enem odjemalcu.
/// </summary>
public sealed class SaopEndpointSnapshotService(IConfiguration configuration)
{
  string ConnectionString => ConnectionStringResolver.Resolve(configuration)
    ?? throw new InvalidOperationException("Povezava PIM ni nastavljena.");

  public async Task<SaopEndpointSnapshot> GetAsync(int organizationId, string itemId, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.GetSaopEndpointSnapshot", connection)
    {
      CommandType = CommandType.StoredProcedure,
      // Zapis se isce po zajetih straneh odgovora; ena stran je nekaj megabajtov XML.
      CommandTimeout = 120,
    };
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@ItemId", SqlDbType.NVarChar, 64).Value = itemId;

    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    if (!await reader.ReadAsync(cancellationToken))
      return new(new(null, null, null, null, null, null, null, false, "Bralni model ni vrnil glave."), []);

    var head = new SaopSnapshotHead(
      PimDb.Text(reader, "SourceTable"), PimDb.Text(reader, "SourceCode"), PimDb.Text(reader, "EntityType"),
      NullableInt64(reader, "InboxId"), NullableInt32(reader, "PageNumber"),
      PimDb.NullableDateTime(reader, "ReceivedUtc"), PimDb.NullableDateTime(reader, "LastModifiedAtUtc"),
      PimDb.Bool(reader, "HasSnapshot"), PimDb.Text(reader, "Explanation"));

    var rows = new List<SaopSnapshotRow>();
    if (await reader.NextResultAsync(cancellationToken))
      while (await reader.ReadAsync(cancellationToken))
        rows.Add(new(
          PimDb.TextOrEmpty(reader, "Section"), Convert.ToInt32(reader["SectionSort"]),
          PimDb.TextOrEmpty(reader, "ElementName"), PimDb.Text(reader, "Value"),
          PimDb.Text(reader, "FieldKey"), PimDb.Text(reader, "PimValue"),
          PimDb.Bool(reader, "HasCanonical"), PimDb.Bool(reader, "IsDifferent"),
          Convert.ToInt32(reader["SortOrder"])));

    return new(head, rows);
  }

  static long? NullableInt64(SqlDataReader reader, string name)
  {
    var ordinal = reader.GetOrdinal(name);
    return reader.IsDBNull(ordinal) ? null : Convert.ToInt64(reader.GetValue(ordinal));
  }

  static int? NullableInt32(SqlDataReader reader, string name)
  {
    var ordinal = reader.GetOrdinal(name);
    return reader.IsDBNull(ordinal) ? null : Convert.ToInt32(reader.GetValue(ordinal));
  }
}
