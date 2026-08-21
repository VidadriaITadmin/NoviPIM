using Microsoft.Data.SqlClient;
using PIM.B2b;

namespace PIM.B2bWorker;

/// <summary>
/// Bere izvozni profil iz registra <c>out.ExportProfile</c> / <c>out.ExportColumn</c>.
///
/// Do migracije 045 je bila oblika izvoza zapisana v kodi: seznam glav v
/// <see cref="MagentoCsvContract"/> in preslikava indeks→kanonična koda kot <c>switch</c>.
/// Nov spletni kanal ali premaknjen stolpec sta zato zahtevala novo namestitev programa.
/// Zdaj je oblika vrstica v bazi, koda pa pove samo, <em>kateri</em> profil naj prebere.
///
/// Kar ostane v kodi, so poizvedbe, ki kanonične vrednosti proizvedejo
/// (<c>Product.ItemID</c>, <c>Product.PriceB2C</c>, <c>Attr.&lt;koda&gt;</c>). Register pove,
/// kam gredo, ne kako nastanejo.
/// </summary>
public static class ExportProfileRegistry
{
    public static async Task<IReadOnlyList<ExportColumnDefinition>> LoadColumnsAsync(
        SqlConnection connection,
        string profileCode,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(connection);
        ArgumentException.ThrowIfNullOrWhiteSpace(profileCode, nameof(profileCode));

        var columns = new List<ExportColumnDefinition>();

        await using (var command = new SqlCommand("""
            SELECT exportColumn.ColumnCode, exportColumn.OutputColumnName, exportColumn.CanonicalFieldCode,
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
                columns.Add(new ExportColumnDefinition(
                    reader.GetString(0),
                    reader.GetString(1),
                    reader.GetString(2),
                    reader.GetInt32(3),
                    reader.GetBoolean(4),
                    true));
        }

        // Prazen profil ni "izvoz brez stolpcev", ampak manjkajoča ali izklopljena
        // konfiguracija. Tiho bi nastala datoteka s prazno glavo in Magento bi jo zavrnil
        // šele ob uvozu; zato pade tu, z imenom profila v sporočilu.
        if (columns.Count == 0)
            throw new ExportContractException(
                $"Izvozni profil {profileCode} v out.ExportProfile / out.ExportColumn nima nobenega aktivnega stolpca. "
                + "Preveri, ali je profil aktiven in ali so bile migracije uporabljene.");

        return columns;
    }
}
