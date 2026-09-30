# PIM baza — operativna dokumentacija

## Namen in meja

Razvojna baza je izključno `PIM` na lokalni SQL instanci. `PIM_test` ni dovoljen za ta cikel. Vse spremembe sheme so samo v `PIM_Solution/sql/migrations`; ročne spremembe v SSMS niso dovoljene.

Povezava uporablja Windows Integrated Authentication, šifriranje in zaupan lokalni certifikat. Povezovalni niz ostane lokalna skrivnost (`PIM_CONNECTION_STRING` oziroma `appsettings.Local.json`) in se nikoli ne zapisuje v Git, dokumentacijo ali testne izpise.

## Lokalna konfiguracija povezave

Edina veljavna lokalna konfiguracija je korenska `appsettings.Local.json` (v korenu repozitorija, ob `AGENTS.md`). Intranet (`PIM.Intranet`) razrešuje povezavo po tej prednosti:

1. okoljska spremenljivka `PIM_CONNECTION_STRING`, če je nastavljena;
2. sicer `ConnectionStrings:Pim` iz korenske `appsettings.Local.json`.

Ta prednost velja dokazano za intranet. Drugi lokalni procesi (workerji, konzolni testi) niso nujno enaki — npr. `PIM.XmlFileWorker` bere pot iz trenutne mape, nekateri workerji uporabljajo samo okoljsko spremenljivko brez branja korenske datoteke. Pred sklepanjem o obnašanju posameznega procesa preveri njegovo kodo.

**Kako intranet najde korensko datoteko.** `Program.cs` ne sestavlja poti do korena s fiksnim številom `..` (to bi se podrlo takoj, ko se `ContentRootPath` spremeni — npr. po `dotnet publish`). Namesto tega `LocalSettingsLocator.FindRepositoryRootLocalSettingsPath` (`Services/LocalSettingsLocator.cs`) od `ContentRootPath` išče navzgor po nadrejenih mapah, dokler ne najde `PIM_Solution\PIM.sln`, kar zanesljivo označuje koren repozitorija ne glede na globino. To deluje enako, če intranet zaženemo iz korena repozitorija, iz `PIM_Solution\src\PIM.Intranet`, ali iz poljubno globoke `dotnet publish` izhodne mape, dokler je ta še vedno nekje pod repozitorijem. Če korena ne najde (prava objava izven repozitorija), iskanje vrne `null` in intranet korenske datoteke sploh ne poskusi naložiti — takrat velja samo `PIM_CONNECTION_STRING` oziroma `ConnectionStrings:Pim` iz objavljene `appsettings.json`/`appsettings.Production.json`.

Morebitne podrejene datoteke s pripono `.zastarelo` (npr. `PIM_Solution/appsettings.Local.json.zastarelo`, `PIM_Solution/src/PIM.Intranet/appsettings.Local.json.zastarelo`) so preimenovani ostanki prejšnje, podvojene konfiguracije. Niso v uporabi, se ne berejo in se ne commitajo.

## Model

| Shema | Vloga |
|---|---|
| `raw` | nespremenjeni zajeti payloadi in karantena |
| `map` | konfiguracija virov, XPath/preslikave, watermarki, staging sled |
| `canon` | virsko neodvisen kanonični katalog |
| `val` | validacijski profili, zahteve polj, težave in promocija |
| `pim` | potrjeni katalog in B2B domena |
| `stock` | landing, posnetki, pozicije in neusklajene zaloge |
| `out` | izvozni kontrakti in outbox |
| `ops` | teki cevovodov, heartbeat, watchdog, alarmi in dnevniki |
| `sec` | uporabniki, vloge in navigacija |
| `intranet` | bralne/zapisovalne procedure za UI |

Tok: `raw.Inbox` → `map.ExtractedValue` → `canon.*` → `val.*` → `pim.*` → CSV/outbox. `OrganizationId` je obvezen izolacijski ključ.

### Slovar vrednosti in pretvorbe (migraciji 049 in 056)

Med `map.ExtractedValue` in `canon.*` stoji `map.ApplyValueTransforms`. Preslikava pove, **od kod** vrednost pride; te tri tabele povedo, **v kakšni obliki** pride v katalog.

| Tabela | Vloga |
|---|---|
| `map.FieldTransform` | koraki nad eno preslikavo: `TRIM`, `NUMBER`, `UNIT`, `PREFIX`, `STRIPPREFIX`, `BOOL`, `UPPER`, `LOWER`, `LOOKUP` |
| `map.ValueLookup` | slovar vrednosti; `Domain` je koda lastnosti, `'*'` pomeni »velja povsod« in ožja domena ga premaga |
| `map.MissingTranslation` | delovni seznam vrednosti, za katere prevoda še ni — ena vrstica na vrednost, ne na izdelek |

Zakaj obstajajo: isto lastnost dobavitelji pošiljajo različno. Nowodvorski loči vrednost in enoto v dve polji, Braytron ju stlači v en niz (`30 mm`); isti dobavitelj piše `CLASS II` in `Class I`; vsi pošiljajo angleško, predloga Magenta pa ima stolpce `ANG` in `SLO`. Brez tega sloja bi bil vsak nov dobavitelj sprememba programa.

Sledljivost: izvorna vrednost se prepiše v `map.ExtractedValue.RawValue` in tam ostane. Ponoven zagon iste vrstice ne pretvori dvakrat (obdela samo `RawValue IS NULL`).

Manjkajoč prevod ni napaka: vrednost gre naprej nespremenjena, zapiše se v `map.MissingTranslation`.

Začetna polnitev slovarja je `scripts\seed_prevodi_besede.sql` (ni migracija — podatki, ne shema). Dokaz je `tests\PIM.F5.ValueTransformTests`.

## Migracije

Trenutni paket zajema migracije 001–100. Migrator sledi `dbo.SchemaMigration` in preveri hash vsake že uporabljene datoteke. Nameščenih migracij se ne ureja; popravek je vedno nova številka.

Hash (SHA-256) se od 2026-09-15 računa nad vsebino z normaliziranimi konci vrstic (CRLF → LF); pri primerjavi s starimi zapisi migrator sprejme tudi LF in CRLF različico surove vsebine, zato obstoječih ledgerjev ni treba popravljati. Razlog: git s `core.autocrlf` isto datoteko odloži enkrat z LF in drugič s CRLF, migrator pa je to prej javil kot »spremenjeno vsebino« in razveljavil ves paket (195_ReclaimStaleSendingDocuments.sql, lokalna baza DAVID\MSSQL19).

Ukazi migracij tečejo brez časovne omejitve (`CommandTimeout = 0`): podatkovne migracije, kot je 197 (brisanje ~6,5 GB `raw.Inbox.PayloadXml`), trajajo več minut, prejšnjih 120 s pa je skripto prekinilo in razveljavilo vse migracije v paketu. Če migrator obvisi, preveri blokade na `PIM.SchemaMigration` applocku, ne ponovnega zagona.

### Varni postopek

V PowerShellu na cilju nastavi skrivnost lokalno, nato v korenu `PIM_Solution`:

```powershell
$env:PIM_CONNECTION_STRING = '<lokalno-nastavljen-povezovalni-niz>'
$env:PIM_MIGRATIONS_PATH = 'C:\PIM\Source\NoviPIM\PIM_Solution\sql\migrations'
pwsh -File .\deploy\Apply-Migrations.ps1
pwsh -File .\deploy\Apply-Migrations.ps1
pwsh -File .\deploy\Apply-Migrations.ps1 -VerifyOnly
```

Dokaz uspeha:
1. prvi zagon uporabi samo manjkajoče migracije;
2. drugi zagon ne spremeni ničesar;
3. `--verify` izpiše `Preverjanje F0–F10 baze je uspešno.`

Pred migracijami vedno naredi COPY_ONLY backup z `deploy/Backup-PIM.sql` in preveri `RESTORE VERIFYONLY`.

## Dokazni podatkovni cikli

- F3: SAOP fixture → raw → mapiranje → kanonični katalog → CSV.
- F5: NW XML → EAN obogatitev kategorije, medija in atributa → validacija → promocija → B2C CSV; test preveri karanteno, manjkajoče obvezne vrednosti, neveljavno ceno/DDV/datum in deduplikacijo.
- F6: NW CSV in Braytron XML zaloge → `stock.LandingRecord`/snapshot/position → intranet read model.
- F7: B2B kupci, pravila popustov in CSV.
- F8: outbox le proti lokalnemu `127.0.0.1` fixture; dedup, retry, dead, sent, verified in drift.
- F9: watchdog, alarmi, lease/recovery in intranet integracije.

## Meje in tveganja

- Nove worker/input poti se dodajajo prek `map.*` konfiguracije in ne prek novih virsko-specifičnih tabel.
- Živi SAOP write-back, produkcijski endpointi in `PIM_test` niso del razvojnega dokaza.
- Testna konfiguracija in testne sledi se ne brišejo neposredno, če so povezane z `map.ExtractedValue`; zgodovina je namenoma zaščitena s tujimi ključi.
- Če integracijski test preseže SQL timeout, najprej preveri aktivne zahteve/blokade; ne zvišuj timeouta kot nadomestek za diagnostiko.

## Sledenje spremembam izdelkov

Migracija `028_AddProductChangeTracking.sql` uvaja sledljivost na dejanskem skupnem zapisovalnem sloju tega projekta, `canon.Product` in `canon.ProductCommercial` (ta rešitev nima tabel `stg.ProductCore`/`stg.ProductCommercial`).

- `pim.FieldOwnership` je register 17 sledljivih polj in trenutnega lastnika (`PIM`, `SAOP`, `SHARED`). Lastništvo je podatek in se ne podvaja v triggerjih.
- `pim.ProductChangeBatch` združi več polj ene poslovne akcije pod en `BatchId`.
- `pim.ProductFieldHistory` hrani polje, staro/novo vrednost, vir, izvajalca, čas in posnetek lastnika ob spremembi.
- množična triggerja nad `canon.Product` in `canon.ProductCommercial` primerjata `inserted`/`deleted` NULL-varno; brez razlik ne ustvarita prazne zgodovine;
- `pim.SetChangeContext` / `pim.ClearChangeContext` nastavita vir, izvajalca, paket in opombo na isti SQL povezavi kot zapis. Manjkajoč kontekst se pošteno zapiše kot `NEZNANO`.

`SqlMappingPipeline` za XML/SAOP mapping že nastavi `XML_FEED`, connector in `RunId`, zato se bodo novi mapping zapisi v zgodovini označili z resničnim virom. Sledljivost za nove nepovezane zapisovalne poti je treba dodati na njihovo lastno SQL povezavo; ne sme se jim pripisati lažen vir.

Migracija `029_AddProductHistoryIntranetReadModel.sql` doda zgodovino kot četrti rezultatni nabor `intranet.GetProductDetail`. Migraciji `030` in `031` popravita vrstni red `ROWCOUNT_BIG()`/`SET NOCOUNT ON` v triggerjih; sicer SQL Server po `SET NOCOUNT ON` vidi nič vrstic in bi sled tiho preskočil.

Migracije 032–038 dodajo omejeni poslovni Ctrl+Z: `pim.UndoProductField` in `pim.UndoProductBatch`. Pot preveri, da trenutna vrednost še ustreza izbrani spremembi, zavrne ponovno razveljavitev, prazen batch in SAOP/SHARED polja. `TRY/CATCH` pri obeh procedurah ob napaki rollbacka transakcijo in počisti `SESSION_CONTEXT`, da neuspešni undo ne kontaminira izvora naslednjega zapisa na isti povezavi. Trenutno sta eksplicitno podprti samo PIM-lastni polji `Product.WebPublish` in `Product.IsActive`; za novo polje je potreben nov preverjen poslovni adapter in test. Paketni undo uporabi eno transakcijo in en nov skupni undo batch.

`tests/PIM.ChangeTracking.Integration` je xUnit integracijski test (ni console proof) in pokriva uspešen undo polja, redo/conflict blokadi, skupni batch undo, SAOP/SHARED ownership blokado, prazen batch in čiščenje session konteksta po uspehu.

Migracija 034 razširi množično sledljivost na `canon.ProductText`, `canon.ProductAttribute` in `canon.ProductMedia`. Vrednosti so omejene na prvih 400 znakov prek `CONVERT(nvarchar(400), ...)`; za tekste se v zgodovini hrani kvalifikator `TextType.Lang`, za atribut koda atributa in za medij `Role.SortOrder`.

## Bralni model kartice izdelka

Migracija `100_ProductCardReadModel.sql` doda izključno bralni proceduri:

- `intranet.GetProductCard` vrne 15 imenovanih naborov: glavo z ločenima statusoma ERP in
  splet, ključna polja z lastnikom, čakajočo prekrivko iz obstoječe
  `intranet.GetPendingOverlay`, besedila, lastnosti, kategorije, medije, dokumente, cene,
  zalogo, trgovinske podatke, validacijske profile, odprte težave, odhodna sporočila in
  zgodovino;
- `intranet.GetProductOrigin` pove, iz katerega `raw.Inbox` teka, strani in zapisa je bila
  izluščena identiteta izdelka. Povezuje po dejanski `map.ExtractedValue` identiteti in vedno
  ohrani mejo `OrganizationId`.

Meritev na razvojnem izdelku `NW.9072` (ProductId 5971, organizacija 2): kartica je vrnila
vseh 15 naborov v 81 ms; izvor 28 vrstic v 869 ms. Neposredno iskanje identitete nad
837.404 vrednostmi `Product.ItemID` je pred migracijo trajalo 415 ms. Poskus materializiranega
indeksa nad `nvarchar(max)` je bil zavrnjen kot nesorazmeren, ker je prekinil povezavo med
gradnjo; migracija zato ne spreminja `map.ExtractedValue` in ostane lahka ter aditivna.

## Žig seje (migracija 181)

Pregled 2026-09-08 (`docs/PREGLED_SISTEMA_IN_UX_2026-09-08.md`, ugotovitev **A3**) je pokazal, da
onemogočen račun ostane prijavljen: `IsEnabled` in vloge se preberejo samo ob prijavi, piškotek pa
velja še 14 dni. Dokaz je bil `DISABLED_ACCOUNT_COOKIE {"Status":200,"Path":"/izdelki"}`.

Migracija `181_LocalUserSecurityStamp.sql` doda:

- `sec.LocalUser.SecurityStamp uniqueidentifier NOT NULL DEFAULT NEWID()` — žig veljavnosti seje;
- sprožilec `sec.TR_LocalUser_SecurityStamp` (AFTER UPDATE) zavrti žig ob spremembi `IsEnabled`,
  `PasswordHash`, `AuthSource` ali `DomainIdentity`; sprememba prikaznega imena ali e-pošte žiga
  namenoma **ne** zavrti, ker ne spremeni ničesar, kar bi seja smela početi;
- sprožilec `sec.TR_LocalUserRole_SecurityStamp` (AFTER INSERT, DELETE) zavrti žig ob vsaki
  spremembi vlog, da odvzeta vloga velja takoj;
- `sec.GetUserSecurityState @UserName` vrne `UserName`, `DisplayName`, `IsEnabled`, `SecurityStamp`
  in vloge kot `STRING_AGG` — to je bralni model, ki ga intranet uporabi ob preverjanju piškotka.

Zakaj sprožilca in ne klic iz aplikacije: račun se v praksi izklopi tudi neposredno v bazi (tako je
bil narejen dokaz A3). Če bi žig obnavljala samo aplikacija, bi taka sprememba ostala neopažena.

Dokaz nad razvojno bazo `PIM`: prvi zagon migratorja `Uporabljena migracija:
181_LocalUserSecurityStamp.sql`, drugi `Preskočena že uporabljena migracija`, `--verify`
`Preverjanje F0–F10 baze je uspešno.` Ročna preverba nad začasnim računom `qa_stamp_probe`
(ustvarjen in pobrisan v istem skriptu): sprememba imena žiga ne zavrti, `IsEnabled = 0` ga zavrti,
dodana vloga ga zavrti; `sec.GetUserSecurityState` vrne `IsEnabled = 0` in vlogi `ADMIN,VIEWER`.

## Spletišča izdelka (migracija 182)

Pregled 2026-09-08 (ugotovitev **D2**) je izmeril, da spletna profila validirata tudi izdelke, ki na
splet ne gredo: 883.587 in 873.812 odprtih napak na ~162.000 izdelkih z `WebPublish = 0`. Predlog
pregleda je bil obseg omejiti na `WebPublish = 1`.

**Uporabnik je to zavrnil** (2026-09-08, dobesedno): »ta webpublish to ne bomo več uporabljali in
bomo imeli polje oz morajo biti nekje check boxi ki bodo povedali, da gre artikel na svetila ali
videlektro in to se bo gledalo. Ta webpublish je iz SAOPja in je BV da ga pišemo nazaj lahko pa
naredimo nek programček, ki gleda in samo postavi na 1, če ima artikel check box označen.«

Migracija `182_ProductWebShopFlags.sql` zato uvede odločitev človeka namesto polja iz ERP:

- `pim.ProductWebShop (ProductId, WebShopCode, IsPublished, ChangedBy, ChangedUtc)` — ena vrstica
  na izdelek in spletišče. Koda spletišča je `canon.WebSite.CategoryTreeCode` (`svetila_si`,
  `videlektro`); isti ključ nosi `val.ValidationProfile.CategoryTreeCode` za spletna profila, zato
  nov register ni potreben in jezikovni različici spletišča (sl/en) delita eno oznako.
- `intranet.GetProductWebShops @ProductId` vrne **vsa** aktivna spletišča, tudi neoznačena —
  obrazec mora imeti tudi prazno potrditveno polje.
- `pim.SaveProductWebShops` zapiše oznake, pusti sled v `pim.ProductFieldHistory`
  (`FieldKey = ProductWebShop.<koda>`, `Owner = PIM`) in izdelek takoj revalidira.
- `val.RunValidation` upošteva oznako na **štirih** mestih: izbor zahtev, zapiranje zastarelih
  napak, izračun popolnosti po profilu in končno stanje izdelka. Pravilo je povsod isto: profil s
  `Scope = 'WEB'` velja samo za izdelek, ki je za njegovo spletišče označen.

**Začetno stanje.** `svetila_si` je napolnjen iz dodeljenih kategorij tega drevesa — **6.070**
aktivnih izdelkov. `videlektro` ostane **prazen**, ker v njegovem drevesu ni nobene dodeljene
kategorije in nihče ne more vedeti, kateri izdelki tja sodijo. To je namerno: dokler nekdo ne
označi, na videlektro ne gre nič. `WebPublish` se za polnjenje ni uporabil, ker ne loči spletišč.

**Dokaz.** Prvi zagon migratorja `Uporabljena migracija: 182_ProductWebShopFlags.sql`, drugi
`Preskočena že uporabljena migracija`, `--verify` »Preverjanje F0–F10 baze je uspešno.«
`docs/pregled-20260909/Preveri-Spletisca.ps1` = 10 preverb, vse OK; med njimi krog nad enim
izdelkom: 18 odprtih spletnih napak → odvzeta oznaka → **0** → vrnjena oznaka → **18**, z vrstico
v zgodovini in vrnjenim začetnim stanjem.

**Kar še ni narejeno.** Migracija **ne** požene validacije nad celotnim katalogom; učinek se pri
posameznem izdelku pokaže ob `pim.SaveProductWebShops`, pri celoti pa šele ob
`EXEC val.RunValidation` brez parametrov. Ta zagon zapre ~1,76 milijona spletnih napak na izdelkih,
ki na splet ne gredo, in je zato operativna odločitev, ne del migracije.

## Bralni model validacijskih težav je omejen (migracija 183)

Pregled 2026-09-08 (§5) je izmeril počasne strani. Meritev nad razvojno bazo 2026-09-09 je pokazala,
kje je čas: `intranet.GetValidationIssues` je za **eno** podjetje tekel **9.788 ms**, medtem ko so
`intranet.GetDashboard` 42 ms, `intranet.GetPipelineRuns` 2 ms in `intranet.GetSystemIntegrations`
1 ms. Nadzorna plošča postopek kliče enkrat na podjetje.

Vzrok ni bil načrt poizvedbe, ampak obseg: prvi nabor je vračal **vse** aktivne težave podjetja brez
`TOP` in brez strani — za podjetje 2 čez dva milijona vrstic. Edini odjemalec (`Dashboard.razor`)
iz odgovora bere samo drugi nabor (povzetek po profilih), zato se je dva milijona vrstic preneslo
čez povezavo, sestavilo v seznam predmetov in zavrglo.

Migracija `183_ValidationIssuesReadModelBounded.sql` doda `@Take int = 200`; `@Take = 0` pomeni
»samo povzetka«. Razvrstitev dobi še `ProductIssueId`, sicer meja pri enakih časih ni ponovljiva.
Podrobni seznam s stranmi in filtri je in ostaja `intranet.GetQualityIssues` (`/kakovost/napake`).

Dokaz: postopek 9.788 ms → **714 ms** (`@Take = 0` → 596 ms, podjetje 1 → 207 ms); nadzorna plošča
8,84 s → **4,47 s** (strežniški izris, brez brskalnika). Prvi zagon migratorja `Uporabljena
migracija`, drugi `Preskočena že uporabljena migracija`, `--verify` uspešen.

**Naslednje ozko grlo, še neodpravljeno.** `sys.dm_exec_query_stats` kaže poizvedbo s povprečjem
**2.866 ms na zagon** in 75 zagoni v dvajsetih minutah: `STRING_AGG` nad `canon.FieldValue`, ki je
**pogled**, ne tabela. Uporabljajo ga `val.RunValidation`, `intranet.GetProductFieldValues`,
`out.GetExportRows` in `intranet.GetProductExportSheet`. To je največji posamični strošek v sistemu
in zasluži svojo nalogo.

## Vrednosti atributa (migraciji 184 in 185)

`/nastavitve/atributi/{koda}` je bila po pregledu 2026-09-08 brez vsebine. Vzrok ni bila stran —
napisana je v celoti, s tabelo, stranmi in poštenim `<PimMissing>` — ampak manjkajoč bralni model
`intranet.GetAttributeValues`. Migracija **184** ga doda: po vrstici na različno vrednost atributa
v podjetju, s številom izdelkov, prevodom iz `map.ValueLookup`, virom, oznako uporabe na spletu in
številom manjkajočih prevodov, ter drugim naborom s skupnim številom.

Migracija **185** popravi **napako iz 184, ki jo je razkrila meritev.** 184 je vir posamezne
vrednosti iskala s korelirano podpoizvedbo `TOP (1)` nad `map.ExtractedValue`. Ta tabela ima
**20.252.420 vrstic** in **nima indeksa na `TargetFieldCode`**, zato je vsaka vrstica strani
sprožila svoj pregled cele tabele:

| | `@Take = 5` | `@Take = 50` (velikost strani) |
|---|---:|---:|
| Podjetje 1 | — | **96.506 ms** |
| Podjetje 2 | 784 ms | **271.595 ms** |

Indeksa na `map.ExtractedValue` namenoma nisem dodal: to je vhodna tabela, v katero zajem piše v
velikih svežnjih, indeks nad `TargetFieldCode` z vključenim `Value` pa bi podražil vsak zapis.
Namesto tega vir pride iz **registra** — kateri konektorji tega podjetja imajo preslikavo za ta
atribut (`map.FieldMapping` + `map.SourceConnector`). Vir na posamezno vrednost je bila izmišljena
natančnost: stran ima stolpec »Vir«, ne »Vir te vrednosti«.

Po popravku: **75 ms** (podjetje 1) in **64 ms** (podjetje 2) pri `@Take = 50`; stran **60,1 s →
0,1 s**, 50 vrstic in naslov »Vrednosti atributa Garancija«. Migrator: prvi zagon uporabljen, drugi
preskočen, `--verify` uspešen.

## Sočasnost pri urejanju kartice (migracija 186)

Pregled 2026-09-08 (P3-17): »`rowversion` na `pim.*` in pričakovana vrednost v
`SaveProductTexts/Attributes`; kartica pokaže konflikt s tujo vrednostjo«. Do te migracije sta se
dva urednika tiho prepisala — kartica je poslala novo vrednost, procedura jo je zapisala in nihče
ni izvedel, da je nekdo vmes isto polje že spremenil. Zgodovina je to zabeležila šele potem, ko je
bilo delo izgubljeno.

**Merilo ni `rowversion`, ampak pričakovana vrednost polja.** `rowversion` na `canon.ProductText`
bi se spremenil ob vsakem zapisu katerekoli vrstice izdelka, tudi če se polje, ki ga urednik ureja,
sploh ni dotaknilo — dobili bi lažne konflikte. Vrednost polja pove natanko to, kar urednik vidi.

- `@ChangesJson` sprejme `expected` in `hasExpected`. Kdor ju ne pošlje (`hasExpected` odsoten
  ali 0), dobi natanko dosedanje vedenje — zato uvoz delovnega zvezka, ki ima svoje pravilo
  »prazna celica = ne dotakni se«, ostane nespremenjen. Kartica ju pošlje vedno.
- Konflikt **ni napaka**: sporne vrstice se preskočijo, ostale se zapišejo. Vse ali nič bi
  pomenilo, da en konflikt zavrže deset dobrih popravkov.
- Prvi nabor dobi `ConflictCount`, drugi pa `FieldKey`, `Expected` in `TheirValue`.

**Dokaz nad razvojno bazo** (izdelek 2, polje `ProductText.WEB_TITLE.sl`, izhodiščno prazno):
urednik B shrani »Vrednost urednika B« → `ChangedCount = 1, ConflictCount = 0`. Urednik A nato
shrani in pošlje `expected = ""` (kar je videl) → `ChangedCount = 0, ConflictCount = 1`, sporno
polje `ProductText.WEB_TITLE.sl` s `TheirValue = Vrednost urednika B`. V katalogu ostane B-jeva
vrednost; **A je ne povozi več**. Izhodiščno stanje je bilo po preizkusu vrnjeno.
Migrator: prvi zagon uporabljen, drugi preskočen, `--verify` uspešen.

## Popravek zaloge po podjetjih (migracija 191)

Uporabnik, dobesedno: »zakaj zaloga dela samo za Vidadrio, mora delati za vsa podjetja«. Vzrok ni
bil manjkajoč podatek (vsa štiri podjetja imajo aktivne posnetke), ampak nestabilen načrt
poizvedbe: `intranet.GetStockByItem` (migracija 190) je isto zapleteno združevanje sklicevala
dvakrat (enkrat za stran, enkrat za števec), brez `OPTION (RECOMPILE)` na glavni poizvedbi pa je
SQL Server včasih ponovno uporabil načrt, sestavljen za prejšnje, drugačno podjetje — klasičen
parameter sniffing. Blazor stran je vse napake lovila v en splošen »Zaloge trenutno ni mogoče
naložiti« (`Stocks.razor`), zato je bil časovno prekoračen klic viden kot »za to podjetje ne
dela«, ne kot počasna poizvedba.

**Objekti:** `intranet.GetStockByItem` (procedura, `CREATE OR ALTER`) — brez sprememb sheme.
Popravek zbere enkrat v začasno tabelo `#StockByItem` z `OPTION (RECOMPILE, MAXDOP 1)`, enak vzorec
kot migracija 150 (`intranet.GetPriceChecks`/`#PriceChecks`).

**Ročni korak po uvedbi: ni potreben.** Migracija samo zamenja telo procedure; nič podatkov se ne
polni ročno. Po uvedbi velja preveriti vsa štiri podjetja (ne samo `MIN(OrganizationId)`) — ravno
to je bilo prej neopaženo.

## Napaka in vzrok zavrnitve v čakalni vrsti (migracija 192)

Uporabnik je vprašal: če SAOP zavrne dokument, ali se to pokaže kot napaka in ali uporabnik vidi
razlog? `out.CompleteItemDocument`/`out.CompleteMessage` sta `Status`, `LastError` in
`SaopErrorKind` na `out.OutboxMessage` pisala že prej pravilno — samo
`intranet.GetOutboundMessages` (torej Čakalna vrsta/Zgodovina) teh dveh stolpcev ni brala. Enak
vzorec kot migracija 187 (`ApprovedBy`/`SentUtc`).

**Objekti:** `intranet.GetOutboundMessages` (procedura, `CREATE OR ALTER`) — doda `LastError` in
`SaopErrorKind` v izhodni nabor. Brez sprememb sheme.

**Ročni korak po uvedbi: ni potreben.**

## Prevzem točno izbranega artikla pri ročnem pošiljanju (migracija 193)

Uporabnik je opozoril, da pošiljanje iz vmesnika (klik »Odobri« ali »Pošlji zdaj« na eni vrstici)
prevzame najstarejši artikel v celi vrsti (`out.ClaimItemDocument`, migracija 084) — ne tistega, ki
ga je uporabnik pravkar odobril. Za avtomatiziran worker v ozadju je to pravilno (pravično, po
vrstnem redu); za klik na eno vrstico v vmesniku pa uporabnik pričakuje natanko to, kar je izbral.

**Objekti:** nova procedura `out.ClaimItemDocumentByKey` — enaka `out.ClaimItemDocument`, samo da
namesto `TOP(1)` po celi vrsti prevzame vsa čakajoča sporočila danega artikla (organizacija +
šifra). `out.ClaimItemDocument` (worker CLI/ozadje) ostane nedotaknjena. Klicatelja:
`SaopDocumentRunner.SendOneAsync` (`PIM.Outbound`).

**Ročni korak po uvedbi: ni potreben**, a nova procedura in koda, ki jo kliče, morata biti
uveljavljeni skupaj — brez migracije 193 `SendOneAsync` pade na neobstoječo proceduro.

## Kakovost podatkov po kanalih in neobhodna ERP zapora (migracija 194)

Tehnična karantena `raw.Inbox` ostane namenjena zapisom, ki niso prišli do PIM-a. Artikel, ki v
PIM-u obstaja, po tej migraciji dobi pripravljenost po kanalu (ERP/WEB) in po potrebi ročni
zadržek. `ERP_L1` je stari validacijski profil; naslednika `ERP_L1_SLO`/`ERP_L1_EU`/`ERP_L1_THIRD`
sta vir resnice.

**Objekti:**
- `val.ValidationProfile`, `val.ProductIssue` — **podatkovna sprememba znotraj same migracije**:
  `ERP_L1` se deaktivira (`IsActive = 0`), njegove odprte napake se zaprejo. Stari profil se fizično
  ne briše (nanj so vezane revizijske in zgodovinske vrstice).
- `val.ProductHold` — **nova tabela** (ročni zadržek po artiklu in kanalu `ALL/ERP/WEB`); ob
  uvedbi prazna, brez seed podatkov.
- `val.IsProductChannelReady` — nova funkcija; `val.ProductChannelReadiness` — nov bralni pogled;
  `intranet.GetQualityProducts` — nova procedura za `QualityProducts.razor` (klicatelj:
  `QualityReadService.cs`); `val.SetProductHold` — nova procedura za ročno postavljanje/sproščanje
  zadržka (klicatelj: `QualityWriteService.cs`).
- `out.TR_OutboxMessage_ErpQualityGate` — nov sprožilec na `out.OutboxMessage` (AFTER
  INSERT/UPDATE): artikel, ki ni pripravljen za ERP (blokirajoča napaka ali ročni zadržek), se ne
  more vstaviti/posodobiti v izhodno vrsto proti SAOP-u. Pokrije enqueue, odobritev, retry in oba
  načina prevzema (084 in 193).

**Ročni korak po uvedbi: ni potreben.** Migracija na koncu sama pokliče `EXEC val.RunValidation`
(cel katalog se ponovno ovrednoti, da upokojitev starega profila velja takoj) in se sama preveri:
`THROW`, če je `ERP_L1` še aktiven ali če bralni model pripravljenosti manjka. Edini prihodnji ročni
korak ni del te migracije: če kdo želi ročno pregledati/sprostiti zadržke po uvedbi, to naredi prek
`/kakovost/izdelki` (`val.SetProductHold`), ne neposredno v tabeli.

## MID prag in predlagane vrednosti MIN/MID/MAX (migracija 198)

Izhodišče je `MIN_MAX_proces.docx` (sestanek + Lukini zapiski): PIM naj MIN/MAX ne nastavlja
ročno, ampak ju izračuna iz prodajnih analitik in predlaga, samo za artikle razreda A/B. Luka je
predlagal tretji prag MID, viden samo v PIM ("MAX, potem pa nek MID, ki bi bil viden samo v PIM,
ter MIN, ki bi bil v sistemu"). Uporabnik je potrdil, da ta faza ostane pri "samo predlog" — brez
pisanja nazaj v SAOP, kar ohranja obstoječo odločitev iz migracije 103 ("Zaloga ostaja izrecno
samo bralna").

**Objekti:**
- `canon.ProductStockPolicy` — **nova polja**: `MidStock` (potrjena vrednost tretjega praga, samo
  PIM) ter `SuggestedMinimumStock`/`SuggestedMidStock`/`SuggestedMaximumStock` +
  `SuggestionCalculatedUtc`/`SuggestionMethod` (izračun PIM, ločen od `MinimumStock`/
  `MaximumStock`, ki ostajata nespremenjena kopija iz SAOP-a). SAOP nima MID polja (potrjeno v
  `SAOP_API_swagger_v2.json`, `ItemWarehouseData`), zato MID ne more nikoli oditi nazaj v SAOP.
- `pim.FieldOwnership` — `CK_PimFieldOwnership_Location` razširjen z `canon.ProductStockPolicy`;
  4 nova polja registrirana z `Owner = PIM` (`StockPolicy.MidStock`,
  `StockPolicy.SuggestedMinimumStock`, `StockPolicy.SuggestedMidStock`,
  `StockPolicy.SuggestedMaximumStock`).
- Sprožilec za zgodovino sprememb (`canon.TR_ProductStockPolicy_FieldHistory`, po vzoru
  `TR_Product_FieldHistory` iz migracije 028) se **namenoma še ne doda** — pride skupaj s
  shranjevalno potjo/UI za potrditev predloga v naslednji fazi. Do takrat registracija v
  `pim.FieldOwnership` ne prime nobenega zapisa (varno, a neaktivno stanje).

**Ročni korak po uvedbi: ni potreben.** Nova polja so prazna (`NULL`) do naslednje faze
(izračun predlogov + UI). Konkretna formula izračuna MIN/MID/MAX (dnevi pokritja po dobavitelju)
še ni dogovorjena z nabavo/prodajo — to je odprto vprašanje iz `MIN_MAX_proces.docx`, ne del te
migracije.

## Pristajanje naročil kupcev (VNK) in naročil dobaviteljem (VND) (migracija 199)

Za ABC klasifikacijo in izračun MIN/MID/MAX (`MIN_MAX_proces.docx`) rabimo prodajno zgodovino in
odprta naročila, ki jih PIM prej sploh ni hranil. Endpointi in XML oblika so preverjeni z živimi
primeri iz SAOP swaggerja (2026-09-14), ne samo s shemo — shema swaggerja zavaja glede imena korena
(`OrderHeaderDetail`/`PurchaseOrderHeaderDetail` v shemi, `<OrderHeader>`/`<PurchaseOrderHeader>` v
živem odgovoru) in glede oblike zaporedne številke vrstice (`@OrderLineNo` je pri VNK XML atribut,
`LineSEQNumber` pri VND pa navaden element).

Prvotno nartovan tretji tok (`GetOrderRealisation` za prodajno realizacijo) je uporabnik po pregledu
odločil, da se ne gradi: `GetOrder` že vrne `Qty`/`ShippedQTY` na vsaki vrstici, kar je natanko to,
kar bi realizacija dodatno prinesla. Prodajna zgodovina za ABC/formulo se zato računa neposredno iz
`sales.OrderLine`, ne iz ločene tabele — to je bil tudi edini del brez živega primera (ugibana oblika
XML), tako da odstranitev pomeni manj kode in manj tveganja hkrati.

**Objekti:**
- `sales.OrderHeader`/`sales.OrderLine` — naročila kupcev (VNK), iz `api/Order/GetOrder`.
- `purch.PurchaseOrderHeader`/`purch.PurchaseOrderLine` — naročila dobaviteljem (VND), iz
  `api/PurchaseOrders/GetPurchaseOrder`. **VND je ločen SAOP modul od `Order`** — prvi poskus branja
  VND iz `/api/Order/*` je bil napačen (ne napaka SAOP-a), razčiščeno pri pregledu swaggerja.
- `map.EntityMapping`/`map.FieldMapping` — dva nova svetova (`SalesOrder`, `PurchaseOrder`)
  registrirana na vseh aktivnih SAOP konektorjih (`CK_EntityMapping_TargetDomain` razširjen). Glava
  in vrstice se pristanejo iz istega `raw.Inbox` zapisa: `RecordXPath` kaže na ponavljajočo se
  vrstico, polja glave se berejo relativno navzgor (`../../`, vzorec iz migracije 076/072) in so
  podvojena na vsaki vrstici istega naročila.
- `map.ProcessSalesOrderInbox`, `map.ProcessPurchaseOrderInbox` — nove procedure, registrirane tudi
  v `MappingProcedures.All` (`src/PIM.XmlMapping/MappingProcedures.cs`) — brez te registracije bi
  bili podatki v registru, tabele pa prazne (natanko napaka, ki jo ta seznam po lastnem komentarju
  preprečuje, iz izkušnje z migracijo 082).
- `ops.ScheduleProfile` — nov razpored `SAOP_ORDERS` (uro, 3600 s) za vsako organizacijo z aktivnim
  SAOP konektorjem, `IsEnabled=1`. Brez tega bi `ops.BeginRun` za nov delavec vrgel napako 51100
  ("Razpored ni omogočen"), tudi ob ročnem zagonu.

**Nepotrjeno, preveriti na prvem živem teku delavca:** `@OrderLineNo` (atribut na `<OrderLine>` pri
VNK) je prva raba atributnega XPath v tem cevovodu — tehnično podprto (`System.Xml.XPath`), a brez
predhodnega testa. **Še vedno nepotrjeno na 2026-09-14**: delavec (`workers/PIM.SaopOrdersWorker`,
glej spodaj) je zgrajen in zagnan, a servisni račun `ApiMagento` (edine SAOP poverilnice, ki jih PIM
danes ima) nima dostopa do `Order`/`PurchaseOrders` modulov — potrjeno z neposrednim klicem
(`GetPurchaseOrder` vrne `<ArrayOfError/>`, `GetPurchaseOrdersStatus` prazen seznam, čeprav znano
naročilo obstaja). Dokler kdo temu računu v SAOP-u ne odpre dostopa (ali ne da drugih poverilnic),
`sales.OrderLine`/`purch.PurchaseOrderLine` ostaneta prazna in atributni XPath ostaja neprepreverjen.

**Delavec je zdaj zgrajen**: `workers/PIM.SaopOrdersWorker` — odkritje prek `GetOrderStatus`/
`GetPurchaseOrdersStatus` (samo ključi sprememb od vodnega žiga), nato `GetOrder`/`GetPurchaseOrder`
po ključu za podrobnosti. Knjiga (`SalesOrderBook`/`PurchaseOrderBook`, npr. "VNK"/"VND") se nastavi
**po organizaciji** v `appsettings.Local.json` pod `Saop:Organizations` — ni univerzalna konstanta,
organizacija brez nastavljene knjige se pri tistem toku tiho preskoči. Prvi zajem (brez vodnega žiga)
je omejen na zadnjih 24 mesecev (`InitialBackfillMonths`), ne na vso zgodovino.

**Ročni korak po uvedbi: ni potreben za shemo.** Za dejanski zajem: (1) nastaviti knjigo po
organizaciji v `appsettings.Local.json`, (2) urediti dostop računa `ApiMagento` v SAOP-u do
`Order`/`PurchaseOrders` — glej zgornji odstavek.

## Zaloga pod MID: izračun, poizvedba in dnevni e-mail po dobavitelju (migracija 200)

Konkretna v1 formula in vsebina maila (MIN_MAX_proces.docx, uporabnikova zahteva 2026-09-14, ne več
odprto vprašanje): `MidStock` = zaokroženo na celo število povprečje `MinimumStock`/`MaximumStock`
(obstoječi, iz SAOP prek migracije 076). Opozorilo gre, ko razpoložljiva zaloga <= `MidStock`.
Razpoložljiva zaloga = trenutna zaloga (`stock.Position`) MINUS odprta količina na naročilih kupcev
(`sales.OrderLine`, `ClosedLine=0`) — VND je samo informativni stolpec v mailu, ne vstopa v primerjavo.

Prejemniki so PIM uporabniki s kljukico, ne dobaviteljevi kontakti (tistih PIM ne hrani) —
uporabnikova izrecna zahteva. "ABC klasifikacija" v mailu je namenoma `canon.Product.Department`:
prava izračunana ABC klasifikacija (Faza 3 načrta `MIN_MAX_proces.docx`) še ne obstaja, Department pa
je že v obstoječem UI označen kot "ABC klasifikacija/Oddelek" (`SaopFieldLabels.cs`) — ista
poenostavitev, ne nova.

**Objekti:**
- `sec.LocalUser.ReceivesStockReplenishmentEmail` — nov stolpec (bit, privzeto 0). Ločen od
  obstoječega `Email` polja (opozorila): kljukica pove, ali uporabnik prejema TA specifičen mail, ne
  vsa opozorila. UI: `Sistem → Uporabniki`, nov stolpec "Zaloga pod MID"
  (`IntranetUserAdministrationService.SetStockReplenishmentSubscriptionAsync`).
- `stock.RefreshStockPolicyMid` — nova procedura, osveži `MidStock` za vse vrstice z nastavljenima
  `MinimumStock`/`MaximumStock`.
- `stock.GetBelowMidReplenishment @OrganizationId` — nova procedura, vrne artikle na/pod MID pragom
  z dobaviteljem, oddelkom, trenutno zalogo, MAX/MID/MIN in odprto VND količino (informativno).
- `ops.ScheduleProfile` — nov razpored `STOCK_REPLENISHMENT_DIGEST` (enkrat na dan, 86400 s) za vsako
  organizacijo z aktivnim SAOP konektorjem.

**Nov delavec**: `workers/PIM.StockReplenishmentWorker` — osveži MID, prebere artikle pod pragom,
sestavi HTML (po dobavitelju → kategoriji → tabeli), pošlje vsem s kljukico (ali zapiše "danes ni
nič", če seznam prazen — po uporabnikovi izrecni zahtevi, mail gre ven vsak dan ne glede na vsebino).
Isti SMTP/Resend prevoznik in iste okoljske spremenljivke kot `PIM.AlertDispatcher.EmailAlertSender`
(namenoma podvojeno, ne deljeno — glej `DigestEmailSender.cs`). `--dry-run` zapiše HTML v datoteko
namesto pošiljanja.

**Preverjeno na živi razvojni bazi (2026-09-14, s pravimi podatki):** `stock.RefreshStockPolicyMid`
je osvežil 2120 vrstic; `stock.GetBelowMidReplenishment` za organizacijo 2 (IQLighting) je pravilno
vrnil 74 artiklov pri 3 dobaviteljih, pravilno razvrščenih; `PIM.StockReplenishmentWorker --dry-run`
je sestavil pravilen HTML. Mimogrede odkrito pri istem preverjanju: nekateri SAOP zapisi imajo
`MinimumStock > MaximumStock` (npr. MIN=60, MAX=0) — verjetno napaka vnosa v SAOP, ne v tej kodi;
formula to vseeno izračuna dosledno, vredno pa je preveriti pri nabavi.

**Ročni korak po uvedbi:** nihče privzeto ni odkljukan za ta mail — po uvedbi mora administrator v
`Sistem → Uporabniki` odkljukati vsaj enega uporabnika z nastavljenim naslovom e-pošte, sicer
delavec vsak dan "pošlje" na 0 naslovov. Pošiljanje e-pošte je poleg tega globalno izklopljeno,
dokler `PIM_ALERT_EMAIL_ENABLED=true` ni nastavljen (isto stikalo kot `PIM.AlertDispatcher`).

## Ime dobavitelja in popravki izpisa v stock.GetBelowMidReplenishment (migracija 202)

Tri popravke je uporabnik zahteval po ročnem pregledu rezultatov na 2026-09-15:

1. **Ime dobavitelja manjkalo** — `canon.Product.Supplier` je surova SAOP šifra partnerja (npr.
   `91086973`), ne ime. Ime je že sinhronizirano ločeno v `canon.PartnerName`
   (`OrganizationId`, `PartnerCode`, `PartnerName` — ista šifra kot pri strankah/dobaviteljih).
   Nov stolpec `SupplierName` je dodan z `LEFT JOIN` nanjo.
2. **Naziv artikla nedosleden po jeziku** — `canon.ProductText` je večjezičen (`Lang` stolpec), a
   prvotna različica te procedure ni izbirala po jeziku, zato je `TOP(1)` naključno vrnil nemški/
   angleški/slovenski zapis za različne vrstice. Popravljeno: po tipu besedila (`TITLE_ERP` pred
   `WEB_TITLE`) prednost zdaj dobi `Lang = 'sl'` — isti vzorec kot obstoječi
   `intranet.GetStockPositions` (migracija 103).
3. **Štiri decimalke namesto dveh** — količinski stolpci (`CurrentStock`, `MaximumStock`,
   `MidStock`, `MinimumStock`, `AvailableStock`, `IncomingPurchaseQty`) so zdaj `CONVERT(decimal(19,2), ...)`
   samo za izpis tega poročila. Osnovne tabele (`canon.ProductStockPolicy` ipd.) ostanejo pri
   `decimal(19,4)` — to ni sprememba podatkovnega modela, samo predstavitve.

**Objekti:** `stock.GetBelowMidReplenishment` (`CREATE OR ALTER`, brez sprememb sheme).

**Ročni korak po uvedbi: ni potreben.**

## Katalog in stranke za splet: kljukica, aktivnost, validacija (migracija 201)

Uporabnik 2026-09-14: »Naredi to da se bo sam zaganjal in dal artikle v katalog. Ampak morajo iti
artikli, ki so aktivni, ki imajo kljukico svetila ali videlektro in pa potem morajo imeti narejeno
validacijo.« In za stranke: »isto preveri in naredi da bo delalo za stranke«.

Stanje pred migracijo (razvojna baza, 2026-09-14):

- `out.GetExportRows` je izdelek za splet izbiral po SAOP polju `canon.Product.WebPublish`, ki ga je
  uporabnik ob migraciji 182 zavrnil; kljukic iz `pim.ProductWebShop` in `canon.Product.IsActive`
  ni gledal.
- Stranka je šla v stranke.csv samo po `pim.CustomerWebProfile.WebEnabled` — tudi neaktivna in tudi
  brez tipa (kartica stranke oznako Splet dovoli brez tipa, pravilo iz 098 pa pravi »stranka brez
  tipa v izvoz ne sme«).
- `PIM.B2bWorker` od istega dne vsak zagon začne z `ops.BeginRun`, ki brez vrstice v
  `ops.ScheduleProfile` pade z 51100. Vrstici `MAGENTO_PRODUCTS`/`MAGENTO_STOCK_PRICES` sta bili
  samo ročno v bazi namenskega strežnika, zato bi urni `Katalog-cikel.ps1` na razvojni bazi padel.
- Na razvojnem računalniku ni registrirano nobeno opravilo `PIM*`; zadnji izvoz v `izvoz\magento\`
  je bil 2026-09-09.

**Pravilo po migraciji.** Spletna stran S je za izdelek dovoljena, če ima izdelek kategorijo na S,
je aktiven, ima kljukico za drevo strani S (`svetila_si` → svetila_si/svetila_si_en, `videlektro` →
B2C/B2C_EN), nima spletnega zadržka (194) in je — pri `RequireWebValid = 1`, torej
`MAGENTO_PRODUCTS` — `VALID` v vseh aktivnih profilih, ki za S blokirajo splet (`SHARED_CORE` +
`WEB_<drevo>`). Stranka gre v izvoz, če je aktivna, ima oznako Splet in ima tip.

**Objekti:**
- `out.GetExportRows` — v izboru strani (B0) je `canonProduct.WebPublish = 1` (dvakrat: pri
  `@OnlyPublished` in pri `@RequireWebValid`) zamenjan z »aktiven + kljukica za drevo strani«; v
  izboru strank je `WebEnabled = 1` (dvakrat) razširjen z `b2b.Customer.IsActive = 1` in
  `CustomerTypeCode IS NOT NULL`. Po vzoru 194 prek `OBJECT_DEFINITION` + `REPLACE`; migracija pred
  zamenjavo prešteje obe mesti in pade, če definicija ni pričakovana.
- `intranet.GetExportReadiness` — števci na `/splet` po istem pravilu (z zadržkom iz 194):
  `WebFlaggedCount` = aktivni s kljukico, `WebExportableCount` = vrstice v katalog.csv.
- `ops.ScheduleProfile` — **podatkovna sprememba znotraj migracije**: `MAGENTO_PRODUCTS` (3600 s) in
  `MAGENTO_STOCK_PRICES` (300 s), `Provider = MAGENTO`, za vsako podjetje, kjer vrstica še ne
  obstaja. Obstoječa vrstica (namenski strežnik), tudi izklopljena, ostane nedotaknjena.
- Brez sheme: `PIM.B2bWorker` dobi stikalo `--osvezi-validacijo` (pred izvozom `val.RunValidation` +
  `val.Promote`), `deploy/Configure-WorkerScheduledTasks.ps1` ga poda nalogi `PIM-MagentoProducts`
  (glej `docs/WORKERS.md`).

**Dokaz (razvojna baza, 2026-09-14).** Migracija uveljavljena v transakciji (3,3 s) in ponovljena
brez sprememb. `PIM.B2bWorker --export-magento --osvezi-validacijo --organization-id 2`: izhod 0,
520 s. Vsaka vrstica katalog.csv preverjena proti bazi: **2.176** vrstic, 0 neaktivnih, 0 brez
kljukice, 0 ne-`VALID`, 0 izdelkov, ki po pravilu sodijo v datoteko, a jih ni; `/splet` *V datoteki*
= 2.176. Preverba pravila nad istim postopkom z začasnimi podatki (na koncu pospravljeni): izdelek
brez kljukice izpade iz katalog.csv in iz datoteke cen/zaloge, kategorija na B2C brez kljukice
videlektro ne pride v izvoz, stranka izpade, če ni aktivna, nima tipa ali nima oznake Splet —
12/12 OK. Cel urni cikel `Katalog-cikel.ps1` (vsa 4 podjetja, validacija + objava + izvoz): 1.051 s,
0 padlih korakov, `out.ExportRun` = Succeeded (215 stolpcev), vsaka datoteka v `izvoz\magento\1–4`
preverjena vrstico za vrstico; validacija + objava zavzame skoraj ves čas (podjetje 2: 7 min 45 s,
izvoz 23 s). 219 izdelkov iz katalog.csv podjetja 2 ima `WebPublish = 0` in bi po starem pravilu izpadlo; noben izdelek, ki je
šel ven po starem pravilu, po novem ne izpade (182 je kljukico svetila_si napolnila iz dodeljenih
kategorij). Po podjetjih (aktivni s kljukico → v katalogu): 1 = 1.147 → 422, 2 = 2.371 → 2.176,
3 = 2.551 → 2.418, 4 = 0 → 0; razlika so izdelki, ki niso `VALID` za `WEB_svetila_si`. Na videlektro
ni označen noben izdelek. Stranke: nobena nima tipa (in nobena `WebEnabled = 1`), zato je
stranke.csv prazen, dokler na kartici stranke nekdo ne nastavi tipa in oznake Splet.

**Ročni korak po uvedbi.** Za bazo **ni potreben** (migracija se sama preveri in izvede oba
postopka). Na namenskem strežniku po `git pull` ponovno poženi
`deploy\Configure-WorkerScheduledTasks.ps1 -InstallRoot ... -ExportRoot ...`, da se `PIM.B2bWorker`
ponovno objavi in naloga `PIM-MagentoProducts` dobi `--osvezi-validacijo`. Na razvojnem računalniku
je 2026-09-14 registrirana samo naloga `PIM katalog` (vsako uro, `Katalog-cikel.ps1`, uporabnik
`AD\david`); petminutne »PIM zaloga« uporabnik ni želel, ker validacija vseh štirih podjetij traja
~16 min, SAOP pa že kliče strežnik. `scripts\Namesti-opravila.ps1` registrira z `DOMENA\uporabnik`
(samo `$env:USERNAME` Windows na domenskem računalniku zavrne).

## Stranke za splet samo po aktivnosti (migracija 202)

Uporabnik 2026-09-15: »stranke ne bodo mela kljukice splet, samo aktivnost, če imajo, drugače ne.
Ta splet kljukica se tiče samo artiklov.« Migracija 201 je stranko spustila v stranke.csv samo z
aktivnostjo + oznako Splet + tipom; ker nobena od ~4.400 aktivnih strank nima tipa, je bila datoteka
prazna. Po 202 gre v stranke.csv vsaka stranka z `b2b.Customer.IsActive = 1`. Tip ostane podatek na
kartici (določa Magento skupino v datoteki), ni pa pogoj; stranka brez tipa gre ven s prazno skupino.

**Objekti:**
- `out.GetExportRows` — filter strank `(profile.WebEnabled = 1 AND customer.IsActive = 1 AND
  profile.CustomerTypeCode IS NOT NULL)` (dvakrat: števec in stran) zamenjan s
  `customer.IsActive = 1`. Po vzoru 194/201 prek `OBJECT_DEFINITION` + `REPLACE`, s štetjem mest
  pred zamenjavo. Migracija se na koncu sama preveri: število vrstic izvoza mora biti enako številu
  aktivnih strank s profilom.
- Brez sheme: kartica stranke ne kaže več potrditvenega polja »Splet omogočen«, seznam strank ne
  stolpca »Splet« (`CustomerDetail.razor`, `Customers.razor`). Stolpec `pim.CustomerWebProfile.WebEnabled`
  in parameter `b2b.SaveCustomerWebProfile @WebEnabled` ostaneta (kartica pošlje obstoječo vrednost).

**Dokaz (razvojna baza, 2026-09-15).** Migracija uveljavljena in ponovljena brez sprememb; podjetje
2: 3.988 strank v izvozu = 3.988 aktivnih. Test F7 (`PIM.F7.MagentoExportTests`): neaktivna stranka
izpade, aktivna brez tipa in brez oznake Splet je v izvozu.

**Ročni korak po uvedbi: ni potreben.** Stranke.csv se napolni ob naslednjem urnem ciklu.

## Postopek uvedbe brez celotne aplikacije

Ni nujno vedno objaviti/prenesti celoten `PIM.Intranet` build, da pridejo v produkcijo samo
spremembe sheme: `PIM_Solution/sql/migrations/*.sql` se lahko potisne na GitHub in požene samostojno
z `deploy/Apply-Migrations.ps1` (glej »Varni postopek« zgoraj) — Migrator je majhno, neodvisno
orodje, ki bere samo `sql/migrations` in ne potrebuje objavljenega `PIM.Intranet`. Konvencija za
vsako novo migracijo naprej:

1. Datoteka gre v `PIM_Solution/sql/migrations/NNN_Opis.sql`, naslednja prosta številka, idempotentna
   (`CREATE OR ALTER`, `IF OBJECT_ID(...) IS NULL BEGIN CREATE TABLE ... END`) in se na koncu sama
   preveri (`THROW` ob neuspehu) — obstoječi vzorec vseh migracij v tej mapi.
2. V ta dokument (`docs/DATABASE.md`) pride nov razdelek: kaj in zakaj (uporabnikova beseda, če
   obstaja), **Objekti** (katere tabele/procedure/poglede/sprožilce migracija dotakne) in **Ročni
   korak po uvedbi** — če migracija zahteva, da nekdo po uvedbi ročno napolni tabelo (INSERT, npr.
   nastavitveni/konfiguracijski podatki) ali sproži proces (EXEC procedure, npr. enkratni
   backfill), to je tu izrecno napisano, sicer piše »ni potreben«.
3. Če manjka ročni korak in ga migracija ne more sama izvesti varno v vseh okoljih (npr. vrednost
   je specifična za produkcijo), skript zanj priloži SQL (INSERT/EXEC) v samem razdelku, ne samo
   besedo.

## Stopnjevanje odhodnih napak z dolgim imenom polja (migracija 209)

Najdeno 2026-09-15, ko so bile naloge Windows znova registrirane: »PIM nadzor« je vsakih pet minut
končal z izhodom 1. `PIM.AlertDispatcher` je padel v `ops.EscalateOutboundEvents` z napako 2628
(»String or binary data would be truncated … column 'FieldName'«).

Vzrok: migracija 196 je `ops.OutboundEvent.FieldName` razširila na `nvarchar(400)`, ker obvestilo za
en dokument združi imena vseh spremenjenih polj. Stopnjevanje je stolpec še naprej bralo v tabelno
spremenljivko in kurzor z `nvarchar(200)`. Dovolj je en nepotrjen dogodek z daljšim seznamom polj,
da pade vsak zagon; v razvojni bazi sta bila dva (369 znakov, 2026-09-11). Posledica: stopnjevanje
ni stopnjevalo ničesar, razpošiljanje alarmov ni prišlo do vrste, nadzor pa je bil ves čas rdeč.

**Objekti:** `ops.EscalateOutboundEvents` (procedura; `FieldName` v `@ZaStopnjevanje` in v
spremenljivki kurzorja je `nvarchar(400)`, telo je sicer enako kot v 090). Migracija se na koncu
preveri: `THROW 52909`, če definicija še vsebuje `FieldName nvarchar(200)`, in `THROW 52910`, če je
stolpec kdaj širši od 400.

**Ročni korak po uvedbi: ni potreben.** Ob prvem naslednjem zagonu nadzora se nepotrjeni dogodki, ki
so doslej obtičali, stopnjujejo v alarm `OutboundUnacknowledged` (Critical) in uvrstijo v vrsto za
dostavo. Po e-pošti gredo samo, če je `PIM_ALERT_DELIVERY_ENABLED=true`.

**Dokaz (razvojna baza, 2026-09-15).** Uveljavljena ročno s `sqlcmd` in vpisana v
`dbo.SchemaMigration` z enako zgoščeno vrednostjo, kot jo izračuna `PIM.Migrator` (SHA-256 besedila
datoteke). Orodje ni bilo pognano, ker bi hkrati uveljavilo tuje čakajoče migracije 201, 202, 204–208.

**Tveganje, ki ga 209 ne popravlja.** `ops.RecordOutboundEvent` ima parameter `@FieldName
nvarchar(200)` in daljši seznam tiho obreže. `out.RequeueOutboxMessage` in `out.RequeueOutboundBatch`
bereta `out.OutboxMessage.FieldSummary` (`nvarchar(1000)`) v `nvarchar(200)`; druga v tabelno
spremenljivko, kjer bi daljša vrednost povzročila isto napako 2628. Danes je najdaljši `FieldSummary`
33 znakov, zato to ni nujno, je pa isti vzorec.

## Zastoj med preslikavo in urno validacijo/promocijo (migracija 211)

Najdeno 2026-09-15: petminutno »PIM zaloga« (`SaopStockWorker` → `SqlMappingPipeline.ExtractAndApplyAsync`
→ `map.ProcessRawInbox`) in urno »PIM katalog« (`Katalog-cikel.ps1`: `EXEC val.RunValidation` +
`EXEC val.Promote`) sta ločeni Windows opravili, ki ju `MultipleInstances IgnoreNew` varuje samo pred
podvajanjem istega opravila, ne pred sočasnostjo med njima. Obe pišeta/berejo ista `canon.*` polja
istega podjetja, a v različnem vrstnem redu vrstic (`map.ProcessRawInbox` po strani/`RecordOrdinal`,
`val.RunValidation`/`val.Promote` v enem samem stavku čez vse aktivne izdelke podjetja) — klasičen
vzorec za SQL Server zastoj (deadlock). Posledica 2026-09-15: 8 strani (5 od 6 strani dobavitelja
Vidadria) je pristalo v karanteni in `VatRateId` ni prišel v katalog za del artiklov (SAOP ga je
poslal za vseh 28.994 zapisov, katalog ga je imel le pri 3.882). `map.ProcessRawInbox` je takrat
zastoj že lovil in stran vrnil nazaj na `Pending` (`SqlMappingPipeline.cs`, `DeadlockRetries`) — to je
ostalo kot varovalka; tu je popravljeno, kdo v takem zastoju vedno izgubi.

**Prvi poskus (opuščen, glej git zgodovino).** Ideja je bila obe strani pred pisanjem ustaviti na
skupni izključni ključavnici (`sys.sp_getapplock`), da do zastoja sploh ne pride. Merjeno na lokalni
razvojni bazi istega dne: `val.RunValidation` za eno samo podjetje (98.277 aktivnih izdelkov) traja
**več kot 10 minut** — kar se ujema s tem, da `Sql.ps1` (`PimUkaz`) validaciji/promociji že namenoma
dovoljuje do 1800 sekund. Vsaka razumna čakalna meja bi zato petminutni cikel zaloge/cen — ki mora po
izrecni uporabnikovi zahtevi ostati zelo reden — občasno ustavila tudi za pol ure; prekratka meja
(180 s, dejansko preizkušeno) pa je namesto zastoja povzročila enako karanteno, ki jo naj bi reševala
(tri strani Vidadrie so bile s to mejo lažno karantenirane, brez pravega zastoja).

**Objekti:** `val.RunValidation`, `val.Promote` (`CREATE OR ALTER`, brez spremembe poslovne logike;
`map.ProcessRawInbox` je v migracijski datoteki zgolj obnovljen na besedilo migracije 197, ker mu je
opuščeni prvi poskus na lokalni razvojni bazi med razvojem dodal `sp_getapplock` blok). Obe proceduri
na začetku nastavita `SET DEADLOCK_PRIORITY LOW`. To zastoja ne prepreči — SQL Server ga še vedno
odkrije — določi pa vnaprej, kdo je vedno žrtev: ob zastoju z `map.ProcessRawInbox` (privzeta, višja
prioriteta) izgubi vedno validacija/promocija, nikoli preslikava. Brez čakanja, brez vpliva na
petminutni ritem zaloge/cen.

**Ročni korak po uvedbi: ni potreben.** `val.RunValidation`/`val.Promote` ob (redkem) zastoju padeta
enako kot ob katerikoli drugi napaki — `Katalog-cikel.ps1` korak šteje kot padel in poskusi znova čez
uro (`pim.SaveProductWebShops` enako ob naslednjem shranjevanju). Obstoječe karantenirane strani z
`deadlock` v `FailureReason` ponovno odpre že obstoječa zanka v
`SqlMappingPipeline.ExtractAndApplyAsync` ob naslednjem zagonu tega vira/podjetja.


## Cene za vsa podjetja, naročila samodejno in ločena po VNK/VND (migracija 210)

Uporabnik 2026-09-15: cene in zaloga morata biti sveže na 5 minut za vsa štiri podjetja, ne samo
eno; naročila (VNK, VND) naj se berejo samodejno in ločeno, da ju je mogoče vklopiti/izklopiti
in spremljati vsako posebej na `/sistem/urniki`.

**Objekti:** samo `ops.ScheduleProfile` — brez sprememb sheme ali procedur.

- `SAOP_PRICES` dobi vrstico za vsa štiri podjetja (300 s), ne samo za tisto iz pilotnega
  preizkusa. Brez te vrstice `PIM.KatalogWorker --endpoints GetPrices` za preostala tri podjetja
  vsakič pade z 51100 ("Razpored ni omogočen") — to se je dejansko zgodilo 2026-09-15, preden je
  bila vrstica dodana.
- `SAOP_ORDERS_VNK` in `SAOP_ORDERS_VND` nadomestita skupno `SAOP_ORDERS` (1 h razmik, isto kot
  prej). `PIM.SaopOrdersWorker` zdaj odpre ločen `OperationsRun` za vsakega, namesto enega
  skupnega — padec VND po uspešnem VNK ne označi več uspešno pristanjenega VNK podatka kot del
  neuspešnega teka. Stara vrstica `SAOP_ORDERS` je izklopljena (`IsEnabled = 0`), ne izbrisana:
  zgodovina tekov pod tem imenom ostane berljiva na `/sistem/postopki`.

**Ročni korak po uvedbi: ni potreben.** `Katalog-cikel.ps1` od te spremembe naprej vsako uro
kliče `PIM.SaopOrdersWorker` za vsa štiri podjetja; naslednji zagon naloge "PIM katalog" naročila
prebere sam. Enako `Zaloga-cikel.ps1` od te spremembe naprej kliče cene za vsa štiri podjetja
namesto samo za eno (glej `scripts/Zaloga-cikel.ps1`, popravek istega dne).

**Najdeno hkrati (popravljeno brez migracije, samo skripta):** `Katalog-cikel.ps1` je imel
privzeti seznam podjetij nastavljen na `@(2)` namesto `@(1, 2, 3, 4)`; ta zapis je to takrat ocenil
kot ostanek pilotnega preizkusa in privzetek vrnil na vsa štiri. **Ta ocena je bila napačna** —
uporabnik je isti dan (2026-09-15, glej migracijo 213 spodaj) potrdil, da katalog.csv in stranke.csv
namenoma nastaneta samo za podjetje 2. Od 213 naprej ima skripta ločen parameter
`-PodjetjeKataloga` (privzeto 2) za izvoz, `-Podjetja` (vsa štiri) pa velja samo še za naročila,
validacijo in objavo.

**Dokaz (razvojna baza, 2026-09-15).** Migracija uveljavljena in preverjena: `SAOP_PRICES`,
`SAOP_ORDERS_VNK`, `SAOP_ORDERS_VND` imajo po 4 vklopljene vrstice, `SAOP_ORDERS` 0. Živ zagon
`PIM.SaopOrdersWorker --organizations 2` je pristal z dvema ločenima `RunId` (VNK, VND), oba
`Succeeded` v `ops.PipelineRun`.


## Tip stranke prenesen iz PIM_test (migracija 212)

Uporabnik 2026-09-15: v stari razvojni bazi `PIM_test` (isti strežnik `DAVID\MSSQL19`, starejša
generacija sheme brez `b2b.*`) je bil tip stranke za 352 strank že ročno določen. V trenutni bazi
`PIM` ni imela vrednosti `CustomerTypeCode` niti ena od 4.390 strank s spletnim profilom.

**Objekt:** samo podatek — `pim.CustomerWebProfile.CustomerTypeCode`, brez sprememb sheme.

- Ujemanje po poslovni šifri stranke (`OrganizationId` + `CustomerKey`/`CustomerCode`), ne po
  `CustomerId` — identitetni števci se med bazama ne ujemajo. Preverjeno pred pisanjem: vseh 352
  šifer iz `PIM_test` se ujema z `b2b.Customer` v `PIM` (0 neujemajočih).
- Stare slovenske kratice (`PIM_test.pim.CustomerWebProfile.CustomerTypeCode`) preslikane v nove
  kode `pim.CustomerTypeCatalog` po imenu, 1:1 razen ene nedvoumnosti: stara `INSTALATER_MAX` je v
  novem katalogu razdeljena na `INSTALLER_MAX` ("INŠTALATER MAX") in `MAX_INSTALLER` ("MAX
  INŠTALATER") — uporabnik je izbral `MAX_INSTALLER`. Polni seznam preslikave je v komentarju
  migracije.
- Vrednosti so v migraciji **dobesedne** (ni žive poizvedbe nad `PIM_test`): ta baza morda ne
  obstaja na vsakem strežniku, kamor se migracija še uporabi (TEST, produkcija), poleg tega imata
  bazi različno privzeto zbirko (`PIM_test` `Slovenian_CI_AS`, `PIM`
  `SQL_Latin1_General_CP1_CI_AS`) — cez dve bazi bi vsak `JOIN` brez `COLLATE DATABASE_DEFAULT`
  padel z napako 468 (past, opisana v `EXPORTS.md` §3.1). Enkraten zajem, nato navadna migracija.
- `MERGE` je varen tudi ob morebitnem ponovnem ročnem zagonu (migrator sicer vsako datoteko
  uporabi kvečjemu enkrat na bazo): obstoječo vrstico posodobi samo, če je `CustomerTypeCode` še
  prazen — že ročno izbran tip (odločitev človeka, pravilo iz migracije 098) se ne prepiše. Vrstico
  ustvari za stranke, ki še nimajo `pim.CustomerWebProfile` (161 od 352); `WebEnabled` ostane
  privzetih 0 — ta migracija spreminja samo tip, ne spletne kljukice.

**Ročni korak po uvedbi: da, na vsakem strežniku posebej.** Migracija spremeni samo podatek v tej
bazi; na TEST/produkciji jo je treba pognati z `PIM.Migrator` proti tisti bazi (privzeto orodje za
uveljavitev migracij, glej `deploy/`), enako kot vsako drugo migracijo. `PIM_test` na tistem
strežniku ni potrebna — vrednosti so že vgrajene v datoteko.


## En katalog za splet (podjetje 2): B2B cena iz VID cenika, spletne strani iz kljukic (migracija 213)

Uporabnik 2026-09-15, tri odločitve v enem dnevu:

1. »katalog.csv in stranke.csv bi mogle biti samo ena datoteka, ne pa da za vsako podjetje posebej
   imamo katalog.« Na vprašanje, kaj z Vidadriinimi artikli (podjetje 3, svetila_si, 2.368
   objavljenih), je izbral: **en katalog.csv, samo IQ (podjetje 2) artikli**; VID prispeva samo
   zalogo (že od 146) in B2B cenik (ta migracija).
2. »B2B preberejo iz VID-a, B2C pa iz IQ.« Potrjeno: pravi vir stolpca »Cena B2B« za IQ artikle je
   VID-ov cenik `B2B` po isti šifri artikla; migracija 208 (B2B ← IQ-jev lasten B2C) je bila
   začasna, ker IQLighting v ERP nima cenika B2B.
3. »Zakaj je svetila_si in svetila_si_en … te fore imamo samo svetila pa samo videlektro.« Stolpec
   »Spletne strani« bere kljukici spletišč s kartice (`pim.ProductWebShop`), izpiše `svetila`,
   `videlektro` ali `svetila|videlektro`.

**Objekti:**
- `out.ExportPriceList.PriceOrganizationId` (nov, NULL = isto podjetje) — isti vzorec kot
  `out.ExportStockSource.StockOrganizationId` iz 146. Vrstica podjetja 2 za `Product.PriceB2B`:
  `PriceListCode = 'B2B'`, `PriceOrganizationId = 3`; vrstica iz 208 (`'B2C'`) je izklopljena, ne
  izbrisana. Izmerjeno pred pisanjem: 2.385 od 2.569 objavljenih IQ artiklov (93 %) ima VID B2B
  ceno; ostali ostanejo brez B2B cene — enako pravilo kot doslej za manjkajoč cenik (083).
- `canon.WebSite.TreeLabel` (nov): `svetila` za drevo `svetila_si`, `videlektro` za `videlektro`.
  Interne kode ostanejo — `svetila_si` je v 16 tabelah, validacijskih profilih (`WEB_svetila_si`)
  in testih; preimenovanje bi bilo tveganje brez koristi za uporabnika, ki vidi samo oznako.
- `out.GetExportRows` (zamenjava besedila žive definicije, oznaki `/* PriceOrg213 */` in
  `/* WebSitesFromFlags213 */`): cenik se bere iz `ISNULL(PriceOrganizationId, @OrganizationId)`;
  `Product.WebSites` je `STRING_AGG(TreeLabel, '|')` prek objavljenih kljukic. Pogoj, *kdaj* je
  izdelek v katalogu (aktiven + kljukica + kategorija na strani + veljaven, 146/201), je
  nespremenjen — spremeni se samo vsebina stolpca. Ker isto proceduro bere tudi
  `MAGENTO_STOCK_PRICES`, ima petminutna datoteka isto B2B ceno kot katalog.
- `intranet.GetProductWebShops`: ime kljukice na kartici je `TreeLabel` (svetila, videlektro);
  kartica ne kaže več interne kode.

**Izven baze (isti dan):** `Katalog-cikel.ps1` in `Nocno-vse.ps1` izvozita en par datotek samo za
`-PodjetjeKataloga` (privzeto 2); validacija, objava in naročila še vedno tečejo za vsa štiri
(VID zaloga in cenik vstopata v IQ katalog prek objavljenega sloja podjetja 3). Gumb »Izvoz
kataloga za splet« na `/sistem/workerji` teče vedno za podjetje 2 (`WorkerJob.FixedOrganizationId`),
ne glede na izbiro podjetja. `MAGENTO_STOCK_PRICES` ostaja za vsa štiri podjetja, dokler uporabnik
ne reče drugače.

**Ritem (uporabnik 2026-09-15: »avtomatsko katalog in stranke na 1 h, zaloge in cene pa se filajo v
ta katalog.csv«):** naloga »PIM katalog« (vsako uro, `Katalog-cikel.ps1`) = naročila + validacija +
objava za vsa štiri podjetja + `katalog.csv`/`stranke.csv` za podjetje 2; naloga »PIM zaloga« (vsakih
5 minut, `Zaloga-cikel.ps1`) = zaloga in cene iz SAOP za vsa štiri + `magento-stock-prices.csv` za
vsa štiri + **ponovno `katalog.csv`/`stranke.csv` za podjetje 2** s svežo zalogo in cenami, brez
validacije (cene in zaloga se v `out.GetExportRows` berejo iz `canon.ProductPrice` in
`stock.Snapshot` naravnost, 204/146 — objava ni potrebna). Petminutna obnova para je v
`Zaloga-cikel.ps1` obstajala že prej, a za vsa štiri podjetja; zdaj samo za podjetje 2.
`ops.ScheduleProfile`: `MAGENTO_PRODUCTS` je za podjetja 1, 3 in 4 izklopljen (vrstica ostane,
ročen zagon za ta podjetja pade z 51100 — namerno), za podjetje 2 ostane na uro (3600/7200), ker
skripte poln izvoz kličejo brez `--po-urniku` in sočasnost varuje `ops.BeginRun` (51101 → zagon se
umakne). Brez izklopa bi nadzornik razpored brez zagonov po dveh urah vsakič razglasil za
zastalega.

**Ročni korak po uvedbi: ni potreben.** Naslednji urni cikel »PIM katalog« zapiše
`izvoz\magento\2\katalog.csv` z novo vsebino stolpcev »Cena B2B« in »Spletne strani«. Mape
`izvoz\magento\1`, `3`, `4` se za katalog.csv/stranke.csv ne polnijo več (ostaneta v njih samo
`magento-stock-prices.csv`); starih datotek migracija ne briše.

**Preveri po uvedbi (lokalna baza):** za artikel `BA.BC15.00330` je IQ B2C 26,89 in VID B2B 29,78 —
v katalog.csv mora stolpec »Cena B2B« pokazati 29,78 (prej 26,89); stolpec »Spletne strani« pri
artiklu z obema kljukicama `svetila|videlektro`.

## Nadzorna plošča: "ERP veljavni" ne sme presegati "Skupaj izdelkov" (migracija 214)

Uporabnik je na `/nadzorna-plosca` opazil nemogoče stanje: "ERP veljavni" je bil 297.677 (151 % vseh
izdelkov), medtem ko je "Skupaj izdelkov" prikazoval samo 196.559. Pregled sheme
(`005_CreateOutputContract`, `006_CreateCanonicalValidationAndPim`) pokaže, da to po definiciji ne sme
biti mogoče: `val.ProductValidationState` ima `UQ_ProductValidationState_ProductProfile UNIQUE
(ProductId, ValidationProfileId)`, `val.ValidationProfile` ima `UQ_ValidationProfile_ProfileCode UNIQUE
(ProfileCode)` — en izdelek sme imeti kvečjemu eno `VALID` vrstico za profil `ERP_L1`, torej
`ErpValidCount` na `/nadzorna-plosca` po konstrukciji ne more preseči `CanonProductCount` za isto
podjetje, če baza spoštuje lastne omejitve.

Lokalna baza (`DAVID\MSSQL19`) te napake ne pokaže — `ErpValidCount` je tam 0 za vsa štiri podjetja,
ker `val.RunValidation` na njej še ni tekel — medtem ko je vsota `CanonProductCount` (196.591) skoraj
natanko enaka številki iz vprašanja. To pomeni, da posnetek prihaja iz druge baze (najverjetneje
produkcije SONJA), kjer je omejitev iz nekega razloga kršena — verjetno podvojene vrstice v
`val.ProductValidationState` iz obdobja pred uvedbo `UNIQUE` omejitve ali rocnega posega mimo migracij.
Do produkcijske baze v tej seji ni bilo neposrednega dostopa (bralni dostop do produkcije je
blokiran), zato vzroka podvojitve ni bilo mogoče potrditi na samih podatkih — samo na shemi.

**Objekti:**
- `intranet.GetDashboard` (010, popravljeno tu): `ErpValidCount` in `WebInvalidCount` zdaj štejeta
  `COUNT(DISTINCT stateValue.ProductId)` namesto `COUNT(*)`. Obe števili sta s tem po definiciji
  navzgor omejeni s `CanonProductCount` za isto podjetje, ne glede na morebitne podvojene vrstice v
  `val.ProductValidationState`.

**To ne odpravi vzroka:** če v produkcijski bazi res obstajajo podvojene vrstice v
`val.ProductValidationState` (ali podvojeni `val.ValidationProfile` zapisi za isto `ProfileCode`, kar
shema sicer preprečuje), jih je treba najti in počistiti neposredno v bazi. Diagnostika:

```sql
-- Ali UNIQUE omejitev na val.ProductValidationState sploh obstaja?
SELECT name FROM sys.key_constraints WHERE parent_object_id = OBJECT_ID(N'val.ProductValidationState');

-- Podvojene (ProductId, ValidationProfileId) vrstice
SELECT ProductId, ValidationProfileId, COUNT(*) AS Cnt
FROM val.ProductValidationState
GROUP BY ProductId, ValidationProfileId
HAVING COUNT(*) > 1;

-- Podvojeni ValidationProfile zapisi za isto kodo
SELECT ProfileCode, COUNT(*) FROM val.ValidationProfile GROUP BY ProfileCode HAVING COUNT(*) > 1;
```

**Ločeno ugotovljeno pri tem pregledu (ni del te migracije):** lokalna baza je manjkala šest migracij,
ki so na disku, a niso bile pognane (`201`, `202`, `209`, `211`, `212`, `213`) — uporabnika velja
opozoriti, naj `PIM.Migrator` požene, preden nadaljuje delo na lokalni bazi.

## Dohitevanje šestih manjkajočih migracij na lokalni bazi (2026-09-16)

Pet od šestih zgoraj naštetih migracij je bilo dejansko pognanih na `DAVID\MSSQL19` in vpisanih v
`dbo.SchemaMigration`:

- **202, 211, 212, 213** so tekle brez težav.
- **209_CatalogColumnContract** je prvič padla (`UNIQUE KEY` na `out.ExportColumn` — dve neaktivni
  legacy koloni, `COL055`/`COL058`, sta že zasedali ciljna `SortOrder` 214/215). Popravek: obe
  neaktivni koloni sta ročno prestavljeni na `SortOrder` 900/901 (izven aktivnega obsega 1-217), nato
  je migracija tekla čisto.
- **201_WebExportByShopFlags** se NE da pognati več in verjetno nikoli več ne bo šla skozi lastno
  preverbo: njen del za stranke (`profile.CustomerTypeCode IS NOT NULL /* 201 */`) je bil po enem
  dnevu namerno razveljavljen z uporabnikovo odločitvijo v migraciji `202` (»tip stranke ni več pogoj
  za izvoz«). Preverjeno ročno: VSE ostale trditve iz `201`-ovega dokaza držijo na trenutnem stanju
  (`ProductWebShop /* 201 */` prisoten, `canonProduct.WebPublish` odsoten, `ProductHold /* 194 */`
  prisoten, `intranet.GetExportReadiness` ne bere več `WebPublish`, urnik `MAGENTO_PRODUCTS`/
  `MAGENTO_STOCK_PRICES` obstaja za vsa štiri podjetja) — edino, kar manjka, je del, ki ga je `202`
  namenoma odpravila. Vpis `201` v `dbo.SchemaMigration` je bil blokiran s strani varnostnega
  filtra seje (»Logging/Audit Tampering«), zato **`201` na `dbo.SchemaMigration` ostaja neuveljavljena**
  — če se strinjate z zgornjo ugotovitvijo, vrstico dodajte ročno:
  ```sql
  INSERT dbo.SchemaMigration (MigrationId, ScriptHash)
  VALUES (N'201_WebExportByShopFlags.sql', N'58a9f63710c007ac27cca957ed8cd0a5562d8a963d3e25801a8447424799d6aa');
  ```

**Ločena, nerešena najdba:** `Invoke-PendingMigrations.ps1 -Status` javlja, da imajo štiri že
uveljavljene migracije (`187_ReservationExclusionAlerts`, `188_ReservationExclusionAlertsCritical`,
`189_SystemIntegrationsAlertOrganization`, `190_ReservationFlagIgnoresArchived`) na disku drugačno
vsebino, kot kaže zapisani hash v `dbo.SchemaMigration`. V git zgodovini so te štiri datoteke nastale
v enem samem commitu (`ce6e1c1`, »flagani produkti«) in se od takrat niso spreminjale — torej ne gre
za naknadno urejanje datoteke. Vzrok neujemanja ni bil ugotovljen (možna razlika v načinu izračuna
hasha med `PIM.Migrator` in `Invoke-PendingMigrations.ps1` ob prvotnem zagonu). Priporočilo: preveriti
z `dotnet run --project src\PIM.Migrator -- --status` (avtoritativno orodje), preden se karkoli
ročno popravlja v `dbo.SchemaMigration`.

## Popravek migracije 201 in umik ERP_L1/WEB_B2C z nadzorne plošče (migracija 215, 2026-09-16)

**201 popravljena, ne le vpisana:** preverba za `CustomerTypeCode IS NOT NULL /* 201 */` v razdelku
"dokaz" je bila trajno nemogoča (glej zgoraj) — datoteka je zdaj popravljena (preverba odstranjena,
razlaga v komentarju ob njej) in migracija je bila dejansko pognana in uveljavljena, ne le ročno
vpisana v ledger.

**Umik ERP_L1/WEB_B2C:** uporabnik je ta dva stara profila umaknil iz validacije (`ERP_L1.IsActive=0`,
`WEB_B2C.BlocksErp=0`/`BlocksWeb=0`), njuno mesto so prevzeli `ERP_L1_EU/SLO/THIRD`, `SHARED_CORE`
(ERP) in `WEB_svetila_si`/`WEB_videlektro`/`SHARED_CORE` (splet). `intranet.GetDashboard` pa je
"ERP veljavni"/"Z napakami" še vedno računal trdo kodirano po `ProfileCode = 'ERP_L1'`/`'WEB_B2C'` —
po umiku ERP_L1 je "ERP veljavni" na vseh štirih podjetjih kazal **0**, "Z napakami" pa je štel
napake profila, ki jih nihče več ne blokira.

**Objekti:**
- `intranet.GetDashboard` (010 → 214 → tu): obe števili zdaj štejeta `canon.Product` prek
  `EXISTS`/`NOT EXISTS` proti `val.ProductIssue`, filtrirano po `profileValue.BlocksErp`/`BlocksWeb`
  (ne po imenu profila) — ista logika kot `canon.Product.ValidationStatus` v `val.RunValidation`
  (182/211), samo ločena na ERP/splet. Po popravku (preverjeno na vseh 4 podjetjih): "ERP veljavni"
  1.863–32.654, "Z napakami" 5.717–48.745, oboje smiselno pod "Skupaj izdelkov" za isto podjetje.
- `src/PIM.Migrator/Program.cs` (`VerifyF1Async`) in `tests/sql/Verify-F1.sql`: preverba je zahtevala
  natanko `ERP_L1`/`WEB_B2C` kot aktivna — po umiku bi vedno padla. Zamenjana z generično preverbo
  (vsaj en aktiven profil z `BlocksErp=1`, vsaj en z `BlocksWeb=1`). To nista migraciji, popravljeni
  sta neposredno v kodi.

**Namerno NE narejeno:** `ERP_L1`/`WEB_B2C` nista izbrisana ali dodatno deaktivirana v
`val.ValidationProfile` — `WEB_B2C` aktivno uporablja `PIM.F5.Integration` (`val.Promote`/
`out.ExportProductsCsv @ProfileCode='WEB_B2C'`/`'_PRODUCTS'`), ki bi ob izklopu padel. Če želite tudi
to počiščeno, je treba najprej ta test preusmeriti na enega od novih profilov (`WEB_svetila_si`),
kar zahteva kategorijo/kljukico v testnih podatkih — ločeno delo od te migracije.

## Katalog: enote v glavi, imena partnerjev, garancija, velike začetnice, kategorije VID, napetost/frekvenca (migracija 216, 2026-09-16)

Uporabnik je pregledal `katalog.csv` (podjetje 2) in naštel napake; migracija jih odpravi pri viru
(zajem), v objavi in v izvozu — vsaka točka je v glavi datoteke citirana dobesedno.

- **Proizvajalec / Dobavitelj** sta ime, ne šifra (`canon.PartnerName`, isti vir kot kartica, 128);
  brez imena ostane šifra.
- **Enota je v glavi stolpca** (`Bruto teža [kg]`, `Višina [mm]`, `Napetost [V]` …). Vseh 40 stolpcev
  `Enota …` in stolpec `Komentarji` so izklopljeni (`IsActive = 0`). Katera enota velja za kateri
  stolpec, je podatek v novem registru `out.CatalogUnitRule` (polje vrednosti, polje z enoto vira,
  ciljna enota); izvoz vrednost pretvori (`out.UnitFactor`: mm/cm/m, g/kg, cm3/dm3/m3, sopomenke
  kgs/gr/dm³/⁰) ali ji enoto glave samo odvzame (`50/60 Hz` → `50/60`); neznano pusti pri miru.
  Aktivnih stolpcev je zdaj **176** (prej 217), `SortOrder` zvezen 1..176.
- **Kategorije vid** = iste kot pri svetilih: drevo `svetila_si` (132) je zrcaljeno v drevo
  `videlektro` (isti `CategoryCode`, imena, prevodi), preslikave dobaviteljev (`map.CategoryPathMap`,
  226 vrstic NW/BT) prekopirane, obstoječe uvrstitve `svetila_si`/`svetila_si_en` prepisane v
  `B2C`/`B2C_EN` (canon in pim). Ročna uvrstitev (`pim.ProductCategoryOverride`) ima prednost.
- **Garancija** v letih s sklanjanjem (`pim.WarrantySl`: 1 leto, 2 leti, 3/4 leta, 5 let); pri zajemu
  (pretvorba `WARRANTY` na vseh preslikavah v `ProductAttribute.Garancija`), v izvozu in enkratno
  na obstoječih vrsticah. Kar ni število let (SAOP `Warranty` pri nekaterih dobaviteljih nosi naziv
  izdelka), ostane nespremenjeno.
- **Velike začetnice** prevodov: `map.ValueLookup` (SL/DE/HR, domene `… SLO` in `*`), obstoječe
  jezikovne vrstice `canon`/`pim.ProductAttribute`, izvoz (stolpci SLO/ANG) in zajem (pretvorba
  `CAPITALIZE` na vseh preslikavah v `… SLO`/`… ANG`).
- **Napetost / frekvenca**: Braytron pošlje `220-240V 50/60Hz` → `Napetost` = `220-240` (pretvorba
  `BEFORE V`), nova preslikava v `Frekvenca` = `50/60` (`REQUIRE Hz` → `AFTER ' '` → `BEFORE Hz`);
  podvojena preslikava v `Nazivna napetost` je izklopljena, njene vrstice (1.202) izbrisane, obstoječe
  vrednosti razcepljene. Nowodvorski `NW.11710` (zamenjan par) se od zdaj popravi že pri zajemu
  (`map.ApplyValueTransforms`, blok `SwapVoltageFrequency216`).
- Nove splošne pretvorbe: `BEFORE`, `AFTER`, `REQUIRE`, `WARRANTY`, `CAPITALIZE`
  (`CK_FieldTransform_Code` razširjen).

**Objekti:** `out.UnitFactor` (nova funkcija), `pim.WarrantySl` (nova funkcija), `out.CatalogUnitRule`
(nova tabela + seme 44 vrstic), `out.ExportColumn` (41 izklopov, 44 preimenovanj, preštevilčenje),
`out.GetExportRows` (blok `/* Catalog216 */`), `map.ApplyValueTransforms` (bloka
`/* Transforms216 */`, `/* SwapVoltageFrequency216 */`), `map.FieldTransform` (omejitev
`CK_FieldTransform_Code`; nove vrstice WARRANTY/CAPITALIZE/BEFORE/AFTER/REQUIRE), `map.FieldMapping`
(BT `voltage` → `Frekvenca` nova; BT `voltage` → `Nazivna napetost` izklop), `map.ValueLookup`,
`canon.ProductAttribute`, `pim.ProductAttribute` (podatki), `canon.Category`, `canon.CategoryTranslation`,
`map.CategoryPathMap`, `canon.ProductCategory`, `pim.ProductCategory` (zrcalo in uvrstitve).

**Koda v istem commitu (ni migracija):** `src/PIM.B2b/MagentoCsvContract.cs` (predloga 176 glav),
`tests/PIM.F7.MagentoExportTests`, `tests/PIM.F7.MappingTests` (indeksi stolpcev). Delujoči worker
glave bere iz registra, zato deluje tudi brez nove gradnje.

**Ročni korak po uvedbi:** ni potreben. Stolpca `Kategorije vid` se napolnita, ko urni
`Katalog-cikel.ps1` požene `val.RunValidation` + `val.Promote` (profil `WEB_videlektro` mora biti
VALID, da je stran za izdelek dovoljena — pravilo 146/201 se ne spreminja). Spletni uvoz (Magento)
mora poznati nove glave z enoto v `[]` in 41 stolpcev manj — to je sprememba pogodbe do spleta.

**Namerno ne:** `Naziv artikla EN` ostane WARNING (ne blokira; 652 vrstic brez EN naziva); `Dobavitelj
datum` je že `dd.MM.yyyy`; stolpca `Bruto/Neto teža (2)` ostaneta — predlogi združevanja so v
`docs/KATALOG_PRESLIKAVA_ATRIBUTOV.md`.

## Kategorije VID pod "Razsvetljava"; glavi "Popust na artikel" in "Pakirna količina" (migracija 217, 2026-09-16)

Sestanek 2026-09-16 (`popravki_kataloga.csv`): opomba pri stolpcu "Kategorije vid ANG" — »Doda se
nadkategorija Razsvetljava« — ter preimenovanje dveh glav.

- **Kategorije VID:** 216 je drevo `svetila_si` zrcalila v koren drevesa `videlektro`. Spletna stran
  videlektro.com ima svetila pod oddelkom `razsvetljava` (092), zato so zrcaljene kategorije zdaj pod
  njim: `Razsvetljava > Notranja svetila > …` / `Lighting > Interior lighting > …`. Zrcaljeni
  "Tračni sistemi" so se združili z obstoječo kategorijo `razsvetljava___tracni_sistemi` (otroci
  prestavljeni, kopija `tracni_sistemi` izklopljena, preslikava dobavitelja preusmerjena). Uvrstitve
  izdelkov (canon in pim, strani `B2C`/`B2C_EN`) so izračunane znova iz drevesa
  (`canon.CategoryPathTranslated`); število uvrstitev je nespremenjeno (dokaz v migraciji). Izmerjeno
  po izvozu: 2.090 vrstic ima `Kategorije vid SLO` = `Razsvetljava > ` + `Kategorije svetila SLO`.
- **Glavi:** `Popust` → `Popust na artikel` (vir `Product.ClearancePercent`), `PAK2` →
  `Pakirna količina` (vir `Product.Pak2`). Katalog ostane pri 176 stolpcih.

**Objekti:** `canon.Category` (videlektro: ParentCategoryCode, LevelNo, CategoryPath, IsActive
za `tracni_sistemi`), `map.CategoryPathMap` (1 vrstica: `tracni_sistemi` →
`razsvetljava___tracni_sistemi`), `canon.ProductCategory`, `pim.ProductCategory` (izbris in ponovni
vpis poti na `B2C`/`B2C_EN`), `out.ExportColumn` (2 preimenovanji).

**Koda v istem commitu:** `src/PIM.B2b/MagentoCsvContract.cs`, `tests/PIM.F7.MappingTests`,
`tests/PIM.F7.MagentoExportTests/CatalogLifecycleTests.cs` (novi imeni glav).

**Ročni korak po uvedbi:** ni potreben. Migracija je ponovljiva (vsak korak preveri, ali je že
narejen); poti v katalogu se osvežijo ob naslednjem urnem izvozu.

**Namerno ne (čaka na PIM):** stolpci `Izpostavljeno`, `Razstavni eksponat`, `Popust rastavni` in
dodelitev skupine popusta `S1` — uporabnik: »bo treba najprej popraviti v PIM-u in bomo potem videli
izvoz«.

## Zmogljivost: indeksi, delovni list brez pogleda, množična nadzorna plošča, hitra validacija ob shranjevanju, množični uvoz (migracija 218, 2026-09-17)

Analiza 2026-09-17 na lokalni bazi `DAVID\MSSQL19` (196.594 `canon.Product`, 2,5 M `canon.ProductText`,
1,5 M `val.ProductIssue`, 4 M `stock.Position`, 4,1 M `stock.LandingRecord`): strani so se odpirale
v desetinah sekund, štiri (nadzorna plošča, `/kakovost/artikli`, `/zajem`, `/nastavitve/kategorije`)
so padle na 30-sekundni privzeti meji `SqlCommand`. Vzrok nikjer ni bila meja, ampak poizvedba.

| Kaj | Pred | Po | Vzrok in popravek |
|---|---|---|---|
| `intranet.GetProductWorkbook` (2.000 izdelkov) | 43–61 s | 1,9–2,4 s | 1. del je vezal pogled `canon.FieldValue` (35 vej UNION ALL) na tabelno spremenljivko; optimizer je pogled izvedel v celoti za vsako polje. Polja se zdaj berejo neposredno iz tabel z istimi kodami in vrednostmi kot v pogledu. |
| `intranet.GetProductWorkbook` (20.000) | 56–87 s | 4,3–4,5 s | isto |
| `intranet.GetDashboard` (eno podjetje) | 12–16 s | 0,5–0,8 s | korelirani `(NOT) EXISTS` za vsak izdelek → množični izračun v začasnih tabelah; isti pomen kot v 215 |
| `pim.SaveProductTexts` (en izdelek, ista vrednost) | 10,7 s | 0,18 s | klicala je `val.RunValidation @ProductId` (14–95 s, glej 195); zdaj `val.RunValidationForProduct` (0,1–0,5 s). Enako `SaveProductAttributes` in `SaveProductWebShops`. |
| `stock.LandingRecord WHERE SyncRunId = @r` (StockLandingWriter, vsakih 5 min, dvakrat) | 1,5–5,6 s | 3 ms | ni bilo indeksa; `IX_StockLandingRecord_SyncRun` |
| `intranet.GetStockOverview` | 1,1–2,7 s | 0,05–0,07 s | `stock.Position` brez indeksa po `SnapshotId`; `IX_stock_Position_Snapshot` |
| `intranet.GetProductListViews` | 1,1–1,7 s | 0,3 s | `canon.ProductText` brez indeksa po `TextType`; `IX_CanonProductText_TextType_Product` |
| `intranet.GetProductList @ErpStatus` | 1,3–2,4 s | 0,6 s | `IX_ProductValidationState_Profile_Status` |
| `intranet.GetQualityProducts` (`/kakovost/artikli`) | 24–39 s | 2,0–2,6 s | pogled `val.ProductChannelReadiness` je štel napake z `OUTER APPLY` na vsak izdelek in bral naziv prek `canon.FieldValue`; zdaj `GROUP BY` in naziv neposredno iz `canon.ProductText` |
| `PipelineReadService.GetInboundFlowsAsync` (`/zajem`) | 25–39 s | 0,13–0,17 s | števec čakajočih/karanteniranih zapisov zaloge je pregledal milijone `Applied` vrstic na konektor; filtriran indeks `IX_StockLandingRecord_Open` + poizvedba omejena na odprta stanja |
| `CategoryTreeService.GetCategoryPickerAsync` (na vsakem nalaganju `/izdelki`, dve drevesi) | 6 s na drevo | 5 ms | `OUTER APPLY` je za vsako vozlišče znova izračunal rekurzivni pogled `canon.CategoryPathTranslated`; poti se izračunajo enkrat v začasno tabelo, poddrevo prek zaprtja po poti (C#, brez migracije) |
| `intranet.GetCategoryTreeNodes` | 0,4 s | 0,3 s | isto načelo (začasna tabela poti) |
| `intranet.GetQualityOverview` | 4,0–4,5 s | ~2 s | odprte napake podjetja enkrat v ozko začasno tabelo, trije nabori iz nje |
| `intranet.GetPriceChecks` (`/preverbe`) | 5,4–7,8 s | ~4 s | začasna tabela namesto tabelne spremenljivke; naziv samo za vrnjeno stran |
| `intranet.GetStockByItem` @Take | največ 200 | največ 20.000 | izvoz zaloge je delal desetine klicev po 200 vrstic, vsak je znova sestavil vso `#StockByItem` (44 s za eno podjetje); zdaj en klic |
| `intranet.GetProductOrigin` (kartica izdelka) | 17,8 s | 2,0–2,5 s, in šele ob odprtju zavihka | iskanje po 78 M vrstic `map.ExtractedValue` (`Value` je `nvarchar(max)`, ne more biti ključ); filtriran indeks `IX_ExtractedValue_Identity` na treh identitetnih poljih (~2,9 M vrstic) + procedura z istim pogojem; kartica ga bere lenobno (`ProductCard.razor`) |
| `intranet.GetCategoryMappings` (`/kakovost/kategorije`) | 27,7 s | 0,6–0,9 s | poti enkrat v začasno tabelo namesto `OUTER APPLY` na vsako vrstico registra |
| `intranet.GetCategoryTree` (`/nastavitve/kategorije`, dva klica) | 12,5 s | 1,0–1,3 s | števci izdelkov po kategoriji množično (`#Uvrstitev`, `#Spodaj`) namesto `OUTER APPLY` z `LIKE` na vsako kategorijo |
| `intranet.GetValidationIssues @Take = 0` (nadzorna plošča, 4 podjetja) | 2,8–4,7 s | 0,2–0,3 s | plošča bere samo profile; seznam napak in kode se pri `@Take = 0` ne računajo (`Dashboard.razor` podaja `take: 0`) |
| `intranet.GetStockOverview` (zavrnjene pozicije) | 3,7 s | 0,1–0,25 s | `LOOP JOIN` — 2.000 zavrnjenih pozicij išče svoj zapis po ključu namesto pregleda 4 M zapisov |
| `intranet.GetProductList` (izvozna stran, do 20.000) | 60 s meja ukaza | 600 s | pod sočasno obremenitvijo (dva izvoza celega kataloga + urna validacija) je stran presegla 60 s in izvoz je padel s 500; stran seznama (50 vrstic) ostane pri 60 s |

**Indeksi (vsi ponovljivi, `IF NOT EXISTS`):** `stock.LandingRecord` (`IX_StockLandingRecord_SyncRun`,
filtriran `IX_StockLandingRecord_Open`), `stock.Position` (`IX_stock_Position_Snapshot`), `canon.ProductText`
(`IX_CanonProductText_TextType_Product`), `val.ProductIssue` (obstoječi filtrirani
`IX_ProductIssue_Active_ProductRequirement` dobi `INCLUDE (ValidationProfileId, IssueCode)`, `DROP_EXISTING`),
`val.ProductValidationState` (`IX_ProductValidationState_Profile_Status`), `ops.PipelineRun`
(`IX_PipelineRun_OrganizationPipelineStartedUtc`), `ops.Alert` (filtriran `IX_Alert_Open`), `canon.ProductPrice`
in `pim.ProductPrice` (`..._ListActive`), `canon.Product` (`IX_CanonProduct_OrgSupplier`, `_OrgManufacturer`,
`_OrgItemGroup`, `_OrgActiveDepartment`). Namerno **ne**: `map.ExtractedValue` (78 M vrstic, DMV predlaga
pokrivni indeks z `Value` — podvojil bi 4 GB tabelo za šest izvedb na dan; če bo preslikava počasna, je to
ločena odločitev), `raw.Inbox` (v vrstici je 1 MB, pregled je poceni).

**Procedure in pogledi:** `val.RunValidationForProduct` (zagotovljena; 195 živi v `sql\`, ne v mapi migracij,
zato je na TEST morda ni), nova `val.RunValidationForProducts(@ProductIdsJson)` (ista logika za seznam
izdelkov, `DEADLOCK_PRIORITY LOW` kot 211), `pim.SaveProductTexts`, `pim.SaveProductAttributes`,
`pim.SaveProductWebShops` (validacija prek `RunValidationForProduct`), novi `pim.SaveProductTextsBulk` in
`pim.SaveProductAttributesBulk` (množični zapis za uvoz: en `MERGE`, ena serija `pim.ProductChangeBatch` prek
sprožilcev, ena validacija paketa; izdelek izven podjetja odpade in se vrne v drugem naboru z razlogom),
`intranet.GetProductWorkbook`, `intranet.GetDashboard`, `intranet.GetQualityOverview`, `intranet.GetStockByItem`,
`intranet.GetCategoryTreeNodes`, `intranet.GetPriceChecks`, pogled `val.ProductChannelReadiness`.

**Koda v istem commitu:** `PIM.Intranet/Services/HeavyWorkGate.cs` (nova vrata: največ 2 izvoza in 2 uvoza
hkrati, nastavljivo z `Intranet:MaxConcurrentExports` / `Intranet:MaxConcurrentImports`; ostali čakajo v vrsti
in stran pove, koliko jih je pred njimi), `ExportJobService` (vrsta, napredek, časovna meja 90 min, zvezek na
disk), `ExportResultStore` (datoteke v začasni mapi procesa, ne `byte[]` v pomnilniku; brisanje po 2 urah),
`WorkbookWriter.WriteAsync(Stream, ...)`, `ProductWorkbookService` (seznam po 20.000 = meja procedure,
podatki na vrstico po 5.000, uvoz bere stanje po paketih in zapisuje besedila/atribute prek `*Bulk` procedur
po 1.000 izdelkov, sprotni napredek), `ProductEditService.SaveTextsBulkAsync/SaveAttributesBulkAsync`,
`CategoryTreeService.GetCategoryPickerAsync` (poti enkrat v začasni tabeli + petminutni predpomnilnik procesa
`IMemoryCache`, ker stran `/izdelki` izbirnik bere ob vsakem nalaganju za obe drevesi), `PipelineReadService.GetInboundFlowsAsync`,
`StockReadService.BuildStockWorkbookAsync` (stran 20.000), `Dashboard.razor` (podjetja vzporedno, `GetValidationIssues`
s `take: 0`, števci in paneli 60 s v `IMemoryCache` — deset uporabnikov na plošči hkrati je bilo 40 sočasnih
težkih poizvedb in 30 s meja za vse),
`ProductImport.razor` (vrata + napredek), `Products.razor` (stanje v vrsti in napredek), `Program.cs`
(neposredni izvozi `/izvoz/*.xlsx|csv` gredo skozi ista vrata; `/izvoz/prenos/{token}` pretaka datoteko z diska).

**Ročni korak po uvedbi:** ni potreben; migracija je ponovljiva. **Priporočilo za instanco (ni del
migracije, odločitev skrbnika, potrebuje `sysadmin`):** `cost threshold for parallelism` je na 5
(privzeto); CXPACKET/CXCONSUMER sta bili daleč največji čakanji (5.991 s + 2.686 s od zagona), ker se
vsaka poizvedba nad ~5 enot razdeli na vzporedne niti in si jih deset uporabnikov deli. Predlog 50;
skripta je v `sql\218_zmogljivost\instanca_cost_threshold.sql`.

**Za TEST/produkcijo:** `sql\218_zmogljivost\navodila.txt` — migracija se požene prek `PIM.Migrator` (ali
izolirano, kot 195), datoteka je brez `GO` in jo je mogoče pognati tudi neposredno v SSMS; indeksi na
4 M vrstic `stock.LandingRecord` in `stock.Position` trajajo skupaj nekaj minut in med gradnjo držijo
bralne zaklepe (brez `ONLINE`, ker izdaja strežnika ni znana).

## Kategorije VID v katalogu tudi brez kljukice "videlektro" (migracija 219, 2026-09-17)

Uporabnik je odprl svež `katalog.csv` (podjetje 2) in opozoril, da sta stolpca "Kategorije vid
ANG/SLO" pri delu vrstic prazna. Vzrok ni bila napaka preslikave 216/217: 213 je `out.GetExportRows`
naredila tako, da je kategorija izdelka na posamezni spletni strani v izvozu vidna samo, če ima
izdelek na kartici (`pim.ProductWebShop`) prižgano kljukico za tisto stran — ista kljukica, iz katere
izhaja tudi stolpec "Spletne strani". 86 izdelkov (podjetje 2) ima kljukico samo za `svetila_si`, ne
za `videlektro`; preverjeno na `BA.BH15.01100` (ProductId 140617): `pim.ProductCategory` je za te
izdelke že imela zrcaljeno vrstico na `B2C`/`B2C_EN` (216/217 sta jo ustvarili), izvoz je le ni
pokazal, ker izdelek (še) ni objavljen na videlektro.

Uporabniku so bile ponujene tri možnosti (prižgi kljukico vsem / pokaži samo v CSV brez objave /
pusti kot je); izbral je drugo: stolpca naj bosta v katalogu vedno polna, kadar ima izdelek kategorijo
svetila, **brez** vpliva na kljukico, na stolpec "Spletne strani" ali na dejansko objavo izdelka na
videlektro.com. Migracija v `out.GetExportRows` (blok `/* VidKategorijePreview219 */`, tik za
`/* Catalog216 */`) doda vrstico za `Product.CategorySl`/`Product.CategoryEn`, kadar je ni (izdelek ni
objavljen na videlektro), iz `Product.CategorySvetilaSl`/`Product.CategorySvetilaEn` s predpono
`Razsvetljava > ` / `Lighting > ` (enako kot 217); če vrstica že obstaja (izdelek JE objavljen na
videlektro), ostane taka, kot jo je izračunal običajni potek (`#Site`/`#Category`). Več kategorij na
isto stran (`STRING_AGG` z `|`, 213) je bilo pri preverjanju izmerjeno 0-krat, koda pa jih vseeno loči
in ponovno združi (`STRING_SPLIT`/`STRING_AGG`), da predpona ne pokrije celega spojenega niza.

Preverjeno na `DAVID\MSSQL19` s polnim izvozom (`out.GetExportRows`, podjetje 2, 2.176 vrstic): po
migraciji 0 vrstic z manjkajočo ali neujemajočo se `Kategorije vid ANG/SLO` (bilo: 86 manjkajočih),
`Spletne strani` in število izdelkov s kljukico "videlektro" (2.090) nespremenjena.

**Objekti:** `out.GetExportRows` (nov blok, samo besedilni popravek — ne dotika se
`pim.ProductWebShop`, `pim.ProductCategory` ali `canon.ProductCategory`).

**Ročni korak po uvedbi:** ni potreben; migracija je ponovljiva. Za produkcijo je treba migracijo
219 pognati prek `PIM.Migrator` posebej (na lokalni bazi je bila zaradi hitrega preverjanja pognana
neposredno prek `sqlcmd`, mimo `Invoke-PendingMigrations.ps1` — pri naslednjem rednem teku orodja se
bo zavedla kot že uveljavljena, ker skript sam preveri oznako `/* VidKategorijePreview219 */`).

## Nowodvorski slike/dokumenti: protokol-relativni URL dobi "https:" (migracija 220, 2026-09-17)

Uporabnik je v katalogu opazil, da so v stolpcih "Glavna slika"/"Ostale slike" (in enako pri
dokumentih — Energijska nalepka, Navodila za montažo) vsi Nowodvorski URL-ji brez sheme
(`//pim.nowodvorski.com/media/files/10017.jpg`), medtem ko so Braytronovi že polni
(`https://cdn.braytron.center/...`) — pri protokol-relativnem URL-ju se povezava ne odpre, kjer
stran ni servirana prek istega protokola (CSV, urejevalniki, e-pošta).

Vzrok: NW_XML pošlje pot brez sheme, preslikave v `ProductMedia.Url` in v oba dokumentna atributa
(`ProductDocument.Energijska nalepka`, `ProductDocument.Navodila za montažo`) pa niso imele
nobenega koraka v `map.FieldTransform` — `map.ApplyValueTransforms` polje brez aktivnega koraka
sploh ne obdela, vrednost gre v canon/pim nespremenjena. Braytron pošilja že poln URL po svojih,
ločenih preslikavah (BT_XML) — nanje migracija ne vpliva.

- **Nova pretvorba `HTTPSPREFIX`** (`map.ApplyValueTransforms`, oznaka `/* HttpsPrefix220 */`):
  `"//..."` → `"https://..."`; karkoli drugega (že absoluten URL) pusti pri miru — varno tudi, če bi
  Nowodvorski nekoč začel pošiljati poln URL.
- **`map.FieldTransform`:** nov korak `HTTPSPREFIX` na vseh 12 aktivnih NW_XML preslikavah v
  `ProductMedia.Url` in `ProductDocument.*` (doslej brez koraka) — od naslednjega zajema naprej
  pride URL v canon/pim že popravljen.
- **Obstoječi podatki:** enkraten popravek `canon.ProductMedia` (26.726 vrstic), `pim.ProductMedia`
  (23.080), `canon.ProductDocument` (6.134), kjer je `Url LIKE '//%'`.

Preverjeno na `DAVID\MSSQL19`: po migraciji 0 protokol-relativnih URL-jev v vseh treh tabelah;
poln izvoz (`out.GetExportRows`, `NW.10580`) vrne `https://pim.nowodvorski.com/...` za slike in za
dokument (`.../Manuals/10580-2.pdf`).

**Objekti:** `map.FieldTransform` (nov CK-omejitev vrednosti, 12 novih vrstic), `map.ApplyValueTransforms`
(nova veja), `canon.ProductMedia`, `pim.ProductMedia`, `canon.ProductDocument` (enkraten popravek podatkov).

**Ročni korak po uvedbi:** ni potreben; migracija je ponovljiva. Kot 219 je bila na lokalni bazi
pognana neposredno prek `sqlcmd`; za produkcijo jo je treba pognati prek `PIM.Migrator`.

## QUOTED_IDENTIFIER OFF na map.ApplyValueTransforms lomi UPDATE proti filtriranemu indeksu (migracija 230, 2026-09-18)

Od 17. 9. 2026 13:34 (5 minut po zadnjem uspešnem teku) je `SAOP_PRICES` na `/sistem` padal za vsa
štiri podjetja identično, z `UPDATE failed because the following SET options have incorrect
settings: 'QUOTED_IDENTIFIER'. ...` (SQL Server napaka 1934).

Vzrok, potrjen na `DAVID\MSSQL19` prek `sys.sql_modules.uses_quoted_identifier`:
`map.ApplyValueTransforms` je imela to nastavitev izklopljeno, spremenjena natanko 2026-09-17
13:34:38. Veriga: migracija 218 je istega dne na `map.ExtractedValue` dodala filtriran indeks
(`IX_ExtractedValue_Identity ... WHERE TargetFieldCode IN (...)`) — od takrat vsak
UPDATE/INSERT/DELETE na tej tabeli zahteva `QUOTED_IDENTIFIER ON` za celo sejo. Migracija 220 je
`map.ApplyValueTransforms` spremenila mimo običajnega vzorca (`OBJECT_DEFINITION` → vrinjena veja →
`sp_executesql`) **brez** predhodnega `SET QUOTED_IDENTIFIER ON` — in ker je bila (glej opombo pri
220) pognana neposredno prek `sqlcmd` (privzeto `QUOTED_IDENTIFIER OFF`, razen z `-I`), je proceduro
trajno zapekla z izklopljeno nastavitvijo. `map.ApplyValueTransforms` znotraj sebe UPDATE-a prav
`map.ExtractedValue`, zato je od takrat padel vsak klic z vsaj enim aktivnim korakom v
`map.FieldTransform` — pri `SAOP_PRICES` gre skozenj skoraj vsako polje (npr. `NUMBER`), zato je
prvi opazen; po istem mehanizmu tvegata tudi `SAOP_PRODUCTS` in `GENERIC_XML` (obe kličeta isto
proceduro, prva prek `PIM.KatalogWorker`, druga prek `PIM.XmlFileWorker`).

Ista poizvedba je razkrila še tri starejše procedure v isti pomoti, spremenjene že 2026-09-02 (pred
218/220, neodvisno od te napake): `ops.BeginRun`, `ops.AbandonOrphanRuns`, `ops.RecordRunCounts`.
Doslej niso padle, ker tabele, ki jih pišejo (`ops.PipelineRun`, `ops.IntegrationHealth`), (še)
nimajo filtriranega indeksa — a so pod istim tveganjem ob naslednjem, zato jih popravi ista
migracija.

Popravek: za vse štiri procedure `SET QUOTED_IDENTIFIER ON` pred `ALTER PROCEDURE` (isti
`OBJECT_DEFINITION`→`ALTER`→`sp_executesql` vzorec kot 220, tokrat s pravilno SET opcijo pred
klicem) — brez vsebinske spremembe kode, popravi se izključno metapodatek.

Preverjeno na `DAVID\MSSQL19` (`PIM.Migrator`, brez `--verify`): migracija uporabljena,
`sys.sql_modules.uses_quoted_identifier` za vse štiri objekte po popravku `1`.

**Objekti:** `map.ApplyValueTransforms`, `ops.BeginRun`, `ops.AbandonOrphanRuns`,
`ops.RecordRunCounts` (samo metapodatek `uses_quoted_identifier`, telo nespremenjeno).

**Ročni korak po uvedbi:** ni potreben; migracija je ponovljiva in gre skozi `PIM.Migrator` (ne
neposredno prek `sqlcmd`) — s tem se ista napaka ne ponovi.

## Premik kategorije mora posodobiti tudi njeno kodo (migracija 229, 2026-09-18)

Uporabnik je na strani "Kategorije" povlekel vejo "Pritrdila" izpod "Cameleon sistem" pod "Notranja
svetila" (glej posnetek zaslona v seji) in opozoril, da se koda v desnem panelu ni spremenila.
228 je to naredila namerno ("Kategorija je stabilna entiteta: pri premiku se njena koda ne
spremeni.") — narobe: koda je fizično sestavljena kot `starševaKoda___slug` (078/178), zato je po
premiku pod drugega starša vizualno še vedno kazala na STAREGA starša
(`cameleon_sistem___pritrdila` bi moral postati `notranja_svetila___pritrdila`), čeprav sta
`CategoryPath` in `ParentCategoryCode` že kazala na novo mesto. Enak vzorec zamenjave predpone
(za celo poddrevo, ne le za koren) je 223 že uvedla za preimenovanje SL naziva; ta migracija ga
uporabi tudi za premik.

`canon.MoveCategories` zdaj za vsako premaknjeno korensko vejo izračuna njen "lastni" del kode
(brez stare predpone starša) in iz njega sestavi novo kodo za ciljnega starša — enaka zamenjava
predpone kot za `CategoryPath`, uporabljena na CELO poddrevo (koren + vsi potomci). Ker
`FK_CategoryAttributeSet_Category` kaže na `canon.Category(CategoryTreeCode, CategoryCode)`, je
okrog `UPDATE canon.Category` + `UPDATE canon.CategoryAttributeSet` isti `NOCHECK`/`WITH CHECK CHECK`
ovinek kot v 223. Kodo za celo poddrevo dobijo tudi `canon.CategoryTranslation(History)`,
`map.CategoryPathMap` (+ vpis v `CategoryPathMapHistory`), `val.FieldRequirement` — enak nabor kot
223 — in dodatno `pim.TitleRule.CategoryCode`, ki ga je 223 pri preimenovanju spregledala (naslov,
izračunan po pravilu, vezanem na kategorijo, bi drugače po premiku "odpadel" s te kategorije, čeprav
`canon.GetCategoryChangeImpact` (228) `TitleRuleCount` že šteje kot del vpliva premika). Uvrstitve
izdelkov (`canon.ProductCategory` / `pim.ProductCategory` / `pim.ProductCategoryOverride`) ostajajo
nedotaknjene v tem koraku — te že premika 228 po `CategoryPath` BESEDILU; prilagoditi je bilo treba
le vrstni red, ker poizvedba, ki po `UPDATE` prebere novo prevedeno pot iz
`canon.CategoryPathTranslated`, mora vozlišče zdaj poiskati po NOVI kodi.

Postopek poleg obstoječega povzetka (RootCount/CategoryCount/AssignmentCount) vrne še en nabor
vrstic — (CategoryTreeCode, OldCategoryCode, NewCategoryCode) za vsako premaknjeno korensko vejo.
`CategoryTreeService.MoveCategoriesAsync` ga prebere (drugi `NextResultAsync`) v nov
`CategoryChangeResult.CodeChanges`; `CatalogCategories.razor` (`ConfirmMoveAsync`) ga uporabi, da po
premiku spet izbere isto vozlišče v UI — enak razlog kot OUTPUT parameter pri 223.

Preverjeno na `DAVID\MSSQL19` neposredno prek `canon.MoveCategories`, dvakrat in nato nazaj (stanje
baze po testu enako kot pred njim):
- `svetila_si`/`cameleon_sistem___pritrdila` → pod `notranja_svetila`: koda pravilno postane
  `notranja_svetila___pritrdila`, `CategoryTranslation` (sl/en), `map.CategoryPathMap` (1 vrstica,
  `NW_XML`) in vse uvrstitve (`canon.ProductCategory` 36, `pim.ProductCategory` 27, za oba jezika
  svetila_si/svetila_si_en) sledijo na novo kodo/pot.
- `videlektro`/`instalacije___kabli_in_vodniki___kabelski_koncniki_in_spojke` → pod `instalacije`:
  koda postane `instalacije___kabelski_koncniki_in_spojke`; `canon.CategoryAttributeSet` (4 vrstice)
  se pravilno preseli na novo kodo, `FK_CategoryAttributeSet_Category` po koncu ostane omogočen in
  zaupanja vreden (`is_disabled=0`, `is_not_trusted=0`) — `NOCHECK`/`WITH CHECK CHECK` ovinek deluje.

Opažena, a NAMERNO nedotaknjena stranska tema: `videlektro`/B2C ima za iste izdelke svoj, ločen
"zrcaljen" zapis kategorije v `canon.ProductCategory` (`WebSite='B2C'`, besedilo z vnaprej dodanim
"Razsvetljava > ", npr. `Razsvetljava > Cameleon sistem > Pritrdila` — glej 216/217/219), ker je
`videlektro` SVOJE, ločeno drevo (`CategoryTreeCode='videlektro'`), ne isto kot `svetila_si`. Premik
znotraj drevesa `svetila_si` ga zato ne dotakne in po premiku ostane s starim imenskim segmentom v
besedilu, dokler ne izvozi/osveži nekdo ta zrcaljeni zapis posebej — to je obstoječa lastnost
216/217/219 zrcaljenja, ne nova napaka te migracije, in ni bila del uporabnikovega poročila.

**Objekti:** `canon.MoveCategories` (spremenjena — nov izračun kode za premaknjeno poddrevo, nov drugi
nabor rezultatov), `canon.CategoryTranslation(History)`, `canon.CategoryAttributeSet`,
`map.CategoryPathMap(History)`, `val.FieldRequirement`, `pim.TitleRule` (dodatne posodobitve kode ob
premiku — brez sprememb sheme). `canon.GetCategoryChangeImpact` in `canon.DeleteCategories` se ne
spremenita.

**Koda v istem commitu:** `CategoryTreeService.cs` (`CategoryChangeResult.CodeChanges`, nov
`CategoryCodeChange` zapis, `MoveCategoriesAsync` bere drugi nabor rezultatov),
`CatalogCategories.razor` (`ConfirmMoveAsync` po premiku izbere vozlišče po novi kodi).

**Ročni korak po uvedbi:** ni potreben; migracija je ponovljiva. Za produkcijo jo je treba pognati
prek `PIM.Migrator`.

## 229 je predpostavljala napačno kodno obliko za zrcaljeno vejo Razsvetljava (migraciji 230, 231; 2026-09-18)

Uporabnik je po 229 v UI naletel na pravo SQL napako namesto lepega sporočila: *"Violation of UNIQUE
KEY constraint 'UQ_Category_TreeCode' ... duplicate key value is (videlektro, razsvetljava___xxx)"*.
Vzrok: migracija 092 je pod `videlektro`/`razsvetljava` zrcalila celo drevo `svetila_si`, a je
OBDRŽALA identične kode (`cameleon_sistem`, `tracni_sistemi`, `tracni_sistemi___1_fazni_24v_nano_lvm`
…), čeprav je `ParentCategoryCode` preusmerjen v videlektro hierarhijo — koda torej NE sledi vedno
vzorcu `starševaKoda___slug`, ki ga je 229 predpostavljala povsod. Preverjeno na `DAVID\MSSQL19`:

```sql
SELECT CategoryTreeCode, CategoryCode, ParentCategoryCode FROM canon.Category
WHERE ParentCategoryCode IS NOT NULL AND CategoryCode NOT LIKE ParentCategoryCode + '___%';
```

vrne 11 vrstic, vse pod `videlektro`/`razsvetljava`.

**230** doda `@Roots.CodeIsWellFormed`: za vsako korensko vejo preveri, ali predpostavka drži za
CELO poddrevo (koren glede na svojega dejanskega starša IN vsak potomec glede na kodo korena kot
dobesedno predpono). Če ne drži, koda za to vejo (koren + vsi potomci) ostane NESPREMENJENA — vrne se
na prvotno obnašanje 228 — medtem ko `ParentCategoryCode`/`LevelNo`/`CategoryPath` še vedno sledijo
premiku. Za standardno kodirane veje (velika večina drevesa) ostane popravek iz 229 v celoti veljaven.

**231** — pri lastnem preverjanju 230 (ne pri uporabniku) sem odkril drugo, resnejšo napako: premik
"tracni_sistemi" (zrcaljena veja) je zaradi PRESEGA obsega (glej spodaj) potegnil s seboj še 5
kategorij, ki so dejansko otroci DRUGE, pravilno kodirane kategorije `razsvetljava___tracni_sistemi`
(isto ime "Tračni sistemi", različna koda — native videlektro veja in zrcaljena veja se po naključju
imenujeta enako, torej imata IDENTIČNO prikazano pot). Ko UPDATE preslika `ParentCategoryCode` prek
`parentMap` (LEFT JOIN na `@Affected`), za te "tuje" otroke ujemanja ni (njihov pravi starš ni del
premika) in `parentMap.NewCode` je NULL — 230 je to NULL brez zaščite zapisala naravnost v
`ParentCategoryCode`, 5 kategorij je obviselo brez starša. Podatke sem takoj popravil na
`DAVID\MSSQL19` (rekonstrukcija `ParentCategoryCode`/`CategoryPath`/`LevelNo` iz nepoškodovanega
`CategoryName` prek rekurzivnega CTE — prvi poskus popravka prek ročno vtipkanih literalov je zaradi
sqlcmd privzetega kodnega nabora (brez `-f 65001`) pokvaril šumnike v besedilu; to je bila napaka
moje popravne skripte, ne podatkov). **231** doda `ISNULL(parentMap.NewCode, node.ParentCategoryCode)`
namesto golega `parentMap.NewCode`, da ostane `ParentCategoryCode` nespremenjen, kadar pravi starš
potomca ni del premika.

**Nepopravljen, širši, PREDHODNO OBSTOJEČ problem (ni del te migracije):** `@Roots`/`@Affected` v
228/229/230/231 določajo obseg premika/brisanja/predogleda izključno po BESEDILU `CategoryPath`
(`node.CategoryPath LIKE root.CategoryPath + ' > %'`), ne po dejanski verigi `ParentCategoryCode`.
Kadarkoli dve kategoriji v istem drevesu delita identično prikazano pot (isto ime, isti neposredni
prikazani starš, a različna koda — kot `razsvetljava___tracni_sistemi` proti zrcaljeni `tracni_sistemi`),
bo premik ALI TRAJNO BRISANJE ene od njiju napačno zajelo tudi poddrevo druge. To ni nekaj, kar je
vpeljala 229/230/231, in vpliva na `canon.MoveCategories`, `canon.DeleteCategories` ter
`canon.GetCategoryChangeImpact` (isti vzorec v vseh treh). Pravi popravek bi obseg moral graditi z
rekurzivnim sledenjem `ParentCategoryCode`, ne s poizvedbo po besedilu poti — večji, tvegan poseg v
vse tri procedure, namenoma izven obsega teh dveh migracij. **Uporabnik je bil o tem obveščen in
mora odločiti, ali in kdaj naj se to popravi.**

Preverjeno na `DAVID\MSSQL19`: premik `videlektro`/`tracni_sistemi` (z zrcaljenimi otroki) in
`svetlobni_viri_in_dodatki` v `instalacije` — koda pravilno ostane nespremenjena, brez SQL napake;
premik `videlektro`/`instalacije___kabli_in_vodniki___kabelski_koncniki_in_spojke` (standardno
kodirana veja s 4 vrsticami `canon.CategoryAttributeSet`) v `instalacije` — koda se pravilno preimenuje,
FK ostane omogočen; po 231 se `ParentCategoryCode` petih "tujih" otrok pravilno ohrani (ni več NULL).
Vsi testni premiki so bili ročno povrnjeni v izvirno stanje (preverjeno brez osirotelih vrstic v celi
`canon.Category`).

**Objekti:** `canon.MoveCategories` (spremenjena dvakrat — 230 doda `CodeIsWellFormed`, 231 popravi
`ParentCategoryCode` ob nejasnem starševstvu). `canon.GetCategoryChangeImpact` in
`canon.DeleteCategories` se ne spremenita (a delita isto, zgoraj opisano nepopravljeno tveganje).

**Ročni korak po uvedbi:** ni potreben; obe migraciji sta ponovljivi. Za produkcijo ju je treba
pognati prek `PIM.Migrator`.

## Drobtinica poti v drevesu kategorij sledi izbranemu jeziku (migracija 235, 2026-09-21)

Uporabnik je na `/nastavitve/kategorije` zamenjal jezik filtra na en in opozoril, da se ime v glavi
desne plošče prevede ("Downlights"), pot pod njim ("Notranja svetila > Downlights") pa ostane
slovenska — pričakoval je "Interior lighting > Downlights". Koda kategorije
(`notranja_svetila___downlights`) mora po njegovih besedah ostati nespremenjena.

Vzrok: `intranet.GetCategoryTree` je `CategoryPath` od nekdaj vračal neposredno iz
`canon.Category.CategoryPath` — slovenske, "kanonične" poti, ki se nikoli ni prevajala. `DisplayName`
v `CatalogCategories.razor` že bere `TranslationsJson` in prikaže ime v izbranem jeziku, a stran ni
imela ločenega, prevedenega stolpca za pot.

**235** doda stolpec `CategoryPathDisplay`: pot v `@LanguageCode`, prek `canon.CategoryPathTranslated`
(rekurziven pogled iz 059, ki manjkajoč prevod posameznega prednika že nadomesti z njegovim
slovenskim imenom — enako počne za pot spletne trgovine). Izračunan **enkrat v začasno tabelo**
(`#PotPrikaz`, filtrirano na `@CategoryTreeCode`/`@LanguageCode`), ne prek `OUTER APPLY` na vsako
vrstico — korelirano `APPLY` nad tem pogledom je bilo v 218 izmerjeno na 6 s na drevo, enak vzorec kot
`#Uvrstitev`/`#Spodaj` v isti proceduri. Zunanji `ISNULL(pot.CategoryPath, v.CategoryPath)` lovi rob
primer, ko za jezik v celi bazi še ni zapisanega niti enega prevoda (tedaj ga niti `CROSS JOIN` znotraj
pogleda ne zajame).

Obstoječi `CategoryPath` (slovenska pot) ostane **nespremenjen** in ga stran še naprej uporablja za
notranjo logiko (zlaganje vej `Collapsed`, iskanje `@Iskanje`, `VejaFilter`/`ZPredniki`) — sprememba
teh primerjav na prevedeno pot ni bila del prijavljene napake in bi pri delno prevedenem drevesu
tvegala neujemanje. `CategoryTreeService.TreeRow` dobi novo polje `CategoryPathDisplay`;
`CatalogCategories.razor` ga uporabi na treh mestih, kjer je pot doslej prikazovala uporabniku
(glava izbrane kategorije, drobtinica v urejevalniku atributov, drobtinica v urejevalniku imen) — ne
pa tudi v izbirnikih za ustvarjanje/premik kategorije (`CategoryOptionRow`), ki namenoma ostanejo
slovenski (izbira starša po imenu/poti, neodvisno od jezikovnega filtra drevesa).

Preverjeno na `DAVID\MSSQL19`, veja `notranja_svetila___downlights`: `@LanguageCode = N'en'` vrne
`CategoryPath = 'Notranja svetila > Downlights'`, `CategoryPathDisplay = 'Interior lighting >
Downlights'`; `@LanguageCode = N'sl'` vrne enak niz v obeh stolpcih; `CategoryCode` se v nobenem
primeru ne spremeni.

**Objekti:** `intranet.GetCategoryTree` (nov stolpec `CategoryPathDisplay`, brez spremembe
obstoječih).

**Ročni korak po uvedbi:** ni potreben; migracija je ponovljiva. Za TEST/produkcijo prek
`PIM.Migrator`.

## Odstranitev varovalke "artikel ni pripravljen za ERP" (migracija 236, 2026-09-21)

Uporabnik je na kartici izdelka poskusil hkrati popraviti dve manjkajoči obvezni SAOP polji
(Knjižna skupina, Skupina popusta) na artiklu s 5 odprtimi blokirajočimi napakami — oba poskusa
je sprožilec `out.TR_OutboxMessage_ErpQualityGate` (194, popravljen v 195) zavrnil z napako 51497
"Artikel ni pripravljen za ERP.". Popravek iz 195 iz preverbe izvzame samo polje, ki ga trenutno
vpisano sporočilo samo popravlja — pri **več** hkratnih blokirajočih napakah na istem artiklu
(kot v tem primeru) ostane vsak posamezen popravek zavrnjen, ker sosednje, še nerešene napake
ostanejo v preverbi. Uporabnik se je namesto še ene zakrpe iste vzorčne napake odločil, da
varovalke na tej poti ne bo več: vsako polje — ERP ali ne — se vedno da urediti in uvrstiti v
vrsto za SAOP; sinhronizacija ostane preprosto "čaka odobritev" na kartici, SAOP-ova lastna
validacija ob dejanskem pošiljanju pa je edina preostala zavora.

**236** odstrani `out.TR_OutboxMessage_ErpQualityGate` v celoti — to je bila edina "neobhodna ERP
varovalka" v odhodni poti, pokrivala je vstop v vrsto IN vsak kasnejši prehod stanja (odobritev
iz `out.ApproveOutboundBatch`, prevzem iz `out.ClaimItemDocument`/`out.ClaimItemDocumentByKey`,
retry) — z odstranitvijo izginejo vsi trije zavrnitveni prehodi hkrati. `val.IsProductChannelReady`
(194) in `val.IsProductChannelReadyForField` (195) gresta stran skupaj s sprožilcem, ker je bil
ta njun edini klicatelj (preverjeno po `sql/migrations` in `PIM.Intranet`).

Kaj **ostane** nespremenjeno: `val.ProductHold`/`val.SetProductHold` (ročni zadržek) ostaneta —
še naprej izključujeta artikel iz spletnega izvoza (`out.GetExportRows`), le za ERP vrsto ne
vplivata več, ker je edina pot, po kateri je ERP kanal zanju sploh vedel, izginila s
sprožilcem. `val.ProductChannelReadiness`/`intranet.GetQualityProducts` (nadzorna plošča
kakovosti, "blokirajoče napake" na kartici izdelka) ostaneta nespremenjena — napake se še naprej
štejejo in prikazujejo kot informacija, le vrste več ne zapirajo.

Preverjeno na `DAVID\MSSQL19`: pred migracijo je artikel `F5-TRANSFORM-PROBE` (podjetje 2, 13
odprtih blokirajočih napak) na poskus vpisa `Product.AccountingGroup` in `Product.DiscountGroup`
hkrati padel z 51497 na obeh vrsticah; po migraciji (test znotraj `BEGIN TRAN … ROLLBACK`, brez
trajne spremembe) sta obe vrstici vrnjeni kot `Queued`. F8 (`PIM.F8.BulkOutboundTests`, izolirana
organizacija 9822 — množično naročilo, delna zavrnitev, prekrivka, odobritev/preklic skupine) po
migraciji še vedno PASS.

**Objekti:** `out.TR_OutboxMessage_ErpQualityGate` (odstranjen), `val.IsProductChannelReady`
(odstranjena), `val.IsProductChannelReadyForField` (odstranjena). `val.ProductHold`,
`val.SetProductHold`, `val.ProductChannelReadiness`, `intranet.GetQualityProducts` nespremenjeni.

**Ročni korak po uvedbi:** ni potreben; migracija je ponovljiva (`DROP … IF OBJECT_ID …`). Za
TEST/produkcijo prek `PIM.Migrator`. Na tej razvojni bazi (`DAVID\MSSQL19`) je že uveljavljena.

## Pripravljenost zahteva svežo validacijo (migracija 236_ReadinessRequiresFreshValidation, 2026-09-21)

`val.ProductChannelReadiness` je kazal `IsErpReady`/`IsWebReady` = 1 tudi pri validaciji, starejši
od dveh ur (`IsValidationStale` = 1) — ista vrstica je hkrati trdila »zastarelo« in »pripravljeno«.
Migracija doda pogoj `LastValidatedUtc >= DATEADD(hour, -2, SYSUTCDATETIME())` v oba stolpca
pripravljenosti; števci napak in zadržkov so nespremenjeni. Ista meja kot prej v odstranjeni
`val.IsProductChannelReady` (194). Kartica izdelka in `/kakovost/artikli` kažeta »Potrebna
preverba« in gumb »Preveri zdaj« (`QualityWriteService.ValidateAsync`); ERP ocena je informativna
(glej 236_OdstranitevErpPripravljenostneVarovalke zgoraj).

Opomba: dve migraciji nosita številko 236 (ta in `236_OdstranitevErpPripravljenostneVarovalke`), ker
sta nastali vzporedno. `PIM.Migrator` ju vodi po celem imenu datoteke in sta obe v
`dbo.SchemaMigration`; nobene od njiju ne preimenuj.

**Objekti:** `val.ProductChannelReadiness` (pogled, `CREATE OR ALTER`).

**Ročni korak po uvedbi:** ni potreben; migracija je ponovljiva. Na razvojni bazi `DAVID\MSSQL19` je
uveljavljena (2026-09-21 14:33); preverba `IsValidationStale = 1 AND (IsErpReady = 1 OR IsWebReady = 1)`
vrne 0 vrstic.

## Enotni model opravil in gostitelj avtomatike (migracija 237, 2026-09-21)

Uporabnik: »Problem ni število strani, ampak to, da so pomešani poslovni tokovi, urniki, worker
procesi in nadzor.« Cikel »katalog« (221) je v enem teku izvajal zajem artiklov, zajem naročil,
validacijo in objavo štirih podjetij ter izvoz; izvoz je z `--osvezi-validacijo` validiral; urniki so
bili na dveh ravneh (`ops.WorkerCycle`, `ops.ScheduleProfile`); cikel je po padlem vhodu izvoz
izvedel vseeno; ura je bila vezana na proces intraneta. V razvojni bazi sta bila `WorkerCycleRunId`
188 in 192 tri ure in pol `Running` brez utripa, najem je potekel ob 11:26 UTC.

**237** uvede eno raven: `ops.JobDefinition` (posel = ena odgovornost, urnik, časovna meja, SLA,
poslovni tok), `ops.JobDependency` (vrata `IsGate` in sprožilec `TriggersDependent`), `ops.JobRun`
(vedno konča kot Succeeded/Warning/Failed/TimedOut/Cancelled/Abandoned ali je Blocked),
`ops.JobStepRun`, `ops.DataCheckpoint`, `ops.Artifact`. `ops.SchedulerLease` dobi `Priority`:
gostitelj (10) vzame uro intranetu (0). Prevzem (`ops.ClaimJobRun`) je edina vrata in zapiše
blokado z razlogom; `ops.CompleteJobRun` zapiše kontrolno točko, sproži odvisne in zapre alarme;
`ops.AbandonStaleJobRuns` zapre zagone brez utripa 10 min; `ops.EvaluateJobAlerts` odpira
`JobOverdue`, `JobFailed`, `JobBlocked`, `AutomationHostDown`. Ročni zagon in ustavitev iz intraneta
sta zahtevi (`ops.RequestJobRun`, `ops.RequestJobCancel`), ki ju prevzame gostitelj. Zasejanih je
15 poslov (`SAOP_OUTBOUND_DISPATCH` izklopljen) in 6 odvisnosti; naročila so brez odvisnosti.
Migracija zapre viseče zagone starih ciklov brez utripa (30 min) prek `ops.AbandonWorkerCycleRuns`.
Stari cikli ostanejo (prehodno obdobje, glej `docs/AVTOMATIZACIJA.md` §7). Celotna zasnova:
`docs/AVTOMATIZACIJA.md`.

Preverjeno na `DAVID\MSSQL19`: migracija uporabljena dvakrat (drugič brez sprememb), zagona 188 in
192 sta `Abandoned`, `PIM.F11.AutomationTests` (blokada, ponovitev, sprožilec, alarm, zapuščen zagon,
ustavitev, ročna zahteva) PASS.

**Objekti:** tabele `ops.JobDefinition`, `ops.JobDependency`, `ops.JobRun`, `ops.JobStepRun`,
`ops.DataCheckpoint`, `ops.Artifact` (nove); stolpec `ops.SchedulerLease.Priority` (nov);
procedure `ops.AcquireSchedulerLease` (nov parameter `@Priority`), `ops.EnsureJobDefinition`,
`ops.EnsureJobDependency`, `ops.SetJobNextDue`, `intranet.SaveJobSchedule`, `ops.RequestJobRun`,
`ops.RequestJobCancel`, `ops.ClaimJobRun`, `ops.HeartbeatJobRun`, `ops.RecordJobStepRun`,
`ops.SetDataCheckpoint`, `ops.RegisterArtifact`, `ops.CompleteJobRun`, `ops.AbandonStaleJobRuns`,
`ops.EvaluateJobAlerts`, `intranet.GetJobDefinitions`, `intranet.GetJobRuns`,
`intranet.GetJobStepRuns`, `intranet.GetAutomationHost` (nove); omejitev
`CK_UserAlertSubscription_Kind` (razširjena s štirimi vrstami) in naročnine skrbnikov nanje.

**Ročni korak po uvedbi:** migracija je ponovljiva in samozadostna za bazo. Za delovanje avtomatike
je treba na strežniku namestiti storitev `PIM.AutomationHost` (`deploy\Install-AutomationHost.ps1`)
in zunanji nadzor (`scripts\Namesti-nadzor-avtomatike.ps1`); dokler storitev ne teče, intranet
poganja stare cikle kot rezervo in kartice na `/sistem` kažejo »GOSTITELJ NE TEČE«. Za
TEST/produkcijo prek `PIM.Migrator`.

## Nova kategorija z imeni v vseh jezikih (migracija 237_NovaKategorijaZImeniVVsehJezikih, 2026-09-21)

Uporabnik (»napake kategorij v PIM«): »ko izbereš angleško drevo se pot pokaže v slovenščini« in
»dodajanje angleške podkategorije ni možno ker jo doda v slovensko drevo«. »Angleško drevo« na
`/nastavitve/kategorije` je isto drevo (`svetila_si`, `videlektro`) v jeziku `en` (filter »Jezik v
ospredju«); drevo je eno, `canon.Category` nosi slovensko (kanonično) ime, kodo in pot,
`canon.CategoryTranslation` pa imena v ostalih jezikih. Obrazec za novo kategorijo je ponujal samo
»Ime (slovensko)«, zato je angleško ime pristalo kot slovensko ime (in v kodi/poti), angleškega
prevoda pa ni bilo. Izbirnika starša in cilja premika sta tudi po 235 kazala slovenske poti.

`canon.SaveCategory` dobi neobvezen parameter `@TranslationsJson` (`[{"lang":"en","name":"…"}, …]`):
kategorija nastane s slovenskim imenom (iz njega koda in pot, pravilo 178/223), v isti transakciji pa
se prek `canon.SaveCategoryTranslations` (223) zapišejo imena v ostalih jezikih; neznan jezik
(113003) razveljavi tudi kategorijo (`XACT_ABORT`). Obstoječi klici brez parametra delujejo
nespremenjeno. Intranet: obrazec »+ Dodaj kategorijo« ima polje za vsak jezik (slovensko obvezno,
jezik v ospredju poudarjen); `CategoryTreeService.GetCategoryOptionsAsync(tree, jezik)` vrne
`DisplayName`/`DisplayPath` prek `canon.CategoryPathTranslated` (059) — izbirnik starša, cilj premika
in napis »Nova lokacija« govorijo jezik v ospredju, slovenska pot ostane za notranjo logiko.

Preverjeno na `DAVID\MSSQL19` (BEGIN TRAN … ROLLBACK): `SaveCategory` z en+de ustvari `sl`, `en`, `de`
prevode in pravilno pot; podkategorija pod njo dobi kodo `…___podkategorija_237`; jezik `xx` pade s
113003 in kategorija ne nastane.

**Objekti:** `canon.SaveCategory` (nov neobvezen parameter, brez spremembe obstoječih).

**Ročni korak po uvedbi:** ni potreben; migracija je ponovljiva. Za TEST/produkcijo prek
`PIM.Migrator`.

## Register atributov: dodaj, uredi, izbriši (migracija 238_AtributiDodajUrediIzbrisi, 2026-09-21)

Uporabnik (»nemore se dodajat atributov«): »treba dodat da se dodaja piše briše«. Stran
`/nastavitve/atributi` je znala samo prevesti ime in povezati enoto; nov atribut je nastajal
stransko (`canon.EnsureAttributeDefinition`, 177), osnovnih lastnosti ni bilo mogoče urejati
(`canon.SaveAttributeDefinition` iz 125 s COALESCE prazne vrednosti ne pobriše), brisanja ni bilo.

Novi postopki (revizija v `b2b.AuditLog` kot pri 177/178):
- `canon.CreateAttributeDefinition` — slovensko ime (obvezno; koda iz imena prek
  `canon.AttributeCodeFromName`, če je klicatelj ne poda), skupina, tip, enota, prevedljivost, opomba
  in imena v ostalih jezikih v eni transakciji; zavrne obstoječo kodo (52385) in obstoječe slovensko
  ime (52386 — vrednosti pri izdelkih se hranijo po imenu, glej 125).
- `canon.UpdateAttributeDefinition` — izrecen pomen: NULL **pobriše** skupino/enoto/opombo/par
  enote; ista pravila za verigo enot kot 125; lahko deaktivira/aktivira.
- `intranet.GetAttributeUsage` — vrednosti pri izdelkih (`canon.ProductAttribute` in
  `pim.ProductAttribute` po slovenskem imenu), nabori kategorij, aktivne preslikave virov, pari enot,
  aktivne zahteve validacije (`val.FieldRequirement`, `ProductAttribute.<ime>`), prevodi, opomba.
- `canon.DeleteAttributeDefinition @AttributeCode, @Actor, @Force` — brez `@Force` zavrne atribut z
  vrednostmi pri izdelkih (52402); z `@Force` jih izbriše. Odstrani prevode in vrstice
  `canon.CategoryAttributeSet`, deaktivira `map.AttributeMap` (vrstica ostane zaradi zgodovine) in
  zahteve validacije, počisti `UnitOfAttributeCode`, zapiše revizijo.

Intranet: panel »+ Nov atribut«, zavihek »Osnovno« z urejanjem lastnosti in »Izbriši atribut …« s
pregledom uporabe, potrditvijo IZBRIŠI in ločeno kljukico za brisanje vrednosti.

Preverjeno na `DAVID\MSSQL19` (BEGIN TRAN … ROLLBACK): ustvarjanje z en prevodom, urejanje z
brisanjem skupine/enote, pregled uporabe, brisanje; dvojnik `Garancija` pade s 52385; brisanje
`GARANCIJA` (51.901 izdelkov) brez `@Force` pade s 52402.

**Objekti:** `canon.CreateAttributeDefinition`, `canon.UpdateAttributeDefinition`,
`intranet.GetAttributeUsage`, `canon.DeleteAttributeDefinition` (vsi novi).

**Ročni korak po uvedbi:** ni potreben.

## ERP opisi ločeni od spletnih (migracija 239_LocitevErpInSpletnihOpisov, 2026-09-21)

Uporabnik (»Opisi ločiti ERP / Splet«): »Trenutno se ERP opisi pojavijo na kartici pod Splet – opisi.
Moramo imeti ERP in pa potem Splet opisi tako v bazi kot v PIM aplikaciji.« SAOP pošilja opise po
jezikih in vrstah (DescriptionType T/O/K/KD/KK), `map.ProcessProductTextInbox` (080) jih je pisal v
`canon.ProductText` kot `DESCRIPTION`, `DESCRIPTION_O`, `DESCRIPTION_K` … — v isto vrsto, ki jo
spletni izvoz in kartica štejeta za spletni opis, in jih z MERGE ob **vsakem zajemu prepisal**:
lastnega spletnega opisa v PIM-u ni bilo mogoče obdržati.

1. Preslikava SAOP (`map.FieldMapping` konektorjev s `CanCreateProducts = 1`) je preusmerjena s
   `ProductTextByLanguage.DESCRIPTION` na `ProductTextByLanguage.DESCRIPTION_ERP`; 080 je
   nespremenjen (vrsto bere iz ciljne kode in pripne pripono: `DESCRIPTION_ERP`, `_ERP_O`, `_ERP_K` …).
   Omejitev `CK_CanonProductText_Type` (143) družino `DESCRIPTION%` že dovoljuje.
2. `DESCRIPTION_ERP*` je napolnjen iz **zadnje** izluščene vrednosti SAOP v `map.ExtractedValue`
   (po istem pravilu kot 080: `Record.ItemID`, `Record.LanguageId` prek `canon.Language`,
   `Record.TextTypeSuffix`) pod virom sprememb `MIGRATION_239` (`pim.SetChangeContext`).
3. Spletni opisi (`DESCRIPTION*`) **ostanejo** — tudi kjer so danes enaki ERP opisu (na razvojni bazi
   22.500 od 22.501 slovenskih): so trenutno besedilo spletne trgovine, ki ga bereta izvoz in
   validacija. Od zdaj jih SAOP ne prepisuje več; kartica pokaže »· enak ERP opisu«, dokler urednik
   ali AI ne napiše spletnega.

Intranet: `ProductFieldLabels.IsErpTextType` (TITLE_ERP*, TITLE_SHORT, SEARCH_NAME,
DESCRIPTION_ERP*) loči kanala: ERP kanal dobi skupino »Opisi iz ERP (SAOP)« (samo prikaz) in »ERP
kratki naziv«, zavihek Splet kaže samo spletna besedila (spletni naziv in spletni opis vedno, tudi
brez vrstice). Na zavihku Splet je nov gumb »Predlagaj naziv in opis (AI)« (`AiTextService`, Claude
prek uradnega SDK; ključ `Ai:ApiKey` v `appsettings.Local.json` ali `ANTHROPIC_API_KEY`, neobvezno
`Ai:Model` in `Ai:Effort`): predlog gre v osnutek kartice in se shrani z istim gumbom kot ročna
sprememba.

Preverjeno na `DAVID\MSSQL19`: po migraciji 58.772 vrstic `DESCRIPTION_ERP` (5 jezikov), 531
`_ERP_K`, 235 `_ERP_O`, 18 `_ERP_KD`, 14 `_ERP_KK`; vse štiri SAOP preslikave ciljajo
`DESCRIPTION_ERP`. Polnjenje je na razvojni bazi trajalo ~20 min (sprožilec zgodovine
`TR_ProductText_FieldHistory` in vzporedni tek drugih opravil) — na produkciji predvidi enak čas.

**Objekti:** `map.FieldMapping` (podatki: 4 vrstice preusmerjene), `canon.ProductText` (podatki:
nove vrstice `DESCRIPTION_ERP*`), `pim.ProductFieldHistory` (zapisi polnjenja pod `MIGRATION_239`).
Brez sprememb postopkov.

**Ročni korak po uvedbi:** ni potreben. Če na ciljni bazi surovih vrednosti SAOP ni več, ERP opise
napolni naslednji tek SAOP (preslikava je že preusmerjena). Za AI predlog nastavi
`"Ai": { "ApiKey": "sk-ant-…" }` v `appsettings.Local.json` ob objavljenem intranetu.

## Kandidati iz XML po EAN, pregled in uvoz (migracija 240_KandidatiIzXmlPoEanPregledInUvoz, 2026-09-21)

Uporabnik (»novi artikli«): »da bo nadzor nad novimi artikli iz xmlja ter pregled in uvoz«.
Ugotovljeno na razvojni bazi: (1) `map.ProcessRawInbox` v bazi ni več vseboval blokov 3b/5b iz 219
(migracija je zabeležena kot uveljavljena, telo pa je bilo starejše) — kandidati niso nastajali;
(2) NW_XML in BT_XML preslikata samo `Product.EAN`, 5b pa je zahteval `ItemID`, zato tudi s 219 ne bi
nastal noben kandidat (zajem BT 2026-09-21, podjetje 4: 3.166 zapisov »Izdelek za konfigurirani
identifikator ne obstaja«, 0 kandidatov); (3) odobritev je ustvarila samo golo vrstico
`canon.Product`, podatki iz XML so prišli šele z naslednjim zajemom.

- `map.SupplierProductCandidate.ItemIdFromEan bit` — kandidat brez dobaviteljeve šifre je ključan po
  EAN (`ItemID = EAN`); ob odobritvi nastane `canon.Product` z `ItemID = EAN`,
  `ErpExistence = NOT_YET_IN_ERP`.
- `map.ProcessRawInbox` — celotno telo iz 219, ključ kandidata `COALESCE(ItemID, EAN)`; kandidat se
  ob ujemanju zapre po šifri ali po EAN (3b).
- `intranet.GetSupplierProductCandidates` — dodatno `RunId`, `EntityType`, `ItemIdFromEan`,
  `SupplierTitle` (naziv iz izluščenih vrednosti istega zajema, kadar ga vir preslika).
- `intranet.GetSupplierProductCandidateValues` — vse izluščene vrednosti zapisov istega zajema z isto
  šifro/EAN (atributi, slike, dokumenti, kategorija) za pregled.
- `map.ImportSupplierProductCandidates @CandidatesJson, @Actor` — odobri izbrane in takoj obogati:
  strani zadevnih zajemov nazaj na `Pending`, nato `map.ProcessRawInbox`, `map.ProcessAttributePairInbox`,
  `map.ProcessDocumentInbox`, `map.ResolveProductCategories` pod `pim.SetChangeContext('XML_IMPORT')`
  — ista pot kot redni zajem. Zajemi se izberejo po šifri/EAN prek vseh zajemov istega vira pri
  istem podjetju (NW pošlje entitete v ločenih tekih); pregled (`GetSupplierProductCandidateValues`)
  enako vzame najnovejši zapis na entiteto. Ponovna obdelava ni nov pojav: `OccurrenceCount` in
  `LastSeenUtc` preostalih čakajočih kandidatov se po obdelavi vrneta na stanje pred uvozom.

Intranet: `/zajem/novi-artikli` dobi zavihek v vhodih in števec »Novi artikli iz XML« na `/zajem`,
gumbe »Podatki iz XML« (pregled), »Uvozi«, »Samo odobri«, »Zavrni …« ter paketni uvoz izbranih.

Preverjeno na `DAVID\MSSQL19`: ponovna preslikava zajema NW_XML podjetja 4
(`681A09A3-B44D-405E-9CCF-28DB11B44529`, 2.619 zapisov) po migraciji ustvari 2.619 kandidatov
`PENDING` z `ItemIdFromEan = 1` v 3 s. Uvoz enega kandidata iz intraneta (EAN 5903139989091) je
ustvaril `canon.Product` 224049 (`ItemID` = EAN, `NOT_YET_IN_ERP`) s 3 slikami, 1 dokumentom, 34
atributi in 4 uvrstitvami — skozi preslikavo sta šla 2 zajema (5 strani) v ~15 s.

**Objekti:** `map.SupplierProductCandidate` (nov stolpec), `map.ProcessRawInbox` (prepis),
`intranet.GetSupplierProductCandidates` (prepis), `intranet.GetSupplierProductCandidateValues` (nova),
`map.ImportSupplierProductCandidates` (nova).

**Ročni korak po uvedbi:** kandidati za obstoječe zajeme nastanejo šele ob naslednjem zajemu
dobaviteljevega XML-ja (ali ob ročni ponovni preslikavi zajema: `PIM.XmlFileWorker --znova-preslikaj
<RunId>`). Za produkcijo ni drugega ročnega koraka.

## Novi artikli iz XML v čakalno vrsto SAOP in prevzem šifre (migracija 241_NoviArtikliIzXmlVCakalnoVrstoSaop, 2026-09-21)

Uporabnik: »rabimo neko stran kjer bodo zaznani novi artikli ki so samo v XMLju in jih urednik
lahko porine v PIM in nato tudi v SAOP cakalno vrsto.« Prvi korak (XML → kandidat → PIM) je dala
migracija 240; ta dodaja drugi korak (PIM → čakalna vrsta SAOP → šifra SAOP) in zapre vrzel, ki je
ostala od 169: `canon.Product.ErpExistence` se ni nikjer postavil na `CONFIRMED_IN_ERP`, šifra, ki
jo SAOP dodeli ob ADD (`SuggestFirstFreeCode`), pa je ostala samo v `out.SaopItemAssignment` —
naslednji zajem SAOP bi z njo ustvaril drug artikel, EAN-ski bi ostal sirota in bi ob vsakem
pošiljanju spet šel kot ADD.

- `CK_OutboundBatch_Source` — dovoljen vir `XML` (poleg SINGLE/BULK/EXCEL/CARD), da so skupine s
  strani kandidatov v `/outbound` in `/saop` razpoznavne.
- `intranet.GetSupplierProductCandidates` — telo iz 240, dodatno za odobrene kandidate:
  `ProductItemId` (trenutna šifra ustvarjenega artikla), `ErpExistence`, `SaopState`
  (`NOT_QUEUED` / `QUEUED` / `SENT` / `FAILED` / `CONFIRMED`), `SaopLiveMessages`,
  `SaopPendingApproval`, `SaopLastStatus`, `SaopLastBatchId`, `SaopLastUpdatedUtc`, `SaopLastError`,
  `SaopAssignedItemId`; nov parameter `@SaopState` (filter) in v povzetku `ImportedWaitingCount`,
  `QueuedCount`, `SentCount`, `FailedCount`, `ConfirmedCount`. Sporočila se iščejo po trenutni šifri
  artikla IN po ključu kandidata (EAN), ker po prevzemu šifre stara sporočila ostanejo pod EAN.
  Iskanje zadene tudi `product.ItemID` (šifro SAOP).
- `out.CompleteItemDocument` — telo iz 196, dodatno ob uspehu: artikel z `NOT_YET_IN_ERP` postane
  `CONFIRMED_IN_ERP`; če je SAOP dodelil drugo šifro, `canon.Product.ItemID` to šifro prevzame (EAN
  ostane; sporočila v vrsti ostanejo pod staro šifro kot zgodovina; `ops.OutboundEvent` Info
  »Artikel je prevzel sifro iz SAOP«). Če šifro v PIM že ima drug artikel, se nič ne preimenuje,
  artikel ostane `NOT_YET_IN_ERP` in nastane `ops.OutboundEvent` Warning »SAOP je dodelil sifro, ki
  jo v PIM ze ima drug artikel« — ročna uskladitev (napačna povezava je slabša od nobene, načelo iz
  046). Ob neuspehu se ne spremeni nič.

Koda (brez nove zapisovalne poti v bazi): `PIM.Outbound.SaopNewItemQueue` (kaj gre v vrsto za nov
artikel: vpisano ima prednost, prazno pomeni »vzemi kanonično«, ključ nikoli; katera polja so na
artikel in katera skupna), `SupplierCandidateSaopService` (pogodba + stanje artikla →
`SaopItemPlanner`, uvrstitev prek `out.EnqueueSaopItemChanges` z virom `XML`, odobritev prek
`out.ApproveItemDocument` po artiklu, »Pošlji zdaj« prek `TrySendArticleAsync`). Test
`PIM.F8.SaopItemPlannerTests` (razdelek 9).

Intranet `/zajem/novi-artikli`: filter »Pot v SAOP«, števci (uvoženi čakajo na SAOP / v vrsti /
zavrnil / potrjeni) za cel obseg podjetja, v vrstici stanje SAOP (skupina, napaka, šifra SAOP),
gumbi »V vrsto SAOP …« (priprava pod vrstico: šifranti ERP, naziv, EAN, mere; manjkajoča obvezna
polja označena; predogled XML; »Uvrsti v čakalno vrsto« ali »Uvrsti in odobri«; nato »Pošlji
zdaj«), »Odobri v vrsti«, »Pošlji zdaj« ter paketna priprava izbranih (skupni šifranti enkrat, naziv
na artikel; stran si skupne vrednosti zapomni po podjetju za sejo).

Preverjeno na `DAVID\MSSQL19` (v transakciji z ROLLBACK, artikel 224049 / EAN 5903139989091,
podjetje 4): uspešen zaključek z dodeljeno šifro `TEST.241.0001` → `ItemID = TEST.241.0001`,
`CONFIRMED_IN_ERP`, dogodek Info, `out.SaopItemAssignment` Response, kandidat `CONFIRMED` s
`SaopAssignedItemId`; trk šifre (šifra obstoječega artikla) → brez preimenovanja, `NOT_YET_IN_ERP`,
dogodek Warning; uspeh brez šifre → samo `CONFIRMED_IN_ERP`; neuspeh → nespremenjeno, sporočilo
`Dead`, kandidat `FAILED` z `SaopLastError`. Pot v SAOP s strani (uvrstitev, odobritev) je bila
preverjena prek storitve proti razvojni bazi; stran sama v brskalniku ni bila preverjena (ni bilo
prijave).

**Objekti:** `out.OutboundBatch` (CK_OutboundBatch_Source), `intranet.GetSupplierProductCandidates`
(prepis), `out.CompleteItemDocument` (prepis).

**Ročni korak po uvedbi:** ni potreben. Pogoj za uvrstitev ostaja omogočen `dbo.IntegrationProfile`
za `SAOP_PRODUCT` (ni migracija, glej ODHODNA_POT_SAOP.md §4); pošiljanje ostaja `PIM.OutboxDispatcher
--send` s poverilnicami ali gumb »Pošlji zdaj« (razdelek `Saop` v `appsettings.Local.json`).

## Objava za splet po izvoznih pravilih, sestava kataloga, zadnji uspeh cikla (migracija 242_ObjavaZaSpletPoIzvoznihPravilih, 2026-09-21)

Uporabnik: »uporabnik mora v aplikaciji videti dejansko izdelan CSV, iskati artikle in razumeti,
zakaj artikel je ali ni objavljen« in »uskladi prikaz /kakovost/artikli z dejanskimi izvoznimi
pravili«. Do te migracije je pogled `val.ProductChannelReadiness` splet računal iz
`canon.Product.WebPublish` (oznaka iz SAOP), izvoz `out.GetExportRows` pa vrstico v `katalog.csv`
določa po kljukicah spletišč (`pim.ProductWebShop.IsPublished`), kategoriji na spletišču, ročnem
zadržku, izključitvi iz kataloga, veljavnosti profilov, ki blokirajo splet, in pravilu 220 (artikel
brez vsake kljukice je v datoteki s praznim stolpcem »Spletne strani«). Stran je zato kazala »Ni za
objavo« pri artiklih v datoteki in »Pripravljen« pri artiklih, ki jih izvoz izpusti.

- `val.ProductChannelReadiness` — novi stolpci `IsPromoted`, `IsExcludedFromCatalog`, `SiteFlagCount`,
  `SiteCategoryCount`, `AllowedSiteCount`, `WebExportState` (`INACTIVE | NOT_PROMOTED | EXCLUDED | HOLD |
  NO_SITE | PUBLISHED | NO_CATEGORY | BLOCKED_ERRORS`), `IsInCatalogCsv`; `IsWebReady` zahteva kljukico
  spletišča namesto `WebPublish` (ta ostane informativen). `IsErpReady` nespremenjen (236).
- `intranet.GetQualityProducts` — nove stolpce vrne; `WEB_BLOCKED`/`READY` po kljukicah; nova stanja
  filtra `IN_CSV`, `NOT_IN_CSV`, `NO_SITE`, `PUBLISHED`; seštevki `InCsvCount`, `NoSiteCount`,
  `PublishedCount`.
- `intranet.GetProductWebExportState @ProductId` (nova) — vrstica pogleda in razlog po spletiščih
  (kljukica, kategorija, neveljavni blokirajoči profili) za kartico artikla (razdelek »Objava za
  splet (katalog.csv)« z gumbom »Preveri zdaj«).
- `intranet.GetWebExportSummary @OrganizationId` (nova) — sestava kataloga za `/splet`.
- `intranet.GetWorkerCycles` — dodan `LastSucceededUtc` (zadnji uspešen zagon, ne samo zadnji poskus).
- Podatki: `ops.WorkerCycle.magento-csv` 300 → 900 s in `ops.JobDefinition.WEB_CATALOG_EXPORT`
  300 → 3600 s, samo kadar je vrednost še privzeta (skrbnikova nastavitev se ne prepiše).

Preverjeno na `DAVID\MSSQL19` (podjetje 2): aktivnih 98.288, objavljenih v PIM 89.851,
`IsInCatalogCsv` = 89.491 = točno število vrstic dejanskega `katalog.csv` (2.176 objavljenih s
spletno stranjo + 87.315 brez spletnega mesta), brez kategorije 167, blokirajoče napake 193, strank
3.988 = vrstice `stranke.csv`. `GetWebExportSummary` 2,3 s; `GetQualityProducts` s filtrom pod
obremenitvijo 13,8 s (pred migracijo ~2 s pri mirni bazi; ponovno izmeriti ob mirni bazi).

**Objekti:** `val.ProductChannelReadiness` (prepis), `intranet.GetQualityProducts` (prepis),
`intranet.GetProductWebExportState` (nova), `intranet.GetWebExportSummary` (nova),
`intranet.GetWorkerCycles` (prepis), `ops.WorkerCycle` in `ops.JobDefinition` (podatki).

**Ročni korak po uvedbi:** ni potreben za bazo. Za izdelavo datotek mora imeti račun, pod katerim
teče worker, pravico pisanja v `EXPORT_ROOT`: `scripts\Nastavi-pravice-izvozne-mape.ps1` kot skrbnik
(glej `docs/WORKERS.md`).

## Ponovna preslikava celega vira brez ponovnega nalaganja (migracija 244_PonovnaPreslikavaVira, 2026-09-22)

Uporabnik: polja na kartici artikla se morajo spreminjati »kadarkoli«, brez oznake »čaka SAOP«, uvoz pa
ne sme nikjer obtičati — napake naj se pokažejo v pojavnem oknu po sklopih (manjkajoča kategorija,
manjkajoč atribut), z gumbom za ustvarjanje, nato naj gre »ista datoteka še enkrat skozi, brez
ponovnega nalaganja«.

Zakaj nova procedura in ne ponoven klic `map.ImportSupplierProductCandidates` (240): ta najprej
odobri kandidate (`map.ApproveSupplierProductCandidate` zahteva `Status = 'PENDING'`), zajeme za
ponovno obdelavo pa izbere samo za pravkar odobrene. Že uvoženi artikli — prav tisti, ki jim manjka
kategorija ali atribut — bi bili preskočeni in njihove surove strani ne bi šle znova skozi preslikavo.

- `map.ReprocessSupplierSource @OrganizationId, @SourceCode, @Actor` — vse zajeme vira pri podjetju
  (strani z izluščenimi vrednostmi) vrne na `Pending` in jih pošlje skozi isto jedro kot redni zajem:
  `map.ProcessRawInbox`, `map.ProcessAttributePairInbox`, `map.ProcessDocumentInbox`,
  `map.ResolveProductCategories` pod `pim.SetChangeContext('XML_IMPORT')`. Napaka enega zajema se
  zapiše in ne ustavi ostalih. `OccurrenceCount`/`LastSeenUtc` čakajočih kandidatov se vrneta na
  stanje pred obdelavo (enako pravilo kot v 240). Vrne `Runs`, `Pages`, `Errors`. Podjetje brez
  zajema vira vrne 0 zajemov. Začasni tabeli imata edinstveni imeni (`#PonovnaTek`, `#PonovnaPrej`),
  ker SQL Server v gnezdeni proceduri ime začasne tabele veže na klicateljevo z istim imenom.

Preslikave kategorij (`map.CategoryPathMap`) in atributov (`map.SaveAttributeMap`) so ključane po viru,
ne po podjetju, zato intranet ob ponovni preslikavi pošlje vir skozi pri **vseh** podjetjih, ki ga imajo.

Intranet (brez sprememb v bazi):
- `ProductChannelPanel.razor` — polja SAOP niso več onemogočena, ko za polje čaka odhodno sporočilo;
  oznaki »čaka SAOP« in »sprememba čaka odobritev« sta odstranjeni. Ponovljeno enako vrednost še
  vedno zavrne `UX_OutboxMessage_ActiveDedup` (021), drugačna vrednost nadomesti čakajočo
  (`Superseded`, 046) — podvajanja v vrsti ni.
- `/zajem/novi-artikli` — po uvozu se odpre okno »Vrzeli po sklopih« (`ImportGapsDialog`):
  nepreslikane kategorije vira (ustvari novo pod izbrano nadrejeno in preslikaj, ali poveži z
  obstoječo), nepreslikani atributi (»Ustvari …« prek `canon.EnsureAttributeDefinition` + preslikava,
  ali poveži z obstoječim) in druge napake uvoza; gumb »Ponovno preslikaj vir« pokliče
  `map.ReprocessSupplierSource`. Isto okno odpre gumb »Vrzeli in ponovna preslikava …« v orodni vrstici.

Preverjeno na `DAVID\MSSQL19` (v transakciji z `ROLLBACK`, v bazi ni ostalo nič): edina nepreslikana
pot NW_XML (»F5 svetila« → drevo `videlektro`) je po preslikavi in `map.ReprocessSupplierSource 4,
'NW_XML'` izginila s seznama vrzeli; 2 zajema, 5 strani, brez napak, vse strani spet `Processed`,
vsota `OccurrenceCount` nespremenjena (2.618), nobena obstoječa uvrstitev izgubljena. Artikel s to
potjo je pri podjetju 2 — zato ponovna preslikava vseh podjetij. Ponovna preslikava NW_XML podjetja 2
(21 strani) v transakciji je trajala več kot 12 minut (hladen predpomnilnik, hkrati `val.RunValidation`)
in je med tem zadrževala worker `ApplyLandingRecord` — test je bil prekinjen in povrnjen. **Gumba ne
poganjaj med nočno uskladitvijo ali urno validacijo**, ker drži zaklepe nad istimi tabelami.

**Objekti:** `map.ReprocessSupplierSource` (nova).

**Ročni korak po uvedbi:** ni potreben. Na razvojni bazi `DAVID\MSSQL19`, kjer je bila ta procedura
najprej uveljavljena pod imenom `243_PonovnaPreslikavaVira.sql` (številko 243 je medtem zasedla
`243_VerifyEchoBatch.sql`), odstrani staro vrstico dnevnika, preden poženeš migracije:

```sql
DELETE FROM dbo.SchemaMigration WHERE MigrationId = N'243_PonovnaPreslikavaVira.sql';
```

## Uvoz delovnega lista: ERP polja v PIM takoj, slike in dokumenti (migracija 245_UvozDelovnegaListaErpTakojSlikeDokumenti, 2026-09-22)

Uporabnik ob datoteki Objemke.xlsx (31 artiklov Vidadria): »morajo se v PIM vstaviti vsi podatki. Sepravi
ERP brez čakanja SAOPa in omejitev, potem kategorije, nazivi splet in pa ERP morajo biti ločeni in ravno tako
opisi, potem atributi, slike, dokumenti, kljukica za izločanje«. Test istega uvoza na razvojni bazi pred
popravkom je pokazal: spletni nazivi, spletni opisi, kategorija Videlektro in dva atributa so se zapisali,
ERP besedila so ostala ločena (TITLE_ERP, DESCRIPTION_ERP nedotaknjena); **ni** pa se zapisalo: ERP polja
(samo v vrsto za SAOP), slike in dokumenti (stolpca samo za branje), 5 atributov, ki jih šifrant ni poznal
(tiho neprepoznani stolpci), kategorija za Videlektro (ANG) (opozorilo na vsaki vrstici), kljukica za
rezervacijo (izvoz je ni bral, zato je bila vedno prazna).

Migracija doda dve proceduri po vzorcu `pim.SaveProductTextsBulk` (218): paket izdelkov v enem klicu,
zgodovina z virom `EXCEL` (sprožilci, kjer jih ni pa ročne vrstice v `pim.ProductFieldHistory`), ena
množična validacija. Slaba vrednost ne podre paketa — vrne se z razlogom.

- `pim.SaveProductErpFieldsBulk` — ERP polja iz registra `out.SaopXmlField` zapiše v katalog takoj:
  `canon.Product`, `canon.ProductCommercial`, `canon.ProductText` (TITLE_ERP, TITLE_ERP2, SEARCH_NAME),
  `canon.ProductAttribute` (Garancija), `canon.ProductPlanning.ExcludeQuantityReservation`. Aplikacija isto
  spremembo prej uvrsti v odhodno vrsto (`out.EnqueueSaopItemChanges`), kjer za pot v SAOP čaka odobritev.
- `pim.SaveProductMediaBulk` — slike (`canon.ProductMedia`, prva PRIMARY, ostale GALLERY, obstoječa AMBIENT
  ostane) in dokumenti (`canon.ProductDocument`, nov dobi vlogo »Dokument«). Celica je cel seznam izdelka;
  kar izdelek ima, v celici pa ni, aplikacija pošlje v `remove` (razvrstitev slika/dokument je
  `MediaKindPolicy`, ista kot izvoz).

Koda v istem koraku (brez sprememb baze): nov atribut pod skupino »Atributi …« se ustvari v šifrantu
(`canon.CreateAttributeDefinition`); jezikovna različica strani brez svoje celice (Videlektro (ANG)) dobi
isto kategorijo kot primarna stran, kadar kategorije nima ali je bila do zdaj usklajena; kljukica za
rezervacijo se bere in izvozi; logična polja so v listu D/N (kot v dokumentih SAOP POST/PATCH), uvoz sprejme
tudi 1/0 in da/ne, v vrsto gredo kot 1/0 (graditelj jih po registru pretvori: IsActive D/N, WebPublish d/N,
ItemExcludeQtyReservation true/false); števila z vejico se sprejmejo, besedilo namesto števila se javi in
preskoči; opozorila kažejo številko vrstice iz Excela. Na izkaznici artikla je kljukica »Izloči iz
rezervacije zaloge« prvič vidna in urejiva (ključ `Planning.ExcludeQtyReservation`), logična polja kažejo
Da/Ne tudi, kadar čakajoča vrednost pride kot 1/0, D/N ali true.

Tveganje, ki ga uporabnik sprejema: zajem iz SAOP prepiše kanonično vrednost, ko se artikel v SAOP spremeni;
dokler SAOP spremembe iz vrste ne prejme, lahko PIM za trenutek spet kaže vrednost iz SAOP.
`out.VerifyEchoBatch` (243) poslano sporočilo potrdi takoj, ker je kanonična vrednost že nova.

**Objekti:** `pim.SaveProductErpFieldsBulk` (nova), `pim.SaveProductMediaBulk` (nova); piše v
`canon.Product`, `canon.ProductCommercial`, `canon.ProductText`, `canon.ProductAttribute`,
`canon.ProductPlanning`, `canon.ProductMedia`, `canon.ProductDocument`, `pim.ProductChangeBatch`,
`pim.ProductFieldHistory`.

**Ročni korak po uvedbi:** ni potreben za bazo. Proceduri kliče samo nova različica intraneta
(`ProductWorkbookService`), zato ju uvedi skupaj z aplikacijo. Na razvojni bazi `DAVID\MSSQL19` je bila
migracija med razvojem uveljavljena s `sqlcmd` in še ni v `dbo.SchemaMigration`; migrator jo bo ob naslednjem
zagonu pognal znova (je idempotentna, `CREATE OR ALTER`).

## En motor avtomatike, pas SAOP in zaloga ter cene na 10 min (migracija 246_EnMotorAvtomatike, 2026-09-22)

Ekipa SAOP je javila, da PIM kliče GetPrices in GetItem brez premora in obremenjuje njihov procesor.
Izmerjeno istega dne: workerje so poganjali trije razporejevalniki hkrati (Windows naloge, razporejevalnik
v IIS, ki se je vklopil ob vsakem zagonu intraneta, in nenameščen `PIM.AutomationHost`). Cikel zaloge
»na 5 min« je trajal 6–11 min in se takoj začel znova, dobavni roki so se iz IIS brali vsakih 30 min.

Koda v istem commitu: gostitelj posle, ki kličejo SAOP (`JobCatalog.UsesSaop`), poganja po enega
naenkrat z 2 min tišine vmes. Naslednji termin šteje od **konca** teka, po zaporednih napakah z odlogom
(razmik × 2^(n-1), največ 4 h). Workerji tečejo v Windows Job Objectu (brez sirot). Vsako podjetje je svoj
korak. Urni zajem artiklov bere samo 8 točk artiklov. Razporejevalnik v IIS je privzeto izklopljen
(vklop samo z `Scheduler:Enabled=true`). Magento cene in zaloga gredo v `<EXPORT_ROOT>\<podjetje>\`.
Nov posel `SUPPLIER_STOCK_IMPORT` (zaloga NW in Braytron) nastane ob zagonu gostitelja.

Migracija uskladi obstoječe vrstice (samo tiste, ki jih ni spreminjal človek, `UpdatedBy` je postopek ali migracija):

- `STOCK_IMPORT` (zdaj samo zaloga iz SAOP) in `PRICE_IMPORT`: razmik 600 s, meja 900 s, SLA 1800 s.
- `WEB_STOCK_EXPORT`: razmik 1800 s (sproži ga uspešna zaloga), meja 1800 s, SLA 3600 s.
- `SAOP_DELIVERY_IMPORT` in `SYSTEM_SELF_TEST`: izklopljena. `NIGHTLY_RECONCILIATION`: ob 00:30.
- `NextDueUtc = NULL` za posle, ki ne tečejo (gostitelj jih razmakne znova).
- Podjetje DEMO (1, predpona `DEMO`) izključeno v `ops.OrganizationAutomationPolicy`.
- Stari cikli `ops.WorkerCycle` izklopljeni. `ops.ScheduleProfile` `SAOP_DELIVERY`: 1 dan, zastarelost 36 h.

**Objekti:** `ops.JobDefinition`, `ops.OrganizationAutomationPolicy`, `ops.WorkerCycle`, `ops.ScheduleProfile` (samo podatki).

**Ročni korak po uvedbi:** da. Workerje mora poganjati samo `PIM.AutomationHost` (storitev ali konzola).
Windows naloge »PIM zaloga«, »PIM katalog«, »PIM nadzor« in »PIM nocni tok« izklopi, ko gostitelj teče
(dokler drži najem, se same umaknejo). Na PRD migracija še ni uveljavljena.

## Alarmi zamujanja po novem ritmu avtomatike (migracija 247_AlarmiPoNovemRitmu, 2026-09-22)

Pregled sprememb 246 je našel dva vira lažnih kritičnih alarmov:

- `ops.RaiseOverdueAlerts` (PIM.Watchdog) javi `PipelineOverdue`, ko postopek molči več kot 2 × razmik iz
  `ops.ScheduleProfile`. Tam je bil še razmik 300 s, gostitelj pa zalogo in cene iz SAOP poganja na
  ~10–13 min. Razmiki so poravnani navzgor: `SAOP_STOCK`, `SAOP_PRICES` na 900 s (zastarelost 1800 s),
  `MAGENTO_STOCK_PRICES`, `STOCK_FILE`, `SOURCE_FETCH` na 1800 s (zastarelost 3600 s).
- `ops.EvaluateJobAlerts` je `JobOverdue` meril od zadnjega začetka. Zdaj meri od termina (`NextDueUtc`):
  posel zamuja, ko je termin minil za več kot (`WarnAfterMultiplier` − 1) × razmik in posel ne teče.
  Odlog po napakah in čakanje v pasu SAOP nista zaostanek, padec javlja `JobFailed`.

V isti izdaji kode: delni padec posla (npr. eno od treh podjetij) konča kot `Warning`, ne `Failed`, zato
ne sproži odloga za zdrava podjetja in še sproži odvisne posle. Ročna ustavitev premakne termin na konec
+ razmik.

**Objekti:** `ops.EvaluateJobAlerts` (spremenjena), `ops.ScheduleProfile` (podatki).

**Ročni korak po uvedbi:** ni potreben.

## Nowodvorski katalog prek povezave (migracija 270_NowodvorskiXmlPrekoPovezave, 2026-09-23)

`NW_XML` v `map.SourceFetchLocation` ni več `MAPA` (ročno odlaganje), ampak `HTTP` kot Braytron:
`CredentialKey = Fetch:NW_XML`, `FileNamePattern = products_en_US.xml` (s končnico `.xml`, sicer bi prevzemnik
shranil `NW_XML.dat`, ki ga `PIM.XmlFileWorker` ne bere), `MinIntervalMinutes = 360`, `Location = NULL`.
Nočna uskladitev (00:30) datoteko prenese v `<LANDING_ROOT>\NW_XML` in jo nato prebere. Preizkušeno na
razvoju: prenos 18,4 MB, ista oblika kot `fixtures\nw\products_en_US.xml`.

**Objekti:** `map.SourceFetchLocation` (samo podatki).

**Ročni korak po uvedbi:** da. V `appsettings.Local.json` ob intranetu na strežniku pod `"Fetch"` dodaj
`"NW_XML": "https://pim.nowodvorski.com/xmlfeed/download/1/<žeton>"`. Brez tega prevzem javi napako
»Naslov ni nastavljen«.

## Šumniki v glavah izvoza (migracija 271_PopraviSumnikeVGlavahIzvoza, 2026-09-23)

Na strežniku je `katalog.csv` imel glavi »Pakirna koliÄŤina« (217) in »Odprodaja - koliÄŤina« (234). Migraciji
sta tekli skozi `sqlcmd` brez `-f 65001`, zato je bil UTF-8 prebran kot Windows-1250. `Invoke-PendingMigrations.ps1`
ima `-f 65001` danes vgrajen; 271 popravi, kar je že v bazi (zaporedja `Ä`/`Ĺ` + drugi znak → č, Č, š, Š, ž, Ž, ć, Ć, đ),
in pade, če ostane pokvarjen znak. Na bazi brez napake ne spremeni ničesar. Preizkušeno na razvoju v povrnjeni transakciji.

**Objekti:** `out.ExportColumn.OutputColumnName` (samo podatki).

**Ročni korak po uvedbi:** ne. Naslednji izvoz `katalog.csv` že nosi pravilne glave.

## Sprememba polja SAOP velja v PIM takoj, v SAOP gre po odobritvi (migracija 273_NeposlanaSpremembaPimPredZajemomSaop, 2026-09-23)

Pravilo (uporabnik 2026-09-23): sprememba polja SAOP (kartica, uvoz delovnega lista, popravek iz zgodovine) velja
v PIM takoj in povsod. V SAOP ne gre nič samo: sprememba čaka odobritev na Čakalni vrsti, poslana je zadnja
vrednost (starejša neposlana sprememba istega polja postane `Superseded`, `out.EnqueueMessage` od 046).

- `map.ProcessRawInbox`: telo iz 240 + korak 8b. Zajem iz SAOP ne povozi polja, za katero ima artikel v
  `out.OutboxMessage` (`SAOP_PRODUCT`) neposlano sporočilo (`PendingApproval`, `Pending`, `Retry`, `Sending`, `Error`).
  `Sent` ni zaščiten, da potrditev odmeva (243) loči potrditev od odklona.
- `intranet.GetOutboundMessages`: 20. stolpec `Value` (poslana vrednost). Zgodovina (`/saop/zgodovina`) iz izbranih
  sporočil pripravi popravek (polje + vrednost, čaka odobritev).

Preizkušeno na razvoju v povrnjeni transakciji: ponovna obdelava zajema 4768 — artikel s čakajočo spremembo obdrži
vrednost iz PIM, artikel brez nje dobi vrednost iz SAOP; popravek in nadomestitev delujeta.

**Objekti:** `map.ProcessRawInbox`, `intranet.GetOutboundMessages` (samo procedure).

**Ročni korak po uvedbi:** ne. Potrebna je objava intranetu (kartica zdaj piše v PIM takoj, zgodovina ima popravek).

## Katalog dobaviteljev (XML) kot svoj posel in prednost ročnih zahtev v pasu SAOP (brez migracije, 2026-09-23)

Dobaviteljev XML (NW_XML, BT_XML) je bil samo korak nočne uskladitve. Ta kliče SAOP, zato čaka v pasu SAOP,
v vrstnem redu je zadnja in na strežniku ni tekla nikoli: obstoječi artikli se niso bogatili, novi niso
postali kandidati na /zajem/novi-artikli.

Koda (`PIM.Automation`): nov posel `SUPPLIER_CATALOG_IMPORT` »Katalog dobaviteljev (XML)«, tok INPUTS, vsakih
6 h, meja 90 min. Za vsak vir posebej: `PIM.SourceFetchWorker --source <vir>`, nato `PIM.XmlFileWorker` za
vsako podjetje. Padel prevzem (npr. manjka `Fetch:NW_XML`) preskoči branje istega vira. Brez rezervnih
fixtures. SAOP ne kliče. Med zajemom artiklov iz SAOP čaka (odvisnost brez vrat in brez sprožilca).
Viri svežine NW_XML/BT_XML se premaknejo z `NIGHTLY_RECONCILIATION` na nov posel; nočni XML korak ostane kontrola.

Pas SAOP: ročna zahteva (»Poženi zdaj«) za SAOP posel ima prednost. Redni SAOP posli ji prepustijo pas, dokler ne začne.

Objekti v bazi: `ops.JobDefinition` (nova vrstica), `ops.JobDependency` (SUPPLIER_CATALOG_IMPORT → SAOP_PRODUCT_IMPORT),
`ops.JobSource` (NW_XML/BT_XML pod novim poslom; pri nočni se izklopita). Vse zapiše gostitelj ob zagonu
(`ops.EnsureJobDefinition`, `ops.EnsureJobSource`, `ops.RetireJobSources`).

Ročni korak: **da** — na strežniku objaviti novo avtomatiko (PIM.AutomationHost) in v `appsettings.Local.json`
ob intranetu imeti `Fetch:NW_XML` (glej 270) in `Fetch:BT_XML`, sicer posel pade na prevzemu z jasnim razlogom.

## S-popusti: pravila po tipu stranke, stranki, rabatni skupini in S kodi (migracija 274_SPopustiPravilaPoTipuStrankiInSkupini, 2026-09-23)

S-popust na polno pakiranje (Magento_Pravila_Cene_Popusti_Postnine §4.4, §4.5, §4.8) ima tri sloje:

1. **privzeti S izdelka** (`pim.ProductPackagingDiscount`, od 020): velja za vse stranke s kljukico
   »Popust polno pakiranje« pri količini ≥ PAK2. V katalog.csv gre v »Skupina popusta« in »S popust %«.
2. **posebni S po tipu stranke**: npr. vsi inštalaterji dobijo na rabatni skupini BRAYTRON S3. V katalog.csv gre v nov
   stolpec »Posebni S za skupino strank« (COL037B) kot `MAGENTO_SKUPINA\S3 | …`.
3. **posebni S po stranki**. V katalog.csv gre v »Posebni popust za stranko« (COL037) kot `ŠIFRA_STRANKE\S2 | …`.

Pravilo velja za en artikel (ITEM), rabatno skupino (ITEM_GROUP = `canon.Product.DiscountGroup`), vse artikle
z dano privzeto S kodo (S_CODE) ali vse artikle (ALL). Zmaga najbolj specifično pravilo (artikel, S koda,
skupina, vsi). Stranka ima prednost pred svojim tipom: tako to prikaže kartica stranke, Magento pa to
pravilo uveljavi pri branju obeh stolpcev.

- `b2b.PackagingDiscountRule` (nova tabela): vsa posebna S pravila, en veljaven zapis na cilj in obseg (filtriran unikaten indeks).
- `b2b.CustomerPackagingDiscountOverride` (216) → preimenovana v `…_pred274`. Vrstice so prenesene v novo tabelo
  (CUSTOMER/ITEM). Ime zdaj nosi **pogled** z istimi stolpci (bralci 129/250 delujejo naprej).
- `b2b.PackagingDiscountSpecials(@OrganizationId, @OnDate)` (nova funkcija): učinkoviti posebni S na cilj in izdelek.
- `b2b.SavePackagingDiscountRule`, `b2b.RemovePackagingDiscountRule` (novi, revizija `b2b.AuditLog`).
  `b2b.SaveCustomerPackagingDiscountOverride` in `b2b.RemoveCustomerPackagingDiscountOverride` (216) pišeta prek njiju.
- `pim.SaveProductPackagingDiscountsBulk` (nova): privzeti S več izdelkom (delovni list, cenik, seznam izdelkov),
  zgodovina v `pim.ProductFieldHistory`. `pim.SavePackagingDiscountPercent` (nova): šifrant S kod.
- `intranet.GetProductPackagingDiscount` (spremenjena, + nabor posebnih S), `intranet.GetProductPackagingDiscountSheet`,
  `intranet.GetPackagingDiscountRules`, `intranet.GetCustomerPackagingDiscounts` (nove).
- `intranet.GetProductList` (+ `@PackagingDiscount`, `@DiscountGroup`, `@SpecialFor`), `intranet.GetProductListFilters`
  (+ faseta DISCOUNT_GROUP), indeks `IX_CanonProduct_OrgDiscountGroup`.
- `out.GetExportRows` (oznaka `/* SpecialS274 */`), `out.ExportColumn` (COL037B na koncu profila MAGENTO_PRODUCTS, za dodatki 234 — prvih 176 stolpcev predloge Magenta ostane na mestu).
- `intranet.GetCustomerList`: `SpecialDiscounts` v zapisu `ARTIKEL\S2 | SKUPINA:koda\S3 | S:S2\S3 | *\S3`.

Začasne tabele v procedurah imajo `COLLATE DATABASE_DEFAULT`, ker je kolacija tempdb lahko druga kot kolacija baze
(na DAVID\MSSQL19: Slovenian_CI_AS proti SQL_Latin1_General_CP1_CI_AS, Msg 4191).

Intranet: filtri in »S-popust …« (za izbrane izdelke ali cel pogled) na /izdelki, kartica izdelka (Komerciala), kartica stranke,
Pravila → Komercialna pravila → S-popusti. Delovni list izdelkov ima stolpce »S koda« (sprejme tudi »Skupina popusta« iz cenika),
»Posebni S — tipi strank« in »Posebni S — stranke«. Uvoz prebere vse liste z istimi stolpci. VPAK iz cenika samo primerja
s PAK2 in ga ne zapiše, ker je to podatek SAOP. Delovni list strank ima drugi list »S po tipih strank«.

**Ročni korak po uvedbi:** ne. Magento mora brati nov stolpec »Posebni S za skupino strank«.

## Odprodaja: pregled, ročni vnos in razstavni eksponat (migracija 275_OdprodajaPregledInRocniVnos, 2026-09-23)

Odprodaja je zdaj ena stran v intranetu: **Izdelki → Odprodaja** (`/izdelki/odprodaja`; stara pot
`/izdelki/uvoz-odprodaje` vodi na isto stran). Na njej so številke, tabela vseh artiklov v odprodaji (urejanje
količine, popusta in oznake razstavni eksponat, zaključitev, obnova), ročni vnos enega artikla in uvoz seznama iz Excela.
Na kartici izdelka (zavihek Odprodaja) je ročni vnos pod virom »Ročno«.

Izvoz se ne spreminja: katalog.csv že od 234 bere `pim.ClearanceItem` (najnovejša aktivna vrstica artikla,
Odprodaja = DA pri količini > 0) in `pim.ProductFlag` RAZSTAVNI_EKSPONAT.

- `pim.SetShowcaseFlags` (nova): oznaka RAZSTAVNI_EKSPONAT za več artiklov naenkrat, z zgodovino.
- `pim.SaveClearanceItem` (nova): en artikel v odprodajo ali popravek vrstice istega vira; `@Razstavni` NULL ne spreminja oznake.
- `pim.SaveClearanceItems` (spremenjena): JSON vrstica ima `razstavni` (uvoz bere stolpec »Razstavni eksponat«;
  1/da/x = DA, prazno = NE, brez stolpca oznake ne spreminja). Samodejno zaključene vrstice počistijo oznako.
- `pim.EndClearanceItem` (spremenjena): ob zaključitvi počisti oznako, kadar artikel nima druge aktivne odprodaje.
- `intranet.GetClearanceOverview` (nova): tabela strani, vključno s spletnimi stranmi in »gre v katalog.csv«.
- `sec.RolePermission`: nova pravica `view.products.clearance` za ADMIN, CATALOG_EDITOR, COMMERCIAL.

Namerno ločeno od `Product.ClearancePercent` na `/splet/katalog` (204/207, oddelčni popust X/O), ki ostane, kot je.

**Objekti:** procedure zgoraj + vrstice v `sec.RolePermission`. Tabel ne spreminja.

**Ročni korak po uvedbi:** ne (migracija + objava intranetu).

## Meja svežine vira na strani posla (migracija 276_MejaSvezineVirovNaStrani, 2026-09-24)

Meja svežine vira (kako stari smejo biti podatki, preden je posel na Nadzoru rdeč in se odpre alarm
`SourceStale`) je bila samo v kodi (`JobCatalog.Sources`); gostitelj jo ob vsakem zagonu prepiše z
`ops.EnsureJobSource`. Zdaj jo skrbnik nastavi na **Nadzor → posel → 5. Nastavitve → Meja svežine virov**
(v urah, velja za vir v vseh podjetjih). »Nazaj na kodo« preglas odstrani.

- `ops.JobSource.MaxAgeSecondsOverride` (nov stolpec, NULL = velja koda; 60 s–30 dni). `MaxAgeSeconds` ostane
  meja iz kode, ki jo `ops.EnsureJobSource` še naprej usklajuje — preglasa ne pozna, zato ga ne prepiše.
- `ops.JobSourceState()` (spremenjena): `MaxAgeSeconds` je veljavna meja (preglas ali koda), nova stolpca
  `DefaultMaxAgeSeconds` in `IsMaxAgeOverridden`. Stanje Stale in alarm `SourceStale` (`ops.EvaluateJobAlerts`
  bere to funkcijo) sledita meji s strani brez spremembe procedure alarmov.
- `intranet.GetJobSourceState` (spremenjena): vrne še `DefaultMaxAgeSeconds`, `IsMaxAgeOverridden`.
- `intranet.SetJobSourceMaxAge` (nova): zapis preglasa; NULL ali vrednost enaka kodi preglas odstrani.
  Sled zapiše intranet (`JOB_SOURCE_MAX_AGE`).

Ni isto kot razmik posla (`ops.JobDefinition.IntervalSeconds`, kako pogosto teče) ali časovna meja
(`TimeoutSeconds`, kako dolgo sme en tek trajati).

**Objekti:** `ops.JobSource` (stolpec + CHECK), `ops.JobSourceState`, `intranet.GetJobSourceState`, `intranet.SetJobSourceMaxAge`.

**Ročni korak po uvedbi:** ne (migracija + objava intranetu; intranet brez 276 pokaže mejo iz kode brez urejanja).

## Slike, ki jih dobavitelj ne pošilja več, na konec galerije + vse slike iz XML (migracija 278_StareSlikeNaKonecGalerije, 2026-09-24)

Stran Media za NW_XML je šla v karanteno pri vseh podjetjih: dvojnik na `UQ_CanonProductMedia_ProductRoleSort`.
Nowodvorski je pri nekaterih artiklih (org 2: 44) umaknil glavno sliko. MERGE v `map.ProcessRawInbox` (korak 13)
slike ujema po (ProductId, Url), zato sta nova in stara glavna slika obe ostali na PRIMARY/1. Ker je cela
stran ena transakcija, se ni posodobila nobena NW slika.

Objekti: `map.ProcessRawInbox` (korak 13, oznaka `/* 278 */`, zamenjava besedila kot 261, ponovljivo).
- Pred MERGE: pri artiklih, ki jim stran prinaša vsaj eno sliko, se slike, ki jih na strani ni, umaknejo
  na SortOrder 100000+. PRIMARY postane GALLERY, AMBIENT ostane AMBIENT.
- Po MERGE: umaknjene slike dobijo zaporedje takoj za slikami vira, v prejšnjem vrstnem redu.
  Nič se ne briše (uporabnik: stare na konec galerije; kasneje arhiv slik na naš strežnik).

Koda v istem commitu (`PIM.XmlMapping`): ekstraktor je za vsako preslikavo vzel samo prvi zadetek in
`map.FieldMapping.IsMultiValue` ni poznal (izgubljeno po koncu avgusta; zadnja stran z ValueOrdinal > 1 je 2706).
Iz NW XML je zato prišla samo prva slika na artikel. Zdaj večvrednostna preslikava (slike, vrste slik,
dokumenti NW/BT) vrne vse zadetke z `map.ExtractedValue.ValueOrdinal` 1..n. Preslikave SAOP niso večvrednostne.

Ročni korak: ne za migracijo. Strani v karanteni se ne ponovijo same; ob naslednji novi NW datoteki
(posel Katalog dobaviteljev, 6 h) gredo slike skozi popravljeno pot. Za objavo potreba nova izdaja workerjev
(PIM.XmlFileWorker, PIM.KatalogWorker zaradi skupne knjižnice PIM.XmlMapping).

## Varovalke: katalog.csv pred objavo + cene z decimalno vejico, ločilo podpičje (migracija 277_VarovalkeKatalogCsv, 2026-09-24)

Uporabnik 2026-09-23/24: »katalog ni dal vejice cenam in smo imeli napačne cene na svetilih«, »kljukice za splet niso
delovale«, varovalke »ne blokirajo procesov, ampak samo opozorijo in mora uporabnik ponovno potrditi«; »dej cenam vejico in
pa ločilo naj bo ; ne pa vejica« (cena `29,78`, brez narekovajev); »če ima en artikel prazno polje, se ostali pojavijo v
CSV, ta pa ne sme biti v CSV in mora čakati odobritev«.

Worker (`PIM.B2bWorker`, `CatalogSafeguard`) po zapisu katalog.csv in pred zamenjavo datotek pokliče
`ops.EvaluateCatalogSafeguards`. Ta vrne izid in seznam **zadržanih artiklov**; worker prepiše datoteko brez njihovih vrstic
(`RegistryCsvWriter.CopyWithoutAsync`, bajt za bajtom) in objavi ostalo. Zadržan artikel na spletu ostane s prejšnjimi podatki
(Magento artiklov, ki jih ni v datoteki, ne spreminja; nov artikel tja ne pride), obdrži izhodišče cen in stanje v
`out.WebPublication`. Posel se vedno konča uspešno; faza DATOTEKA v sporočilu pove, koliko artiklov je zadržanih in zakaj.
Uporabnik potrdi na `/varovalke/{id}` posamezne ugotovitve ali vse; potrditev (`ops.SafeguardApproval`, prstni odtis: pravilo,
artikel, polje, spletišče, prej, zdaj) velja 14 dni, ob potrditvi se odda zahteva za zagon `WEB_CATALOG_EXPORT`. Če napako
popravi (npr. ceno v SAOP), je naslednji izvoz ne najde več in artikel gre ven sam. Napaka varovalke dostave ne ustavi
(datoteka gre ven brez preverjanja, opozorilo v zvoncu).

- `out.ExportColumn.DecimalSeparator` (nov stolpec, ',' = število z decimalno vejico) in `GuardKind` ('PRICE' = preverja
  varovalka cen). Nastavljeno za Cena B2B/Cena B2C (MAGENTO_PRODUCTS, MAGENTO_STOCK_PRICES). Ostala števila ostanejo s piko.
  `out.GetExportRows` ostane s piko (po njej računa varovalka); vejico postavi zapis datoteke (`PIM.B2b.ExportValueFormat`)
  in ročni prenos na /splet.
- `out.ExportProfile.FieldDelimiter` (nov stolpec, ',' ali ';'): MAGENTO_PRODUCTS (katalog.csv) in MAGENTO_CUSTOMERS
  (stranke.csv) = ';', ostali profili (cene in zaloga) ostanejo ','. Vrednost se da v narekovaje samo, če vsebuje ločilo, `"` ali prelom vrstice.
- `ops.SafeguardRule` (nova): pravila po področjih (zdaj `KATALOG_CSV`), besedila, prag, najmanj artiklov, ali zadrži artikel
  (`RequiresConfirmation`; samo pravila o artiklu, `CanHold = 1`), vklop — nastavljivo na /varovalke (samo ADMIN). Pravila:
  KAT_CENA_OBLIKA (ni število), KAT_CENA_VEJICA (×10/×100/×1000 ±2 %), KAT_CENA_NIC (0 ali negativna), KAT_CENA_PRAZNA,
  KAT_CENA_SKOK (prag 25 %) — vse zadržijo artikel; KAT_SPLET_UMIK (gre s spleta; zadrži od 10 artiklov naprej),
  KAT_VRSTICE (padec artiklov na spletu, prag 10 % — opozorilo o celoti), KAT_KLJUKICA_NE_GRE (nova kljukica, artikel ne
  gre — opozorilo), KAT_SPLET_NOVI (informacija). Nova področja (SAOP, zaloga, viri) so nove vrstice + svoja procedura.
- `ops.SafeguardCheck`, `ops.SafeguardFinding` (novi): preverjanje (CLEAN/WARNED/WAITING = so zadržani/CONFIRMED/SUPERSEDED),
  število zadržanih (`HeldCount`), artiklov na spletu (`PublishedRows`, `PreviousPublishedRows`), ugotovitve po artiklu (prej,
  zdaj, sprememba, razlog, prstni odtis, `RequiresConfirmation` = zadržan). Zadržan ostane zadržan tudi, ko pade pod prag.
  Čakajoče preverjanje z enakimi nepotrjenimi ugotovitvami se osveži, ne podvoji. Čiščenje: nadomeščena po 2 dneh,
  podrobnosti objavljenih po 30, vse po 120 dneh.
- `ops.SafeguardApproval` (nova): potrjene ugotovitve (kdo, kdaj, opomba) — velja 14 dni, izbriše se po 120 dneh.
- `out.CatalogPublishedValue` (nova): cene zadnjega objavljenega katalog.csv (izhodišče primerjave), piše
  `out.RecordCatalogPublication` po uspešni zamenjavi — brez zadržanih artiklov (`@HeldItemsJson`).
- `pim.WebShopReason(@OrganizationId)` (nova funkcija): za vsako kljukico, ali artikel gre na spletišče in zakaj ne (UNCHECKED,
  INACTIVE, EXCLUDED, HOLD, NO_CATEGORY, BLOCKED_ERRORS + polja, NOT_VALIDATED, NOT_PROMOTED) — po pravilih #Site v out.GetExportRows.
- Procedure: `ops.EvaluateCatalogSafeguards`, `out.RecordCatalogPublication`, `ops.ApproveSafeguardFindings` (izbrane ali vse),
  `ops.SaveSafeguardRule`, `intranet.GetSafeguardRules`, `intranet.GetSafeguardChecks`, `intranet.GetSafeguardCheck`,
  `intranet.GetWebShopBlocked` (kljukice, ki ne gredo na splet), `intranet.GetWebWithdrawnItems` (umaknjeni s spleta z razlogom).
- Opozorilo `SafeguardPending` (zvonec → /varovalke): CHECK naročnin, naročnina skrbnikov, `intranet.GetUserAlertSubscriptions`
  (dopolnjena živa definicija), `intranet.GetMonitorAlerts` (podatkovna vrsta, ni na Nadzoru; enako `MonitorPolicy.IsDataAlert`).
- `sec.RolePermission`: `page.safeguards` za ADMIN, CATALOG_EDITOR, VIEWER, COMMERCIAL. Potrdi lahko ADMIN, CATALOG_EDITOR, COMMERCIAL.

Intranet: `/varovalke` (čaka potrditev, zgodovina, pravila), `/varovalke/{id}` (zadržani artikli z izbiro in potrditvijo
izbranih ali vseh, razlogi umikov v vrsticah s števili, Excel), pasica na `/splet`, `/splet/umaknjeni` z zavihki Umaknjeni s
spleta (vsi umiki z razlogom + vrnitev kljukic v enem koraku), S kljukico, a ne gredo na splet, Samodejni umik (251).
Predogled in Excel na /splet prepoznata ločilo iz glave datoteke.

**Objekti:** zgoraj. Migracija preveri, da je datoteka prebrana kot UTF-8 (`THROW 52700` sicer).

**Ročni korak po uvedbi: DA — uvoznik Magento.** katalog.csv ima od te migracije ločilo `;` in cene z decimalno vejico brez
narekovajev (`A-1;13,02;1.5`). Uvoz katalog.csv in stranke.csv na Magento (svetila) mora biti nastavljen na ločilo `;` **preden** se objavi nov
`PIM.B2bWorker`, sicer Magento prebere vso vrstico kot en stolpec. Enako za stranke.csv (tudi ločilo `;`). Prvi izvoz po uvedbi še nima
objavljenih cen za primerjavo: artikli s prazno ceno ali ceno 0 so enkrat zadržani (/varovalke), po potrditvi ne več.
Objava: migracija + intranet + `PIM.B2bWorker`.

## Baza kupcev ViD: referent, dodatni popust P2, prodajni kontakti in opombe (migracija 279_BazaKupcevDodatniPopustInKontakti, 2026-09-24)

Pregled Excela »Baza kupcev_ViD_2026.xlsx« (listi B2B, Tujina, Dodatna pravila za artikle, Opombe strank 2.2026)
proti PIM: popusti R1–R7, VD1 … TT so kopija SAOP rabatnega cenika (1.818 enakih, 10 različnih) in ostanejo v
SAOP. Manjkalo je: drugi popust »NW-P2« (7 %, ki ga prodaja vpiše v P2 naročila), referent, e-pošta za dobavnice
in obveščanje, skrbnik in opombe v delovnem listu.

- `b2b.Customer.SalesClerkCode` (nov stolpec) iz SAOP `<SalesClerkID>`: preslikava `Customers → Customer.SalesClerkCode`
  za vse SAOP konektorje, `map.ProcessCustomerInbox` popravljen na živi definiciji (5 zamenjav besedila, kot 253).
  Obstoječe stranke dobijo vrednost iz zadnje že zajete strani `raw.Inbox` (Vidadria 2.744, IQLighting 3.723, Ediito 477).
- `pim.SalesClerk` (nova): imena referentov po podjetju. SAOP imen v zajetih entitetah ne pošilja; Vidadria je
  napolnjena iz Excela (8 referentov).
- `pim.CustomerExtra` + `b2b.SaveCustomerExtra` (nova): skrbnik (ročno), e-pošta za dobavnice, e-pošta in oseba za
  obveščanje. Ločeno od `pim.CustomerContact`, ker kontakt gre v stranke.csv, ta polja pa ne. Sled `CustomerExtra`.
- `b2b.CustomerExtraGroupDiscount` + `b2b.SaveCustomerExtraGroupDiscount` / `b2b.RemoveCustomerExtraGroupDiscount`
  (nova): dodatni popust stranke po skupini artiklov; ena aktivna vrstica na stranko in skupino. Sled `CustomerExtraGroupDiscount`.
- `b2b.CustomerGroupDiscounts` (spremenjena): dodatni popust se obračuna **za** osnovnim (kot P2 za P1 v SAOP):
  `100 − (100 − osnovni) × (100 − dodatni) / 100` (NW 39 % + 7 % = 43,27 %); brez osnovnega velja sam (vir `EXTRA`,
  velja tudi za tranzit — ročna odločitev kot pri 253). Nova stolpca `BasePercent`, `ExtraPercent`. Isti rezultat
  berejo stranke.csv (`out.GetExportRows`), stran Stranke in kartica.
- `intranet.GetCustomerCard` nabor 2 (popravljen): vir »dodatni popust stranke« oz. »… + dodatni 7 %«.
- `intranet.GetCustomerListExtra` (nova): referent, skrbnik, e-pošte, dodatni popusti in opombe za stran Stranke in
  delovni list (`intranet.GetCustomerList` ostane nespremenjena).

Delovni list strank (`/izvoz/stranke.xlsx`, `/stranke/uvoz`) ima nove stolpce: »Dodatni popust po skupinah (P2)«,
»Referent (SAOP)« (samo branje), »Skrbnik«, »E-pošta za dobavnice«, »E-pošta za obveščanje«, »Oseba za obveščanje«,
»Dodaj opombo« (doda zaznamek, enak obstoječemu se ne podvoji) in »Opombe« (samo branje).

**Ni narejeno:** privzeti popusti po tipu iz vrstic TRGOVINE/INŠTALATERJI (ročni popust tipa bi prevladal nad SAOP
ceniki strank), list »Dodatna pravila za artikle« (prosto besedilo).

**Objekti:** `b2b.Customer` (stolpec), `map.FieldMapping` (vrstice), `map.ProcessCustomerInbox`, `pim.SalesClerk`,
`pim.CustomerExtra`, `b2b.SaveCustomerExtra`, `b2b.CustomerExtraGroupDiscount`, `b2b.SaveCustomerExtraGroupDiscount`,
`b2b.RemoveCustomerExtraGroupDiscount`, `b2b.CustomerGroupDiscounts`, `intranet.GetCustomerCard`, `intranet.GetCustomerListExtra`.

**Ročni korak po uvedbi:** ne (migracija + objava intranetu; migracija teče ~40 s zaradi branja XML strani strank).
Skripto poganjaj z `sqlcmd -I` (Invoke-PendingMigrations.ps1 to dela), brez tega pade na QUOTED_IDENTIFIER.

## Zgodovina uvozov in povratek (migracija 280_ZgodovinaInPovratekUvozov, 2026-09-24)

Uporabnik 2026-09-24: »hitra sprememba samo za eno polje ni uporabna; mišljeno je, da ko se spremenijo artikli, da se
povrne — pri uvozih artiklov, cen, strank in SAOP«. Do zdaj uvoz ni imel identitete (uvoz izdelkov je nastal kot
desetine serij v `pim.ProductChangeBatch`, uvoz cen prejšnjih vrednosti ni shranil nikjer), zato ga ni bilo mogoče ne
pokazati kot celote ne povrniti.

- `ops.ImportRun` (nova): en zapis na uveljavljen uvoz (IZDELKI, CENE, STRANKE): datoteka, kdo, kdaj, vrstic, sprememb,
  koliko v SAOP, skupine v odhodni vrsti, opozorila, pri strankah `Snapshot` (vrstice seznama strank pred uvozom, JSON),
  povezava povratka (`UndoOfImportRunId`, `UndoneByImportRunId`, `UndoneUtc`, `UndoneBy`).
- `ops.ImportRunChange` (nova): vsaka spremenjena celica — vrstica (šifra artikla, ključ stranke, »cenik|šifra«), polje,
  naslov stolpca, prej → potem, PIM ali SAOP, vrsta vrednosti (TEXT/BOOL/NUMBER). »Prej« zajame predogled uvoza tik
  pred zapisom (izdelki: `ProductWorkbookRowChange.OldValues`; cene: `PriceImportRow.Old*`; stranke: predogled).
- `ops.RecordImportRun`, `intranet.GetImportRuns`, `intranet.GetImportRun`. Čiščenje: starejši od 180 dni.
- `sec.RolePermission`: `page.imports.history` za ADMIN, CATALOG_EDITOR, VIEWER, COMMERCIAL.

Intranet: `/uvozi` (seznam uvozov), `/uvozi/{id}` (spremembe prej → potem, stanje v vrsti za SAOP, »Prekliči, kar še
čaka v SAOP« in »Pripravi povratek«). Povratek ni nova pot zapisa: odpre stran uvoza (`izdelki/uvoz`, `cene/uvoz`,
`stranke/uvoz`) s `?povrni=N` in običajnim predogledom prejšnjih vrednosti; zapiše se kot vsak uvoz in se sam zabeleži
kot uvoz z `UndoOfImportRunId`. Pravila:
- Povrne se samo celica, ki ima še vrednost uvoza; kar je po uvozu spremenil kdo drug, je spor in ostane (našteto).
- ERP polja izdelkov gredo v PIM takoj in v vrsto za SAOP s stanjem PendingApproval (nikoli samodejno); starejše
  čakajoče sporočilo uvoza za isto polje postane Superseded. Prazne vrednosti v SAOP ni mogoče poslati (graditelj
  dokumenta prazno izpusti) — tako polje se ne povrne in se pove.
- Cene: povrne se samo cena, ki jo je zajem že prinesel iz SAOP; kjer je v PIM še stara cena, je pravi povratek
  preklic čakajoče serije (`out.CancelOutboundBatch`, gumb na `/uvozi/{id}`). Nova cena se v SAOP ne da izbrisati,
  povratek jo izklopi (Aktivna = N).
- Stranke: povratek sestavi delovni list strank samo s celicami, ki jih je uvoz spremenil (prej prazno → »-«).
  Zaznamkov, pravil »S po tipih strank« in ustvarjenega B2B profila ne vzame nazaj (pove).

**Objekti:** `ops.ImportRun`, `ops.ImportRunChange`, `ops.RecordImportRun`, `intranet.GetImportRuns`, `intranet.GetImportRun`,
`sec.RolePermission` (vrstice).

**Ročni korak po uvedbi:** ne (migracija + objava intranetu). Zgodovina se piše od uvedbe naprej; starejših uvozov ni.

## Varovalke pošiljanja v SAOP (migracija 281_VarovalkeSaop, 2026-09-24)

Uporabnik 2026-09-24: »če je že en neaktiven, moraš opozoriti in potrebna je potrditev; uporabnik mora vedeti, katerim
se je spremenila vrednost«; »nisem mislil, da moraš na druge strani skakati — če je artikel aktiven, takoj v SAOP; če je
neaktiven, ti javi toliko artiklov je neaktivnih in se vidi seznam«; »dej mi še ostale varovalke notri«.

Ob odobritvi (skupina, artikel, sporočilo) gre v SAOP vse, kar ni sumljivo; sumljiva sporočila ostanejo PendingApproval.
Stran odobritve (`/outbound`, `/izvozi/mnozicno`, `/saop/artikli`, zavihek »V SAOP« na `/cene`) jih takoj pokaže s seznamom
(šifra, naziv, prej → potem, od kod, kdo) in gumbom »Da, prav je — pošlji v SAOP«. Isti seznam je na `/varovalke`.

- Pravila (`ops.SafeguardRule`, področje `SAOP`): SAOP_NEAKTIVEN (že en artikel), SAOP_CENA_VEJICA (×10/×100/×1000 ±2 %
  glede na trenutno ceno), SAOP_CENA_NIC, SAOP_CENA_SKOK (prag 25 %), SAOP_CENA_IZKLOP, SAOP_KLJUCNO (EAN, enota, skupina
  obstoječega artikla), SAOP_MNOZICNO (isto polje v skupini pri ≥ 100 artiklih, brez novih artiklov), SAOP_STARO (v vrsti > 7 dni).
- `ops.IsSaopDeactivation`, `ops.SaopHeldMessage` (sporočilo × pravilo, nepotrjeno; potrditev velja za sporočilo),
  `ops.SaopHeldForApproval` (+ ostala polja iste cene — cena gre v SAOP kot celota).
- `out.ApproveMessage`, `out.ApproveItemDocument`, `out.ApproveOutboundBatch` (spremenjene): zadržana preskočijo; posamična
  odobritev zadržanega vrne 52901; skupina in artikel vrneta tudi `Zadrzanih`.
- `intranet.GetSaopHeldMessages`, `ops.ConfirmSaopHeldMessages` (seznam in potrditev na mestu, hkrati odobri za pošiljanje),
  `ops.EvaluateSaopSafeguards` (preverjanje področja SAOP + zvonec), `ops.OnSafeguardApproved` (potrditev na `/varovalke/{id}`).
- 277: `ops.SafeguardFinding.SourceRef`, klic `ops.OnSafeguardApproved` iz `ops.ApproveSafeguardFindings`.
- `out.EnqueueMessage` (popravek žive definicije): deaktivacija je vedno PendingApproval.

PIM vrednost (npr. `canon.Product.IsActive`) uvoz zapiše takoj kot doslej (245) — varovalka zadrži samo pošiljanje v SAOP.

**Objekti:** zgoraj. **Ročni korak po uvedbi:** ne (277 pred 281; objava intranetu).

## Varovalka datoteke cen in zaloge za splet (migracija 282_VarovalkaCenInZaloge, 2026-09-24)

Datoteka cen in zaloge (MAGENTO_STOCK_PRICES) gre na Magento vsakih nekaj minut in nosi cene — varovalka katalog.csv je
ni pokrivala. Worker (`MagentoExportCommand.ExportProfileFileAsync`) pred zamenjavo pokliče
`ops.EvaluateStockPriceSafeguards`; sumljive artikle izpusti (na spletu ostanejo s prejšnjo ceno in zalogo), ostale objavi
in zapiše izhodišče (`out.RecordExportPublication`). Prvi zagon samo zapiše izhodišče.

- `out.ExportColumn.GuardKind` dovoli še `STOCK`; nastavljeno za MAGENTO_STOCK_PRICES (Cena B2B/B2C = PRICE,
  VID razpoložljiva količina = STOCK).
- `out.ExportPublishedValue` (nova): vrednosti zadnje objavljene datoteke po profilu.
- Pravila (področje `ZALOGA_CSV`): ZAL_CENA_VEJICA, ZAL_CENA_NIC, ZAL_CENA_PRAZNA, ZAL_CENA_SKOK (25 %) — vse glede na zadnjo
  objavo; ZAL_ZALOGA_NIC (zaloga z >0 na 0 pri ≥ 20 artiklih hkrati); ZAL_VRSTICE (padec artiklov > 20 %, opozorilo).
- 277: potrditev področja `ZALOGA_CSV` zahteva zagon `WEB_STOCK_EXPORT`.

**Objekti:** zgoraj. **Ročni korak po uvedbi:** ne. Opomba: ta datoteka ima ločilo `,`, zato so cene z vejico v narekovajih.

## Varovalka zaloge virov (migracija 283_VarovalkaZalogeVirov, 2026-09-24)

Nov posnetek zaloge vira (NW_STOCK, BT_STOCK, zajem zaloge iz SAOP) v celoti nadomesti prejšnjega — okrnjena ali prazna
datoteka bi pobrala zalogo vsem artiklom vira. `StockLandingWriter.PersistAsync` pred zapisom pokliče
`ops.EvaluateStockFeedSafeguards`; ob prevelikem padcu posnetka ne zapiše (velja prejšnji), faza ZAPIS je preskočena z
razlogom, v zvoncu je opozorilo. Po potrditvi na `/varovalke/{id}` naslednji zajem iste datoteke (isto število vrstic in
vrstic z zalogo) posnetek zapiše.

- Pravila (področje `ZALOGA_VIR`): ZALV_VRSTICE (manj artiklov za > 30 %), ZALV_NIC (artiklov z zalogo > 0 manj za > 50 %,
  vsaj 20 v veljavnem).
- XML katalog dobaviteljev nima varovalke: ne briše artiklov, praznih vrednosti ne zapiše in ne nosi cen.

**Objekti:** `ops.EvaluateStockFeedSafeguards`, pravila. **Ročni korak po uvedbi:** ne (objava `PIM.StockFileWorker`,
`PIM.SaopStockWorker`).

## Analitika prodaje, zalog in nabave (migracija 284_AnalitikaProdajeZalogInNabave, 2026-09-24/25)

Uporabnik: »naredi analitiko v PIM-u … koliko se kaj proda, mesečni trend po dobaviteljih in artiklih, koliko česa naročiti, katera zaloga je zaležana« in »naredi worker, ki prebere vse te podatke, da se samo priklopim v omrežje«. Nova shema `ana`; nič ne piše v SAOP in se ne dotika `canon`/`pim`/`out`.

- **Vhodne tabele** (polni `PIM.SaopAnalyticsWorker`, samo GET): `ana.SalesInvoiceLine` (Invoice/GetInvoices; račun se zamenja v celoti), `ana.CustomerOrderLine` (Barkawi/GetCO), `ana.PurchaseOrderLine` (Barkawi/GetPO, izračunan `LeadTimeDays`), `ana.ItemPurchaseInfo` (Barkawi/GetSKU), `ana.SourcePage` (surovi odgovori 30 dni za `--razcleni-znova`), `ana.StreamState` (vodni žig in svežina toka).
- **Zaloga v času:** `ana.StockDaily` — dnevni posnetek lastne zaloge iz vira BASE (`out.ExportStockSource`), zaloga NW/BT se ne šteje; hrani ~26 mesecev (`ana.CaptureStockDaily`).
- **Preračun:** `ana.RefreshAnalytics @OrganizationId` prepiše `ana.ItemMonthly`, `ana.ItemMetric`, `ana.SupplierMetric` (ena transakcija na tabelo, brez zanke po artiklih; podjetje 2 ≈ 15 s). Vir prodaje po prednosti: računi → `sales.OrderLine.ShippedQTY` → Barkawi CO. Formula in pravila so v glavi postopka.
- **Nastavitve:** `ana.Setting` po podjetju (z, razmik naročil, privzeti dobavni čas, obdobje, meje zaležanosti/presežka, cenik nabavne cene), sprememba prek `ana.SaveSettings` piše `ana.SettingHistory` (prej/potem, kdo).
- **Branje za intranet:** `ana.GetOverview`, `ana.GetItemMetrics` (strežniško listanje, iskanje brez šumnikov, števci po signalih, izbrani po `@ProductIdsJson`), `ana.GetSupplierMetrics`, `ana.GetItemDetail`, `ana.GetSettings`.
- **Razpored** `SAOP_ANALYTICS` (2, 3, 4 vklopljeno, DEMO izklopljeno); **pravice** `page.analytics` in zavihki `tab.analytics.*` za ADMIN in COMMERCIAL.

**Objekti:** shema `ana` (11 tabel, 14 postopkov), vrstice v `ops.ScheduleProfile` in `sec.RolePermission`. **Ročni korak po uvedbi:** ne; objaviti `PIM.SaopAnalyticsWorker` (Publish-Workers.ps1 ga najde sam) in intranet. Prvi zagon v omrežju: `PIM.SaopAnalyticsWorker --preizkus` (vzorci in polja, v bazo ne piše), nato `PIM.SaopOrdersWorker --zgodovina-od 2023` (enkratni zajem zgodovine naročil po številkah).

**Brez migracije, ista sprememba:** `PIM.SaopOrdersWorker` bere naročila VNK/VND tudi po številkah (`OrderSweep`): `GetOrderStatus` za VNK ni vrnil ničesar, `GetOrder/{leto}/{knjiga}/{številka}` pa dela. Redni tek od največje številke v `sales.OrderHeader`/`purch.PurchaseOrderHeader` naprej (konec po `OrderSweepTailGap` zaporednih manjkajočih, največ `OrderSweepTailMaxCalls` klicev), odprta naročila znova enkrat na `OrderOpenRefreshHours` ur (zaznamek `GetOrder:ODPRTA` v `map.Watermark`).

## Katalog iz več podjetij (migracija 285_KatalogIzVecPodjetij, 2026-09-25)

Uporabnik: IQ in ViD artikli v katalog.csv brez podvajanj, »svetila samo IQ, videlektro oba«; stranke obeh podjetij (Anja Zorenc: stranke so dvojne, z dvojnimi šiframi, vodijo se posebej). Do zdaj je bil katalog samo podjetje 2.

- **`out.CatalogSource`** (CatalogOrganizationId, SourceOrganizationId, Priority, WebSiteLabels, IsActive): vpisana 2 (prednost 10, vsa spletišča) in 3 (prednost 20, `videlektro`). Brez vrstic ali z enim podjetjem izvoz dela natanko kot pred 285.
- `PIM.B2bWorker` (`CatalogMerge`): vsako podjetje zapiše svoje vrstice z `out.GetExportRows` (procedura nespremenjena) v svojo začasno datoteko, gre skozi svojo varovalko 277; nato ena vrstica na šifro — vsebina iz podjetja z najvišjo prednostjo, ki artikel objavlja, »Spletne strani« = unija dovoljenih spletišč, kategorija spletišča iz podjetja, ki ga prispeva. Vrstica ViD brez videlektro ne gre ven (razen odjavne, če je ViD artikel na videlektro objavil v zadnjih WithdrawalRowDays dneh). Zapis objave (251) in izhodišče varovalke po podjetju.
- `stranke.csv`: stranke vseh podjetij iz registra zaporedoma; ponovljena šifra (se ne zgodi, IQ 8 mest, ViD 7) gre ven samo prva, v izpisu je opozorilo.
- **Čiščenje:** `out.WebPublication` vrstice podjetij, ki niso podjetje kataloga in niso bile nikoli izvožene (`LastExportedUtc IS NULL` — začetno stanje 251), so odstranjene; kopija v `out.WebPublication_pred285`. Brez tega bi ViD pošiljal odjavne vrstice za artikle, ki jih Magento od njega ni nikoli dobil.
- Razvojna baza (DAVID\MSSQL19), `--brez-objave`: IQ 2.536 vrstic → združeno 2.595 (59 artiklov samo ViD na videlektro, 68 IQ odjav postane videlektro iz ViD, 2.468 IQ vrstic bitno enakih); stranke 3.988 + 393 = 4.381, vse šifre enolične.

**Objekti:** tabela `out.CatalogSource`, tabela `out.WebPublication_pred285`, brisanje v `out.WebPublication`. **Ročni korak po uvedbi:** objaviti `PIM.B2bWorker`. Izklop ViD: `UPDATE out.CatalogSource SET IsActive = 0 WHERE SourceOrganizationId = 3`. Predogled na `/splet` in »Prenesi za Excel« še kažeta samo podjetje 2.

## Stolpci atributov iz naborov (migracija 286_StolpciAtributovIzNaborov, 2026-09-25)

Uporabnik: atributi, dodani v nabor kategorije, morajo iti v katalog.csv — »to ne sme biti fiksno«.

- **`out.SyncAttributeExportColumns @ProfileCode, @Actor`**: za vsak aktiven atribut iz aktivnih naborov (Level <> EXCLUDED) doda stolpec na konec profila (prevedljiv »Ime ANG« + »Ime SLO«, sicer »Ime [enota]«); samodejni stolpec `ATTR_…` preimenuje, izklopi ali znova vklopi, ročnih ne spreminja. Kliče ga `PIM.B2bWorker` pred vsakim izvozom katalog.csv.
- **`out.ExportColumnChange`**: zgodovina samodejnih sprememb stolpcev.
- **`out.GetExportRows`**: vrednost atributa brez jezika gre v stolpec »… SLO«, če artikel za isti atribut nima vrednosti v sl.

**Objekti:** procedura `out.SyncAttributeExportColumns`, tabela `out.ExportColumnChange`, sprememba `out.GetExportRows`. **Ročni korak:** ne (objaviti `PIM.B2bWorker`). Magento: glava se lahko razširi s stolpci na koncu.

## Hitrejši izvoz atributov SLO (migracija 287_HitrejsiIzvozAtributovSlo, 2026-09-28)

Pravilo 286 (vrednost brez jezika → SLO) je bilo zapisano kot `NOT EXISTS` nad istim `#Attribute` (kopica brez indeksa, pogoj v OR) in je sam porabil ~310 s na podjetje. 287 ga zapiše z okensko funkcijo (`MAX(CASE WHEN LanguageCode = N'sl' …) OVER (PARTITION BY RowKey, AttributeCode)`), pomen je enak.

- Meritev na razvojni bazi (DAVID\MSSQL19, cel katalog, `@Take = 0`): podjetje 2 **387 s → 24 s**, podjetje 3 **266 s → 20 s**; izhod procedure pred in po je za obe podjetji bajt za bajt enak.
- Preverjanje nabora atributov po artiklu (`#AttributeFilter`, 147) stane 0,5–0,8 s in ostane. Brez njega in z vsemi atributi kot stolpci izvoz ni hitrejši (sestava datoteke 14 → 22 s), v datoteko pa bi šli tudi atributi zunaj nabora.
- Migracija poišče stavek 286 po besedilu in pade, če ni v pričakovani obliki; ponoven zagon ne naredi ničesar (oznaka `/* 287 */`).

**Objekti:** sprememba `out.GetExportRows` (en stavek). **Ročni korak:** ne. Na razvojni bazi uveljavljena ročno (sqlcmd), brez vpisa v `dbo.SchemaMigration` — kot 285/286.

## Neskladja med podjetji (migracija 290_NeskladjaMedPodjetji, 2026-09-28)

Uporabnik: pregled in nadzor nad ERP obeh podjetij — ista šifra v IQ in ViD (viri kataloga `out.CatalogSource`) z manjkajočo kartico ali različnimi kljukicami spletišč. Stran `/splet/neskladja`.

- **`intranet.GetOrganizationMismatches`** (samo bere): vrste `MANJKA_GLAVNA` (ViD ima kljukico spletišča, ki ga ne sme prispevati — svetila — IQ artikla nima ali je neaktiven), `MANJKA_DRUGA` (IQ ima kljukico spletišča, ki ga sme prispevati tudi ViD, ViD artikla nima), `RAZLICNE_KLJUKICE` (obe kartici aktivni, kljukice različne). Vrne tudi »V katalogu po kljukicah« (unija po pravilu 285, brez kategorije in validacije) in »ne gre na«. Iskanje brez šumnikov, predpona šifre, razvrščanje in listanje v bazi; števci po vrstah, predpone, viri.
- **Pravica `view.web.mismatches`** za ADMIN, CATALOG_EDITOR, COMMERCIAL, VIEWER (kot `view.web.withdrawals`).
- Razvojna baza: 360 neskladij (322 manjka v IQ — 154 NW + 168 BA, 30 manjka v ViD, 8 različnih kljukic); klic 1,5 s na mirni bazi.

**Objekti:** procedura `intranet.GetOrganizationMismatches`, vrstice v `sec.RolePermission`. **Ročni korak:** ne (objaviti intranet).

## Odprodaja: naročila kupcev zmanjšajo količino (migraciji 288_OdprodajaOdstejNarocila in 289_OdprodajaNarociloOdVidenjaPim, 2026-09-28)

Uporabnik: na strani Odprodaja se nastavi samo, kaj je v odprodaji in koliko; katalog.csv pošlje odprodajo, popust in količino; naročila kupcev količino sproti zmanjšujejo. Odločitve: štejejo **vsa** naročila kupcev iz SAOP (VNK, `sales.OrderLine` iz `PIM.SaopOrdersWorker`, splet + trgovina + B2B), odšteje se **ob naročilu**, pri 0 gre v katalog Odprodaja = NE in količina 0 (Magento pri 0 odprodaje ne pokaže), vrstica ostane.

- Nič se ne odšteva v tabeli; preostanek se izračuna: **`pim.ClearanceItemRemaining(@OrganizationId)`** vrne vrstice odprodaje podjetja s `Kolicina` = vpisano − prodano (nikoli pod 0), `ZacetnaKolicina`, `Prodano`, `Narocila` (npr. `2026/VNK/3495 (1.00)`). Stornirano/preklicano naročilo ne šteje; zaprta vrstica šteje samo odpremljeno količino.
- **`pim.ClearanceItem.StetjeOdUtc`** + sprožilec **`pim.TR_ClearanceItem_StetjeOd`**: štetje prodaje začne ob vnosu vrstice, ob spremembi količine (nova količina = nova zaloga) in ob obnovi zaključene vrstice. Ponovni uvoz iste datoteke (enaka količina) štetja ne ponastavi.
- **`sales.OrderHeader.PrvicVidenoUtc`** (289): kdaj je PIM naročilo prvič zapisal. Naročilo šteje, če je njegov dan ≥ dan začetka štetja **in** ga je PIM videl po začetku štetja. SAOP pri naročilu pove samo dan, zato je brez tega popravek količine isti dan odštel že znano naročilo še enkrat (najdeno pri preizkusu 288).
- **`out.GetExportRows`**: blok OdprodajaExport234 bere `pim.ClearanceItemRemaining` namesto `pim.ClearanceItem` (oznaka `/* 288 */`); imena stolpcev in pravilo DA pri količini > 0 ostanejo.
- **`intranet.GetClearanceOverview`**: nova stolpca ZacetnaKolicina, Prodano, Narocila; `VKatalogu` zdaj zahteva še obkljukano spletno stran in aktiven artikel (prej je kazal DA tudi za artikle, ki niso na spletu).
- Preizkus na razvojni bazi (DAVID\MSSQL19) s testnimi naročili `2099/TEST288` (pobrisana): 14 − 4 = 10; stornirano in starejše naročilo ne štejeta; zaprta vrstica 2 naročeno / 1 odpremljeno šteje 1; izvoz za artikel na spletu 3 → 1 (DA) → 0 (NE, popust 0); popravek na 1 isti dan ne odšteje že znanega naročila; ponoven uvoz Azzardo datoteke ohrani odšteto.

**Objekti:** stolpca `pim.ClearanceItem.StetjeOdUtc`, `sales.OrderHeader.PrvicVidenoUtc`; sprožilec `pim.TR_ClearanceItem_StetjeOd`; funkcija `pim.ClearanceItemRemaining`; spremembi `out.GetExportRows`, `intranet.GetClearanceOverview`. **Ročni korak:** ne. Pogoj za delovanje: `PIM.SaopOrdersWorker` (SAOP_ORDERS_VNK) mora teči — na razvojni bazi `sales.OrderLine` je še prazna. Na razvojni bazi uveljavljeni z `Invoke-PendingMigrations.ps1` (v `dbo.SchemaMigration`).

## Odprodaja na kartici izdelka: preostanek (migracija 296_OdprodajaNaKarticiPreostanek, 2026-09-28)

Kartica izdelka (Splet → Odprodaja) je kazala vpisano količino, katalog.csv pa preostanek po naročilih (288). **`intranet.GetClearanceItemsForProduct`** zdaj bere `pim.ClearanceItemRemaining` za podjetje izdelka in vrne še ZacetnaKolicina, Prodano, Narocila; `Kolicina` je preostanek. Kartica kaže Vpisano / Prodano (naročila) / Ostane in stanje (aktivna, razprodano, količina 0, zaključena); obrazec za ročni vnos pokaže obstoječo ročno vrstico.

Hkrati (koda, brez baze): `ClearanceService` uvoz, ročni vnos in zaključitev ob zastoju z zajemom iz SAOP (Msg 1205) ponovi do trikrat — prvi uvoz Azzardo na DEV je bil žrtev zastoja z `map.ProcessPlanningInbox`.

Številke 291–295 je rezervirala druga seja. **Objekti:** sprememba `intranet.GetClearanceItemsForProduct`. **Ročni korak:** ne. Na razvojni bazi uveljavljena s sqlcmd brez vpisa v `dbo.SchemaMigration` (runner bi uveljavil tudi nedokončano 290 druge seje).

## Katalog: vsi atributi, poenotene vrednosti, veljavne kategorije (migracije 291_KatalogVsiAtributiPoenotenjeKategorije, 292_HitrejsiIzvozKatalogaPoStevilkahStolpcev, 293_IzvozKatalogaStolpciPoStevilkahPopravek, 2026-09-28)

Uporabnik: v katalogu morajo biti vsi atributi, kljukice »Spletne strani« morajo kazati isto kot PIM, Napetost naj bo za izmenično vedno enaka (splet je v filtru kazal »~220-230« in »220-230« kot dve vrednosti), prav tako frekvenca; kategorije morajo štimati; izvoz mora biti hiter in zanesljiv.

Meritve na razvojni bazi pred 291: 81.257 vrednosti atributov je imelo stolpec, v katalog.csv pa so ostale prazne — nabor atributov po kategoriji (147) je v izvoz spustil **samo** atribute iz nabora. Napetost je imela 12 zapisov (~220-230, 220-230, 220/230, ~220-230V, 24, DC5 …), frekvenca 3, CRI in faktor moči presledke in decimalno vejico. Na spletišču videlektro je bilo ~390 poti na podjetje, ki jih ni v drevesu (okrnjene »1-fazni Profile«, stari prevodi); EN prevod »1-fazni 48V LVM« je bil »1-circuit 48V   UT- LVM«. Kljukice: kartica in izvoz sta se ujemala 100 % — pravilo ostane.

- **`pim.NormalizeAttributeValue(@AttributeCode, @Value)`** (skalarna, kliče se enkrat na različno vrednost): presledki, znak spredaj (»≥ 80« → »≥80«), decimalna vejica v čistem številu/razponu → pika, **Napetost** vedno `~220-230` (izmenična) oz. `DC 24` (enosmerna), brez V; brez oznake od 100 V naprej izmenična, pod 100 V enosmerna; **Frekvenca** `50/60`; nato slovar **`map.ValueLookup` z jezikom `ENOTNO`** (domena = slovensko ime lastnosti ali `*`; stran `/pravila/slovar` ponuja »ENOTNO«). Nov indeks `IX_ValueLookup_LanguageKey`.
- Obstoječe vrednosti poenotene v `canon.ProductAttribute` (sprožilec zapiše `pim.ProductFieldHistory`, vir POENOTENJE) in `pim.ProductAttribute`; dnevnik obeh **`pim.AttributeValueNormalizationLog`** (prej/potem) — 7.142 vrstic na DEV.
- **`map.ApplyValueTransforms`** (oznaka `Poenotenje291`): vrednosti atributov vsakega zajema gredo skozi isto pravilo; izvirnik ostane v `map.ExtractedValue.RawValue` (094 ga ob ponovni obdelavi vrne).
- **`out.GetExportRows`**: nabor po kategoriji je le izločevalen — izpade samo atribut z ravnijo EXCLUDED (če ga druga kategorija izdelka ne vključi), izračun nabora se preskoči, ko EXCLUDED ni (`VsiAtributi291`); vrednosti atributov skozi preslikavo `#NormalMap291`; v stolpce kategorij gre samo pot iz **`canon.WebSiteCategoryPath`** (nov pogled: pot v jeziku spletišča iz imen prednikov + shranjena slovenska pot vozlišča) (`VeljavnaPot291`).
- Kategorije: EN prevod »1-fazni 48V LVM« → »1-circuit 48V LVM« v obeh drevesih (`canon.SaveCategoryTranslations`, zgodovina) in EN poti izdelkov pod njim; odvečne neveljavne poti (izdelek ima na istem spletišču veljavno, ročna uvrstitev ostane) odstranjene iz canon in pim — kopija v **`canon.ProductCategory_pred291`** / **`pim.ProductCategory_pred291`** (DEV: 1.797 / 1.725 vrstic; razveljavitev = INSERT nazaj). **`map.ResolveProductCategories`** in **`val.Promote`** (oznaka `Pospravi291`) po zapisu odstranita isto vrsto ostankov, ker sta do zdaj poti samo dodajala.
- **292/293** (hitrost): razdelek D izbira stolpec po številki kanonične kode (`#FieldNo291`, `#ValueNo293`) namesto primerjave niza v Slovenian_CI_AS za vsako vrednost; pretvorba enot (216d) išče enoto v `#UnitValue292`; velika začetnica (216c) samo pri vrednostih z malo začetnico in brez rezanja pri 4.000 znakih. 292 je sestavljanje postavil v izpeljan stik, ki ga je SQL Server ponavljal za vsako vrstico (izvoz ustavljen po 10 min); 293 to popravi — **292 brez 293 ne uvajati**.
- Rezultat na DEV (podjetje 2 / 3): izpolnjenih celic 120.889 → 154.652 / 119.931 → 156.021, vsi atributi s stolpcem v izvozu (0 manjkajočih), Napetost 8 zapisov (~220-230, ~220-240, ~250, ~230, ~450, DC 48, DC 24, DC 5), Frekvenca 50/60 in 50, neveljavnih poti 787/813 → 1/2 (predogled VID 219 »Track systems« proti »Track Systems«), kljukice kartica = izvoz 2176/2176 in 2448/2448, čas izvoza 36 s → 30–39 s (org 2), 30 s → 32 s (org 3); izpis po 293 celica za celico enak izpisu po 291.

**Objekti:** funkcija `pim.NormalizeAttributeValue`, pogled `canon.WebSiteCategoryPath`, tabele `pim.AttributeValueNormalizationLog`, `canon.ProductCategory_pred291`, `pim.ProductCategory_pred291`, indeks `IX_ValueLookup_LanguageKey`, spremembe `out.GetExportRows`, `map.ApplyValueTransforms`, `map.ResolveProductCategories`, `val.Promote`; podatki `canon/pim.ProductAttribute`, `canon/pim.ProductCategory`, `canon.CategoryTranslation`, 1 vrstica `map.ValueLookup`. **Ročni korak:** ne (objaviti intranet zaradi izbire ENOTNO na `/pravila/slovar`). Na DEV uveljavljene z `Invoke-PendingMigrations.ps1` posamično (vpis v `dbo.SchemaMigration`).

## Vklop lepega zapisa vrednosti atributov (migraciji 314_VklopLepegaZapisaVrednostiAtributov in 316_LepZapisBrezEnotAtributov, 2026-09-30, naloga #49)

Lastnik 2026-09-29: lep zapis (predlog 307) vklopiti za vse naenkrat — nove uvoze, katalog.csv in obstoječe vrednosti — z zgodovino in povratkom. 2026-09-30: nič v SAOP, cene in jeziki katalog.csv (SL, EN) ostanejo.

- **`pim.PolishAttributeValue`** (307, ALTER v 314 in 316): najprej `pim.NormalizeAttributeValue` (291), nato razpon »30 - 50« → »30-50«, presledek za vejico (»3CCT,IP65« → »3CCT, IP65«), presledek pred enoto (»10W« → »10 W«), velika začetnica pri čistem besedilu (»bela« → »Bela«), slovar ENOTNO. 314 je vejico premaknil **pred** enoto (7 vrednosti predloga 307 ni bilo stabilnih: »3.7V,6600mAh« je drugi klic spet spremenil). Pri miru pusti: Napetost, Frekvenca, polja s kodo (SEKUNDARNAMERSKAENOTA), povezave, e-naslove, **polja, ki jih PIM piše v SAOP** (`out.SaopXmlField`, npr. `ProductAttribute.Garancija`), **cilje slovarja ENOTNO** (izjema uporabnika velja, kot jo zapiše) in (316) **spremljevalne atribute »Enota …«** (»kgs« ne postane »Kgs«).
- **`map.ApplyValueTransforms`** (oba klica v bloku `Poenotenje291`) in **`out.GetExportRows`** (blok `#NormalMap291`) kličeta `pim.PolishAttributeValue` namesto `pim.NormalizeAttributeValue` (oznaka `Lep314`; REPLACE na živi definiciji, sidro mora biti 2x oz. 1x). Še vedno po **različnih** vrednostih strani/teka: na strani 1.000 izdelkov (1.672 različnih vrednosti) +1,1 s (Normalize 0,5 s → Polish 1,5 s); celoten izvoz strani je na DEV pod obremenitvijo 25–70 s, razlika je v šumu.
- Enkratno poenotenje v eni transakciji, pred zapisom kontrola, da je vsaka nova vrednost stabilna: DEV `canon.ProductAttribute` 27.490 vrstic (316 od tega 2.730 enot vrne) in `pim.ProductAttribute` 5.668 vrstic, 3 podjetja; dnevnik **`pim.AttributeValueNormalizationLog`** (`ChangedBy` = `migracija 314` / `migracija 316`), canon še `pim.ProductFieldHistory` (vir POENOTENJE; sprožilec ne zapiše sprememb, ki se razlikujejo samo v veliki/mali črki — te so samo v dnevniku). Po 314+316: 0 različnih vrednosti, ki bi jih pravilo zapisalo drugače (canon in pim). Nič ne gre v `out.*` / vrsto za SAOP.
- Nov indeks **`IX_AttributeValueNormalizationLog_ChangedBy`**; nova procedura **`pim.RevertAttributeValueNormalization @ChangedBy, @Actor, @DryRun = 0`**: vrne `OldValue` iz dnevnika (zadnja sprememba te oznake na vrstico), samo kjer je vrednost še enaka `NewValue`; zapiše dnevnik `povratek <oznaka> (<kdo>)` in zgodovino canon (vir POVRAT_POENOTENJA). Povratek podatkov **ne izklopi pravila** v zajemu in izvozu (katalog.csv ostane lepo zapisan; za izklop je potrebna migracija). Preizkus na DEV v preklicani transakciji: 24.760 + 5.668 vrnjenih, 2.730 preskočenih (spremenila jih je 316).
- Stran `/nastavitve/atributi/ciscenje?pogled=zapis`: pasica »vklopljeno«, ostanek (ročni vnosi po vklopu) in **Dnevnik poenotenj** z izvozom prej/potem v Excel.

**Objekti:** `pim.PolishAttributeValue`, `pim.RevertAttributeValueNormalization` (nova), `IX_AttributeValueNormalizationLog_ChangedBy`, `map.ApplyValueTransforms`, `out.GetExportRows`; podatki `canon/pim.ProductAttribute` (+ dnevnik, + `pim.ProductFieldHistory`). **Ročni korak:** ne (objaviti intranet zaradi strani). 316 brez 314 ne uvajati.

## Odprodaja in zaloga v glavnem skladišču (migracija 297_OdprodajaZalogaGlavnegaSkladisca, 2026-09-28)

Uporabnik: količino odprodaje vpišemo; ob vpisu se preveri zaloga artikla v glavnem skladišču (IQ: Brnčičeva). Enaka zaloga = vsa zaloga je za odprodajo (SAOP ob prodaji sam zmanjša zalogo, naročila samo za vsak slučaj); večja = redna prodaja in nekaj kosov za odprodajo (velja vpisano minus naročila); manjša = napaka z obvestilom. Med skladišči se nič ne prestavlja.

- **`pim.ClearanceItem.ZalogaObVpisu`, `ZalogaObVpisuUtc`**: zaloga (`out.CatalogStock.OwnAvailable`) in čas posnetka ob vnosu, spremembi količine ali obnovi. Sprožilec `pim.TR_ClearanceItem_StetjeOd` je zdaj `AFTER INSERT, UPDATE`.
- **`pim.ClearanceItemRemaining`**: novi stolpci Zaloga, ZalogaSveza, ZalogaObVpisu, ZalogaObVpisuUtc, **Nacin** (CELA / DEL / PREMALO / NEZNANA). `Kolicina` (katalog.csv) = vpisano − naročeno, pri sveži zalogi (pravilo 207: `out.CatalogOwnStockFresh` + posnetek < 30 min) največ zaloga; pri PREMALO največ zadnja znana zaloga, tudi stara.
- **`intranet.GetClearanceOverview`, `intranet.GetClearanceItemsForProduct`**: novi stolpci. Stran Odprodaja: stolpec Zaloga z načinom, števec »Zaloge premalo«, filter »Samo zaloga premalo ali neznana«; predogled uvoza našteje artikle z zalogo premalo ali neznano in jih pokaže prve. Kartica izdelka: stolpec Zaloga z načinom.
- Razvojna baza, Azzardo 177: CELA 168, PREMALO 8 (npr. AZ.0858 6 v datoteki / 3 na zalogi → na splet 3), NEZNANA 1. Simulacija sveže zaloge (transakcija, razveljavljena): prodan AZ.0059 v SAOP (zaloga 0) → na splet 0. Ročni vnos 5 pri zalogi 14 → DEL. Nov uvoz 177 vrstic 1,3 s, ponoven 0,25 s, predogled 0,23 s.
- **Odprto:** artikel v IQ in ViD — katalog.csv vzame vrstico (tudi odprodajo) iz IQ, če ga IQ objavlja; odprodaja, vpisana v ViD, tam ne velja. Obvestilo v zvoncu za PREMALO še ni (zahteva register vrst obvestil).

**Objekti:** stolpca `pim.ClearanceItem.ZalogaObVpisu`/`ZalogaObVpisuUtc`, sprožilec `pim.TR_ClearanceItem_StetjeOd`, funkcija `pim.ClearanceItemRemaining`, proceduri `intranet.GetClearanceOverview`, `intranet.GetClearanceItemsForProduct`. **Ročni korak:** ne. Na razvojni bazi uveljavljena s sqlcmd brez vpisa v `dbo.SchemaMigration` (kot 296).

## Atributi z jezikom namesto končnice ANG/SLO (migraciji 294_AtributiJezikNamestoKoncniceAngSlo in 295_NeprevedenaVrednostNePovoziPrevoda, 2026-09-28)

Uporabnik: »Prevladujoča barva ANG« in »… SLO« ne smeta biti atributa v PIM, ampak samo stolpca v katalog.csv (osnova + prevod). 124 je končnico enkrat prenesla v `LanguageCode`, zajem pa ni bil prilagojen: 160 ciljev `map.FieldMapping` »ProductAttribute.<ime> ANG/SLO« (NW_XML, BT_XML) je `map.ProcessRawInbox` pisal kot ločena imena, zato je vsak uvoz obnovil ~80.000 starih vrstic (17 lastnosti), prave vrstice z jezikom pa so ostale pri stanju 27. 8. (razen ročnih popravkov v intranetu). Izvoz je stolpec »… ANG« polnil iz obeh.

- **294 — `map.ProcessRawInbox`** (oznaka `Jezik294`): cilj »<ime> SLO/ANG«, kjer je <ime> v registru (`canon.AttributeTranslation` sl), se zapiše kot <ime> z `LanguageCode` sl/en; MERGE primerja tudi jezik. Preslikave ostanejo — končnica v cilju pomeni jezik.
- **294 — podatki:** vrednost stare vrstice gre v vrstico <ime>+jezik (nova ali posodobljena), razen kjer je bila prava vrstica ročno popravljena v intranetu (`pim.ProductFieldHistory`, vir INTRANET — ostane); stara vrstica gre. DEV: canon 80.765 odstranjenih, 280 novih, 179 posodobljenih; pim 72.913 / 224 / 177. Vse v `pim.AttributeValueNormalizationLog` (odstranjena vrstica: staro ime, `NewValue` NULL), canon tudi v `pim.ProductFieldHistory`. Imena brez atributa v registru (testni »F5 … SLO«) ostanejo.
- **295 — `map.ProcessRawInbox`** (oznaka `Prevod295`): vrstica sl se ne posodobi, če je nova vrednost enaka angleški istega atributa v istem zapisu in ima izdelek že drugačno slovensko (neprevedena vrednost ne povozi prevoda; prevede se na `/kakovost/prevodi`). 26 vrstic (13 canon, 13 pim), ki jih je 294 tako povozila (»Nikelj« → »Nickle«), je vrnjenih iz dnevnika.
- Izvoz: stolpci »… SLO/ANG« izpolnjeni enako kot pred 294 (npr. Prevladujoča barva 2.360 / 2.360, org 2), noben atribut s stolpcem ne manjka; 39 celic org 2 drugačnih zaradi svežih vrednosti uvoza (npr. NW.10328 »Prozorna« → »Črna«).

**Objekti:** sprememba `map.ProcessRawInbox`; podatki `canon/pim.ProductAttribute`. **Ročni korak:** ne. Prvi pravi preizkus zajema: naslednji uvoz XML (SUPPLIER_CATALOG_IMPORT) — po njem v canon ne sme biti atributov »… ANG/SLO« brez jezika.

## Nabor atributov za svetila (migracija 299_NaborAtributovSvetila, 2026-09-28)

Uporabnik je poslal seznam 39 atributov, ki veljajo za vse kategorije svetila.si in razsvetljave na videlektro (s pripombami: barva svetlobe z imenom, ne v kelvinih; pametno upravljanje brez on/off; drsnik za IP, moč, svetlobni tok, dimenzije).

- **Novi atributi** (`canon.CreateAttributeDefinition`, ENUM, prevodi en/de/hr/it): `BARVA_SVETLOBE`, `PAMETNO_UPRAVLJANJE`, `POVEZLJIVOST`, `VRSTA_SENZORJA`.
- **Obstoječi atributi** za ostala imena, ker izdelki vrednosti hranijo po slovenskem imenu: Prostor → Uporaba, Stil → Slog, Barva → Prevladujoča barva, Material → Prevladujoč material, Svetlobni vir → Vrsta svetlobnega vira, Zatemnitev → Zatemnljivo, IP zaščita → IP stopnja zaščite, Moč → Nazivna moč, Senzor → Senzor gibanja, Temperatura svetlobe → Temperatura barve, Material/Barva komplementarna → Dopolnilni material I / Dopolnilna barva I, Domet → Razdalja detekcije, Kot zaznavanja → Kot detekcije, Čas delovanja → Časovna zakasnitev, Svetlobna občutljivost → Luks, Kot svetenja → Kot svetlobnega snopa, Število sijalk → Število svetlobnih virov, Vključuje sijalko → Svetilka vključuje svetlobni vir, Vhodna napetost → Napetost, Frekvence → Frekvenca, CRI → Indeks barvnega videza (CRI), Vidna dimenzija → Dolžina, Širina, Višina, Premer, Vgradna dimenzija → Izvrtina (cutout); ostali po enakem imenu. Ime s seznama in želja za filter sta v `Note` vrstice nabora (»Svetila 2026-09-28: …«).
- **Nabor:** vsi atributi kot RECOMMENDED (opozorilo, ne blokira spleta) na korenske kategorije `svetila_si` (vseh 6) in `videlektro` (`razsvetljava` + trije korenski `razsvetljava___tracni_sistemi___*`), prek `canon.SaveCategoryAttributeSet` (zahteve `val.FieldRequirement`, `b2b.AuditLog`). Obstoječe vrstice na isti kategoriji niso spremenjene. `SortOrder` po seznamu uporabnika.
- DEV (DAVID\MSSQL19): 4 atributi, 349 vrstic nabora, 349 aktivnih zahtev, 353 vnosov revizije; `notranja_svetila` in `razsvetljava___luci` imata zdaj 47 učinkovitih atributov.
- **Povratek:** `canon.SaveCategoryAttributeSet @Level = NULL` za vrstice z `UpdatedBy = 'migracija 298'` (oznaka akterja je ostala iz prvotne številke).

**Objekti:** podatki `canon.AttributeDefinition`, `canon.AttributeTranslation`, `canon.CategoryAttributeSet`, `val.FieldRequirement`, `b2b.AuditLog`. **Ročni korak:** ne; učinek na validacijo ob naslednjem `PRODUCT_VALIDATION`, na katalog.csv ob naslednjem `WEB_CATALOG_EXPORT`. Na DEV uveljavljena z `Invoke-PendingMigrations.ps1` posamično (vpis v `dbo.SchemaMigration`).

## Kartica artikla: dolžina in prostornina v SAOP (migraciji 298_KarticaDolzinaInProstorninaVSaop in 300_KarticaDolzinaInProstorninaLastPim, 2026-09-28)

Uporabnik: »dej vse v oblačke in da se da vse urejat, nič zaklepat — program mora sam zaznati, ali gre za SAOP polje«; sodelavec: »lahko širino in višino, dolžino pa ne morem«. Zajem je `PropertiesData/ItemLength` (`ProductCommercial.PackageLength`) in `ItemVolumePerUnit` (`ProductCommercial.Volume`) bral od 057, pisati pa ju PIM ni smel: v registru `out.SaopXmlField` ju ni bilo, v `out.OwnershipPolicy` (068) sta bili »SAOP« (beremo, ne pišemo). Specifikacija SAOP (`SAOP_API_swagger_v2.json`, PropertiesData) obe polji sprejme.

- **298:** dve vrstici v `out.SaopXmlField` (SAOP_PRODUCT, PropertiesData, decimal8, ni obvezno ob dodajanju).
- **300:** `out.OwnershipPolicy` Owner = PIM za obe polji v vseh podjetjih s pravili SAOP_PRODUCT (1–4). Pomen »PIM« (068): pisljivo IN zajem ga še naprej bere nazaj.
- Posledica: kartica, uvoz/izvoz delovnega lista in `/saop/zgodovina` obravnavajo polji kot ostala SAOP polja — PIM takoj (`pim.SaveProductErpFieldsBulk` ju je že poznal), v SAOP po odobritvi. Nič se ne pošlje samo od sebe.
- DEV (DAVID\MSSQL19): po 300 ni nobenega omogočenega polja v registru SAOP_PRODUCT (razen ključa ItemID), ki ne bi bilo last PIM v vseh štirih podjetjih.
- **Povratek:** `UPDATE out.SaopXmlField SET IsEnabled = 0` za obe vrstici in Owner = 'SAOP' v `out.OwnershipPolicy` (UpdatedBy = 'migracija 300').

**Objekti:** podatki `out.SaopXmlField`, `out.OwnershipPolicy`. **Ročni korak:** ne. **Tveganje:** prvo pošiljanje dolžine/prostornine v živi SAOP — pred množično odobritvijo odobri eno sporočilo in preveri potrditev na `/saop/zgodovina`. Na DEV uveljavljeni s `PIM.Migrator --migrations <mapa s samo to datoteko>` (vpis v `dbo.SchemaMigration`).

Intranet v istem koraku (brez migracije): kartica bere davčno stopnjo iz `Product.VatRateId` (prej napačen ključ `Product.VatRate`), ERP opisi/nazivi v drugih jezikih so urejljivi (vir PIM, označeni »samo PIM« — SAOP jih ne sprejme), kategorije in dodajanje atributa na zavihku Splet (`ProductCategoryEditor`), `CategoryMappingService` preverja vlogo `CatalogWrite`.

## Enota na atributu (migracija 301_EnotaNaAtributu, 2026-09-29)

Uporabnik: atribut ima svojo mersko enoto; uvozi prepoznajo, v kateri enoti je vpisano, in pretvorijo; atributi enot ostanejo za lažje preslikave XML, PIM in katalog.csv pa gledata samo glavni atribut in njegovo enoto v `[]`. Besedilne vrednosti (»do 30m«) so dovoljene, uvoz opozori.

- **`canon.AttributeDefinition.Unit`** dobijo glavni atributi iz `out.CatalogUnitRule` (38; ista enota kot v glavi katalog.csv), atributi enot pa `UnitOfAttributeCode` (34 parov).
- **`canon.UnitConversion`** (inline, mm/cm/m, g/kg, cm3/dm3/l/m3, sopomenke mt/kgs/gr …) in **`canon.AttributeUnitValue`** (ena vrednost: ista enota -> samo število, kot je zapisano; druga enota iste vrste -> pretvorba; »1.500 m« se zaradi dvoumnosti ne pretvori; besedilo ostane).
- **`canon.NormalizeAttributeUnits`** dela nad `#AttributeSource` klicatelja: glavni atribut v enoti atributa (enota iz vrednosti ali iz atributa enote istega izdelka), atribut enote poravnan. **`val.Promote`** ga pokliče pred MERGE v `pim.ProductAttribute` (oznaka Enota301) — izvorni sloj `canon` ostane, kot ga pošlje vir.
- **`canon.AlignAttributeUnits`** v `pim.SaveProductAttributes` in `pim.SaveProductAttributesBulk`: vrednost s kartice ali iz Excela je v enoti atributa, atribut enote izdelka se nastavi na to enoto (sicer bi stara »m« iz XML novo vrednost pretvorila še enkrat).
- **Enkratna uskladitev PIM:** 9.325 vrednosti (razvojna baza; npr. »10000h« -> 10000, paket I iz mm v cm, »Dolžina 50 + mt« -> 50000 mm), samo vrstice, enake izvornemu sloju; dnevnik `pim.AttributeValueNormalizationLog` (ChangedBy »migracija 301«).
- Prva različica je bila pogled nad vsemi vrednostmi (>10 min za eno podjetje) — nadomeščen s postopkom; `val.Promote` org 2 37 s, org 3 31 s (normalizacija ~5 s na podjetje).
- katalog.csv: glave ostanejo enake (stalni stolpci iz 216); pretvorba 216d dobi atribut enote že v ciljni enoti (količnik 1).

**Objekti:** `canon.AttributeDefinition` (Unit, UnitOfAttributeCode), `canon.UnitConversion`, `canon.AttributeUnitValue`, `canon.NormalizeAttributeUnits`, `canon.AlignAttributeUnits`, spremembe `val.Promote`, `pim.SaveProductAttributes`, `pim.SaveProductAttributesBulk`; podatki `pim.ProductAttribute`. **Ročni korak:** ne. **Povratek:** `OldValue` v dnevniku; `val.Promote` vrniti na blok MERGE iz `canon.ProductAttribute`.

## Odprodaja tudi v starih stolpcih katalog.csv (migracija 304_OdprodajaVStarihStolpcihKataloga, 2026-09-29)

Preizkus uvoza Azzardo (2026-09-29): artikel v odprodaji je imel v novih stolpcih (234) »Odprodaja - popust %« 55 in »Odprodaja - količina« 2, v starih (204/207) »Popust na artikel«, »Popust odprodaje %« in »Količina odprodaje« pa 0. Kateri stolpec bere Magento, iz kode ni razvidno. Uporabnik: »popravi stare stolpce odprodaje v katalog.csv«.

- **`out.GetExportRows`** (oznaka OdprodajaStariStolpci304, tik pred `CREATE CLUSTERED INDEX IX_Value`): za vrstice z »Odprodaja« = DA se polji `Product.ClearancePercent` in `Clearance.Quantity` zamenjata z že izračunanima `ClearanceItem.DiscountPercent` in `ClearanceItem.Quantity` — stari stolpci so vedno enaki novim, tudi po popravkih količine (288, 297).
- Artikli brez aktivne odprodaje: nespremenjeno (oddelčni popust X/O iz Nadzora kataloga, zaloga X/O).
- Glave, število in vrstni red stolpcev ostanejo enaki. Velja za vse profile nad `out.GetExportRows` (tudi MAGENTO_STOCK_PRICES).
- Razvojna baza: 119 artiklov v odprodaji, v starih stolpcih 0 neusklajenih, ostalih 2.775 vrstic nespremenjenih; izvoz 40 s kot prej.

**Objekti:** `out.GetExportRows`. **Ročni korak:** ne. **Povratek:** iz definicije odstraniti blok OdprodajaStariStolpci304.

## »Popust na artikel« brez odprodaje (migracija 305_PopustNaArtikluBrezOdprodaje, 2026-09-29)

304 je popust odprodaje zapisala v `Product.ClearancePercent`, ki ga bereta dva stolpca: »Popust odprodaje %« in »Popust na artikel« (COL030). Uporabnik: »Popust na artikel« ne sme mešati odprodaje (nevarnost dvojnega popusta v Magentu). »Popust na artikel« ne izhaja iz cenikov SAOP — PIM iz cenikov zajema samo neto ceno in DDV; vir je od 204 oddelčni popust X/O iz Nadzora kataloga (045: prazen stolpec »Popust«, 217: preimenovan).

- **`out.GetExportRows`** (oznaka PopustNaArtikluBrezOdprodaje305 v bloku 304): novo polje `Clearance.CatalogDiscountPercent` = `Product.ClearancePercent`; blok 304 pri artiklih v odprodaji prepiše to polje (in `Clearance.Quantity`), `Product.ClearancePercent` ostane nedotaknjen.
- **`out.ExportColumn`:** »Popust odprodaje %« (MAGENTO_PRODUCTS COL217 in CATALOG_CLEARANCE, MAGENTO_STOCK_PRICES CATALOG_CLEARANCE) → `Clearance.CatalogDiscountPercent`. »Popust na artikel« (COL030) ostane `Product.ClearancePercent`.
- Razvojna baza: 119 artiklov v odprodaji — »Popust na artikel« 0, »Popust odprodaje %« in »Količina odprodaje« enaka novima stolpcema; hitri izvoz cen enako; ostale vrstice nespremenjene. F7 catalog lifecycle (X/O) PASS.
- Besedilo v proceduri je brez šumnikov: `Invoke-PendingMigrations.ps1` dinamičnega SQL ne bere kot UTF-8 (komentar bloka 304 ima zato pokvarjene znake, na delovanje ne vpliva).

**Objekti:** `out.GetExportRows`, podatki `out.ExportColumn`. **Ročni korak:** ne. **Povratek:** stolpce »Popust odprodaje %« vrniti na `Product.ClearancePercent` in iz bloka 304 odstraniti vrstice 305.

## Pakirno naročanje (migraciji 302_PakirnoNarocanje in 303_PakirnoNarocanjeEnaNic, 2026-09-29, naloga #5)

Artikel se na spletu naroča samo po celih paketih; količino paketa Magento vzame iz stolpca »Pakirna količina« (Pakiranje 2 = SAOP `ItemQuantityOfPackaging2`). Oznaka je samo PIM, po podjetju, privzeto ne; v SAOP ne gre.

- **302:** oznaka `PAKIRNO_NAROCANJE` v `pim.ProductFlagDefinition` (kartica, Oznake; zapis `pim.SaveProductFlags` z zgodovino); `out.ExportColumn` COL034 profila MAGENTO_PRODUCTS = »Pakirno naročanje« (prej prazen »Omejitev pri naročanju«); vrednost v `out.GetExportRows`; `val.SyncPackageOrderHolds` (artikel z oznako brez Pakiranja 2 > 1 dobi zadržek WEB »pravilo 302«, sprosti se sam); `pim.SetProductFlagsBulk` (uvoz delovnega lista). Izvoz katalog.csv pred sestavo pokliče `val.SyncPackageOrderHolds` enkrat na podjetje.
- **303:** odločitev lastnika 29. 9. 16:59 (naloga #13): v katalog.csv je vrednost **1/0**, ne DA/NE. Popravek žive definicije `out.GetExportRows` (REPLACE natanko enega izraza v bloku 302, marker `PakirnoNarocanje303`). Kartica in Excel ostaneta Da/Ne oziroma D/N. »Razstavni eksponat« in »Odprodaja« ostaneta DA/NE.

**Objekti:** `pim.ProductFlagDefinition` (podatek), `out.ExportColumn` (podatek), `out.GetExportRows`, `val.SyncPackageOrderHolds`, `pim.SetProductFlagsBulk`. **Ročni korak:** ne. **Vrstni red:** 303 zahteva 302. **Povratek 303:** v `out.GetExportRows` vrni `N'1'`/`N'0'` na `N'DA'`/`N'NE'`. Na DEV 303 uveljavljena posamično s `sqlcmd -f 65001` in vpisom v `dbo.SchemaMigration` (hash kot `Invoke-PendingMigrations.ps1`). **PRD:** 302 in 303 skupaj, šele po lastnikovi potrditvi.

## Pakirno naročanje: razlog zadržka (migracija 306_PakirnoNarocanjeRazlogZadrzka, 2026-09-29, naloga #5)

Preverjalec: kartica je kazala Pakiranje 2 iz zajema (`canon.ProductCommercial`, npr. 50), pravilo 302 in katalog.csv pa objavljeno vrednost (`pim.ProductCommercial`, npr. 1 ali artikel še ni objavljen); razlog zadržka je velel »vpiši Pakiranje 2«, čeprav je bilo vpisano (163 od 166 zadržkov na DEV).

- `val.SyncPackageOrderHolds` (CREATE OR ALTER, isti parametri in izhodi): pravilo ostane (zadržek, dokler **objavljeno** Pakiranje 2 ni > 1, ker ga nosi »Pakirna količina« v katalog.csv), razlog pa loči: manjka tudi v zajemu → »vpiši Pakiranje 2 ali odstrani oznako«; vpisano, artikel še ni objavljen v PIM → »čaka objavo«; vpisano, objavljena vrednost je še stara → »na splet gre še objavljena vrednost Y«. Razlog aktivnega zadržka »pravilo 302« se posodobi, ko se stanje spremeni. Ročnih zadržkov ne spreminja.
- Migracija na koncu pokliče `val.SyncPackageOrderHolds` (obstoječi zadržki dobijo pravi razlog; na DEV 163 posodobljenih).

**Objekti:** `val.SyncPackageOrderHolds`, podatki `val.ProductHold.Reason` (samo aktivni zadržki »pravilo 302«). **Ročni korak:** ne. **Vrstni red:** zahteva 302. **Povratek:** ponovno izvedi blok 4 iz 302. **PRD:** skupaj s 302 in 303, šele po lastnikovi potrditvi.

## Preverjanje slik: ali se naslov res odpre (migracija 312_PreverjanjeSlik, 2026-09-30, naloga #9)

Lastnik (odločitev #18, 29. 9.): napaka validacije samo, če izdelek nima nobene delujoče slike (ena pokvarjena od več = opozorilo); pokvarjena šele po 2 neuspehih v razmiku 24 ur; pokvarjene slike se izpustijo iz katalog.csv, glavna postane prva delujoča.

- **`val.MediaUrlCheck`** (nova): izid na **naslov** (ključ `UrlHash` = SHA2_256 obrezanega naslova), ne na `ProductMediaId` — zajem XML vrstice slik zamenja. Stolpci: zadnji izid (`OK` / `NAPAKA` / `NI_ODZIVA`), HTTP status, vrsta vsebine, koda in besedilo napake, prvič/zadnjič neuspešno, število neuspehov; `IsBroken` je izračunan stolpec (≥ 2 neuspeha, zadnji vsaj 24 h po prvem). `NI_ODZIVA` (429, 5xx, 401/403, časovna meja) števca ne poveča; `OK` ga ponastavi.
- **`val.GetMediaUrlsToCheck`** (vpiše nove naslove aktivnih izdelkov aktivnih podjetij, vrne paket: novi, potrditev po 24 h, brez odziva po 6 h, ostali po 7 dneh) in **`val.RecordMediaUrlChecks`** (izidi kot JSON; vrne število na novo pokvarjenih in popravljenih). Kliče ju `PIM.SourceFetchWorker --preveri-slike` (posel `MEDIA_URL_CHECK`, privzeto izklopljen).
- **`canon.FieldValue`** (zamenjava žive definicije, oznaka PreverjanjeSlik312): izpeljani polji `ProductMedia.DelujocaSlika` (manjka, ko ima izdelek slike in so vse pokvarjene) in `ProductMedia.VseSlikeDelujejo` (manjka, ko ima vsaj eno pokvarjeno in vsaj eno delujočo). Izdelek brez slik ima obe polji izpolnjeni (zanj velja `ProductMedia.Url`).
- **`val.FieldRequirement`** (podatek): v profilih z zahtevo `ProductMedia.Url` (DEV: WEB_svetila_si, WEB_videlektro) `DelujocaSlika` = ERROR, `VseSlikeDelujejo` = WARNING. Validacija (`val.RunValidation*`) ju bere kot vsako polje — en JOIN, brez spremembe procedur.
- **`out.GetExportRows`** (zamenjava žive definicije, bloki 302–306 ostanejo): blok B3 izpusti potrjeno pokvarjene slike; če je bila izpuščena glavna, postane glavna prva preostala.
- **`intranet.GetMediaUrlChecks`**: stran `/mediji/napacni-naslovi` in izvoz (strežniško listanje, filtri stanje/podjetje/strežnik/napaka, števci).
- **`ops.ScheduleProfile`** (podatek): `MEDIA_URL_CHECK` pod prvim aktivnim podjetjem (za `ops.BeginRun`); vklop posla je v katalogu poslov.
- Dokler posel ne teče, v `val.MediaUrlCheck` ni pokvarjenih naslovov in se validacija ter katalog.csv ne spremenita. DEV: 19.016 naslovov vpisanih, 60 preverjenih (58 OK, 2× 404 na www.vipelektro.si). Dokaz v transakciji z ROLLBACK: izdelek z eno pokvarjeno od dveh slik ostane VALID z opozorilom in katalog.csv ima samo delujočo; izdelek z edino pokvarjeno sliko postane INVALID (napaka DelujocaSlika v obeh spletnih profilih) in slike v katalog.csv nima.
- Proceduri z izračunanim stolpcem zahtevata `QUOTED_IDENTIFIER ON` (sqlcmd `-I`, SqlClient privzeto).

**Objekti:** `val.MediaUrlCheck`, `val.GetMediaUrlsToCheck`, `val.RecordMediaUrlChecks`, `intranet.GetMediaUrlChecks`, `canon.FieldValue`, `out.GetExportRows`, podatki `val.FieldRequirement` in `ops.ScheduleProfile`. **Ročni korak:** ne (posel ostane izklopljen, dokler ga skrbnik ne vklopi). **Povratek:** zahtevi `DelujocaSlika`/`VseSlikeDelujejo` nastaviti na `IsActive = 0` in `DELETE val.MediaUrlCheck` (validacija in katalog.csv se vrneta v stanje pred 312). **PRD:** skupaj z intranetom in workerjem; pred vklopom posla preštej, koliko izdelkov bi padlo s spleta.
## Hitra sled sprememb (migracija 310_SledSpremembHitrejse, 2026-09-30, naloga #44)

Stran `/sistem/sled` se ni naložila: `intranet.GetUserActivityTrail` (172) je ob vsakem odprtju prebrala celo `pim.ProductFieldHistory` (2,7 milijona vrstic) in jo šele na koncu razvrstila za TOP.

- Nov indeks `IX_PimProductFieldHistory_Changed` na `pim.ProductFieldHistory (ChangedAtUtc DESC) INCLUDE (ChangeBatchId, OrganizationId, ItemID, FieldKey, Owner)`; `IF NOT EXISTS`, `ONLINE = ON` samo na izdajah, ki to znajo (EngineEdition 3/5/8).
- `intranet.GetUserActivityTrail` (CREATE OR ALTER, isti parametri, isti stolpci, istih 7 virov, isto iskanje): vsaka veja vzame največ `@Take` najnovejših ustreznih vrstic (filter uporabnika in iskanja je v veji), nato združitev in TOP. Polja izdelkov v dveh korakih (`#polje`: ChangeId, nato vrednosti za največ `@Take` vrstic). Pri iskanju se LIKE za uporabnika izračuna enkrat na paket (`#paket`), za opis »Polje X (lastnik)« enkrat na par polje/lastnik (`#opis`), po vrsticah samo za šifro; prazen način se preskoči.
- Meritev na DEV (obremenjen strežnik): 7 dni / 500 vrstic 0,13–0,27 s (prej 6 s topel, 77–108 s hladen predpomnilnik); leto + iskanje »cena« 0,7 s (prej 12 s); leto + šifra »NW.79« 1,7–4,3 s. Primerjava z definicijo 172 v 10 scenarijih (obdobje, uporabnik, iskanje po uporabniku/šifri/opisu/alarmu/urniku/B2B): enake vrstice (razlika le v vrstnem redu vrstic s popolnoma enakim časom na meji TOP, kar je bilo nedoločeno že prej).

**Objekti:** indeks `IX_PimProductFieldHistory_Changed`, `intranet.GetUserActivityTrail`. **Podatki:** nič. **Ročni korak:** na PRD uveljavi izven urnikov uvozov — gradnja indeksa traja od nekaj sekund do nekaj minut; na izdaji brez ONLINE (Standard/Express) je med gradnjo pisanje v `pim.ProductFieldHistory` blokirano. **Strošek:** en indeks več pri vsakem zapisu zgodovine polj (~60.000 vrstic na dan ob uvozih). **Povratek:** ponovno izvedi razdelek 8 iz `172_AdminConsole.sql` in `DROP INDEX IX_PimProductFieldHistory_Changed ON pim.ProductFieldHistory`.
## Indeksa zgodovine za razveljavitev in brisanje artikla (migracija 313_IndeksUndoOfChangeId, 2026-09-30, naloga #82)

`pim.UndoProductField` in `pim.UndoProductBatch` (037) preverjata, ali je sprememba že razveljavljena (`WHERE UndoOfChangeId = @ChangeId`). Na tem stolpcu ni bilo indeksa, zato je vsaka razveljavitev pregledala celo `pim.ProductFieldHistory` (~2,7 mio vrstic; DEV 88.730 logičnih branj) in čakala na vsako tujo odprto transakcijo, ki piše zgodovino. Enak pregled je delal tuji ključ `FK_PimProductFieldHistory_Undo` ob brisanju vrstic zgodovine, `FK_PimProductFieldHistory_Product` pa ob brisanju artikla (obstoječi indeks se začne z `OrganizationId`).

- **`IX_PimProductFieldHistory_UndoOf`** (`UndoOfChangeId`) `WHERE UndoOfChangeId IS NOT NULL` — filtriran, vsebuje samo vrstice razveljavitev (na DEV 0 strani), navadno pisanje zgodovine ga ne vzdržuje. Vse procedure in sprožilci, ki pišejo v tabelo, imajo `QUOTED_IDENTIFIER ON` (preverjeno v `sys.sql_modules`).
- **`IX_PimProductFieldHistory_ProductId`** (`ProductId`) — ozek indeks za tuji ključ na `canon.Product` (DEV 7.810 strani ≈ 61 MB).
- Gradnja z `ONLINE = ON`, kjer izdaja to dopušča (Enterprise/Developer/Azure); sicer navadno (na Standard med gradnjo zaklene pisanje zgodovine — poženi izven konice). DEV: 5 s.
- DEV po migraciji: preverba razveljavitve 0 logičnih branj (prej 88.730), iskanje po `ProductId` 3 (prej 12.592).

**Objekti:** indeksa na `pim.ProductFieldHistory`; procedure nespremenjene. **Ročni korak:** ne. **Povratek:** `DROP INDEX IX_PimProductFieldHistory_UndoOf ON pim.ProductFieldHistory; DROP INDEX IX_PimProductFieldHistory_ProductId ON pim.ProductFieldHistory;`
## Pasica »spremembe za SAOP čakajo potrditev« brez čakanja (migraciji 309_HitraPasicaSaop in 311_HitriPogledZadrzanihSaop, 2026-09-30, naloga #46)

Stran Izvozi (`/outbound`) se je odpirala 50-60 s, ker je pasica z zadržanimi spremembami za SAOP (`intranet.GetSaopHeldMessages`) tekla toliko časa; isto so čakale `/cene`, `/saop/artikli`, `/izvozi/mnozicno` in odobritev serije.

- **311 — `ops.SaopHeldMessage`** (CREATE OR ALTER VIEW, ista definicija kot v 281 + en pogoj): pravilo SAOP_KLJUCNO išče prejšnjo vrednost polja v `pim.ProductFieldHistory` (~2,7 mio. vrstic) zdaj tudi po `OrganizationId`, zato SQL uporabi `IX_PimProductFieldHistory_Product (OrganizationId, ProductId)`. Prej 20 mio. branj in ~60 s ob vsakem branju pogleda. Zgodovina izdelka je vedno v podjetju izdelka (preverjeno na DEV: 0 izjem), izid je enak.
- **309 — `intranet.GetSaopHeldMessages`** (CREATE OR ALTER, isti parametri in izhodi): naziv artikla se išče z dvema ločenima APPLY (najprej po šifri `UQ_CanonProduct_OrganizationItem`, nato po EAN `IX_CanonProduct_OrganizationEan`) namesto enega z `OR`.
- DEV: `EXEC intranet.GetSaopHeldMessages` (vsa podjetja, 1.380 vrstic) prej 283 s (ob obremenjeni bazi), zdaj 1,1 s; za IQ (631 vrstic) 0,24 s. Izpis pred in po je enak do znaka.
- Intranet (ni migracija): pasica bere seznam šele po prvem izrisu strani, meja branja 15 s.

**Objekti:** `ops.SaopHeldMessage`, `intranet.GetSaopHeldMessages`. **Ročni korak:** ne. **SAOP:** nič (samo branje). **Povratek:** ponovno izvedi definiciji pogleda in procedure iz 281. **PRD:** lahko skupaj z intranetom.
## Posebni S za tip/stranko z /izdelki v enem paketu z razveljavitvijo (migracija 317_SPosebniMnozicnoInRazveljavitev, 2026-09-30, naloga #33)

Seznam izdelkov (`/izdelki` → S-popust …) je posebni S za tip stranke ali stranko pisal po vrstici (`b2b.SavePackagingDiscountRule` / `RemovePackagingDiscountRule`): pri celem pogledu do ~90.000 klicev, brez skupne sledi in brez razveljavitve.

- **`b2b.PackagingDiscountRuleBatch`** — en paket = en množični zapis v enem podjetju za en cilj (TYPE ali CUSTOMER): koda (NULL = umik), zahtevano/spremenjeno/enako/izpuščeno, kdo in kdaj, razveljavitev (`UndoneUtc`, `UndoneBy`, `UndoneCount`).
- **`b2b.PackagingDiscountRuleBatchItem`** — vrstica na spremenjen izdelek: `ActionCode` INSERT/UPDATE/DEACTIVATE, `RuleId`, stara koda in veljavnost, nova koda.
- **`b2b.SavePackagingDiscountRulesBulk`** (`@OrganizationId`, `@TargetKind`, `@CustomerTypeCode` | `@CustomerKey`, `@DiscountCode` NULL = umik, `@ItemsJson` = JSON seznam šifer, `@Actor`, `@Note`, `@ChangeSource`): ena transakcija, pravila ITEM se ustvarijo/posodobijo/umaknejo naenkrat; vsaka sprememba gre v `b2b.AuditLog` (EntityType `PackagingDiscountRule`, prej/potem, `$.PackagingBatchId` v `NewValueJson`). Izdelki brez `pim.Product` se izpustijo z razlogom. Vrne `BatchId, ChangedCount, UnchangedCount, SkippedCount` in izpuščene vrstice. Vedenje enako kot 274 po vrstici (nova koda pobriše veljavnost od/do).
- **`b2b.UndoPackagingDiscountRuleBatch`** — prej brez pravila = umik, prej druga koda = stara koda in veljavnost, prej umaknjeno = spet aktivno; vrstice, ki jih je kdo po paketu spremenil, ostanejo (vrnjene kot izpuščene z razlogom). Drugič istega paketa ne razveljavi. V `b2b.AuditLog` `ActionCode = UNDO`, `$.UndoOfPackagingBatchId`.
- **`intranet.GetPackagingDiscountRuleBatches`** (`@CreatedBy`, `@Take`) — zadnji paketi za seznam na `/izdelki`.
- DEV (IQ, 89.855 izdelkov, en klic): zapis 16 s, sprememba kode 12 s, umik 11 s, razveljavitev 14 s; 6.000 izdelkov ~1 s. Prej 90.000 klicev po vrstici.

**Objekti:** tabeli `b2b.PackagingDiscountRuleBatch`, `b2b.PackagingDiscountRuleBatchItem`; procedure zgoraj. Obstoječe procedure nespremenjene. **Ročni korak:** ne. **SAOP:** nič. **Izvoz:** posebni S gre v `katalog.csv` ob naslednjem `WEB_CATALOG_EXPORT` kot doslej. **Povratek:** `DROP PROCEDURE` treh procedur, `DROP TABLE b2b.PackagingDiscountRuleBatchItem, b2b.PackagingDiscountRuleBatch` (pravila ostanejo, kot so).
## Hitrejši predogled spletnega izvoza (migracija 315_HitrejsiPredogledIzvoza, 2026-09-30, naloga #80)

Predogled `/splet/izvoz` (`intranet.GetWebExportRows` → `out.GetExportRows`, profil MAGENTO_PRODUCTS, 200 vrstic) je trajal 8–55 s. Meritev na DEV (`sys.dm_exec_query_stats`, `sys.dm_os_waiting_tasks`): strežnik ima `cost threshold for parallelism` = 5 in MAXDOP 10, zato so majhni stavki nad začasnimi tabelami tekli z 10 nitmi; porabili so 0,1–0,5 s CPU, čakali pa do 46 s (CXPACKET/CXCONSUMER, LATCH_EX NESTING_TRANSACTION_FULL), kadar je bil strežnik obremenjen. Poleg tega je osnovni `INSERT #Value` za 200 vrstic trikrat razvrstil vse cene `pim.ProductPrice`, štetje in stran pa sta filter (z iskanjem LIKE po besedilih) izvedla dvakrat.

Popravek bere živo definicijo `out.GetExportRows` (kot 304/305), preveri vsa sidra (vsako natanko enkrat) in spremeni samo vejo PIM_PRODUCT in skupni rep:
- filter izdelkov se izvede enkrat v `#Match80` (ROW_NUMBER po `product.ItemID`); `@TotalCount` in stran (`OFFSET/FETCH`) prideta iz nje. Migracija pred zamenjavo preveri, da sta bila filtra štetja in strani besedilno enaka;
- cene (B2B, B2C, katerakoli) v osnovnem `INSERT #Value` se razvrščajo samo za izdelke strani (`PARTITION BY PimProductId`, izid enak);
- `#ValidPath291` vsebuje samo poti, ki jih imajo izdelki strani (tabela se bere samo s temi potmi);
- `OPTION (MAXDOP 1)` na `#SpecialAll274`, osnovnem `INSERT #Value`, `#Attribute`, `#UnitValue292` in `#GroupDiscount` (stranke).

Isto proceduro uporablja nočni `katalog.csv` (`@Take = 0`). Primerjava izhoda pred/po na DEV (vse vrstice, vsi stolpci, `@TotalCount`) v 11 primerih — IQ (2) MAGENTO_PRODUCTS celoten in strani 0/400, iskanje »AZ.0722« in »led«, MAGENTO_STOCK_PRICES celoten, Vidadria (3) celoten in stran, Ediito (4) celoten, MAGENTO_CUSTOMERS za 2 in 3: **enako do bajta**. Čas 200 vrstic brez tuje obremenitve 3,7–5,5 s (prej 7–10 s, ob obremenitvi 45–55 s zaradi vzporednih načrtov).

**Objekti:** `out.GetExportRows`. **Podatki:** nič. **Ročni korak:** ne. **SAOP:** nič. **Povratek:** definicija pred 315 ni shranjena v datoteki — povratek je `ALTER` z odstranitvijo sprememb z oznako `HitrejsiPredogled80` (vsebina izvoza je v obeh različicah enaka). **Opomba za PRD:** migracija zahteva, da so 142, 251, 274, 291, 292, 304 že uveljavljene (sidra); če sidro manjka, se ustavi brez sprememb.
## Hitra pripravljenost artiklov na /kakovost/artikli (migracija 318_HitrejsaKakovostArtikli, 2026-09-30, naloga #102)

Stran `/kakovost/artikli` (in gola `/kakovost`, ki preusmeri nanjo) se je odpirala 26-73 s. `intranet.GetQualityProducts` (264) je naredil `SELECT * INTO #Rows` iz pogleda `val.ProductChannelReadiness` za vse aktivne artikle (~160.000) — za vsakega naziv, števce napak, zadržke, kljukice spletišč s kategorijo in veljavnostjo profilov ter korelirano iskanje odjavnega okna 251 — in šele nato razvrstil in preštel. DEV: CPU 13-14 s na klic.

- **`intranet.GetQualityProducts`** (CREATE OR ALTER, isti parametri, isti izhodni stolpci in vrstni red): po korakih v ozkih začasnih tabelah izračuna samo to, kar potrebujejo razvrstitev, filter stanja in števci — `#Org` (podjetja v obsegu enkrat), `#P` (artikli + iskanje po šifri/EAN/nazivu), `#Issue` (samo blokirajoče napake), `#Shop`/`#Sites` (~12.000 kljukic spletišč), `#Hold`, `#Withdrawal` (odjavno okno enkrat na podjetje), `#R` (stanje na artikel). Polne vrstice pogleda se preberejo samo za `@Take` artiklov na strani.
- Pravila so ista kot v `val.ProductChannelReadiness` (242/251); pogled ostane nespremenjen (bere ga tudi kartica izdelka). **Ob spremembi pravil v pogledu popravi tudi to proceduro.**
- Novo: neznano stanje se primerja s stanjem za katalog.csv (`WebExportState`), zato povezave s `/splet` in `/splet/umaknjeni` (`stanje=BLOCKED_ERRORS`, `NO_CATEGORY` …) vrnejo artikle namesto praznega seznama.
- DEV (stara in nova definicija, 7 kombinacij filtrov — vsa podjetja, WEB_BLOCKED stran 2, PUBLISHED, IN_CSV za IQ, HOLD, iskanje, iskanje + NO_SITE): enaki števci in enake vrstice. Čas pod obremenitvijo drugih sej: vsa podjetja 1,8-3,6 s (prej 5-30 s), PUBLISHED 3,7 s (prej 47 s), iskanje 1,0 s (prej 7,4 s); CPU ~4 s (prej 13-14 s). Ob močno zasedenem strežniku (tempdb, CPU) še vedno do ~20 s.
- Intranet (ni migracija): `/kakovost/artikli` brez predupodabljanja, zato se procedura ob odprtju strani izvede enkrat namesto dvakrat.

**Objekti:** `intranet.GetQualityProducts`. **Podatki:** nič. **SAOP:** nič (samo branje). **Ročni korak:** ne. **Povratek:** ponovno izvedi definicijo procedure iz 264. **PRD:** lahko skupaj z intranetom.
## Združitev podvojenih atributov z dnevnikom in povratkom (migracija 319_ZdruziAtribute, 2026-09-30, naloga #48)

Nadaljevanje #15: na `/nastavitve/atributi/ciscenje` lahko urednik kataloga (politika `CatalogWrite`) izbrane pare podvojenih atributov združi v enega. Lastnik 2026-09-29: »Grlo« in »Podnožje / socket« → ostane Grlo, angleško »socket«; ostale pare izbere sam. Nič se ne združi samodejno (migracija sama ne združi ničesar).

- **`pim.AttributeMerge`** — ena združitev: izvorni (opuščeni) in ciljni atribut (koda in slovensko ime), povzetek (JSON), kdo/kdaj, razveljavitev (kdo/kdaj/povzetek).
- **`pim.AttributeMergeItem`** — vrstica na spremembo: vrednosti pri izdelkih (`canon.ProductAttribute`, `pim.ProductAttribute`; `MOVED` = vrstica preimenovana na cilj, `FILLED` = prazen cilj dobil vrednost, `DROPPED_SAME` = enaka vrednost, `DROPPED_CONFLICT` = različna vrednost, cilj zmaga) in nastavitve (`map.FieldMapping`, `map.AttributeMap`, `canon.CategoryAttributeSet`, `val.FieldRequirement`, `out.ExportColumn`, par enote v `canon.AttributeDefinition`, deaktivacija izvornega atributa, angleško ime cilja) s stanjem prej/potem.
- **`canon.MergeAttributeDefinitions`** (`@SourceAttributeCode`, `@TargetAttributeCode`, `@TargetEnglishName`, `@Actor`, `@DryRun`, `@AttributeMergeId OUTPUT`). `@DryRun = 1`: povzetek, štetje po podjetjih, do 50 trkov — nič se ne zapiše. Sicer ena transakcija (zaklep obeh definicij): vrednosti po slovenskem imenu (125), preslikave zajema XML na cilj ali izklop, če ista že gre v cilj (sicer bi zajem opuščeni atribut spet napolnil), register virov na cilj (+ `map.AttributeMapHistory`), nabori/zahteve na cilj ali izklop ob dvojniku, izvozni stolpec na cilj, če profil cilja še nima (sicer ostane — glava katalog.csv se ne spremeni, stolpec je prazen), izvorni atribut `IsActive = 0` z opombo (ne izbriše), angleško ime cilja (+ `canon.AttributeTranslationHistory`). Zgodovina izdelka prek sprožilca (`ChangeSource = ZDRUZITEV_ATRIBUTOV`), `b2b.AuditLog` (`EntityType = AttributeMerge`, `MERGE`). Vrne povzetek in `ProductId` izdelkov, pri katerih je cilj dobil vrednost (stran jih validira v paketih po 200 z `val.RunValidationForProducts`).
- **`canon.RevertAttributeMerge`** (`@AttributeMergeId`, `@Actor`, `@DryRun`) — vrne samo, kar je še v stanju »potem« (vrednost, ki jo je kdo po združitvi spremenil, ostane; štetje preskočenih). Združitve, ki si delijo atribut, od zadnje proti prvi (sicer napaka 53199). `ChangeSource = POVRAT_ZDRUZITVE`, `b2b.AuditLog` `REVERT`.
- **`intranet.GetAttributeMerges`** (`@Top`) — seznam za »Zgodovino združitev« s stanjem, ali se da razveljaviti.
- DEV, par Podnožje / socket → Grlo: 402 izdelkov (Vidadria 327, IQLighting 75), 751 vrednosti, vse enake (0 trkov), 4 preslikave BT `socket` se izklopijo, 0 naborov, stolpec katalog.csv »Podnožje / socket« ostane prazen. Preizkus združitve in povratka v transakciji z ROLLBACK (tudi umeten trk in umetno premaknjena vrednost): po povratku vsa štetja enaka kot prej.

**Objekti:** tabeli in tri procedure zgoraj. **Podatki:** nič (združi šele uporabnik). **Ročni korak:** ne. **SAOP:** nič — vrednosti atributov niso v `out.SaopXmlField`, nič se ne postavi v vrsto. **Izvoz:** ciljni stolpec katalog.csv ima vrednosti ob naslednjem `WEB_CATALOG_EXPORT`. **Povratek migracije:** `DROP PROCEDURE canon.MergeAttributeDefinitions, canon.RevertAttributeMerge, intranet.GetAttributeMerges; DROP TABLE pim.AttributeMergeItem, pim.AttributeMerge` (najprej razveljavi združitve, sicer dnevnik izgine).

## Hitrejša stran Napake validacije (migracija 321_HitrejseNapakeKakovosti, 2026-09-30, naloga #122)

`/kakovost/napake` se je v vratih #108 nalagala 15 s, v vratih #112 106 s, filtri pa so javili »Odprtih težav trenutno ni mogoče naložiti«. Dva vzroka: (1) baza nima `READ_COMMITTED_SNAPSHOT`, zato je branje čakalo na zaklepe, ki jih validacija (`PRODUCT_VALIDATION`, ročni zagoni) drži na `val.ProductIssue`, in padlo na 60 s omejitvi ukaza — na DEV sta isti klic brez filtra enkrat trajala 0,2 s, drugič 16,4 s; (2) `intranet.GetQualityIssues` (177) je isti `EXISTS` nad ~1,8 M odprtimi težavami izračunal dvakrat (stran z `ORDER BY ItemID OFFSET` in `TotalCount`), pri redkem filtru polja pa ga je optimizator izvedel kot zanko po izdelkih v vrstnem redu šifre (4,7 s za 0 zadetkov, filter kategorije do 17,5 s).

- **`intranet.GetQualityIssues`** (CREATE OR ALTER, isti parametri, isti trije nabori in stolpci, isti pogoji): ujemajoči izdelki se izračunajo enkrat v `#Match`; stran je `OFFSET` nad `#Match`, `TotalCount` je `@@ROWCOUNT`. Bere `READ UNCOMMITTED` z `LOCK_TIMEOUT 20000` (vzorec #44, sled uporabnikov): ne čaka na zaklepe vrstic, ob zaklepu sheme (npr. gradnja indeksa) vrne napako 1222, ki jo stran pokaže kot »baza je zasedena«.
- **`intranet.GetQualityOverview`**: telo iz 218 nespremenjeno, dodano samo `READ UNCOMMITTED` + `LOCK_TIMEOUT 20000`.
- Novih indeksov ni: obstoječi filtrirani `IX_ProductIssue_Active_ProductRequirement` (`IsActive = 1`) že pokriva `EXISTS`.
- Pomen branja: seznam je bralni model za človeka; med tekom validacije lahko pokaže stanje sredi preračuna, ki ga naslednja osvežitev popravi. Izvoz Excel (`QualityIssueExportService`) bere isto proceduro.
- Intranet (ni migracija): vgrajena poizvedba za izbrani nivo (`QualityReadService.GetIssuesForProfilesAsync`) po istem vzorcu (`#Match`, `READ UNCOMMITTED`, na koncu vrne nastavitvi povezave). Stran nalaga pregled (števci, pravila, dobavitelji) vzporedno in neodvisno od seznama, prejšnje branje ob novem filtru prekliče, napake zapiše v dnevnik in loči »baza je zasedena« od drugih napak.
- DEV (org 2 IQ Lighting, 111.099 izdelkov; stara in nova definicija, 13 kombinacij — brez filtra, stran 2 in zadnja stran, polje EAN, neobstoječe polje, ERROR+ERP, WARNING, iskanje, profil, NONE+polje, kategorija s podkategorijami, org 4 iskanje+ERROR, org 1 Take 200): **enaki izhodi vseh treh naborov** (diff 0 vrstic). Čas nove 0,03-0,65 s (stara 0,1-17,5 s). Pregled 0,5-0,8 s, števci enaki kot prej. Nivo ERP_SLO (vgrajena SQL): 0,11 s, `TotalCount` enak ročnemu štetju (48.766).

**Objekti:** `intranet.GetQualityIssues`, `intranet.GetQualityOverview`. **Podatki:** nič. **SAOP:** nič (samo branje). **Ročni korak:** ne. **Povratek:** ponovno izvedi definicijo `GetQualityIssues` iz 177 in `GetQualityOverview` iz 218. **PRD:** lahko skupaj z intranetom.
## Hitra validacija paketov izdelkov (migracija 320_HitrejsaValidacijaPaketov, 2026-09-30, naloga #105)

Paketno urejanje na `/izdelki` (#10), uvoz delovnega lista (`/izdelki/uvoz`), združitev atributov in samodejni umik validirajo spremenjene izdelke z `val.RunValidationForProducts`. Zadnja definicija (249) je za 1.000 izdelkov IQ Lighting porabila 9,5 min in 87 mio logičnih branj, ves čas v eni transakciji: MERGE/UPDATE po `val.ProductIssue` (~30 vrstic na izdelek) je presegel 5.000 zaklepov in jih povzdignil na celo tabelo, zato so druge seje čakale (`LCK_M_IX`), strežnik pa je zaradi velike dodelitve pomnilnika zadrževal še druge poizvedbe (`RESOURCE_SEMAPHORE`). Vzroka: pogoj »polje ni izpolnjeno« je bil `NOT EXISTS` na pogled `canon.FieldValue` (UNION ALL, koda polja pri atributih/besedilih izračunana s `CONCAT`) za vsak par (izdelek, zahteva) — dvakrat — in `CROSS JOIN canon.Product × val.ValidationProfile`.

- **`val.RunValidationForProducts`** (CREATE OR ALTER, isti parameter `@ProductIdsJson`, oznaka `HitrejsaValidacijaPaketov320`):
  1. izračun pred pisanjem, samo za izbrane izdelke: `#Active`, `#Effective`, `#ScopedRequirement` (ime polja atributa enkrat na atribut v `#AttributeField`), `#Origin`, `#Shop` (kljukice spletišč), `#Req` (aktivne obvezne zahteve aktivnih profilov), `#FieldPresent` (pogled `canon.FieldValue` prebran **enkrat**, brez pogojev v `#FieldValueRaw`, šele nato filtriran — en stavek s pogoji na pogledu je imel nestabilen načrt, 20–145 s CPU), `#Applicable` (zahteve brez obsega kategorije × izdelki + zahteve z obsegom prek `#Effective`) z oznako manjkajočih (brez potrditev skrbnika);
  2. pisanje po **25 izdelkov v svoji kratki transakciji** (odpri/osveži napake, zapri napake, stanje profilov, brisanje stanja izven obsega 248, stanje izdelka). Izdelki so med seboj neodvisni, zato je rezultat enak kot v eni transakciji. Ob napaki ostanejo že zapisani paketi pravilno validirani, ostali v prejšnjem stanju; klic vrne napako kot doslej (`ops.LogError`, `RUN_VALIDATION_FAILED`).
- Pravila so enaka kot v 249: 182 (spletni profil samo za objavljene), 248 (brisanje stanja izven obsega), 249 (poreklo, potrditev skrbnika, ničla pri `ProductCommercial.*` = manjka). Zapiranje napak ima dobesedno pogoje 249 (tudi neaktiven izdelek/profil). `SET DEADLOCK_PRIORITY LOW` ostane.
- DEV (vzorec 1.005 izdelkov IQ Lighting: 500 s kljukico spletišča, 500 brez, 5 neaktivnih z odprtimi napakami; posnetek napak, stanj profilov in stanja izdelka pred in po, `EXCEPT` v obe smeri): **0 razlik** med stanjem pred tekom, po novi proceduri in po stari proceduri na istih izdelkih. Čas: nova 5,4–6,3 s za 1.005 izdelkov (prvi teki pod obremenitvijo drugih sej 34–42 s, pred popravkom branja pogleda), po uveljavitvi 5,6 s in **nobena druga seja ni čakala na zaklep**; stara 2.153 s (36 min) za samo 200 izdelkov istega vzorca pod obremenitvijo, ves čas je blokirala druge (`LCK_M_IX`, `LCK_M_IS`, `RESOURCE_SEMAPHORE`, 110 mio branj v prvih 10 min). Preizkus s pokvarjenim stanjem v transakciji z ROLLBACK (40 izdelkov: 3.827 obrnjenih napak, 242 izbrisanih stanj, lažna stanja spletnega profila, napačno stanje izdelka): nova procedura v 0,5 s vse aktivne izdelke vrne natanko v stanje stare; neaktivnih izdelkov (kot 249) ne validira.

**Objekti:** `val.RunValidationForProducts`. **Podatki:** nič. **Ročni korak:** ne. **SAOP:** nič. **Povratek:** ponovno izvedi definicijo procedure iz 249. **PRD:** neodvisno od intraneta (parameter in izhod enaka).
## Brez fiksnega števila stolpcev v imenu profila (migracija 325_OdstraniStevecStolpcevIzImenaProfila, 2026-09-30, naloga #92)

Na `/splet/izvoz` je profil MAGENTO_PRODUCTS nosil ime »Magento - izdelki (predloga 215 stolpcev)« (migracija 045), izvožen CSV pa ima 223 stolpcev. Število je bilo zapisano v imenu in je zastarelo.

- **`out.ExportProfile.Name`** za `MAGENTO_PRODUCTS` in `MAGENTO_CUSTOMERS`: odstranjena pripona » (predloga N stolpcev)« → »Magento - izdelki«, »Magento - stranke«; `UpdatedUtc` osvežen. Ponovljivo (brez pripone se ne spremeni nič).
- Intranet (ni migracija): izbirnik profila na `/splet/izvoz` pokaže živo število aktivnih stolpcev (`out.ExportColumn IsActive = 1`, isti nabor kot glava CSV), povzetek predogleda pa »v datoteki bo N vrstic in M stolpcev« iz glave predogleda. Čas v privzetem imenu prenesene datoteke (`PIM_splet_<profil>_yyyyMMdd_HHmm.csv`) je v naši uri (`PimTime`), ne več UTC.
- Profili se iščejo po `ProfileCode`, nikjer po imenu — sprememba ne vpliva na katalog.csv, stranke.csv, avtomatiko ali SAOP.

**Objekti:** `out.ExportProfile` (podatki, 2 vrstici). **Ročni korak:** ne. **SAOP:** nič. **Povratek:** `UPDATE out.ExportProfile SET Name = N'Magento - izdelki (predloga 215 stolpcev)' WHERE ProfileCode = N'MAGENTO_PRODUCTS'` (in »Magento - stranke (predloga 19 stolpcev)« za `MAGENTO_CUSTOMERS`). **PRD:** neodvisno od intraneta.
## Umik oddane zahteve za zagon posla (migracija 324_PrekliciZahtevoZaZagon, 2026-09-30, naloga #69)

Po »Poženi zdaj« (`ops.RequestJobRun`, 237) zahteve ni bilo mogoče umakniti: ostala je v `ops.JobDefinition.RequestedRunUtc`, dokler je gostitelj ni prevzel (29. 9. je tako preizkus s testnega intraneta sprožil izvoz kataloga). Na `/sistem` in `/sistem/posel/{JobKey}` je zdaj gumb **Prekliči zahtevo**.

- **`ops.CancelJobRunRequest`** (`@JobKey`, `@Actor`, `@NextDueUtc = NULL`) — pod `UPDLOCK, HOLDLOCK` preveri, da posel obstaja (52376), da ne teče (52388: gostitelj je zahtevo že prevzel) in da zahteva še čaka (52389). Počisti `RequestedRunUtc`, `RequestedBy` in `TriggerSource` ter postavi `NextDueUtc = @NextDueUtc`; zagon, ki ga je sprožil uspeh predhodnika (`TriggerSource = Dependency:…`), ostane nedotaknjen. Vrne prejšnjo zahtevo (`RequestedBy`, `RequestedRunUtc`) za sled.
- `@NextDueUtc` izračuna intranet (`MonitorService.CancelRunRequestAsync`): naslednji redni termin po urniku od zdaj (`JobCatalog.NextAfterEnd`; dnevni posel naslednja dnevna ura, ponavljajoč zdaj + razmik), pri izklopljenem poslu `NULL`. Izvirnega termina ni mogoče vrniti, ker ga `ops.RequestJobRun` prepiše z »zdaj«; `NULL` pri vklopljenem ponavljajočem poslu ne bi zadoščal, ker ga gostitelj postavi na zdaj + 30 s (`JobCatalog.InitialDue`).
- Sled: `ops.UserActivity` prek `LogActivityAsync`, `ActionCode = JOB_RUN_REQUEST_CANCEL`, prej = kdo je zahtevo oddal (tudi varovalka kataloga ali `/splet`), potem = naslednji redni zagon.
- DEV: v transakciji z ROLLBACK `RequestJobRun` → `CancelJobRunRequest` na `WEB_CATALOG_EXPORT` (zahteva počiščena, termin nastavljen), ponovni umik → 52389, neznan posel → 52376; test F11 7b (umik, gostitelj umaknjene zahteve ne prevzame, umik pri poslu, ki teče, zavrnjen).

**Objekti:** `ops.CancelJobRunRequest`. **Tabele:** brez sprememb. **Podatki:** nič. **Ročni korak:** ne (samo uveljavitev). **SAOP:** nič. **Povratek:** `DROP PROCEDURE ops.CancelJobRunRequest` (gumb potem vrne napako). **PRD:** skupaj z intranetom (intranet brez procedure ob kliku vrne napako, drugo deluje).
