using System.Net;
using System.Text;
using PIM.SourceFetchWorker;

// Prevzem dobaviteljevih datotek in arhiv prevzetih različic.
//
// Zakaj ta test obstaja: PIM.SourceFetchWorker prinese vsako datoteko vsakega dobavitelja in
// do zdaj ni imel nobenega testa. Braytronov XML se sme prenesti enkrat na tri ure — datoteka,
// ki jo tu izgubimo, je izgubljena do naslednjega okna. Ravno zato so tri lastnosti prevzema
// pogodba in ne podrobnost izvedbe:
//
//   1. zavrnitev dobavitelja pride kot HTTP 200 in NE sme povoziti prejšnje datoteke;
//   2. arhivska kopija nastane samo ob resnični spremembi vsebine;
//   3. kopije se starajo same, po 30 dneh.
//
// Zunanjega klica ni: dobavitelja igra HttpListener na 127.0.0.1 z vrati, ki jih dodeli sistem.

var koren = Path.Combine(Path.GetTempPath(), "pim-prevzem-" + Guid.NewGuid().ToString("N")[..8]);
Directory.CreateDirectory(koren);

var vrata = ProstaVrata();
var naslov = $"http://127.0.0.1:{vrata}/zaloga/";
string odgovor = "<Stocks><Item code=\"A\" qty=\"5\" /></Stocks>" + new string(' ', 5000);

using var listener = new HttpListener();
listener.Prefixes.Add(naslov);
listener.Start();
var streznik = Task.Run(async () =>
{
  while (listener.IsListening)
  {
    HttpListenerContext context;
    try { context = await listener.GetContextAsync(); }
    catch (HttpListenerException) { return; }
    catch (ObjectDisposedException) { return; }

    var telo = Encoding.UTF8.GetBytes(odgovor);
    context.Response.StatusCode = 200;
    context.Response.ContentLength64 = telo.Length;
    await context.Response.OutputStream.WriteAsync(telo);
    context.Response.Close();
  }
});

try
{
  using var http = new HttpClient();
  var fetcher = new SourceFetcher(http, koren);

  // MinIntervalMinutes = null: v tem testu razmika dobavitelja ni, sicer bi drugi prevzem
  // zavrnila naša lastna varovalka in test ne bi preizkusil ničesar.
  var mesto = new FetchLocation(1, null, "BT_TEST", "HTTP", null, "Fetch:BT_TEST", "zaloga.xml", null, null);
  var poverilnica = new FetchCredential(naslov, null, null, null, null, null, true);

  var cilj = Path.Combine(koren, "BT_TEST", "zaloga.xml");
  var arhivMapa = Path.Combine(koren, "BT_TEST", "arhiv");

  // ── 1. Prvi prevzem: datoteka in ena arhivska kopija ───────────────────────
  var prvi = await fetcher.FetchAsync(mesto, poverilnica);
  Assert(prvi.Error is null, "Prvi prevzem ne sme vrniti napake: " + prvi.Error);
  Assert(prvi.Fetched, "Prvi prevzem mora prinesti datoteko.");
  Assert(File.Exists(cilj), "Živa datoteka mora nastati na " + cilj);
  Assert(prvi.ArchivePath is not null, "Prvi prevzem mora ustvariti arhivsko kopijo.");
  Assert(Arhivov(arhivMapa) == 1, "Po prvem prevzemu mora biti natanko ena kopija.");

  // Kopija je stisnjena in se prebere nazaj v natanko izvorno vsebino: arhiv brez tega
  // jamstva je samo zasedeno mesto na disku.
  Assert(prvi.ArchivePath!.EndsWith(".xml.gz", StringComparison.Ordinal),
    "Kopija mora ohraniti končnico izvorne datoteke in biti stisnjena: " + prvi.ArchivePath);
  Assert(Odstisni(prvi.ArchivePath) == File.ReadAllText(cilj),
    "Vsebina arhivske kopije se mora ujemati z živo datoteko.");

  // Ime nosi UTC in črko Z; lokalni čas bi ob jesenskem premiku ure dal dve enaki imeni.
  Assert(System.Text.RegularExpressions.Regex.IsMatch(Path.GetFileName(prvi.ArchivePath), @"_\d{8}_\d{6}Z\.xml\.gz$"),
    "Ime kopije mora nositi UTC žig z oznako Z: " + Path.GetFileName(prvi.ArchivePath));

  // ── 2. Nespremenjena vsebina: nobene nove kopije ───────────────────────────
  var drugi = await fetcher.FetchAsync(mesto, poverilnica);
  Assert(drugi.Error is null, "Ponovni prevzem ne sme vrniti napake: " + drugi.Error);
  Assert(!drugi.Fetched, "Nespremenjena datoteka ne velja za nov prevzem.");
  Assert(drugi.ArchivePath is null, "Nespremenjena vsebina ne sme ustvariti nove kopije.");
  Assert(Arhivov(arhivMapa) == 1, "Arhiv ne sme rasti ob nespremenjenih prevzemih.");

  // ── 3. Spremenjena vsebina: druga kopija ───────────────────────────────────
  odgovor = "<Stocks><Item code=\"A\" qty=\"7\" /></Stocks>" + new string(' ', 5000);
  var tretji = await fetcher.FetchAsync(mesto, poverilnica);
  Assert(tretji.Fetched, "Spremenjena vsebina mora veljati za nov prevzem.");
  Assert(tretji.ArchivePath is not null, "Spremenjena vsebina mora ustvariti novo kopijo.");
  Assert(Arhivov(arhivMapa) == 2, "Po spremembi morata biti dve kopiji, jih je " + Arhivov(arhivMapa) + ".");
  Assert(File.ReadAllText(cilj).Contains("qty=\"7\"", StringComparison.Ordinal),
    "Živa datoteka mora nositi novo vsebino.");

  // ── 4. Staranje: kar je starejše od 30 dni, gre stran ──────────────────────
  var stara = Directory.EnumerateFiles(arhivMapa).OrderBy(x => x).First();
  File.SetLastWriteTimeUtc(stara, DateTime.UtcNow.AddDays(-31));
  var mlada = Directory.EnumerateFiles(arhivMapa).OrderBy(x => x).Last();
  File.SetLastWriteTimeUtc(mlada, DateTime.UtcNow.AddDays(-29));

  odgovor = "<Stocks><Item code=\"A\" qty=\"9\" /></Stocks>" + new string(' ', 5000);
  var cetrti = await fetcher.FetchAsync(mesto, poverilnica);
  Assert(cetrti.Fetched, "Četrti prevzem mora prinesti spremenjeno vsebino.");
  Assert(!File.Exists(stara), "Kopija, starejša od 30 dni, mora biti odstranjena.");
  Assert(File.Exists(mlada), "Kopija, mlajša od 30 dni, mora ostati.");
  Assert(Arhivov(arhivMapa) == 2, "Po staranju morata ostati mlada in nova kopija.");

  // ── 5. Zavrnitev dobavitelja ne sme povoziti podatka ───────────────────────
  // Braytron ob preseženi omejitvi odgovori s HTTP 200 in kratkim <Hata>. Brez te varovalke
  // bi 193 bajtov napake povozilo veljavno zalogo in naslednji worker bi prebral nič.
  var predZavrnitvijo = File.ReadAllText(cilj);
  var kopijPred = Arhivov(arhivMapa);
  odgovor = "<Hata>Maximum Sorgu Limitine Ulastiniz</Hata><XmlAraligi>180 Dk</XmlAraligi>";
  var peti = await fetcher.FetchAsync(mesto, poverilnica);

  Assert(peti.Error is null, "Zavrnitev ob veljavni prejšnji datoteki ni napaka zagona: " + peti.Error);
  Assert(!peti.Fetched, "Zavrnitev ni prevzem.");
  Assert(peti.ArchivePath is null, "Zavrnitev ne sme ustvariti kopije.");
  Assert(File.ReadAllText(cilj) == predZavrnitvijo, "Zavrnitev ne sme povoziti prejšnje datoteke.");
  Assert(Arhivov(arhivMapa) == kopijPred, "Zavrnitev ne sme spremeniti arhiva.");
  Assert(File.Exists(cilj + ".pocakaj"), "Po zavrnitvi mora nastati oznaka razmika.");

  // ── 6. Razmik dobavitelja: dokler teče, vira ne kličemo ────────────────────
  odgovor = "<Stocks><Item code=\"A\" qty=\"11\" /></Stocks>" + new string(' ', 5000);
  var sesti = await fetcher.FetchAsync(mesto, poverilnica);
  Assert(!sesti.Fetched && sesti.Error is null, "Med razmikom prevzema ni, a to ni napaka.");
  Assert(sesti.Skipped is not null && sesti.Skipped.Contains("Razmik", StringComparison.OrdinalIgnoreCase),
    "Preskok mora povedati, da teče razmik dobavitelja: " + sesti.Skipped);
  Assert(File.ReadAllText(cilj) == predZavrnitvijo, "Med razmikom se živa datoteka ne sme spremeniti.");

  Console.WriteLine($"F6 prevzem in arhiv PASS. Kopij v arhivu: {Arhivov(arhivMapa)}.");
}
finally
{
  listener.Stop();
  await Task.WhenAny(streznik, Task.Delay(TimeSpan.FromSeconds(2)));

  // Test počisti samo svojo začasno mapo; drugih poti se ne dotika.
  try { Directory.Delete(koren, recursive: true); } catch (IOException) { }
}

return 0;

static int Arhivov(string mapa) => Directory.Exists(mapa) ? Directory.GetFiles(mapa).Length : 0;

static string Odstisni(string path)
{
  using var vir = File.OpenRead(path);
  using var razsirjevalnik = new System.IO.Compression.GZipStream(vir, System.IO.Compression.CompressionMode.Decompress);
  using var bralec = new StreamReader(razsirjevalnik);
  return bralec.ReadToEnd();
}

// Vrata dodeli sistem: fiksna bi se na razvojnem računalniku slej ko prej zaletela v tuj proces.
static int ProstaVrata()
{
  var poslusalec = new System.Net.Sockets.TcpListener(IPAddress.Loopback, 0);
  poslusalec.Start();
  var vrata = ((IPEndPoint)poslusalec.LocalEndpoint).Port;
  poslusalec.Stop();
  return vrata;
}

static void Assert(bool condition, string message)
{
  if (!condition) throw new InvalidOperationException(message);
}
