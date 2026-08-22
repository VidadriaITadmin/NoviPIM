using System.Text.Json;
using Microsoft.Data.SqlClient;

const int organizationId = 9813;
var connectionString = ReadConnectionString();
// Brez nastavljene povezave se test preskoci, ne pade. Padec je pomenil, da je paket na
// racunalniku brez razvojne baze videti pokvarjen, ceprav ni, in da CI ni mogel poganjati
// testov. Preskoci se SAMO, kadar povezave ni nikjer; kjer je nastavljena, dokaz tece kot prej.
if (string.IsNullOrWhiteSpace(connectionString)) { Console.WriteLine("F8 utrjevanje preskoceno: lokalna PIM povezava ni na voljo."); return 0; }
var settings = new SqlConnectionStringBuilder(connectionString);
if (string.Equals(settings.InitialCatalog, "PIM_test", StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("F8 hardening test ne sme dostopati do PIM_test.");
if (!string.Equals(settings.InitialCatalog, "PIM", StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("F8 hardening test je dovoljen samo v razvojni bazi PIM.");

await using var connection = new SqlConnection(connectionString);
await connection.OpenAsync();
try
{
  await Sql("INSERT dbo.OrganizationConfig(OrganizationId,Name,SaopPrefix) VALUES(@Org,N'F8_HARDENING',N'F8_HARDENING');", ("@Org", organizationId));
  await Sql("INSERT dbo.IntegrationProfile(OrganizationId,TargetKind,EndpointTemplate,HttpOperation,ApprovalMode,IsEnabled,TimeoutSeconds,MaxAttempts,BaseRetrySeconds,UpdatedBy) VALUES(@Org,N'SAOP_PRODUCT',N'http://127.0.0.1:1/fixture',N'PATCH',N'Automatic',1,300,3,1,N'F8_HARDENING');", ("@Org", organizationId));
  await Sql("INSERT out.OwnershipPolicy(OrganizationId,TargetKind,EntityType,FieldName,Owner,IsEnabled,UpdatedBy) VALUES(@Org,N'SAOP_PRODUCT',N'Product',N'ERP_DESCRIPTION',N'PIM',1,N'F8_HARDENING');", ("@Org", organizationId));
  await Sql("INSERT out.OwnershipPolicy(OrganizationId,TargetKind,EntityType,FieldName,Owner,ConstraintKind,ConstraintValue,IsEnabled,UpdatedBy) VALUES(@Org,N'SAOP_PRODUCT',N'Product',N'PLANNING_EXCLUDED',N'PIM',N'ExactValue',N'0',1,N'F8_HARDENING');", ("@Org", organizationId));

  var first = await Enqueue("A-1", "ERP_DESCRIPTION", "Fixture");
  var stored = await Row(first);
  Equal("A-1", stored.EntityKey, "EntityKey mora izhajati iz payload-a");
  Equal("ERP_DESCRIPTION", stored.FieldSummary, "FieldSummary mora izhajati iz payload-a");
  Equal("{\"entityKey\":\"A-1\",\"field\":\"ERP_DESCRIPTION\",\"value\":\"Fixture\"}", stored.Payload, "Payload mora biti kanoničen strežniški zapis");
  Equal(await SqlScalar<string>("SELECT CONVERT(char(64),HASHBYTES('SHA2_256',CONVERT(varbinary(max),PayloadJson)),2) FROM out.OutboxMessage WHERE OutboxMessageId=@Id;", ("@Id", first)), stored.PayloadHash, "PayloadHash mora izračunati strežnik");
  Equal(stored.PayloadHash, stored.ExpectedEchoHash, "ExpectedEchoHash mora izračunati strežnik");
  Equal(stored.PayloadHash, stored.DedupKey, "DedupKey mora izračunati strežnik");
  Equal(first, await Enqueue("A-1", "ERP_DESCRIPTION", "Fixture"), "Kanonični dedup vrne isto sporočilo");
  await ExpectFailure("EXEC out.EnqueueMessage @OrganizationId=@Org,@TargetKind=N'SAOP_PRODUCT',@Operation=N'UPDATE',@EntityType=N'Product',@PayloadJson=N'{\"entityKey\":\"A-2\",\"field\":\"VAT\",\"value\":\"22\"}',@Actor=N'F8_HARDENING',@OutboxMessageId=@Id OUTPUT;", "Ne-lastniško polje mora mejnik zavrniti");
  await ExpectFailure("EXEC out.EnqueueMessage @OrganizationId=@Org,@TargetKind=N'SAOP_PRODUCT',@Operation=N'UPDATE',@EntityType=N'Product',@PayloadJson=N'{\"entityKey\":\"A-2\",\"field\":\"ERP_DESCRIPTION\",\"value\":\"Fixture\",\"injected\":true}',@Actor=N'F8_HARDENING',@OutboxMessageId=@Id OUTPUT;", "Dodatno payload polje mora mejnik zavrniti");
  await ExpectFailure("EXEC out.EnqueueMessage @OrganizationId=@Org,@TargetKind=N'SAOP_PRODUCT',@Operation=N'UPDATE',@EntityType=N'Product',@PayloadJson=N'{\"entityKey\":\"A-2\",\"field\":\"PLANNING_EXCLUDED\",\"value\":\"1\"}',@Actor=N'F8_HARDENING',@OutboxMessageId=@Id OUTPUT;", "ExactValue policy mora mejnik zavrniti");
  Equal(first, await Claim("first-worker"), "Prvi worker prevzame prvo sporočilo");
  await Complete(first, "first-worker", true);

  var late = await Enqueue("A-late", "ERP_DESCRIPTION", "late");
  await Claim("late-worker");
  await Sql("UPDATE out.OutboxMessage SET LeaseUntilUtc=DATEADD(second,-1,SYSUTCDATETIME()) WHERE OutboxMessageId=@Id;", ("@Id", late));
  await Complete(late, "late-worker", true);
  Equal("Sent", await Status(late), "Veljaven lastnik lahko zaključi odziv po poteku lease-a pred reclaimom");

  var crashed = await Enqueue("A-crash", "ERP_DESCRIPTION", "crash");
  Equal(crashed, await Claim("crashed-worker"), "Prvi worker prevzame crash sporočilo");
  await Sql("UPDATE out.OutboxMessage SET LeaseUntilUtc=DATEADD(second,-1,SYSUTCDATETIME()) WHERE OutboxMessageId=@Id;", ("@Id", crashed));
  Equal(crashed, await Claim("recovery-worker"), "Reclaimer atomsko prevzame potekli Sending lease");
  Equal(2, await SqlScalar<int>("SELECT AttemptCount FROM out.OutboxMessage WHERE OutboxMessageId=@Id;", ("@Id", crashed)), "Reclaim odpre nov poskus");
  Equal("Retry", await SqlScalar<string>("SELECT Outcome FROM out.OutboxAttempt WHERE OutboxMessageId=@Id AND AttemptNumber=1;", ("@Id", crashed)), "Crash poskus je zaprt kot Retry");
  await ExpectFailure("EXEC out.CompleteAttempt @OutboxMessageId=@Id,@WorkerId=N'crashed-worker',@Succeeded=1,@PermanentFailure=0;", "Stari worker po reclaimu ne sme zaključiti novega poskusa", ("@Id", crashed));
  await Complete(crashed, "recovery-worker", true);

  var concurrent = await Enqueue("A-concurrent", "ERP_DESCRIPTION", "concurrent");
  Equal(concurrent, await Claim("initial-worker"), "Začetni worker prevzame concurrent sporočilo");
  await Sql("UPDATE out.OutboxMessage SET LeaseUntilUtc=DATEADD(second,-1,SYSUTCDATETIME()) WHERE OutboxMessageId=@Id;", ("@Id", concurrent));
  var recovered = await Task.WhenAll(ClaimSeparate("concurrent-a"), ClaimSeparate("concurrent-b"));
  Equal(1, recovered.Count(id => id == concurrent), "Natanko en concurrent worker prevzame potekli lease");
  Equal(1, recovered.Count(id => id is null), "Drugi concurrent worker ne dobi istega sporočila");
  var winner = recovered[0] == concurrent ? "concurrent-a" : "concurrent-b";
  await Complete(concurrent, winner, true);

  var olderEcho = await Enqueue("A-echo", "ERP_DESCRIPTION", "old");
  Equal(olderEcho, await Claim("echo-old-worker"), "Starejši echo worker prevzame sporočilo");
  await Complete(olderEcho, "echo-old-worker", true);
  var newerEcho = await Enqueue("A-echo", "ERP_DESCRIPTION", "new");
  Equal(newerEcho, await Claim("echo-new-worker"), "Novejši echo worker prevzame sporočilo");
  await Complete(newerEcho, "echo-new-worker", true);
  var newestHash = await PayloadHash(newerEcho);
  await Sql("DECLARE @Observed datetime2(3)=SYSUTCDATETIME(); EXEC out.VerifyEcho @OrganizationId=@Org,@EntityType=N'Product',@EntityKey=N'A-echo',@InboundHash=@Hash,@ObservedUtc=@Observed;", ("@Org", organizationId), ("@Hash", newestHash));
  // Namen te trditve je nespremenjen: echo novejše spremembe ne sme starejše označiti kot Drift.
  // Spremenil se je odgovor. Do migracije 046 je bil pravilni odgovor "Sent", ker drugega
  // stanja ni bilo — a to je pomenilo sporočilo, ki za vedno izgleda kot poslano in nepotrjeno.
  // Vrzel O16 doda stanje Superseded: starejše sporočilo za isto polje ni nepotrjeno, ampak
  // nadomeščeno. Zato je tu zdaj Superseded in izrecno preverjeno, da ni Drift.
  Equal("Superseded", await Status(olderEcho), "Starejše sporočilo za isto polje mora biti nadomeščeno");
  Equal(false, await Status(olderEcho) == "Drift", "Echo novejše spremembe ne sme označiti starejše kot Drift");
  Equal("Verified", await Status(newerEcho), "Echo mora potrditi sporočilo z ujemajočim pričakovanim hashem");

  Console.WriteLine("F8 hardening: server-side ownership/integrity, late completion, crash reclaim in concurrent recovery PASS.");
}
finally
{
  await Sql("DELETE attempt FROM out.OutboxAttempt attempt INNER JOIN out.OutboxMessage message ON message.OutboxMessageId=attempt.OutboxMessageId WHERE message.OrganizationId=@Org; DELETE out.OutboxMessage WHERE OrganizationId=@Org; DELETE out.OwnershipPolicy WHERE OrganizationId=@Org; DELETE dbo.IntegrationProfile WHERE OrganizationId=@Org; DELETE dbo.OrganizationConfig WHERE OrganizationId=@Org;", ("@Org", organizationId));
}
return 0;

async Task<long> Enqueue(string key, string field, string value)
{
  var payload = JsonSerializer.Serialize(new { entityKey = key, field, value });
  return await SqlScalar<long>("DECLARE @Id bigint; EXEC out.EnqueueMessage @OrganizationId=@Org,@TargetKind=N'SAOP_PRODUCT',@Operation=N'UPDATE',@EntityType=N'Product',@PayloadJson=@Payload,@Actor=N'F8_HARDENING',@OutboxMessageId=@Id OUTPUT; SELECT @Id;", ("@Org", organizationId), ("@Payload", payload));
}
async Task<long?> ClaimSeparate(string worker)
{
  await using var separate = new SqlConnection(connectionString); await separate.OpenAsync();
  await using var command = new SqlCommand("EXEC out.ClaimMessage @WorkerId;", separate); command.Parameters.AddWithValue("@WorkerId", worker);
  await using var reader = await command.ExecuteReaderAsync(); return await reader.ReadAsync() ? reader.GetInt64(reader.GetOrdinal("OutboxMessageId")) : null;
}
async Task<long> Claim(string worker) => (await ClaimSeparate(worker)) ?? throw new InvalidOperationException("Ni claim sporočila.");
async Task Complete(long id, string worker, bool succeeded) => await Sql("EXEC out.CompleteAttempt @OutboxMessageId=@Id,@WorkerId=@Worker,@Succeeded=@Succeeded,@PermanentFailure=0;", ("@Id", id), ("@Worker", worker), ("@Succeeded", succeeded));
async Task<string> Status(long id) => await SqlScalar<string>("SELECT Status FROM out.OutboxMessage WHERE OutboxMessageId=@Id;", ("@Id", id));
async Task<string> PayloadHash(long id) => await SqlScalar<string>("SELECT PayloadHash FROM out.OutboxMessage WHERE OutboxMessageId=@Id;", ("@Id", id));
async Task<(string EntityKey, string FieldSummary, string Payload, string PayloadHash, string ExpectedEchoHash, string DedupKey)> Row(long id)
{
  await using var command = new SqlCommand("SELECT EntityKey,FieldSummary,PayloadJson,PayloadHash,ExpectedEchoHash,DedupKey FROM out.OutboxMessage WHERE OutboxMessageId=@Id;", connection); command.Parameters.AddWithValue("@Id", id);
  await using var reader = await command.ExecuteReaderAsync(); if (!await reader.ReadAsync()) throw new InvalidOperationException("Outbox vrstica manjka.");
  return (reader.GetString(0), reader.GetString(1), reader.GetString(2), reader.GetString(3), reader.GetString(4), reader.GetString(5));
}
async Task<T> SqlScalar<T>(string sql, params (string Name, object Value)[] parameters) { await using var command = new SqlCommand(sql, connection); foreach (var p in parameters) command.Parameters.AddWithValue(p.Name, p.Value); return (T)Convert.ChangeType((await command.ExecuteScalarAsync())!, typeof(T)); }
async Task Sql(string sql, params (string Name, object Value)[] parameters) { await using var command = new SqlCommand(sql, connection); foreach (var p in parameters) command.Parameters.AddWithValue(p.Name, p.Value); await command.ExecuteNonQueryAsync(); }
async Task ExpectFailure(string sql, string message, params (string Name, object Value)[] parameters) { try { await Sql(sql, new[] { ("@Org", (object)organizationId) }.Concat(parameters).ToArray()); } catch (SqlException) { return; } throw new InvalidOperationException(message); }
static void Equal<T>(T expected, T actual, string message) { if (!EqualityComparer<T>.Default.Equals(expected, actual)) throw new InvalidOperationException($"{message}: {expected} != {actual}"); }
static string? ReadConnectionString() { var env = Environment.GetEnvironmentVariable("PIM_F8_TEST_CONNECTION_STRING") ?? Environment.GetEnvironmentVariable("PIM_CONNECTION_STRING"); if (!string.IsNullOrWhiteSpace(env)) return env; var path = Path.Combine(Directory.GetCurrentDirectory(), "appsettings.Local.json"); if (!File.Exists(path)) return null; using var json = JsonDocument.Parse(File.ReadAllText(path)); return json.RootElement.GetProperty("ConnectionStrings").GetProperty("Pim").GetString(); }
