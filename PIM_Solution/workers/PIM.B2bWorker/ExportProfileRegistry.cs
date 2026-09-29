using Microsoft.Data.SqlClient;
using PIM.B2b;

namespace PIM.B2bWorker;

/// <param name="ExportProfileId">Ključ profila; procedura out.GetExportRows ga potrebuje.</param>
/// <param name="FieldDelimiter">Ločilo stolpcev (<c>out.ExportProfile.FieldDelimiter</c>, 277): katalog.csv »;«, ostali »,«.</param>
public sealed record ExportProfileDefinition(int ExportProfileId, string ProfileCode, IReadOnlyList<ExportColumnDefinition> Columns, char FieldDelimiter = ',');

/// <summary>
/// Bere izvozni profil iz registra <c>out.ExportProfile</c> / <c>out.ExportColumn</c>.
///
/// Do migracije 045 je bila oblika izvoza zapisana v kodi: seznam glav v
/// <see cref="MagentoCsvContract"/> in preslikava indeks→kanonična koda kot <c>switch</c>.
/// Nov spletni kanal ali premaknjen stolpec sta zato zahtevala novo namestitev programa.
/// Zdaj je oblika vrstica v bazi, koda pa pove samo, <em>kateri</em> profil naj prebere.
///
/// Od migracije 142 tudi poizvedbe, ki kanonične vrednosti proizvedejo, niso več v kodi:
/// zanje skrbi <c>out.GetExportRows</c>, ki bere isti register. Tu ostane samo branje
/// profila — kateri profil, koliko stolpcev in kateri od njih so obvezni.
/// </summary>
public static class ExportProfileRegistry
{
    public static async Task<IReadOnlyList<ExportColumnDefinition>> LoadColumnsAsync(
        SqlConnection connection,
        string profileCode,
        CancellationToken cancellationToken = default)
        => (await LoadProfileAsync(connection, profileCode, cancellationToken)).Columns;

    /// <summary>
    /// Profil s ključem in stolpci. Ključ potrebuje <c>out.GetExportRows</c>, ki po istem
    /// registru sestavi tudi vrstice — glava in vsebina zato ne moreta priti iz dveh profilov.
    /// </summary>
    public static async Task<ExportProfileDefinition> LoadProfileAsync(
        SqlConnection connection,
        string profileCode,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(connection);
        ArgumentException.ThrowIfNullOrWhiteSpace(profileCode, nameof(profileCode));

        var columns = new List<ExportColumnDefinition>();
        var exportProfileId = 0;
        var delimiter = ',';

        // 277: oblika števila (decimalna vejica), varovani stolpci in ločilo stolpcev. Na bazi pred 277 stolpcev
        // še ni — worker, nameščen pred migracijo, piše kot doslej, namesto da bi izvoz padel.
        var hasFormat = await HasFormatColumnsAsync(connection, cancellationToken);
        await using (var command = new SqlCommand($"""
            SELECT profile.ExportProfileId,
                   exportColumn.ColumnCode, exportColumn.OutputColumnName, exportColumn.CanonicalFieldCode,
                   exportColumn.SortOrder, exportColumn.IsRequired,
                   {(hasFormat ? "exportColumn.DecimalSeparator, exportColumn.GuardKind, profile.FieldDelimiter" : "CAST(NULL AS nchar(1)), CAST(NULL AS nvarchar(20)), CAST(N',' AS nchar(1))")}
            FROM out.ExportColumn exportColumn
            INNER JOIN out.ExportProfile profile ON profile.ExportProfileId = exportColumn.ExportProfileId
            WHERE profile.ProfileCode = @ProfileCode AND profile.IsActive = 1 AND exportColumn.IsActive = 1
            ORDER BY exportColumn.SortOrder;
            """, connection) { CommandTimeout = 60 })
        {
            command.Parameters.AddWithValue("@ProfileCode", profileCode);
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            while (await reader.ReadAsync(cancellationToken))
            {
                exportProfileId = reader.GetInt32(0);
                if (!reader.IsDBNull(8) && reader.GetString(8) is { Length: 1 } profileDelimiter) delimiter = profileDelimiter[0];
                columns.Add(new ExportColumnDefinition(
                    reader.GetString(1),
                    reader.GetString(2),
                    reader.GetString(3),
                    reader.GetInt32(4),
                    reader.GetBoolean(5),
                    true,
                    reader.IsDBNull(6) ? null : reader.GetString(6),
                    reader.IsDBNull(7) ? null : reader.GetString(7)));
            }
        }

        // Prazen profil ni "izvoz brez stolpcev", ampak manjkajoča ali izklopljena
        // konfiguracija. Tiho bi nastala datoteka s prazno glavo in Magento bi jo zavrnil
        // šele ob uvozu; zato pade tu, z imenom profila v sporočilu.
        if (columns.Count == 0)
            throw new ExportContractException(
                $"Izvozni profil {profileCode} v out.ExportProfile / out.ExportColumn nima nobenega aktivnega stolpca. "
                + "Preveri, ali je profil aktiven in ali so bile migracije uporabljene.");

        return new ExportProfileDefinition(exportProfileId, profileCode, columns, delimiter);
    }

    static async Task<bool> HasFormatColumnsAsync(SqlConnection connection, CancellationToken cancellationToken)
    {
        await using var command = new SqlCommand(
            "SELECT CASE WHEN COL_LENGTH(N'out.ExportColumn', N'DecimalSeparator') IS NOT NULL AND COL_LENGTH(N'out.ExportColumn', N'GuardKind') IS NOT NULL "
            + "AND COL_LENGTH(N'out.ExportProfile', N'FieldDelimiter') IS NOT NULL THEN 1 ELSE 0 END;",
            connection) { CommandTimeout = 30 };
        return Convert.ToInt32(await command.ExecuteScalarAsync(cancellationToken)) == 1;
    }
}
