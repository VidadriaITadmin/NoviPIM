using PIM.StockFileWorker;

var root = FindRoot();
var nwPath = Path.Combine(root, "fixtures/stocks/nw/NOWODVORSKI.csv");
var btPath = Path.Combine(root, "fixtures/stocks/bt/Braytron_stocks.xml");
var nw = await new NwFtpTransport().ReadFixtureAsync(nwPath);
var bt = await new BtXmlTransport().ReadFixtureAsync(btPath);
Equal(2697, nw.Records.Count, "NW mora prebrati vse headerless vrstice.");
Equal(1361, bt.Records.Count, "BT mora prebrati vse Stok vrstice.");
Equal(64, nw.PayloadHash.Length, "NW SHA-256");
Equal(64, bt.PayloadHash.Length, "BT SHA-256");
if (!nw.Records.Any(row => row.Values["Quantity"] == "0")) throw new InvalidOperationException("NW fixture mora ohraniti ničelno količino.");
if (nw.Records.Any(row => row.Values.Values.Any(value => value?.Contains('\0') == true))) throw new InvalidOperationException("NUL ni normaliziran.");
Console.WriteLine($"F6 fixtures: NW={nw.Records.Count}, BT={bt.Records.Count}, SHA-256 sled PASS.");

static string FindRoot() { var d=new DirectoryInfo(Directory.GetCurrentDirectory()); while(d is not null&&!Directory.Exists(Path.Combine(d.FullName,"fixtures")))d=d.Parent; return d?.FullName??throw new InvalidOperationException(); }
static void Equal<T>(T expected,T actual,string message) { if(!EqualityComparer<T>.Default.Equals(expected,actual))throw new InvalidOperationException($"{message} Pričakovano {expected}, dejansko {actual}."); }
