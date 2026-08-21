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
| `--only-ingest` | samo v `raw.Inbox`, brez preslikave v katalog |
| `--help` | izpiše seznam vseh znanih končnih točk |

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
