# PIM bralni API (PIM.Api) — tehnični opis

Uporabniška navodila (namestitev, ključi, povezava AI): [`Navodila/08_API_za_AI.md`](../Navodila/08_API_za_AI.md).
Analiza baze, na kateri je API zasnovan: [`ANALIZA_BAZE_ZA_API_2026-09-26.md`](ANALIZA_BAZE_ZA_API_2026-09-26.md).

## 1. Namen in meje

Samo branje za AI, analize in poročanje: izdelki, cene, zaloga, stranke, naročila dobaviteljem, analitika.
API ne piše v `canon`, `pim`, `out`, SAOP ali nastavitve. Edini zapisi so dnevnik klicev (`api.RequestLog`)
in čas zadnje uporabe ključa (`api.Client.LastUsedUtc`).

## 2. Zgradba

| Del | Kje |
|---|---|
| Spletna aplikacija (.NET 10, minimal API) | `PIM_Solution/src/PIM.Api` |
| Katalog končnih točk (en vir za poti, parametre, OpenAPI, navodila in orodja MCP) | `Catalog.cs` |
| Preverjanje parametrov in izvedba postopkov | `QueryRunner.cs` |
| Ključi, podjetja, dnevnik | `ClientAccess.cs` |
| Skrbnik ključev (ukazna vrstica) | `ClientCli.cs` (`PIM.Api.exe odjemalec ...`) |
| Opis OpenAPI 3.0 in navodila za AI | `ApiDocs.cs` (`/openapi.json`, `/api/v1/guide`) |
| MCP brez baze in brez ASP.NET (initialize, tools/list, tools/call, ping) | `McpProtocol.cs` |
| Test pogodbe (katalog ↔ 287, vloga samo za branje, MCP) | `tests/PIM.F12.ApiContractTests` (`run_tests.ps1 -Filter F12`) |
| Baza: shema `api`, vloga `pim_api_reader` | migracija `287_BralniApiZaAnalizeInAi.sql` |
| Objava in namestitev | `deploy/Publish-Api.ps1`, `deploy/Install-PimApi.ps1` |

**Nova končna točka** = nov postopek `api.*` v novi migraciji + ena vrstica v `Catalog.Endpoints`. Vse ostalo
(pot, preverjanje, OpenAPI, navodila, orodje MCP) nastane samo.

## 3. Varnost (obramba v globino)

1. **Baza.** API se prijavi z uporabnikom v vlogi `pim_api_reader`, ki ima samo `EXECUTE` na shemi `api`.
   Brez `SELECT` na katerokoli tabelo, `api.Admin_*` so izrecno prepovedani (`DENY`), prav tako branje
   `api.Client`, `api.ClientHistory` in `api.RequestLog`. Postopki berejo `canon`/`b2b`/`stock`/`purch`/`ana`
   prek verige lastništva (vse sheme so v lasti `dbo`), zato brez dinamičnega SQL. Preverjeno 2026-09-26 z
   `EXECUTE AS USER` (vseh 17 postopkov deluje, `SELECT canon.Product`, `sec.LocalUser`, `api.Client`,
   `api.Admin_ListClients`, `pim.SaveProductTexts` zavrnjeni z napako 229).
2. **Ključ.** `pim_` + 43 naključnih znakov (256 bitov). V bazi samo SHA-256 (`api.Client.KeyHash`).
   Prijava je v pomnilniku 60 s (`Api:AuthCacheSeconds`), zato preklic velja najkasneje po 60 s. Napačen
   ključ: 300 ms zamika in 401.
3. **Podjetje in področje.** Vsak klic je v enem podjetju (`organizationId`); ključ vidi samo svoja podjetja
   (`api.Client.OrganizationIds`, NULL = vsa aktivna) in področja (`Scopes`). Kartica izdelka izpusti nabore
   področij, ki jih ključ nima (cene, zaloga, nabava).
4. **Omrežje.** `Api:AllowedRemoteIps` (IP ali CIDR); prazno = vsi. Localhost je vedno dovoljen.
5. **Hitrost.** Omejitev na ključ (`RequestsPerMinute`, privzeto 120), sicer 429 z `Retry-After: 60`.
6. **Sled.** Vsak klic v `api.RequestLog` (ključ, čas, pot, poizvedba, podjetje, status, ms, vrstice, IP);
   `api.PurgeRequestLog` enkrat na dan pobriše starejše od `Api:RequestLogDays` (90).

## 4. Končne točke

| Pot | Postopek | Področje | Vrsta |
|---|---|---|---|
| `GET /health` | `SELECT 1` | — (brez ključa) | zdravje baze |
| `GET /openapi.json`, `GET /api/v1/guide` | — | — (brez ključa) | opis |
| `GET /api/v1` | — | — | kdo sem, podjetja, področja |
| `GET /api/v1/organizations` | `api.GetOrganizations` | — | vrstice |
| `GET /api/v1/freshness` | `api.GetDataFreshness` | — | vrstice |
| `GET /api/v1/partners` | `api.GetPartners` | izdelki | vrstice |
| `GET /api/v1/products` | `api.SearchProducts` | izdelki | stran |
| `GET /api/v1/products/detail` | `api.GetProduct` (11 naborov) | izdelki | kartica |
| `GET /api/v1/prices/lists` | `api.GetPriceLists` | cene | vrstice |
| `GET /api/v1/prices` | `api.GetPrices` | cene | stran |
| `GET /api/v1/prices/history` | `api.GetPriceHistory` | cene | vrstice |
| `GET /api/v1/prices/comparison` | `api.GetPriceComparison` | cene | stran |
| `GET /api/v1/stock` | `api.GetStock` | zaloga | stran |
| `GET /api/v1/stock/summary` | `api.GetStockSummary` | zaloga | vrstice |
| `GET /api/v1/customers` | `api.SearchCustomers` | stranke | stran |
| `GET /api/v1/customers/detail` | `api.GetCustomer` (3 nabori) | stranke | kartica |
| `GET /api/v1/purchase-orders` | `api.GetPurchaseOrderLines` | nabava | stran |
| `GET /api/v1/analytics/items` | `api.GetItemMetrics` | analitika | stran |
| `GET /api/v1/analytics/suppliers` | `api.GetSupplierMetrics` | analitika | vrstice |
| `POST /mcp` | vse zgoraj kot orodja | po ključu | MCP |

Parametri in opisi: `/api/v1/guide`. Neznan parameter, napačen tip ali vrednost izven seznama → 400 s
seznamom napak in dovoljenih parametrov (AI se tako sam popravi). Odgovor strani:
`{ organizationId, total, skip, count, hasMore, items }`; `format=csv` vrne CSV za Excel (sl-SI).

## 5. Pomen podatkov (kaj postopki računajo)

- **Zaloga** (`api.StockByProduct`): aktivni posnetki podjetja (`stock.Snapshot.IsActive = 1`), samo ujete
  pozicije (`MatchedProductId`). ERP = konektorji tipa `SAOP`, DOBAVITELJ = datotečni (NW, Braytron).
  `erpAvailable` = `COALESCE(AvailableQuantity, Quantity)` kot v izvozu (§5.3 SISTEM_PIM). Zaloga
  sestrskega podjetja (`ADD` v `out.ExportStockSource`) se **ne** prišteje: API poroča o podjetju, ki ga vprašaš.
- **Cene** (`api.CurrentPrice`): po (izdelek, cenik) zadnja aktivna vrstica z `ValidFrom <= zdaj`; prejšnja
  cena = naslednja starejša. Cene so neto, `grossPrice = net × (1 + DDV/100)`.
- **Cene v seznamu izdelkov:** `costPrice` = `ana.Setting.CostPriceList` (privzeto NAB), `retailPrice` in
  `wholesalePrice` po `out.ExportPriceList` (PriceB2C / PriceB2B), vključno s cenikom drugega podjetja
  (`PriceOrganizationId`, npr. IQ B2B iz Vidadrie) — enako kot katalog.csv.
- **Vrednost zaloge** = pozitivna ERP količina × nabavna cena; artikli brez nabavne cene so prešteti
  (`itemsWithoutCost`), ne tiho izpuščeni.
- **Marža:** faktor = prodajna / nabavna; prag `FAKTOR_MARZE` iz `pim.CheckThreshold` (po podjetju ali privzeto).
- **Popusti stranke:** `b2b.CustomerItemGroupDiscount` po `CustomerGroupCode = b2b.Customer.DiscountPriceListCode`,
  veljavni danes.
- **Imena partnerjev:** pogled `canon.PartnerName` (= `b2b.Customer` istega podjetja).
- **Iskanje:** `COLLATE Latin1_General_100_CI_AI` (brez šumnikov in velikih črk), vsaka beseda posebej
  (zanka po največ 8 besedah, ne po izdelkih).

## 6. Zmogljivost (lokalna baza, 2026-09-26, ~197.000 izdelkov)

| Klic | Čas |
|---|---|
| iskanje izdelkov, 2 besedi, podjetje 2 (111.098 izdelkov) | ~1,0 s |
| iskanje izdelkov z zalogo, podjetje 3 | 0,23 s |
| kartica izdelka (11 naborov) | 0,22 s |
| povzetek zaloge po dobaviteljih, podjetje 2 | 0,20 s |
| cene, spremembe od datuma | 0,05 s |
| primerjava marže | 0,08 s |
| naročila dobaviteljem | 0,02 s |

Največ vrstic na stran: 500 (izdelki, stranke) oziroma 1000 (cene, zaloga, naročila). Časovna omejitev
poizvedbe 60 s (`Api:CommandTimeoutSeconds`).

## 7. Nastavitve (`appsettings.Local.json` ob `PIM.Api.exe`)

| Ključ | Privzeto | Pomen |
|---|---|---|
| `ConnectionStrings:PimApi` | — | povezava z uporabnikom v vlogi `pim_api_reader` (okolje `PIM_API_CONNECTION_STRING` ima prednost) |
| `Api:AllowedRemoteIps` | `[]` | dovoljeni IP/CIDR; prazno = vsi |
| `Api:PublicBaseUrl` | — | javni naslov v OpenAPI in navodilih |
| `Api:RequestLogDays` | 90 | hramba dnevnika klicev |
| `Api:AuthCacheSeconds` | 60 | koliko časa velja prijava v pomnilniku |
| `Api:CommandTimeoutSeconds` | 60 | časovna omejitev postopka |

## 8. MCP

`POST /mcp` je strežnik Model Context Protocol (HTTP brez seje, JSON odgovori): `initialize` (v `instructions`
vrne navodila za AI), `tools/list` (samo orodja področij ključa, vsa `readOnlyHint`), `tools/call`, `ping`.
Obvestila (brez `id`) → 202. Napaka orodja (npr. brez področja) vrne `isError: true` z razlogom v besedilu.
Neveljaven JSON → 400 in `-32700`; seznam zahtevkov (paket) ali `method`, ki ni besedilo → 400/`-32600`;
neznano orodje → `-32602`; nepodprta metoda → `-32601`.

Protokol je v `McpProtocol.cs` ločen od ASP.NET in baze: branje dobi od `Program.cs` kot funkcijo, ki kliče
`QueryRunner`. Zato ga test F12 preveri brez strežnika in brez baze (initialize, tools/list z in brez področij,
tools/call, napake). `PIM.Api` in test sta v `PIM.sln`, zato vrata vsake naloge API prevedejo; napaka prevajanja
kjerkoli v API-ju podre build.

**Kdo se lahko poveže (2026-09-29):** Claude Code (`claude mcp add --transport http ... --header`) in Claude
Desktop (`mcp-remote`) v notranjem omrežju. Povezovalniki v oblaku (Claude.ai v brskalniku, ChatGPT) praviloma
zahtevajo javni HTTPS in OAuth; glave `X-Api-Key` večinoma ne podpirajo (nepreverjeno). Objava na internet je
odločitev lastnika.

## 9. Vpliv na sistem

- Nova shema `api`, vloga `pim_api_reader`, tri tabele (`api.Client`, `api.ClientHistory`, `api.RequestLog`).
- Obstoječe tabele, postopki, izvozi, SAOP pot in workerji so nespremenjeni.
- Obremenitev baze: bralne poizvedbe z `READ COMMITTED`. Ker `READ_COMMITTED_SNAPSHOT` na bazi ni vklopljen,
  lahko dolga bralna poizvedba med nočnim uvozom počaka na zaklep (ali obratno). Priporočilo v analizi (§4).
