using System.Data;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using PIM.XmlMapping;

const int organizationId = 2;
const string sourceCode = "NW_XML";
const string itemId = "F5-EAN-ENRICHMENT";
const string ean = "9999900000005";
var connectionString = ReadConnectionString()
  ?? throw new InvalidOperationException("Manjka razvojna povezava Pim; F5 integracije ni dovoljeno preskočiti.");
var connectionBuilder = new SqlConnectionStringBuilder(connectionString);
if (!string.Equals(connectionBuilder.InitialCatalog, "PIM", StringComparison.OrdinalIgnoreCase)
  || !connectionBuilder.IntegratedSecurity)
  throw new InvalidOperationException("F5 integracija se sme zaganjati samo z Windows Integrated Auth v bazi PIM.");
var xml = $"""
  <?xml version="1.0" encoding="UTF-8"?>
  <channel><products><product>
    <ean>{ean}</ean>
    <product_classification><product_classification_i><i>F5 svetila</i></product_classification_i></product_classification>
    <attributes><attribute_symbol>F5-203</attribute_symbol></attributes>
    <media><image_i><image_i_path>//example.invalid/f5-203.jpg</image_i_path></image_i></media>
  </product></products></channel>
  """;

await using var connection = new SqlConnection(connectionString);
await connection.OpenAsync();
await CleanupAsync(connection);
await SeedBaseProductAsync(connection);
var runId = Guid.NewGuid();
await InsertRunAndInboxAsync(connection, runId, xml);
var originalPayload = await ScalarAsync<string>(connection, "SELECT TOP(1) PayloadXml FROM raw.Inbox WHERE RunId=@RunId;", ("@RunId", runId));

await new SqlMappingPipeline(connectionString).ExtractAndApplyAsync(runId, organizationId, sourceCode);

Equal(xml, await ScalarAsync<string>(connection, "SELECT TOP(1) PayloadXml FROM raw.Inbox WHERE RunId=@RunId;", ("@RunId", runId)), "raw.Inbox payload se je spremenil.");
Equal(originalPayload, xml, "Vstavljeni payload ni identičen.");
Equal(6, await ScalarAsync<int>(connection, "SELECT COUNT(*) FROM map.ExtractedValue value INNER JOIN raw.Inbox inbox ON inbox.InboxId=value.InboxId WHERE inbox.RunId=@RunId;", ("@RunId", runId)), "Manjka staging sled.");
Equal("F5 svetila", await ProductValueAsync(connection, "canon.ProductCategory", "CategoryPath"), "EAN kategorija ni obogatena.");
Equal("//example.invalid/f5-203.jpg", await ProductValueAsync(connection, "canon.ProductMedia", "Url"), "EAN medij ni obogaten.");
Equal("F5-203", await ProductValueAsync(connection, "canon.ProductAttribute", "Value"), "EAN atribut ni obogaten.");

await VerifyReviewRemediationAsync(connection);

await ExecuteAsync(connection, "EXEC val.RunValidation @OrganizationId=@OrganizationId;", ("@OrganizationId", organizationId));
Equal("VALID", await ScalarAsync<string>(connection, """
  SELECT validationState.Status FROM val.ProductValidationState validationState
  INNER JOIN val.ValidationProfile profile ON profile.ValidationProfileId=validationState.ValidationProfileId
  INNER JOIN canon.Product product ON product.ProductId=validationState.ProductId
  WHERE profile.ProfileCode=N'WEB_B2C' AND product.OrganizationId=@OrganizationId AND product.ItemID=@ItemID;
  """, ("@OrganizationId", organizationId), ("@ItemID", itemId)), "B2C validacija ni uspela.");
await ExecuteAsync(connection, "EXEC val.Promote @OrganizationId=@OrganizationId,@ValidationProfileCode=N'WEB_B2C';", ("@OrganizationId", organizationId));
Equal(1, await ScalarAsync<int>(connection, "SELECT COUNT(*) FROM pim.Product WHERE OrganizationId=@OrganizationId AND ItemID=@ItemID;", ("@OrganizationId", organizationId), ("@ItemID", itemId)), "Promocija v pim ni uspela.");

await using (var export = Command(connection, "EXEC out.ExportProductsCsv @OrganizationId=@OrganizationId,@ProfileCode=N'WEB_B2C_PRODUCTS';", ("@OrganizationId", organizationId)))
await using (var reader = await export.ExecuteReaderAsync())
{
  var found = false;
  while (await reader.ReadAsync())
  {
    if (Enumerable.Range(0, reader.FieldCount).Any(index =>
      !reader.IsDBNull(index) && reader.GetValue(index).ToString()!.Contains(ean, StringComparison.Ordinal))) found = true;
  }
  if (!found) throw new InvalidOperationException("B2C CSV ne vsebuje F5 EAN.");
}

var definition = await ScalarAsync<string>(connection, "SELECT OBJECT_DEFINITION(OBJECT_ID(N'map.ProcessRawInbox'));");
if (definition.Contains(".nodes(", StringComparison.OrdinalIgnoreCase)
  || definition.Contains("sp_executesql", StringComparison.OrdinalIgnoreCase))
{
  throw new InvalidOperationException("SQL apply še vedno izvaja dinamični XPath.");
}
Console.WriteLine("F5 integration: EAN enrichment category/media/attribute, B2C validation, pim in CSV PASS.");
return 0;

static string? ReadConnectionString()
{
  var value = Environment.GetEnvironmentVariable("PIM_CONNECTION_STRING");
  if (!string.IsNullOrWhiteSpace(value)) return value;
  var path = Path.Combine(Directory.GetCurrentDirectory(), "appsettings.Local.json");
  if (!File.Exists(path)) return null;
  using var document = JsonDocument.Parse(File.ReadAllText(path));
  return document.RootElement.GetProperty("ConnectionStrings").GetProperty("Pim").GetString();
}
async Task CleanupAsync(SqlConnection sqlConnection)
{
  await ExecuteAsync(sqlConnection, """
    DELETE FROM map.UnmappedValue WHERE ExtractedValueId IN
    (
      SELECT value.ExtractedValueId FROM map.ExtractedValue value
      INNER JOIN raw.Inbox inbox ON inbox.InboxId=value.InboxId
      INNER JOIN ops.PipelineRun run ON run.RunId=inbox.RunId WHERE run.Pipeline=N'F5_INTEGRATION'
    );
    DELETE FROM map.ExtractedValue WHERE InboxId IN
    (
      SELECT inbox.InboxId FROM raw.Inbox inbox
      INNER JOIN ops.PipelineRun run ON run.RunId=inbox.RunId WHERE run.Pipeline=N'F5_INTEGRATION'
    );
    DELETE inbox FROM raw.Inbox inbox
    INNER JOIN ops.PipelineRun run ON run.RunId=inbox.RunId WHERE run.Pipeline=N'F5_INTEGRATION';
    DELETE FROM ops.PipelineRun WHERE Pipeline=N'F5_INTEGRATION';
    DELETE FROM map.FieldMapping WHERE SourceConnectorId IN
      (SELECT SourceConnectorId FROM map.SourceConnector WHERE SourceCode=N'F5_FUTURE_CONFIG' AND OrganizationId=@OrganizationId);
    DELETE FROM map.EntityMapping WHERE SourceConnectorId IN
      (SELECT SourceConnectorId FROM map.SourceConnector WHERE SourceCode=N'F5_FUTURE_CONFIG' AND OrganizationId=@OrganizationId);
    DELETE FROM map.SourceConnector WHERE SourceCode=N'F5_FUTURE_CONFIG' AND OrganizationId=@OrganizationId;

    DELETE FROM pim.ProductText WHERE PimProductId IN (SELECT PimProductId FROM pim.Product WHERE OrganizationId=@OrganizationId AND ItemID=@ItemID);
    DELETE FROM pim.ProductAttribute WHERE PimProductId IN (SELECT PimProductId FROM pim.Product WHERE OrganizationId=@OrganizationId AND ItemID=@ItemID);
    DELETE FROM pim.ProductCategory WHERE PimProductId IN (SELECT PimProductId FROM pim.Product WHERE OrganizationId=@OrganizationId AND ItemID=@ItemID);
    DELETE FROM pim.ProductMedia WHERE PimProductId IN (SELECT PimProductId FROM pim.Product WHERE OrganizationId=@OrganizationId AND ItemID=@ItemID);
    DELETE FROM pim.ProductPrice WHERE PimProductId IN (SELECT PimProductId FROM pim.Product WHERE OrganizationId=@OrganizationId AND ItemID=@ItemID);
    DELETE FROM pim.ProductCommercial WHERE PimProductId IN (SELECT PimProductId FROM pim.Product WHERE OrganizationId=@OrganizationId AND ItemID=@ItemID);
    DELETE FROM pim.Product WHERE OrganizationId=@OrganizationId AND ItemID=@ItemID;
    DELETE FROM val.ProductIssue WHERE ProductId IN (SELECT ProductId FROM canon.Product WHERE OrganizationId=@OrganizationId AND ItemID=@ItemID);
    DELETE FROM val.ProductValidationState WHERE ProductId IN (SELECT ProductId FROM canon.Product WHERE OrganizationId=@OrganizationId AND ItemID=@ItemID);
    DELETE FROM canon.ProductText WHERE ProductId IN (SELECT ProductId FROM canon.Product WHERE OrganizationId=@OrganizationId AND ItemID=@ItemID);
    DELETE FROM canon.ProductAttribute WHERE ProductId IN (SELECT ProductId FROM canon.Product WHERE OrganizationId=@OrganizationId AND ItemID=@ItemID);
    DELETE FROM canon.ProductCategory WHERE ProductId IN (SELECT ProductId FROM canon.Product WHERE OrganizationId=@OrganizationId AND ItemID=@ItemID);
    DELETE FROM canon.ProductMedia WHERE ProductId IN (SELECT ProductId FROM canon.Product WHERE OrganizationId=@OrganizationId AND ItemID=@ItemID);
    DELETE FROM canon.ProductPrice WHERE ProductId IN (SELECT ProductId FROM canon.Product WHERE OrganizationId=@OrganizationId AND ItemID=@ItemID);
    DELETE FROM canon.ProductCommercial WHERE ProductId IN (SELECT ProductId FROM canon.Product WHERE OrganizationId=@OrganizationId AND ItemID=@ItemID);
    DELETE FROM canon.Product WHERE OrganizationId=@OrganizationId AND ItemID=@ItemID;
    """, ("@OrganizationId", organizationId), ("@ItemID", itemId), ("@SourceCode", sourceCode));
}
async Task VerifyReviewRemediationAsync(SqlConnection sqlConnection)
{
  const string futureSource = "F5_FUTURE_CONFIG";
  await ExecuteAsync(sqlConnection, """
    INSERT map.SourceConnector(SourceCode,OrganizationId,ConnectorType,IsActive)
    VALUES(@SourceCode,@OrganizationId,N'FILE_XML',1);
    DECLARE @ConnectorId int=SCOPE_IDENTITY();
    INSERT map.EntityMapping(SourceConnectorId,EntityType,RecordXPath,IsActive)
    VALUES(@ConnectorId,N'FutureProduct',N'/feed/product',1);
    INSERT map.FieldMapping(SourceConnectorId,EntityType,SourceElement,TargetFieldCode,IsRequired,IsActive,MappingVersion)
    VALUES
      (@ConnectorId,N'FutureProduct',N'item/text()',N'Product.ItemID',1,1,1),
      (@ConnectorId,N'FutureProduct',N'ean/text()',N'Product.EAN',0,1,1),
      (@ConnectorId,N'FutureProduct',N'title/text()',N'ProductText.WEB_TITLE.sl',0,1,1),
      (@ConnectorId,N'FutureProduct',N'alt-title/text()',N'ProductText.WEB_TITLE.sl',0,1,1),
      (@ConnectorId,N'FutureProduct',N'note/text()',N'Future.Note',0,1,1),
      (@ConnectorId,N'FutureProduct',N'price-list/text()',N'ProductPrice.PriceList',0,1,1),
      (@ConnectorId,N'FutureProduct',N'net/text()',N'ProductPrice.Net',0,1,1),
      (@ConnectorId,N'FutureProduct',N'vat/text()',N'ProductPrice.VatRate',0,1,1),
      (@ConnectorId,N'FutureProduct',N'valid-from/text()',N'ProductPrice.ValidFrom',0,1,1);
    """, ("@SourceCode", futureSource), ("@OrganizationId", organizationId));

  var requiredRun = Guid.NewGuid();
  await InsertFutureInboxAsync(sqlConnection, requiredRun, futureSource,
    "<feed><product><ean>9999900000005</ean><note>required-null-retained</note></product></feed>");
  await new SqlMappingPipeline(connectionString).ExtractAndApplyAsync(requiredRun, organizationId, futureSource);
  await AssertRejectedAsync(sqlConnection, requiredRun, "required-null-retained", "Obvezna");

  var unmatchedRun = Guid.NewGuid();
  await InsertFutureInboxAsync(sqlConnection, unmatchedRun, futureSource,
    "<feed><product><item>F5-DOES-NOT-EXIST</item><ean>F5-NO-EAN</ean><note>unmatched-retained</note></product></feed>");
  await new SqlMappingPipeline(connectionString).ExtractAndApplyAsync(unmatchedRun, organizationId, futureSource);
  await AssertRejectedAsync(sqlConnection, unmatchedRun, "unmatched-retained", "ne obstaja");
  Equal(0, await ScalarAsync<int>(sqlConnection,
    "SELECT COUNT(*) FROM canon.Product WHERE OrganizationId=@OrganizationId AND ItemID=N'F5-DOES-NOT-EXIST';",
    ("@OrganizationId", organizationId)), "Neujemajoči zapis je ustvaril produkt.");

  var invalidRun = Guid.NewGuid();
  await InsertFutureInboxAsync(sqlConnection, invalidRun, futureSource,
    $"""
      <feed><product><item>{itemId}</item><ean>{ean}</ean><title>NE SME OSTATI</title>
      <price-list>B2C</price-list><net>ni-cena</net><vat>101x</vat><valid-from>ni-datum</valid-from>
      <note>invalid-price-retained</note></product></feed>
      """);
  await new SqlMappingPipeline(connectionString).ExtractAndApplyAsync(invalidRun, organizationId, futureSource);
  await AssertRejectedAsync(sqlConnection, invalidRun, "invalid-price-retained", "Neveljavna");
  Equal("F5 testno svetilo", await ScalarAsync<string>(sqlConnection, """
    SELECT Value FROM canon.ProductText text
    INNER JOIN canon.Product product ON product.ProductId=text.ProductId
    WHERE product.OrganizationId=@OrganizationId AND product.ItemID=@ItemID
      AND text.TextType=N'WEB_TITLE' AND text.Lang=N'sl';
    """, ("@OrganizationId", organizationId), ("@ItemID", itemId)), "Zavrnjeni inbox je bil delno uporabljen.");

  var duplicateRun = Guid.NewGuid();
  await InsertFutureInboxAsync(sqlConnection, duplicateRun, futureSource,
    $"""
      <feed><product><item>{itemId}</item><ean>{ean}</ean>
      <title>Naslov A</title><alt-title>Naslov B</alt-title><note>duplicate-source-retained</note></product></feed>
      """);
  await new SqlMappingPipeline(connectionString).ExtractAndApplyAsync(duplicateRun, organizationId, futureSource);
  Equal("Processed", await ScalarAsync<string>(sqlConnection,
    "SELECT Status FROM raw.Inbox WHERE RunId=@RunId;", ("@RunId", duplicateRun)),
    "Podvojene ciljne preslikave so zrušile generični MERGE.");
  Equal("Naslov B", await ScalarAsync<string>(sqlConnection, """
    SELECT Value FROM canon.ProductText text
    INNER JOIN canon.Product product ON product.ProductId=text.ProductId
    WHERE product.OrganizationId=@OrganizationId AND product.ItemID=@ItemID
      AND text.TextType=N'WEB_TITLE' AND text.Lang=N'sl';
    """, ("@OrganizationId", organizationId), ("@ItemID", itemId)), "Deduplikacija ni deterministična.");
  Console.WriteLine("F5 review integration: required NULL, unmatched, invalid price/VAT/date, atomicity, dedupe in config-only source PASS.");
}
async Task InsertFutureInboxAsync(SqlConnection sqlConnection, Guid id, string source, string payload)
{
  await ExecuteAsync(sqlConnection, """
    INSERT ops.PipelineRun(RunId,Pipeline,OrganizationId,SourceCode,Status)
    VALUES(@RunId,N'F5_INTEGRATION',@OrganizationId,@SourceCode,N'Running');
    INSERT raw.Inbox(RunId,OrganizationId,SourceCode,EntityType,PageNumber,PayloadXml,PayloadHash,Status)
    VALUES(@RunId,@OrganizationId,@SourceCode,N'FutureProduct',1,@Payload,@Hash,N'Pending');
    """, ("@RunId", id), ("@OrganizationId", organizationId), ("@SourceCode", source),
    ("@Payload", payload), ("@Hash", Convert.ToHexString(SHA256.HashData(Encoding.Unicode.GetBytes(payload)))));
}
async Task AssertRejectedAsync(SqlConnection sqlConnection, Guid runId, string retainedValue, string reasonFragment)
{
  Equal("Quarantined", await ScalarAsync<string>(sqlConnection,
    "SELECT Status FROM raw.Inbox WHERE RunId=@RunId;", ("@RunId", runId)), "Inbox ni v karanteni.");
  Equal(1, await ScalarAsync<int>(sqlConnection, """
    SELECT COUNT(*) FROM map.UnmappedValue rejected
    INNER JOIN map.ExtractedValue value ON value.ExtractedValueId=rejected.ExtractedValueId
    INNER JOIN raw.Inbox inbox ON inbox.InboxId=value.InboxId
    WHERE inbox.RunId=@RunId AND value.Value=@Value AND rejected.Reason LIKE N'%' + @Reason + N'%';
    """, ("@RunId", runId), ("@Value", retainedValue), ("@Reason", reasonFragment)),
    "Zavrnjena generična vrednost ali razlog nista ohranjena.");
}
async Task SeedBaseProductAsync(SqlConnection sqlConnection)
{
  await ExecuteAsync(sqlConnection, """
    INSERT canon.Product(OrganizationId,ItemID,EAN,Manufacturer,UoM,Supplier,AccountingGroup,DiscountGroup)
    VALUES(@OrganizationId,@ItemID,@EAN,N'F5 maker',N'kos',N'F5 supplier',N'F5 accounting',N'F5 discount');
    DECLARE @ProductId bigint=SCOPE_IDENTITY();
    INSERT canon.ProductText(ProductId,Lang,TextType,Value) VALUES(@ProductId,N'sl',N'WEB_TITLE',N'F5 testno svetilo');
    INSERT canon.ProductPrice(ProductId,PriceList,Net,VatRate,ValidFrom,IsActive) VALUES(@ProductId,N'B2C',100,22,'20260101',1);
    """, ("@OrganizationId", organizationId), ("@ItemID", itemId), ("@EAN", ean));
}
async Task InsertRunAndInboxAsync(SqlConnection sqlConnection, Guid id, string payload)
{
  await ExecuteAsync(sqlConnection, """
    INSERT ops.PipelineRun(RunId,Pipeline,OrganizationId,SourceCode,Status)
    VALUES(@RunId,N'F5_INTEGRATION',@OrganizationId,@SourceCode,N'Running');
    INSERT raw.Inbox(RunId,OrganizationId,SourceCode,EntityType,PageNumber,PayloadXml,PayloadHash,Status)
    SELECT @RunId,@OrganizationId,@SourceCode,entityMapping.EntityType,
      ROW_NUMBER() OVER(ORDER BY entityMapping.EntityType),@Payload,@Hash,N'Pending'
    FROM map.EntityMapping entityMapping
    INNER JOIN map.SourceConnector connector ON connector.SourceConnectorId=entityMapping.SourceConnectorId
    WHERE connector.SourceCode=@SourceCode AND connector.OrganizationId=@OrganizationId AND entityMapping.IsActive=1;
    """, ("@RunId", id), ("@OrganizationId", organizationId), ("@SourceCode", sourceCode),
    ("@Payload", payload), ("@Hash", Convert.ToHexString(SHA256.HashData(Encoding.Unicode.GetBytes(payload)))));
}
async Task<string> ProductValueAsync(SqlConnection sqlConnection, string table, string column)
{
  var allowed = new Dictionary<string, string>
  {
    ["canon.ProductCategory"] = "CategoryPath",
    ["canon.ProductMedia"] = "Url",
    ["canon.ProductAttribute"] = "Value"
  };
  if (!allowed.TryGetValue(table, out var allowedColumn) || allowedColumn != column) throw new InvalidOperationException("Neveljavna testna poizvedba.");
  return await ScalarAsync<string>(sqlConnection, $"SELECT TOP(1) child.{column} FROM {table} child INNER JOIN canon.Product product ON product.ProductId=child.ProductId WHERE product.OrganizationId=@OrganizationId AND product.ItemID=@ItemID;", ("@OrganizationId", organizationId), ("@ItemID", itemId));
}
static SqlCommand Command(SqlConnection connection, string sql, params (string Name, object Value)[] parameters)
{
  var command = new SqlCommand(sql, connection) { CommandTimeout = 120 };
  foreach (var parameter in parameters) command.Parameters.AddWithValue(parameter.Name, parameter.Value);
  return command;
}
static async Task ExecuteAsync(SqlConnection connection, string sql, params (string Name, object Value)[] parameters)
{
  await using var command = Command(connection, sql, parameters);
  await command.ExecuteNonQueryAsync();
}
static async Task<T> ScalarAsync<T>(SqlConnection connection, string sql, params (string Name, object Value)[] parameters)
{
  await using var command = Command(connection, sql, parameters);
  return (T)(await command.ExecuteScalarAsync() ?? throw new InvalidOperationException("Poizvedba ni vrnila vrednosti."));
}
static void Equal<T>(T expected, T actual, string message)
{
  if (!EqualityComparer<T>.Default.Equals(expected, actual)) throw new InvalidOperationException($"{message} Pričakovano={expected}, dejansko={actual}.");
}
