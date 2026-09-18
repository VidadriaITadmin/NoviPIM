# Nadzor skrbnika

Datum: 2026-09-08. Migracija: **172**. Stanje: izvedeno in preizkušeno na razvojni bazi `PIM`.

Ta dokument opisuje, kje skrbnik vidi, ali sistem dela, kdo je kaj spremenil, kaj gre ven in
kako hitro posamezni deli delujejo — ter kaj od tega še ni pokrito.

---

## 1. Zakaj je to nastalo

Podatki so obstajali že prej, a razsuti po petih tabelah in šestih straneh. Vprašanje »ali PIM
zdaj deluje« je zato zahtevalo odpiranje strani in poznavanje sheme. Tri stvari so manjkale v
celoti:

| Vrzel | Kaj je manjkalo | Kje je zdaj |
|---|---|---|
| Sled uporabnika čez vse | zgodovina je obstajala samo za polja izdelkov; kdo je izklopil urnik ali odobril sporočilo, je bilo v `UpdatedBy`/`ApprovedBy` in nikjer skupaj | `/sistem/sled` |
| Izvozi | `out.ExportProfile` pove, kakšna naj bi datoteka bila, ne pa ali je nastala, koliko vrstic je imela in kako dolgo je trajalo | `/sistem/izvozi` |
| Ali celota dela | vsak kos je imel svoj zeleni test, celota nobenega | `/sistem/samotest` |

---

## 2. Strani

Vse so odprte **samo vlogi `ADMIN`** in vse kažejo čas v naši uri, ne v UTC.

| Pot | Kaj odgovori |
|---|---|
| `/sistem` | **Nadzorna plošča.** Prvi razdelek je seznam stvari, ki potrebujejo pozornost; ko je prazen, to izrecno piše. Nato ploščice, tabela postopkov z vklopom/izklopom in razmikom, nočni samotest s trajanji korakov, artikli po podjetjih in zadnji izvoz po profilu. Osvežuje se sama vsako minuto. |
| `/sistem/sled` | Kdo je kaj spremenil, kdaj (na sekundo) in iz katere vrednosti v katero. Filtri: obdobje in iskanje po uporabniku, ključu ali opisu. Stolpec **Vir** pove, iz katere tabele vrstica prihaja. |
| `/sistem/izvozi` | Zagoni izvozov: profil, podjetje, izid, vrstice, stolpci, velikost, trajanje, sprožilec in SHA-256 datoteke. |
| `/sistem/zmogljivost` | Na postopek: zagoni, uspešnost, povprečno in najdaljše trajanje, razmik iz urnika. Postopek, ki traja dlje od svojega razmika, je označen — takrat se zagoni lovijo sami s seboj. |
| `/sistem/samotest` | Zgodovina nočnih samotestov: izid, koliko korakov je uspelo in koliko časa je zagon potreboval. |

Obstoječe podstrani (`/sistem/urniki`, `/sistem/integracije`, `/sistem/uporabniki`,
`/sistem/vloge`, `/sistem/napake`) so nespremenjene in dosegljive z razdelilnega dela plošče.

### Obvestila

Zvonec v glavi aplikacije je **samo za `ADMIN`**. Prej ga je videl vsakdo, vodil pa je na stran,
ki je odprta samo skrbnikom — opozorilo, ki ga naslovnik ne more odpreti, ni opozorilo.

Števec ni vezan na izbrano podjetje: postopek, ki je padel pri podjetju 3, je enako narobe,
tudi kadar skrbnik gleda podjetje 1. Šteje molčeče postopke, postopke v napaki, odprte
kritične alarme in padel nočni samotest. Ko skrbnik odpre `/sistem`, se odprti alarmi zanj
označijo kot videni (`ops.AlertSeen`); vsak skrbnik ima svoje stanje.

### Ura

Baza hrani UTC, kot vsa baza. Pretvorbo dela izključno intranet, prek `PimTime`:

- pas je izbran **izrecno** (`Pim:TimeZone`, privzeto `Central European Standard Time`), ne
  podedovan od strežnika;
- `DateTime.ToLocalTime()` v intranetu ni več nikjer — vrne čas *strežnika*, kar je na razvojnem
  računalniku slučajno pravilno, na IIS strežniku v UTC pa dve uri narobe, in to se pokaže šele
  po objavi. Prepoved varuje pogodbeni test `PIM.F10.AdminConsoleUxTests`.
- poletni/zimski čas ureja `TimeZoneInfo`; v podnaslovu strani piše veljavna oznaka (`CEST, UTC+2`).

---

## 3. Nočni samotest

**Odgovor na vprašanje »ali je treba imeti E2E test, ki se sproži ponoči«: da, in tu je.**

`PIM_Solution/tests/PIM.SelfTest.Nightly` enkrat na noč prehodi celo verigo in vsakemu koraku
**izmeri čas**. Brez trajanj ni odgovora na »kako hitro deluje« in podvojitev iz treh sekund v
tri minute ostane nevidna, dokler nekaj ne odpove.

| # | Korak | Kaj dokaže |
|---|---|---|
| 1 | `DB` | baza je dosegljiva in migracije so uporabljene |
| 2 | `SCHEMA` | ključne procedure obstajajo |
| 3 | `SCHEDULES` | vsaj en razpored je vklopljen — nič vklopljenih ni mirovanje, ampak sistem, ki se ne bo zagnal sam |
| 4 | `HEARTBEAT` | vsak vklopljen postopek ima svež srčni utrip |
| 5 | `RUNS_24H` | vsak vklopljen postopek je v 24 h vsaj enkrat tekel |
| 6 | `CATALOG` | katalog obstaja in ni čez noč padel za več kot desetino (primerja s prejšnjim zagonom) |
| 7 | `STOCK_FRESHNESS` | zaloga je sveža **po vsakem viru posebej** — zelen postopek ni dokaz svežih podatkov |
| 8 | `QUARANTINE` | koliko vhodnih zapisov čaka v karanteni |
| 9 | `QUALITY` | koliko objavljenih izdelkov ima odprto zahtevo |
| 10 | `WEB_CSV` | **spletni CSV dejansko nastane** prek iste procedure `out.GetExportRows`, ki jo uporablja produkcijski izvoz |
| 11 | `OUTBOX` | odhodna vrsta ni zamašena |
| 12 | `ECHO` | poslane spremembe se ujemajo s tem, kar ERP vrne |
| 13 | `EXPORT_FRESHNESS` | v zadnjih 24 h je bil vsaj en uspešen izvoz |

**Kaj samotest ni.** Ni nadomestek za `scripts\run_tests.ps1`. Tisti dokazuje, da je koda
pravilna; ta dokazuje, da nameščen sistem *trenutno dela*. Ne kliče SAOP-a, ne pošilja ničesar
navzven in ne spreminja podatkov — edini zapis je njegov lastni rezultat, edina datoteka pa
začasni CSV, ki ga na koncu pobriše. Zato se sme izvajati tudi v produkciji.

Iz istega razloga je **izključen iz `scripts\run_tests.ps1`**: pade, kadar delavec molči ali je
SAOP nedosegljiv, kar sta operativni stanji in ne napaki v kodi.

### Zagon

```powershell
# ročno
powershell -File scripts\Nocni-samotest.ps1

# nočno opravilo (požene ČLOVEK, AGENTS.md #4.7)
pwsh -File scripts\Namesti-samotest.ps1
```

Ob 04:30, ne ob 02:30: nočno opravilo se začne ob 02:30 in sme teči do osem ur. Samotest med
njim bi meril sistem sredi dela — polovico uvoženega kataloga in izvoz, ki še ni končan.

Izhodna koda: `0` uspeh ali samo opozorila, `1` vsaj en korak je padel, `2` samotesta ni bilo
mogoče zagnati. Opozorilo ni napaka — nočno opravilo ne sme vsako jutro javljati okvare, ker je
v karanteni pet vrstic.

### Prvi izmerjeni zagon, 2026-09-08

```text
DB                 USPEL             24 ms  184 uporabljenih migracij
SCHEMA             USPEL              4 ms  7 objektov je na mestu
SCHEDULES          USPEL              1 ms  23 od 23 vklopljenih
HEARTBEAT          PADEL              6 ms  Molčijo: ALERT_DISPATCH (org 2), GENERIC_XML (1-4),
                                            SAOP_DELIVERY (1-4), SAOP_STOCK (org 2)
RUNS_24H           PADEL              5 ms  Brez zagona v 24 h: ALERT_DISPATCH, SAOP_DELIVERY (1-4)
CATALOG            USPEL             20 ms  196.559 izdelkov
QUARANTINE         OPOZORILO          1 ms  5 zapisov čaka v karanteni
QUALITY            OPOZORILO      38760 ms  15.034 objavljenih izdelkov ima odprto zahtevo
WEB_CSV            USPEL           1855 ms  2.071 vrstic × 14 stolpcev, 118 kB
OUTBOX             OPOZORILO          1 ms  1 mrtvo sporočilo, 14 čaka odobritve
ECHO               USPEL              0 ms  ni nepojasnjenih odklonov
EXPORT_FRESHNESS   USPEL              1 ms  5 uspešnih izvozov v 24 h
REZULTAT: PADEL — 12 korakov, 40678 ms
```

To ni napaka testa. `ALERT_DISPATCH` ni tekel od 28. 8. — kar pomeni, da se alarmi zbirajo,
razpošiljajo pa se ne. `SAOP_DELIVERY` ni tekel nikoli. Korak `QUALITY` traja 38 sekund, ker
pregleda cel katalog; to trajanje je samo po sebi podatek o tem, kdaj bo katalog prerasel svoje
indekse.

---

## 4. Kaj je v bazi (migracija 172)

| Objekt | Namen |
|---|---|
| `ops.SelfTestRun`, `ops.SelfTestStep` | izid in **trajanje** vsakega koraka nočnega samotesta |
| `out.ExportRun` | ena vrstica na sestavljeno izvozno datoteko: vrstice, stolpci, bajti, SHA-256, trajanje, sprožilec |
| `ops.UserActivity` | dejanja intraneta, ki drugod ne pustijo vrstice |
| `ops.AlertSeen` | kaj je posamezni skrbnik že videl |
| `intranet.GetAdminPulse` | utrip: en klic, sedem naborov (postopki, alarmi, samotest, koraki, katalog, odhodna vrsta, izvozi) |
| `intranet.GetWorkerPerformance` | zagoni, uspešnost in trajanja po postopku |
| `intranet.GetUserActivityTrail` | en kronološki seznam iz šestih virov |
| `intranet.GetExportRuns`, `intranet.GetSelfTestHistory` | zgodovini izvozov in samotestov |

Migracija **ne spremeni nobene obstoječe tabele, procedure ali stolpca**; obstoječe samo bere.

Zakaj en klic za utrip in ne sedem: stran se osvežuje sama vsako minuto. Sedem obiskov baze na
minuto na eno odprto stran je sedem različnih trenutkov — ploščice bi kazale stanje, ki ni
nikoli hkrati obstajalo.

### Kdo polni `out.ExportRun`

| Pot | Kdaj |
|---|---|
| `PIM.B2bWorker --export-profile` | hitri profil iz `Zaloga-cikel.ps1`, vsakih 5 minut |
| `PIM.B2bWorker --export-magento` | par izdelki + stranke iz `Nocno-vse.ps1` |
| `/izvoz/splet-na-zahtevo` | prenos s strani `/splet` — datoteka, ki jo je uporabnik prenesel, je enakovreden dogodek |

Zapis nikoli ne podre izvoza: datoteka je pomembnejša od zapisa o njej, zato so napake pri
zapisovanju požrte in samo izpisane. Zgodovina se polni **od te migracije naprej**; izvozi, ki
so tekli prej, v njej niso.

---

## 5. Kaj to razkrije zdaj (2026-09-08)

Konzola ni pokazala prazne slike. Ob prvem zagonu je našla:

- **`ALERT_DISPATCH` ni tekel od 28. 8.** Alarmi se zbirajo, ne razpošiljajo. Odprtih je več
  kritičnih, med njimi `OutboundDead` s **680 pojavitvami**.
- **`SAOP_STOCK` in `SAOP_PRODUCTS` padata od 3. 9.** za vsa štiri podjetja; zadnja napaka je
  `A connection attempt failed…`, torej dosegljivost, ne podatek.
- **`SAOP_DELIVERY` ima vklopljen razpored, a ni tekel nikoli** — nima niti `NextScheduledUtc`.
- **`SAOP_PRODUCTS` pri podjetju 2 ima najdaljši zagon 31 ur** pri razmiku 1 ure.
- **Izvoz `MAGENTO_STOCK_PRICES` za podjetje 4 vrne 0 vrstic** (251 bajtov, samo glava).

Nič od tega ni novo; novo je, da je vidno na enem zaslonu.

### Zakaj je zaloga videti v redu, čeprav SAOP ne dela

Na zaslonu sta »zaloga« **dve različni stvari**, ki pišeta v isto tabelo `stock.*` in se obe
prikažeta na `/zaloge`:

| Postopek | Od kod | Pot | Stanje 8. 9. |
|---|---|---|---|
| `SOURCE_FETCH` | Braytron prek HTTPS, Nowodvorski prek FTP | javni internet → mapa `PIM_Solution\data\prevzem\…` | V redu |
| `STOCK_FILE` | ta datoteka z diska | samo lokalna datoteka, brez omrežja | V redu |
| `SAOP_STOCK` | naš ERP | **`192.168.178.12:81`** — zasebni naslov, dosegljiv le prek VPN/LAN | Neuspešno od 3. 9. |

Prva dva torej **nikoli ne gresta skozi VPN** in ju izpad povezave do ERP ne zadene. Zelena
lučka pri njiju je resnična, a govori o dobaviteljevi zalogi, ne o naši.

Izmerjeno 8. 9. 2026 ob 20:30:

| Vir | Pozicij | Najnovejši posnetek | Starost |
|---|---:|---|---:|
| Datoteka dobavitelja (podjetja 1–4) | 15.215 | 8. 9. 17:02 | 1 h |
| SAOP (ERP, podjetja 1–4) | 15.019 | **3. 9. 00:42** | **138 h** |

Torej: polovica zaloge, ki gre v `MAGENTO_STOCK_PRICES`, je stara skoraj šest dni. Iz same
plošče postopkov to ni bilo razvidno, zato ima konzola odslej razdelek **Svežina zaloge po
viru**, nočni samotest pa korak `STOCK_FRESHNESS`, ki pade, ko je katerikoli vir starejši od
24 ur. Ob prvem zagonu je pravilno padel s `SAOP (org 1–4): 138 h`.

Datoteke prevzema imajo poleg sebe oznako `.pocakaj` z uro zadnjega prevzema — to je razmik
dobavitelja (`MinIntervalMinutes`: BT 180, NW 120 minut), ne napaka. Naslovi za HTTP in FTP
niso v bazi: `map.SourceFetchLocation.Location` je prazen, ključ `CredentialKey`
(`Fetch:BT_STOCK`, `Fetch:BT_XML`, `Fetch:NW_STOCK`) pa kaže v `appsettings.Local.json`.

### Zakaj `ALERT_DISPATCH` »molči«

Preverjeno v kodi, ne ugotovljeno iz stanja: `PIM.AlertDispatcher` se pri izključeni dostavi
(`PIM_ALERT_DELIVERY_ENABLED` ni `true`) konča z izhodom 0 **preden** odpre zagon
(`OperationsRun.BeginAsync`, `workers/PIM.AlertDispatcher/Program.cs:51`). Stopnjevanje se
izvede, srčni utrip pa ne. Načrtovano opravilo »PIM nadzor« je 8. 9. ob 18:09 teklo z izidom 0 —
skripta torej dela, worker pa namenoma ne poroča.

Posledica je razpored, ki je `IsEnabled = 1` za postopek, ki se po zasnovi nikoli ne oglasi.
Konzola to pravilno pokaže kot »molči«; to ni napaka konzole, ampak nedoslednost sistema.
Odločitev je človekova in ima dve pošteni obliki:

1. **vklopiti dostavo** — `PIM_ALERT_DELIVERY_ENABLED=true` in SMTP oziroma
   `PIM_ALERT_WEBHOOK_URL`; prejemniki so v `ops.AlertRecipientConfig` že nastavljeni
   (ADMIN, e-pošta, `Critical`, podjetja 2–4); ali
2. **izklopiti razpored** `ALERT_DISPATCH` na `/sistem`, dokler dostave ni — takrat postopek
   ni več videti kot pokvarjen.

Namerno **nisem** naredil izjeme za `ALERT_DISPATCH` v samotestu: izjema bi skrila prav tisti
signal, zaradi katerega je bila konzola narejena.

Enako velja za `SAOP_DELIVERY`: razpored je vklopljen za vsa štiri podjetja, `NextScheduledUtc`
je prazen in zagona ni bilo nikoli.

---

## 6. Kaj še ni pokrito

| Vrzel | Zakaj šteje | Predlog |
|---|---|---|
| Obvestilo izven aplikacije | zvonec vidi samo, kdor je prijavljen; ponoči ni nikogar | `ops.AlertRecipientConfig` in `PIM.AlertDispatcher` že obstajata za e-pošto in webhook — manjkata SMTP nastavitev in odločitev, kateri alarmi grejo ven |
| Dostava izvoza | `out.ExportRun` dokazuje, da je datoteka nastala, ne da jo je Magento prevzel | dodati `DeliveredUtc` in potrditev prevzema, ko bo dostava zaprta |
| E2E enega artikla | samotest dokaže, da vsak člen dela; ne dokaže, da isti artikel preide celo verigo | `docs/E2E_EN_ARTIKEL.md` je načrt; potrebuje izolirano testno organizacijo in fixture konektor |
| Zgodovina meritev | trajanja se hranijo, trend pa se ne riše | graf trajanja po korakih na `/sistem/samotest` |
| Živi SAOP write-back | samotest ga namenoma ne izvede | ostaja ročni korak z odobritvijo |
| Pregled po uporabniku | sled se filtrira po iskanju, ne po izbiri uporabnika iz seznama | spustni seznam akterjev na `/sistem/sled` |
| Nočna opravila na strežniku | vsa tri današnja opravila so `InteractiveToken` (»Run only when user is logged on«); na strežniku z IIS, kjer ni prijavljenega uporabnika, se **ne bi zagnala nikoli** in tega ne bi javila — konzola bi to pokazala kot »vse molči« | `docs/NACRT_RAZPOREJEVALNIK.md` (`PIM.Scheduler` kot Windows storitev); do takrat je konzola edini način, da se to sploh opazi |
| Indeks za `canon.Product` | korak `QUALITY` traja 38 s, ker pregleda cel katalog brez indeksa na `(WebPublish, IsActive)`; isti pregled uporablja več strani | filtriran indeks; meriti pred in po, trajanje koraka je merilo |
| Opozorilo ob predolgem zagonu | konzola pokaže, da zagon presega razmik, alarma pa iz tega ne nastane | pravilo v `ops.RunWatchdog`: `MaxDurationMs > IntervalSeconds` je `Warning` |
| Čiščenje zgodovine | `ops.PipelineRun` ima 2.365 vrstic samo za `STOCK_FILE`; raste s petminutnim ciklom | zadrževanje (npr. 90 dni) v isti skripti, ki briše dnevnike |

---

## 7. Preizkušeno

| Kaj | Kako | Izid |
|---|---|---|
| Migracija 172 | `PIM.Migrator` proti razvojni bazi `PIM` | uporabljena; hash datoteke v repozitoriju se ujema z zapisom v `dbo.SchemaMigration` |
| Vse nove procedure | klic proti živi bazi | vračajo pričakovane nabore; `GetAdminPulse` sedem |
| Izris strani | prijava s praviloma ustvarjenim začasnim skrbnikom, nato GET vseh petih poti | vse `200` z resnično vsebino; začasni uporabnik je odstranjen |
| Sled izvoza | `--export-profile MAGENTO_STOCK_PRICES --organization-id 2` | vrstica v `out.ExportRun`: 2.071 vrstic, 14 stolpcev, 119.599 B, 2.321 ms, SHA-256 |
| Nočni samotest | `scripts\Nocni-samotest.ps1` | 12 korakov, 40.678 ms, rezultat v bazi in na `/sistem` |
| Pogodbeni test | `PIM.F10.AdminConsoleUxTests` | PASS |
| Prevod celote | `dotnet build PIM.sln` | 0 opozoril, 0 napak |

Ni bilo izvedeno: živi SAOP klic, dostava v Magento, e-pošta ali webhook, IIS objava.
