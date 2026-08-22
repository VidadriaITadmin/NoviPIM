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
// Vhodni dogovor workerja: kaj naj prebere in kam naj to zapiše. To je edini del, ki se da
// preveriti brez baze, in prav ta je doslej manjkal — worker je znal brati, ni pa vedel,
// čigava zaloga je in v kateri vir gre.
var privzeto = StockFileWorkerOptions.Parse(["--file", nwPath]);
Equal("NW_STOCK", privzeto.SourceCode, "CSV brez --source mora biti Nowodvorski.");
Equal("dd/MM/yyyy", privzeto.DateFormat, "Nowodvorski piše datum po evropsko.");
Equal(2, privzeto.OrganizationId, "Privzeto podjetje.");
Equal("file://NOWODVORSKI.csv", privzeto.Endpoint, "Privzeta oznaka vira je ime datoteke.");
Equal(false, privzeto.ReadOnly, "Privzeto se v bazo piše.");

var braytron = StockFileWorkerOptions.Parse(["--file", btPath]);
Equal("BT_STOCK", braytron.SourceCode, "XML brez --source mora biti Braytron.");
Equal("yyyy-MM-dd", braytron.DateFormat, "Braytron piše datum po ISO.");

var izrecno = StockFileWorkerOptions.Parse(
  ["--file", nwPath, "--source", "BT_STOCK", "--organization-id", "3", "--endpoint", "ftp://x", "--samo-preberi"]);
Equal("BT_STOCK", izrecno.SourceCode, "--source mora premagati končnico.");
Equal(3, izrecno.OrganizationId, "--organization-id se upošteva.");
Equal("ftp://x", izrecno.Endpoint, "--endpoint se upošteva.");
Equal(true, izrecno.ReadOnly, "--samo-preberi se upošteva.");
Equal("yyyy-MM-dd", izrecno.DateFormat, "Oblika datuma sledi izbranemu viru, ne končnici.");

Throws(() => StockFileWorkerOptions.Parse(["--source", "NW_STOCK"]), "Brez --file mora pasti.");
Throws(() => StockFileWorkerOptions.Parse(["--file", nwPath, "--organization-id", "nula"]), "Nečloveško podjetje mora pasti.");
Throws(() => StockFileWorkerOptions.Parse(["--file", nwPath, "--organization-id", "0"]), "Podjetje 0 mora pasti.");
Throws(() => StockFileWorkerOptions.Parse(["--file"]), "Argument brez vrednosti mora pasti.");
Throws(() => StockFileWorkerOptions.Parse(["--neznano"]), "Neznan argument mora pasti.");

Console.WriteLine($"F6 fixtures: NW={nw.Records.Count}, BT={bt.Records.Count}, SHA-256 sled in vhodni dogovor workerja PASS.");

static string FindRoot() { var d=new DirectoryInfo(Directory.GetCurrentDirectory()); while(d is not null&&!Directory.Exists(Path.Combine(d.FullName,"fixtures")))d=d.Parent; return d?.FullName??throw new InvalidOperationException(); }
static void Throws(Action action, string message)
{
  try { action(); }
  catch (ArgumentException) { return; }
  throw new InvalidOperationException($"{message} — pričakovala se je ArgumentException.");
}
static void Equal<T>(T expected,T actual,string message) { if(!EqualityComparer<T>.Default.Equals(expected,actual))throw new InvalidOperationException($"{message} Pričakovano {expected}, dejansko {actual}."); }
