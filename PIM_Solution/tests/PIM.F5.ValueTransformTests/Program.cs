using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using PIM.XmlMapping;

// Dokaz za migracijo 048: pretvorbe (map.FieldTransform) in slovar vrednosti
// (map.ValueLookup) delujejo na pravi bazi, na poti od dobaviteljevega XML do
// canon.ProductAttribute. Test si naredi svoj konektor in ga na koncu pobriše,
// zato v registru ne pusti ničesar.
//
// Zakaj ravno ti primeri: vsak je oblika, ki jo je bilo treba v resnici rešiti.
//   "30 mm"      Braytron pošlje vrednost in enoto skupaj, predloga ima dva stolpca
//   "Dimmable"   Da/Ne kot besedilo, izvoz hoče 1/0
//   "203"        NW šifra, ki jo ločimo od naših s predpono
//   " CLASS II"  isti dobavitelj piše isto stvar na več načinov
//   "black"      prevod je odvisen od lastnosti (barva je ženskega spola)
//   "galvanised steel"  prevod, ki velja povsod
//   "sploh ni v slovarju"  manjkajoč prevod ni napaka, ampak delovni seznam

const int organizationId = 2;
const string sourceCode = "F5_TRANSFORM";
const string entityType = "TransformProbe";
const string itemId = "F5-TRANSFORM-PROBE";
const string ean = "9999900000048";
const string unknownValue = "F5 vrednost brez prevoda";

var connectionString = ReadConnectionString()
  ?? throw new InvalidOperationException("Manjka razvojna povezava Pim; testa pretvorb ni dovoljeno preskočiti.");
var builder = new SqlConnectionStringBuilder(connectionString);
if (!string.Equals(builder.InitialCatalog, "PIM", StringComparison.OrdinalIgnoreCase) || !builder.IntegratedSecurity)
  throw new InvalidOperationException("Test se sme zaganjati samo z Windows Integrated Auth v bazi PIM.");

var payload = $"""
  <feed><product>
    <item>{itemId}</item>
    <ean>{ean}</ean>
    <size>30 mm</size>
    <dim>Not-Dimmable</dim>
    <sym>203</sym>
    <cls> CLASS II</cls>
    <col>black</col>
    <mat>galvanised steel</mat>
    <unk>{unknownValue}</unk>
  </product></feed>
  """;

await using var connection = new SqlConnection(connectionString);
await connection.OpenAsync();
await CleanupAsync(connection);
try
{
  await SeedProductAsync(connection);
  await SeedRegistryAsync(connection);

  var firstRun = Guid.NewGuid();
  await InsertInboxAsync(connection, firstRun, payload);
  await new SqlMappingPipeline(connectionString).ExtractAndApplyAsync(firstRun, organizationId, sourceCode);

  Equal("Processed", await ScalarAsync<string>(connection,
    "SELECT Status FROM raw.Inbox WHERE RunId=@RunId;", ("@RunId", firstRun)),
    "Paket se ni dokončal.");

  Equal("30", await AttributeAsync(connection, "F5 Visina"), "NUMBER ni izluščil števila iz \"30 mm\".");
  Equal("mm", await AttributeAsync(connection, "F5 Enota visine"), "UNIT ni izluščil enote iz \"30 mm\".");
  Equal("0", await AttributeAsync(connection, "F5 Zatemnljivo"), "BOOL ni pretvoril \"Not-Dimmable\" v 0.");
  Equal("NW.203", await AttributeAsync(connection, "F5 Simbol"), "PREFIX ni pripel predpone.");
  Equal("II", await AttributeAsync(connection, "F5 Razred"), "TRIM + STRIPPREFIX nista poenotila \" CLASS II\".");
  Equal("črna", await AttributeAsync(connection, "F5 Barva SLO"), "LOOKUP ni uporabil prevoda za lastnost.");
  Equal("cinkano jeklo", await AttributeAsync(connection, "F5 Material SLO"), "LOOKUP ni uporabil splošnega prevoda.");
  Equal(unknownValue, await AttributeAsync(connection, "F5 Neznano SLO"), "Manjkajoč prevod ni pustil vrednosti pri miru.");

  // Izvorna vrednost se ne izgubi: Value nosi pretvorjeno, RawValue izvorno.
  Equal("30 mm", await ScalarAsync<string>(connection, """
    SELECT TOP(1) value.RawValue FROM map.ExtractedValue value
    INNER JOIN raw.Inbox inbox ON inbox.InboxId=value.InboxId
    WHERE inbox.RunId=@RunId AND value.TargetFieldCode=N'ProductAttribute.F5 Visina';
    """, ("@RunId", firstRun)), "RawValue ne hrani izvorne vrednosti.");

  Equal(1, await ScalarAsync<int>(connection, """
    SELECT COUNT(*) FROM map.MissingTranslation
    WHERE Domain=N'F5 Neznano SLO' AND Language=N'SL' AND SourceValue=@Value;
    """, ("@Value", unknownValue)), "Manjkajoč prevod ni pristal na delovnem seznamu.");

  Equal(0, await ScalarAsync<int>(connection, """
    SELECT COUNT(*) FROM map.MissingTranslation
    WHERE Domain LIKE N'F5 %' AND SourceValue IN (N'black', N'galvanised steel');
    """), "Prevedena vrednost je pristala med manjkajočimi.");

  // Trditvi sta omejeni na domene tega testa. Odkar so vpisane resnicne preslikave
  // (054, 055), je map.MissingTranslation zivo delovno kazalo: 'Black' se v njem
  // pojavi kot resnicno manjkajoc prevod pri 'Prevladujoca barva SLO' in globalna
  // trditev bi padla zaradi tujega, pravilnega zapisa.
  // Regresija za 056: seznam manjkajočih se je pisal po tem, ko je bil prevod že uveljavljen,
  // zato je vanj pristal prevod sam ('črna' namesto 'black') in seznam je kazal delo, ki je
  // bilo opravljeno. Beleži se lahko samo izvirnik, in še ta le, kadar prevoda res ni.
  Equal(0, await ScalarAsync<int>(connection, """
    SELECT COUNT(*) FROM map.MissingTranslation
    WHERE Domain LIKE N'F5 %' AND SourceValue IN (N'črna', N'cinkano jeklo');
    """), "Med manjkajočimi je pristal prevod, ne izvirnik.");

  // Ponovljen klic postopka nad istimi vrsticami ne sme pretvarjati drugic (NW.NW.203).
  await ExecuteAsync(connection, "EXEC map.ApplyValueTransforms @RunId,@OrganizationId,@SourceCode;",
    ("@RunId", firstRun), ("@OrganizationId", organizationId), ("@SourceCode", sourceCode));
  Equal("NW.203", await ScalarAsync<string>(connection, """
    SELECT TOP(1) value.Value FROM map.ExtractedValue value
    INNER JOIN raw.Inbox inbox ON inbox.InboxId=value.InboxId
    WHERE inbox.RunId=@RunId AND value.TargetFieldCode=N'ProductAttribute.F5 Simbol';
    """, ("@RunId", firstRun)), "Ponoven klic postopka je predpono pripel dvakrat.");

  // Ista vsebina na naslednji strani: zajem tece znova od zacetka in mora dati isto.
  var secondRun = Guid.NewGuid();
  await InsertInboxAsync(connection, secondRun, payload, 2);
  await new SqlMappingPipeline(connectionString).ExtractAndApplyAsync(secondRun, organizationId, sourceCode);
  Equal("NW.203", await AttributeAsync(connection, "F5 Simbol"), "Drugi zajem je predpono pripel dvakrat.");
  Equal(2, await ScalarAsync<int>(connection, """
    SELECT SeenCount FROM map.MissingTranslation
    WHERE Domain=N'F5 Neznano SLO' AND Language=N'SL' AND SourceValue=@Value;
    """, ("@Value", unknownValue)), "Števec manjkajočega prevoda se ni povečal.");

  Console.WriteLine("F5 value transform: NUMBER, UNIT, BOOL, PREFIX, TRIM+STRIPPREFIX, LOOKUP (lastnost in splošno), manjkajoč prevod in ponoven zagon PASS.");
}
finally
{
  await CleanupAsync(connection);
}
return 0;

async Task SeedProductAsync(SqlConnection sqlConnection)
{
  await ExecuteAsync(sqlConnection, """
    INSERT canon.Product(OrganizationId,ItemID,EAN,Manufacturer,UoM)
    VALUES(@OrganizationId,@ItemID,@EAN,N'F5 maker',N'kos');
    """, ("@OrganizationId", organizationId), ("@ItemID", itemId), ("@EAN", ean));
}

async Task SeedRegistryAsync(SqlConnection sqlConnection)
{
  await ExecuteAsync(sqlConnection, """
    INSERT map.SourceConnector(SourceCode,OrganizationId,ConnectorType,IsActive)
    VALUES(@SourceCode,@OrganizationId,N'FILE_XML',1);
    DECLARE @ConnectorId int=SCOPE_IDENTITY();
    INSERT map.EntityMapping(SourceConnectorId,EntityType,RecordXPath,IsActive)
    VALUES(@ConnectorId,@EntityType,N'/feed/product',1);

    DECLARE @Mapping TABLE(Code nvarchar(200) PRIMARY KEY, FieldMappingId int NOT NULL);
    MERGE map.FieldMapping AS target
    USING (VALUES
      (N'item/text()', N'Product.ItemID'),
      (N'ean/text()',  N'Product.EAN'),
      (N'size/text()', N'ProductAttribute.F5 Visina'),
      (N'size/text()', N'ProductAttribute.F5 Enota visine'),
      (N'dim/text()',  N'ProductAttribute.F5 Zatemnljivo'),
      (N'sym/text()',  N'ProductAttribute.F5 Simbol'),
      (N'cls/text()',  N'ProductAttribute.F5 Razred'),
      (N'col/text()',  N'ProductAttribute.F5 Barva SLO'),
      (N'mat/text()',  N'ProductAttribute.F5 Material SLO'),
      (N'unk/text()',  N'ProductAttribute.F5 Neznano SLO')
    ) AS source(SourceElement, TargetFieldCode)
      ON 1=0
    WHEN NOT MATCHED THEN
      INSERT(SourceConnectorId,EntityType,SourceElement,TargetFieldCode,IsRequired,IsActive,MappingVersion)
      VALUES(@ConnectorId,@EntityType,source.SourceElement,source.TargetFieldCode,0,1,1)
    OUTPUT inserted.TargetFieldCode, inserted.FieldMappingId INTO @Mapping(Code, FieldMappingId);

    INSERT map.FieldTransform(FieldMappingId,StepOrder,TransformCode,Argument)
    SELECT mapping.FieldMappingId, step.StepOrder, step.TransformCode, step.Argument
    FROM (VALUES
      (N'ProductAttribute.F5 Visina',       1, N'NUMBER',      NULL),
      (N'ProductAttribute.F5 Enota visine', 1, N'UNIT',        NULL),
      (N'ProductAttribute.F5 Zatemnljivo',  1, N'BOOL',        N'Dimmable;Yes;Da'),
      (N'ProductAttribute.F5 Simbol',       1, N'PREFIX',      N'NW.'),
      (N'ProductAttribute.F5 Razred',       1, N'TRIM',        NULL),
      (N'ProductAttribute.F5 Razred',       2, N'STRIPPREFIX', N'CLASS '),
      (N'ProductAttribute.F5 Barva SLO',    1, N'LOOKUP',      N'SL'),
      (N'ProductAttribute.F5 Material SLO', 1, N'LOOKUP',      N'SL'),
      (N'ProductAttribute.F5 Neznano SLO',  1, N'LOOKUP',      N'SL')
    ) AS step(Code, StepOrder, TransformCode, Argument)
    INNER JOIN @Mapping mapping ON mapping.Code=step.Code;

    INSERT map.ValueLookup(Domain,SourceValue,Language,TargetValue,Note)
    VALUES(N'F5 Barva SLO',N'black',N'SL',N'črna',N'test 048');
    """, ("@SourceCode", sourceCode), ("@OrganizationId", organizationId), ("@EntityType", entityType));
}

async Task InsertInboxAsync(SqlConnection sqlConnection, Guid runId, string body, int pageNumber = 1)
{
  await ExecuteAsync(sqlConnection, """
    INSERT ops.PipelineRun(RunId,Pipeline,OrganizationId,SourceCode,Status)
    VALUES(@RunId,N'F5_TRANSFORM',@OrganizationId,@SourceCode,N'Running');
    INSERT raw.Inbox(RunId,OrganizationId,SourceCode,EntityType,PageNumber,PayloadXml,PayloadHash,Status)
    VALUES(@RunId,@OrganizationId,@SourceCode,@EntityType,@PageNumber,@Payload,@Hash,N'Pending');
    """, ("@RunId", runId), ("@OrganizationId", organizationId), ("@SourceCode", sourceCode),
    ("@EntityType", entityType), ("@PageNumber", pageNumber), ("@Payload", body),
    ("@Hash", Convert.ToHexString(SHA256.HashData(Encoding.Unicode.GetBytes(body)))));
}

async Task<string> AttributeAsync(SqlConnection sqlConnection, string attributeCode)
{
  return await ScalarAsync<string>(sqlConnection, """
    SELECT attribute.Value FROM canon.ProductAttribute attribute
    INNER JOIN canon.Product product ON product.ProductId=attribute.ProductId
    WHERE product.OrganizationId=@OrganizationId AND product.ItemID=@ItemID
      AND attribute.AttributeCode=@AttributeCode;
    """, ("@OrganizationId", organizationId), ("@ItemID", itemId), ("@AttributeCode", attributeCode));
}

async Task CleanupAsync(SqlConnection sqlConnection)
{
  await ExecuteAsync(sqlConnection, """
    DELETE unmapped FROM map.UnmappedValue unmapped
    INNER JOIN map.ExtractedValue value ON value.ExtractedValueId=unmapped.ExtractedValueId
    INNER JOIN raw.Inbox inbox ON inbox.InboxId=value.InboxId
    WHERE inbox.SourceCode=@SourceCode;

    DELETE value FROM map.ExtractedValue value
    INNER JOIN raw.Inbox inbox ON inbox.InboxId=value.InboxId
    WHERE inbox.SourceCode=@SourceCode;

    DELETE FROM raw.Inbox WHERE SourceCode=@SourceCode;
    DELETE FROM ops.PipelineRun WHERE SourceCode=@SourceCode;

    DELETE step FROM map.FieldTransform step
    INNER JOIN map.FieldMapping mapping ON mapping.FieldMappingId=step.FieldMappingId
    INNER JOIN map.SourceConnector connector ON connector.SourceConnectorId=mapping.SourceConnectorId
    WHERE connector.SourceCode=@SourceCode;

    DELETE mapping FROM map.FieldMapping mapping
    INNER JOIN map.SourceConnector connector ON connector.SourceConnectorId=mapping.SourceConnectorId
    WHERE connector.SourceCode=@SourceCode;

    DELETE entityMapping FROM map.EntityMapping entityMapping
    INNER JOIN map.SourceConnector connector ON connector.SourceConnectorId=entityMapping.SourceConnectorId
    WHERE connector.SourceCode=@SourceCode;

    DELETE FROM map.SourceConnector WHERE SourceCode=@SourceCode;

    DELETE FROM map.ValueLookup WHERE Note=N'test 048';
    DELETE FROM map.MissingTranslation WHERE Domain LIKE N'F5 %';

    /* Najprej lastnosti, sele nato zgodovina: brisanje lastnosti spet sprozi sledilnik
       sprememb (migracija 034) in bi po ociscenju zgodovine dodal nove vrstice. */
    DELETE attribute FROM canon.ProductAttribute attribute
    INNER JOIN canon.Product product ON product.ProductId=attribute.ProductId
    WHERE product.OrganizationId=@OrganizationId AND product.ItemID=@ItemID;

    DELETE history FROM pim.ProductFieldHistory history
    INNER JOIN canon.Product product ON product.ProductId=history.ProductId
    WHERE product.OrganizationId=@OrganizationId AND product.ItemID=@ItemID;
    DELETE batch FROM pim.ProductChangeBatch batch
    WHERE NOT EXISTS(SELECT 1 FROM pim.ProductFieldHistory history WHERE history.ChangeBatchId=batch.ChangeBatchId);

    /* Validacija lahko medtem tece kadarkoli in testnemu izdelku pripise stanje;
       brez tega DELETE pade na FK_ProductValidationState_Product. */
    DELETE state FROM val.ProductValidationState state
    INNER JOIN canon.Product product ON product.ProductId=state.ProductId
    WHERE product.OrganizationId=@OrganizationId AND product.ItemID=@ItemID;
    DELETE issue FROM val.ProductIssue issue
    INNER JOIN canon.Product product ON product.ProductId=issue.ProductId
    WHERE product.OrganizationId=@OrganizationId AND product.ItemID=@ItemID;

    DELETE FROM canon.Product WHERE OrganizationId=@OrganizationId AND ItemID=@ItemID;
    """, ("@SourceCode", sourceCode), ("@OrganizationId", organizationId), ("@ItemID", itemId));
}

static SqlCommand Command(SqlConnection connection, string sql, params (string Name, object Value)[] parameters)
{
  var command = new SqlCommand(sql, connection) { CommandTimeout = 180 };
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
  if (!EqualityComparer<T>.Default.Equals(expected, actual))
    throw new InvalidOperationException($"{message} Pričakovano={expected}, dejansko={actual}.");
}

static string? ReadConnectionString()
{
  var value = Environment.GetEnvironmentVariable("PIM_CONNECTION_STRING");
  if (!string.IsNullOrWhiteSpace(value)) return value;
  var directory = new DirectoryInfo(Directory.GetCurrentDirectory());
  while (directory is not null)
  {
    var path = Path.Combine(directory.FullName, "appsettings.Local.json");
    if (File.Exists(path))
    {
      using var document = JsonDocument.Parse(File.ReadAllText(path));
      if (document.RootElement.TryGetProperty("ConnectionStrings", out var connectionStrings)
        && connectionStrings.TryGetProperty("Pim", out var pim))
        return pim.GetString();
    }
    directory = directory.Parent;
  }
  return null;
}
