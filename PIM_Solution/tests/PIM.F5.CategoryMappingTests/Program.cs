using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using PIM.XmlMapping;

// Dokaz za migracijo 059: dobaviteljeva kategorija se prevede v našo, in to v obeh jezikih
// spletne strani. Prej je v katalog padlo dobaviteljevo ime prve ravni ("Interior lighting")
// pod spletno stranjo B2C — angleška beseda v slovenskem stolpcu in brez preostalih ravni.
//
// Kaj mora ta test pokazati:
//   1. pot treh ravni se sestavi v ključ in najde v map.CategoryPathMap;
//   2. v katalog pride NAŠA pot, ne dobaviteljeva, za vsako spletno stran svojega jezika;
//   3. pot, ki je slovar ne pozna, ni napaka — pristane v map.MissingCategoryMap s števcem;
//   4. ponoven zagon ne podvoji ničesar.
//
// Test si naredi svoje drevo, svoj slovar in svojo spletno stran, in vse za sabo pobriše.

const int organizationId = 2;
const string sourceCode = "F5_CATEGORY";
const string entityType = "CategoryProbe";
const string treeCode = "f5_drevo";
const string siteSl = "f5_drevo_sl";
const string siteEn = "f5_drevo_en";
const string itemId = "F5-CATEGORY-PROBE";
const string itemIdUnknown = "F5-CATEGORY-PROBE-NEZNANA";
const string ean = "9999900000059";
const string eanUnknown = "9999900000060";
const string expectedSl = "Notranja svetila > Stenska svetila > Svečniki";
const string expectedEn = "Interior lighting > Wall lamps > Sconces";
const string unknownKey = "track_systems___3-circuit_ctls___accessories";

// Brez nastavljene povezave se preskoci, ne pade (glej isti popravek v F2/F3/F5/F8/F9):
// padec je pomenil, da je paket na racunalniku brez razvojne baze videti pokvarjen.
// Kjer je povezava nastavljena, dokaz tece kot prej.
var connectionString = ReadConnectionString();
if (string.IsNullOrWhiteSpace(connectionString))
{
  Console.WriteLine("F5 kategorije preskocene: manjka razvojna povezava Pim.");
  return 0;
}
var builder = new SqlConnectionStringBuilder(connectionString);
if (!string.Equals(builder.InitialCatalog, "PIM", StringComparison.OrdinalIgnoreCase) || !builder.IntegratedSecurity)
  throw new InvalidOperationException("Test se sme zaganjati samo z Windows Integrated Auth v bazi PIM.");

// Ravni so zapisane tako, kot jih pošlje Nowodvorski: velike začetnice in presledki.
// Ključ nastane šele v postopku — če bi ga sestavljal test, ne bi dokazal ničesar.
var payload = $"""
  <feed>
    <product>
      <item>{itemId}</item>
      <ean>{ean}</ean>
      <c><i>Interior lighting</i><ii>Wall lamps</ii><iii>Sconces</iii></c>
    </product>
    <product>
      <item>{itemIdUnknown}</item>
      <ean>{eanUnknown}</ean>
      <c><i>Track systems</i><ii>3-circuit CTLS</ii><iii>Accessories</iii></c>
    </product>
  </feed>
  """;

await using var connection = new SqlConnection(connectionString);
await connection.OpenAsync();
await CleanupAsync(connection);
try
{
  await SeedProductsAsync(connection);
  await SeedTreeAsync(connection);
  await SeedRegistryAsync(connection);

  var firstRun = Guid.NewGuid();
  await InsertInboxAsync(connection, firstRun, payload);
  await new SqlMappingPipeline(connectionString).ExtractAndApplyAsync(firstRun, organizationId, sourceCode);

  Equal("Processed", await ScalarAsync<string>(connection,
    "SELECT Status FROM raw.Inbox WHERE RunId=@RunId;", ("@RunId", firstRun)),
    "Paket se ni dokončal.");

  Equal(expectedSl, await PathAsync(connection, itemId, siteSl), "Slovenska pot ni naša pot.");
  Equal(expectedEn, await PathAsync(connection, itemId, siteEn), "Angleška pot ni sestavljena iz prevodov.");

  Equal(0, await ScalarAsync<int>(connection, """
    SELECT COUNT(*) FROM canon.ProductCategory category
    INNER JOIN canon.Product product ON product.ProductId=category.ProductId
    WHERE product.OrganizationId=@OrganizationId AND product.ItemID=@ItemID
      AND category.CategoryPath LIKE N'%Interior lighting > Wall lamps > Sconces%'
      AND category.WebSite=@Site;
    """, ("@OrganizationId", organizationId), ("@ItemID", itemId), ("@Site", siteSl)),
    "Dobaviteljeva angleška pot je pristala v slovenskem stolpcu.");

  Equal(0, await ScalarAsync<int>(connection, """
    SELECT COUNT(*) FROM canon.ProductCategory category
    INNER JOIN canon.Product product ON product.ProductId=category.ProductId
    WHERE product.OrganizationId=@OrganizationId AND product.ItemID=@ItemID;
    """, ("@OrganizationId", organizationId), ("@ItemID", itemIdUnknown)),
    "Izdelek z neznano potjo je vseeno dobil kategorijo.");

  Equal(1, await ScalarAsync<int>(connection, """
    SELECT SeenCount FROM map.MissingCategoryMap
    WHERE SourceCode=@SourceCode AND CategoryTreeCode=@TreeCode AND SourcePathKey=@Key;
    """, ("@SourceCode", sourceCode), ("@TreeCode", treeCode), ("@Key", unknownKey)),
    "Neznana pot ni pristala na delovnem seznamu s pravim ključem.");

  // Drugi zajem iste vsebine: nič novega v katalogu, števec neznane poti pa se premakne.
  var secondRun = Guid.NewGuid();
  await InsertInboxAsync(connection, secondRun, payload, 2);
  await new SqlMappingPipeline(connectionString).ExtractAndApplyAsync(secondRun, organizationId, sourceCode);

  Equal(2, await ScalarAsync<int>(connection, """
    SELECT COUNT(*) FROM canon.ProductCategory category
    INNER JOIN canon.Product product ON product.ProductId=category.ProductId
    WHERE product.OrganizationId=@OrganizationId AND product.ItemID=@ItemID;
    """, ("@OrganizationId", organizationId), ("@ItemID", itemId)),
    "Ponoven zajem je podvojil kategorije.");

  Console.WriteLine("F5 kategorije: ključ poti, naša pot v obeh jezikih, delovni seznam neznanih in ponoven zagon PASS.");
}
finally
{
  await CleanupAsync(connection);
}
return 0;

async Task SeedProductsAsync(SqlConnection sqlConnection)
{
  await ExecuteAsync(sqlConnection, """
    INSERT canon.Product(OrganizationId,ItemID,EAN,Manufacturer,UoM)
    VALUES(@OrganizationId,@ItemID,@EAN,N'F5 maker',N'kos'),
          (@OrganizationId,@ItemIDUnknown,@EANUnknown,N'F5 maker',N'kos');
    """, ("@OrganizationId", organizationId), ("@ItemID", itemId), ("@EAN", ean),
    ("@ItemIDUnknown", itemIdUnknown), ("@EANUnknown", eanUnknown));
}

async Task SeedTreeAsync(SqlConnection sqlConnection)
{
  await ExecuteAsync(sqlConnection, """
    INSERT canon.WebSite(WebSiteCode,WebSiteName,CategoryTreeCode,LanguageCode,CategoryFieldCode,SortOrder,IsActive)
    VALUES(@SiteSl,N'F5 drevo (SLO)',@TreeCode,N'sl',N'Product.F5CategorySl',900,1),
          (@SiteEn,N'F5 drevo (ANG)',@TreeCode,N'en',N'Product.F5CategoryEn',901,1);

    INSERT canon.Category(CategoryTreeCode,CategoryCode,ParentCategoryCode,LevelNo,CategoryName,CategoryPath,IsActive)
    VALUES(@TreeCode,N'f5_notranja',NULL,1,N'Notranja svetila',N'Notranja svetila',1),
          (@TreeCode,N'f5_stenska',N'f5_notranja',2,N'Stenska svetila',N'Notranja svetila > Stenska svetila',1),
          (@TreeCode,N'f5_svecniki',N'f5_stenska',3,N'Svečniki',N'Notranja svetila > Stenska svetila > Svečniki',1);

    INSERT canon.CategoryTranslation(CategoryTreeCode,CategoryCode,LanguageCode,CategoryName)
    VALUES(@TreeCode,N'f5_notranja',N'sl',N'Notranja svetila'),
          (@TreeCode,N'f5_stenska',N'sl',N'Stenska svetila'),
          (@TreeCode,N'f5_svecniki',N'sl',N'Svečniki'),
          (@TreeCode,N'f5_notranja',N'en',N'Interior lighting'),
          (@TreeCode,N'f5_stenska',N'en',N'Wall lamps'),
          (@TreeCode,N'f5_svecniki',N'en',N'Sconces');

    INSERT map.CategoryPathMap(SourceCode,CategoryTreeCode,SourcePathKey,CategoryCode,IsActive)
    VALUES(@SourceCode,@TreeCode,N'interior_lighting___wall_lamps___sconces',N'f5_svecniki',1);
    """, ("@SiteSl", siteSl), ("@SiteEn", siteEn), ("@TreeCode", treeCode), ("@SourceCode", sourceCode));
}

async Task SeedRegistryAsync(SqlConnection sqlConnection)
{
  await ExecuteAsync(sqlConnection, """
    INSERT map.SourceConnector(SourceCode,OrganizationId,ConnectorType,IsActive)
    VALUES(@SourceCode,@OrganizationId,N'FILE_XML',1);
    DECLARE @ConnectorId int=SCOPE_IDENTITY();
    INSERT map.EntityMapping(SourceConnectorId,EntityType,RecordXPath,IsActive)
    VALUES(@ConnectorId,@EntityType,N'/feed/product',1);

    INSERT map.FieldMapping(SourceConnectorId,EntityType,SourceElement,TargetFieldCode,IsRequired,IsActive,MappingVersion)
    VALUES(@ConnectorId,@EntityType,N'item/text()',N'Product.ItemID',1,1,1),
          (@ConnectorId,@EntityType,N'ean/text()',N'Product.EAN',0,1,1),
          (@ConnectorId,@EntityType,N'c/i/text()',N'ProductCategory.SourceLevel1',0,1,1),
          (@ConnectorId,@EntityType,N'c/ii/text()',N'ProductCategory.SourceLevel2',0,1,1),
          (@ConnectorId,@EntityType,N'c/iii/text()',N'ProductCategory.SourceLevel3',0,1,1);
    """, ("@SourceCode", sourceCode), ("@OrganizationId", organizationId), ("@EntityType", entityType));
}

async Task InsertInboxAsync(SqlConnection sqlConnection, Guid runId, string body, int pageNumber = 1)
{
  await ExecuteAsync(sqlConnection, """
    INSERT ops.PipelineRun(RunId,Pipeline,OrganizationId,SourceCode,Status)
    VALUES(@RunId,N'F5_CATEGORY',@OrganizationId,@SourceCode,N'Running');
    INSERT raw.Inbox(RunId,OrganizationId,SourceCode,EntityType,PageNumber,PayloadXml,PayloadHash,Status)
    VALUES(@RunId,@OrganizationId,@SourceCode,@EntityType,@PageNumber,@Payload,@Hash,N'Pending');
    """, ("@RunId", runId), ("@OrganizationId", organizationId), ("@SourceCode", sourceCode),
    ("@EntityType", entityType), ("@PageNumber", pageNumber), ("@Payload", body),
    ("@Hash", Convert.ToHexString(SHA256.HashData(Encoding.Unicode.GetBytes(body + pageNumber)))));
}

async Task<string> PathAsync(SqlConnection sqlConnection, string productItemId, string webSite)
{
  return await ScalarAsync<string>(sqlConnection, """
    SELECT category.CategoryPath FROM canon.ProductCategory category
    INNER JOIN canon.Product product ON product.ProductId=category.ProductId
    WHERE product.OrganizationId=@OrganizationId AND product.ItemID=@ItemID AND category.WebSite=@Site;
    """, ("@OrganizationId", organizationId), ("@ItemID", productItemId), ("@Site", webSite));
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

    DELETE mapping FROM map.FieldMapping mapping
    INNER JOIN map.SourceConnector connector ON connector.SourceConnectorId=mapping.SourceConnectorId
    WHERE connector.SourceCode=@SourceCode;
    DELETE entityMapping FROM map.EntityMapping entityMapping
    INNER JOIN map.SourceConnector connector ON connector.SourceConnectorId=entityMapping.SourceConnectorId
    WHERE connector.SourceCode=@SourceCode;
    DELETE FROM map.SourceConnector WHERE SourceCode=@SourceCode;

    DELETE FROM map.CategoryPathMap WHERE SourceCode=@SourceCode;
    DELETE FROM map.MissingCategoryMap WHERE SourceCode=@SourceCode;

    /* Kategorije izdelka gredo pred spletno stranjo: od migracije 063 canon.ProductCategory
       kaze na canon.WebSite s tujim kljucem in obratni vrstni red pade s 547. */
    DELETE category FROM canon.ProductCategory category
    INNER JOIN canon.Product product ON product.ProductId=category.ProductId
    WHERE product.OrganizationId=@OrganizationId AND product.ItemID IN (@ItemID,@ItemIDUnknown);

    DELETE FROM canon.CategoryTranslation WHERE CategoryTreeCode=@TreeCode;
    DELETE FROM canon.Category WHERE CategoryTreeCode=@TreeCode;
    DELETE FROM canon.WebSite WHERE CategoryTreeCode=@TreeCode;

    /* Najprej odvisne vrstice, sele nato izdelek — enak vrstni red kot v testu pretvorb. */
    DELETE history FROM pim.ProductFieldHistory history
    INNER JOIN canon.Product product ON product.ProductId=history.ProductId
    WHERE product.OrganizationId=@OrganizationId AND product.ItemID IN (@ItemID,@ItemIDUnknown);
    DELETE batch FROM pim.ProductChangeBatch batch
    WHERE NOT EXISTS(SELECT 1 FROM pim.ProductFieldHistory history WHERE history.ChangeBatchId=batch.ChangeBatchId);

    DELETE state FROM val.ProductValidationState state
    INNER JOIN canon.Product product ON product.ProductId=state.ProductId
    WHERE product.OrganizationId=@OrganizationId AND product.ItemID IN (@ItemID,@ItemIDUnknown);
    DELETE issue FROM val.ProductIssue issue
    INNER JOIN canon.Product product ON product.ProductId=issue.ProductId
    WHERE product.OrganizationId=@OrganizationId AND product.ItemID IN (@ItemID,@ItemIDUnknown);

    DELETE FROM canon.Product WHERE OrganizationId=@OrganizationId AND ItemID IN (@ItemID,@ItemIDUnknown);
    """, ("@SourceCode", sourceCode), ("@OrganizationId", organizationId), ("@ItemID", itemId),
    ("@ItemIDUnknown", itemIdUnknown), ("@TreeCode", treeCode));
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
