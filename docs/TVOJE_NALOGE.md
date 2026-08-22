# Tvoje naloge — po vrsti, z razlogom in koraki

Zadnja sprememba: 2026-08-21 (po prvem živem zajemu). Stanje sistema: migracija `046`, `scripts\run_tests.ps1`
→ 44 uspeli, 0 padlih, veja `feature/baza-a3-mnozicna-obdelava`.

To je edini seznam stvari, **ki jih ne morem narediti jaz**. Vse ostalo delam sam.
Trije razlogi, zakaj je nekaj tu:

1. **Poslovna odločitev** — odgovor ni v kodi in ga ne smem ugibati.
2. **Zunanji svet** — živ SAOP klic, `git push`, namestitev (`AGENTS.md` §4.5).
3. **Brisanje ali prepis** — vsak `rm`, `DROP`, `DELETE` (`AGENTS.md` §4.1).

Vsaka naloga ima: **zakaj**, **koraki**, **kako veš, da je uspelo**, **kaj naredim jaz potem**.

Vrstni red ni naključen. Naloga 1 odklene največ; naloge 2–4 blokirajo izvoz;
naloge 5–9 so kratke odločitve; 10–12 so stvari, ki jih po pravilih smeš samo ti.

> **Če imaš čas samo za eno stvar: naredi nalogo 1.** Brez nje pet drugih nalog nima
> podlage, ker sistem še nikoli ni videl pravih SAOP podatkov.

---

## Del 1 — Zdaj (odklene največ)

### 1. Poženi prvi živ zajem iz SAOP

**Zakaj.** Na tem računalniku **še ni bilo nobenega živega SAOP klica** — zadnji zagon v
`ops.PipelineRun` je simuliran, iz 4. 8. 2026. Vse, kar je danes v bazi, je iz posnetkov in
fixture datotek. Zaradi tega je pet drugih vprašanj neodgovorljivih: ne vemo, koliko
artiklov nima obveznih polj, katere lastnosti SAOP sploh vrne, ali so EAN-i enolični in
kako se obnese preslikava na 200.000 artiklih namesto na 5.303.

Poverilnice **so že nastavljene** v korenski `appsettings.Local.json` (`BaseUrl`,
`Username`, `Password` so izpolnjeni). Klica ne smem izvesti jaz — `AGENTS.md` §4.5 pravi,
da je živ SAOP klic tvoja odločitev. Zato ga poženeš ti.

**Koraki.**

1. Najmanjša možna stvar — en šifrant, eno podjetje, brez preslikave:

   ```powershell
   cd C:\Users\David\Desktop\PIM\NoviPIM\PIM_Solution
   $env:PIM_SAOP_MODE='Live'
   dotnet run --project workers\PIM.KatalogWorker -- --endpoints Currencies --organizations 2 --only-ingest
   ```

   To dokaže povezavo in geslo, ne da bi karkoli spremenilo v katalogu.

2. Če je uspelo, artikli — še vedno brez preslikave:

   ```powershell
   dotnet run --project workers\PIM.KatalogWorker -- --endpoints GetItemsGeneralData --organizations 2 --only-ingest
   ```

3. Zdaj pa **s preslikavo** (brez `--only-ingest`). Do migracije `044` je bil to sedemurni
   posel in smo ga odsvetovali; zdaj je ~1,5 minute na 200.000 artiklov:

   ```powershell
   dotnet run --project workers\PIM.KatalogWorker -- --endpoints GetItemsGeneralData --organizations 2
   ```

**Kako veš, da je uspelo.** Worker izpiše `strani=… zapisov=… RunId=…`. Nato v SSMS
(baza `PIM`):

```sql
SELECT TOP 5 Pipeline, SourceCode, Status, RowsRead, RowsFailed,
       CONVERT(varchar(19), StartedUtc, 120) AS Zacetek
FROM ops.PipelineRun ORDER BY StartedUtc DESC;

SELECT COUNT(*) AS Artiklov,
       SUM(CASE WHEN EAN IS NOT NULL AND EAN <> '' THEN 1 ELSE 0 END) AS ZEan,
       SUM(CASE WHEN ItemGroup IS NOT NULL THEN 1 ELSE 0 END) AS ZSkupino
FROM canon.Product WHERE OrganizationId = 2;

-- Kaj je bilo zavrnjeno in zakaj:
SELECT TOP 20 Reason, COUNT(*) AS Kolikokrat
FROM map.UnmappedValue GROUP BY Reason ORDER BY Kolikokrat DESC;
```

Uspeh je `Status = Succeeded` in število artiklov, ki je bistveno večje od današnjih 6.141.
Če kaj pade, je razpredelnica simptomov v `docs\ZAJEM-SAOP.md`, razdelek 5.

**IZVEDENO 2026-08-21 — prvi živi klic je uspel.** `GetItemsGeneralData` je vrnil 183
artiklov, od tega jih je 168 obogatenih in 148 novih. EAN 789 → 906, `ItemGroup` 0 → 168.

**Naloga 1 zato še NI zaključena.** Dokazano je najtežje — povezava, geslo in pot podatka od
SAOP do kataloga. Manjkajo trije koraki:

**1. Poln zajem artiklov.** 183 je bila delta, ne katalog. Živo je zajeta ena sama končna
točka od šestnajstih:

```powershell
dotnet run --project workers\PIM.KatalogWorker -- --endpoints GetItemsGeneralData --organizations 2 --full
```

Pri ~200.000 artiklih pričakuj ~200 strani. Zdaj je to smiselno, ker preslikava od migracije
`044` teče ~1,5 minute namesto ~6 ur. Ob tem zajemu se bo vrnilo tudi tistih 15 artiklov, ki
so prej izpadli — od migracije `047` jih zajem ne zavrne več.

**2. Preostali dve preslikani končni točki.** Opisi in cene so v bazi še vedno iz posnetkov
z dne 4. 8., ne iz živega SAOP:

```powershell
dotnet run --project workers\PIM.KatalogWorker -- --endpoints GetItemsDescriptions,GetPrices --organizations 2 --full
```

**3. Ostala tri podjetja.** V `appsettings.Local.json` so Vidadria, Ediito in DEMO
nastavljeni z `"IsActive": false`. Ko bo čas zanje, jim to prestavi na `true`.

**Kako veš, da je naloga zaključena:** `canon.Product` za podjetje 2 ima red velikosti
100.000 artiklov (danes 6.265), `raw.Inbox` pa ima žive strani za `ItemGeneralData`,
`Descriptions` in `Prices` z današnjim datumom.

**Kaj sem jaz naredil po tvojem zagonu.**
- Našel in popravil napako, ki jo je sprožilo moje navodilo: `--only-ingest` je premaknil
  mejnik, čeprav ni ničesar preslikal. 183 artiklov je zato ostalo `Pending` za mejnikom.
  Popravljeno; tvojih 183 artiklov sem rešil z novim `--map-run`. Podrobno v nalogi 1a.
- Izmeril, koliko zapisov izpade zaradi obveznih polj — glej **nalogo 1b**. To je meritev,
  ki je migraciji `042` manjkala.
- Ostaja: preslikave za 6 končnih točk, katerih oblike XML ne poznamo, in preveritev, ali so
  EAN-i enolični (povezano z `out.SaopItemAssignment`).

---

### 1a. Nič ti ni treba narediti — samo da veš, kaj se je zgodilo

Tvoje prvo zaporedje ukazov je razkrilo pravo napako. `--only-ingest` po definiciji ničesar
ne preslika, mejnik pa je vseeno premaknil. Ker si nato isti zajem pognal še enkrat s
preslikavo, je SAOP vrnil enako vsebino, `raw.Inbox` jo je prepoznal po hashu in je ni
vstavil znova — zato preslikava ni imela česa obdelati, mejnik pa je bil že naprej.
Rezultat: 183 artiklov v `raw.Inbox` s statusom `Pending`, za mejnikom, ki jih delta zajem
ne bi več prinesel.

To je isti razred napake, kot ga je 2026-08-20 našel Codex (mejnik gre čez podatek, ki ga ni
mogoče uporabiti), samo z drugim sprožilcem. Zdaj mejnik stoji tudi pri `--only-ingest` in
takrat, ko so bile vse strani podvojene; izpis vedno pove, zakaj stoji.

Tvojih 183 artiklov ni izgubljenih — preslikal sem jih z novim ukazom:

```powershell
dotnet run --project workers\PIM.KatalogWorker -- --map-run <RunId> --organizations 2
```

---

### 1b. ~~Ali `DiscountGroup1ID` res sme ustaviti cel artikel?~~ — **ODGOVORJENO 2026-08-21**

**Zakaj.** Zdaj je prva prava meritev. Od 183 artiklov jih je bilo **15 (8,2 %) zavrnjenih v
celoti** — ne delno, ampak brez naziva, brez EAN, brez šifre. V vseh 15 primerih manjka
`Product.DiscountGroup` (`SalesData/DiscountGroup1ID`).

Pri 200.000 artiklih bi enak delež pomenil okrog **16.000 artiklov, ki jih v PIM sploh ne
bi bilo** — in nikjer ne bi pisalo, da manjkajo, razen kot številka preskočenih.

Migracija `042` je ta polja pustila obvezna z izrecnim zapisom, da je to »verjetno preostro,
a mere še ni«. Zdaj je mera tu.

**Moje priporočilo:** `DiscountGroup1ID` in `AccountingBookGroupID` naj **ne** bosta obvezna.
Artikel brez skupine popusta je nepopoln artikel, ne pa neobstoječ artikel; nepopolnost že
lovi validacija (`ValidationStatus`), ki je za to narejena.

**Tvoj odgovor:** skupina popusta **je obvezno polje**, obveznost pa je v vašem modelu
stvar validacijskega profila s stopnjo resnosti, ne zavrnitve ob zajemu.

**Izvedeno** (migracija `047`): `DiscountGroup1ID` je `ERROR` v profilu `ERP_L1_SLO`, ki
blokira ERP. Artikel obstaja, je viden, je označen kot neveljaven za ERP in se ne promovira.
Pri zajemu ostane obvezna samo šifra artikla. Cel model je v `docs\VALIDACIJA.md`.

---

### 2. Katera SAOP ali NW lastnost pripada kateremu Magento stolpcu?

> **Stanje 2026-08-22 — večina te naloge je opravljena; spodnje besedilo je starejše.**
> Tvoji odgovori v `Magento_stolpci_ZA-POTRDITEV.csv` so zapisani kot vrstice registra v
> migracijah **054** (Nowodvorski, 108 preslikav) in **055** (Braytron, 76). Merjeno v bazi:
> od **160** atributnih stolpcev jih ima vir **156**.
>
> **Kar še čaka tebe, je ožje:** 4 atributni stolpci brez vira, **33 stolpcev sploh brez
> kanonične kode** (zaloge `VID *`, dobavitelj, dokumenti, kategorije svetila, popust,
> valuta, skladišče) in Braytronov `slug=sensor_type`, ki ni Da/Ne in ga 055 nalašč ne
> preslika.
>
> **Pozor — to ni več razlog, da je izvoz prazen.** Izvožena datoteka ima danes vrednost v
> **15 od 213 stolpcev**, ker so `pim.*` otroške tabele skoraj prazne, ne ker bi manjkale
> preslikave. Prava ozka grla so v [`ANALIZA_A_B_C.md`](ANALIZA_A_B_C.md) §6.

**Zakaj.** 162 od 215 stolpcev Magento predloge (stolpci 54–215: `Grlo ANG`, `Barva`,
`Delovna temperatura` …) je v izvozu **praznih**. To ni napaka v kodi — mehanizem je dokazan
s testom: če v `map.FieldMapping` obstaja vrstica s `TargetFieldCode = ProductAttribute.Grlo ANG`,
stolpec `Grlo ANG` se napolni. Danes je edina obstoječa koda atributa v bazi `CategoryRequired`
(dve vrstici), zato se ne ujema noben od 162 stolpcev.

Manjka torej **podatek, ne koda**: katera lastnost iz SAOP oziroma iz dobaviteljevega XML
pripada kateremu stolpcu. Tega ne smem ugibati — napačna vrednost v izvozu je slabša od
prazne, ker je ni videti.

Od migracije `045` je tudi izvozna stran vrstica v bazi, zato je odgovor v celoti sprememba
podatkov: nič ni treba prevesti in ponovno namestiti.

**Koraki.**

> Popravek 2026-08-21: prej je tu pisalo »odpri list `Za-izpolniti`«. To je bilo napačno —
> tisti list ima sedem splošnih vprašanj (in nanje si **že odgovoril**), ne pa mesta za
> preslikavo stolpec → vir. Takega lista v delovnem zvezku sploh ni bilo.

1. Odpri `PIM_Solution\docs\Magento_stolpci_ZA-POTRDITEV.csv` (Excel ga odpre neposredno; ločilo je `;`).
   V njem je vseh 162 stolpcev, za vsakega pa **moj predlog vira**, ki sem ga izpeljal iz
   dobaviteljevega XML (`fixtures\nw\products_en_US.xml`), in stopnja zanesljivosti:

   | Zanesljivost | Koliko | Kaj rabim od tebe |
   |---|---|---|
   | `gotovo` | 93 | samo »da« — pripišem brez dodatnega vprašanja |
   | `negotovo` | 11 | povej, ali je predlog pravi |
   | `vprasanje` | 14 | so `SLO` polovice parov ANG/SLO — glej spodaj |
   | `ni vira` | 44 | v NW XML tega atributa ni; povej, od kod pride, ali pa »ne rabimo« |

2. Trije odgovori, ki odklenejo največ (brez njih 14 + 44 stolpcev ostane praznih):

   - **A — od kod pridejo `SLO` vrednosti?** Predloga ima pare `Uporaba ANG` / `Uporaba SLO`.
     Fixture datoteka je samo angleška (`products_en_US.xml`). Ali Nowodvorski ponuja tudi
     slovenski XML (npr. `products_sl_SI.xml`)? Če ga, mi povej naslov — potem sta oba
     stolpca en zajem več in nič ročnega dela. Če ga ne, je edina pot šifrant prevodov
     vrednosti (npr. `Living room` → `Dnevna soba`), ki ga moraš enkrat napolniti ti.
   - **B — 44 stolpcev brez vira** (baterija, senzorika, solar, vrtenje motorja, hrup,
     zatemnljivost, IK stopnja …) v Nowodvorski XML ne obstaja. Ti atributi so videti kot
     drug dobavitelj — Braytron XML jih ima v obliki `<attribute><slug>…</slug><value>…`.
     Povej, ali naj mapiram Braytron, ali pa naj stolpce označim kot namerno prazne.
   - **C — katerih deset stolpcev splet res potrebuje najprej?** Vrstni red dela.

3. Odgovor lahko vpišeš v zadnji stolpec CSV-ja ali mi ga napišeš kar v pogovor v obliki
   `Grlo ANG ← NW attribute_light_source` — oblika ni pomembna, nedvoumnost je.

Dve stvari, ki sem ju našel med pripravo predloga in ju **nisem** popravil sam:

- Stolpca 58 in 122 (`Frekvenca`, naloga 4): stolpci 113–215 so urejeni po abecedi
  angleških imen atributov in tam par `122 Frekvenca` + `123 Enota frekvence` sledi vzorcu
  vrednost+enota. Stolpec 58 tega para nima. Zato je moja domneva, da je **58 podvojitev**,
  a to je še vedno tvoja odločitev.
- Edina obstoječa preslikava atributa danes pelje `attribute_symbol` v kodo
  `CategoryRequired`, ki ne ustreza nobenemu od 215 stolpcev. Videti je, da bi morala peljati
  v stolpec 66 `Simbol atributa`. Potrdi in popravim.

**Kako veš, da je uspelo.** Ko vrstice zapišem, poženeš izvoz in stolpec ni več prazen:

```powershell
dotnet run --project PIM_Solution\workers\PIM.B2bWorker -- --export-magento --organization-id 2 --output-dir C:\temp\magento
```

**Kaj naredim jaz potem.** Vsak odgovor postane vrstica v `map.FieldMapping`, ne veja v kodi.
Nato dokažem s testom, da se vrednost pojavi v pravem stolpcu izvoza.

**Stanje 2026-08-21.** Odgovoril si na 62 vrstic. Iz njih in iz obeh dobaviteljevih XML je
nastal `PIM_Solution\docs\Magento_stolpci_VIRI.csv` — isti stolpci, zdaj z virom pri
Nowodvorskem in pri Braytronu vzporedno: 24 stolpcev ima oba vira, 71 samo Nowodvorskega,
45 samo Braytrona, 22 nobenega (16 od teh so prevodi `SLO`).

Sloj, ki je za to manjkal, je narejen in dokazan (migraciji `049` in `056`, test
`PIM.F5.ValueTransformTests`): `map.FieldTransform` in `map.ValueLookup`. Tvoja prevajalna
tabela je v bazi — 6.316 vrstic v slovenščini, nemščini in hrvaščini.

Preslikave so vpisane (migraciji `054` in `055`): **106 iz Nowodvorskega XML** in **75 iz
Braytronovega**, konektor `BT_XML` obstaja. Dokazano na resničnih podatkih — `NW.203` ima
zdaj `Grlo = E14`, `Simbol atributa = NW.203`, `Svetilka vključuje svetlobni vir = 0`,
`Uporaba SLO = Dnevna soba`.

Ostane eno, kar lahko narediš samo ti: `PIM_Solution\docs\Prevodi_sporni.csv` — 236
angleških besed ima v tvoji preglednici več slovenskih prevodov (`black` → črn / črna /
črne / črni / črno). To ni napaka preglednice, ampak sklanjatev: prevod je odvisen od
lastnosti. Dokler ni odločeno, katera lastnost dobi kateri prevod, te besede v slovarju ni
in vrednost ostane v angleščini. Kar manjka, se sproti zbira v `map.MissingTranslation` —
tam je delovni seznam s števci, koliko izdelkov posamezno vrednost čaka.

---

### 3. Stolpca 24 in 25 — »Kategorije svetila ANG« in »Kategorije svetila SLO«

**Zakaj.** Ta dva stolpca sta danes brez vira. Stolpca 26 in 27 (»Kategorije vid ANG/SLO«)
imata vzor, ki v repozitoriju že obstaja: `B2C` je slovenska pot, `B2C_EN` angleška. Za
»svetila« takega vzora ni nikjer. Ugibanje bi pomenilo, da bi v Magento poslali napačno
drevo kategorij.

**Koraki.** Odgovori na eno vprašanje: **iz katere spletne strani (`WebSite` v
`canon.ProductCategory`) se napolnita ta dva stolpca?** Možnosti so približno tri:

- iz istih `B2C` / `B2C_EN` kot »vid« (potem sta stolpca podvojena in to je v redu),
- iz svojega para spletnih strani, ki ga je treba dodati (povej imeni),
- ostaneta prazna, ker ju Magento ne uporablja (potem ju označim kot namerno prazna).

**Kako veš, da je uspelo.** Stolpca 24 in 25 v izvozu vsebujeta poti, ločene z `|`.

**Kaj naredim jaz potem.** Če je odgovor »svoj par«, dodam vrstici v register in preslikavo;
če je »prazna«, to zapišem v `out.ExportColumn` kot namerno stanje, da ne bo naslednjič spet
izgledalo kot pozabljeno.

---

### 4. Glava »Frekvenca« je v predlogi dvakrat

**Zakaj.** Stolpca 58 in 122 imata isto ime `Frekvenca`. Register (migracija `045`) je zato
obema dodelil isto kanonično kodo `Attr.Frekvenca` — dobila bosta isto vrednost. Doslej je
bilo to skrito v izrazu `"Attr." + glava` in tega ni bilo videti; zdaj sta to dve vidni
vrstici v bazi.

Nisem tega popravil, ker ne vem, kaj je bil namen. Mogoče je podvojitev v predlogi napaka,
mogoče gre za dve različni frekvenci (na primer omrežna in delovna).

**Koraki.** Poglej Magento predlogo pri stolpcih 58 in 122 in povej eno od treh:

- podvojitev je napaka v predlogi → drugega izklopim (`IsActive = 0`),
- gre za dve različni lastnosti → povej, katera je katera,
- naj ostane, kot je (obe isto) → zapišem, da je to namerno.

**Kako veš, da je uspelo.** V izvozu sta stolpca 58 in 122 taka, kot si rekel.

**Stanje 2026-08-21.** Rekel si, da bi morala biti samo ena, in tvoja razlaga se ujema z
dokazi: stolpci 113–215 so urejeni po abecedi angleških imen atributov in tam ima
`122 Frekvenca` takoj za sabo `123 Enota frekvence`. Stolpec 58 svoje enote nima — je
ostanek. V Excelu sta to stolpca **BF** (58) in **DR** (122).

Nisem tega izvedel, ker to ni več en `UPDATE`, kot je prej kazalo. Predloga je zunanja
pogodba s 215 stolpci in ista številka stoji na štirih mestih: `out.ExportColumn`,
`PIM.B2b.MagentoCsvContract`, `MagentoProductSchema` in osem trditev v testih. Če stolpec
odstranim, se vsi za njim premaknejo za eno mesto in predloga ima 214 stolpcev.

**Zaključeno 2026-08-21.** Povedal si, da Magento bere po imenu glave. Stolpec 58 je zato
izklopljen (migracija `050`), predloga ima 214 stolpcev.

Ker je glava ključ, sem ob tem pregledal vse glave in našel še dve enaki imeni:
`Enota bruto teže` (13 in 125) in `Enota neto teže` (15 in 164). Vrednostna stolpca sta se
ločila s pripono `(2)`, enotna pa ne — zato imata zdaj `Enota bruto teže (2)` in
`Enota neto teže (2)`. Devetnajst glav je imelo na koncu presledek (`Enota dolžine `),
ki bi ga bilo treba v Magentu vtipkati, sicer se ime tiho ne bi ujelo; odrezan je
(migraciji `050` in `051`).

Izklopljen je tudi stolpec 55 `Grlo SLO` (migracija `052`) — vrednost grla je koda
(`E14`, `GU10`), ne beseda, zato sta bila stolpca po vsebini ista. Predloga ima 213 stolpcev.

Glave v točnem zapisu, kot bodo v datoteki, so v `PIM_Solution\docs\Magento_glave_ZA_MAGENTO.csv`
— tam je tudi prazen stolpec za Magentov atribut.

---

## Del 2 — Kratke odločitve (nič ni treba pognati)

### 5. Kam v modelu spadajo šifranti in B2B entitete?

**Zakaj.** Zajem dela za vseh 16 SAOP končnih točk, preslikava v katalog pa je nastavljena
za tri. Sedem od preostalih trinajstih nima cilja v podatkovnem modelu:

- šifranti: `Currencies`, `PriceLists`, `Warehouses`, `GetLanguages`
- B2B: `Customers`, `GetItemCustomerDataV2`, `CustomerItemGroupDiscounts`

Ne gre za manjkajočo preslikavo, ampak za manjkajoč cilj: `canon.Product` nima kam dati
seznama valut. Od 2026-08-20 to ni več tiho — zajem teh entitet mejnika ne premakne, zato
podatek ni izgubljen, samo čaka.

**Koraki.** Za vsako od sedmih povej eno od treh:

- **v svojo tabelo** (povej, kaj naj hrani in kdo jo bere — intranet, izvoz, validacija),
- **v obstoječo tabelo** (povej katero; `b2b.Customer` že obstaja in bi bila naravna za
  `Customers`),
- **zaenkrat ne rabimo** — potem preslikave ne pišem in to izrecno zapišem, da naslednjič
  ne izgleda kot pozabljeno.

**Kaj naredim jaz potem.** Za vsako, ki dobi cilj, napišem migracijo s tabelo in vrsticami
registra ter test, ki dokaže, da zajeti podatek pride do cilja.

---

### 6. Smem izbrisati mrtvo kodo `MagentoExportRunner.cs`?

**Zakaj.** `PIM_Solution\workers\PIM.B2bWorker\MagentoExportRunner.cs` je druga, vzporedna
izvedba istega izvoza. `grep` po celotni rešitvi vrne samo njeno definicijo — **nihče je ne
kliče**. Priklopljen je `MagentoExportCommand`. Dve izvedbi istega opravila se prej ali slej
razideta in nekdo popravi napačno.

Brisanje datotek je na zaprtem seznamu `AGENTS.md` §4.1, zato brez tvoje besede ne smem.

**Koraki.** Odgovori z **da** ali **ne**. Če je odgovor »ne vem«, je varna vmesna pot: pustim
datoteko, dodam pa test, ki pade, če jo kdo poskusi uporabiti — takrat se odločiš z več podatki.

**Kaj naredim jaz potem.** Ob »da« jo izbrišem v svojem commitu z jasnim sporočilom, da je
šlo za mrtvo kodo, in poženem cel paket testov, da to dokažem.

---

### 7. Kaj s tremi nedokončanimi workerji?

**Zakaj.** Trije projekti so v repozitoriju v nedoločenem stanju in vsak dan zamegljujejo
sliko, kaj sistem pravzaprav zna:

- `PIM.SaopStockWorker`
- `PIM.FoundationWorker`
- ostanek `PIM.NwXmlWorker` — od njega sta ostali samo mapi `bin\` in `obj\`, projekta v
  `PIM.sln` sploh ni

**Koraki.** Za vsakega povej: **dokončati**, **izbrisati** ali **pustiti pri miru in
označiti kot arhiv**.

**Kaj naredim jaz potem.** »Dokončati« pomeni novo nalogo na tabli z merljivim ciljem;
»izbrisati« naredim v ločenem commitu; »arhiv« zapišem v `STATUS.md`, da ne bo vprašanje
vsak mesec znova.

---

### 8. Kakšen je vhod za `PIM.B2bWorker`?

**Zakaj.** Pisalna logika (`B2bLandingWriter`) obstaja in je dokazana — zna atomarno zapisati
en JSON zapis. Toda worker sam v bazo ne piše ničesar, ker repozitorij ne določa, **od kod
dobi podatke**. Implementacija bi si morala te vrednosti izmisliti, zato je nisem začel.

**Koraki.** Povej štiri stvari:

1. **Vhod** — kje so datoteke, kakšno ime imajo, v kakšni obliki so (primer datoteke je
   najboljši odgovor).
2. **Podjetje in vir** — od kod worker ve, kateri `OrganizationId` in `SourceCode` velja za
   posamezno datoteko: iz imena datoteke, iz mape, iz argumenta?
3. **Ključ zapisa** — katero polje v datoteki je stabilna identiteta stranke
   (`SourceRecordKey`). Mora biti isto pri vsakem uvozu iste stranke.
4. **Podvojitev** — kaj naj se zgodi, če ista stranka pride dvakrat: prepiši, preskoči ali
   javi napako?

**Kaj naredim jaz potem.** Napišem `Program.cs`, test s pravo (anonimizirano) vzorčno
datoteko in dokaz, da zapis pristane v bazi.

---

### 9. Ali gre mapa `Povezave_virov_in_sistemov` v Git?

**Zakaj.** `PIM_Solution\docs\Povezave_virov_in_sistemov\` vsebuje Swagger SAOP (461 poti),
inventar končnih točk in preslikave — vse to je delovni vir, ki bi v Gitu koristil. Vsebuje
pa tudi notranji naslov strežnika SAOP. Ni geslo, je pa notranji podatek, `AGENTS.md` §5.5 pa
pravi »nobene skrivnosti v repozitorij«. Zato mape nisem commital in v nobenem dokumentu
nisem zapisal naslova.

**Koraki.** Izberi eno:

- **v Git kot referenca** — naslov je notranji in ti to ni problem,
- **v Git brez naslova** — iz Swaggerja odstranim `host` in commitam ostalo,
- **ostane lokalno** — dodam vrstico v `.gitignore`, da ne pride noter po pomoti.

**Kaj naredim jaz potem.** Izvedem izbrano in to zapišem v `AGENTS.md`, da vprašanje ne bo
vsakič znova odprto.

---

## Del 3 — Samo ti smeš (`AGENTS.md` §4)

### 10. Preglej in združi vejo

**Zakaj.** Vse delo te seje je na veji `feature/baza-a3-mnozicna-obdelava` v treh commitih.
`git push` in merge v `master` sta na zaprtem seznamu (`AGENTS.md` §4.5 in §4.6).

Kaj je na veji:

| Commit | Kaj |
|---|---|
| `7792b0d` | migracija `044` — preslikava iz kurzorja v množično obdelavo, 9,1 → 1.747 zapisov/s |
| `330be96` | migracija `045` — Magento predloga iz C# v register `out.ExportColumn` |
| `f5d2e2a` | migracija `046` — razred napake, stanje `Superseded`, uskladitev nove šifre |

**Koraki.**

```powershell
cd C:\Users\David\Desktop\PIM\NoviPIM
git log --oneline master..feature/baza-a3-mnozicna-obdelava
git diff master..feature/baza-a3-mnozicna-obdelava --stat
scripts\run_tests.ps1          # mora vrniti 44 uspeli, 0 padlih
```

Šele nato merge in push — z lastnimi rokami.

**Na kaj bodi pozoren pri pregledu.** Dvoje sem naredil, kar bi rad, da vidiš:

- V migraciji `046` sem **spremenil obstoječi test** `PIM.F8.HardeningTests`. Trdil je
  `Equal("Sent", …)`; zdaj trdi `Equal("Superseded", …)` plus ločeno, da ni `Drift`. Namen
  trditve je nespremenjen, spremenilo se je stanje, ki ga migracija uvaja. Pravilo »testa se
  ne spreminja, da bi šel skozi« sem vzel resno — presodi sam, ali se strinjaš.
- Migracijo `044` sem enkrat popravil, potem ko je bila že uporabljena, in pobrisal njeno
  vrstico iz `dbo.SchemaMigration`, da se je uporabila znova. Šlo je za mojo napako iz iste
  seje na datoteki, ki tega računalnika še ni zapustila.

**Kaj naredim jaz potem.** Naslednje delo grem na novo vejo iz posodobljenega `master`.

---

### 11. Kam se Magento CSV pravzaprav dostavi?

**Zakaj.** Izvoz naredi `magento-products.csv` in `magento-customers.csv` v mapo, ki jo
podaš, ter zraven zapiše oznako `magento-export.complete` (dokler te oznake ni, para ni
dovoljeno brati). To je konec poti. **Ni urnika, ni dostave, ni evidence oddanih datotek.**
Kdo datoteki pobere in kako pridejo v Magento, v repozitoriju ni zapisano nikjer.

Namestitev opravila, dostop do FTP in objava na strežnik so na zaprtem seznamu
(`AGENTS.md` §4.5 in §4.7).

**Koraki.** Povej troje:

1. **Kako** — Magento bere iz mape, ali datoteki potiskamo prek FTP/SFTP/HTTP?
2. **Kam** — točna pot ali naslov (poverilnice **ne** v pogovor; gredo v
   `appsettings.Local.json`, ki ni v Gitu).
3. **Kdaj** — kako pogosto. Enkrat na noč? Vsako uro?

**Kaj naredim jaz potem.** Napišem dostavni korak in urnik ter ju dokažem proti lokalnemu
testnemu strežniku na `127.0.0.1`. Pravo dostavo prvič pognaš ti.

---

### 12. Namestitev in varnostna kopija

**Zakaj.** Vse, kar teče danes, teče na tvojem računalniku ročno. Objava na IIS, načrtovana
opravila in dostop do produkcijske baze so na zaprtem seznamu (`AGENTS.md` §4.4, §4.5, §4.7).

**Koraki.** Ko bo čas za namestitev, povej, in pripravim korake; navodila so v
`docs\LAPTOP_INSTALL.md` in `PIM_Solution\deploy\`. Pred prvo migracijo na pravi bazi velja pravilo iz
`docs\DATABASE.md`: `COPY_ONLY` varnostna kopija z `PIM_Solution\deploy\Backup-PIM.sql` in preverjen
`RESTORE VERIFYONLY`.

**Kaj naredim jaz potem.** Pripravim in preizkusim vse lokalno; korake, ki gredo ven, opišem
tako, da jih izvedeš z eno kopijo v ukazno vrstico.

---

## Del 4 — Čaka na nekaj drugega (zdaj ne rabiš ničesar)

| Kaj | Na kaj čaka |
|---|---|
| Ali `DiscountGroup1ID` in `AccountingBookGroupID` res smeta biti obvezna | na nalogo 1 — brez pravih podatkov je odgovor ugibanje |
| Preslikave za 6 končnih točk, katerih oblike XML ne poznamo | na nalogo 1 — v posnetkih ni bilo vsebine |
| Ali je uskladitev po EAN v praksi dvoumna | na nalogo 1 — mehanizem je pripravljen (`out.SaopItemAssignment`), meritve ni |
| Min/max zaloga: pišemo nazaj ali ne | odprta odločitev iz arhitekture; predlog je »ne v prvi iteraciji« |
| Alarmi po e-pošti | naslovniki na vlogo; smiselno šele, ko kaj teče po urniku |

---

## Kaj delam jaz brez tebe

Da veš, česa ti ni treba imeti v glavi. Naslednje po načrtu
(`docs\NACRT_PRILAGODLJIVOSTI.md`):

- **C6** — register SAOP zapisovalnih končnih točk iz Swaggerja (`Add/UpdateItemsGeneralData`,
  `Customers`); danes je pot v kodi, moral bi biti podatek.
- **C8** — `out.OwnershipPolicy` iz stolpcev »Smer« in »Master« tvoje preglednice, vključno s
  pravilom, da polje, ki ga ne beremo nazaj, ne sme biti zapisljivo. Podatki za to **so** v
  `Mapiranje_SAOP_API_PIM.xlsx`, zato od tebe ne rabim ničesar.
- **A1/A2** — `map.SourceEndpoint` kot register končnih točk in preslikave za preostale
  entitete, kolikor jih je mogoče brez naloge 1.
- Pet testnih projektov, ki na računalniku brez baze padejo, namesto da bi se preskočila.
