using PIM.StockMapping;
using PIM.StockFileWorker;
using Microsoft.Data.SqlClient;
using System.Text.Json;

var root=FindRoot();
var csvPath=Path.Combine(Path.GetTempPath(),"pim-f6-stock-"+Guid.NewGuid().ToString("N")+".csv");
var rows=new[]{new StockExportRow("NW.10168","5903139101684",0m,new DateOnly(2026,11,4),1000m,"NW_STOCK",null,new DateTime(2026,7,31,9,0,0,DateTimeKind.Utc))};
await StockCsvGenerator.WriteAsync(csvPath,rows);
var csv=await File.ReadAllTextAsync(csvPath);
if(!csv.StartsWith("ProductKey,EAN,Quantity,AvailabilityDate,IncomingQuantity,Source,Provider,SnapshotUtc\n",StringComparison.Ordinal))throw new InvalidOperationException("STOCK CSV glava ni pravilna.");
if(!csv.Contains("NW.10168,5903139101684,0,2026-11-04,1000,NW_STOCK,,2026-07-31T09:00:00.0000000Z",StringComparison.Ordinal))throw new InvalidOperationException("STOCK CSV podatki niso realno generirani.");
File.Delete(csvPath);
var page=File.ReadAllText(Path.Combine(root,"src/PIM.Intranet/Components/Pages/Stocks.razor"));
foreach(var label in new[]{"Zaloge","Vir","Čas posnetka","Količina","Pričakovana dobava","Prihodna količina","Ujemanje","Svežina"})if(!page.Contains(label,StringComparison.Ordinal))throw new InvalidOperationException("Manjka slovenska oznaka "+label);
Console.WriteLine("F6 integration (brez DB): realni STOCK CSV in slovenska stran PASS.");

var pim=Connection("PIM_CONNECTION_STRING","Pim");
if(string.IsNullOrWhiteSpace(pim))
{
  Console.WriteLine("F6 DB integration: SKIP — povezava Pim ni konfigurirana.");
}
else
{
  await using var probe=new SqlConnection(pim);
  try { await probe.OpenAsync(); }
  catch(Exception e) when(e is SqlException or InvalidOperationException)
  {
    Console.WriteLine("F6 DB integration: SKIP — konfigurirana baza PIM ni dosegljiva.");
    return 0;
  }
  await probe.CloseAsync();
  var nw=await new NwFtpTransport().ReadFixtureAsync(Path.Combine(root,"fixtures/stocks/nw/NOWODVORSKI.csv"));
  var bt=await new BtXmlTransport().ReadFixtureAsync(Path.Combine(root,"fixtures/stocks/bt/Braytron_stocks.xml"));
  var snapshot=DateTime.UtcNow;
  var writer=new StockLandingWriter(pim);
  var nwRun=await writer.PersistAsync(2,"NW_STOCK","FILE","fixture://nw/NOWODVORSKI.csv",snapshot,nw.PayloadHash,nw.Records,new("SourceItemId","NW.",null,null,"ItemID"),"dd/MM/yyyy");
  var btRun=await writer.PersistAsync(2,"BT_STOCK","FILE","fixture://bt/Braytron_stocks.xml",snapshot,bt.PayloadHash,bt.Records,new("SourceItemId","BA.","-",".","ItemID"),"yyyy-MM-dd");
  if(nwRun.Applied+nwRun.Quarantined!=2697||btRun.Applied+btRun.Quarantined!=1361)throw new InvalidOperationException("DB števec fixture vrstic ni popoln.");
  await using var connection=new SqlConnection(pim);await connection.OpenAsync();
  await using var command=new SqlCommand("EXEC intranet.GetStocks @OrganizationId=2;",connection);
  await using var reader=await command.ExecuteReaderAsync();if(!await reader.ReadAsync())throw new InvalidOperationException("Intranet procedura ni vrnila realne zaloge.");
  Console.WriteLine($"F6 DB integration: NW={nwRun.Applied}/{nwRun.Quarantined} applied/quarantine, BT={btRun.Applied}/{btRun.Quarantined}; intranet vrstica PASS.");
}

var pimTest=Connection("PIM_TEST_CONNECTION_STRING","PimTest");
if(string.IsNullOrWhiteSpace(pimTest)) Console.WriteLine("PIM_test capability: SKIP — povezava ni konfigurirana.");
else
{
  try
  {
    await using var connection=new SqlConnection(pimTest);await connection.OpenAsync();
    await using var command=new SqlCommand("SELECT HAS_PERMS_BY_NAME(DB_NAME(),N'DATABASE',N'SELECT'),HAS_PERMS_BY_NAME(DB_NAME(),N'DATABASE',N'INSERT');",connection);
    await using var reader=await command.ExecuteReaderAsync();await reader.ReadAsync();
    Console.WriteLine($"PIM_test capability (read-only poizvedba): SELECT={reader.GetInt32(0)}, INSERT={reader.GetInt32(1)}.");
  }
  catch(Exception e) when(e is SqlException or InvalidOperationException){Console.WriteLine("PIM_test capability: SKIP — baza ni dosegljiva.");}
}
return 0;

static string FindRoot(){var d=new DirectoryInfo(Directory.GetCurrentDirectory());while(d is not null&&!File.Exists(Path.Combine(d.FullName,"PIM.sln")))d=d.Parent;return d?.FullName??throw new InvalidOperationException();}
string? Connection(string variable,string key)
{
  var value=Environment.GetEnvironmentVariable(variable);if(!string.IsNullOrWhiteSpace(value))return value;
  var path=Path.Combine(root,"appsettings.Local.json");if(!File.Exists(path))return null;
  using var document=JsonDocument.Parse(File.ReadAllText(path));
  return document.RootElement.TryGetProperty("ConnectionStrings",out var strings)&&strings.TryGetProperty(key,out var setting)?setting.GetString():null;
}
