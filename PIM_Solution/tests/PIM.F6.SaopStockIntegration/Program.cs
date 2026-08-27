using System.Net;
using System.Text;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using PIM.SaopStockWorker;

// Dokaz za migracije 064–066 in PIM.SaopStockWorker: profil iz baze → zahteva → XML → stock.*.
// Živ SAOP se ne kliče; odgovor pošlje lokalni strežnik na 127.0.0.1, ki hkrati posname, kaj je
// worker vprašal. Prav to je bilo doslej nepreverljivo — worker je bil štirivrstični izpis.
//
// Kaj mora pokazati:
//   1. zahteva gre na api/Stock/GetStocks in nosi šifre skladišč iz canon.Warehouse (samo šifre);
//   2. glava OrganisationId je nastavljena — brez nje SAOP vrne napačno podjetje;
//   3. artikel, ki ga poznamo, se ujame in postane pozicija zaloge;
//   4. artikel, ki ga ne poznamo, ni tiho izgubljen: pozicija nastane brez izdelka (Unmatched).
//
// Test dela v izoliranem podjetju 9606 in za sabo pobriše vse svoje vrstice.

const int organizationId = 9606;
const string sourceCode = "SAOP_TEST_STOCK";
const string znanItemId = "F6-SAOP-ZNAN";
const string neznanItemId = "F6-SAOP-NEZNAN";

// Brez nastavljene povezave se preskoci, ne pade (isto pravilo kot v ostalih integracijah).
var connectionString = ReadConnectionString();
if (string.IsNullOrWhiteSpace(connectionString))
{
  Console.WriteLine("F6 SAOP zaloga preskocena: manjka razvojna povezava Pim.");
  return 0;
}

// Oblika je prepisana z ZIVEGA odziva SAOP (2026-08-27, podjetje 2, skladisce 0000003):
// element je <Item>, sifra pa je atribut ItemID. Prejsnja razlicica tega testa je uporabljala
// <ArrayOfStockItem><StockItem><ItemID>… po Swaggerju — oblika, ki je API ne vraca. Test je bil
// zato zelen, worker pa je v produkciji prebral nic.
var payload = $"""
  <?xml version="1.0" encoding="utf-8"?>
  <ArrayOfItem xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
    <Item ItemID="{znanItemId}"><Qty>12.500</Qty><StockSeries /></Item>
    <Item ItemID="{neznanItemId}"><Qty>3.000</Qty><StockSeries /></Item>
  </ArrayOfItem>
  """;

await using var connection = new SqlConnection(connectionString);
await connection.OpenAsync();
await CleanupAsync(connection);
try
{
  await SeedAsync(connection);

  using var listener = new HttpListener();
  var port = FreePort();
  var prefix = $"http://127.0.0.1:{port}/";
  listener.Prefixes.Add(prefix);
  listener.Start();

  string? zahtevanaPot = null;
  string? organisationHeader = null;
  var streznik = Task.Run(async () =>
  {
    var context = await listener.GetContextAsync();
    zahtevanaPot = context.Request.Url!.PathAndQuery;
    organisationHeader = context.Request.Headers["OrganisationId"];
    var bytes = Encoding.UTF8.GetBytes(payload);
    context.Response.ContentType = "application/xml";
    context.Response.ContentLength64 = bytes.Length;
    await context.Response.OutputStream.WriteAsync(bytes);
    context.Response.Close();
  });

  using var http = new HttpClient();
  var izid = await new SaopStockRunner(connectionString, http, new Uri(prefix)).RunAsync(organizationId);
  await streznik;
  listener.Stop();

  Equal("SAOP_TEST_GETSTOCKS", izid.ProfileCode, "Uporabljen je bil napacen profil.");
  Equal("GetStocks", izid.ProviderKind, "Uporabljen je bil napacen vmesnik.");
  Equal(2, izid.Warehouses, "Skladisci iz registra nista prisli v zahtevo.");
  Equal(2, izid.RecordsRead, "Iz odgovora nista prebrana oba zapisa.");

  if (zahtevanaPot is null || !zahtevanaPot.Contains("api/Stock/GetStocks", StringComparison.Ordinal))
    throw new InvalidOperationException($"Zahteva ni sla na GetStocks, ampak na {zahtevanaPot}.");
  // Sifra mora ohraniti vodilne nicle. Izmerjeno na zivem SAOP 2026-08-27: "0000003" vrne 138
  // zapisov, "3" pa HTTP 200 z enim praznim <Item>. Prej je ta test pricakoval "16,17" in s tem
  // potrjeval napako, zaradi katere je bila zaloga iz SAOP vedno prazna.
  if (!zahtevanaPot.Contains("warehouseIdList=0000016%2C0000017", StringComparison.Ordinal)
    && !zahtevanaPot.Contains("warehouseIdList=0000016,0000017", StringComparison.Ordinal))
    throw new InvalidOperationException($"Zahteva ne nosi sifer skladisc z vodilnimi niclami: {zahtevanaPot}.");
  if (zahtevanaPot.Contains("Testno", StringComparison.OrdinalIgnoreCase))
    throw new InvalidOperationException("V zahtevo je prislo ime skladisca; endpoint potrebuje samo sifro.");
  Equal(organizationId.ToString(), organisationHeader, "Glava OrganisationId ni nastavljena.");

  Equal(1, await ScalarAsync<int>(connection, """
    SELECT COUNT(*) FROM stock.Position pozicija
    INNER JOIN canon.Product product ON product.ProductId=pozicija.MatchedProductId
    WHERE product.OrganizationId=@OrganizationId AND product.ItemID=@ItemID AND pozicija.Quantity=12.5;
    """, ("@OrganizationId", organizationId), ("@ItemID", znanItemId)),
    "Znan artikel ni dobil pozicije zaloge.");

  // Artikel, ki ga ne vodimo, ni izgubljen in ni napaka: pozicija nastane z MatchKey='Unmatched'
  // in brez izdelka. stock.UnmatchedPosition je nekaj drugega — tam koncajo zapisi, ki ne prestanejo
  // normalizacije (brez identitete, brez kolicine), in prav teh v tem odgovoru ni.
  Equal(1, await ScalarAsync<int>(connection, """
    SELECT COUNT(*) FROM stock.Position pozicija
    INNER JOIN stock.LandingRecord landing ON landing.LandingRecordId=pozicija.LandingRecordId
    WHERE landing.OrganizationId=@OrganizationId AND landing.SourceItemId=@ItemID
      AND pozicija.MatchedProductId IS NULL AND pozicija.MatchKey=N'Unmatched' AND pozicija.Quantity=3;
    """, ("@OrganizationId", organizationId), ("@ItemID", neznanItemId)),
    "Neznan artikel ni dobil neujete pozicije.");

  Equal(0, await ScalarAsync<int>(connection, """
    SELECT COUNT(*) FROM stock.UnmatchedPosition neujeta
    INNER JOIN stock.LandingRecord landing ON landing.LandingRecordId=neujeta.LandingRecordId
    WHERE landing.OrganizationId=@OrganizationId;
    """, ("@OrganizationId", organizationId)),
    "Zapis je po nepotrebnem padel iz normalizacije.");

  Equal(1, await ScalarAsync<int>(connection, """
    SELECT COUNT(*) FROM stock.SaopProviderProfile
    WHERE OrganizationId=@OrganizationId AND ProfileCode=N'SAOP_TEST_GETSTOCKS' AND LastSuccessUtc IS NOT NULL;
    """, ("@OrganizationId", organizationId)), "Profil ni zabelezil uspesnega zajema.");

  Console.WriteLine("F6 SAOP zaloga: profil, sifre skladisc, glava podjetja, ujet in neujet artikel PASS.");
}
finally
{
  await CleanupAsync(connection);
}
return 0;

async Task SeedAsync(SqlConnection sqlConnection)
{
  await ExecuteAsync(sqlConnection, """
    IF NOT EXISTS(SELECT 1 FROM dbo.OrganizationConfig WHERE OrganizationId=@OrganizationId)
      INSERT dbo.OrganizationConfig(OrganizationId,Name,SaopPrefix,IsActive) VALUES(@OrganizationId,N'F6 test zaloge',N'F6',1);

    INSERT canon.Product(OrganizationId,ItemID,EAN) VALUES(@OrganizationId,@ItemID,N'9999900000066');

    /* Skladisci sta v registru s sifro IN imenom; v zahtevo sme samo sifra. */
    INSERT canon.Warehouse(OrganizationId,WarehouseCode,Name,IsActive)
    VALUES(@OrganizationId,N'0000016',N'Testno skladisce ena',1),
          (@OrganizationId,N'0000017',N'Testno skladisce dve',1),
          (@OrganizationId,N'0000018',N'Testno skladisce zaprto',0);

    INSERT stock.SaopProviderProfile(OrganizationId,ProfileCode,ProviderKind,Priority,Enabled,WarehouseSelectionMode)
    VALUES(@OrganizationId,N'SAOP_TEST_GETSTOCKS',N'GetStocks',10,1,N'ActiveFromRegister');

    INSERT map.SourceConnector(SourceCode,OrganizationId,ConnectorType,IsActive)
    VALUES(@SourceCode,@OrganizationId,N'SAOP',1);
    DECLARE @ConnectorId int=SCOPE_IDENTITY();
    INSERT map.StockIdentityRule(SourceConnectorId,SourceKeyField,Prefix,MatchPriority,IsActive)
    VALUES(@ConnectorId,N'SourceItemId',N'',N'ItemID',1);
    """, ("@OrganizationId", organizationId), ("@ItemID", znanItemId), ("@SourceCode", sourceCode));
}

async Task CleanupAsync(SqlConnection sqlConnection)
{
  await ExecuteAsync(sqlConnection, """
    DELETE neujeta FROM stock.UnmatchedPosition neujeta
    INNER JOIN stock.LandingRecord landing ON landing.LandingRecordId=neujeta.LandingRecordId
    WHERE landing.OrganizationId=@OrganizationId;
    DELETE pozicija FROM stock.Position pozicija
    INNER JOIN stock.LandingRecord landing ON landing.LandingRecordId=pozicija.LandingRecordId
    WHERE landing.OrganizationId=@OrganizationId;
    DELETE FROM stock.LandingRecord WHERE OrganizationId=@OrganizationId;
    DELETE FROM stock.Snapshot WHERE OrganizationId=@OrganizationId;
    DELETE FROM stock.SyncRun WHERE OrganizationId=@OrganizationId;
    DELETE FROM stock.SaopProviderProfile WHERE OrganizationId=@OrganizationId;

    DELETE pravilo FROM map.StockIdentityRule pravilo
    INNER JOIN map.SourceConnector connector ON connector.SourceConnectorId=pravilo.SourceConnectorId
    WHERE connector.OrganizationId=@OrganizationId;
    DELETE FROM map.SourceConnector WHERE OrganizationId=@OrganizationId;

    DELETE FROM canon.Warehouse WHERE OrganizationId=@OrganizationId;
    DELETE pravilo FROM canon.ProductStockPolicy pravilo
    INNER JOIN canon.Product product ON product.ProductId=pravilo.ProductId
    WHERE product.OrganizationId=@OrganizationId;

    DELETE state FROM val.ProductValidationState state
    INNER JOIN canon.Product product ON product.ProductId=state.ProductId WHERE product.OrganizationId=@OrganizationId;
    DELETE issue FROM val.ProductIssue issue
    INNER JOIN canon.Product product ON product.ProductId=issue.ProductId WHERE product.OrganizationId=@OrganizationId;
    /* Svezenj brisemo samo tistega, ki ga je naredil ta test. Prejsnja razlicica je vprasala
       "kateri svezenj nima vec zgodovine" nad celo tabelo; ta je z rastjo kataloga postala
       predraga in je test padel na casovni meji, ceprav ni bilo nic narobe. */
    DECLARE @Svezenj TABLE(ChangeBatchId bigint PRIMARY KEY);
    INSERT @Svezenj(ChangeBatchId)
    SELECT DISTINCT history.ChangeBatchId
    FROM pim.ProductFieldHistory history
    INNER JOIN canon.Product product ON product.ProductId=history.ProductId
    WHERE product.OrganizationId=@OrganizationId;

    DELETE history FROM pim.ProductFieldHistory history
    INNER JOIN canon.Product product ON product.ProductId=history.ProductId WHERE product.OrganizationId=@OrganizationId;

    DELETE batch FROM pim.ProductChangeBatch batch
    INNER JOIN @Svezenj mojSvezenj ON mojSvezenj.ChangeBatchId=batch.ChangeBatchId
    WHERE NOT EXISTS(SELECT 1 FROM pim.ProductFieldHistory history WHERE history.ChangeBatchId=batch.ChangeBatchId);
    DELETE FROM canon.Product WHERE OrganizationId=@OrganizationId;
    DELETE FROM dbo.OrganizationConfig WHERE OrganizationId=@OrganizationId;
    """, ("@OrganizationId", organizationId));
}

static int FreePort()
{
  var listener = new System.Net.Sockets.TcpListener(IPAddress.Loopback, 0);
  listener.Start();
  var port = ((IPEndPoint)listener.LocalEndpoint).Port;
  listener.Stop();
  return port;
}

static async Task ExecuteAsync(SqlConnection connection, string sql, params (string Name, object Value)[] parameters)
{
  await using var command = new SqlCommand(sql, connection) { CommandTimeout = 120 };
  foreach (var parameter in parameters) command.Parameters.AddWithValue(parameter.Name, parameter.Value);
  await command.ExecuteNonQueryAsync();
}

static async Task<T> ScalarAsync<T>(SqlConnection connection, string sql, params (string Name, object Value)[] parameters)
{
  await using var command = new SqlCommand(sql, connection) { CommandTimeout = 120 };
  foreach (var parameter in parameters) command.Parameters.AddWithValue(parameter.Name, parameter.Value);
  return (T)(await command.ExecuteScalarAsync() ?? throw new InvalidOperationException("Poizvedba ni vrnila vrednosti."));
}

static void Equal<T>(T expected, T actual, string message)
{
  if (!EqualityComparer<T>.Default.Equals(expected, actual))
    throw new InvalidOperationException($"{message} Pricakovano={expected}, dejansko={actual}.");
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
