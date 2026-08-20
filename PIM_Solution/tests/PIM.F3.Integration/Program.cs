using Microsoft.Data.SqlClient;
using PIM.KatalogWorker;
using PIM.XmlMapping;

var connectionString = LocalConfiguration.GetConnectionString("PIM_CONNECTION_STRING", "Pim");
if (string.IsNullOrWhiteSpace(connectionString))
{
  Console.WriteLine("F3 integracija preskočena: manjka PIM_CONNECTION_STRING oziroma ConnectionStrings:Pim v appsettings.Local.json.");
  return 0;
}

await using var connection = new SqlConnection(connectionString);
await connection.OpenAsync();
const string sql = """
  IF OBJECT_ID(N'raw.Inbox',N'U') IS NULL THROW 52320,'Manjka raw.Inbox.',1;
  IF OBJECT_ID(N'map.ProcessRawInbox',N'P') IS NULL THROW 52321,'Manjka map.ProcessRawInbox.',1;
  IF OBJECT_ID(N'out.ExportProductsCsv',N'P') IS NULL THROW 52322,'Manjka out.ExportProductsCsv.',1;
  IF (SELECT COUNT(*) FROM map.SourceConnector WHERE SourceCode=N'SAOP_IQLIGHTING' AND OrganizationId=2 AND IsActive=1)<>1
    THROW 52323,'Konektor ni pravilen.',1;
  IF (SELECT COUNT(*) FROM map.PipelineStep WHERE PipelineCode=N'SAOP_PRODUCTS' AND IsActive=1)<>3
    THROW 52324,'Koraki niso pravilni.',1;
  """;
await using var command = new SqlCommand(sql, connection);
await command.ExecuteNonQueryAsync();

const string endToEndSql = """
  DECLARE @RunId uniqueidentifier =
  (
    SELECT TOP(1) pipelineRun.RunId
    FROM ops.PipelineRun pipelineRun
    WHERE pipelineRun.Pipeline=N'SAOP_PRODUCTS'
      AND EXISTS (SELECT 1 FROM raw.Inbox inbox WHERE inbox.RunId=pipelineRun.RunId)
    ORDER BY pipelineRun.StartedUtc DESC
  );
  IF @RunId IS NULL THROW 52325,'Manjka SAOP PipelineRun.',1;
  EXEC map.RunSaopProducts @RunId=@RunId, @OrganizationId=2, @SourceCode=N'SAOP_IQLIGHTING';
  IF NOT EXISTS(SELECT 1 FROM ops.PipelineRun WHERE RunId=@RunId AND Status=N'Succeeded') THROW 52326,'Pipeline ni uspel.',1;
  EXEC out.ExportProductsCsv @OrganizationId=2, @ProfileCode=N'WEB_B2C_PRODUCTS';
  """;
await using (var endToEnd = new SqlCommand(endToEndSql, connection) { CommandTimeout = 120 })
await using (var reader = await endToEnd.ExecuteReaderAsync())
{
  var csvRows = 0;
  while (await reader.ReadAsync()) csvRows++;
  if (csvRows == 0) throw new InvalidOperationException("CSV ni vrnil nobene vrstice.");
  Console.WriteLine($"F3 integracijski tok je uspešen; CSV vrstic={csvRows}.");
}

await VerifySaopXmlDeclarationAndErpEligibilityAsync(connection, connectionString);
Console.WriteLine("F3 popravek XML deklaracije in ERP upravičenosti je preverjen.");

await VerifyRawInboxRequeueAsync(connection, connectionString);
Console.WriteLine("F3 varna ponovna vrstitev karantenskega raw.Inbox je preverjena.");

// ---------------------------------------------------------------------------
// Mejnik se ne sme premakniti za entiteto brez aktivne preslikave.
//
// Zakaj je to pomembno: zajem dela za vseh 16 SAOP končnih točk, preslikava v canon pa je
// nastavljena samo za tri. SqlMappingPipeline.ReadInboxesAsync veže raw.Inbox z INNER JOIN na
// map.EntityMapping in map.FieldMapping, zato zapisi nepreslikanih entitet ostanejo Pending.
// Če bi zajem kljub temu premaknil mejnik, bi bilo to obdobje ob pozneje dodani preslikavi
// trajno preskočeno — delta zajem ga ne bi več prinesel.
{
  const string sourceCode = "SAOP_IQLIGHTING";
  const int organizationId = 2;
  const string probeEntityType = "F3_WATERMARK_GUARD_TEST";

  await using var guardConnection = new SqlConnection(connectionString);
  await guardConnection.OpenAsync();

  int sourceConnectorId;
  await using (var lookup = new SqlCommand(
    "SELECT SourceConnectorId FROM map.SourceConnector WHERE SourceCode=@SourceCode AND OrganizationId=@OrganizationId AND IsActive=1;",
    guardConnection))
  {
    lookup.Parameters.AddWithValue("@SourceCode", sourceCode);
    lookup.Parameters.AddWithValue("@OrganizationId", organizationId);
    var value = await lookup.ExecuteScalarAsync();
    if (value is null or DBNull) throw new InvalidOperationException("Manjka konektor SAOP_IQLIGHTING za organizacijo 2.");
    sourceConnectorId = Convert.ToInt32(value);
  }

  // 1. Preslikana entiteta — mejnik se sme premakniti.
  if (!await SaopIngestRunner.HasActiveMappingAsync(guardConnection, sourceConnectorId, "ItemGeneralData", default))
    throw new InvalidOperationException("ItemGeneralData ima nastavljeno preslikavo, a je bila prepoznana kot nepreslikana.");

  // 2. Nepreslikana entiteta — mejnik mora ostati na mestu.
  if (await SaopIngestRunner.HasActiveMappingAsync(guardConnection, sourceConnectorId, "GetItemsPlanningData", default))
    throw new InvalidOperationException("GetItemsPlanningData nima preslikave, a je bila prepoznana kot preslikana.");

  // 3. Polovično nastavljena preslikava (entiteta brez polj) šteje kot NEpreslikana — enako, kot
  //    jo obravnava INNER JOIN v SqlMappingPipeline. Vrstico testa vstavimo in jo sami odstranimo.
  await using (var insertProbe = new SqlCommand(
    "INSERT map.EntityMapping (SourceConnectorId, EntityType, RecordXPath, IsActive) VALUES (@SourceConnectorId, @EntityType, N'/x/y', 1);",
    guardConnection))
  {
    insertProbe.Parameters.AddWithValue("@SourceConnectorId", sourceConnectorId);
    insertProbe.Parameters.AddWithValue("@EntityType", probeEntityType);
    await insertProbe.ExecuteNonQueryAsync();
  }

  try
  {
    if (await SaopIngestRunner.HasActiveMappingAsync(guardConnection, sourceConnectorId, probeEntityType, default))
      throw new InvalidOperationException("Entiteta z map.EntityMapping, a brez map.FieldMapping, je bila napačno prepoznana kot preslikana.");
  }
  finally
  {
    await using var cleanup = new SqlCommand(
      "DELETE FROM map.EntityMapping WHERE SourceConnectorId=@SourceConnectorId AND EntityType=@EntityType;",
      guardConnection);
    cleanup.Parameters.AddWithValue("@SourceConnectorId", sourceConnectorId);
    cleanup.Parameters.AddWithValue("@EntityType", probeEntityType);
    await cleanup.ExecuteNonQueryAsync();
  }

  Console.WriteLine("F3 zaščita mejnika pri entiteti brez preslikave je preverjena.");
}

// ---------------------------------------------------------------------------
// Isto pravilo, dokazano skozi cel zajem in ne le na posamezni metodi: zaženemo
// SaopIngestRunner proti lažnemu HTTP odgovoru (brez živega SAOP) za dve entiteti hkrati —
// eno preslikano in eno nepreslikano — in preverimo, kaj se je zgodilo z map.Watermark.
//
// Ta test pade, če kdo odstrani varovalko v RunEndpointAsync; prejšnji dve preverjata samo
// gradnika, ta preverja, da sta res povezana.
{
  const string sourceCode = "SAOP_IQLIGHTING";
  const int organizationId = 2;
  const string unmappedEntityType = "F3_UNMAPPED_PROBE";

  var settings = new SaopSettings
  {
    BaseUrl = "http://saop.test.local/",
    Username = "test",
    Password = "test",
    PageSize = 10,
    MaxPagesPerEndpoint = 2,
    RetryMaxExtraAttempts = 0,
    RetryBaseDelayMilliseconds = 0,
    DelayAfterSuccessMilliseconds = 0,
    AcceptUntrustedCertificate = false,
    LookbackDays = 0
  };

  // Prva stran vsake končne točke nosi en zapis, druga je prazna in s tem konča paginacijo.
  // Števec mora biti vezan na stran iz zahtevka, ne skupen — sicer bi prva končna točka
  // porabila obe strani in druga bi dobila 0 zapisov.
  var handler = new StubHandler(request =>
  {
    var query = request.RequestUri!.Query;
    var isFirstPage = query.Contains("page=1", StringComparison.OrdinalIgnoreCase);
    var xml = isFirstPage
      ? "<ArrayOfItem><Item><ItemID>F3-PROBE-1</ItemID></Item></ArrayOfItem>"
      : "<ArrayOfItem />";
    return new HttpResponseMessage(System.Net.HttpStatusCode.OK)
    {
      Content = new StringContent(xml, System.Text.Encoding.UTF8, "application/xml")
    };
  });

  var mappedEndpoint = SaopEndpoints.Find(SaopEndpoints.GetItemsGeneralData)!;
  var unmappedEndpoint = new SaopEndpoint(
    unmappedEntityType, "api/Item/GetProbe", SaopEndpointKind.Paged, SupportsWatermark: true)
  {
    EntityType = unmappedEntityType
  };

  int probeConnectorId;
  await using (var idConnection = new SqlConnection(connectionString))
  {
    await idConnection.OpenAsync();
    await using var lookup = new SqlCommand(
      "SELECT SourceConnectorId FROM map.SourceConnector WHERE SourceCode=@SourceCode AND OrganizationId=@OrganizationId AND IsActive=1;",
      idConnection);
    lookup.Parameters.AddWithValue("@SourceCode", sourceCode);
    lookup.Parameters.AddWithValue("@OrganizationId", organizationId);
    probeConnectorId = Convert.ToInt32(await lookup.ExecuteScalarAsync());
  }

  static async Task<string?> ReadWatermarkValueAsync(string cs, int connectorId, string entityType)
  {
    await using var connection = new SqlConnection(cs);
    await connection.OpenAsync();
    await using var command = new SqlCommand(
      "SELECT WatermarkValue FROM map.Watermark WHERE SourceConnectorId=@SourceConnectorId AND EntityType=@EntityType;",
      connection);
    command.Parameters.AddWithValue("@SourceConnectorId", connectorId);
    command.Parameters.AddWithValue("@EntityType", entityType);
    var value = await command.ExecuteScalarAsync();
    return value is null or DBNull ? null : Convert.ToString(value);
  }

  var mappedBefore = await ReadWatermarkValueAsync(connectionString, probeConnectorId, "ItemGeneralData");

  var runner = new SaopIngestRunner(connectionString, settings, handler);
  var summary = await runner.RunAsync(
    new SaopOrganization(organizationId, "IQLighting", sourceCode),
    [mappedEndpoint, unmappedEndpoint],
    fullSync: true);

  try
  {
    var mappedResult = summary.Endpoints.Single(endpoint => endpoint.EndpointKey == mappedEndpoint.Key);
    var unmappedResult = summary.Endpoints.Single(endpoint => endpoint.EndpointKey == unmappedEndpoint.Key);

    if (!mappedResult.Succeeded) throw new InvalidOperationException($"Preslikana končna točka ni uspela: {mappedResult.Error}");
    if (!unmappedResult.Succeeded) throw new InvalidOperationException($"Nepreslikana končna točka bi morala uspeti pri zajemu: {unmappedResult.Error}");

    if (!mappedResult.WatermarkAdvanced)
      throw new InvalidOperationException("Preslikani končni točki mejnik ni bil premaknjen, čeprav bi moral biti.");
    if (unmappedResult.WatermarkAdvanced)
      throw new InvalidOperationException("Nepreslikani končni točki je bil mejnik premaknjen — to je prav tista tiha izguba podatkov, ki jo varovalka preprečuje.");
    if (!unmappedResult.AwaitingMapping)
      throw new InvalidOperationException("Nepreslikana končna točka ni bila označena kot 'čaka na preslikavo'.");
    if (summary.AwaitingMappingCount != 1)
      throw new InvalidOperationException($"Pričakovana ena končna točka brez preslikave, dobil {summary.AwaitingMappingCount}.");

    // Dokaz v bazi, ne le v objektu: za nepreslikano entiteto mejnika sploh ni.
    if (await ReadWatermarkValueAsync(connectionString, probeConnectorId, unmappedEntityType) is not null)
      throw new InvalidOperationException("map.Watermark je dobil vrstico za nepreslikano entiteto.");

    // Preslikana entiteta pa se je premaknila.
    var mappedAfter = await ReadWatermarkValueAsync(connectionString, probeConnectorId, "ItemGeneralData");
    if (mappedAfter is null) throw new InvalidOperationException("Preslikana entiteta ni dobila mejnika.");
    if (mappedAfter == mappedBefore) throw new InvalidOperationException("Mejnik preslikane entitete se ni premaknil.");

    // In zajeti zapis nepreslikane entitete res leži v raw.Inbox — podatek ni izgubljen, le čaka.
    await using var inboxConnection = new SqlConnection(connectionString);
    await inboxConnection.OpenAsync();
    await using var inboxCount = new SqlCommand(
      "SELECT COUNT(*) FROM raw.Inbox WHERE RunId=@RunId AND EntityType=@EntityType AND Status=N'Pending';",
      inboxConnection);
    inboxCount.Parameters.AddWithValue("@RunId", summary.RunId);
    inboxCount.Parameters.AddWithValue("@EntityType", unmappedEntityType);
    if (Convert.ToInt32(await inboxCount.ExecuteScalarAsync()) < 1)
      throw new InvalidOperationException("Zajeti zapis nepreslikane entitete ni pristal v raw.Inbox.");
  }
  finally
  {
    // Test počisti izključno vrstice, ki jih je ustvaril sam, in vrne mejnik preslikane
    // entitete na prejšnjo vrednost — ta je skupno stanje in ga test ne sme pustiti premaknjenega.
    await using var cleanup = new SqlConnection(connectionString);
    await cleanup.OpenAsync();
    await using (var cleanupCommand = new SqlCommand("""
      DELETE FROM raw.Inbox WHERE RunId=@RunId;
      DELETE FROM map.Watermark WHERE SourceConnectorId=@SourceConnectorId AND EntityType=@EntityType;
      DELETE FROM ops.PipelineRun WHERE RunId=@RunId;
      """, cleanup))
    {
      cleanupCommand.Parameters.AddWithValue("@RunId", summary.RunId);
      cleanupCommand.Parameters.AddWithValue("@SourceConnectorId", probeConnectorId);
      cleanupCommand.Parameters.AddWithValue("@EntityType", unmappedEntityType);
      await cleanupCommand.ExecuteNonQueryAsync();
    }

    await using var restore = mappedBefore is null
      ? new SqlCommand(
          "DELETE FROM map.Watermark WHERE SourceConnectorId=@SourceConnectorId AND EntityType=N'ItemGeneralData';",
          cleanup)
      : new SqlCommand(
          "UPDATE map.Watermark SET WatermarkValue=@WatermarkValue WHERE SourceConnectorId=@SourceConnectorId AND EntityType=N'ItemGeneralData';",
          cleanup);
    restore.Parameters.AddWithValue("@SourceConnectorId", probeConnectorId);
    if (mappedBefore is not null) restore.Parameters.AddWithValue("@WatermarkValue", mappedBefore);
    await restore.ExecuteNonQueryAsync();
  }

  Console.WriteLine("F3 celoten zajem: mejnik nepreslikane entitete ostane nespremenjen.");
}
return 0;

static async Task VerifySaopXmlDeclarationAndErpEligibilityAsync(SqlConnection connection, string connectionString)
{
  const string testItemId = "F3-FIX-TEST-SUPPLIER-DISCOUNT";
  const string sourceCode = "SAOP_IQLIGHTING";
  const int organizationId = 2;

  // Realna oblika odgovora SAOP ItemGeneralData (potrjena v PIM_test), vključno z XML deklaracijo
  // in resničnimi vzorčnimi vrednostmi SupplierID/DiscountGroup1ID/ManufacturerID.
  var payloadXml = $"""
    <?xml version="1.0" encoding="utf-8"?>
    <ItemsGeneralData>
      <ItemGeneralData>
        <ItemID>{testItemId}</ItemID>
        <ItemTitle1>F3 testni izdelek za popravek</ItemTitle1>
        <GeneralData>
          <ItemUnitOfMeas>kom</ItemUnitOfMeas>
          <AccountingBookGroupID>NOWODVORSKI</AccountingBookGroupID>
        </GeneralData>
        <SalesData>
          <DiscountGroup1ID>NOWODVORSKI</DiscountGroup1ID>
        </SalesData>
        <StockData>
          <SupplierID>91086973</SupplierID>
          <ManufacturerID>00001625</ManufacturerID>
        </StockData>
      </ItemGeneralData>
    </ItemsGeneralData>
    """;

  await using (var cleanup = new SqlCommand("""
    DECLARE @TestChangeBatches TABLE(ChangeBatchId bigint PRIMARY KEY);
    DELETE FROM val.ProductIssue WHERE ProductId IN (SELECT ProductId FROM canon.Product WHERE OrganizationId = @OrganizationId AND ItemID = @ItemID);
    DELETE FROM val.ProductValidationState WHERE ProductId IN (SELECT ProductId FROM canon.Product WHERE OrganizationId = @OrganizationId AND ItemID = @ItemID);
    DELETE FROM canon.ProductText WHERE ProductId IN (SELECT ProductId FROM canon.Product WHERE OrganizationId = @OrganizationId AND ItemID = @ItemID);
    DELETE FROM canon.ProductAttribute WHERE ProductId IN (SELECT ProductId FROM canon.Product WHERE OrganizationId = @OrganizationId AND ItemID = @ItemID);
    DELETE FROM canon.ProductCategory WHERE ProductId IN (SELECT ProductId FROM canon.Product WHERE OrganizationId = @OrganizationId AND ItemID = @ItemID);
    DELETE FROM canon.ProductMedia WHERE ProductId IN (SELECT ProductId FROM canon.Product WHERE OrganizationId = @OrganizationId AND ItemID = @ItemID);
    DELETE FROM canon.ProductPrice WHERE ProductId IN (SELECT ProductId FROM canon.Product WHERE OrganizationId = @OrganizationId AND ItemID = @ItemID);
    DELETE FROM canon.ProductCommercial WHERE ProductId IN (SELECT ProductId FROM canon.Product WHERE OrganizationId = @OrganizationId AND ItemID = @ItemID);
    INSERT @TestChangeBatches(ChangeBatchId)
    SELECT DISTINCT history.ChangeBatchId
    FROM pim.ProductFieldHistory history
    INNER JOIN canon.Product product ON product.ProductId=history.ProductId
    WHERE product.OrganizationId=@OrganizationId AND product.ItemID=@ItemID;
    DELETE history
    FROM pim.ProductFieldHistory history
    INNER JOIN canon.Product product ON product.ProductId=history.ProductId
    WHERE product.OrganizationId=@OrganizationId AND product.ItemID=@ItemID;
    DELETE batch
    FROM pim.ProductChangeBatch batch
    INNER JOIN @TestChangeBatches testBatch ON testBatch.ChangeBatchId=batch.ChangeBatchId
    WHERE NOT EXISTS(SELECT 1 FROM pim.ProductFieldHistory history WHERE history.ChangeBatchId=batch.ChangeBatchId);
    DELETE FROM canon.Product WHERE OrganizationId = @OrganizationId AND ItemID = @ItemID;
    DELETE FROM map.UnmappedValue WHERE ExtractedValueId IN (SELECT ExtractedValueId FROM map.ExtractedValue WHERE InboxId IN (SELECT InboxId FROM raw.Inbox WHERE OrganizationId=@OrganizationId AND SourceCode=@SourceCode AND EntityType=N'ItemGeneralData' AND PageNumber=999));
    DELETE FROM map.ExtractedValue WHERE InboxId IN (SELECT InboxId FROM raw.Inbox WHERE OrganizationId=@OrganizationId AND SourceCode=@SourceCode AND EntityType=N'ItemGeneralData' AND PageNumber=999);
    DELETE FROM raw.Inbox WHERE OrganizationId = @OrganizationId AND SourceCode = @SourceCode AND EntityType = N'ItemGeneralData' AND PageNumber = 999;
    DELETE FROM ops.PipelineRun WHERE Pipeline = N'SAOP_PRODUCTS_FIX_TEST';
    """, connection))
  {
    cleanup.Parameters.AddWithValue("@OrganizationId", organizationId);
    cleanup.Parameters.AddWithValue("@ItemID", testItemId);
    cleanup.Parameters.AddWithValue("@SourceCode", sourceCode);
    await cleanup.ExecuteNonQueryAsync();
  }

  await using (var seedProduct = new SqlCommand("""
    INSERT canon.Product(OrganizationId,ItemID,BusinessHash)
    VALUES(@OrganizationId,@ItemID,CONVERT(char(64),HASHBYTES('SHA2_256',@ItemID),2));
    """, connection))
  {
    seedProduct.Parameters.AddWithValue("@OrganizationId", organizationId);
    seedProduct.Parameters.AddWithValue("@ItemID", testItemId);
    await seedProduct.ExecuteNonQueryAsync();
  }

  var runId = Guid.NewGuid();
  await using (var startRun = new SqlCommand("""
    INSERT ops.PipelineRun (RunId, Pipeline, OrganizationId, SourceCode, Status)
    VALUES (@RunId, N'SAOP_PRODUCTS_FIX_TEST', @OrganizationId, @SourceCode, N'Running');
    """, connection))
  {
    startRun.Parameters.AddWithValue("@RunId", runId);
    startRun.Parameters.AddWithValue("@OrganizationId", organizationId);
    startRun.Parameters.AddWithValue("@SourceCode", sourceCode);
    await startRun.ExecuteNonQueryAsync();
  }

  await using (var insertInbox = new SqlCommand("""
    INSERT raw.Inbox (RunId, OrganizationId, SourceCode, EntityType, PageNumber, PayloadXml, PayloadHash, Status)
    VALUES (@RunId, @OrganizationId, @SourceCode, N'ItemGeneralData', 999, @PayloadXml,
            CONVERT(char(64), HASHBYTES('SHA2_256', CONVERT(varbinary(max), @PayloadXml)), 2), N'Pending');
    """, connection))
  {
    insertInbox.Parameters.AddWithValue("@RunId", runId);
    insertInbox.Parameters.AddWithValue("@OrganizationId", organizationId);
    insertInbox.Parameters.AddWithValue("@SourceCode", sourceCode);
    insertInbox.Parameters.Add("@PayloadXml", System.Data.SqlDbType.NVarChar, -1).Value = payloadXml;
    await insertInbox.ExecuteNonQueryAsync();
  }

  await new SqlMappingPipeline(connectionString).ExtractAndApplyAsync(runId, organizationId, sourceCode);

  await using (var assertStatus = new SqlCommand("""
    SELECT Status, FailureReason FROM raw.Inbox
    WHERE OrganizationId = @OrganizationId AND SourceCode = @SourceCode AND EntityType = N'ItemGeneralData' AND PageNumber = 999;
    """, connection))
  {
    assertStatus.Parameters.AddWithValue("@OrganizationId", organizationId);
    assertStatus.Parameters.AddWithValue("@SourceCode", sourceCode);
    await using var reader = await assertStatus.ExecuteReaderAsync();
    if (!await reader.ReadAsync()) throw new InvalidOperationException("Testna vrstica raw.Inbox ni bila najdena.");
    var status = reader.GetString(0);
    if (status != "Processed")
    {
      var reason = reader.IsDBNull(1) ? "(brez razloga)" : reader.GetString(1);
      throw new InvalidOperationException($"XML z deklaracijo ni bil varno obdelan; status={status}, razlog={reason}.");
    }
  }

  await using (var assertProduct = new SqlCommand("""
    SELECT Supplier, DiscountGroup, Manufacturer FROM canon.Product WHERE OrganizationId = @OrganizationId AND ItemID = @ItemID;
    """, connection))
  {
    assertProduct.Parameters.AddWithValue("@OrganizationId", organizationId);
    assertProduct.Parameters.AddWithValue("@ItemID", testItemId);
    await using var reader = await assertProduct.ExecuteReaderAsync();
    if (!await reader.ReadAsync()) throw new InvalidOperationException("Testni canon.Product ni bil obogaten.");
    var supplier = reader.IsDBNull(0) ? null : reader.GetString(0);
    var discountGroup = reader.IsDBNull(1) ? null : reader.GetString(1);
    var manufacturer = reader.IsDBNull(2) ? null : reader.GetString(2);
    if (supplier != "91086973") throw new InvalidOperationException($"Product.Supplier ni preslikan iz SupplierID; dobljeno='{supplier}'.");
    if (discountGroup != "NOWODVORSKI") throw new InvalidOperationException($"Product.DiscountGroup ni preslikan iz DiscountGroup1ID; dobljeno='{discountGroup}'.");
    if (manufacturer != "00001625") throw new InvalidOperationException($"Product.Manufacturer ni preslikan iz ManufacturerID; dobljeno='{manufacturer}'.");
  }

  await using (var cleanup = new SqlCommand("""
    DECLARE @TestChangeBatches TABLE(ChangeBatchId bigint PRIMARY KEY);
    DELETE FROM val.ProductIssue WHERE ProductId IN (SELECT ProductId FROM canon.Product WHERE OrganizationId = @OrganizationId AND ItemID = @ItemID);
    DELETE FROM val.ProductValidationState WHERE ProductId IN (SELECT ProductId FROM canon.Product WHERE OrganizationId = @OrganizationId AND ItemID = @ItemID);
    DELETE FROM canon.ProductText WHERE ProductId IN (SELECT ProductId FROM canon.Product WHERE OrganizationId = @OrganizationId AND ItemID = @ItemID);
    DELETE FROM canon.ProductAttribute WHERE ProductId IN (SELECT ProductId FROM canon.Product WHERE OrganizationId = @OrganizationId AND ItemID = @ItemID);
    DELETE FROM canon.ProductCategory WHERE ProductId IN (SELECT ProductId FROM canon.Product WHERE OrganizationId = @OrganizationId AND ItemID = @ItemID);
    DELETE FROM canon.ProductMedia WHERE ProductId IN (SELECT ProductId FROM canon.Product WHERE OrganizationId = @OrganizationId AND ItemID = @ItemID);
    DELETE FROM canon.ProductPrice WHERE ProductId IN (SELECT ProductId FROM canon.Product WHERE OrganizationId = @OrganizationId AND ItemID = @ItemID);
    DELETE FROM canon.ProductCommercial WHERE ProductId IN (SELECT ProductId FROM canon.Product WHERE OrganizationId = @OrganizationId AND ItemID = @ItemID);
    INSERT @TestChangeBatches(ChangeBatchId)
    SELECT DISTINCT history.ChangeBatchId
    FROM pim.ProductFieldHistory history
    INNER JOIN canon.Product product ON product.ProductId=history.ProductId
    WHERE product.OrganizationId=@OrganizationId AND product.ItemID=@ItemID;
    DELETE history
    FROM pim.ProductFieldHistory history
    INNER JOIN canon.Product product ON product.ProductId=history.ProductId
    WHERE product.OrganizationId=@OrganizationId AND product.ItemID=@ItemID;
    DELETE batch
    FROM pim.ProductChangeBatch batch
    INNER JOIN @TestChangeBatches testBatch ON testBatch.ChangeBatchId=batch.ChangeBatchId
    WHERE NOT EXISTS(SELECT 1 FROM pim.ProductFieldHistory history WHERE history.ChangeBatchId=batch.ChangeBatchId);
    DELETE FROM canon.Product WHERE OrganizationId = @OrganizationId AND ItemID = @ItemID;
    DELETE FROM map.UnmappedValue WHERE ExtractedValueId IN (SELECT ExtractedValueId FROM map.ExtractedValue WHERE InboxId IN (SELECT InboxId FROM raw.Inbox WHERE OrganizationId=@OrganizationId AND SourceCode=@SourceCode AND EntityType=N'ItemGeneralData' AND PageNumber=999));
    DELETE FROM map.ExtractedValue WHERE InboxId IN (SELECT InboxId FROM raw.Inbox WHERE OrganizationId=@OrganizationId AND SourceCode=@SourceCode AND EntityType=N'ItemGeneralData' AND PageNumber=999);
    DELETE FROM raw.Inbox WHERE OrganizationId = @OrganizationId AND SourceCode = @SourceCode AND EntityType = N'ItemGeneralData' AND PageNumber = 999;
    DELETE FROM ops.PipelineRun WHERE RunId = @RunId;
    """, connection))
  {
    cleanup.Parameters.AddWithValue("@OrganizationId", organizationId);
    cleanup.Parameters.AddWithValue("@ItemID", testItemId);
    cleanup.Parameters.AddWithValue("@SourceCode", sourceCode);
    cleanup.Parameters.AddWithValue("@RunId", runId);
    await cleanup.ExecuteNonQueryAsync();
  }
}

static async Task VerifyRawInboxRequeueAsync(SqlConnection connection, string connectionString)
{
  const string sourceCode = "SAOP_IQLIGHTING";
  const int organizationId = 2;
  const string requeuePayload = "<Test>F3-REQUEUE-FIX-MARKER</Test>";
  const string keepPayload = "<Test>F3-REQUEUE-FIX-KEEP-PROCESSED-MARKER</Test>";

  async Task<Guid> StartRunAsync(string pipeline)
  {
    var runId = Guid.NewGuid();
    await using var startRun = new SqlCommand("""
      INSERT ops.PipelineRun (RunId, Pipeline, OrganizationId, SourceCode, Status)
      VALUES (@RunId, @Pipeline, @OrganizationId, @SourceCode, N'Running');
      """, connection);
    startRun.Parameters.AddWithValue("@RunId", runId);
    startRun.Parameters.AddWithValue("@Pipeline", pipeline);
    startRun.Parameters.AddWithValue("@OrganizationId", organizationId);
    startRun.Parameters.AddWithValue("@SourceCode", sourceCode);
    await startRun.ExecuteNonQueryAsync();
    return runId;
  }

  async Task InsertRawRowAsync(Guid runId, string payload, string status)
  {
    await using var insert = new SqlCommand("""
      INSERT raw.Inbox (RunId, OrganizationId, SourceCode, EntityType, PageNumber, PayloadXml, PayloadHash, Status, ProcessedUtc)
      VALUES (@RunId, @OrganizationId, @SourceCode, N'ItemGeneralData', 1, @PayloadXml,
              CONVERT(char(64), HASHBYTES('SHA2_256', CONVERT(varbinary(max), @PayloadXml)), 2), @Status,
              CASE WHEN @Status = N'Pending' THEN NULL ELSE SYSUTCDATETIME() END);
      """, connection);
    insert.Parameters.AddWithValue("@RunId", runId);
    insert.Parameters.AddWithValue("@OrganizationId", organizationId);
    insert.Parameters.AddWithValue("@SourceCode", sourceCode);
    insert.Parameters.Add("@PayloadXml", System.Data.SqlDbType.NVarChar, -1).Value = payload;
    insert.Parameters.AddWithValue("@Status", status);
    await insert.ExecuteNonQueryAsync();
  }

  async Task DeleteRowsAsync(string payload, IEnumerable<Guid> runIds)
  {
    await using (var deleteInbox = new SqlCommand("""
      DELETE FROM raw.Inbox
      WHERE OrganizationId = @OrganizationId AND SourceCode = @SourceCode AND EntityType = N'ItemGeneralData'
        AND PayloadHash = CONVERT(char(64), HASHBYTES('SHA2_256', CONVERT(varbinary(max), @PayloadXml)), 2);
      """, connection))
    {
      deleteInbox.Parameters.AddWithValue("@OrganizationId", organizationId);
      deleteInbox.Parameters.AddWithValue("@SourceCode", sourceCode);
      deleteInbox.Parameters.Add("@PayloadXml", System.Data.SqlDbType.NVarChar, -1).Value = payload;
      await deleteInbox.ExecuteNonQueryAsync();
    }

    foreach (var runId in runIds)
    {
      await using var deleteRun = new SqlCommand("DELETE FROM ops.PipelineRun WHERE RunId = @RunId;", connection);
      deleteRun.Parameters.AddWithValue("@RunId", runId);
      await deleteRun.ExecuteNonQueryAsync();
    }
  }

  async Task<(int Count, string Status, Guid RunId, string PayloadXml)> ReadRowAsync(string payload)
  {
    await using var select = new SqlCommand("""
      SELECT Status, RunId, PayloadXml FROM raw.Inbox
      WHERE OrganizationId = @OrganizationId AND SourceCode = @SourceCode AND EntityType = N'ItemGeneralData'
        AND PayloadHash = CONVERT(char(64), HASHBYTES('SHA2_256', CONVERT(varbinary(max), @PayloadXml)), 2);
      """, connection);
    select.Parameters.AddWithValue("@OrganizationId", organizationId);
    select.Parameters.AddWithValue("@SourceCode", sourceCode);
    select.Parameters.Add("@PayloadXml", System.Data.SqlDbType.NVarChar, -1).Value = payload;
    await using var reader = await select.ExecuteReaderAsync();
    var count = 0;
    var status = "";
    var runId = Guid.Empty;
    var payloadXml = "";
    while (await reader.ReadAsync())
    {
      count++;
      status = reader.GetString(0);
      runId = reader.GetGuid(1);
      payloadXml = reader.GetString(2);
    }
    return (count, status, runId, payloadXml);
  }

  // Počisti morebitne ostanke prejšnjega zagona tega testa.
  await DeleteRowsAsync(requeuePayload, []);
  await DeleteRowsAsync(keepPayload, []);

  // Scenarij A: obstoječi Quarantined zapis z istim hashem se mora varno vrniti v vrsto pod novim RunId,
  // brez podvajanja vrstice in brez spremembe surovega PayloadXml.
  var oldRunIdA = await StartRunAsync("SAOP_PRODUCTS_REQUEUE_TEST_OLD");
  await InsertRawRowAsync(oldRunIdA, requeuePayload, "Quarantined");
  var newRunIdA = await StartRunAsync("SAOP_PRODUCTS_REQUEUE_TEST_NEW");

  await using (var writerConnection = new SqlConnection(connectionString))
  {
    await writerConnection.OpenAsync();
    await using var requeueCommand = RawInboxWriter.CreateCommand(
      writerConnection, new RawPage("ItemGeneralData", 1, requeuePayload), newRunIdA, organizationId, sourceCode);
    await requeueCommand.ExecuteNonQueryAsync();
  }

  var requeued = await ReadRowAsync(requeuePayload);
  if (requeued.Count != 1) throw new InvalidOperationException($"Ponovna vrstitev je podvojila zapis; najdenih vrstic={requeued.Count}.");
  if (requeued.Status != "Pending") throw new InvalidOperationException($"Karantenski zapis ni bil vrnjen v vrsto; status={requeued.Status}.");
  if (requeued.RunId != newRunIdA) throw new InvalidOperationException("Ponovno vrščen zapis ni bil prenesen na nov RunId.");
  if (requeued.PayloadXml != requeuePayload) throw new InvalidOperationException("Ponovna vrstitev je spremenila surov PayloadXml.");

  await DeleteRowsAsync(requeuePayload, [oldRunIdA, newRunIdA]);

  // Scenarij B: obstoječi Processed zapis z istim hashem se ne sme podvojiti niti ponovno vrstiti.
  var oldRunIdB = await StartRunAsync("SAOP_PRODUCTS_REQUEUE_TEST_OLD");
  await InsertRawRowAsync(oldRunIdB, keepPayload, "Processed");
  var newRunIdB = await StartRunAsync("SAOP_PRODUCTS_REQUEUE_TEST_NEW");

  await using (var writerConnection = new SqlConnection(connectionString))
  {
    await writerConnection.OpenAsync();
    await using var noOpCommand = RawInboxWriter.CreateCommand(
      writerConnection, new RawPage("ItemGeneralData", 1, keepPayload), newRunIdB, organizationId, sourceCode);
    await noOpCommand.ExecuteNonQueryAsync();
  }

  var kept = await ReadRowAsync(keepPayload);
  if (kept.Count != 1) throw new InvalidOperationException($"Že uspešno obdelan zapis je bil podvojen; najdenih vrstic={kept.Count}.");
  if (kept.Status != "Processed") throw new InvalidOperationException($"Že uspešno obdelan zapis je bil nepotrebno ponovno vrščen; status={kept.Status}.");
  if (kept.RunId != oldRunIdB) throw new InvalidOperationException("Že uspešno obdelan zapis je bil premaknjen na nov RunId.");

  await DeleteRowsAsync(keepPayload, [oldRunIdB, newRunIdB]);
}

sealed class StubHandler(Func<HttpRequestMessage, HttpResponseMessage> respond) : HttpMessageHandler
{
  protected override Task<HttpResponseMessage> SendAsync(
    HttpRequestMessage request, CancellationToken cancellationToken) =>
    Task.FromResult(respond(request));
}
