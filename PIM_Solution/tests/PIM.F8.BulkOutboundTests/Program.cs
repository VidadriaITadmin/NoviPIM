using System.Data;
using System.IO.Compression;
using System.Text;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using PIM.Operations;

// F8 — množično urejanje, uvoz delovnega zvezka in obvestila.
//
// Trije deli, vsak s svojim merilom:
//   1. WorkbookTable — bere pravi .xlsx, ki ga test sam sestavi; nobene zunanje datoteke.
//   2. WorkbookChangeMapper — preslikava na pisljiva polja; čista logika, brez baze.
//   3. Množično naročilo, prekrivka in obvestila proti bazi PIM, v izolirani organizaciji 9822.
//
// Namenoma brez sklica na PIM.Intranet: dokaz odhodne poti ne sme pasti zaradi kode spletnega
// projekta, ki z njo nima zveze. Pogodba, ki šteje, je v bazi.
//
// Nobenega omrežnega klica. V SAOP ne gre nič.

const int organizationId = 9822;

/* --- 1) Branje delovnega zvezka ------------------------------------------------------ */

using (var workbook = new MemoryStream(BuildWorkbook(
  ["Šifra artikla", "ItemEANCode", "Naziv v ERP", "Prazen stolpec"],
  [
    ["NW.1", "3830000000001", "Prvi naziv", ""],
    ["NW.2", "", "Drugi naziv", ""],
    // Vrstica s praznino v sredini: Excel tako celico izpusti in jo je treba razbrati iz sklica.
    ["NW.3", "3830000000003", "", ""],
    ["", "", "", ""]
  ])))
{
  var sheet = WorkbookTable.Read(workbook);
  Equal(4, sheet.Headers.Count, "Prebrati je treba vse naslove stolpcev");
  Equal("Šifra artikla", sheet.Headers[0], "Prvi naslov mora ostati nedotaknjen, s šumniki vred");
  Equal(3, sheet.Rows.Count, "Popolnoma prazna vrstica ni vrstica");
  Equal("NW.2", sheet.Rows[1][0], "Vrstica s praznino v sredini se ne sme zamakniti");
  Equal("", sheet.Rows[1][1], "Izpuščena celica mora ostati prazna, ne prevzeti sosednje vrednosti");
  Equal("Drugi naziv", sheet.Rows[1][2], "Vrednost za praznino mora ostati v svojem stolpcu");
}

Throws<WorkbookReadException>(() =>
{
  using var prazen = new MemoryStream(BuildWorkbook(["Samo en stolpec"], []));
  WorkbookTable.Read(prazen);
}, "Zvezek brez uporabne naslovne vrstice mora pasti razumljivo");

/* --- 1b) Zapis delovnega zvezka: kar zapisemo, mora biti mogoce prebrati nazaj -------- */

// Dokaz, da je zapisana datoteka pravi .xlsx, je branje z isto potjo, ki bere Excelove
// datoteke dobaviteljev. Ce bi bil zapis pokvarjen, bi WorkbookTable.Read padel.
{
  var written = WorkbookWriter.Write(
    "Izdelki",
    [
      new("Sifra", WorkbookCellKind.Text),
      new("Naziv", WorkbookCellKind.Text),
      new("Popolnost", WorkbookCellKind.Percent),
      new("Tezav", WorkbookCellKind.Number),
      new("Zadnja sprememba", WorkbookCellKind.DateTime),
      new("Objavljen", WorkbookCellKind.Text),
    ],
    [
      ["0000000000001", "Sijalka <E14> & \"plamen\"", 42.5m, 6L, new DateTime(2026, 8, 27, 14, 5, 0), true],
      ["NW.12603", null, 0m, 0L, null, false],
    ],
    ["Izvozenih 2 od 5 vrstic pogleda."]);

  using var reread = new MemoryStream(written);
  var sheet = WorkbookTable.Read(reread);
  Equal(6, sheet.Headers.Count, "Zapisani zvezek mora imeti vseh sest naslovov");
  Equal("Zadnja sprememba", sheet.Headers[4], "Naslov stolpca mora priti nazaj nespremenjen");
  Equal("0000000000001", sheet.Rows[0][0], "Sifra artikla mora ostati besedilo z vodilnimi niclami");
  Equal("Sijalka <E14> & \"plamen\"", sheet.Rows[0][1], "Znaki XML v nazivu ne smejo pokvariti zvezka");
  Equal("da", sheet.Rows[0][5], "Logicna vrednost se zapise kot da/ne");
  Equal("ne", sheet.Rows[1][5], "Logicna vrednost se zapise kot da/ne");
  Equal("", sheet.Rows[1][1], "Prazna vrednost mora ostati prazna celica");
  Assert(sheet.Rows.Any(row => row[0].StartsWith("Izvozenih", StringComparison.Ordinal)),
    "Opomba o odrezanem izvozu mora biti zapisana v datoteko, ne samo na zaslon");

  // Zvezek mora nositi tudi obliko: brez sloga bi bil datum videti kot stevilo 46261.
  using var archive = new ZipArchive(new MemoryStream(written), ZipArchiveMode.Read);
  foreach (var part in new[] { "[Content_Types].xml", "_rels/.rels", "xl/workbook.xml", "xl/_rels/workbook.xml.rels", "xl/styles.xml", "xl/worksheets/sheet1.xml" })
    Assert(archive.GetEntry(part) is not null, "Zvezku manjka del " + part);
  using var sheetPart = new StreamReader(archive.GetEntry("xl/worksheets/sheet1.xml")!.Open());
  var sheetXml = sheetPart.ReadToEnd();
  Assert(sheetXml.Contains("state=\"frozen\"", StringComparison.Ordinal), "Naslovna vrstica mora biti zamrznjena");
  Assert(sheetXml.Contains("<autoFilter", StringComparison.Ordinal), "Tabela mora imeti samodejni filter");
}

/* --- 1c) Skupine stolpcev in barvne oznake ------------------------------------------- */

// Zahteva uporabnika 2026-08-28: v izvozu morajo biti podatki ERP, komerciala in splet, polja,
// ki pri izdelku manjkajo, morajo biti blago rdeca, polja, ki so pogoj za validacijo, pa
// rumenkasta. Brez tega je treba vsak stolpec preverjati rocno.
{
  var written = WorkbookWriter.Write(
    "Izdelki",
    [
      new("Sifra", WorkbookCellKind.Text, 0, "Istovetnost"),
      new("EAN", WorkbookCellKind.Text, 0, "ERP", WorkbookCellTone.Required),
      new("Enota mere", WorkbookCellKind.Text, 0, "ERP"),
      new("Spletni naziv", WorkbookCellKind.Text, 0, "Splet", WorkbookCellTone.Required),
    ],
    [
      ["0000000000001", new WorkbookCell("3830000000001"), new WorkbookCell("KOS"), new WorkbookCell(null, WorkbookCellTone.Missing)],
    ]);

  // Skupine dobi samo list »pregled«, ki ga bere clovek. Predloga SAOP, ki se ureja in vraca
  // skozi WorkbookTable.Read, ostane brez skupin — tam je prva vrstica ime stolpca in nic
  // drugega. Tu se to izrecno preveri, da nihce ne doda skupin v predlogo za vracanje.
  using var reread = new MemoryStream(written);
  var sheet = WorkbookTable.Read(reread);
  Equal("Istovetnost", sheet.Headers[0], "Bralec vzame prvo vrstico; grupiran list zato ni pot za vracanje");
  Equal("Sifra", sheet.Rows[0][0], "Imena stolpcev so v drugi vrstici, takoj pod skupinami");
  Equal("3830000000001", sheet.Rows[1][1], "Vrednost v oznaceni celici mora priti nazaj nespremenjena");

  using var archive = new ZipArchive(new MemoryStream(written), ZipArchiveMode.Read);
  using var sheetPart = new StreamReader(archive.GetEntry("xl/worksheets/sheet1.xml")!.Open());
  var sheetXml = sheetPart.ReadToEnd();
  Assert(sheetXml.Contains("<t xml:space=\"preserve\">Istovetnost</t>", StringComparison.Ordinal),
    "Nad stolpci mora stati vrstica s skupinami");
  Assert(sheetXml.Contains("ySplit=\"2\"", StringComparison.Ordinal),
    "Pri dveh naslovnih vrsticah morata biti zamrznjeni obe");
  Assert(sheetXml.Contains("<autoFilter ref=\"A2:", StringComparison.Ordinal),
    "Samodejni filter mora stati na vrstici z imeni stolpcev, ne na skupinah");
  // Slog 11 je rumena glava, slog 4 rdeca prazna celica; brez njiju oznake v Excelu ni.
  Assert(sheetXml.Contains(" s=\"11\"", StringComparison.Ordinal),
    "Zahtevano polje mora imeti rumeno glavo");
  Assert(sheetXml.Contains(" s=\"4\"", StringComparison.Ordinal),
    "Manjkajoca vrednost mora imeti rdeco podlago");

  using var stylesPart = new StreamReader(archive.GetEntry("xl/styles.xml")!.Open());
  var stylesXml = stylesPart.ReadToEnd();
  foreach (var fill in new[] { "FFF6D6D6", "FFFCEFC0" })
    Assert(stylesXml.Contains(fill, StringComparison.Ordinal), "Manjka polnilo " + fill);
}

/* --- 2) Preslikava zvezka na pisljiva polja ------------------------------------------ */

var writable = new[]
{
  new WritableField("Product.EAN", "ItemEANCode"),
  new WritableField("ProductText.TITLE_ERP.sl", "ItemTitle1")
};

using (var workbook = new MemoryStream(BuildWorkbook(
  ["Šifra artikla", "ItemEANCode", "ItemTitle1", "Neznan stolpec"],
  [
    ["NW.1", "3830000000001", "Prvi", "karkoli"],
    ["NW.2", "", "Drugi", ""],
    ["NW.1", "3830000000009", "", ""],
    ["NW.3", "", "", ""]
  ])))
{
  var preview = WorkbookChangeMapper.Map(WorkbookTable.Read(workbook), writable);

  Equal(3, preview.Rows.Count, "Vrstica brez ene same izpolnjene celice ni sprememba");
  Equal(4, preview.ChangeCount, "Prešteti je treba spremembe, ne vrstic");
  Equal(true, preview.Unmapped.Contains("Neznan stolpec"), "Stolpec brez ustreznega polja mora biti naveden");
  Equal(false, preview.Unmapped.Contains("Šifra artikla"), "Ključni stolpec ni neprepoznan stolpec");
  Equal(true, preview.Problems.Any(problem => problem.Contains("NW.1")), "Podvojen artikel mora biti opozorilo");

  // Prazna celica pomeni "tega polja se ne dotakni". Nasprotna razlaga bi v SAOP prepisala
  // pravo vrednost s prazno, in to na vsakem stolpcu, ki ga uporabnik ni izpolnil.
  var drugi = preview.Rows.Single(row => row.ItemId == "NW.2");
  Equal(1, drugi.Values.Count, "Prazna celica ne sme postati sprememba");
  Equal(true, drugi.Values.ContainsKey("ProductText.TITLE_ERP.sl"), "Izpolnjena celica mora postati sprememba");
}

// Zvezek brez stolpca s šifro ni uvozljiv; brez ključa se ne ve, kateremu artiklu sprememba pripada.
Throws<WorkbookReadException>(() =>
{
  using var brezKljuca = new MemoryStream(BuildWorkbook(["Naziv", "ItemEANCode"], [["a", "b"]]));
  WorkbookChangeMapper.Map(WorkbookTable.Read(brezKljuca), writable);
}, "Zvezek brez šifre artikla mora biti zavrnjen z jasnim razlogom");

/* --- 3) Množično naročilo, prekrivka in obvestila proti bazi ------------------------- */

var connectionString = ReadConnectionString();
if (string.IsNullOrWhiteSpace(connectionString))
{
  Console.WriteLine("F8 množično: del z bazo preskočen, lokalna PIM povezava ni na voljo.");
  Console.WriteLine("F8 množično: branje zvezka in preslikava na pisljiva polja PASS.");
  return 0;
}

var settings = new SqlConnectionStringBuilder(connectionString);
if (!string.Equals(settings.InitialCatalog, "PIM", StringComparison.OrdinalIgnoreCase))
  throw new InvalidOperationException("F8 dokaz je dovoljen samo v razvojni bazi PIM.");

await using var connection = new SqlConnection(connectionString);
await connection.OpenAsync();

try
{
  await SetupAsync();

  var fields = await ReadWritableFieldsAsync();
  Equal(2, fields.Count, "Ponudi se samo tisto, kar je v lasti PIM in del dokumenta");
  Equal(false, fields.Contains("Product.ItemGroup"), "Polje v lasti SAOP se ne sme ponuditi");

  // Mešanica: dve veljavni, ena za polje v lasti SAOP, ena za neobstoječe polje, ena podvojena.
  var (batchId, results) = await EnqueueManyAsync(
  [
    ("F8B-1", "ProductText.TITLE_ERP.sl", "Naziv ena"),
    ("F8B-1", "Product.EAN", "3830000000041"),
    ("F8B-2", "Product.ItemGroup", "SKUPINA"),
    ("F8B-2", "Product.Izmisljeno", "x"),
    ("F8B-1", "ProductText.TITLE_ERP.sl", "Naziv ena")
  ]);

  Equal(5, results.Count, "Vsaka vhodna vrstica mora imeti svoj izid");
  Equal(2, results.Count(row => row.Status == "Queued"), "Veljavni vrstici morata biti uvrščeni");
  Equal(1, results.Count(row => row.Status == "Duplicate"), "Enaka sprememba se ne sme uvrstiti dvakrat");
  Equal(2, results.Count(row => row.Status == "Rejected"), "Polje v lasti SAOP in neobstoječe polje morata pasti");
  // Ena slaba vrstica ne sme podreti uvoza — to je bistvo množične poti.
  Equal(true, results.Where(row => row.Status == "Rejected").All(row => !string.IsNullOrWhiteSpace(row.Reason)),
    "Vsaka zavrnitev mora povedati razlog");

  var overlay = await ReadOverlayAsync();
  Equal(2, overlay.Count, "Prekrivka mora pokazati obe čakajoči vrednosti");
  Equal(true, overlay.All(row => row.Status == "PendingApproval"), "Brez odobritve sprememba ne gre v vrsto");
  Equal(true, overlay.Any(row => row.Value == "3830000000041"), "Prekrivka nosi želeno vrednost, ne kanonične");

  Equal(2, await ScalarIntAsync($"EXEC out.ApproveOutboundBatch {batchId}, N'F8B';"),
    "Odobri se skupina, ne sporočilo po sporočilo");
  Equal(true, (await ReadOverlayAsync()).All(row => row.Status == "Pending"),
    "Po odobritvi sporočilo čaka na pošiljanje");

  Equal(1, await ScalarIntAsync(
    $"SELECT COUNT(DISTINCT EntityKey) FROM out.OutboxMessage WHERE OutboundBatchId={batchId};"),
    "Skupina zajema en artikel");
  Equal(2, await ScalarIntAsync($"SELECT COUNT(*) FROM out.OutboxMessage WHERE OutboundBatchId={batchId};"),
    "Skupina zajema dve sporočili");

  /* --- obvestila in stopnjevanje ---------------------------------------------------- */

  await RecordEventAsync("Failed", "Error", "SAOP je zavrnil spremembo.",
    "Carinska tarifa ni v šifrantu SAOP. Popravi jo na artiklu ali naj jo skrbnik doda.");
  await RecordEventAsync("Sent", "Info", "Sprememba je sprejeta v SAOP.", null);

  Equal(1, await ScalarIntAsync(
    "SELECT COUNT(*) FROM ops.OutboundEvent WHERE OrganizationId=@Org AND Severity=N'Error' AND AcknowledgedUtc IS NULL;"),
    "Napaka mora biti vidna");
  Equal(1, await ScalarIntAsync(
    "SELECT COUNT(*) FROM ops.OutboundEvent WHERE OrganizationId=@Org AND Severity=N'Info';"),
    "Uspeh mora biti tih, a zabeležen");

  var open = await ReadOpenEventsAsync();
  Equal(1, open.Count, "Odprt pogled kaže samo tisto, kar zahteva ukrep");
  Equal(true, open[0].Detail!.Contains("šifrant"), "Obvestilo mora nositi navodilo, ne surovega izpisa");

  // Napaka, mlajša od praga, se ne stopnjuje. Brez tega bi vsaka napaka takoj sprožila e-pošto.
  Equal(0, await EscalateAsync(300), "Sveža napaka se ne sme stopnjevati");

  // Prag 0 sekund pomeni "vse nepotrjene napake" — s tem se dokaže pot, ne da bi test čakal pet minut.
  Equal(1, await EscalateAsync(0), "Nepotrjena napaka se mora stopnjevati");
  Equal(1, await ScalarIntAsync(
    "SELECT COUNT(*) FROM ops.Alert WHERE OrganizationId=@Org AND AlertKind=N'OutboundUnacknowledged';"),
    "Stopnjevanje mora ustvariti opozorilo");
  Equal(0, await EscalateAsync(0), "Isto obvestilo se ne sme stopnjevati dvakrat");

  await SqlAsync($"EXEC intranet.AcknowledgeOutboundEvent {open[0].EventId}, N'F8B';");
  Equal(0, (await ReadOpenEventsAsync()).Count, "Potrjena napaka izgine iz odprtega pogleda");

  /* --- varen ponovni poskus neuspelih SAOP sporocil -------------------------------- */

  var messageIds = await ReadMessageIdsAsync(batchId);
  Equal(2, messageIds.Count, "Dokaz ponovnega poskusa potrebuje obe sporocili skupine");
  await SqlAsync($"""
    UPDATE out.OutboxMessage
       SET Status = CASE WHEN OutboxMessageId={messageIds[0]} THEN N'Error' ELSE N'Dead' END,
           AttemptCount = 1,
           LastError = N'F8B namerna napaka',
           LeaseOwner = NULL,
           LeaseUntilUtc = NULL
     WHERE OrganizationId=@Org AND OutboundBatchId={batchId};
    INSERT out.OutboxAttempt(OutboxMessageId,AttemptNumber,WorkerId,CompletedUtc,Outcome,FailureReason)
    SELECT OutboxMessageId,1,N'F8B-requeue',SYSUTCDATETIME(),N'Dead',N'F8B namerna napaka'
      FROM out.OutboxMessage
     WHERE OrganizationId=@Org AND OutboundBatchId={batchId};
    """);

  await ExpectSqlFailureAsync(
    async () =>
    {
      await SqlAsync($"UPDATE out.OutboxMessage SET Status=N'Sent' WHERE OutboxMessageId={messageIds[0]} AND OrganizationId=@Org;");
      await RequeueMessageAsync(messageIds[0]);
    },
    "Poslanega sporocila ni dovoljeno vrniti v vrsto");
  Equal("Sent", await ReadMessageStatusAsync(messageIds[0]), "Neuspel ponovni poskus ne sme spremeniti statusa Sent");
  await SqlAsync($"UPDATE out.OutboxMessage SET Status=N'Error' WHERE OutboxMessageId={messageIds[0]} AND OrganizationId=@Org;");

  await ExpectSqlFailureAsync(
    async () =>
    {
      await SqlAsync($"UPDATE out.OutboxMessage SET Status=N'Sending',LeaseOwner=N'F8B',LeaseUntilUtc=DATEADD(minute,5,SYSUTCDATETIME()) WHERE OutboxMessageId={messageIds[1]} AND OrganizationId=@Org;");
      await RequeueMessageAsync(messageIds[1]);
    },
    "Sporocila, ki ga worker posilja, ni dovoljeno vrniti v vrsto");
  Equal("Sending", await ReadMessageStatusAsync(messageIds[1]), "Neuspel ponovni poskus ne sme spremeniti statusa Sending");
  await SqlAsync($"UPDATE out.OutboxMessage SET Status=N'Dead',LeaseOwner=NULL,LeaseUntilUtc=NULL WHERE OutboxMessageId={messageIds[1]} AND OrganizationId=@Org;");

  Equal(1, await RequeueMessageAsync(messageIds[0]), "Posamezen ponovni poskus mora vrniti eno sporocilo");
  Equal("Pending", await ReadMessageStatusAsync(messageIds[0]), "Sporocilo Error se mora vrniti v Pending");
  Equal(0, await ScalarIntAsync($"SELECT COUNT(*) FROM out.OutboxMessage WHERE OutboxMessageId={messageIds[0]} AND LastError IS NOT NULL;"),
    "Ob ponovnem poskusu se mora pobrisati zadnja napaka");
  Equal(1, await ScalarIntAsync($"SELECT AttemptCount FROM out.OutboxMessage WHERE OutboxMessageId={messageIds[0]};"),
    "Stevec poskusov mora ostati nedotaknjen");

  Equal(1, await RequeueBatchAsync(batchId), "Skupinski ponovni poskus mora zajeti samo preostalo sporocilo Dead");
  Equal("Pending", await ReadMessageStatusAsync(messageIds[1]), "Sporocilo Dead se mora vrniti v Pending");
  Equal(2, await ScalarIntAsync($"SELECT COUNT(*) FROM out.OutboxAttempt WHERE OutboxMessageId IN ({messageIds[0]},{messageIds[1]});"),
    "Zgodovina poskusov mora ostati nedotaknjena");
  Equal(2, await ScalarIntAsync($"SELECT COUNT(*) FROM ops.OutboundEvent WHERE OrganizationId=@Org AND OutboundBatchId={batchId} AND Step=N'REQUEUE' AND Severity=N'INFO';"),
    "Vsak ponovni poskus mora biti viden v obstojecem dnevniku dogodkov");

  Equal(2, await ScalarIntAsync($"EXEC out.CancelOutboundBatch {batchId}, N'F8B';"),
    "Preklic velja za celo skupino, ne za eno sporočilo");

  Console.WriteLine("F8 množično: branje zvezka, preslikava na pisljiva polja, delna zavrnitev brez podrtja uvoza, "
    + "prekrivka, odobritev in preklic skupine, tiho obvestilo ob uspehu in stopnjevanje nepotrjene napake PASS.");
  return 0;
}
finally
{
  await CleanupAsync();
}

/* --- postavitev in čiščenje ------------------------------------------------------------ */

async Task SetupAsync()
{
  await CleanupAsync();
  await SqlAsync("INSERT dbo.OrganizationConfig(OrganizationId,Name,SaopPrefix) VALUES(@Org,N'F8B_ISOLATED',N'F8B');");
  await SqlAsync(
    "INSERT dbo.IntegrationProfile(OrganizationId,TargetKind,EndpointTemplate,HttpOperation,ApprovalMode,IsEnabled,"
    + "TimeoutSeconds,MaxAttempts,BaseRetrySeconds,UpdatedBy) "
    + "VALUES(@Org,N'SAOP_PRODUCT',N'http://127.0.0.1:1/',N'PATCH',N'ManualApproval',1,30,5,1,N'F8B');");

  foreach (var (fieldKey, owner) in new[]
  {
    ("ProductText.TITLE_ERP.sl", "PIM"), ("Product.EAN", "PIM"), ("Product.ItemGroup", "SAOP")
  })
    await SqlAsync(
      "INSERT out.OwnershipPolicy(OrganizationId,TargetKind,EntityType,FieldName,Owner,IsEnabled,UpdatedBy) "
      + $"VALUES(@Org,N'SAOP_PRODUCT',N'Product',N'{fieldKey}',N'{owner}',1,N'F8B');");
}

async Task CleanupAsync()
{
  // Pobriše izključno vrstice, ki jih je ta test ustvaril, in samo v svoji organizaciji.
  await SqlAsync("""
    DELETE delivery FROM ops.AlertDelivery delivery
      INNER JOIN ops.Alert alert ON alert.AlertId = delivery.AlertId WHERE alert.OrganizationId = @Org;
    DELETE FROM ops.Alert WHERE OrganizationId = @Org;
    DELETE FROM ops.AlertRecipientConfig WHERE OrganizationId = @Org;
    DELETE FROM ops.OutboundEvent WHERE OrganizationId = @Org;
    DELETE attempt FROM out.OutboxAttempt attempt
      INNER JOIN out.OutboxMessage message ON message.OutboxMessageId = attempt.OutboxMessageId
      WHERE message.OrganizationId = @Org;
    DELETE FROM out.OutboxMessage WHERE OrganizationId = @Org;
    DELETE FROM out.OutboundBatch WHERE OrganizationId = @Org;
    DELETE FROM out.OwnershipPolicy WHERE OrganizationId = @Org;
    DELETE FROM out.SaopAddDefault WHERE OrganizationId = @Org;
    DELETE FROM dbo.IntegrationProfile WHERE OrganizationId = @Org;
    DELETE FROM dbo.OrganizationConfig WHERE OrganizationId = @Org;
    """);
}

/* --- dostop do procedur ---------------------------------------------------------------- */

async Task<List<string>> ReadWritableFieldsAsync()
{
  await using var command = new SqlCommand("EXEC intranet.GetWritableSaopFields @Org, N'SAOP_PRODUCT';", connection);
  command.Parameters.AddWithValue("@Org", organizationId);
  await using var reader = await command.ExecuteReaderAsync();
  var fields = new List<string>();
  while (await reader.ReadAsync()) fields.Add(reader.GetString(reader.GetOrdinal("FieldKey")));
  return fields;
}

async Task<(long BatchId, List<(string Status, string? Reason)> Rows)> EnqueueManyAsync(
  (string ItemId, string FieldKey, string Value)[] changes)
{
  var payload = JsonSerializer.Serialize(
    changes.Select(change => new { itemId = change.ItemId, fieldKey = change.FieldKey, value = change.Value }));

  await using var command = new SqlCommand(
    "EXEC out.EnqueueSaopItemChanges @Org, @Changes, N'F8B', N'BULK', N'Test', @Batch OUTPUT;", connection);
  command.Parameters.AddWithValue("@Org", organizationId);
  command.Parameters.AddWithValue("@Changes", payload);
  var batch = command.Parameters.Add("@Batch", SqlDbType.BigInt);
  batch.Direction = ParameterDirection.InputOutput;
  batch.Value = DBNull.Value;

  var rows = new List<(string, string?)>();
  await using (var reader = await command.ExecuteReaderAsync())
    while (await reader.ReadAsync())
      rows.Add((reader.GetString(reader.GetOrdinal("Status")),
        reader.IsDBNull(reader.GetOrdinal("Reason")) ? null : reader.GetString(reader.GetOrdinal("Reason"))));

  return (Convert.ToInt64(batch.Value), rows);
}

async Task<List<(string Status, string? Value)>> ReadOverlayAsync()
{
  await using var command = new SqlCommand("EXEC intranet.GetPendingOverlay @Org, @Items, N'SAOP_PRODUCT';", connection);
  command.Parameters.AddWithValue("@Org", organizationId);
  command.Parameters.AddWithValue("@Items", JsonSerializer.Serialize(new[] { "F8B-1" }));
  await using var reader = await command.ExecuteReaderAsync();
  var rows = new List<(string, string?)>();
  while (await reader.ReadAsync())
    rows.Add((reader.GetString(reader.GetOrdinal("Status")),
      reader.IsDBNull(reader.GetOrdinal("Value")) ? null : reader.GetString(reader.GetOrdinal("Value"))));
  return rows;
}

async Task<List<(long EventId, string? Detail)>> ReadOpenEventsAsync()
{
  await using var command = new SqlCommand("EXEC intranet.GetOutboundEvents @Org, 1, 100;", connection);
  command.Parameters.AddWithValue("@Org", organizationId);
  await using var reader = await command.ExecuteReaderAsync();
  var rows = new List<(long, string?)>();
  while (await reader.ReadAsync())
    rows.Add((reader.GetInt64(reader.GetOrdinal("OutboundEventId")),
      reader.IsDBNull(reader.GetOrdinal("Detail")) ? null : reader.GetString(reader.GetOrdinal("Detail"))));
  return rows;
}

async Task<List<long>> ReadMessageIdsAsync(long batchId)
{
  await using var command = new SqlCommand(
    "SELECT OutboxMessageId FROM out.OutboxMessage WHERE OrganizationId=@Org AND OutboundBatchId=@Batch ORDER BY OutboxMessageId;",
    connection);
  command.Parameters.AddWithValue("@Org", organizationId);
  command.Parameters.AddWithValue("@Batch", batchId);
  await using var reader = await command.ExecuteReaderAsync();
  var ids = new List<long>();
  while (await reader.ReadAsync()) ids.Add(reader.GetInt64(0));
  return ids;
}

async Task<string> ReadMessageStatusAsync(long messageId)
{
  await using var command = new SqlCommand(
    "SELECT Status FROM out.OutboxMessage WHERE OrganizationId=@Org AND OutboxMessageId=@Message;", connection);
  command.Parameters.AddWithValue("@Org", organizationId);
  command.Parameters.AddWithValue("@Message", messageId);
  return Convert.ToString(await command.ExecuteScalarAsync()) ?? string.Empty;
}

async Task<int> RequeueMessageAsync(long messageId)
{
  await using var command = new SqlCommand("EXEC out.RequeueOutboxMessage @Message, N'F8B';", connection);
  command.Parameters.AddWithValue("@Message", messageId);
  var value = await command.ExecuteScalarAsync();
  return value is null or DBNull ? 0 : Convert.ToInt32(value);
}

async Task<int> RequeueBatchAsync(long batchId)
{
  await using var command = new SqlCommand("EXEC out.RequeueOutboundBatch @Batch, N'F8B';", connection);
  command.Parameters.AddWithValue("@Batch", batchId);
  var value = await command.ExecuteScalarAsync();
  return value is null or DBNull ? 0 : Convert.ToInt32(value);
}

async Task ExpectSqlFailureAsync(Func<Task> action, string message)
{
  try { await action(); }
  catch (SqlException) { return; }
  throw new InvalidOperationException(message);
}

async Task RecordEventAsync(string step, string severity, string title, string? detail)
{
  await using var command = new SqlCommand(
    "EXEC ops.RecordOutboundEvent @Org, N'Product', N'F8B-1', @Step, @Severity, @Title, @Detail, NULL, NULL, NULL, N'F8B';",
    connection) { CommandTimeout = 60 };
  command.Parameters.AddWithValue("@Org", organizationId);
  command.Parameters.AddWithValue("@Step", step);
  command.Parameters.AddWithValue("@Severity", severity);
  command.Parameters.AddWithValue("@Title", title);
  command.Parameters.AddWithValue("@Detail", (object?)detail ?? DBNull.Value);
  await command.ExecuteNonQueryAsync();
}

async Task<int> EscalateAsync(int afterSeconds)
{
  await using var command = new SqlCommand("EXEC ops.EscalateOutboundEvents @After, N'F8B';", connection) { CommandTimeout = 60 };
  command.Parameters.AddWithValue("@After", afterSeconds);
  var value = await command.ExecuteScalarAsync();
  return value is null or DBNull ? 0 : Convert.ToInt32(value);
}

async Task SqlAsync(string sql)
{
  await using var command = new SqlCommand(sql, connection) { CommandTimeout = 120 };
  command.Parameters.AddWithValue("@Org", organizationId);
  await command.ExecuteNonQueryAsync();
}

async Task<int> ScalarIntAsync(string sql)
{
  await using var command = new SqlCommand(sql, connection) { CommandTimeout = 60 };
  command.Parameters.AddWithValue("@Org", organizationId);
  var value = await command.ExecuteScalarAsync();
  return value is null or DBNull ? 0 : Convert.ToInt32(value);
}

/* --- pomožno --------------------------------------------------------------------------- */

static string? ReadConnectionString()
{
  var fromEnvironment = Environment.GetEnvironmentVariable("PIM_CONNECTION_STRING");
  if (!string.IsNullOrWhiteSpace(fromEnvironment)) return fromEnvironment;
  foreach (var candidate in new[] { "appsettings.Local.json", "../../appsettings.Local.json", "../../../appsettings.Local.json" })
  {
    var path = Path.GetFullPath(candidate);
    if (!File.Exists(path)) continue;
    using var document = JsonDocument.Parse(File.ReadAllText(path));
    if (document.RootElement.TryGetProperty("ConnectionStrings", out var strings)
      && strings.TryGetProperty("Pim", out var pim)) return pim.GetString();
  }
  return null;
}

static void Assert(bool condition, string message)
{
  if (!condition) throw new InvalidOperationException(message);
}

static void Equal<T>(T expected, T actual, string message)
{
  if (!EqualityComparer<T>.Default.Equals(expected, actual))
    throw new InvalidOperationException($"{message}\n  pričakovano: {expected}\n  dobljeno:    {actual}");
}

static void Throws<TException>(Action action, string message) where TException : Exception
{
  try { action(); }
  catch (TException) { return; }
  throw new InvalidOperationException(message);
}

/// <summary>
/// Sestavi pravi .xlsx v pomnilniku. Zvezek v repozitoriju bi bil binarna datoteka, ki je
/// nihče ne bi znal popraviti; tu je vidno, kaj točno test bere.
///
/// Prazne celice se namenoma NE zapišejo, ker jih tudi Excel ne zapiše — prav na tem je
/// bralnik doslej padal.
/// </summary>
static byte[] BuildWorkbook(string[] headers, string[][] rows)
{
  var stream = new MemoryStream();
  using (var archive = new ZipArchive(stream, ZipArchiveMode.Create, leaveOpen: true))
  {
    Write(archive, "[Content_Types].xml",
      """
      <?xml version="1.0" encoding="UTF-8"?>
      <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="xml" ContentType="application/xml"/>
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
        <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
      </Types>
      """);
    Write(archive, "_rels/.rels",
      """
      <?xml version="1.0" encoding="UTF-8"?>
      <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
      </Relationships>
      """);
    Write(archive, "xl/workbook.xml",
      """
      <?xml version="1.0" encoding="UTF-8"?>
      <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <sheets><sheet name="Podatki" sheetId="1" r:id="rId1"/></sheets>
      </workbook>
      """);
    Write(archive, "xl/_rels/workbook.xml.rels",
      """
      <?xml version="1.0" encoding="UTF-8"?>
      <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
      </Relationships>
      """);

    var sheet = new StringBuilder();
    sheet.Append("""<?xml version="1.0" encoding="UTF-8"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>""");
    AppendRow(sheet, 1, headers);
    for (var index = 0; index < rows.Length; index++) AppendRow(sheet, index + 2, rows[index]);
    sheet.Append("</sheetData></worksheet>");
    Write(archive, "xl/worksheets/sheet1.xml", sheet.ToString());
  }
  return stream.ToArray();

  static void AppendRow(StringBuilder builder, int rowNumber, string[] cells)
  {
    builder.Append($"<row r=\"{rowNumber}\">");
    for (var column = 0; column < cells.Length; column++)
    {
      if (cells[column].Length == 0) continue;
      builder.Append($"<c r=\"{ColumnName(column)}{rowNumber}\" t=\"inlineStr\"><is><t>{Escape(cells[column])}</t></is></c>");
    }
    builder.Append("</row>");
  }

  static string ColumnName(int index)
  {
    var name = string.Empty;
    for (var value = index + 1; value > 0; value = (value - 1) / 26) name = (char)('A' + (value - 1) % 26) + name;
    return name;
  }

  static string Escape(string value) => value.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;");

  static void Write(ZipArchive archive, string path, string content)
  {
    var entry = archive.CreateEntry(path);
    using var writer = new StreamWriter(entry.Open(), new UTF8Encoding(false));
    writer.Write(content);
  }
}
