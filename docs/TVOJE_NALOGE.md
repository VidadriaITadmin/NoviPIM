# Tvoje naloge — po vrsti, z razlogom in koraki

Zadnja sprememba: 2026-08-22 (zaloga dobavitelja v bazi, paket brez baze ne pade več).
Stanje sistema: migracija `063`, `scripts\run_tests.ps1` → 46 uspeli, 0 padlih; brez baze
36 uspeli, 10 preskočenih, 0 padlih. Veja `feature/baza-a3-mnozicna-obdelava`.

To je edini seznam stvari, **ki jih ne morem narediti jaz**. Vse ostalo delam sam.
Trije razlogi, zakaj je nekaj tu:

1. **Poslovna odločitev** — odgovor ni v kodi in ga ne smem ugibati.
2. **Zunanji svet** — živ SAOP klic, `git push`, namestitev (`AGENTS.md` §4.5).
3. **Brisanje ali prepis** — vsak `rm`, `DROP`, `DELETE` (`AGENTS.md` §4.1).

Vsaka naloga ima: **zakaj**, **koraki**, **kako veš, da je uspelo**, **kaj naredim jaz potem**.

> Celotna meritev sistema (zajem, izvoz, odhodna pot) je v
> [`ANALIZA_A_B_C.md`](ANALIZA_A_B_C.md). Njene številke o izvozu (15 od 213 stolpcev) so
> nastale zjutraj 22. 8., **pred** današnjim polnim branjem dobaviteljevega XML; po njem jih
> ima vrednost 152 od 213.

---

## Kaj je odprto zdaj — najkrajši pregled

| # | Kaj čaka tebe | Zakaj ne morem sam |
|---|---|---|
| A | Šifra registriranega pogleda za Vidadrio in prvi živi klic zaloge | živ klic je tvoja odločitev (`AGENTS.md` §4.5) |
| B | Potrditev prevodov — `Prevodi_predlog.csv` (120 predlogov, 96 % pojavitev) | oblika je odvisna od lastnosti; zadnja beseda je tvoja |
| C | Stolpca 26/27 »Kategorije vid« — drevo videlektro | drevesa ni nikjer, tudi v starem sistemu ne |
| D | Ali dobaviteljev XML obogati tudi Vidadrio (in DEMO), ne le IQLighting | katero podjetje prodaja katerega dobavitelja, veš samo ti |
| E | Kam v modelu spadajo šifranti in B2B entitete (naloga 5) | poslovna odločitev |
| F | Vhod za `PIM.B2bWorker` (naloga 8) | ni zapisano nikjer |
| G | Pregled in merge veje (naloga 10) | `git push` in merge sta tvoja |
| H | Kam se Magento CSV dostavi (naloga 11) | zunanji sistem |
| I | Namestitev in varnostna kopija (naloga 12) | produkcija |

Kar sem naredil po tvojih odgovorih 2026-08-22, je spodaj pri vsaki nalogi.

---

## Del 1 — Zaključeno

### 1. Prvi živ zajem iz SAOP — **ZAKLJUČENO 2026-08-21**

Vseh 16 končnih točk, vsa štiri podjetja, **196.516 artiklov** (IQLighting 111.064,
Ediito 39.130, Vidadria 28.897, DEMO 17.425). Podrobno v `TASKBOARD.md`.

Odprto ostaja samo: trgovinski podatki (teže, volumen, mere pakiranja, carinska tarifa) so
od migracije `057` preslikani, a **jih bo prinesel šele naslednji poln zajem** — v katalogu
so še iz starega zajema. Nočno opravilo `NoviPIM - nocni zajem SAOP` poln zajem naredi
prvega v mesecu; če jih hočeš prej, poženi ročno:

```powershell
dotnet run --project PIM_Solution\workers\PIM.KatalogWorker -- --endpoints GetItemsGeneralData --organizations 2 --full
```

### 1a in 1b — **ZAKLJUČENO**, glej zgodovino v `TASKBOARD.md`

### 2. Katera lastnost pripada kateremu Magento stolpcu — **ZAKLJUČENO 2026-08-22**

181 preslikav (106 Nowodvorski, 75 Braytron) in slovar vrednosti s 6.316 vrsticami so
vpisani. **Danes je v izvozu polnih 152 od 213 stolpcev** (pred tem 12).

Kaj je bilo narejeno danes: preslikave so obstajale, dobaviteljev XML pa nikoli ni bil
prebran v celoti — brala se je le 336 KB izrezek (25 izdelkov). Polni datoteki (19 MB in
18 MB) zdaj gresta skozi: **2.548 izdelkov ima lastnosti** namesto 29, `canon.ProductAttribute`
ima 112.820 vrstic namesto 1.064.

**Kar čaka tebe (točka B):** `PIM_Solution\docs\Prevodi_sporni.csv` — 236 angleških besed
ima več slovenskih prevodov (`black` → črn / črna / črne / črni / črno), ker je oblika
odvisna od lastnosti. Dokler ni odločeno, ostane vrednost v angleščini. Delovni seznam s
števci je v bazi:

```sql
SELECT TOP 30 Domain, SourceValue, SeenCount FROM map.MissingTranslation ORDER BY SeenCount DESC;
```

### 3. Stolpca 24 in 25 »Kategorije svetila« — **IZVEDENO 2026-08-22**

Tvoj odgovor: kategorije dobavitelja niso uporabne, zato imate svoje drevo in dobaviteljevo
preslikate vanj; 24/25 je drevo **svetila.si**, 26/27 drevo **videlektro**; drevo je v
starem sistemu.

Kaj sem naredil (migracija `059`): iz baze `PIM_test` (samo branje) sem prenesel drevo
(132 kategorij, 4 ravni), prevode (225 vrstic, sl/en/de/hr) in slovar dobaviteljevih poti
(190 poti). Nastali so `canon.WebSite`, `canon.Category`, `canon.CategoryTranslation`,
`map.CategoryPathMap` in `map.MissingCategoryMap`, pot pa se sestavi v pogledu
`canon.CategoryPathTranslated`.

Rezultat v izvozu: stolpca 24 in 25 sta polna pri **2.113 izdelkih**, na primer
`Cameleon sistem > Rozete` in `Cameleon System > Canopies`. Katera spletna stran gre v
kateri stolpec, je zdaj vrstica v registru, ne stikalo v programu.

**Izvedeno po tvoji potrditvi 2026-08-22:**

- **Enajst poti tračnih sistemov** je vpisanih (migracija `060`). Nowodvorski jih pošilja na
  treh ravneh, stari slovar jih je imel na štirih — vseh enajst gre v nadrejeno kategorijo,
  ki v drevesu že obstaja. `map.MissingCategoryMap` je zdaj prazen, kategorijo pa ima
  **2.540 izdelkov** (prej 2.382) oziroma **2.267 objavljenih** v izvozu.
- **Stare vrstice z dobaviteljevo kategorijo pod `B2C` so pobrisane** (migracija `060`) —
  2.541 vrstic v katalogu in enako v objavi. Stolpec 27 »Kategorije vid SLO« je zato zdaj
  prazen namesto poln angleških besed dobavitelja.
- **Ob tem se je pokazala napaka, ki je vredna svoje vrstice:** izklopljena preslikava je
  še naprej pisala v katalog. `map.ProcessRawInbox` je bral že izluščene vrednosti in ni
  gledal, ali je preslikava, ki jih je naredila, še aktivna — zato so se pobrisane vrstice ob
  prvi ponovni preslikavi vrnile. Popravljeno v migraciji `062`; `IsActive = 0` zdaj res
  pomeni »ta preslikava ne piše več«.

**Kar pri kategorijah še čaka tebe:**

- **Točka C — drevo videlektro.** Stolpca 26/27 sta prazna, ker drevesa videlektro ni
  nikjer — tudi v starem sistemu je `pim.WebSite` zanj izklopljen in brez kategorij.
  Ko drevo obstaja (izvoz iz Magenta ali seznam), ga vpišem po isti poti kot svetila.si.

### 4. Podvojena glava »Frekvenca« — **ZAKLJUČENO 2026-08-21**

Predloga ima 213 aktivnih stolpcev; glave so enolične in brez končnih presledkov.
Točen zapis glav: `PIM_Solution\docs\Magento_glave_ZA_MAGENTO.csv`.

### 6. Mrtva koda `MagentoExportRunner.cs` — **IZVEDENO 2026-08-22**

Tvoj odgovor: pusti in dodaj test. Datoteka ostane; `PIM.F7.MappingTests` zdaj pade, če se
nanjo sklicuje karkoli razen komentarja. Dokaz RED→GREEN: z začasno datoteko, ki jo uporabi,
test pade (`sklicujejo se nanj: ZzzRedProbe.cs`), brez nje uspe.

### 7. Trije nedokončani workerji — **DELNO IZVEDENO 2026-08-22**

Tvoj odgovor: `SaopStockWorker` dokončaj, ostala v arhiv.

- `PIM.FoundationWorker` — **arhiv.** Zapisano v kodi in v `STATUS.md`.
- ostanek `PIM.NwXmlWorker` (samo `bin\`/`obj\`) — **arhiv**, ni v rešitvi in ni v Gitu.
- `PIM.SaopStockWorker` — **naslednja naloga na tabli**, glej spodaj »Kaj delam jaz«.

### 9. Mapa `Povezave_virov_in_sistemov` — **IZVEDENO 2026-08-22**

Tvoj odgovor: v Git kot je. Commitana z Swaggerjem SAOP (461 poti), inventarjem končnih
točk in preslikavo.

---

## Del 2 — Kratke odločitve, ki še čakajo

### 5. Kam v modelu spadajo šifranti in B2B entitete?

**Zakaj.** Zajem dela za vseh 16 SAOP končnih točk, preslikava v katalog za tri (+ trgovinski
podatki od `057`). Sedem od preostalih trinajstih nima cilja v podatkovnem modelu:

- šifranti: `Currencies`, `PriceLists`, `Warehouses`, `GetLanguages`
- B2B: `Customers`, `GetItemCustomerDataV2`, `CustomerItemGroupDiscounts`

Podatek ni izgubljen: zajem teh entitet mejnika ne premakne, zato strani čakajo v
`raw.Inbox` kot `Pending` in jih bo prvi zagon po dodani preslikavi pobral.

**Koraki.** Za vsako od sedmih povej eno od treh: **v svojo tabelo** (kaj naj hrani, kdo jo
bere), **v obstoječo tabelo** (katero; `b2b.Customer` že obstaja), ali **zaenkrat ne rabimo**
(to izrecno zapišem, da naslednjič ne izgleda kot pozabljeno).

### 8. Kakšen je vhod za `PIM.B2bWorker`?

**Zakaj.** `B2bLandingWriter` zna atomarno zapisati zapis, worker pa v bazo ne piše, ker
repozitorij ne določa, od kod dobi podatke.

**Koraki.** Povej štiri stvari: **vhod** (kje so datoteke, kako se imenujejo, primer),
**podjetje in vir** (iz imena, iz mape ali iz argumenta), **ključ zapisa**
(`SourceRecordKey`, stabilen med uvozi) in **podvojitev** (prepiši, preskoči ali javi napako).

---

## Del 3 — Samo ti smeš (`AGENTS.md` §4)

### 10. Preglej in združi vejo

Na veji `feature/baza-a3-mnozicna-obdelava` je delo, ki še ni v `master`. `git push` in merge
sta na zaprtem seznamu (§4.5, §4.6).

```powershell
cd C:\Users\David\Desktop\PIM\NoviPIM
git log --oneline master..feature/baza-a3-mnozicna-obdelava
git diff master..feature/baza-a3-mnozicna-obdelava --stat
scripts\run_tests.ps1          # mora vrniti 46 uspeli, 0 padlih
```

**Na kaj bodi pozoren.** Trije popravki so spremenili obstoječe teste in nobeden ni skrit —
razlogi so v `TASKBOARD.md` pri posamezni nalogi (migracije `046`, `047` in današnji
`PIM.F7.MappingTests`). Nov je tudi ukaz `--znova-preslikaj`, ki strani zajema postavi nazaj
na `Pending`: nič ne briše, preslikava je združevalna, a je to edini ukaz, ki spreminja
stanje že obdelanega zajema.

### 11. Kam se Magento CSV dostavi?

Izvoz naredi `magento-products.csv` in `magento-customers.csv` ter oznako
`magento-export.complete`. Ni urnika, ni dostave, ni evidence oddanih datotek.

Povej troje: **kako** (mapa, FTP/SFTP, HTTP), **kam** (pot ali naslov; poverilnice v
`appsettings.Local.json`, ne v pogovor) in **kdaj** (kako pogosto).

### 12. Namestitev in varnostna kopija

Ko bo čas, povej in pripravim korake; navodila so v `docs\LAPTOP_INSTALL.md` in
`PIM_Solution\deploy\`. Pred prvo migracijo na pravi bazi velja pravilo iz
`docs\DATABASE.md`: `COPY_ONLY` varnostna kopija in preverjen `RESTORE VERIFYONLY`.

---

## Del 4 — Čaka na nekaj drugega

| Kaj | Na kaj čaka |
|---|---|
| Trgovinski podatki v katalogu | na naslednji poln zajem (preslikava obstaja od `057`) |
| Spletni nazivi (stolpca 4 in 5 izvoza) | na preslikavo `GetItemsTitlesLanguage`; 45 strani čaka v `raw.Inbox` |
| Zaloge dobaviteljev v bazi | `PIM.StockFileWorker` prebrano samo izpiše; danes so vse vrstice v `stock.*` iz testnih fixture datotek |
| Min/max zaloga: pišemo nazaj ali ne | odprta odločitev; predlog je »ne v prvi iteraciji« |
| Alarmi po e-pošti | naslovniki na vlogo; smiselno šele, ko kaj teče po urniku |

---

## Kaj delam jaz brez tebe

1. **Preslikave za entitete, ki dobijo cilj** — takoj ko odgovoriš na nalogo 5. Pot je od
   migracije `064` znana: nova vrstica v registru s svojim `TargetDomain` in svoj postopek.
2. **C6** — register SAOP zapisovalnih končnih točk iz Swaggerja.

Zaključeno 2026-08-22: polno branje dobaviteljevega XML, kategorije, zaloga dobavitelja v bazi,
preskok testov brez baze, šifrant skladišč, pot do zaloge iz SAOP in **C8 (lastništvo polj)**.

---

## Točka D — dobaviteljev XML danes obogati samo eno podjetje

**Kaj sem izmeril 2026-08-22.** Konektorja `NW_XML` in `BT_XML` sta registrirana samo za
podjetje 2 (IQLighting), ujemanje pa teče po EAN. Ko sem iste EAN-e primerjal z vsemi štirimi
katalogi, se pokaže tole:

| Dobavitelj | EAN v datoteki | IQLighting (2) | Vidadria (3) | DEMO (1) | Nikjer |
|---|---|---|---|---|---|
| Nowodvorski | 2.619 | 2.543 | **2.571** | 1.145 | 47 |
| Braytron | 3.074 | 291 | **1.086** | 7 | 1.980 |

Vidadria ima torej **več** ujemanj kot IQLighting — pri Braytronu skoraj štirikrat toliko —
lastnosti, kategorij in slik pa ne dobi, ker konektorja zanjo ni.

**Vprašanje.** Ali naj `NW_XML` in `BT_XML` registriram tudi za Vidadrio (in DEMO)? Če ja,
je to samo nekaj vrstic registra: konektor, entitete in kopija preslikav; preslikave same so že
napisane in dokazane. Če ne, zapišem, zakaj — da naslednjič ne izgleda kot pozabljeno.

## Prevodi: delovni list je pripravljen (točka B)

`PIM_Solution\docs\Prevodi_predlog.csv` — 213 vrednosti, ki danes ostanejo v angleščini, z
lastnostjo, številom izdelkov, kandidati iz tvoje preglednice in mojim predlogom. Predlog je pri
120 vrsticah in pokrije **96 % pojavitev**; ostalo je dolg rep z nekaj izdelki.

Zakaj predlog ni bil mogoč prej: oblika je odvisna od lastnosti. `White` je pri barvi `bela`,
pri materialu pa bi bil `bel`. Zdaj, ko je znano, katera lastnost katero vrednost potrebuje
(`map.MissingTranslation`), je predlog mogoč — potrebna je samo tvoja potrditev, enako kot pri
kategorijah.

---

## Zaloga iz SAOP — narejeno po tvojem odgovoru, ostane en korak

Tvoj odgovor 2026-08-22: `GetStocks` za vsa podjetja, `RegisteredViewData` za Vidadrio, ker dela
samo tam; skladišče vodimo s šifro in imenom, v endpoint gre samo šifra.

**Kaj je narejeno.**

- **Šifrant skladišč** (`064`): `canon.Warehouse` s šifro in imenom — DEMO 7, IQLighting 35,
  Vidadria 74, Ediito 15. Podatek je bil že zajet in je čakal v `raw.Inbox`; nov klic ni bil
  potreben. Ob tem je nastala razlika med šifrantom in izdelkom v registru
  (`map.EntityMapping.TargetDomain`), kar je pot tudi za valute, cenike in jezike.
- **Profili** (`065`): `GetStocks` vklopljen za vsa štiri podjetja,
  `SAOP_REGISTERED_VIEW` za Vidadrio vpisan, a **izklopljen**, ker njegove šifre ne poznam.
- **Worker** `PIM.SaopStockWorker` je napisan: profil → šifre skladišč → zahteva → XML →
  `stock.*`. Ob tem se je pokazalo, da je bila stara koda zahteve napačna — pošiljala je `POST`
  z JSON telesom, Swagger SAOP pa pravi `GET` s parametri v naslovu in odgovorom v XML. Klica
  ni nikoli nihče izvedel, zato napake ni bilo videti.
- **Dokaz brez živega SAOP:** `PIM.F6.SaopStockIntegration` — lokalni strežnik vrne odgovor in
  posname zahtevo; preverjeno je, da gre na `GetStocks`, da nosi šifre skladišč (in ne imen),
  da ima glavo `OrganisationId`, da se znan artikel ujame in da neznan ne izgine.

**Kar ostane tebi — dvoje:**

1. **Šifra registriranega pogleda za Vidadrio.** Dobi se s klicem `api/registeredviews`, ki
   pogleda našteje. To je živ klic; če ga poženeš ti ali mi poveš šifro, jo vpišem in profil
   vklopim. Do takrat za Vidadrio velja `GetStocks`, torej podatek ni odvisen od tega koraka.
2. **Prvi živi klic zaloge.** Ko boš pripravljen:

   ```powershell
   $env:PIM_SAOP_MODE = 'Live'
   dotnet run --project PIM_Solution\workers\PIM.SaopStockWorker -- --organizations 2
   ```

   Izpis pove profil, število skladišč, prebranih zapisov, uporabljenih in v karanteni. Če kaj
   pade, pade samo tisto podjetje; ostala tečejo naprej.
