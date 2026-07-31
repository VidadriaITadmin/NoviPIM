using System.Data;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using PIM.Operations;

const int organizationId=9909;
var connectionString=ReadConnectionString();
if(string.IsNullOrWhiteSpace(connectionString)){Console.Error.WriteLine("F9 MSSQL BLOCKED: lokalna PIM povezava ni na voljo.");return 2;}
var settings=new SqlConnectionStringBuilder(connectionString);
if(!string.Equals(settings.InitialCatalog,"PIM",StringComparison.OrdinalIgnoreCase))throw new InvalidOperationException("F9 integracija je dovoljena samo v bazi PIM; PIM_test in druge baze so zavrnjene.");
await using var connection=new SqlConnection(connectionString);await connection.OpenAsync();
await Cleanup();
try
{
  await Sql("INSERT dbo.OrganizationConfig(OrganizationId,Name,SaopPrefix) VALUES(@Org,N'F9_ISOLATED',N'F9_ISOLATED'); INSERT ops.ScheduleProfile(OrganizationId,Provider,Pipeline,IsEnabled,IntervalSeconds,StaleAfterSeconds,LockTimeoutMilliseconds,UpdatedBy) VALUES(@Org,N'Fixture',N'F9_PIPELINE',1,1,1,0,N'F9_TEST');",("@Org",organizationId));
  await using var first=await OperationsRun.BeginAsync(connectionString,organizationId,"F9_PIPELINE","f9-first");
  try{await using var overlap=await OperationsRun.BeginAsync(connectionString,organizationId,"F9_PIPELINE","f9-overlap");throw new InvalidOperationException("Drugi zagon je dobil isti lease.");}catch(SqlException exception) when(exception.Number==51101){}
  await first.CompleteAsync(true);
  await Sql("UPDATE ops.IntegrationHealth SET Status=N'Running',LastHeartbeatUtc=DATEADD(minute,-10,SYSUTCDATETIME()),WatermarkUtc=DATEADD(minute,-10,SYSUTCDATETIME()) WHERE OrganizationId=@Org; EXEC ops.RunWatchdog @Actor=N'F9_TEST'; EXEC ops.RunWatchdog @Actor=N'F9_TEST';",("@Org",organizationId));
  Equal(1,await Scalar<int>("SELECT COUNT(*) FROM ops.Alert WHERE OrganizationId=@Org AND AlertKind=N'StaleHeartbeat' AND ResolvedUtc IS NULL",("@Org",organizationId)),"stale alarm se je podvojil");
  await Sql("UPDATE ops.IntegrationHealth SET Status=N'Running',LastHeartbeatUtc=SYSUTCDATETIME(),WatermarkUtc=SYSUTCDATETIME() WHERE OrganizationId=@Org; EXEC ops.RunWatchdog @Actor=N'F9_TEST';",("@Org",organizationId));
  Equal(1,await Scalar<int>("SELECT COUNT(*) FROM ops.Alert WHERE OrganizationId=@Org AND AlertKind=N'StaleHeartbeat' AND ResolvedUtc IS NOT NULL",("@Org",organizationId)),"okrevanje ni razrešilo alarma");
  await Sql("INSERT dbo.IntegrationProfile(OrganizationId,TargetKind,EndpointTemplate,HttpOperation,IsEnabled,UpdatedBy) VALUES(@Org,N'F9',N'http://127.0.0.1/',N'POST',0,N'F9_TEST'); INSERT out.OutboxMessage(OrganizationId,TargetKind,Operation,EntityType,EntityKey,FieldSummary,PayloadJson,PayloadHash,ExpectedEchoHash,DedupKey,Status,CreatedBy) VALUES(@Org,N'F9',N'POST',N'Fixture',N'DEAD',N'Fixture',N'{}',REPLICATE('0',64),REPLICATE('0',64),REPLICATE('1',64),N'Dead',N'F9_TEST'),(@Org,N'F9',N'POST',N'Fixture',N'DRIFT',N'Fixture',N'{}',REPLICATE('0',64),REPLICATE('0',64),REPLICATE('2',64),N'Drift',N'F9_TEST'); EXEC ops.RunWatchdog @Actor=N'F9_TEST';",("@Org",organizationId));
  Equal(2,await Scalar<int>("SELECT COUNT(*) FROM ops.Alert WHERE OrganizationId=@Org AND AlertKind IN(N'OutboundDead',N'OutboundDrift') AND ResolvedUtc IS NULL",("@Org",organizationId)),"Dead in Drift nista ločena alarma");
  Console.WriteLine("F9 integration: PIM MSSQL lease, stale/recovery, watermark, Dead/Drift in dedup PASS.");
}
finally
{
  await Cleanup();
}
return 0;

async Task Sql(string sql,params (string Name,object Value)[] parameters){await using var command=new SqlCommand(sql,connection);foreach(var parameter in parameters)command.Parameters.AddWithValue(parameter.Name,parameter.Value);await command.ExecuteNonQueryAsync();}
async Task Cleanup()=>await Sql("DELETE ops.AlertDelivery WHERE AlertId IN(SELECT AlertId FROM ops.Alert WHERE OrganizationId=@Org); DELETE ops.Alert WHERE OrganizationId=@Org; DELETE ops.IntegrationHealth WHERE OrganizationId=@Org; DELETE ops.ScheduleProfile WHERE OrganizationId=@Org; DELETE out.OutboxAttempt WHERE OutboxMessageId IN(SELECT OutboxMessageId FROM out.OutboxMessage WHERE OrganizationId=@Org); DELETE out.OutboxMessage WHERE OrganizationId=@Org; DELETE dbo.IntegrationProfile WHERE OrganizationId=@Org; DELETE dbo.OrganizationConfig WHERE OrganizationId=@Org;",("@Org",organizationId));
async Task<T> Scalar<T>(string sql,params (string Name,object Value)[] parameters){await using var command=new SqlCommand(sql,connection);foreach(var parameter in parameters)command.Parameters.AddWithValue(parameter.Name,parameter.Value);return (T)Convert.ChangeType(await command.ExecuteScalarAsync()??throw new InvalidOperationException("Ni rezultata."),typeof(T));}
static void Equal<T>(T expected,T actual,string message){if(!EqualityComparer<T>.Default.Equals(expected,actual))throw new InvalidOperationException($"{message}: {expected} != {actual}");}
static string? ReadConnectionString(){var env=Environment.GetEnvironmentVariable("PIM_F9_TEST_CONNECTION_STRING")??Environment.GetEnvironmentVariable("PIM_CONNECTION_STRING");if(!string.IsNullOrWhiteSpace(env))return env;var path=Path.Combine(Directory.GetCurrentDirectory(),"appsettings.Local.json");if(!File.Exists(path))return null;using var json=JsonDocument.Parse(File.ReadAllText(path));return json.RootElement.GetProperty("ConnectionStrings").GetProperty("Pim").GetString();}
