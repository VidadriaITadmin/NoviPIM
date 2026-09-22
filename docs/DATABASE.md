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
