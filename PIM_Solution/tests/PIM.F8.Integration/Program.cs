using System.Net;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using PIM.Operations;
using PIM.Outbound;
using PIM.OutboxDispatcher;

const int organizationId = 9808;
var connectionString = ReadConnectionString();
if (string.IsNullOrWhiteSpace(connectionString)) { Console.Error.WriteLine("F8 MSSQL BLOCKED: lokalna PIM povezava ni na voljo."); return 2; }
var settings = new SqlConnectionStringBuilder(connectionString);
if (string.Equals(settings.InitialCatalog, "PIM_test", StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("F8 dokaz ne sme dostopati do PIM_test.");
if (!string.Equals(settings.InitialCatalog, "PIM", StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("F8 dokaz je dovoljen samo v razvojni bazi PIM.");

var port = FreePort();
using var fixture = new HttpListener(); fixture.Prefixes.Add($"http://127.0.0.1:{port}/"); fixture.Start();
var fixtureCalls = 0;
var server = Task.Run(async () =>
{
  while (fixtureCalls < 2)
  {
    var context=await fixture.GetContextAsync();
    if (context.Request.HttpMethod != "PATCH") throw new InvalidOperationException("Fixture pričakuje PATCH.");
    using var reader=new StreamReader(context.Request.InputStream);var body=await reader.ReadToEndAsync();
    if (!body.Contains("ERP_DESCRIPTION",StringComparison.Ordinal)) throw new InvalidOperationException("Fixture payload ni pogodben.");
    fixtureCalls++;context.Response.StatusCode=202;context.Response.Headers["X-Correlation-ID"]=$"f8-{fixtureCalls}";
    var bytes=System.Text.Encoding.UTF8.GetBytes("{\"token\":\"fixture-secret\",\"accepted\":true}");await context.Response.OutputStream.WriteAsync(bytes);context.Response.Close();
  }
});

await using var connection = new SqlConnection(connectionString); await connection.OpenAsync();
try
{
  await Sql("INSERT dbo.OrganizationConfig(OrganizationId,Name,SaopPrefix) VALUES(@Org,N'F8_ISOLATED',N'F8_ISOLATED');", ("@Org",organizationId));
  await Sql("INSERT dbo.IntegrationProfile(OrganizationId,TargetKind,EndpointTemplate,HttpOperation,ApprovalMode,IsEnabled,TimeoutSeconds,MaxAttempts,BaseRetrySeconds,UpdatedBy) VALUES(@Org,N'SAOP_PRODUCT',@Endpoint,N'PATCH',N'Automatic',1,5,3,1,N'F8_TEST');",("@Org",organizationId),("@Endpoint",$"http://127.0.0.1:{port}/products/A-1"));
  await Sql("INSERT out.OwnershipPolicy(OrganizationId,TargetKind,EntityType,FieldName,Owner,IsEnabled,UpdatedBy) VALUES(@Org,N'SAOP_PRODUCT',N'Product',N'ERP_DESCRIPTION',N'PIM',1,N'F8_TEST');",("@Org",organizationId));

  var payload="{\"entityKey\":\"A-1\",\"field\":\"ERP_DESCRIPTION\",\"value\":\"Fixture\"}";var hash=Hash(payload);
  var first=await Enqueue("A-1",payload,hash);var duplicate=await Enqueue("A-1",payload,hash);
  Equal(first,duplicate,"Aktivni dedup mora vrniti isto sporočilo.");
  await DispatchAndComplete(first,"worker-verified");
  Equal("Sent",await Status(first),"2xx ostane Sent");
  var expectedEcho=await PayloadHash(first);
  await Sql("DECLARE @Observed datetime2(3)=SYSUTCDATETIME(); EXEC out.VerifyEcho @Org,N'Product',N'A-1',@Hash,@Observed;",("@Org",organizationId),("@Hash",expectedEcho));
  Equal("Verified",await Status(first),"Ujemajoči echo");

  var retry=await Enqueue("A-2",payload.Replace("A-1","A-2"),Hash(payload.Replace("A-1","A-2")));await ClaimAndFail(retry,"worker-retry",false);
  Equal("Retry",await Status(retry),"Začasna napaka");
  await Sql("EXEC out.CancelMessage @Id,N'F8_TEST';",("@Id",retry));
  await Sql("UPDATE dbo.IntegrationProfile SET MaxAttempts=1 WHERE OrganizationId=@Org;",("@Org",organizationId));
  var dead=await Enqueue("A-3",payload.Replace("A-1","A-3"),Hash(payload.Replace("A-1","A-3")));await ClaimAndFail(dead,"worker-dead",false);
  Equal("Dead",await Status(dead),"Izčrpani poskusi");
  await Sql("UPDATE dbo.IntegrationProfile SET MaxAttempts=3 WHERE OrganizationId=@Org;",("@Org",organizationId));
  var drift=await Enqueue("A-4",payload.Replace("A-1","A-4"),Hash(payload.Replace("A-1","A-4")));await DispatchAndComplete(drift,"worker-drift");
  await Sql("DECLARE @Observed datetime2(3)=SYSUTCDATETIME(); EXEC out.VerifyEcho @Org,N'Product',N'A-4',@Hash,@Observed;",("@Org",organizationId),("@Hash",new string('0',64)));
  Equal("Drift",await Status(drift),"Neujemajoči echo");

  // ==========================================================================
  // Vrzel O18 — razred napake odloca o poskusih in o tem, koga obvestimo.
  // ==========================================================================

  // Poslovna zavrnitev: SAOP je zahtevo razumel in jo zavrnil. Ponoviti isto zahtevo pomeni
  // dobiti isti odgovor. Pred migracijo 046 je tak 400 pristal v Retry in porabil vse tri
  // poskuse; zdaj gre takoj v Dead in ohrani zapisan razlog.
  var business=await Enqueue("A-5",payload.Replace("A-1","A-5"),Hash(payload.Replace("A-1","A-5")));
  var claimedBusiness=await Claim("worker-business");
  Equal(business,claimedBusiness.Id,"Claim poslovne zavrnitve");
  await CompleteWithClass(business,"worker-business",false,400,"{\"error\":\"Sifra ne obstaja\"}","SAOP 400","Business");
  Equal("Dead",await Status(business),"Poslovna zavrnitev gre takoj v Dead");
  Equal("Business",await ErrorClass(business),"Razred napake mora biti zapisan");
  Equal(1,await AttemptCount(business),"Poslovna zavrnitev ne sme porabiti vec kot enega poskusa");

  // Napaka integracije: ni na tem artiklu, ampak na poverilnici ali naslovu. Kanal se ustavi
  // in nastane en sam alarm — sicer bi pri 200.000 artiklih nastalo 200.000 enakih alarmov.
  var auth=await Enqueue("A-6",payload.Replace("A-1","A-6"),Hash(payload.Replace("A-1","A-6")));
  var claimedAuth=await Claim("worker-auth");
  Equal(auth,claimedAuth.Id,"Claim napake avtentikacije");
  await CompleteWithClass(auth,"worker-auth",false,401,"{\"error\":\"Unauthorized\"}","SAOP 401","AuthConfig");
  Equal("Dead",await Status(auth),"Napaka avtentikacije gre v Dead");
  Equal("AuthConfig",await ErrorClass(auth),"Razred napake mora biti AuthConfig");
  Equal(0,await ScalarInt("SELECT CONVERT(int,IsEnabled) FROM dbo.IntegrationProfile WHERE OrganizationId=@Org;"),
    "AuthConfig mora ustaviti kanal");
  Equal(1,await ScalarInt("SELECT COUNT(*) FROM ops.Alert WHERE OrganizationId=@Org AND AlertKind=N'OUTBOUND_AUTH' AND ResolvedUtc IS NULL;"),
    "AuthConfig mora sprozit natanko en alarm na integracijo");

  // Kanal odpre clovek; test si ga vrne, da lahko nadaljuje.
  await Sql("UPDATE dbo.IntegrationProfile SET IsEnabled=1 WHERE OrganizationId=@Org;",("@Org",organizationId));

  // ==========================================================================
  // Vrzel O16 — nadomesceno sporocilo ni nepotrjeno sporocilo.
  // ==========================================================================

  await Sql("INSERT out.OwnershipPolicy(OrganizationId,TargetKind,EntityType,FieldName,Owner,IsEnabled,UpdatedBy) VALUES(@Org,N'SAOP_PRODUCT',N'Product',N'ERP_NAME',N'PIM',1,N'F8_TEST');",("@Org",organizationId));

  // Drugo polje istega izdelka: nadomestitev se ga ne sme dotakniti.
  var otherField=await Enqueue("A-7","{\"entityKey\":\"A-7\",\"field\":\"ERP_NAME\",\"value\":\"Ime\"}",string.Empty);
  var claimedOther=await Claim("worker-other");
  Equal(otherField,claimedOther.Id,"Claim drugega polja");
  await Complete(claimedOther.Id,"worker-other",true,false,202,"{}",null,null);
  Equal("Sent",await Status(otherField),"Drugo polje je poslano");

  var first7=await Enqueue("A-7","{\"entityKey\":\"A-7\",\"field\":\"ERP_DESCRIPTION\",\"value\":\"Prva\"}",string.Empty);
  var claimed7=await Claim("worker-super");
  Equal(first7,claimed7.Id,"Claim prvega opisa");
  await Complete(claimed7.Id,"worker-super",true,false,202,"{}",null,null);
  Equal("Sent",await Status(first7),"Prvi opis je poslan in caka echo");

  var second7=await Enqueue("A-7","{\"entityKey\":\"A-7\",\"field\":\"ERP_DESCRIPTION\",\"value\":\"Druga\"}",string.Empty);
  Equal("Superseded",await Status(first7),"Starejse sporocilo za isto polje mora postati Superseded");
  Equal("Pending",await Status(second7),"Novejse sporocilo caka na posiljanje");
  Equal("Sent",await Status(otherField),"Nadomestitev ne sme poseci v drugo polje istega izdelka");

  // ==========================================================================
  // Vrzel O19 — uskladitev nove sifre ne sme sloneti samo na EAN.
  // ==========================================================================

  const string sharedEan="3830099900001";
  await Sql("INSERT canon.Product(OrganizationId,ItemID,EAN,BusinessHash) VALUES(@Org,N'F8-EAN-A',@Ean,NULL),(@Org,N'F8-EAN-B',@Ean,NULL);",
    ("@Org",organizationId),("@Ean",sharedEan));

  Equal("Response",await Resolve(second7,"SAOP-77","REQ-1",sharedEan),"Odgovor SAOP prevlada");
  Equal("SAOP-77",await AssignedItemId(second7),"Dodeljena je sifra iz odgovora");
  Equal("RequestedIdentifier",await Resolve(second7,null,"REQ-1",sharedEan),"Brez odgovora obvelja zahtevana sifra");
  Equal("Unresolved",await Resolve(second7,null,null,sharedEan),"Dvoumen EAN ni ujemanje");
  Equal(null,await AssignedItemId(second7),"Dvoumen EAN ne sme dodeliti sifre");

  await Sql("DELETE FROM canon.Product WHERE OrganizationId=@Org AND ItemID=N'F8-EAN-B';",("@Org",organizationId));
  Equal("EAN",await Resolve(second7,null,null,sharedEan),"Enolicen EAN je ujemanje");
  Equal("F8-EAN-A",await AssignedItemId(second7),"Dodeli se sifra edinega ujemajocega artikla");

  var policy=new OwnershipPolicy([new("Product","ERP_DESCRIPTION",Ownership.Pim)]);var builder=new OutboundPayloadBuilder(policy);
  try { builder.Build(new("SAOP_PRODUCT","PATCH","Product","A-1","VAT","22"));throw new InvalidOperationException("VAT ni bil zavrnjen."); } catch(OwnershipViolationException) { }
  await server;
  Equal(2,fixtureCalls,"Lokalni fixture klici");

  // ==========================================================================
  // Vrzel C1 — dispatcher: razpored pred prevzemom in zanka cez cakalno vrsto.
  //
  // Doslej PIM.OutboxDispatcher\Program.cs ni pokrival noben test: F8.DispatcherTests
  // preizkusa SaopOutboundHandler, ta datoteka in F8.HardeningTests pa klicejo procedure
  // neposredno. Zato se ni videlo dvoje:
  //
  //   1. ops.BeginRun vrze 51100, ce za par (organizacija, OUTBOUND) ni omogocenega
  //      razporeda. Program.cs je klical out.ClaimMessage PRED BeginRun, zato je sporocilo
  //      ze bilo prevzeto, ko je zagon umrl: poskus je bil porabljen, zahteva pa nikoli
  //      poslana. Ob dovolj ponovitvah bi sporocilo umrlo od poskusov, ki se niso zgodili.
  //   2. Zagon je obdelal natanko eno sporocilo in koncal. Cakalna vrsta se ni praznila.
  //
  // Posiljanje je tu nadomesceno z lokalnim odgovorom: predmet tega dokaza je vrstni red
  // in zanka, ne HTTP — tega pokrivata F8.DispatcherTests in fixture zgoraj.
  // ==========================================================================

  // Cakalna vrsta mora biti prazna, da test nadzoruje, kaj je v njej. second7 je iz vrzeli
  // O16 ostal Pending; preklicemo ga, ker je svojo trditev ze dokazal.
  await Sql("EXEC out.CancelMessage @Id,N'F8_TEST';",("@Id",second7));

  var dispatched=new List<long>();
  var poisoned=new HashSet<long>();
  Task<DispatchResult> Send(ClaimedOutboxMessage message,CancellationToken _)
  {
    dispatched.Add(message.OutboxMessageId);
    // Natanko izjema, ki jo vrze SaopOutboundHandler.CreateRequest ob nepodprti metodi.
    if(poisoned.Contains(message.OutboxMessageId)) throw new InvalidOperationException("Dispatcher dovoljuje samo HTTP POST in PATCH.");
    return Task.FromResult(new DispatchResult(DispatchOutcome.Sent,202,"{\"accepted\":true}","runner-echo"));
  }
  var runner=new OutboxDispatchRunner(connectionString!,"worker-runner",Send,maxMessages:8);

  // --- 1) Brez razporeda: zagon ne sme prevzeti nicesar ----------------------
  var stranded=await Enqueue("A-8","{\"entityKey\":\"A-8\",\"field\":\"ERP_DESCRIPTION\",\"value\":\"Brez razporeda\"}",string.Empty);
  var withoutSchedule=await runner.RunAsync();
  Equal(true,withoutSchedule.ScheduleMissing,"Manjkajoc razpored mora biti izid zagona, ne izjema");
  Equal(0,withoutSchedule.Claimed,"Brez razporeda dispatcher ne sme prevzeti sporocila");
  Equal(0,dispatched.Count,"Brez razporeda ne sme biti odhodne zahteve");
  Equal("Pending",await Status(stranded),"Sporocilo mora ostati Pending, ne obviseti v Sending");
  Equal(0,await AttemptCount(stranded),"Poskus, ki se ni zgodil, se ne sme steti");

  // --- 2) Z razporedom: en zagon izprazni cakalno vrsto ----------------------
  await Sql(@"INSERT ops.ScheduleProfile(OrganizationId,Provider,Pipeline,IsEnabled,IntervalSeconds,StaleAfterSeconds,LockTimeoutMilliseconds,UpdatedBy)
    VALUES(@Org,N'Fixture',N'OUTBOUND',1,60,600,5000,N'F8_TEST');",("@Org",organizationId));

  var alsoQueued=await Enqueue("A-9","{\"entityKey\":\"A-9\",\"field\":\"ERP_DESCRIPTION\",\"value\":\"Druga v vrsti\"}",string.Empty);
  var withSchedule=await runner.RunAsync();
  Equal(false,withSchedule.ScheduleMissing,"Z razporedom zagon ni preskocen");
  Equal(2,withSchedule.Claimed,"En zagon mora obdelati vso cakalno vrsto, ne enega sporocila");
  Equal(2,withSchedule.Sent,"Obe sporocili sta poslani");
  Equal(0,withSchedule.Failed,"Nobeno ni padlo");
  Equal(2,dispatched.Count,"Dve odhodni zahtevi");
  Equal("Sent",await Status(stranded),"Prvo sporocilo je poslano");
  Equal("Sent",await Status(alsoQueued),"Drugo sporocilo je poslano v istem zagonu");
  Equal(1,await AttemptCount(stranded),"Vsako sporocilo porabi natanko en poskus");

  // --- 3) Prazna cakalna vrsta ni napaka -------------------------------------
  var empty=await runner.RunAsync();
  Equal(0,empty.Claimed,"Prazna cakalna vrsta ne prevzame nicesar");
  Equal(false,empty.ScheduleMissing,"Prazna vrsta ni manjkajoc razpored");
  Equal("Healthy",await ScalarString("SELECT Status FROM ops.IntegrationHealth WHERE OrganizationId=@Org AND Pipeline=N'OUTBOUND';"),
    "Zagon mora zapreti ops.IntegrationHealth kot Healthy");

  // --- 4) Pokvarjeno sporocilo ne sme zapreti vrste ---------------------------
  //
  // out.ClaimMessage bere vrsto po OutboxMessageId. Dokler je lovljena samo omrezna izjema,
  // eno sporocilo s pokvarjeno nastavitvijo ob vsakem zagonu vrze na istem mestu in nobeno
  // sporocilo za njim ne pride nikoli na vrsto.
  var poison=await Enqueue("B-1","{\"entityKey\":\"B-1\",\"field\":\"ERP_DESCRIPTION\",\"value\":\"Pokvarjen profil\"}",string.Empty);
  poisoned.Add(poison);
  var behind=await Enqueue("B-2","{\"entityKey\":\"B-2\",\"field\":\"ERP_DESCRIPTION\",\"value\":\"Za pokvarjenim\"}",string.Empty);
  var mixed=await runner.RunAsync();
  Equal(2,mixed.Claimed,"Zagon se ne sme ustaviti na pokvarjenem sporocilu");
  Equal(1,mixed.Sent,"Sporocilo za pokvarjenim mora iti skozi");
  Equal(1,mixed.Failed,"Pokvarjeno sporocilo se steje kot neuspeh");
  Equal("Retry",await Status(poison),"Pokvarjeno sporocilo gre v Retry, ne obvisi v Sending");
  Equal("Sent",await Status(behind),"Vrsta se ne sme zapreti za pokvarjenim sporocilom");
  Equal(true,(await LastError(poison))?.Contains("InvalidOperationException",StringComparison.Ordinal),
    "Zapisana mora biti vrsta izjeme");
  Equal(false,(await LastError(poison))?.Contains("POST",StringComparison.Ordinal),
    "Sporocilo izjeme ne sme v bazo - lahko nosi naslov s poverilnico");
  await Sql("EXEC out.CancelMessage @Id,N'F8_TEST';",("@Id",poison));

  // --- 5) Meja sporocil na zagon ni tiha -------------------------------------
  var capped=new OutboxDispatchRunner(connectionString!,"worker-capped",Send,maxMessages:1);
  var firstOfTwo=await Enqueue("B-3","{\"entityKey\":\"B-3\",\"field\":\"ERP_DESCRIPTION\",\"value\":\"Prvo\"}",string.Empty);
  var secondOfTwo=await Enqueue("B-4","{\"entityKey\":\"B-4\",\"field\":\"ERP_DESCRIPTION\",\"value\":\"Drugo\"}",string.Empty);
  var truncated=await capped.RunAsync();
  Equal(1,truncated.Claimed,"Meja mora ustaviti zagon");
  Equal(true,truncated.Truncated,"Odrezana vrsta se mora povedati, ne izgledati kot prazna");
  Equal("Sent",await Status(firstOfTwo),"Prvo je poslano");
  Equal("Pending",await Status(secondOfTwo),"Drugo caka na naslednji zagon");
  Equal(1,(await capped.RunAsync()).Sent,"Naslednji zagon pobere ostanek");
  Equal("Sent",await Status(secondOfTwo),"Ostanek gre skozi");

  // --- 6) Prekrivanje s samim sabo ni napaka ---------------------------------
  //
  // ops.BeginRun vrze 51101, kadar isto izvajanje ze tece. Nacrtovan worker se sam s sabo
  // redno prekriva; drugi zagon se mora umakniti, ne koncati z neobravnavano izjemo.
  await using (await OperationsRun.BeginAsync(connectionString!,organizationId,OutboxDispatchRunner.Pipeline,"worker-prvi"))
  {
    var blocked=await Enqueue("B-5","{\"entityKey\":\"B-5\",\"field\":\"ERP_DESCRIPTION\",\"value\":\"Med prekrivanjem\"}",string.Empty);
    var overlapped=await runner.RunAsync();
    Equal(true,overlapped.AlreadyRunning,"Prekrivanje mora biti izid, ne izjema");
    Equal(0,overlapped.Claimed,"Umaknjeni zagon ne sme prevzeti sporocila");
    Equal("Pending",await Status(blocked),"Sporocilo pocaka na prvi zagon");
    await Sql("EXEC out.CancelMessage @Id,N'F8_TEST';",("@Id",blocked));
  }
  Console.WriteLine("F8 integration: PIM MSSQL isolated org 9808, dedup/retry/dead/sent/verified/drift, razred napake, nadomestitev, uskladitev sifre, dispatcher (razpored pred prevzemom + zanka) in lokalni HTTP fixture PASS.");
}
finally
{
  fixture.Stop();
  // Test brise izkljucno vrstice, ki jih je ustvaril sam, v svojem izoliranem podjetju 9808.
  // Vrstni red sledi tujim kljucem: dodeljene sifre in poskusi pred sporocili, dostave pred alarmi.
  await Sql(@"DELETE FROM out.SaopItemAssignment WHERE OrganizationId=@Org;
    DELETE attempt FROM out.OutboxAttempt attempt INNER JOIN out.OutboxMessage message ON message.OutboxMessageId=attempt.OutboxMessageId WHERE message.OrganizationId=@Org;
    DELETE out.OutboxMessage WHERE OrganizationId=@Org;
    DELETE out.OwnershipPolicy WHERE OrganizationId=@Org;
    DELETE delivery FROM ops.AlertDelivery delivery INNER JOIN ops.Alert alert ON alert.AlertId=delivery.AlertId WHERE alert.OrganizationId=@Org;
    DELETE ops.Alert WHERE OrganizationId=@Org;
    DELETE ops.IntegrationHealth WHERE OrganizationId=@Org;
    DELETE ops.ScheduleProfile WHERE OrganizationId=@Org;
    DELETE FROM canon.Product WHERE OrganizationId=@Org;
    DELETE dbo.IntegrationProfile WHERE OrganizationId=@Org;
    DELETE dbo.OrganizationConfig WHERE OrganizationId=@Org;",("@Org",organizationId));
}
return 0;

async Task<long> Enqueue(string key,string payload,string hash)
{
  await using var command=new SqlCommand("DECLARE @Id bigint; EXEC out.EnqueueMessage @OrganizationId=@Org,@TargetKind=N'SAOP_PRODUCT',@Operation=N'UPDATE',@EntityType=N'Product',@PayloadJson=@Payload,@Actor=N'F8_TEST',@OutboxMessageId=@Id OUTPUT; SELECT @Id;",connection);
  command.Parameters.AddWithValue("@Org",organizationId);command.Parameters.AddWithValue("@Payload",payload);return Convert.ToInt64(await command.ExecuteScalarAsync());
}
async Task DispatchAndComplete(long expected,string worker)
{
  var claimed=await Claim(worker);Equal(expected,claimed.Id,"Claim vrstni red");using var http=new HttpClient{Timeout=TimeSpan.FromSeconds(5)};var result=await new SaopOutboundHandler(http).SendAsync(new(new Uri(claimed.Endpoint),claimed.Operation,claimed.Payload),CancellationToken.None);
  Equal(false,result.RedactedBody.Contains("fixture-secret",StringComparison.Ordinal),"Redakcija");await Complete(claimed.Id,worker,true,false,result.StatusCode,result.RedactedBody,result.CorrelationId,null);
}
async Task ClaimAndFail(long expected,string worker,bool permanent) { var claimed=await Claim(worker);Equal(expected,claimed.Id,"Claim napake");await Complete(claimed.Id,worker,false,permanent,503,"fixture unavailable",null,"fixture 503"); }
async Task<(long Id,string Payload,string Endpoint,string Operation)> Claim(string worker)
{
  await using var command=new SqlCommand("EXEC out.ClaimMessage @WorkerId;",connection);command.Parameters.AddWithValue("@WorkerId",worker);await using var reader=await command.ExecuteReaderAsync();if(!await reader.ReadAsync())throw new InvalidOperationException("Ni claim sporočila.");var row=(reader.GetInt64(reader.GetOrdinal("OutboxMessageId")),reader.GetString(reader.GetOrdinal("PayloadJson")),reader.GetString(reader.GetOrdinal("EndpointTemplate")),reader.GetString(reader.GetOrdinal("HttpOperation")));await reader.CloseAsync();return row;
}
async Task Complete(long id,string worker,bool success,bool permanent,int code,string body,string? correlation,string? failure) => await Sql("EXEC out.CompleteAttempt @Id,@Worker,@Success,@Permanent,@Code,@Body,@Correlation,@Failure;",("@Id",id),("@Worker",worker),("@Success",success),("@Permanent",permanent),("@Code",code),("@Body",body),("@Correlation",(object?)correlation??DBNull.Value),("@Failure",(object?)failure??DBNull.Value));
async Task CompleteWithClass(long id,string worker,bool success,int code,string body,string? failure,string errorClass) =>
  await Sql("EXEC out.CompleteAttempt @OutboxMessageId=@Id,@WorkerId=@Worker,@Succeeded=@Success,@PermanentFailure=0,@ResponseStatusCode=@Code,@ResponseBodyRedacted=@Body,@ResponseCorrelationId=NULL,@FailureReason=@Failure,@ErrorClass=@Class;",
    ("@Id",id),("@Worker",worker),("@Success",success),("@Code",code),("@Body",body),("@Failure",(object?)failure??DBNull.Value),("@Class",errorClass));
async Task<string?> ErrorClass(long id) { await using var command=new SqlCommand("SELECT ErrorClass FROM out.OutboxMessage WHERE OutboxMessageId=@Id;",connection);command.Parameters.AddWithValue("@Id",id);var value=await command.ExecuteScalarAsync();return value is DBNull or null?null:Convert.ToString(value); }
async Task<string?> LastError(long id) { await using var command=new SqlCommand("SELECT LastError FROM out.OutboxMessage WHERE OutboxMessageId=@Id;",connection);command.Parameters.AddWithValue("@Id",id);var value=await command.ExecuteScalarAsync();return value is DBNull or null?null:Convert.ToString(value); }
async Task<int> AttemptCount(long id) { await using var command=new SqlCommand("SELECT AttemptCount FROM out.OutboxMessage WHERE OutboxMessageId=@Id;",connection);command.Parameters.AddWithValue("@Id",id);return Convert.ToInt32(await command.ExecuteScalarAsync()); }
async Task<string?> ScalarString(string sql) { await using var command=new SqlCommand(sql,connection);command.Parameters.AddWithValue("@Org",organizationId);var value=await command.ExecuteScalarAsync();return value is DBNull or null?null:Convert.ToString(value); }
async Task<int> ScalarInt(string sql) { await using var command=new SqlCommand(sql,connection);command.Parameters.AddWithValue("@Org",organizationId);var value=await command.ExecuteScalarAsync();return value is DBNull or null?0:Convert.ToInt32(value); }
async Task<string> Resolve(long id,string? response,string? requested,string? ean)
{
  await using var command=new SqlCommand("DECLARE @Method nvarchar(40),@Assigned nvarchar(200); EXEC out.ResolveSaopItemAssignment @OutboxMessageId=@Id,@ResponseItemId=@Response,@RequestedIdentifier=@Requested,@EAN=@Ean,@Actor=N'F8_TEST',@MatchMethod=@Method OUTPUT,@AssignedSaopItemId=@Assigned OUTPUT; SELECT @Method;",connection);
  command.Parameters.AddWithValue("@Id",id);command.Parameters.AddWithValue("@Response",(object?)response??DBNull.Value);
  command.Parameters.AddWithValue("@Requested",(object?)requested??DBNull.Value);command.Parameters.AddWithValue("@Ean",(object?)ean??DBNull.Value);
  return Convert.ToString(await command.ExecuteScalarAsync())!;
}
async Task<string?> AssignedItemId(long id) { await using var command=new SqlCommand("SELECT AssignedSaopItemId FROM out.SaopItemAssignment WHERE OutboxMessageId=@Id;",connection);command.Parameters.AddWithValue("@Id",id);var value=await command.ExecuteScalarAsync();return value is DBNull or null?null:Convert.ToString(value); }
async Task<string> Status(long id) { await using var command=new SqlCommand("SELECT Status FROM out.OutboxMessage WHERE OutboxMessageId=@Id;",connection);command.Parameters.AddWithValue("@Id",id);return Convert.ToString(await command.ExecuteScalarAsync())!; }
async Task<string> PayloadHash(long id) { await using var command=new SqlCommand("SELECT PayloadHash FROM out.OutboxMessage WHERE OutboxMessageId=@Id;",connection);command.Parameters.AddWithValue("@Id",id);return Convert.ToString(await command.ExecuteScalarAsync())!; }
async Task Sql(string sql,params (string Name,object Value)[] parameters) { await using var command=new SqlCommand(sql,connection);foreach(var parameter in parameters)command.Parameters.AddWithValue(parameter.Name,parameter.Value);await command.ExecuteNonQueryAsync(); }
static string Hash(string value)=>Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(value))).ToLowerInvariant();
static void Equal<T>(T expected,T actual,string message) { if(!EqualityComparer<T>.Default.Equals(expected,actual))throw new InvalidOperationException($"{message}: {expected} != {actual}"); }
static int FreePort(){var listener=new System.Net.Sockets.TcpListener(IPAddress.Loopback,0);listener.Start();var port=((IPEndPoint)listener.LocalEndpoint).Port;listener.Stop();return port;}
static string? ReadConnectionString(){var env=Environment.GetEnvironmentVariable("PIM_F8_TEST_CONNECTION_STRING")??Environment.GetEnvironmentVariable("PIM_CONNECTION_STRING");if(!string.IsNullOrWhiteSpace(env))return env;var path=Path.Combine(Directory.GetCurrentDirectory(),"appsettings.Local.json");if(!File.Exists(path))return null;using var json=JsonDocument.Parse(File.ReadAllText(path));return json.RootElement.GetProperty("ConnectionStrings").GetProperty("Pim").GetString();}
