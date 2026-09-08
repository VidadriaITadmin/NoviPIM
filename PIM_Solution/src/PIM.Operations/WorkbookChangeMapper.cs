namespace PIM.Operations;

/// <summary>Polje, ki ga sme uporabnik urejati: kanonična koda in ime elementa v SAOP.</summary>
public sealed record WritableField(string FieldKey, string ElementName);

/// <param name="Values">Vrednosti po kanonični kodi polja; prazne celice niso vključene.</param>
public sealed record WorkbookChangeRow(int RowNumber, string ItemId, IReadOnlyDictionary<string, string> Values);

/// <param name="Unmapped">Naslovi stolpcev, ki jim ni ustrezalo nobeno pisljivo polje.</param>
public sealed record WorkbookImportPreview(
  IReadOnlyList<WorkbookChangeRow> Rows, IReadOnlyList<string> Unmapped, IReadOnlyList<string> Problems, int ChangeCount);

/// <summary>
/// Preslika tabelo iz delovnega zvezka na pisljiva polja.
///
/// Zakaj tu in ne v intranetu: to je čista logika brez baze in brez spleta. Dokler je živela v
/// spletnem projektu, je bil njen test odvisen od tega, ali se ta prevede — in zato je padel
/// zaradi kode, ki z uvozom nima nobene zveze.
///
/// Eno pravilo je pomembnejše od vseh ostalih: <b>prazna celica pomeni »tega polja se ne
/// dotakni«</b>, ne »izprazni ga«. Zvezek s stotimi stolpci ima večino celic praznih in vsaka
/// bi sicer v SAOP prepisala pravo vrednost s prazno.
/// </summary>
public static class WorkbookChangeMapper
{
  /// <summary>
  /// Naslovi stolpcev, ki pomenijo šifro artikla — zapisani v normalizirani obliki (male črke,
  /// brez presledkov in šumnikov), ker se z njo tudi primerjajo.
  /// </summary>
  public static readonly string[] KeyHeaders = ["sifraartikla", "itemid", "artikel", "sifra", "sifraizdelka"];

  public static WorkbookImportPreview Map(WorkbookSheet sheet, IReadOnlyList<WritableField> writable)
  {
    ArgumentNullException.ThrowIfNull(sheet);
    ArgumentNullException.ThrowIfNull(writable);

    var keyColumn = sheet.Headers
      .Select((header, index) => (header, index))
      .Where(pair => KeyHeaders.Contains(Normalize(pair.header)))
      .Select(pair => (int?)pair.index)
      .FirstOrDefault();

    if (keyColumn is null)
      throw new WorkbookReadException("Zvezek nima stolpca s šifro artikla. Poimenuj ga 'Šifra artikla' ali 'ItemID'.");

    // Stolpec se prepozna po kanonični kodi ali po imenu elementa v SAOP; oboje je uporabniku
    // vidno v seznamu pisljivih polj, zato je oboje dovoljeno.
    var byColumn = new Dictionary<int, WritableField>();
    var unmapped = new List<string>();
    for (var index = 0; index < sheet.Headers.Count; index++)
    {
      if (index == keyColumn) continue;
      var header = Normalize(sheet.Headers[index]);
      if (header.Length == 0) continue;
      var match = writable.FirstOrDefault(candidate =>
        Normalize(candidate.FieldKey) == header || Normalize(candidate.ElementName) == header);
      if (match is null) unmapped.Add(sheet.Headers[index]); else byColumn[index] = match;
    }

    var rows = new List<WorkbookChangeRow>();
    var problems = new List<string>();
    var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    var changeCount = 0;

    for (var index = 0; index < sheet.Rows.Count; index++)
    {
      var cells = sheet.Rows[index];
      // Prva vrstica zvezka so naslovi, zato je prva podatkovna vrstica druga.
      var rowNumber = index + 2;
      var itemId = cells[keyColumn.Value].Trim();
      if (itemId.Length == 0) continue;

      if (!seen.Add(itemId))
        problems.Add($"Vrstica {rowNumber}: artikel {itemId} je v zvezku večkrat; upoštevana bo prva.");

      var values = new Dictionary<string, string>(StringComparer.Ordinal);
      foreach (var (column, field) in byColumn)
      {
        var value = cells[column].Trim();
        if (value.Length == 0) continue;
        values[field.FieldKey] = value;
      }

      if (values.Count == 0) continue;
      rows.Add(new(rowNumber, itemId, values));
      changeCount += values.Count;
    }

    if (rows.Count == 0) problems.Add("V zvezku ni nobene vrstice z izpolnjenim pisljivim poljem.");
    return new(rows, unmapped, problems, changeCount);
  }

  /// <summary>Pravilo je eno samo in zivi v <see cref="WorkbookHeader"/>; tu je samo krajsi zapis.</summary>
  static string Normalize(string value) => WorkbookHeader.Normalize(value);
}
