using System.Net;
using System.Text.Json;
using Microsoft.Data.SqlClient;
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

  var policy=new OwnershipPolicy([new("Product","ERP_DESCRIPTION",Ownership.Pim)]);var builder=new OutboundPayloadBuilder(policy);
  try { builder.Build(new("SAOP_PRODUCT","PATCH","Product","A-1","VAT","22"));throw new InvalidOperationException("VAT ni bil zavrnjen."); } catch(OwnershipViolationException) { }
  await server;
  Equal(2,fixtureCalls,"Lokalni fixture klici");
  Console.WriteLine("F8 integration: PIM MSSQL isolated org 9808, dedup/retry/dead/sent/verified/drift in lokalni HTTP fixture PASS.");
}
finally
{
  fixture.Stop();
  await Sql("DELETE attempt FROM out.OutboxAttempt attempt INNER JOIN out.OutboxMessage message ON message.OutboxMessageId=attempt.OutboxMessageId WHERE message.OrganizationId=@Org; DELETE out.OutboxMessage WHERE OrganizationId=@Org; DELETE out.OwnershipPolicy WHERE OrganizationId=@Org; DELETE dbo.IntegrationProfile WHERE OrganizationId=@Org; DELETE dbo.OrganizationConfig WHERE OrganizationId=@Org;",("@Org",organizationId));
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
async Task<string> Status(long id) { await using var command=new SqlCommand("SELECT Status FROM out.OutboxMessage WHERE OutboxMessageId=@Id;",connection);command.Parameters.AddWithValue("@Id",id);return Convert.ToString(await command.ExecuteScalarAsync())!; }
async Task<string> PayloadHash(long id) { await using var command=new SqlCommand("SELECT PayloadHash FROM out.OutboxMessage WHERE OutboxMessageId=@Id;",connection);command.Parameters.AddWithValue("@Id",id);return Convert.ToString(await command.ExecuteScalarAsync())!; }
async Task Sql(string sql,params (string Name,object Value)[] parameters) { await using var command=new SqlCommand(sql,connection);foreach(var parameter in parameters)command.Parameters.AddWithValue(parameter.Name,parameter.Value);await command.ExecuteNonQueryAsync(); }
static string Hash(string value)=>Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(value))).ToLowerInvariant();
static void Equal<T>(T expected,T actual,string message) { if(!EqualityComparer<T>.Default.Equals(expected,actual))throw new InvalidOperationException($"{message}: {expected} != {actual}"); }
static int FreePort(){var listener=new System.Net.Sockets.TcpListener(IPAddress.Loopback,0);listener.Start();var port=((IPEndPoint)listener.LocalEndpoint).Port;listener.Stop();return port;}
static string? ReadConnectionString(){var env=Environment.GetEnvironmentVariable("PIM_F8_TEST_CONNECTION_STRING")??Environment.GetEnvironmentVariable("PIM_CONNECTION_STRING");if(!string.IsNullOrWhiteSpace(env))return env;var path=Path.Combine(Directory.GetCurrentDirectory(),"appsettings.Local.json");if(!File.Exists(path))return null;using var json=JsonDocument.Parse(File.ReadAllText(path));return json.RootElement.GetProperty("ConnectionStrings").GetProperty("Pim").GetString();}
