using Microsoft.Data.SqlClient;
using PIM.B2b;

namespace PIM.B2bWorker;

/// <param name="ExportProfileId">Ključ profila; procedura out.GetExportRows ga potrebuje.</param>
public sealed record ExportProfileDefinition(int ExportProfileId, string ProfileCode, IReadOnlyList<ExportColumnDefinition> Columns);

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

        await using (var command = new SqlCommand("""
            SELECT profile.ExportProfileId,
                   exportColumn.ColumnCode, exportColumn.OutputColumnName, exportColumn.CanonicalFieldCode,
                   exportColumn.SortOrder, exportColumn.IsRequired
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
                columns.Add(new ExportColumnDefinition(
                    reader.GetString(1),
                    reader.GetString(2),
                    reader.GetString(3),
                    reader.GetInt32(4),
                    reader.GetBoolean(5),
                    true));
            }
        }

        // Prazen profil ni "izvoz brez stolpcev", ampak manjkajoča ali izklopljena
        // konfiguracija. Tiho bi nastala datoteka s prazno glavo in Magento bi jo zavrnil
        // šele ob uvozu; zato pade tu, z imenom profila v sporočilu.
        if (columns.Count == 0)
            throw new ExportContractException(
                $"Izvozni profil {profileCode} v out.ExportProfile / out.ExportColumn nima nobenega aktivnega stolpca. "
                + "Preveri, ali je profil aktiven in ali so bile migracije uporabljene.");

        return new ExportProfileDefinition(exportProfileId, profileCode, columns);
    }
}
