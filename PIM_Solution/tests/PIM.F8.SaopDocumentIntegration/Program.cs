using System.Net;
using System.Text;
using Microsoft.Data.SqlClient;
using PIM.Outbound;
using PIM.OutboxDispatcher;

// F8 — odhodna pot na ravni dokumenta, od naročila spremembe do odgovora SAOP.
//
// To je dokaz, da mehanizem deluje kot celota: naročilo (out.EnqueueSaopItemChange), združevanje
// sprememb enega zapisa v en dokument (out.ClaimItemDocument), sestavljanje XML, pošiljanje,
// branje odgovora in samopopravek napačno izbrane metode.
//
// HTTP gre izključno na lokalni 127.0.0.1 fixture, ki se predstavlja kot SAOP in vrača resnične
// oblike odgovorov. Proti pravemu SAOP ta test ne govori in ne sme.
//
// Vse vrstice nastanejo v izolirani organizaciji 9821 in se v finally pobrišejo.

const int organizationId = 9821;
const string vObstojecem = "F8D-OBSTOJEC";
const string vNovem = "F8D-NOV";

var connectionString = ReadConnectionString();
if (string.IsNullOrWhiteSpace(connectionString))
{
  Console.WriteLine("F8 dokument: preskočeno, lokalna PIM povezava ni na voljo.");
  return 0;
}

var settings = new SqlConnectionStringBuilder(connectionString);
if (!string.Equals(settings.InitialCatalog, "PIM", StringComparison.OrdinalIgnoreCase))
  throw new InvalidOperationException("F8 dokaz je dovoljen samo v razvojni bazi PIM.");

var port = FreePort();
var fixture = new SaopFixture(port);
fixture.Start();

await using var connection = new SqlConnection(connectionString);
await connection.OpenAsync();

try
{
  /* --- 0) Register dveh pisljivih polj iz preglednice ------------------------------ */

  var saopOrganizations = await SaopOrganizationIdsAsync();
  Equal(true, saopOrganizations.Count > 0, "Vsaj en aktivni SAOP konektor mora obstajati");
  Equal(saopOrganizations.Count * 2, await ScalarIntAsync("""
    SELECT COUNT(*)
    FROM map.FieldMapping AS mapping
    INNER JOIN map.SourceConnector AS connector
      ON connector.SourceConnectorId = mapping.SourceConnectorId
    WHERE connector.IsActive = 1
      AND connector.SourceCode LIKE N'SAOP[_]%'
      AND connector.SourceCode NOT LIKE N'%[_]STOCK'
      AND mapping.IsActive = 1
      AND
      (
        (mapping.SourceElement = N'GeneralData/ItemSearchName/text()[1]'
          AND mapping.TargetFieldCode = N'ProductText.SEARCH_NAME.sl')
        OR
        (mapping.SourceElement = N'SalesData/Warranty/text()[1]'
          AND mapping.TargetFieldCode = N'ProductAttribute.Garancija')
      );
    """), "Vsak aktivni SAOP konektor mora brati ime za iskanje in garancijo");

  foreach (var saopOrganizationId in saopOrganizations)
  {
    var writable = await WritableFieldsAsync(saopOrganizationId);
    Equal(true, writable.Contains("ProductText.SEARCH_NAME.sl", StringComparer.OrdinalIgnoreCase),
      $"Organizacija {saopOrganizationId} mora ponujati Ime za iskanje");
    Equal(true, writable.Contains("ProductAttribute.Garancija", StringComparer.OrdinalIgnoreCase),
      $"Organizacija {saopOrganizationId} mora ponujati Garancijo");
  }

  await SetupAsync();

  /* --- 1) Naročilo spremembe --------------------------------------------------------- */

  var batchId = await BeginBatchAsync("BULK", "Test množične spremembe");

  // Polje, ki ni del dokumenta, mora pasti takoj ob naročilu — sicer bi sporočilo čakalo v
  // vrsti in nikoli ne bi odšlo.
  await ExpectFailureAsync(
    () => EnqueueAsync(vObstojecem, "Product.NekajIzmisljenega", "x", batchId),
    "Polje zunaj dokumenta mora biti zavrnjeno ob naročilu");

  // Polje brez lastništva PIM mora pasti na obstoječi varovalki iz migracije 068.
  await ExpectFailureAsync(
    () => EnqueueAsync(vObstojecem, "Product.ItemGroup", "SKUPINA", batchId),
    "Polje brez lastništva PIM mora biti zavrnjeno");

  var prvo = await EnqueueAsync(vObstojecem, "ProductText.TITLE_ERP.sl", "Nov naziv", batchId);
  var drugo = await EnqueueAsync(vObstojecem, "Product.EAN", "3830000000017", batchId);
  Equal(true, prvo > 0 && drugo > 0 && prvo != drugo, "Dve različni polji sta dve sporočili");

  // Isto naročilo dvakrat ne sme nastati dvakrat: dvakrat kliknjen gumb ne pošlje dvakrat.
  Equal(prvo, await EnqueueAsync(vObstojecem, "ProductText.TITLE_ERP.sl", "Nov naziv", batchId),
    "Enaka sprememba se ne sme podvojiti");

  Equal(2, await ScalarIntAsync($"SELECT COUNT(*) FROM out.OutboxMessage WHERE OutboundBatchId={batchId};"),
    "Obe spremembi morata pripadati isti skupini");

  /* --- 2) Suhi tek ne porabi poskusa --------------------------------------------------- */

  var predSuhim = await ScalarIntAsync($"SELECT MAX(AttemptCount) FROM out.OutboxMessage WHERE OutboundBatchId={batchId};");
  var suhi = await RunAsync(dryRun: true, sender: null);
  Equal(1, suhi.Documents, "Dve spremembi istega artikla sta EN dokument");
  Equal(predSuhim, await ScalarIntAsync($"SELECT MAX(AttemptCount) FROM out.OutboxMessage WHERE OutboundBatchId={batchId};"),
    "Suhi tek ne sme porabiti poskusa");
  Equal("Pending", await StatusAsync(prvo), "Suhi tek ne sme spremeniti stanja sporočila");

  /* --- 3) Pravo pošiljanje na lokalni fixture ------------------------------------------ */

  fixture.Respond(SaopFixture.UpdateOk);
  var poslano = await RunAsync(dryRun: false, sender: NewSender());
  Equal(1, poslano.Documents, "En dokument");
  Equal(1, poslano.Sent, "Dokument mora biti sprejet");
  Equal("Sent", await StatusAsync(prvo), "Obe sporočili dokumenta gresta v Sent");
  Equal("Sent", await StatusAsync(drugo), "Obe sporočili dokumenta gresta v Sent");

  var zahteva = fixture.LastRequest ?? throw new InvalidOperationException("Fixture ni prejel zahteve.");
  Equal("PATCH", zahteva.Method, "Obstoječ artikel gre s PATCH");
  Equal("/api/Item/UpdateItemsGeneralData", zahteva.Path, "Pot za spremembo artikla");
  Equal(organizationId.ToString(), zahteva.OrganisationId, "Glava OrganisationId mora biti postavljena");
  Equal(true, zahteva.ContentType?.StartsWith("application/xml", StringComparison.OrdinalIgnoreCase) ?? false,
    "SAOP sprejema application/xml, ne JSON");
  Equal(true, zahteva.Authorization?.StartsWith("Basic ", StringComparison.Ordinal) ?? false,
    "Brez Basic avtentikacije bi vsaka zahteva vrnila 401");
  Equal(true, zahteva.Body.StartsWith("<?xml version=\"1.0\" encoding=\"utf-8\"?>", StringComparison.Ordinal),
    "SAOP hoče točno to deklaracijo");
  Equal(true, zahteva.Body.Contains("<ItemTitle1>Nov naziv</ItemTitle1>"), "Prva sprememba mora biti v dokumentu");
  Equal(true, zahteva.Body.Contains("<ItemEANCode>3830000000017</ItemEANCode>"), "Druga sprememba mora biti v istem dokumentu");
  Equal(true, zahteva.Body.Contains("<ItemLastModified>"), "Sprememba nosi ItemLastModified");
  // Sprememba nosi SAMO spremenjena polja: vsako poslano polje SAOP prepiše.
  Equal(false, zahteva.Body.Contains("<VATRateID>"), "Privzetek ne sme povoziti vrednosti, ki jo SAOP že ima");

  /* --- 4) HTTP 200 z napako v telesu ni uspeh ------------------------------------------ */

  var lazni = await EnqueueAsync(vObstojecem, "Product.EAN", "3830000000024", batchId);
  fixture.Respond(SaopFixture.UpdateErrorInBody);
  var zavrnjeno = await RunAsync(dryRun: false, sender: NewSender());
  Equal(1, zavrnjeno.Failed, "ResultCode=Error je zavrnitev, tudi pri HTTP 200");
  // Poslovna zavrnitev, ki je PIM ne zna popraviti sam, gre takoj v Dead: ponavljanje istega
  // dokumenta bi dalo isti odgovor in bi samo porabilo poskuse.
  Equal("Dead", await StatusAsync(lazni), "Poslovna zavrnitev ne sme obveljati za poslano in se ne sme ponavljati");
  Equal(nameof(SaopErrorKind.CodebookMissing), await ErrorKindAsync(lazni),
    "Vrsta zavrnitve se zapiše na sporočilo, da se da napaka razložiti brez branja surovega odgovora");
  Equal(true, (await LastErrorAsync(lazni))?.Contains("šifrant") ?? false,
    "Razlog mora biti navodilo uporabniku, ne surov HTTP izpis");

  /* --- 4b) Nepopolno ustvarjanje ne gre ven -------------------------------------------- */
  //
  // Artikel, ki ga SAOP ne pozna in mu manjka obvezno polje, ne sme oditi. SAOP bi ga zavrnil,
  // poskus bi bil porabljen, v pregledu pa bi izgledal kot napaka SAOP — čeprav je manjkal
  // podatek pri nas. Tu manjka naziv: naročena je samo koda EAN.

  var nepopoln = await EnqueueAsync("F8D-NEPOPOLN", "Product.EAN", "3830000000031", batchId);
  var predKlicem = fixture.RequestCount;
  var nepopolnIzid = await RunAsync(dryRun: false, sender: NewSender());
  Equal(1, nepopolnIzid.Failed, "Nepopoln dokument mora biti označen kot neuspeh");
  Equal(predKlicem, fixture.RequestCount, "Nepopoln dokument ne sme sprožiti nobene zahteve");
  Equal(true, (await LastErrorAsync(nepopoln))?.Contains("ItemTitle1") ?? false,
    "Razlog mora povedati, katero polje manjka");

  /* --- 5) Samopopravek napačno izbrane metode ------------------------------------------ */
  //
  // 118 od 130 napak stare vrste je bila natanko ta: poslan ADD za obstoječ artikel ali PATCH
  // za neobstoječega. Artikla vNovem v canon.Product ni, zato pot izbere ADD; SAOP odgovori,
  // da artikel že obstaja; pot si to zapomni in naslednjič pošlje PATCH.

  var novi = await EnqueueAsync(vNovem, "ProductText.TITLE_ERP.sl", "Naziv novega", batchId);
  var predSamopopravkom = fixture.RequestCount;
  fixture.RespondByMethod(post: SaopFixture.AlreadyExists, patch: SaopFixture.UpdateOk);

  var samopopravek = await RunAsync(dryRun: false, sender: NewSender());
  Equal(1, samopopravek.Documents, "Samopopravek se zgodi znotraj enega prevzema, ne z vrtenjem zanke");
  Equal(1, samopopravek.Sent, "Po popravku metode mora dokument uspeti");
  Equal(2, fixture.RequestCount - predSamopopravkom, "Dva klica: napačna metoda in takoj popravljena");
  Equal("PATCH", fixture.LastRequest!.Method, "Zavrnitev SAOP prevlada nad tem, kar sklepamo iz baze");
  Equal("Sent", await StatusAsync(novi), "Po samopopravku je sporočilo poslano");
  Equal(1, await ScalarIntAsync($"SELECT AttemptCount FROM out.OutboxMessage WHERE OutboxMessageId={novi};"),
    "Samopopravek ne sme porabiti drugega poskusa");

  /* --- 6) Šifra, ki jo dodeli SAOP ----------------------------------------------------- */

  var zaSifro = await EnqueueAsync("F8D-SIFRA", "ProductText.TITLE_ERP.sl", "Artikel brez šifre", batchId);
  fixture.RespondByMethod(post: SaopFixture.CreatedWithCode, patch: SaopFixture.UpdateOk);
  var ustvarjeno = await RunAsync(dryRun: false, sender: NewSender());
  Equal(1, ustvarjeno.Sent, "Ustvarjanje mora uspeti");
  Equal("SAOP-DODELJENA", await ScalarStringAsync(
    $"SELECT TOP(1) AssignedSaopItemId FROM out.SaopItemAssignment WHERE OutboxMessageId={zaSifro};"),
    "Šifra iz Keys/Key[SifraArtikla] se mora zapisati");

  Console.WriteLine("F8 dokument: naročilo, združevanje sprememb v en dokument, suhi tek brez porabe poskusa, "
    + "Basic + OrganisationId + application/xml, HTTP 200 z napako v telesu, samopopravek ADD/PATCH in "
    + "prevzem dodeljene šifre PASS.");
  return 0;
}
finally
{
  fixture.Stop();
  await CleanupAsync();
}

/* --- pomožno ------------------------------------------------------------------------- */

SaopDocumentSender NewSender() =>
  new(new SaopConnection($"http://127.0.0.1:{port}/", "f8-uporabnik", "f8-geslo", TimeoutSeconds: 30));

async Task<SaopDocumentRunResult> RunAsync(bool dryRun, SaopDocumentSender? sender)
{
  using (sender)
  {
    var runner = new SaopDocumentRunner(connectionString!, $"f8d:{Environment.ProcessId}",
      new("SAOP_PRODUCT", dryRun, OutputDirectory: null, MaxDocuments: 5, OrganizationId: organizationId), sender);
    return await runner.RunAsync();
  }
}

async Task SetupAsync()
{
  await CleanupAsync();
  await SqlAsync("INSERT dbo.OrganizationConfig(OrganizationId,Name,SaopPrefix) VALUES(@Org,N'F8D_ISOLATED',N'F8D');",
    ("@Org", organizationId));
  await SqlAsync(
    "INSERT dbo.IntegrationProfile(OrganizationId,TargetKind,EndpointTemplate,HttpOperation,ApprovalMode,IsEnabled,"
    + "TimeoutSeconds,MaxAttempts,BaseRetrySeconds,UpdatedBy) "
    + "VALUES(@Org,N'SAOP_PRODUCT',@Base,N'PATCH',N'Automatic',1,30,5,1,N'F8D');",
    ("@Org", organizationId), ("@Base", $"http://127.0.0.1:{port}/"));

  // Samo dve polji sta v lasti PIM; tretje ostane pri SAOP, da se da zavrnitev dokazati.
  foreach (var (field, owner) in new[]
  {
    ("ProductText.TITLE_ERP.sl", "PIM"), ("Product.EAN", "PIM"), ("Product.ItemGroup", "SAOP")
  })
    await SqlAsync(
      "INSERT out.OwnershipPolicy(OrganizationId,TargetKind,EntityType,FieldName,Owner,IsEnabled,UpdatedBy) "
      + "VALUES(@Org,N'SAOP_PRODUCT',N'Product',@Field,@Owner,1,N'F8D');",
      ("@Org", organizationId), ("@Field", field), ("@Owner", owner));

  // Privzetki, brez katerih ustvarjanje ne more biti popolno. Isti nabor, kot ga ima migracija
  // 081 za prave organizacije, plus tisti, ki jih pravi artikel dobi iz kanoničnega modela.
  foreach (var (section, element, value) in new[]
  {
    ("GeneralData", "ItemType", "B"), ("GeneralData", "ItemUnitOfMeas", "kom"),
    ("GeneralData", "VATRateID", "02"), ("GeneralData", "ItemGroup", "F8DG"),
    ("GeneralData", "AccountingBookGroupID", "F8DG"), ("GeneralData", "ItemDepartment", "C"),
    ("SalesData", "DiscountGroup1ID", "F8DG"), ("SalesData", "IsActive", "D"),
    ("StockData", "SupplierID", "F8DS")
  })
    await SqlAsync(
      "INSERT out.SaopAddDefault(OrganizationId,SourceKey,Section,ElementName,Value,IsEnabled,UpdatedBy) "
      + "VALUES(@Org,N'*',@Section,@Element,@Value,1,N'F8D');",
      ("@Org", organizationId), ("@Section", section), ("@Element", element), ("@Value", value));

  // Samo prvi artikel obstaja v kanoničnem modelu — torej ga SAOP pozna in gre s PATCH.
  await SqlAsync(
    "INSERT canon.Product(OrganizationId,ItemID,ItemGroup,UoM,AccountingGroup,Department,DiscountGroup,Supplier,BusinessHash) "
    + "VALUES(@Org,@Item,N'F8DG',N'kom',N'F8DG',N'C',N'F8DG',N'F8DS',NULL);",
    ("@Org", organizationId), ("@Item", vObstojecem));
}

async Task CleanupAsync()
{
  // Pobriše izključno vrstice, ki jih je ta test ustvaril, in samo v svoji organizaciji.
  await SqlAsync("""
    DELETE FROM ops.OutboundEvent WHERE OrganizationId = @Org;
    DELETE assignment FROM out.SaopItemAssignment assignment
      INNER JOIN out.OutboxMessage message ON message.OutboxMessageId = assignment.OutboxMessageId
      WHERE message.OrganizationId = @Org;
    DELETE attempt FROM out.OutboxAttempt attempt
      INNER JOIN out.OutboxMessage message ON message.OutboxMessageId = attempt.OutboxMessageId
      WHERE message.OrganizationId = @Org;
    DELETE FROM out.OutboxMessage WHERE OrganizationId = @Org;
    DELETE FROM out.OutboundBatch WHERE OrganizationId = @Org;
    DELETE FROM out.OwnershipPolicy WHERE OrganizationId = @Org;
    DELETE FROM canon.Product WHERE OrganizationId = @Org;
    DELETE FROM out.SaopAddDefault WHERE OrganizationId = @Org;
    DELETE FROM dbo.IntegrationProfile WHERE OrganizationId = @Org;
    DELETE FROM dbo.OrganizationConfig WHERE OrganizationId = @Org;
    """, ("@Org", organizationId));
}

async Task<long> BeginBatchAsync(string source, string note)
{
  await using var command = new SqlCommand(
    "DECLARE @Id bigint; EXEC out.BeginOutboundBatch @Org, @Source, @Note, N'F8D', @Id OUTPUT; SELECT @Id;", connection);
  command.Parameters.AddWithValue("@Org", organizationId);
  command.Parameters.AddWithValue("@Source", source);
  command.Parameters.AddWithValue("@Note", note);
  return Convert.ToInt64(await command.ExecuteScalarAsync());
}

async Task<long> EnqueueAsync(string itemId, string fieldKey, string value, long batchId)
{
  await using var command = new SqlCommand(
    "DECLARE @Id bigint; EXEC out.EnqueueSaopItemChange @Org,@Item,@Field,@Value,N'F8D',@Batch,@Id OUTPUT; SELECT @Id;",
    connection);
  command.Parameters.AddWithValue("@Org", organizationId);
  command.Parameters.AddWithValue("@Item", itemId);
  command.Parameters.AddWithValue("@Field", fieldKey);
  command.Parameters.AddWithValue("@Value", value);
  command.Parameters.AddWithValue("@Batch", batchId);
  var result = await command.ExecuteScalarAsync();
  return result is null or DBNull ? 0 : Convert.ToInt64(result);
}

async Task SqlAsync(string sql, params (string Name, object Value)[] parameters)
{
  await using var command = new SqlCommand(sql, connection) { CommandTimeout = 120 };
  foreach (var (name, value) in parameters) command.Parameters.AddWithValue(name, value);
  await command.ExecuteNonQueryAsync();
}

async Task<int> ScalarIntAsync(string sql)
{
  await using var command = new SqlCommand(sql, connection);
  var value = await command.ExecuteScalarAsync();
  return value is null or DBNull ? 0 : Convert.ToInt32(value);
}

async Task<List<int>> SaopOrganizationIdsAsync()
{
  await using var command = new SqlCommand("""
    SELECT DISTINCT connector.OrganizationId
    FROM map.SourceConnector AS connector
    WHERE connector.IsActive = 1
      AND connector.SourceCode LIKE N'SAOP[_]%'
      AND connector.SourceCode NOT LIKE N'%[_]STOCK'
    ORDER BY connector.OrganizationId;
    """, connection);
  await using var reader = await command.ExecuteReaderAsync();
  var result = new List<int>();
  while (await reader.ReadAsync()) result.Add(reader.GetInt32(0));
  return result;
}

async Task<List<string>> WritableFieldsAsync(int writableOrganizationId)
{
  await using var command = new SqlCommand(
    "EXEC intranet.GetWritableSaopFields @OrganizationId, N'SAOP_PRODUCT';", connection);
  command.Parameters.AddWithValue("@OrganizationId", writableOrganizationId);
  await using var reader = await command.ExecuteReaderAsync();
  var result = new List<string>();
  while (await reader.ReadAsync()) result.Add(reader.GetString(reader.GetOrdinal("FieldKey")));
  return result;
}

async Task<string?> ScalarStringAsync(string sql)
{
  await using var command = new SqlCommand(sql, connection);
  var value = await command.ExecuteScalarAsync();
  return value is null or DBNull ? null : Convert.ToString(value);
}

Task<string?> StatusAsync(long messageId) =>
  ScalarStringAsync($"SELECT Status FROM out.OutboxMessage WHERE OutboxMessageId={messageId};");

Task<string?> LastErrorAsync(long messageId) =>
  ScalarStringAsync($"SELECT LastError FROM out.OutboxMessage WHERE OutboxMessageId={messageId};");

Task<string?> ErrorKindAsync(long messageId) =>
  ScalarStringAsync($"SELECT SaopErrorKind FROM out.OutboxMessage WHERE OutboxMessageId={messageId};");

async Task ExpectFailureAsync(Func<Task> action, string message)
{
  try { await action(); }
  catch (SqlException) { return; }
  throw new InvalidOperationException(message);
}

static void Equal<T>(T expected, T actual, string message)
{
  if (!EqualityComparer<T>.Default.Equals(expected, actual))
    throw new InvalidOperationException($"{message}\n  pričakovano: {expected}\n  dobljeno:    {actual}");
}

static string? ReadConnectionString()
{
  var fromEnvironment = Environment.GetEnvironmentVariable("PIM_CONNECTION_STRING");
  if (!string.IsNullOrWhiteSpace(fromEnvironment)) return fromEnvironment;
  foreach (var candidate in new[] { "appsettings.Local.json", "../../appsettings.Local.json", "../../../appsettings.Local.json" })
  {
    var path = Path.GetFullPath(candidate);
    if (!File.Exists(path)) continue;
    using var document = System.Text.Json.JsonDocument.Parse(File.ReadAllText(path));
    if (document.RootElement.TryGetProperty("ConnectionStrings", out var strings)
      && strings.TryGetProperty("Pim", out var pim)) return pim.GetString();
  }
  return null;
}

static int FreePort()
{
  var listener = new System.Net.Sockets.TcpListener(IPAddress.Loopback, 0);
  listener.Start();
  var port = ((IPEndPoint)listener.LocalEndpoint).Port;
  listener.Stop();
  return port;
}

/// <summary>
/// Lokalni strežnik, ki se predstavlja kot SAOP. Vrača resnične oblike odgovorov, prepisane iz
/// zapisov stare vrste — vključno s HTTP 409 in ovojem ArrayOfError.
/// </summary>
sealed class SaopFixture(int port)
{
  public sealed record Request(string Method, string Path, string? OrganisationId, string? Authorization, string? ContentType, string Body);

  public const string UpdateOk = "<?xml version=\"1.0\" encoding=\"utf-8\"?><UpdateResult><ResultCode>Ok</ResultCode><Errors /></UpdateResult>";
  public const string UpdateErrorInBody = "<?xml version=\"1.0\" encoding=\"utf-8\"?><UpdateResult><ResultCode>Error</ResultCode><Errors><Error><Level>ValidationError</Level><Message>Za naslednje artikle:  F8D-OBSTOJEC, skupina artikla ne obstaja v šifrantu!</Message></Error></Errors></UpdateResult>";
  public const string AlreadyExists = "<?xml version=\"1.0\" encoding=\"utf-8\"?><ArrayOfError><Error><Level>ValidationError</Level><Message>Zapis/zapisi za artikel/artikle :  F8D-NOV že obstaja/obstajajo!</Message></Error></ArrayOfError>";
  public const string CreatedWithCode = "<?xml version=\"1.0\" encoding=\"utf-8\"?><CreateResult><Keys><Key><Name>SifraArtikla</Name><Value>SAOP-DODELJENA</Value></Key></Keys><ResultCode>Created</ResultCode><Errors /></CreateResult>";

  readonly HttpListener listener = new();
  string body = UpdateOk;
  string? postBody;
  string? patchBody;
  CancellationTokenSource? cancellation;

  public Request? LastRequest { get; private set; }

  /// <summary>Koliko zahtev je fixture sprejel; s tem se dokaže, da nekaj NI bilo poslano.</summary>
  public int RequestCount { get; private set; }

  /// <summary>Kaj naj fixture odgovori na naslednjo zahtevo. ArrayOfError gre s HTTP 409, kot v resnici.</summary>
  public void Respond(string responseBody) { body = responseBody; postBody = null; patchBody = null; }

  /// <summary>Različen odgovor na POST in na PATCH — s tem se da preizkusiti popravek metode.</summary>
  public void RespondByMethod(string post, string patch) { postBody = post; patchBody = patch; }

  public void Start()
  {
    listener.Prefixes.Add($"http://127.0.0.1:{port}/");
    listener.Start();
    cancellation = new CancellationTokenSource();
    _ = Task.Run(async () =>
    {
      while (!cancellation.IsCancellationRequested)
      {
        HttpListenerContext context;
        try { context = await listener.GetContextAsync(); }
        catch (HttpListenerException) { return; }
        catch (ObjectDisposedException) { return; }

        using var reader = new StreamReader(context.Request.InputStream, Encoding.UTF8);
        RequestCount++;
        LastRequest = new(
          context.Request.HttpMethod,
          context.Request.Url?.AbsolutePath ?? string.Empty,
          context.Request.Headers["OrganisationId"],
          context.Request.Headers["Authorization"],
          context.Request.ContentType,
          await reader.ReadToEndAsync());

        var chosen = context.Request.HttpMethod switch
        {
          "POST" when postBody is not null => postBody,
          "PATCH" when patchBody is not null => patchBody,
          _ => body
        };
        var payload = Encoding.UTF8.GetBytes(chosen);
        context.Response.StatusCode = chosen.Contains("ArrayOfError", StringComparison.Ordinal) ? 409 : 200;
        context.Response.ContentType = "application/xml; charset=utf-8";
        context.Response.Headers["X-Correlation-ID"] = "f8d-fixture";
        await context.Response.OutputStream.WriteAsync(payload);
        context.Response.Close();
      }
    });
  }

  public void Stop()
  {
    cancellation?.Cancel();
    if (listener.IsListening) listener.Stop();
    listener.Close();
  }
}
