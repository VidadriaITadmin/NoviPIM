# Živ zajem iz SAOP — nastavitev, zagon, preverjanje, debagiranje

Namenjeno človeku, ki worker poganja ročno in preverja, ali so podatki res prišli v bazo.

---

## 1. Enkratna nastavitev

Poverilnice gredo v korensko `appsettings.Local.json` (ni v Gitu). Odpri jo in dopolni
tri polja v sekciji `Saop`:

```json
"Saop": {
  "BaseUrl": "https://<gostitelj>:<vrata>/iCenterAPI/",
  "Username": "<uporabnik>",
  "Password": "<geslo>"
}
```

Če gesla nočeš imeti v datoteki, ga podaj prek okolja — okolje ima prednost:

```bash
$env:PIM_SAOP_BASE_URL = 'https://<gostitelj>:<vrata>/iCenterAPI/'; $env:PIM_SAOP_USERNAME = '<uporabnik>'; $env:PIM_SAOP_PASSWORD = '<geslo>'
```

V isti sekciji je seznam `Organizations`. Vzorec vsebuje samo IQLighting (`Id: 2`).
Za vsako podjetje, ki ga želiš zajeti, dodaj vrstico z ustreznim `Id` in `SourceCode`;
`"IsActive": false` omogoča, da je vrstica že zapisana, ne da bi vplivala na zajem.

---

## 2. Prvi preizkus — en šifrant, eno podjetje

Začni z najmanjšo možno stvarjo: `Currencies` je en klic brez paginacije.

```bash
cd C:\Users\David\Namizje\PIM\NoviPIM\PIM_Solution; $env:PIM_SAOP_MODE='Live'; dotnet run --project workers\PIM.KatalogWorker -- --endpoints Currencies --organizations 2 --only-ingest
```

Pričakovan izpis:

```
Živ SAOP zajem: podjetij=1, končnih točk=1, delta zajem, brez preslikave.
[2] IQLighting (SAOP_IQLIGHTING)
  Currencies: strani=1 zapisov=<število>
  SKUPAJ strani=1 zapisov=<število> RunId=<guid>
```

`--only-ingest` pomeni: samo zapiši surov odgovor v `raw.Inbox`, brez preslikave. Za prvi
preizkus je to pravo — dokazuje povezavo in avtentikacijo, ne da bi karkoli spreminjal v
katalogu.

Če to uspe, je povezava v redu in lahko greš naprej.

---

## 3. Zajem artiklov

```bash
cd C:\Users\David\Namizje\PIM\NoviPIM\PIM_Solution; $env:PIM_SAOP_MODE='Live'; dotnet run --project workers\PIM.KatalogWorker -- --endpoints GetItemsGeneralData --organizations 2 --only-ingest
```

To pobere vse strani po 1.000 artiklov. Pri ~200.000 artiklih pričakuj ~200 strani.

Od migracije `044` preslikava ni več ozko grlo (razdelek 7); `--only-ingest` je zdaj
izbira, ne nuja.

Vsi argumenti:

| Argument | Pomen |
|---|---|
| `--endpoints A,B,C` | samo naštete končne točke (privzeto vseh 16) |
| `--organizations 2,3` | samo našteta podjetja (privzeto vsa aktivna) |
| `--full` | prezri mejnik in poberi vse (privzeto se pobere le spremenjeno) |
| `--only-ingest` | samo v `raw.Inbox`, brez preslikave v katalog; **mejnik se ne premakne** |
| `--map-run <RunId>` | preslikaj že zajet zagon iz `raw.Inbox`, brez klica na SAOP |
| `--max-parallel <n>` | koliko podjetij teče hkrati (privzeto 1, največ 8) |
| `--max-parallel-endpoints <n>` | koliko končnih točk istega podjetja hkrati (privzeto 1) |
| `--max-pages <n>` | ustavi se po n straneh na končno točko (za meritve) |
| `--page-size <n>` | koliko zapisov na stran (za meritve) |
| `--brez-neaktivnih` | ne zahtevaj neaktivnih artiklov (za meritve) |
| `--help` | izpiše seznam vseh znanih končnih točk |

---

## 3.1 Delta in poln zajem — zakaj prvi zagon prinese malo

Privzeto je **delta zajem**: worker prebere `map.Watermark` za tisto entiteto, odšteje
`LookbackDays` (privzeto 7) in od SAOP zahteva samo zapise, spremenjene po tem datumu.

Zato prvi zagon **ne** prinese celotnega kataloga. Izmerjeno 2026-08-21 na živem SAOP:
`GetItemsGeneralData` je vrnil **183 artiklov**, ker je bil mejnik za `ItemGeneralData`
postavljen ob prejšnjih zagonih — 183 je toliko, kolikor se jih je od takrat spremenilo.

Za ves katalog je potreben `--full`, ki mejnik prezre:

```powershell
dotnet run --project workers\PIM.KatalogWorker -- --endpoints GetItemsGeneralData --organizations 2 --full
```

Pri ~200.000 artiklih in `PageSize` 1.000 pričakuj ~200 strani. Zgornja meja je
`MaxPagesPerEndpoint` (privzeto 1.000), torej milijon zapisov na končno točko.

**Pozor na branje izpisa.** `Currencies` je šifrant valut, ne artikli. Izpis
`Currencies: strani=1 zapisov=181` pomeni 181 valut, ne 181 izdelkov.

## 3.2 Mejnik se premakne samo, kadar je bil podatek res uporabljen

Od 2026-08-21 mejnik stoji v štirih primerih; izpis vedno pove, v katerem:

| Zakaj mejnik stoji | Kaj to pomeni |
|---|---|
| za entiteto ni aktivne preslikave | zajeti podatek nima poti v katalog |
| zagon je bil `--only-ingest` | preslikave ni pognal nihče |
| SAOP je vrnil isto vsebino kot prej | `raw.Inbox` je strani prepoznal po hashu in jih ni vstavil znova, zato ta zagon nima česa preslikati |
| zajem je padel ali ni bilo cenika | obdobje je treba poskusiti znova |

Vsakič velja isto: **podatek ni izgubljen, samo čaka**, naslednji zagon isto obdobje
zajame znova.

Če v `raw.Inbox` ležijo nepreslikane vrstice iz prejšnjih zagonov, worker to izpiše kot
opozorilo. Preslikaš jih brez novega klica na SAOP:

```sql
SELECT DISTINCT RunId, EntityType, COUNT(*) AS Vrstic
FROM raw.Inbox WHERE Status = N'Pending' GROUP BY RunId, EntityType;
```

```powershell
dotnet run --project workers\PIM.KatalogWorker -- --map-run <RunId> --organizations 2
```

`--map-run` ne potrebuje niti poverilnic niti `PIM_SAOP_MODE=Live` — podatek je že v bazi.

---

## 3.3 Vzporedno po podjetjih — in zakaj samo po podjetjih

`--max-parallel <n>` požene do `n` podjetij hkrati. **Znotraj podjetja gre klic za klicem**,
zato SAOP od nas nikoli ne dobi več hkratnih zahtevkov, kot je podjetij. Vzporednost po
končnih točkah bi to mejo takoj podrla in je zato namenoma ni.

```powershell
dotnet run --project workers\PIM.KatalogWorker -- --full --max-parallel 4
```

Privzeto je 1, torej eno podjetje naenkrat — enako, kot je bilo doslej.

Dve meji varujeta SAOP pred preobremenitvijo; obe sta v `appsettings.Local.json`:

| Nastavitev | Vrednost | Kaj pomeni |
|---|---|---|
| `PageSize` | **5000** | največ 5.000 zapisov na stran — glej razdelek 3.5, zakaj več pomeni **manj** obremenitve |
| `MaxPagesPerEndpoint` | 1000 | največ 1.000 strani na končno točko |
| `DelayAfterSuccessMilliseconds` | 250 | premor po vsakem uspešnem klicu, znotraj podjetja |

Ko podjetja tečejo vzporedno, se izpisi ne prepletajo: vsako podjetje piše v svoj
medpomnilnik, ki se izpiše v enem kosu, ko je podjetje končano.

---

## 3.4 Nočni zajem — načrtovana naloga

Registrirana je ena sama naloga Windows, `NoviPIM - nocni zajem SAOP`, ki vsako noč ob
**02:00** požene [`scripts\Nocni-zajem.ps1`](../scripts/Nocni-zajem.ps1). Skripta sama odloči,
ali je nocojšnji zagon poln ali delta.

| Nastavitev | Vrednost | Zakaj |
|---|---|---|
| Sprožilec | vsak dan ob 02:00 | poln zajem štirih podjetij je 300.000+ zapisov; podnevi bi jemal zmogljivost ERP, ki ga uporabljajo ljudje |
| Poln zajem | 1. dan v mesecu | delta po zasnovi ne vidi brisanj; poln zajem je edini način, da se zanje izve |
| Hkratnost | `IgnoreNew` | če prejšnji zagon še teče, se novi ne zažene |
| Časovna meja | 8 ur | varovalka pred zagonom, ki se zatakne |
| Če zamudi | zažene, ko je mogoče | ugasnjen računalnik ne pomeni preskočenega meseca |
| Teče kot | `david`, samo ko je prijavljen | naloga uporablja Windows Integrated Auth do baze in bere `appsettings.Local.json` iz uporabniškega profila |

**Kar je treba vedeti:** naloga teče **samo, kadar je uporabnik prijavljen** (zaklenjen zaslon
je v redu, odjava ni). Za zagon brez prijave bi bilo treba shraniti geslo ali uporabiti
storitveni račun — to je odločitev, ne tehnična ovira.

Skripta ima svojo varovalko proti prekrivanju, neodvisno od `IgnoreNew`: pogleda v
`ops.PipelineRun` in se ne zažene, če kak zajem `SAOP_PRODUCTS` še teče. Dokazano v živo
2026-08-21 med polnim zajemom — skripta je izpisala `PRESKOCENO` in se končala z izhodom 0.

Dnevniki gredo v `logs\zajem_<datum>_<ura>.log`; starejši od 90 dni se pobrišejo sami.
To je začasno: naslednji korak je, da se podrobnost po končnih točkah zapiše v
`ops.PipelineStepLog`, kjer je poizvedljiva in se ne izgubi.

Ročno preverjanje in zagon:

```powershell
Get-ScheduledTaskInfo -TaskName 'NoviPIM - nocni zajem SAOP'
Start-ScheduledTask   -TaskName 'NoviPIM - nocni zajem SAOP'
```

Ritem se spremeni s parametrom skripte (`-DanPolnegaZajema`), dokler se pravilo ne preseli v
`ops.ScheduleProfile`.

---

## 3.5 Kaj je izmerjeno na živem SAOP (21. 8. 2026)

Prvi polni zajem vseh štirih podjetij: **195.756 artiklov**, 4 podjetja vzporedno.

| Podjetje | Strani | Zapisov | s/stran |
|---|---|---|---|
| DEMO | 95 | 83.372 | 1,9 |
| Vidadria | 211 | 193.159 | 2,3 |
| Ediito | 237 | 220.927 | 3,2 |
| IQLighting | 112 (samo 1 končna točka) | 111.065 | ~51 |

### Cena je na klic, ne na zapis

Meritve na `GetItemsGeneralData` za IQLighting, vse v isti uri:

| Poskus | Zapisov | Klicev | Čas | Na zapis |
|---|---|---|---|---|
| 1 stran po 1.000 | 1.000 | 1 | **50,4 s** | 0,050 s |
| 4 strani po 250 | 1.000 | 4 | **202,8 s** | 0,203 s |
| 1 stran po 5.000 | 5.000 | 1 | **51,6 s** | **0,010 s** |

SAOP porabi okrog **50 sekund za vsak klic** te končne točke, ne glede na to, koliko zapisov
vrne. Iz tega sledi troje:

1. **Manjše strani so strogo slabše.** Štirikrat več klicev je štirikrat več časa.
2. **Večje strani so strogo boljše** — in hkrati **manj obremenijo SAOP**, ker je klicev manj.
   Pri 5.000 na stran je poln zajem IQLighting 23 klicev namesto 112: **~20 minut namesto ~95**.
   `PageSize` je zato od 21. 8. 2026 nastavljen na **5.000**.
3. Počasna je **ena sama končna točka**, ne podjetje. Na istem podjetju in v isti minuti:
   `GetItemsDescriptions` 0,78 s/stran, `GetPrices` 2,16 s/stran, `GetItemsGeneralData` 50 s/stran.

Izklop neaktivnih artiklov (`IncludeNonActiveItems`) prihrani okrog 15 % — ni vzrok.

### Vzporedne končne točke: varne, a skoraj brez učinka

Tri končne točke istega podjetja hkrati proti zaporedno:

| Končna točka | Zaporedno | Vzporedno (3) |
|---|---|---|
| `GetItemsGeneralData` | 52,0 s/stran | 50,1 s/stran |
| `GetItemsDescriptions` | 0,75 s/stran | 0,78 s/stran |
| `GetPrices` | 2,05 s/stran | 2,16 s/stran |
| **Stenska ura** | **228 s** | **203 s** |

**SAOP se pod tremi hkratnimi zahtevki ne upogne** — časi na stran ostanejo enaki. To je
dobra novica in hkrati odgovor: vzporednost po končnih točkah prinese samo 11 %, ker ena
končna točka porabi 92 % časa. Zgornja meja je najdaljša končna točka.

Zato `--max-parallel-endpoints` ostaja privzeto **1**. Vzvod ni vzporednost, ampak
`PageSize`.

### Kako vem, ali je SAOP preobremenjen

Worker za vsako končno točko izpiše čas in **sekunde na stran**. Merilo je to število:
če pri isti končni točki in istem podjetju zraste, je SAOP pod obremenitvijo.
Izhodišča za IQLighting: `ItemGeneralData` ~50, `Prices` ~2, `Descriptions` ~0,8.

---

## 4. Kako preverim rezultate

Odpri [`scripts/pregled-podatkov.sql`](../scripts/pregled-podatkov.sql) v SSMS (baza `PIM`)
in poženi. Bere po vrsti od zajema do potrjenega kataloga.

Za hitro preverjanje po enem zagonu:

```sql
-- Je zagon uspel?
SELECT TOP 5 Pipeline, SourceCode, Status, RowsRead, RowsFailed,
       CONVERT(varchar(19), StartedUtc, 120) AS Zacetek
FROM ops.PipelineRun ORDER BY StartedUtc DESC;

-- Kaj je prišlo v surovi nabiralnik?
SELECT EntityType, Status, COUNT(*) AS Strani, MAX(PageNumber) AS ZadnjaStran
FROM raw.Inbox WHERE OrganizationId = 2
GROUP BY EntityType, Status ORDER BY EntityType;

-- Koliko artiklov in kako polnih?
SELECT COUNT(*) AS Artiklov,
       SUM(CASE WHEN EAN IS NOT NULL AND EAN <> '' THEN 1 ELSE 0 END) AS ZEan,
       SUM(CASE WHEN ItemGroup IS NOT NULL THEN 1 ELSE 0 END) AS ZSkupino
FROM canon.Product WHERE OrganizationId = 2;
```

**Vrstni red, po katerem podatek potuje** — če ga ni na koncu, poglej, kje se je ustavil:

```
raw.Inbox  →  map.ExtractedValue  →  canon.Product (+Text/Price/Media/Category/Attribute)
                     ↓ zavrnjeno
              map.UnmappedValue
```

---

## 5. Debagiranje

| Simptom | Kje pogledati | Kaj pomeni |
|---|---|---|
| `Manjkajo SAOP poverilnice` | — | `BaseUrl`, `Username` ali `Password` je prazen |
| `SAOP klic ni uspel … Status=401` | izpis workerja | napačen uporabnik ali geslo; izpis navede uporabnika, gesla nikoli |
| `SAOP klic ni uspel … Status=404` | izpis workerja | napačen `BaseUrl` — mora se končati z `/iCenterAPI/` |
| `Razpored ni omogočen` (51100) | `ops.ScheduleProfile` | za to podjetje manjka vrstica s `Pipeline='SAOP_PRODUCTS'` |
| `Izvajanje … že poteka` (51101) | `ops.IntegrationHealth` | drug zajem istega podjetja še teče ali je obtičal v `Running` |
| `V map.SourceConnector ni aktivnega vira` | `map.SourceConnector` | `SourceCode` iz nastavitev se ne ujema z bazo |
| Zajem uspe, katalog se ne spremeni | `map.UnmappedValue` | vrednosti so bile zavrnjene; stolpec `Reason` pove zakaj |
| `raw.Inbox` obtiči v `Pending` | `raw.Inbox.RunId` | preslikava se je prekinila; glej spodaj |
| Timeout pri preslikavi | — | `$env:PIM_MAPPING_TIMEOUT_SECONDS = '3600'` (privzeto 900) |

### Izpis `BREZ PRESLIKAVE` — ni napaka

Če worker za neko končno točko izpiše

```text
GetItemsPlanningData: strani=4 zapisov=1200 — BREZ PRESLIKAVE (map.EntityMapping/map.FieldMapping
za entiteto GetItemsPlanningData ni aktivne); zapisi ostanejo v raw.Inbox, mejnik NI premaknjen
```

pomeni, da je zajem uspel, preslikave v `canon` pa za to entiteto še ni. Preslikane so tri
entitete od šestnajstih (glej razdelek 8), zato je to pričakovano stanje, ne okvara.

**Mejnik se v tem primeru namenoma ne premakne.** Zapisi ležijo v `raw.Inbox` kot `Pending`;
ko preslikavo dodaš, bo naslednji zajem isto obdobje prinesel še enkrat in ga tokrat obdelal.
Če bi se mejnik premaknil, bi bilo tisto obdobje trajno preskočeno — delta zajem ga ne bi
več prinesel.

Koliko končnih točk je v tem stanju, worker pove na koncu podjetja:

```text
OPOZORILO: 13 končnih točk je zajetih brez preslikave. Njihovi mejniki niso premaknjeni,
zato jih bo naslednji zagon zajel znova.
```

Katere entitete imajo preslikavo, preveriš takole:

```sql
SELECT em.EntityType,
       (SELECT COUNT(*) FROM map.FieldMapping fm
        WHERE fm.SourceConnectorId = sc.SourceConnectorId
          AND fm.EntityType = em.EntityType AND fm.IsActive = 1) AS Polja
FROM map.SourceConnector sc
JOIN map.EntityMapping em
  ON em.SourceConnectorId = sc.SourceConnectorId AND em.IsActive = 1
WHERE sc.SourceCode = N'SAOP_IQLIGHTING'
ORDER BY em.EntityType;
```

Za premik mejnika sta potrebna oba: aktiven `map.EntityMapping` **in** vsaj ena aktivna
`map.FieldMapping`. Polovično nastavljena preslikava šteje kot nenastavljena — tako jo
obravnava tudi `INNER JOIN` v `SqlMappingPipeline.ReadInboxesAsync`.

### Zapisi, obtičali v `Pending`

Če se preslikava prekine (timeout, prekinjen proces), zapisi ostanejo `Pending` pod starim
`RunId`. **Naslednji zagon jih ne pobere** — prevzame samo zapise v `Quarantined`. Vrneš jih
v vrsto tako, da jih označiš za karantenske; naslednji zajem z istim payloadom jih nato
pobere pod novim `RunId`:

```sql
UPDATE raw.Inbox
SET Status = N'Quarantined', ProcessedUtc = NULL, FailureReason = N'Rocna vrnitev v vrsto'
WHERE OrganizationId = 2 AND SourceCode = N'SAOP_IQLIGHTING'
  AND EntityType = N'ItemGeneralData' AND Status = N'Pending';
```

Ali pa obdelavo dokončaš neposredno za tisti `RunId`:

```sql
EXEC map.ProcessRawInbox @RunId = '<guid iz raw.Inbox>', @OrganizationId = 2, @SourceCode = N'SAOP_IQLIGHTING';
```

### Zagon, obtičal v `Running`

```sql
SELECT * FROM ops.IntegrationHealth WHERE Pipeline = 'SAOP_PRODUCTS';
SELECT * FROM ops.PipelineRun WHERE Status = 'Running' ORDER BY StartedUtc DESC;
```

Ključavnica je vezana na SQL sejo (`sp_getapplock … @LockOwner='Session'`), zato se sprosti
sama, ko se proces konča. Če vrstica ostane `Running` po koncu procesa, je to samo zapis
stanja in ne blokira naslednjega zagona.

---

## 6. Obremenitev SAOP

Dve nastavitvi v `Saop` določata, kako močno zajem pritisne na ERP:

| Nastavitev | Privzeto | Kaj pomeni |
|---|---|---|
| `PageSize` | 1000 | koliko zapisov zahtevamo v enem klicu; **ne povečuj** — 1000 je vrednost, ki jo prenese iCenter API in jo je uporabljal tudi stari sistem |
| `DelayAfterSuccessMilliseconds` | 0 | premor po vsakem uspešnem odgovoru, preden zahtevamo naslednjo stran; 0 = brez premora |

Pri 200.000 artiklih je to ~200 klicev. Brez premora se zajem zaključi kar najhitreje.
Če bi API šepal pod obremenitvijo, nastavi vrednost na 200–500 ms — cena je zanemarljiva
(50–100 sekund skupaj), korist pa vidna v `ops.PipelineRun` pod daljšo osnovo.

Zajem ima tudi varovalko `MaxPagesPerEndpoint` (privzeto 1000). Pri `PageSize` 1000 to
pomeni zgornjo mejo milijona zapisov na končno točko; zanka se sicer ustavi sama, ko
stran pride prazna ali krajša od zahtevane.

Prehodne napake (408, 429, 502, 503, 504) worker ponovi trikrat z dvakratnim odmikom
(1 s, 2 s, 4 s). Trajna napaka ustavi samo tisto končno točko, ne celotnega zajema, in
mejnik zanjo ostane nepremaknjen — naslednji zagon isto obdobje poskusi znova.

## 7. Kaj je izmerjeno in kaj še ni

**Izmerjeno na tem računalniku (13. 8. 2026):**

- preslikava 5.303 artiklov iz `raw.Inbox` v `canon.Product`: **649 sekund**, izhod 0;
- pri tem: 140 novih artiklov ustvarjenih, EAN 788 → 1.026, `ItemGroup` 0 → 5.269,
  `Department` 0 → 285, `WebPublish` 0 → 184.

**Iz tega je sledilo:** preslikava zmore ~8 artiklov na sekundo. Za 200.000 artiklov je to
okrog 7 ur. `map.ProcessRawInbox` je šla čez zapise s kurzorjem in na vsakem izvedla pet
`MERGE` stavkov.

Ta meritev je bila opravljena **brez omrežja** — podatki so bili že v `raw.Inbox`, tekla je
samo procedura. Zajem in preslikava sta ločena koraka z ločenima omejitvama: zajem omejuje
API (`PageSize`, premor med klici), preslikavo pa SQL.

**To ozko grlo je odpravljeno (21. 8. 2026, migracija `044_BulkProcessRawInbox.sql`.)**
Notranji kurzor po zapisih je zamenjala množična obdelava; vhodne vrstice (`raw.Inbox`) se
še vedno obdelujejo ena za drugo, ker so nosilec izolacije napake in karantene.

Merjeno s `PIM_Solution\tools\Bench-ProcessRawInbox.sql` na istem računalniku, isti podatki
pred in po:

| Zapisov | Pred (proc iz 042) | Po (proc iz 044) | Razmerje |
|---|---|---|---|
| 2.000 | 219.347 ms → **9,1 zapisa/s** | 1.145 ms → **1.747 zapisov/s** | 192× |
| 20.000 | (ni merjeno, ~6 h za 200.000) | 9.306 ms → **2.149 zapisov/s** | — |

Iz tega sledi za 200.000 artiklov okrog **1,5 minute** namesto okrog 6 ur. Merilo poganja
isto pot kot živ zajem (ustvarjanje artikla, besedilo, atribut, kategorija, medij, cena) in
za sabo pobriše vse svoje vrstice.

Zato `--only-ingest` **ni več nujen** zaradi hitrosti. Ostaja uporaben, kadar hočeš najprej
videti surov odgovor, preden ga spustiš v katalog.

**Izmerjeno na živem SAOP 2026-08-21** (prvi živi klic na tem računalniku, 183 artiklov
podjetja 2):

- 168 zapisov je bilo obogatenih, **15 (8,2 %) pa zavrnjenih v celoti** z razlogom
  `Obvezna preslikana vrednost manjka.`;
- v vseh 15 primerih manjka `Product.DiscountGroup` (`SalesData/DiscountGroup1ID`);
  `Product.AccountingGroup` manjka pri 4, `Manufacturer`, `Supplier` in `UoM` pri po enem —
  vsi so podmnožica istih 15 zapisov;
- posledica: nastalo je 148 novih artiklov, EAN 789 → 906, `ItemGroup` 0 → 168,
  `Department` 0 → 162.

To je meritev, ki je migraciji `042` manjkala. Zapis se zavrne **v celoti** — skupaj z
nazivom, EAN in šifro — ker mu manjka skupina popusta. Pri 200.000 artiklih bi to pri
enakem deležu pomenilo okrog 16.000 artiklov, ki jih v PIM sploh ne bi bilo.
Odločitev, ali `DiscountGroup1ID` ostane obvezen, je v `docs\TVOJE_NALOGE.md`.

**Ni še izmerjeno:**

- noben živ klic (na tem računalniku še ni bilo poverilnic);
- kako se obnese `IsRequired` na obstoječih sedmih preslikavah `ItemGeneralData`. Med njimi
  sta `DiscountGroup1ID` in `AccountingBookGroupID`, ki ju nekateri artikli nimajo — tak
  zapis se zavrne v celoti. Koliko jih je, se vidi šele po živem zajemu, v
  `map.UnmappedValue` z razlogom `Obvezna preslikana vrednost manjka.`

---

## 8. Katere končne točke so pokrite

Zajem (v `raw.Inbox`) dela za vseh 16. Preslikava v katalog je nastavljena za tri:

| Končna točka | Zajem | Preslikava v `canon` |
|---|---|---|
| `GetItemsGeneralData` | da | da — 12 polj |
| `GetPrices` | da | da — 6 polj |
| `GetItemsDescriptions` | da | da — 2 polji |
| `Currencies`, `PriceLists`, `Warehouses`, `GetLanguages` | da | ne — šifranti, cilj v modelu še ni določen |
| `Customers`, `GetItemCustomerDataV2`, `CustomerItemGroupDiscounts` | da | ne — B2B domena |
| `GetItemsTitlesLanguage`, `GetItemsCustomProperties`, `GetItemsStockData`, `GetItemsStockAccountingData`, `GetItemsPlanningData`, `TechnologicalProcess` | da | ne |

Za šest končnih točk v zadnji vrstici v posnetih odgovorih ni bilo vsebine, zato njihove
oblike XML ne poznamo. Preslikave zanje se napiše po prvem živem zajemu, ko bo v
`raw.Inbox` viden pravi odgovor:

```sql
SELECT TOP 1 PayloadXml FROM raw.Inbox
WHERE EntityType = 'GetItemsTitlesLanguage' ORDER BY InboxId DESC;
```
