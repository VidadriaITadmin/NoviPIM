# TASKBOARD — skupni spomin agentov

Edini vir resnice o tem, kdo kaj dela in kaj je narejeno.
Pravila so v [`AGENTS.md`](AGENTS.md); ta tabla jih ne podvaja.

## Kako se uporablja

- **Pred delom:** preberi to tablo in `STATUS.md`, poženi `git status --short`.
- **Med delom:** premakni nalogo v DELAM, vpiši ime in ozemlje.
- **Po delu:** premakni v KONČANO z **dokazom** — kateri ukaz, kakšen izhod.
- Eno ozemlje = en commit. Ozemlja: BAZA / INTRANET / WORKERJI / DOMENA.

---

> **Kar čaka človeka, ne agenta, je zbrano na enem mestu:
> [`docs/TVOJE_NALOGE.md`](docs/TVOJE_NALOGE.md)** — po vrsti, z razlogom in koraki.
> Vsaka postavka BLOKIRANO spodaj ima tam svojo nalogo.

## TODO (čaka)

> **2026-08-24: uporabnik je odgovoril na vseh devet odprtih vprašanj.** Odgovori in kaj iz njih
> sledi so v [`docs/TVOJE_NALOGE.md`](docs/TVOJE_NALOGE.md). Na kratko, kaj se je s tem spremenilo:
>
> - **Viri:** BT izdelki in BT zaloge imata HTTP(S) povezavo, NW zaloge FTP, NW izdelki ostanejo
>   ročni (dobavitelj ima svojo PIM platformo). Vir dobi **mesto prevzema** v registru; mapa
>   ostane veljavno mesto, ne izjema. Manjkajo še povezave in poverilnice.
> - **Kategorije:** dobaviteljeve se **generirajo same** iz zajema in čakajo na preslikavo;
>   naše drevo se vnaša ročno. Elektromaterial gre pod **videlektro**, ki ga je treba vnesti
>   (predlog: s spletne strani videlektro.com).
> - **Prevodi:** manjkajoče zapolni AI, uporabnik popravlja v vmesniku.
> - **Stranke:** pravila so v `docs/pravila/Magento_Pravila_Cene_Popusti_Postnine 1.docx` —
>   skupina strank je nosilna vez; dokument sam našteje dve vrzeli (neto ceniki po stranki,
>   PE podeduje popuste od plačnika).
> - **Izvozi:** izdelki na uro; stranke, cene in zaloge ločeno, cilj 5 minut.
> - **Odhodna pot:** ERP + komerciala, ADD in PATCH; **validacija je vratar** — veljavno gre
>   samodejno, neveljavno čaka na potrditev človeka.


> Vrstni red spodnjih petih postavk je priporočilo iz meritve 2026-08-22
> ([`docs/ANALIZA_A_B_C.md`](docs/ANALIZA_A_B_C.md)) — od najcenejšega učinka navzdol.

> **Merjeno 2026-08-24 nad bazo (migracija `090`): postavke 1, 2 in 3 spodaj so opravljene.**
> `canon.ProductCommercial` ima **196.513** vrstic (v meritvi 2026-08-22 eno),
> `canon.ProductAttribute` **312.136**, `canon.ProductMedia` **7.645**, `WEB_TITLE` ima
> **31.490** izdelkov v slovenščini, `raw.Inbox` pa **0** vrstic `Pending`. Zaostanek je
> pobral `--preslikaj-zaostanek` 2026-08-23. Vrstic ne brišem, ker je iz njih vidno, kaj je
> bilo ozko grlo; odprti od petih ostajata **4** (vstopnica za objavo) in **5** (outbox).

- **[OPERATIVA / čaka selitev v domeno] Nočno opravilo je ugasnjeno.** Naloga
  `NoviPIM - nocni zajem SAOP` je na zahtevo uporabnika 2026-08-24 v stanju `Disabled`. Kazala
  je na `scripts\Nocni-zajem.ps1`, torej samo na zajem iz SAOP; `Nocno-vse.ps1` ni bila
  registrirana nikoli. Razlog za izklop: SAOP je s tega računalnika dosegljiv le prek
  FortiClient, zato je nočni zagon ob 02:00 padal na časovni iztek. **Ko bo koda v domeni in
  SAOP dosegljiv od tam, se registrira `Nocno-vse.ps1`** s `scripts\Namesti-nocno-opravilo.ps1`
  — po `AGENTS.md` §4.7 sistemska nastavitev in tvoj korak.

- **[WORKERJI] 1. Ponovna preslikava zajetih strani za trgovinske podatke.** Migracija
  **057** je uporabljena in doda 11 preslikav v `canon.ProductCommercial`, tabela pa ima
  **1 vrstico**: zajete strani so že `Processed`, zato jih nova preslikava ne vidi.
  Potreben je `--map-run <RunId>` ali `--full`. Odklene stolpce 10–23 Magento izvoza in
  profile `ERP_L1_EU`, `ERP_L1_THIRD`, `COMMERCIAL_L2`, ki so danes pri **1 veljavnem
  artiklu od 115.685**.
- **[WORKERJI] 2. Preslikava `GetItemsTitlesLanguage`.** 45 strani čaka kot `Pending`.
  To so spletni nazivi — stolpec „Naziv artikla" ima danes izpolnjen **1 izdelek od 1.728**.
  Brez tega spletni izvoz ni uporaben, ne glede na atribute.
- **[WORKERJI] 3. Poln zajem NW in BT XML.** Mehanizem je cel (049 pretvorbe in slovar,
  054/055 preslikave), pognan pa je bil samo za vzorec: BT_XML **ena stran**,
  `canon.ProductAttribute` ima **1.064 vrstic za 27 izdelkov**. To je največji razkorak
  med „narejeno" in „teče" v celotnem sistemu.
- **[BAZA / odločitev] 4. Kateri profil je vstopnica za objavo** in objava za organizaciji
  3 in 4. Danes je vstopnica stari `ERP_L1` → **44.510 VALID**; po `ERP_L1_SLO` bi jih bilo
  **100.809**. Vidadria (3) in Ediito (4) imata **0** objavljenih artiklov. Migracija 058 te
  odločitve nalašč ni sprejela — je poslovna, ne tehnična.
- **[ODHODNA POT / odločitev] Vrstica `OUTBOUND` v `ops.ScheduleProfile` — namerno še ni
  dodana.** Preverjeno 2026-08-22 v `WatchdogRules.Evaluate`: ko za omogočen razpored obstaja
  vrstica v `ops.IntegrationHealth` z `LastHeartbeatUtc` starejšim od `StaleAfterSeconds`,
  nastane **Critical `StaleHeartbeat`**. Dispatcherja ne poganja nič po urniku (Scheduled Task
  je na zaprtem seznamu `AGENTS.md` §4.7), zato bi vklop razporeda po prvem zagonu naredil
  trajen kritičen alarm za pot, ki je nihče ne poganja. Razpored zato sodi v isti korak kot
  odločitev, kaj dispatcherja sploh zaganja — to je tvoja odločitev, ne tehnična.
- **[ODHODNA POT] 5. Proizvajalec sporočil za outbox.** `out.OutboxMessage` ima **0**
  vrstic in nihče vanjo ne piše — ne intranet, ne preslikava, ne razveljavitev. Dokler
  proizvajalca ni, sta dodelava dispatcherja in urnik brezpredmetna. Za tem šele:
  zanka v `PIM.OutboxDispatcher\Program.cs` (danes obdela **eno** sporočilo in konča)
  in vrstica `OUTBOUND` v `ops.ScheduleProfile` (danes je ni).
- **[BAZA] Počistiti rep meritve 2026-08-22:** dva zagona `F5_INTEGRATION` obtičala
  v `ops.PipelineRun` kot `Running` brez
  `EndedUtc`; `dbo.SchemaMigration` vsebuje zapisa `047_ValueDictionaryAndTransforms.sql`
  in `048_ValueDictionaryAndTransforms.sql`, ki kot datoteki ne obstajata (preimenovani
  v 049) — `--verify` kljub temu vrne 0.

- **[BAZA / odločitev] Braytronove kategorije.** Braytronov XML ima družine
  (`main_family`, `sub_family`), a `BT_XML` nima nobene vrstice v `map.CategoryPathMap`.
  `map.ResolveProductCategories` gre čez drevesa iz slovarja za ta vir, zato brez odločitve,
  v katero drevo (`svetila_si`, `videlektro`) Braytronove družine sodijo, sama preslikava ne
  naredi ničesar — niti vrstice v katalogu niti vrstice v delovnem seznamu manjkajočih.
  Migracija `087` je zato namenoma dodala samo slike, ne kategorij.
- **[IZVOZ] Izvoz strank nima česa izvoziti, čeprav so stranke v bazi.** Od `087` ima
  `b2b.Customer` 11.558 vrstic, `out.ExportB2bCustomersCsv` pa vrne prazno datoteko, ker se
  veže na `pim.CustomerWebProfile` (0 vrstic). Katera stranka je v kateri Magento skupini, je
  poslovna odločitev.
- **[WORKERJI]** `PIM.StockFileWorker` dobi pravi `Program.cs`; pri `PIM.B2bWorker`
  manjka **landing pot**, ne cel worker. Popravljeno 2026-08-22: `PIM.B2bWorker\Program.cs`
  obstaja in dela — podpira `--export-magento` in je bil v tej meritvi pognan v živo.
  Kar ne obstaja, je pot za `StockLandingWriter` in `B2bLandingWriter`: pisalna logika je
  dokazana, a jo kliče samo test in worker sam v bazo ne piše ničesar.

- **[BAZA + DOMENA] Datoteke dobavitelja so četrti sklop in edini, ki ga model nima.**
  Uporabnik 2026-08-24: »od dobaviteljev je treba ločiti atribute, kategorijo, medijo in pa
  datoteke — to je nekak standard; potem je pa v mappingu treba povedati, kateri so kateri
  atributi, ker nekateri so podobni, nekateri pa novi.«

  **Model to že dela za tri od štirih.** `map.EntityMapping.EntityType` loči `Attribute`,
  `Classification` (kategorija) in `Media`, `map.FieldMapping` pa za vsakega pove, kateri
  element vira gre v katero kanonično polje — 108 preslikav za Nowodvorskega, 76 za Braytrona.
  To je natanko »v mappingu povemo, kateri je kateri«.

  **Četrtega ni.** Kanonične tabele za dokumente ni, zato tudi trije dokumentni stolpci Magento
  predloge nimajo vira (že zapisano pri blokadi izvoza). Oba dobavitelja jih pošiljata:

  - **Braytron**: `<sections>` z naslovom sklopa (`Specifications`, `3D Files`, `DIALux Files`)
    in v vsakem `<files><file><filename|name><url>` — **11.958** elementov `<file>` v datoteki.
    Vrsta dokumenta je torej naslov sklopa.
  - **Nowodvorski**: blok `<media>` nosi hkrati slike (`image_i`, `image_i_path`,
    `image_i_type`) in datoteke (`file`, `file_path`, `file_type`) — vrsta je v `file_type`.

  *Kaj je treba narediti:* `canon.ProductDocument` (izdelek, vrsta, naslov, URL, jezik),
  entiteta `Document` v registru za oba vira in postopek, ki jo prenese — po isti poti kot
  `Media`. Šele nato imajo dokumentni stolpci izvoza vir.

- **[WORKERJI] Dostava datotek dobavitelja — zdaj s ceno.** `PIM.StockFileWorker` zna zapisati
  zalogo v bazo, datoteko pa mu je treba še vedno položiti v mapo; prevzem s FTP je zunanji klic
  (`AGENTS.md` §4.5) in čaka na odločitev. **Merjeno 2026-08-24, koliko to stane:** obe datoteki
  v `fixtures\` sta z 29. in 30. julija in pokrivata le del ponudbe. V katalogu je **6.651
  artiklov obeh dobaviteljev, ki jih v datotekah ni** (Nowodvorski: 2.619 EAN v datoteki proti
  4.930 samo pri Vidadrii); obratno pa **1.979 Braytronovih EAN iz datoteke ne ustreza nobenemu
  artiklu v nobenem katalogu**. Zgornja meja obogatitve ni v preslikavi, ampak v datoteki.
- **[WORKERJI]** Preslikave za preostale šifrante (`Currencies`, `PriceLists`,
  `GetLanguages`) in B2B entitete. Pot je od migracije `064` znana: nova vrstica v registru s
  svojim `TargetDomain` in svoj postopek, brez posega v postopek za izdelke. Kam v modelu
  spadajo, je še vedno odločitev uporabnika (`docs/TVOJE_NALOGE.md`, naloga 5).

## DELAM (v teku)

- **[INTRANET] Pregledna kartica izdelka s petimi vsebinskimi sklopi** — kdo: Codex —
  ozemlje: INTRANET — začeto 2026-08-28. Prenova obstoječih 11 zavihkov v pet
  nalogovno usmerjenih sklopov, jasen prikaz blokad in odprtih nalog ter manj tehnična
  predstavitev ključnih podatkov; obstoječe bralne in zapisovalne poti ostanejo nespremenjene.

## BLOKIRANO

> **2026-08-26: pet intranetnih vnosov in odločitev o `PIM.F3.Integration` niso več blokirani.**
> Vse je držala ena in ista stvar — polni paket je imel en nepovezan padec
> (`PIM.F3.Integration`, zastarel primer `GetItemsPlanningData`). Commit `b91bc40` je ta test
> uskladil z migracijo 082, zato je polni paket od takrat **51 uspelih / 0 preskočenih /
> 0 padlih**. Zadržano delo je commitano kot `d35e407`; podrobnosti so v razdelku KONČANO.

- **[IZVOZ]** ~~162 atributnih stolpcev Magento predloge nima vira~~ — **preklicano
  2026-08-22, blokada je iz 2026-08-20 in je bila medtem odpravljena.** Odgovor je
  zapisan kot vrstice registra v migracijah **054** (Nowodvorski, 108 preslikav) in
  **055** (Braytron, 76). Merjeno v bazi: od **160** atributnih stolpcev aktivnega
  profila jih ima vir **156**.
  **Kar od te blokade ostane, je ožje in še vedno čaka tvojo odločitev:**
  1. **4 atributni stolpci** brez vira v `map.FieldMapping`.
  2. **31 stolpcev sploh nima kanonične kode** (dva sta dobila vir 2026-08-22:
     `Kategorije svetila ANG/SLO`, migracija `059`) — zanje ni odločeno, od kod pridejo:
     `Dobavitelj`, `ABC klasifikacija`, `Merska enota`, enote teže/volumna/paketa,
     `Popust`, `Valuta`, `Omejitev pri naročanju`,
     `Posebni popust za stranko`, dokumenti (3), zaloge `VID *` (7), dobaviteljeva
     zaloga (3), `Skladišče`.
  3. **`slug=sensor_type` pri Braytronu** ('Motion', 'PIR', 'Microwave') ni Da/Ne in ni
     isto kot stolpec `Senzor gibanja` — migracija 055 ga zato nalašč ne preslika.

- **[WORKERJI / Agent B]** `PIM.B2bWorker` dobi **landing** pot — blokirano
  2026-08-20: `B2bLandingWriter` že zna atomarno zapisati en JSON zapis, toda
  repozitorij ne določa lokalnega execution contracta workerja (vhodne datoteke
  oziroma fixture, argumenti/okoljske nastavitve za `OrganizationId`, `SourceCode`,
  `EntityType` in stabilni `SourceRecordKey`, ter obravnava podvojenega landing
  ključa). `docs/WORKERS.md` ga izrecno označuje kot fixture-only in brez potrjenega
  contracta. Implementacija bi te vrednosti izumila, zato je Agent B ne začne.

## KONČANO

- **[BAZA] Jezik z imena atributa na svoj stolpec — migracija 124 (korak 3a)** —
  kdo: Claude Code — ozemlje: BAZA — končano 2026-08-28.

  `canon.ProductAttribute` ni imel stolpca za jezik, zato je jezik pristal v imenu lastnosti:
  »Prevladujoč material SLO« in »Prevladujoč material ANG« sta bila dva atributa za eno lastnost.

  **Dokaz, merjeno pred in po:**

  | Kaj | Prej | Potem |
  |---|---|---|
  | različnih kod atributov | 164 | **148** |
  | vrstic v `canon.ProductAttribute` | 312.257 | **312.257** |
  | vrstic s pripono `SLO`/`ANG` v imenu | 97.244 | **0** |
  | vrstic z jezikom v stolpcu | 0 | **45.450 sl + 51.794 en** |
  | vrstic v `pim.ProductAttribute` | 251.088 | 251.088 |
  | atributnih vrstic v `canon.FieldValue` | 312.257 | **409.501** |
  | vrstic v `pim.ProductFieldHistory` | 2.267.962 | **2.267.962** |

  **Nobena vrstica ni izgubljena.** Zgodovina se ni povečala, ker sprožilec
  `TR_ProductAttribute_FieldHistory` piše samo ob spremembi *vrednosti*; preimenovanje kode
  vrednosti ne spremeni. `canon.FieldValue` je zrasel za natanko 97.244 — toliko je jezikovnih
  oblik `ProductAttribute.<koda>.<jezik>`, ki so dodane poleg gole kode.

  **Žive reference se niso spremenile.** Edine tri zahteve, ki berejo atribut
  (`ProductAttribute.CategoryRequired`, `ProductAttribute.Garancija` ×2) in edini izvozni
  stolpec (`KEY_CATEGORY_ATTRIBUTES`) nimajo jezikovne pripone. Preverjeno po migraciji:
  `Garancija` 1.725 vrstic, `CategoryRequired` 6.261 — enako kot prej.

  **Enota namenoma ostaja prazna.** Stolpec `Unit` je dodan, a nič ni preneseno: »Enota
  napetosti« pripada »Napetosti«, »Enota dolžine paketa II« pa »Dolžini paketa II«, in ta
  pretvorba v slovenščini ni mehanska. 34 takih kod je v šifrantu označenih z
  `IsUnitCandidate` in čakajo človeka. To je korak 3b.

  **Dve napaki na poti, obe zapisani:**

  1. **Napačen vrstni red.** Prvi poskus je odrezal pripono, preden je razširil enolični ključ,
     in padel z napako 2627 — »X SLO« in »X ANG« imata po odrezu isto kodo pri istem izdelku.
     Migracija se je v celoti povrnila (0 stolpcev dodanih, 0 vrstic spremenjenih, brez zapisa
     v `dbo.SchemaMigration`). Popravljen vrstni red: jezik → širši ključ → odrez.
  2. **`PIM.F2.Integration` je padel z »Poln izdelek ima aktivne napake«.** To ni posledica 124,
     ampak **moje opustitve pri migraciji 105**: dodal sem zahtevo `ProductAttribute.Garancija`
     in nisem dopolnil fixtura. Test sam dokumentira to načelo in je bil tako dopolnjen že pri
     047 in 057. Fixture zdaj vstavi tudi `Garancija`. Napake nisem odkril prej, ker sem po 105
     pognal samo ciljne filtre, ne polnega paketa.

  **Zamenjana sta dva enolična ključa** (`ProductId, AttributeCode` → `+ LanguageCode`, enako v
  `pim`). To je edini DROP v migraciji in ne izgubi nobene vrstice — ključ se v isti transakciji
  ustvari znova, širši. Pred pisanjem preverjeno: po zložitvi ni nobenega podvojenega para, ne v
  `canon` (0 od 312.257) ne v `pim` (0 od 251.088).

  **Dokaz:** migrator prvi in drugi zagon ter `--verify` → izhod 0.
  **`scripts\run_tests.ps1` (polni paket) → 55 uspelih / 0 preskočenih / 0 padlih.**
  `PIM.B2bWorker --export-magento --organization-id 2` → datoteka s 43.508 vrsticami, izhod 0.

  Znana posledica za kartico izdelka: prevedljiva lastnost ima odslej dve vrstici namesto dveh
  različnih imen. `intranet.GetProductCard` odda stolpca `LanguageCode` in `Unit`, da ju stran
  lahko pokaže; prikaz je naloga strani.

- **[BAZA + DOMENA] Atributi dobijo register in šifrant s stalnimi kodami — migracije 121–123** —
  kdo: Claude Code — ozemlje: BAZA + DOMENA — končano 2026-08-28.

  **Merjeno stanje pred posegom.** 164 različnih atributov, 312.257 vrstic. Preslikav 158
  ciljev: **26 skupnih** obema dobaviteljema, 82 samo Nowodvorski, 50 samo Braytron. Dva
  dobavitelja istega blaga si delita šestino atributov — ne ker bi bila različna, ampak ker
  registra ni bilo in si je vsak izmislil svoja imena.

  Tri napake v poimenovanju, vse izmerjene:

  | Vzorec | Kod | Vrstic |
  |---|---|---|
  | jezik v imenu (`… SLO` / `… ANG`) | 33 za 17 lastnosti | 97.244 |
  | enota kot svoj atribut (`Enota …`) | 34 | 58.002 |
  | zaporedna številka (`… I/II/III`, `… (2)`) | 23 | — |

  **155.246 od 312.257 vrstic — polovica vseh podatkov o atributih — obstaja samo zato, ker sta
  jezik in enota zapisana v ime.** Braytronova »Neto teža (2)« je trenutek, ko je nekdo videl,
  da ime že obstaja, in dodal drugo.

  **121 — register izvornih atributov.** `map.SourceAttribute` + `map.SourceAttributeDiscovery`
  + `map.RegisterSourceAttributes`. Zajem odslej prebere **vse** atribute strani, tudi tiste brez
  preslikave. Odkrivanje je vrstica registra in ne pogoj v programu, ker oba dobavitelja nosita
  atribute drugače: Nowodvorski en element na atribut (ime = ime elementa, otroci `_name`,
  `_value`, `_unit`), Braytron eno obliko z razločevalnim `slug`.

  **122 — šifrant s stalnimi kodami.** `canon.AttributeDefinition` (stalna koda, tip, enota,
  prevedljivost), `canon.AttributeTranslation` + zgodovina, `map.AttributeMap` + zgodovina.
  Napolnjeno iz današnjega stanja: **149 definicij** (33 jezikovnih kod se zloži v 17
  prevedljivih), 149 slovenskih imen, **93 preslikav** izpeljanih iz obstoječih pravil.
  Ujemanje je po celi besedi — `type` se ne sme ujeti na `type_of_cable`, sicer bi nepreslikan
  atribut izgledal preslikan.

  **Enote so namenoma prepuščene človeku.** »Enota napetosti« pripada »Napetosti«, »Enota
  dolžine paketa II« pa »Dolžini paketa II«; ta pretvorba v slovenščini ni mehanska in ugibanje
  bi dalo napačne pare, ki bi izgledali pravilni. 34 takih vrstic ima `IsUnitCandidate = 1`.

  **123 — bralna modela** `intranet.GetSourceAttributes` in `intranet.GetAttributeDefinitions`.
  To sta postopka, ki ju pogreša stran `/nastavitve/atributi` s tremi onemogočenimi filtri.

  **Kaj se je takoj pokazalo.** Register je našel **101 izvornih atributov** (BT 66, NW 35 iz ene
  strani; polna datoteka jih ima 64) in **8 brez preslikave** — `main_family`, `sub_family`,
  `ean`, `type` (2.726 izdelkov), `weight` (2.540), `led_quantity`, `sensor_type`,
  `capacity_watt`. Štirje so v uporabnikovem slovarju poimenovani. Sistem tega ne bi javil nikoli.

  **Dokaz:** migrator prvi in drugi zagon ter `--verify` → izhod 0;
  `dotnet build PIM.sln` → 0 napak; `scripts\run_tests.ps1 -Filter F5` → **6 uspelih /
  0 preskočenih / 0 padlih**, vključno z novim `PIM.F5.AttributeDiscoveryTests`, ki teče nad
  pravima datotekama obeh dobaviteljev in najde Braytron 66, Nowodvorski 64 atributov.

  **Popravek napačne razlage.** Ob prvem zagonu je register dobil en atribut namesto šestdesetih.
  Pripisal sem to vgnezdenemu `XPathNodeIterator.Current` in dodal `Clone()`. **To ni bil vzrok** —
  test je zelen tudi brez klona. Prava napaka je bila zastarela knjižnica: worker je tekel z
  `--no-build`, prevedena pa je bila samo `PIM.XmlMapping`. Klon ostaja kot previdnost, komentar
  pa to zdaj pove pošteno.

  **Kar ta paket namenoma NE naredi:** ne dotakne se `canon.ProductAttribute`. Nobena vrednost se
  ne premakne, noben izvoz in nobena validacija ne spremenita vedenja. Zlaganje jezika in enote
  z imena na vrednost je korak 3 z lastnim dokazom pred in po; vmesnik za urejanje je korak 4.

- **[INTRANET] Kakovost: pregled po polju, načrt odblokiranja, profili v svoj zavihek** — kdo: Claude Code
  — ozemlje: INTRANET — končano 2026-08-28.

  Uporabnik je stran razglasil za nepregledno. Razlog je merljiv in ni bil stvar okusa:
  **vseh 340.227 odprtih napak povzroča 16 polj**, stran pa jih je razbijala po profilih.
  Ker isto polje zahteva več profilov, se je `ProductMedia.Url` pojavil v treh razdelkih,
  pod štirimi visokimi karticami in štirimi zaporednimi tabelami.

  1. **Pregled je urejen po polju.** `GetFieldGapsAsync` združi odprte zahteve po `FieldCode`
     in pove, koliko aktivnih izdelkov polje ustavi, katere nivoje blokira, kako je resno in
     kje se popravi. Popravek enega polja zapre isto napako v vseh profilih hkrati.
  2. **Načrt odblokiranja.** `GetUnblockPlanAsync` odgovori na vprašanje, ki ga stran prej ni
     mogla: kaj se dejansko odblokira. Povprečen izdelek ustavi 6,7–8,3 polj hkrati, zato
     posamezen popravek ne naredi nobenega izdelka veljavnega. Račun je zaporeden, z bitno
     masko na izdelek, v enem obhodu baze.
  3. **Odstotek pove, česa je odstotek.** »18,1 %« je delež izdelkov **brez** odprte zahteve;
     zdaj piše »18,1 % pripravljenih« in poleg stoji število izdelkov, ki jih nivo ustavi.
  4. **Profili so dobili svoj zavihek** (`kakovost?pogled=profili`), v eni tabeli z nivojem kot
     stolpcem. Tam se vidi, da `ERP_L1` in `WEB_B2C` (obseg `LEGACY`) nosita 15.686 in 16.269
     neveljavnih izdelkov, a ne blokirata ne ERP ne spleta — čisti šum.
  5. **Imena polj se ne prevajajo iz slovarja.** `QualityFieldPolicy` prevede samo predpono
     entitete; ime polja ostane iz registra. Izmišljen slovar bi se z registrom razšel.

  **Dokaz — merjeno nad razvojno bazo `PIM`, prek pravih metod storitve:**

  ```
  org 1:  17.414 od 17.414 aktivnih ima odprto zahtevo, povprečno 7,8 polj, 18 polj — 341 ms
  org 2:  98.245 od 98.260, povprečno 8,3 polj, 26 polj                              — 1.345 ms
  org 3:  22.813 od 22.828, povprečno 6,8 polj, 18 polj                              —  269 ms
  org 4:  39.132 od 39.132, povprečno 6,7 polj, 18 polj                              —  391 ms

  načrt org 1:  1.–7. polje → 2,4 %      8. polje (EAN) → 57,2 %      9. → 72,9 %
  načrt org 2:  1.–5. polje → 4,2 %      6. polje (WEB_TITLE.sl) → 38,9 %   8. → 58,0 %
  ```

  ```
  scripts\run_tests.ps1 -Filter F10  → uspeli 13, padli 0, REZULTAT: VSE OK
  ```

  **Kaj sem spremenil v obstoječem testu in zakaj:** dve trditvi v `PIM.F10.QualityUxTests` sta
  preverjali staro postavitev — literal `kakovost/napake?polje=` v strani in zavihek profilov.
  Naslov napak zdaj sestavi `QualityFieldPolicy`, zato trditev preverja politiko. Vse ostale
  trditve tega projekta so ostale nespremenjene in držijo.

  **Česa nisem preveril:** strani nisem videl v brskalniku.

- **[BAZA] Dobavitelj in proizvajalec dobita ime, izvoz gre v enem klicu (115) in enotna
  predloga SAOP (117)** — kdo: Claude Code — ozemlje: BAZA — končano 2026-08-27.

  **Od kod sta dobavitelj in proizvajalec** (uporabnikovo vprašanje): izključno iz SAOP
  dokumenta `ItemGeneralData`, `StockData/SupplierID` in `StockData/ManufacturerID`. To sta
  **šifri partnerja**, ne imeni; registra imen v katalogu ni bilo (`canon.Codebook` ima samo
  CURRENCY, PRICELIST, TECHPROCESS). Imena istih šifer so že zajeta v `b2b.Customer` — isti
  šifrant partnerjev iz SAOP. Merjeno: **273 od 275** šifer dobaviteljev in **290 od 292** šifer
  proizvajalcev se ujame. Nov pogled `canon.PartnerName` to poveže; filter in seznam kažeta ime,
  šifra ostane, ker ona potuje nazaj v SAOP.

  **Izvoz ni deloval**, ker je bila meja `@Take` 200: stran je zvezek sestavljala s 100
  zaporednimi klici z vedno večjim OFFSET in brskalnik je zahtevo prekinil prej, kot je datoteka
  nastala (`TaskCanceledException` v dnevniku). Meja je zdaj 20.000 — izvoz je **en klic**,
  merjeno **1,0 s za 20.000 vrstic**.

  **Enotna predloga (117)**: stolpci niso vpisani v kodo, ampak so register `out.SaopXmlField` —
  isti register, ki ga uporablja odhodna vrsta. `intranet.GetSaopTemplateColumns` da stolpce,
  `intranet.GetProductFieldValues` pa vrednosti iz `canon.FieldValue` (merjeno **121.814
  vrednosti za 20.000 izdelkov v 37 ms**).

- **[INTRANET] Seznam: slika, klik na vrstico, imena partnerjev; izvoz z izbiro predloge** —
  kdo: Claude Code — ozemlje: INTRANET — končano 2026-08-27.

  Po uporabnikovih pripombah na zaslonsko sliko:
  - stolpec **Slika** z glavno sliko izdelka (skozi `MediaUrlPolicy`, leno nalaganje);
  - **klik na celo vrstico** odpre kartico, tudi s tipkovnico; klik v kljukico ne;
  - **naziv je navadno besedilo**, ne podčrtana povezava;
  - **stolpec Odpri odstranjen** — cela vrstica že odpira;
  - filtra dobavitelj in proizvajalec kažeta **imena**, filtrirata pa po šifri; ime je tudi v
    vrstici, dodan je stolpec Dobavitelj;
  - **izvoz je izbiren**: pregled ali predloga SAOP, cel pogled ali samo izbrani.

  **Dokaz — zvezka nastala iz prave baze in prebrana nazaj:**

  ```
  pregled:       19 stolpcev, 20.000 vrstic, 1,46 MB,  2,2 s
  predloga SAOP: 25 stolpcev, 20.000 vrstic, 1,90 MB,  3,1 s
  register predloge: 24 stolpcev, 11 obveznih pri novem artiklu, 21 pisljivih nazaj v SAOP
  ```

  ```
  PIM.F10.ProductsUxTests      PASS
  PIM.F10.ProductDetailUxTests PASS
  PIM.F10.AuthTests            PASS
  PIM.F8.BulkOutboundTests     PASS
  migrator --verify            Preverjanje F0–F10 baze je uspešno.
  ```

  **Kar ostaja odprto in ni narejeno:**
  1. **Register ima 24 polj, stari sistem jih je imel 86** (`SaopItemFieldCatalog`). Dokler
     `out.SaopXmlField` ne dobi preostalih, predloga ne pokriva vsega, kar SAOP sprejme.
  2. **Uvoza te predloge nazaj še ni** — datoteka nastane, poti nazaj v PIM in SAOP še ni.
     Obstaja samo `/izvozi/mnozicno` (šifra + eno polje).
  3. **Urejanja glavne slike ni**: `canon.ProductMedia` nima zapisovalne poti.

- **[INTRANET] Drevo kategorij se bere v izbranem jeziku** —
  kdo: Claude Code — ozemlje: INTRANET — končano 2026-08-27.

  Uporabnikova pripomba po prvem pogledu na prenovljeno stran, obe točki upravičeni:

  1. **Izbira jezika ni spremenila drevesa.** Naslov vozlišča je ostal slovenski, ne glede na
     izbrani jezik. Izbira jezika torej ni pomenila ničesar in se je brala kot okvara.
  2. **Vijolični obris na znački izbranega jezika je motil** in ni nosil informacije.

  Zdaj se naslov vozlišča bere v izbranem jeziku. Kjer imena v tem jeziku ni, obvelja slovensko —
  enako, kot to za spletne poti dela `canon.CategoryPathTranslated` — a je **pikčasto podčrtano**,
  da se vidi, da je nadomestek in ne prevod. Tiho slovensko ime sredi tujega drevesa je natanko
  tisto, česar nihče ne opazi. Kadar prevod obstaja, stoji ob njem slovensko ime v drobnem tisku,
  ker se je v tujem drevesu lahko izgubiti. Izbirnik veje bere v istem jeziku kot drevo.

  Značka izbranega jezika ni več obrobljena — poudari jo tanka črta pod besedo.

  **Dokaz:** `dotnet build PIM.Intranet` → **0 opozoril, 0 napak**;
  `PIM.F10.CategoryMappingUxTests` → zelen, s štirimi novimi trditvami, ki to vedenje držijo
  (naslov mora biti `DisplayName(row)`, izbirnik veje prav tako, nadomestek mora biti označen,
  značka ne sme biti obrobljena).

  **Neuspeh, ki ni moj:** polni `-Filter F10` je v tej seji vrnil 12 uspelih in 1 padel —
  `PIM.F10.ProductsUxTests` z `Tabela ima enajst stolpcev; vsak mora imeti ime`. Pade na
  necommitani spremembi `Products.razor`, ki je delo vzporednega agenta; te datoteke se po
  `AGENTS.md` §4.2 nisem dotaknil.

- **[BAZA + INTRANET] Drevo kategorij prenovljeno: vsi jeziki hkrati, zložljive veje, brez kartic — migracija 113** —
  kdo: Claude Code — ozemlje: BAZA + INTRANET — končano 2026-08-27.

  Prva izvedba (110) je bila napačno zastavljena in uporabnik je to takoj videl:

  - **Deset kartic KPI** je zasedlo cel zaslon, preden se je videla prva kategorija.
  - **Drevo se ni bralo kot drevo** — zamik 20 px v tabeli s šestimi stolpci hierarhije ne pokaže.
  - **Prevodi so bili en jezik naenkrat.** Za pet jezikov bi urednik moral petkrat prevesti isto
    vrstico in petkrat menjati filter. Delo pa ne poteka tako: kategorijo prevedeš enkrat, v vse
    jezike, ker jo takrat imaš pred sabo.

  **Kaj je zdaj drugače.**

  Pokritost je **pet vrstic z deležem** namesto desetih kartic, in vsaka vrstica je hkrati filter:
  klik na `de` postavi jezik v ospredje in vklopi »brez imena«. Stran se odpre pri jeziku z največ
  manjkajočimi imeni — tam, kjer je delo.

  Drevo je **`<ul role="tree">`, ne tabela**: zložljive veje (`−`/`+`), »Razpri vse« in »Zloži na
  prvi nivo«, število otrok ob imenu, zamik 22 px na nivo. Ob iskanju ali filtru se zlaganje samo
  sprosti — sicer bi bil zadetek skrit pod vejo, ki jo je uporabnik zložil prej in nanjo ni več
  mislil.

  **Vsi jeziki so vidni v vsaki vrstici** kot pet značk: zapolnjena = ime obstaja (in je v
  opisu), črtkana = manjka. Klik na ime odpre **urejevalnik z vsemi petimi polji naenkrat**,
  shrani pa se z enim klicem `canon.SaveCategoryTranslations` v eni transakciji. Če en jezik pade
  na pravilu, **ne obvelja noben** — delno shranjen prevod izgleda opravljen in ga nihče ne
  pregleda znova. Prazno polje pusti prejšnje ime pri miru; imena se z vpisom nič ne da izbrisati.

  Oblački (`PimStat`, `PimChip`) so s te strani odstranjeni; stanje nosita značka jezika in števec.

  **Dokaz:** `PIM.Migrator` prvi in drugi zagon ter `--verify` → izhod 0.
  `dotnet build PIM.Intranet` → **0 opozoril, 0 napak**.
  `scripts\run_tests.ps1 -Filter F10` → **13 uspelih / 0 preskočenih / 0 padlih**.
  Pogodbeni test je bil pred prenovo rdeč (`Servis mora klicati postopek
  intranet.GetCategoryTranslationGaps`) in je po njej zelen — dokaz, da drži obliko strani, ne
  samo prevajanje.

  Preizkušeno v živo: `113001` brez akterja, `113002` neznana kategorija, `113003` neznan jezik.
  **Atomarnost potrjena:** shranjevanje `{en: "A", zz: "B"}` je bilo v celoti zavrnjeno in `en`
  je ostal »Interior lighting«. Krožni preizkus večjezičnega zapisa spremenil in vrnil ime,
  zgodovina ima obe spremembi, končno stanje 391 prevodov — enako kot prej.

- **[INTRANET] Stran medijev: predogledi, vrste kot filtri, dokumenti in videi** — kdo: Claude Code
  — ozemlje: INTRANET — končano 2026-08-27.

  Uporabnik je poslal dve sliki: predogled slike je zrasel čez celo stran, štiri velike
  števčne kartice nad seznamom so bile odveč, videov in dokumentov pa ni bilo nikjer.

  1. **Zakaj je slika zrasla.** Predoglede je sestavljal `RenderTreeBuilder` v `@code`.
     Taki elementi **ne dobijo oznake obsegnega CSS** (`b-…`), zato jih `Media.razor.css`
     ni mogel omejiti in slika je prišla v naravni velikosti. Zdaj so predogledi
     razčlenjevalni izpis; ploščica ima `aspect-ratio: 1` in `object-fit: contain`.
  2. **Dokumentov ni bilo nikjer.** Stran je brala samo `canon.ProductMedia`. Dokumenti so
     v `canon.ProductDocument` — **9.822 zapisov, ki jih uporabnik ni videl**. Oba vira sta
     zdaj `UNION ALL` v enem predalu s stolpcem `Source`.
  3. **Vrsta medija.** Baza je nima — izpelje jo `MediaKindPolicy` iz končnice, gostitelja
     in vloge. SQL izraz nastane iz **istih seznamov** kot razvrstitev v C#, zato se ploščica
     in filter ne moreta raziti.
  4. **Števila niso več okras.** Štiri KPI kartice so odstranjene; vrste so klikljivi filtri
     s svojimi števci, dva opozorilna števca pa sta drobni oznaki v glavi.
  5. **Iskanje.** Vsaka beseda vnosa je svoja zahteva čez šifro, naslov, vlogo in naziv;
     sproži se samo, z zamikom 350 ms. Vzorec `LIKE` nastane v kodi, zato so nadomestni
     znaki iz vnosa ubežani.

  **Dokaz — merjeno nad razvojno bazo `PIM`:**

  ```
  števci po vrsti (isti izraz, kot ga uporabijo čipi):
    org 1: SLIKA=1153  DOKUMENT=1117
    org 2: DOKUMENT=3309  SLIKA=2838  VIDEO=8
    org 3: DOKUMENT=5396  SLIKA=3657  VIDEO=123
    org 4: brez medijev
  razvrstitev C# proti SQL čez vse zapise: 17.601 enakih, 0 različnih, 0 v DRUGO
  video dobi predogled: https://i.ytimg.com/vi/NTXggzRrAWs/hqdefault.jpg
  iskanje »BH85 3D« → BA.BH85.00040 · 3D datoteka · DOKUMENT · …/3dfiles/BH85-XXXX1.rar
  ```

  ```
  dotnet run (tests\PIM.F10.MediaUxTests)  → PIM.F10.MediaUxTests: vse trditve drzijo.
  dotnet build src\PIM.Intranet -warnaserror → Build succeeded. 0 opozoril
  ```

  **Česa nisem preveril:** strani nisem videl v brskalniku. Ob mojem delu je drug agent
  urejal `ProductCard.razor` in `Products.razor` v istem delovnem drevesu in njegove
  necommitane spremembe takrat niso prevajale, zato sem build svojih datotek pognal v
  ločenem `git worktree` na `HEAD`. Celotnega `scripts\run_tests.ps1` iz istega razloga
  nisem pognal.

- **[BAZA] Kartica izdelka postane urejiva — migracija 111** — kdo: Claude Code — ozemlje: BAZA
  — končano 2026-08-27.

  Seznam izdelkov je pisal »urejanje polja je na kartici izdelka«, kartica pa ni imela nobene
  zapisovalne poti. Migracija doda tisto, kar za to manjka, in nič več:

  1. `val.RunValidation` dobi `@ProductId`. Prej je znala samo celo podjetje — nad podjetjem 1
     merjeno 26 s. Po popravku enega polja tega ni mogoče čakati. Filter je dodan na istih petih
     mestih kot `@OrganizationId`; brez `@ProductId` se obnaša natanko kot prej.
  2. `pim.SaveProductTexts` in `pim.SaveProductAttributes` pišeta podatek, ki je last PIM.
     Kar potuje v SAOP, je **zavrnjeno z napako 52402**, ne tiho preskočeno — ločnico določa
     register `out.SaopXmlField`, ne ime polja. Zgodovino zapišejo obstoječi sprožilci, zato
     obe proceduri nastavita `pim.SetChangeContext` (kdo, od kod, zakaj).

  **Dokaz — merjeno nad razvojno bazo:**

  ```
  pim.SaveProductTexts + revalidacija enega izdelka   228 ms   (org-wide validacija je 26 s)
  pim.SaveProductAttributes + revalidacija             63 ms
  zapis WEB_TITLE + DESCRIPTION → zgodovina z avtorjem in razlogom: 4 vrstice
  prazna vrednost izbriše vrstico:                     PoIzbrisu = 0
  TITLE_ERP mimo odhodne vrste:                        zavrnjeno (52402)
  popolnost izdelka 90 % → 100 % po izpolnitvi zahteve
  ```

  ```
  dotnet run --project src\PIM.Migrator            → Uporabljena migracija: 111_ProductCardEditing.sql
  ```

- **[DOMENA] Izvoz je delovni zvezek Excel, ne CSV — PIM.Operations.WorkbookWriter** —
  kdo: Claude Code — ozemlje: DOMENA — končano 2026-08-27.

  Uporabnikova zahteva: »izvoz mora biti v Excelu«. CSV je za Excel dvoumen — ločilo, kodna
  stran in vodilne ničle v šifri artikla so odvisni od nastavitev računalnika, ki datoteko odpre;
  `0000000000001` je postal `1`. Zvezek nosi tip vsake celice s sabo.

  Brez zunanje knjižnice, iz istega razloga kot pri branju (`WorkbookTable`): zvezek je stisnjena
  mapa datotek XML. Zapisovalnik doda krepko glavo, zamrznjeno naslovno vrstico, samodejni filter,
  širine stolpcev ter obliko za datum in odstotek.

  **Dokaz:** kar zapiše, prebere nazaj ista pot, ki bere Excel dobaviteljev.

  ```
  tests\PIM.F8.BulkOutboundTests  → PASS (krožni preizkus zapis → branje, znaki XML v nazivu,
                                          vodilne ničle, da/ne, prazna celica, opomba o odrezanem izvozu)
  ```

- **[INTRANET] Seznam izdelkov: filtri v plošči, izvoz v Excel; kartica: vidni zavihki in
  urejanje polj** — kdo: Claude Code — ozemlje: INTRANET — končano 2026-08-27.

  Trije popravki po uporabnikovih pripombah na zaslonske slike:

  1. **Filtri so bili natrpani, gumbi čudno postavljeni.** Orodna vrstica ima zdaj dve ravni:
     vedno vidno iskanje z gumbom »Filtri (N)« in dejanji desno, ter ploščo z enajstimi filtri,
     ki se odpre na zahtevo. Vsak filter ima vidno oznako, ne samo skrite. Plošča je odprta,
     kadar je kaj aktivnega.
  2. **Izvoz je Excel** (`/izvoz/izdelki.xlsx`); CSV pot ostaja za skripte, ki jo že uporabljajo.
  3. **Kartica**: aktivni zavihek je razpoznaven po podlagi, krepki pisavi in črti — ne samo po
     barvi — vrstica zavihkov pa je lepljiva. Kanalske kartice so izgubile okrasno barvno črto;
     stanje nosi čip. Polja kanala niso več tabela vrednosti, ampak obrazec.

  **Urejanje na kartici** ima dve poti in nobena ne prevzame druge:
  - polje, ki ga PIM piše nazaj v SAOP (20 polj iz registra), gre v odhodno vrsto in čaka odobritev;
  - besedilo in lastnost, ki sta last PIM, gresta naravnost v katalog in **takoj revalidirata**.

  **Manjkajoča polja**, ki jih je uporabnik pogrešal, so dodana: mere in volumen paketa, enota mer,
  ERP nazivi po jezikih (doslej so bili pomotoma med spletnimi besedili), spletna besedila po
  vrstah in jezikih ter lastnosti izdelka. Vsaka **manjkajoča obvezna zahteva je zdaj vnosno
  mesto** — doslej je kartica povedala, da polje manjka, ni pa ga bilo mogoče izpolniti.

  **Dokaz:**

  ```
  scripts\run_tests.ps1 -Filter F10  → uspeli 13, padli 0
  dotnet build PIM_Solution\PIM.sln  → 0 Warning(s), 0 Error(s)
  ```

  Zapisovalna pot preverjena skozi servis proti razvojni bazi, nad izdelkom podjetja 2:
  spletni naziv → popolnost 0 % → 10 %, težav 46 → 43; lastnost → 20 %, težav 41;
  `TITLE_ERP` zavrnjen z 52402; čiščenje vrne izdelek v izhodiščno stanje.

  **Česa nisem preveril:** strani v brskalniku — nimam prijavnih poverilnic za lokalni intranet.

- **[BAZA + INTRANET] Drevo kategorij z zamikom, prevodi v vseh jezikih in uporabni filtri — migracija 110** —
  kdo: Claude Code — ozemlje: BAZA + INTRANET — končano 2026-08-27.

  Stran `/nastavitve/kategorije` ni znala treh stvari, in dve od njiju sta bili napaki, ne vrzeli:

  1. **Ni bila drevo.** Vozlišča so bila ravna tabela z nivojem kot številko; kam kaj sodi, se
     je dalo razbrati samo iz polne poti v drobnem tisku.
  2. **Stolpec »Prevod« je izpisoval pomišljaj za vsako vrstico** — v kodi je bil dobesedno
     zapisan pomišljaj. Prevodi so v bazi obstajali ves čas.
  3. **Stolpec »S podkategorijami« je bil napačen.** Formula je iskala potomce z
     `LIKE pot + '/%'`, ločilo poti pa je `' > '`. Za »Notranja svetila« je zato pokazala
     **1 izdelek namesto 1.579** — in to ne kot prazno polje, ampak kot prepričljivo napačno
     številko.

  **Prevodi.** Jeziki v šifrantu so `sl, en, de, hr, it`, kategorij je 209. Popolno bi bilo
  1.045 prevodov, zapisanih je **391**, torej **manjka 654**:

  | Drevo | de | en | hr | it | sl |
  |---|---|---|---|---|---|
  | `svetila_si` (132) | 121 | 49 | 121 | 132 | 0 |
  | `videlektro` (77) | 77 | 0 | 77 | 77 | 0 |

  Manjkajoč prevod se nikjer ni pokazal kot napaka: `canon.CategoryPathTranslated` namreč vzame
  slovensko ime, kadar prevoda ni — kar je za splet prava odločitev, pomeni pa slovensko besedo
  sredi tuje poti, ki je nihče ne prešteje. Zdaj `intranet.GetCategoryTree` pri vsaki kategoriji
  pove, v katerih jezikih prevoda ni, `canon.SaveCategoryTranslation` pa ga zapiše z akterjem in
  zgodovino v `canon.CategoryTranslationHistory`.

  **Filtri:** drevo, jezik, podjetje (tudi »vsa podjetja«), veja, nivo, iskanje po imenu ali
  poti, samo brez prevoda, samo z izdelki. Ob vsakem filtru se dodajo **predniki zadetkov**,
  označeni kot kontekst — zadetek brez prednikov je iztrgan iz drevesa in bralec ne vidi, kje
  stoji.

  **Zavrne:** `110001` brez akterja, `110002` prazen prevod, `110003` neznana kategorija,
  `110004` neznan jezik. Vse štiri preizkušene.

  **Dokaz:** `PIM.Migrator` prvi in drugi zagon ter `--verify` → izhod 0.
  `dotnet build PIM.Intranet` → **0 opozoril, 0 napak**.
  `scripts\run_tests.ps1 -Filter F10` → **12 uspelih / 0 preskočenih / 0 padlih**.
  Živ preizkus prevoda: `notranja_svetila` `en` spremenjen v »PREIZKUS« in nazaj v
  »Interior lighting«, obe spremembi v zgodovini, končno stanje 391 prevodov — enako kot prej.
  Popravljena formula potomcev preverjena: »Notranja svetila« org 2 → **1.579** namesto 1.

- **[INTRANET] Preslikave kategorij in uvrstitev izdelka sta urejivi v vmesniku** —
  kdo: Claude Code — ozemlje: INTRANET — končano 2026-08-27.

  Zapisovalna pot iz migracije 109 dobi svoja zaslona. `/kakovost/kategorije` ni več samo
  seznam poti brez cilja — vsaka vrstica je urejiva na mestu, z izbirnikom kategorije,
  opombo, ugasnitvijo preslikave in strežniško paginacijo (privzeti filter je
  **Nepreslikano**, ker stran obstaja zaradi tega dela). Nova
  `/izdelki/{ItemId}/kategorije` prestavlja posamezen izdelek po kategorijah, po spletnih
  straneh posebej, in zna uvrstitev vrniti pod vir.

  **Pravila ostajajo v bazi.** Servis `CategoryMappingService` ne presoja ničesar: postopek
  zavrne neobstoječo kategorijo, kategorijo brez prevedene poti, neznano pot in spremembo brez
  akterja, stran pa pokaže tisto sporočilo, ki ga je povedala baza. Test to drži: strani ne
  smejo vsebovati `canon.Category`, `map.CategoryPathMap`, `INSERT` ali `UPDATE`.

  Ročno uvrstitev smeta samo `ADMIN` in `CATALOG_EDITOR`; urejanje preslikav zahteva prijavo.
  Prazen seznam kategorij je na strani izrecno razložen kot **namenoma brez kategorije** in ne
  kot manjkajoč podatek.

  **Dokaz:** `dotnet build PIM.Intranet` → **0 opozoril, 0 napak**.
  `scripts\run_tests.ps1 -Filter F10` → **12 uspelih / 0 preskočenih / 0 padlih**, vključno z
  novim `PIM.F10.CategoryMappingUxTests`. Test je preverjeno občutljiv: ob odstranitvi vloge
  s strani pade z `Rocno uvrstitev izdelka smeta samo ADMIN in CATALOG_EDITOR` (RED), po
  povrnitvi je spet zelen (GREEN). Lokalni zagon na `127.0.0.1:5199`: `/health` in `/prijava`
  vrneta 200, obe novi poti se za neprijavljenega obnašata enako kot obstoječe zaščitene
  strani — preusmeritev na `/prijava`. **Izris prijavljenih strani ni bil preverjen**, ker
  poverilnic lokalnega uporabnika nimam.

  Opomba k zgodovini: vrstico `AddScoped<CategoryMappingService>()` v `Program.cs` je pobral
  vzporedni commit `4a47d22`, zato je v tem commitu ni.

- **[BAZA] Seznam izdelkov bere vsa podjetja, ne samo prvega — migracija 108** —
  kdo: Claude Code — ozemlje: BAZA — končano 2026-08-27.

  `intranet.GetProductList`, `GetProductListViews` in `GetProductListFilters` so imele
  `@OrganizationId` kot **obvezen** parameter, stran pa ga je dobila iz
  `GetCurrentOrganizationAsync` (`TOP (1) … ORDER BY OrganizationId`), torej vedno **DEMO**.
  Vidnih je bilo 17.425 od 196.531 izdelkov; 179.106 izdelkov treh podjetij prek te strani
  ni bilo mogoče videti. Zdaj je `@OrganizationId` neobvezen: `NULL` pomeni vsa podjetja,
  neznana številka pomeni **prazen nabor** (ne tiha razširitev obsega). Vrstica vrne tudi
  `OrganizationId` in `OrganizationName`, ker ista šifra artikla obstaja v več podjetjih
  (`0000000000001` je AVANS v DEMO **in** v Vidadrii).

  Dodani filtri iz stolpcev, ki so že bili v bralnem modelu: `@Department`, `@Activity`
  (ACTIVE/INACTIVE), `@WebPublish` (YES/NO) in `@Completeness` (EMPTY/LOW/MID/FULL);
  `GetProductListFilters` dobi četrti nabor `DEPARTMENT`; razvrstitev dobi `ORGANIZATION`.

  **Dokaz — merjeno nad razvojno bazo PIM po migraciji (196.531 izdelkov, štiri podjetja):**

  | Poizvedba | Čas |
  |---|---|
  | privzeta stran, vsa podjetja | 130 ms |
  | privzeta stran, podjetje 2 (111.068 izdelkov) | 53 ms |
  | stran 201 (`@Skip = 10000`), vsa podjetja | 112 ms |
  | ERP blokirani, vsa podjetja | 293 ms |
  | splet pripravljeni, vsa podjetja | 156 ms |
  | pogled »čaka SAOP«, vsa podjetja | 35 ms |
  | vsi štirje novi filtri hkrati | 126 ms |
  | razvrstitev po podjetju | 49 ms |
  | štetje pogledov, vsa podjetja | 75 ms |
  | vrednosti filtrov, vsa podjetja | 97 ms |

  Nov indeks `IX_CanonProduct_ItemOrg (ItemID, OrganizationId)`: privzeta razvrstitev je po
  šifri artikla, `UQ_CanonProduct_OrganizationItem` pa se začne z organizacijo in je brez
  podjetja v pogoju ne pokrije.

  `TotalCount` preverjen proti `canon.Product` za vsak nov filter — aktivnost 177.637,
  za splet 15.137, oddelek C 135.866, popolnost 100 % 340, podjetje 4 39.137; vsi se ujemajo
  (popolnost 0 % se je med meritvama premaknila za eno vrstico, ker validacija teče sproti).

  ```
  dotnet run --project src\PIM.Migrator            → Uporabljena migracija: 108_ProductListAllOrganizations.sql
  dotnet run --project src\PIM.Migrator -- --verify → Preverjanje F0–F10 baze je uspešno.
  ```

- **[INTRANET] Stran /izdelki pokaže vsa podjetja in dobi filtre po podjetju, oddelku,
  aktivnosti, objavi in popolnosti** — kdo: Claude Code — ozemlje: INTRANET — končano 2026-08-27.

  Stran je privzeto večorganizacijska (kot `/zajem`), tabela dobi stolpec **Podjetje**,
  spustni seznam podjetij pride iz `dbo.OrganizationConfig`. Novi filtri živijo v naslovu
  (`podjetje`, `oddelek`, `aktivnost`, `objava`, `popolnost`), zato je povezavo mogoče deliti.
  Ob zamenjavi podjetja se sprostijo izbrani proizvajalec, dobavitelj, skupina in oddelek —
  vrednosti so lastne podjetju in bi sicer vrnile prazen seznam brez pojasnila.

  Dve posledici, ki nista kozmetični:

  1. **Kartica izdelka** je dobila obseg iz `GetCurrentOrganizationAsync`, zato bi bil izdelek
     tujega podjetja prikazan kot neobstoječ. Zdaj podjetje določi izdelek sam
     (`GetProductOrganizationAsync`).
  2. **Množično urejanje** piše v eno podjetje. Izbira čez več podjetij je onemogočena in
     povedana na glas; izbira iz enega podjetja nese `podjetje=<id>` na `/izvozi/mnozicno`,
     ki ga uporabi namesto privzetega. Brez tega bi šifre enega podjetja pisale v drugo.

  Izvoz `/izvoz/izdelki.csv` sledi istim filtrom in ima prvi stolpec `Podjetje` ter nov
  stolpec `Oddelek`.

  **Dokaz:**

  ```
  scripts\run_tests.ps1 -Filter F10  → uspeli 11, padli 0
  dotnet build PIM_Solution\PIM.sln  → 0 Warning(s), 0 Error(s)
  ```

  Bralna pot preverjena skozi servis proti razvojni bazi (ne samo prek SQL):
  vsa podjetja `TotalCount = 196.531`, po podjetjih 17.425 / 111.068 / 28.901 / 39.137,
  neznano podjetje 999 → 0 vrstic, kartica izdelka podjetja 2 se prebere.

  **Česa nisem preveril:** strani v brskalniku — nimam prijavnih poverilnic za lokalni
  intranet, zato je vizualni pregled `/izdelki` na tebi (`docs/INTRANET.md`, kontrolni seznam).

  **Ni od te naloge:** `scripts\run_tests.ps1` (vse) vrne dva padla projekta —
  `PIM.F2.Integration` pade z `THROW 52202 'Poln izdelek ima aktivne napake.'`, ker
  necommitana migracija **105** doda zahtevo `ProductAttribute.Garancija` (WARNING) v
  `WEB_svetila_si` in `WEB_videlektro`, test pa šteje **vse** aktivne težave, ne samo napak.
  `PIM.F8.Integration` v samostojnem zagonu uspe. Nobeden ne uporablja seznama izdelkov.

- **[BAZA] Preslikave kategorij in uvrstitev izdelka postanejo urejiv podatek — migracija 109** —
  kdo: Claude Code — ozemlje: BAZA — končano 2026-08-27.

  Do te migracije je bilo urejanje kategorij mogoče samo z novo migracijo. Shema `intranet` je
  imela **30 postopkov `Get*` in nobenega `Save*`**. Register `map.SourceCategory` je vestno
  kazal, kaj čaka na preslikavo, rešiti pa tega ni mogel nihče brez SQL-a.

  **Kaj je dodano:**

  - `map.SaveCategoryPathMap` / `map.DeactivateCategoryPathMap` — preslikava »dobaviteljeva pot
    → naša kategorija« je urejiva. Vsaka sprememba gre v `map.CategoryPathMapHistory` z
    akterjem in staro vrednostjo. Ugasnitev **ne briše** vrstice, ker bi izbrisana preslikava
    naslednji zajem spet prijavil kot manjkajočo, kot da odločitve ni bilo.
  - `pim.ProductCategoryOverride` + `pim.SetProductCategories` / `pim.ClearProductCategoryOverride`
    — ročna uvrstitev enega izdelka, z zgodovino v `pim.ProductFieldHistory`
    (`FieldKey = ProductCategory.CategoryPath`, `Owner = PIM`).
  - `map.ResolveProductCategories` dobi eno novo pravilo: **izdelka z ročno uvrstitvijo ponovna
    preslikava ne povozi.** Brez tega bi vsak nočni zajem tiho izbrisal urednikovo delo.
  - Bralni modeli `intranet.GetCategoryMappings`, `intranet.GetCategoryTreeNodes`,
    `intranet.GetProductCategories` — strežniško paginirani, filtri v bazi.

  **Varovalke, ki jih postopek zavrne (vse preizkušene):**

  | Napaka | Kdaj |
  |---|---|
  | `106001` | brez akterja — sprememba brez lastnika |
  | `106003` | ciljna kategorija ne obstaja ali ni aktivna |
  | `106004` | kategorija nima prevedene poti za aktivno spletno stran tega drevesa |
  | `106005` | izdelka s to šifro v tem podjetju ni |
  | `106007` | pot ne obstaja v drevesu te spletne strani |

  `106003` in `106004` sta bistveni: preslikava na neobstoječo kategorijo ali na kategorijo brez
  prevedene poti **se ne javi kot napaka** — tiho izpade v spoju in izgleda, kot da preslikava
  ne dela. To je past, ki je `BT_XML` zadržala mesece.

  **Dokaz:** `PIM.Migrator` prvi zagon → `Uporabljena migracija: 109_...`, drugi zagon je ne
  uporabi znova, `--verify` → `Preverjanje F0–F10 baze je uspešno`, izhod 0.
  `scripts\run_tests.ps1 -Filter F5` → `Build OK`, **5 uspelih / 0 preskočenih / 0 padlih**
  (vključno s `PIM.F5.CategoryMappingTests` in `PIM.F5.Integration`, ki tečeta čez spremenjeni
  `map.ResolveProductCategories`).

  Preizkus celotnega kroga nad živimi podatki (izdelek `BA.BC15.00300`, org 2): prestavitev v
  dve kategoriji → `canon.ProductCategory` posodobljen, stara vrednost v `pim.ProductFieldHistory`
  → **ponovni `map.ResolveProductCategories` ročne uvrstitve ni povozil** → povrnitev v prvotno
  stanje. Po preizkusu: 25 aktivnih preslikav, 180 kategorij, 0 prekrivk — enako kot prej.

  Številka migracije je bila najprej 106; preštevilčena na 109, ker je vzporedno delo medtem
  zasedlo 106–108.

- **[BAZA] Braytronove kategorije, garancija in skladišče za zalogo — migracija 105** —
  kdo: Claude Code — ozemlje: BAZA — končano 2026-08-27.

  Tri odločitve uporabnika iz datotek `brayxtron_kategorije.xlsx` in
  `Kartica artikla - podatki in pravila.xlsx` (27. 8. 2026), zapisane kot podatek.

  **1. Braytronove kategorije.** `map.CategoryPathMap` je imel za `BT_XML` **0 vrstic**, zajem
  pa je prepoznal 78 izvornih kategorij (1.086 izdelkov). Migracija zapiše **25 preslikav**
  (309 izdelkov) — tiste, kjer je uporabnik cilj poimenoval **in** cilj obstaja v drevesu
  `svetila_si`. Namenoma izpuščeno: 26 kategorij (465 izdelkov), ker ciljne kategorije v drevesu
  ni; 7 (148), ker je cilj odvisen od tipa; 15 (126) izključenih z odločitvijo; 5 (38) brez
  vnosa v Excelu. Sijalke (113) niso tu — pravilo je »vedno gledaš GRLO«, torej po atributu.

  **2. Garancija** je dodana v `WEB_svetila_si` in `WEB_videlektro` kot **WARNING, ne ERROR**.
  Izmerjeno: od 2.090 izdelkov org 2, ki so VALID po `WEB_svetila_si`, jih ima garancijo 77.
  Kot ERROR bi zahteva razveljavila 2.013 od 2.090 veljavnih. Prehod na ERROR je en `UPDATE`.

  **3. Skladišče.** `stock.SaopProviderProfile` za org 2 in 3 dobi način `List` in šifro
  `0000001` (obe preverjeni in aktivni v `canon.Warehouse`). Prej `ActiveFromRegister` = zahteva
  čez 35 oziroma 70 skladišč. Org 1 in 4 v uporabnikovem listu nista in ostaneta nespremenjena.

  **Dokaz — merjeno pred in po:**

  | Kaj | Prej | Potem |
  |---|---|---|
  | `map.CategoryPathMap` za `BT_XML` | 0 | 25 |
  | Braytronovi izdelki s kategorijo (org 2) | 0 | 180 |
  | Braytron VALID po `WEB_svetila_si` (org 2) | 0 / 411 | **86 / 411** |
  | Braytron skupni status VALID (org 2) | 0 | **80** |
  | Braytron skupni status VALID (org 3) | 0 | **232** |

  `PIM.Migrator` → `Uporabljena migracija: 105_...`, izhod 0.
  `map.ResolveProductCategories`: org 2 **270 ms**, org 1+3+4 skupaj **684 ms**.
  `val.RunValidation`: org 1 **12,6 s**, org 2 **61,2 s**, org 3 **15,1 s**, org 4 **20,3 s**.

  Migracija sama preveri, da ciljna kategorija obstaja (`THROW 105001`), ker bi preslikava na
  neobstoječo kategorijo tiho izginila v spoju s `canon.Category`.

- **[INTRANET I1] Kartica izdelka, validacijski nivoji, preverbe ter skupna pogleda SAOP in splet** —
  kdo: Codex — ozemlje: INTRANET — končano 2026-08-27.

  Kartica izdelka ima 11 kanalskih/dokaznih zavihkov, dejanske slike, skupno normalizacijo
  medijskih naslovov in poenoten prikaz svežine. Kakovost, napake in pravila uporabljajo isti
  razvrščevalnik `ERP_SLO` · `ERP_EU/THIRD` · `KOMERCIALA` · `SPLET`. Dodani so `/preverbe`,
  ločeni strehi `/saop` in `/splet`, predogledna pogodba izvoza ter razširjene nastavitve za
  atribute, kategorije in povezave izdelkov. Vse manjkajoče bralne odvisnosti so vidne prek
  `PimMissing` in popisane v `docs/porocila-faz/BAZA_ZAHTEVE_INTRANET.md`.

  Dokaz: `scripts\run_tests.ps1 -Filter F10` → **11 uspelih / 0 preskočenih / 0 padlih**;
  `scripts\run_tests.ps1` → **52 uspelih / 0 preskočenih / 0 padlih**, izhod 0 in `Build OK`;
  ločen `dotnet build PIM_Solution\PIM.sln` → **0 opozoril / 0 napak**. Zagonski smoke:
  `/health` in `/prijava` → 200, `/saop`, `/splet`, `/preverbe` in
  `/nastavitve/povezave-izdelkov` → 302 na prijavo. Vseh 61 deklariranih `@page` poti je
  unikatnih.

- **[INTRANET + BAZA] Delovni seznami: izdelki, kakovost, zaloga in pripravljenost izvoza** —
  kdo: Claude Opus 5 (1M) — ozemlji: BAZA, nato INTRANET — 2026-08-26.

  Najprej je bil odblokiran in commitan Codexov paket (`d35e407`): skupni gradniki, modul
  Vhodni podatki, bralne strani in celovita kartica izdelka nad migracijo 100. Blokada je
  padla, ker je `b91bc40` uskladil `PIM.F3.Integration`; polni paket je odtlej zelen.

  Nato štirje moduli po načrtu (`docs/Sprecifikacije_starega_PIMa/Nacrt_Intranet_Aplikacija.md`):

  | Modul | Migracija | Kaj je bilo narobe | Kaj je zdaj |
  |---|---|---|---|
  | Izdelki — seznam | `101` | seznam je pokazal samo šifro, EAN, status in popolnost | osem shranjenih pogledov s števci, filtri, razvrščanje, stanje v URL, ločena statusa ERP/splet, vrzeli po vrstici, CSV izvoz pogleda |
  | Kakovost — napake | `102` | stran je brala **3.004.688** odprtih težav naenkrat in filtrirala v pomnilniku | strežniška stran po izdelku, resnost, obseg blokade, polje; »katera zahteva ustavi največ izdelkov« in razčlenitev po dobavitelju |
  | Zaloga | `103` | stran je naložila vseh **379.610** pozicij naenkrat | strežniška stran, filtri vir/razpoložljivost/ujemanje/svežina, svežina po viru, izpeljane težave z razlogom |
  | Izvozi | `104` | stran je pokazala samo register profilov | koliko izdelkov je objavljenih in koliko ne, katera zahteva jih ustavi, kateri stolpci nimajo vira |

  Meritve pred/po so v glavah migracij; najpomembnejši: filter po pripravljenosti
  2.911 ms → 172 ms, razvrščanje po popolnosti 1.489 ms → 67 ms (dva ozka indeksa),
  seznam napak z odjemalskega filtriranja 3 milijonov vrstic na 181 ms.

  **Predogleda izvozne datoteke namenoma ni.** Obliko Magento izvoza dela `PIM.B2bWorker`;
  druga izvedba iste logike v SQL bi bila druga resnica. Stran to pove na glas.

  **Pogodbeni testi F10 so posodobljeni skupaj s stranmi** (izdelki, kakovost, zaloga; ena
  trditev v `PIM.F10.AuthTests`). Prejšnje pogodbe so zamrznile ozek obseg — pri zalogi in
  kakovosti prav tisti obseg, ki je bil odvisen od okvare. Varovalke so ostale in so ostrejše:
  dostopnost, samo dejanske bralne procedure, brez zapisovalne površine, brez izmišljene
  vsebine in vsak prikazan podatek mora imeti stolpec v bralnem modelu.

  **Dokaz:** `scripts\run_tests.ps1` → **51 uspelih / 0 preskočenih / 0 padlih**, izhod 0
  (pognan po vsakem modulu); `scripts\run_tests.ps1 -Filter F10` → 10/0/0; `-Filter F6` → 6/0/0;
  `dotnet build PIM_Solution\PIM.sln` → 0 opozoril / 0 napak; migrator 1. zagon uporabi
  101–104, 2. zagon nobene, `--verify` → izhod 0; zagon na 127.0.0.1:5199: `/health` 200,
  `/prijava` 200, `/izdelki` in `/izvoz/izdelki.csv` 302 na prijavo.

  **Česa nisem preveril:** izrisa prijavljenih strani. Poverilnic za lokalno prijavo nimam,
  ustvarjanje testnega uporabnika pa je varnostno blokirano. Za to je potreben tvoj klik ali
  razvojna poverilnica.

  **Opozorilo o vzporednem delu:** med to sejo je v istem repozitoriju delala še ena seja
  (`session_017rtCjszqCQ3VK9imCL6Zmf`). Njen commit `8173ff2` je pobral moje takrat pripravljene
  datoteke, zato so spremembe seznama izdelkov v zgodovini pod njegovim sporočilom. Zgodovine
  nisem prepisoval.

- **[MERITEV + NAČRT] En artikel na spletu, več podjetij v bazi — rešitev je v starem sistemu** —
  kdo: Claude Opus 5 — 2026-08-26. Podrobno:
  [`docs/EN_ARTIKEL_VEC_PODJETIJ.md`](docs/EN_ARTIKEL_VEC_PODJETIJ.md).

  Uporabnik je pokazal izvozni SELECT starega sistema. Ta problem resuje s tremi potezami:
  ključ artikla za splet je **`ItemID` in ne `(OrganizationId, ItemID)`**; ob podvojitvi zmaga
  podjetje z nižjo prioriteto iz registra (`#CatalogOrg`, IQL pred VID); zaloga in dobavni roki
  pa pridejo iz **enega izbranega podjetja** (`@StockOrganizationId`), ločeno od kataloga.

  **Predpostavka drži tudi pri nas.** Aktivnih vrstic v `canon.Product` je 177.635, različnih
  šifer pa **116.742**; **52.077** šifer obstaja v več kot enem podjetju (44.918 v dveh, 5.502 v
  treh, 1.657 v štirih). Združevanje po šifri torej stisne 177.635 vrstic na 116.742 artiklov.

  **Ista šifra res pomeni isti artikel v 99,8 %:** EAN se ujema ali ga ni pri **51.978**,
  razlikuje se pri **99**. Teh 99 ni napaka združevanja, ampak delovni seznam.

  **Past, ki jo je stari sistem že poznal:** pri **46.270** šifrah se proizvajalec razlikuje med
  podjetji, ker je shranjen kot šifra, lokalna za podjetje. Stari sistem ima zato register z
  `ManufacturerCodeIQL` in `ManufacturerCodeVID` in iz njiju sestavi eno ime. Brez tega bi po
  združitvi vsak drugi artikel dobil proizvajalca, odvisnega od tega, katero podjetje je zmagalo.
  To je edini del rešitve, ki ga v NoviPIM še ni.

  **Predlog:** trije registri in nobene nove logike v programu — `out.WebCatalogOrganization`
  (vrstni red podjetij), podjetje za zalogo kot lastnost izvoznega profila, ter
  `canon.ManufacturerAlias` / `canon.SupplierAlias`. Ob tem delovni seznam za 99 spornih šifer.

  **Posledica za validacijo:** spletni profil mora preverjati **združeni artikel**, ne zapisa po
  podjetjih, sicer artikel pade zaradi manjkajoče slike v podjetju, ki na splet sploh ne gre.
  ERP validacija ostane po podjetjih, ker ERP je po podjetjih.

  Ničesar nisem zgradil — vrstni red podjetij in podjetje za zalogo sta poslovni odločitvi.


- **[MERITEV] ERP validacijska pravila so napačno sestavljena — trije dokazljivi očitki** —
  kdo: Claude Opus 5 — 2026-08-26. Podrobno:
  [`docs/ANALIZA_ERP_PRAVIL.md`](docs/ANALIZA_ERP_PRAVIL.md).

  Uporabnik 2026-08-26: »povej, kaj je razlika med temi ERP pravili, ker se mi zdi, da je
  napačno sestavljeno.« Je.

  1. **`ERP_L1_EU` in `ERP_L1_THIRD` sta dobesedno ista profila** — oba zahtevata natanko
     `CountryOfOrigin`, `CustomsTariff`, `GrossWeight`, `NetWeight`. Zato imata skupaj s
     `COMMERCIAL_L2` **identično** število veljavnih izdelkov pri vseh štirih podjetjih
     (5.500 / 43.466 / 12.315 / 35.757). Trije profili, tri iste številke: delitev na EU in
     tretje države obstaja v imenu, ne v pravilu.
  2. **`ERP_L1_SLO` nima nič slovenskega** — vseh sedem zahtev je splošnih, stopnje DDV pa
     ne zahteva, čeprav jo `ERP_L1` zahteva. Zahteva pa `Product.IsActive`, kar je zastavica
     in ne podatek: »ne« je prav tako izpolnjena vrednost.
  3. **Vstopnica za objavo je profil, ki po lastni nastavitvi ne blokira.** `val.Promote` ima
     privzeti `@ValidationProfileCode = N'ERP_L1'`; ta ima `Scope = LEGACY` in
     `BlocksErp = 0`, `BlocksWeb = 0`. Ob tem podvaja `SHARED_CORE` (EAN, ItemID).

  **Predlagana oblika** je jedro plus dodatki, kot pravi uporabnik sam (»ERP validacija je level
  ena, ta se deli na SLO in EU/tretje«): `SHARED_CORE` → `ERP_L1` (skupno za vse trge, z DDV) →
  dodatki `SLO` / `EU` / `THIRD`, kjer vsak pove **samo razliko**.

  **Ničesar nisem spremenil.** Preklop vstopnice iz `ERP_L1` v `ERP_L1_SLO` objavi 67.000
  izdelkov več (89.129 → 156.131); to je poslovna odločitev in ne sme nastati kot stranski
  učinek čiščenja. Tri vprašanja, ki to odklenejo, so na koncu analize.


- **[BAZA] Stranke: profil za splet in delovni seznam odločitev** — kdo: Claude Opus 5 —
  2026-08-24, migraciji `097` in `098`.

  **Odločitev uporabnika:** vrsta stranke (kupec / trgovec / oboje) in PE/tranzit sta PIM-lastni
  polji, ki ju postavi človek, ne uvožen podatek. `CHECK` na `CustomerKind` je za to že
  dovoljeval `CUSTOMER` / `SUPPLIER` / `BOTH`.

  **Narejeno:** `PayerKind` (`PE`/`TRANZIT`), `pim.PromoteCustomerWebProfile` (vrstica profila za
  vsako aktivno stranko, nobene odločitve ne postavi in nobene ne prepiše — varno za nočno
  opravilo), `pim.CustomerWebProfileToDecide` (delovni seznam s kontekstom iz SAOP in predlogom
  za PE iz naziva).

  **Merjeno po zagonu:** 4.390 profilov (toliko je aktivnih strank od 11.566), `WebEnabled = 1`
  pri **0** — izvoz zato ostane prazen, kar je pravilno: po dokumentu je skupina nosilna vez in
  stranka brez tipa v izvoz ne sme. Odločitev čaka pri 4.390 strankah, PE/tranzit je vprašanje
  le pri **149** (plačnik je nekdo drug), pri **52** naziv vsebuje »PE«.

  **Napaka, ujeta med izvedbo (`098` popravlja `097`):** v prvi različici sem `CustomerKind`
  polnil iz pravne oblike (P/F). To je narobe — pravna oblika pove pravna/fizična oseba, ne
  kupec/trgovec — in `CHECK CK_CustomerWebProfile_Kind` je MERGE pravilno ustavil. Preveril sem,
  ali je vrsto mogoče izpeljati iz SAOP: `CustomerType` ima `O` 11.514, `K` 47, `D` 4, `S` 1, kjer
  »O« nosi 99,5 % strank vseh vrst — izpeljava bi bila ugibanje z 11.514 posledicami. Postopek
  je zato ne postavi.

  **Dokaz:** `097` in `098` uporabljeni, `--verify` izhod 0, `PIM.F7.Integration`,
  `PIM.F7.MagentoExportTests` in `PIM.F7.ContractTests` uspejo (izhod 0).

- **[MERITEV] Stranke: mehanizem izvoza je cel, manjka podatek — in ta ni v SAOP** — kdo:
  Claude Opus 5 — 2026-08-24. Podrobno: [`docs/STRANKE_VHOD.md`](docs/STRANKE_VHOD.md).

  `out.ExportB2bCustomersCsv` je napisan, `pim.CustomerTypeMagentoGroup` ima **18** tipov strank,
  `pim.ValueDiscountTier` ima pragove 800/1.500/3.000 → 1/2/3 % natanko po dokumentu §4.6,
  `b2b.Customer` ima 11.558 strank. Izvoz vrne prazno datoteko izključno zato, ker je
  `pim.CustomerWebProfile` prazen — in ta nima vira.

  **Merjeno na surovem odgovoru SAOP `Customers`:** `CustomerType` je `O`/`K`/`S`/`D` (vrsta
  partnerja), `EntityType` `P`/`F` (pravna/fizična oseba). Poslovne taksonomije
  (`RESELLER`, `INSTALLER`, `CARPENTER`, …) **SAOP ne pošlje**. `CompanyLinkType` je bil kandidat
  za razločevanje PE/tranzit iz §4.10 — ni: pri **vseh 4.683** strankah ima vrednost `I`.

  **Zato tu nisem pisal kode.** Napolniti profil iz SAOP bi pomenilo izmisliti tip stranke; izvoz
  bi oddal 11.558 vrstic z ugibano skupino, po dokumentu pa je skupina nosilna vez za vse cene in
  popuste. Napačna skupina je dražja od prazne datoteke.

  **Kar je potrebno:** preglednica STRANKE kot vir (ista pot kot `SPLET_XLSX`, migracija 078),
  imena 18 Magento skupin, in podatek, kako ločiti PE od tranzita.


- **[BAZA + DOMENA] Datoteke so četrti sklop in zdaj pridejo v katalog: 9.953 dokumentov** —
  kdo: Claude Opus 5 — 2026-08-24, migraciji `095` in `096`.

  **Odločitev uporabnika 2026-08-24:** »od dobaviteljev je treba ločiti atribute, kategorijo,
  medijo in pa datoteke — to je nekak standard; potem je pa v mappingu treba povedati, kateri so
  kateri.« Model je to delal za tri od štirih; kanonične tabele za dokumente ni bilo, zato so
  trije dokumentni stolpci Magento predloge (40 »Glavni dokument«, 41 »Vloge dokumentov«,
  42 »Ostali dokumenti«) ostajali brez vira.

  **Kaj dobavitelja pošiljata (merjeno na 401 izdelku Braytrona):** `CE Files` 972 datotek,
  `Data Sheet` 401, `3D Files` 209, `DIALux Files` 130, `Video` 91 — od 1 do 10 na izdelek.
  Nowodvorski ima največ eno: 2.484× navodila za montažo, 89× energijska nalepka.

  **Zakaj preslikava po vlogi in ne po zaporedju.** `XPathMappingExtractor` bere s
  `SelectSingleNode`, torej eno vrednost na polje na zapis — seznama ne zna vrniti. Zaporedne
  preslikave (»prva datoteka, druga, tretja«) bi bile krhke, ker vrstni red sklopov ni zajamčen,
  podatkovni list pa mora ostati podatkovni list. Zato je vsaka vloga svoja preslikava — natanko
  to, kar pravi odločitev: v preslikavi povemo, kateri je kateri.

  **Kaj je narejeno:** `canon.ProductDocument`, postopek `map.ProcessDocumentInbox`, entiteta
  `Document` z osmimi preslikavami (pet vlog Braytrona, dve Nowodvorskega, plus EAN) pri vseh
  štirih podjetjih, in `Document` v `MappingProcedures` (test `PIM.F5.Integration` odslej pade,
  če ta svet ostane brez postopka). `CK_EntityMapping_TargetDomain` je razširjen — vseh dvanajst
  obstoječih vrednosti ostane, doda se trinajsta.

  **Napaka, ujeta med izvedbo (migracija `096`).** Prva različica postopka je dokumente pravilno
  vpisala, strani v `raw.Inbox` pa pustila v stanju `Pending` — manjkala sta zaključek strani in
  obravnava napake, ki ju imajo vsi ostali postopki. Brez škode za podatke (MERGE je združevalen),
  a števec »nepreslikanih strani« bi rasel z vsakim zajemom in nihče ne bi vedel, zakaj. Postopek
  je prepisan po istem vzorcu: kurzor čez strani, transakcija na stran, `Processed` s povzetkom,
  ob napaki `Quarantined`.

  **Dokaz.** Migratorja `095` in `096` uporabljena, drugi zagon nobene, `--verify` izhod 0,
  gradnja 0/0. Po zajemu in preslikavi: `canon.ProductDocument` **9.953 dokumentov na 7.521
  izdelkih**, strani entitete `Document` **8 Processed, 0 Pending**. Po vlogah:

  | Podjetje | Navodila | Podatkovni list | CE izjava | 3D | DIALux | Video | Nalepka |
  |---|---|---|---|---|---|---|---|
  | DEMO | 1.022 | 7 | 1 | 1 | — | — | 86 |
  | IQLighting | 2.414 | 294 | 233 | 150 | 131 | 8 | 87 |
  | Vidadria | 2.436 | 1.086 | 834 | 556 | 395 | 123 | 89 |
  | Ediito | — | — | — | — | — | — | — |

  Ediito je pri ničli iz istega razloga kot pri slikah in kategorijah: nima nobenega artikla teh
  dveh dobaviteljev (odločitev uporabnika 2026-08-24). `PIM.F5.Integration`,
  `PIM.F5.CategoryMappingTests` in `PIM.F6.Integration` uspejo, izhod 0.

  **Kaj namenoma ni narejeno:** izvoz. `pim.ProductDocument`, `val.Promote` in stolpci 40–42
  so naslednji korak, in **kateri dokument je »glavni«, je poslovna odločitev** — ne sme nastati
  mimogrede v migraciji. Predlog: pri Nowodvorskem navodila za montažo, pri Braytronu podatkovni
  list. Prav tako ostaja meja: pri vlogi z več datotekami (CE izjave) se vzame prva; za seznam bi
  moral izluščevalnik znati več vrednosti na polje, kar je ločena sprememba jedra.


- **[BAZA + WORKERJI] Manjkajoči prevodi po lastnosti — in napaka, zaradi katere prevod ni
  prišel do kataloga** — kdo: Claude Opus 5 — 2026-08-24, migraciji `093` in `094`.

  **Odločitev uporabnika 2026-08-24:** »prevode je treba iz te tabele prebrati, kar manjka se
  načeloma lahko uporabi AI, da vse zapolni prevajalne tabele, drugače pa bi uporabnik to mogel,
  samo mu je potrebno omogočiti.«

  ### Prevodi so vezani na lastnost, ne na besedo

  `map.ValueLookup` je imel 6.316 vrstic in **vse** z `Domain = '*'` — en prevod na besedo za
  cel katalog. Prav zato je 2026-08-21 nastala `docs\Prevodi_sporni.csv` z 236 besedami, ki
  imajo več slovenskih ustreznic: »White« je pri barvi *bela*, pri materialu *bel*. Globalen
  slovar tega ne loči, zato je vrednost ostala v angleščini.

  Postopek `map.ApplyValueTransforms` to zna že od migracije `049`, le da ni bilo uporabljeno:

  ```sql
  AND lookup.Domain IN (N'*', scope.Domain)
  ORDER BY CASE WHEN lookup.Domain = N'*' THEN 1 ELSE 0 END
  ```

  Migracija `093` zato ne vpiše nobene vrstice z `'*'`: vseh **213** manjkajočih prevodov
  (**78.709** pojavitev v katalogu, 16 lastnosti) je vezanih na svojo lastnost. »Wooden« je pri
  `Prevladujoča barva SLO` *lesena*, pri `Prevladujoč material SLO` pa *les* — ista angleška
  beseda, dva pravilna prevoda, brez spora.

  Prevodi so **strojni predlog, ne odločitev**: vsak je vrstica registra, popravek je `UPDATE`
  na `TargetValue`, izklop `IsActive = 0`. Stolpec `Note` pove, od kod vrstica je.

  Nastane tudi pogled `map.MissingTranslationOpen`: `map.MissingTranslation` je zapisnik in se
  ne prazni, zato bi po vpisu še vedno kazal 213 vrstic. Pogled odšteje tisto, kar je medtem
  dobilo prevod — enako kot `map.SourceCategoryToMap` pri kategorijah. Ničesar ne brišemo.

  ### Napaka, ki jo je to razkrilo (migracija `094`)

  Po `093` je bilo `map.MissingTranslationOpen` **0**, v katalogu pa **nobene spremembe** —
  `Prevladujoča barva SLO` je imela še vedno 2.425× »White« in 0× »bela«. Ponovna preslikava
  obeh dobaviteljev za vsa štiri podjetja ni spremenila ničesar.

  Vzrok je varovalka v `map.ApplyValueTransforms`:

  ```sql
  AND value.RawValue IS NULL
  ```

  Postopek pred prvo pretvorbo shrani izvirnik v `RawValue` in vrednost s tem označi kot
  obdelano. To je **pravilno** — brez tega bi se pretvorbe ob ponovnem zagonu izvedle dvakrat
  (`PREFIX` bi predpono dodal dvakrat, `STRIPPREFIX` odrezal dva). Posledica pa je bila, da nov
  prevod doseže samo na novo zajete strani.

  Ravno to je primer, za katerega `--znova-preslikaj` obstaja; njegov komentar v obeh workerjih
  pravi »rabi se, ko se preslikave dopolnijo nad že obdelanim zajemom«. Stikalo je vračalo samo
  stanje strani na `Pending`, vrednosti pa puščalo pretvorjene — **svoje naloge torej ni
  opravilo do konca in tega ni bilo videti nikjer.**

  `map.ReopenRunForMapping` (migracija `094`) naredi oboje v enem koraku: strani na `Pending`
  **in** vrednosti nazaj v surovo obliko (`Value = RawValue`, `RawValue = NULL`). Pretvorbe se
  izvedejo znova nad izvirnikom — deterministično in ponovljivo, izvirnik je shranjen prav zato.
  Ničesar ne briše. Postopek je v bazi, ker sta workerja dva (`PIM.XmlFileWorker` in
  `PIM.KatalogWorker`) in sta isti stavek imela prepisan vsak zase.

  ### Dokaz

  Migrator: `093` in `094` uporabljeni, drugi zagon ne uporabi nobene, `--verify` izhod 0.
  Gradnja `PIM.sln` 0 opozoril / 0 napak. Po popravku je bilo ponovno preslikanih **vseh 21
  zagonov** obeh dobaviteljev (lokalni datoteki, brez klica navzven). V katalogu:

  | Lastnost in vrednost | Pred | Po |
  |---|---|---|
  | `Prevladujoča barva SLO` = White | 2.425 | **0** |
  | `Prevladujoča barva SLO` = bela | 0 | **2.428** |
  | `Prevladujoča barva SLO` = črna | 0 | **2.493** |
  | `Slog SLO` = moderen | 0 | **4.031** |
  | `Prevladujoč material SLO` = barvano jeklo | 0 | **2.175** |

  `map.MissingTranslationOpen` je **0**. Strogo preverjeno (binarna primerjava, ki loči velike
  črke): **0** vrednosti v katalogu, kjer bi se prevod razlikoval od zapisane vrednosti. Ostane
  260 vrstic, kjer je prevod enak izvirniku — tehnične oznake (`MDF`, `PBT-PC`, `FPCB`) in
  razlike v veliki začetnici (`Japandi` → `japandi`); te niso neprevedene.

  `PIM.F5.CategoryMappingTests` in `PIM.F5.Integration` uspeta nespremenjena, izhod 0.

  **Kaj ostane odprto:** stran v intranetu, kjer uporabnik prevode ureja sam — druga polovica
  tvoje odločitve (»uporabnik bi to mogel, samo mu je potrebno omogočiti«). To je ozemlje
  INTRANET, ki je trenutno blokirano z drugim sklopom, zato se ga ta seja ni dotaknila.


- **[BAZA] Drevo videlektro je v PIM: 77 kategorij** — kdo: Claude Opus 5 — 2026-08-24,
  migracija `092`.

  **Zakaj je to blokiralo štiri stvari naenkrat.** `canon.WebSite` je imel vrstici `B2C` in
  `B2C_EN` za drevo `videlektro`, drevo pa **0** kategorij. Posledice: stolpca 26 in 27 Magento
  izvoza (»Kategorije vid«) sta bila prazna; profil `WEB_videlektro` je imel 0 veljavnih artiklov
  pri Ediitu; po migraciji `091` je bilo drevo iz preslikave namenoma izpuščeno (drevo brez
  kategorij ne sme delati hrupa), zato Braytronov elektromaterial ni imel kam.

  **Vir:** navigacija https://www.videlektro.com/sl/ , brana 2026-08-24 — po izrecni odločitvi
  uporabnika. Imena druge ravni so preverjena na straneh oddelkov (Inštalacije, Razsvetljava),
  tretja raven pri Sijalkah; ujemanje je bilo natančno, zato imen nisem ugibal.

  **Struktura:** 5 oddelkov (Inštalacije, Razsvetljava, Orodje, E-mobility, Alarmni sistemi),
  20 kategorij druge ravni, 52 tretje — skupaj **77**. Ključ je zapisan enako kot pri
  `svetila_si`, da ga `map.CategoryPathMap` obravnava po isti poti.

  **Namenoma ni vzeto:** `OUTLET`, `ALL BLACK` in `AKCIJA`. To niso kategorije izdelka, ampak
  prodajni sklopi; če jih hočeš v drevesu, so tri vrstice.

  **Angleška imena so predlog, ne prevod iz vira** — spletna stran je samo slovenska. Zapisana so,
  ker stolpec 26 zahteva angleško pot. Popravek nima posledic za podatke: noben izdelek še nima
  kategorije v tem drevesu.

  **Dokaz.** Migrator: `092` uporabljena, drugi zagon nobene, `--verify` izhod 0. V bazi
  `canon.Category` po drevesih: `svetila_si` 132, `videlektro` **77** (5/20/52 po ravneh).
  Prevedena pot dela v obeh jezikih: `Razsvetljava > Sijalke > LED sijalke E27` in
  `Lighting > Bulbs > LED Bulbs E27`.

  **Samoaktivacija iz `091` je dokazana v živo:** po vnosu drevesa je ponovna preslikava
  Braytrona za Vidadrio dala `map.MissingCategoryMap` **78 poti za `svetila_si` in 78 za
  `videlektro`** (prej samo 78 za `svetila_si`). Drevo se je vklopilo samo, brez spremembe kode.

  `PIM.F5.CategoryMappingTests`, `PIM.F5.Integration` in `PIM.F7.MagentoExportTests` uspejo
  nespremenjeni. **Pošteno zabeleženo:** en zagon `PIM.F5.Integration` je vmes padel s
  `SqlException 1205` (žrtev zaklepa) — na razvojni bazi je hkrati delala druga seja; dva
  zaporedna ponovna zagona sta uspela z izhodom 0. Pri `PIM.F7.MagentoExportTests` se je del
  proti bazi preskočil, ker v tisti lupini ni bilo `PIM_CONNECTION_STRING`.

  **Delovni list dopolnjen:** `PIM_Solution\docs\Braytron_druzine_predlog.csv` ima zdaj dva
  stolpca predlogov — `moj_predlog_svetila_si` (70 parov) in `moj_predlog_videlektro` (27).
  Skupaj ima predlog **96 od 103** parov. Brez predloga ostaja 6 pravih:
  `Decorative CLS > Metal / Glass CLR / Glass OPL / Glass CRY / Wooden / Rattan` — iz datoteke
  ni razvidno, ali so to senčniki, deli ali cele svetilke, in tega ne ugibam.


- **[BAZA + WORKERJI] Dobaviteljeve kategorije se odkrijejo same; Braytron jih je dobil 78** —
  kdo: Claude Opus 5 — 2026-08-24, migracija `091`.

  **Kaj je bilo narobe.** `map.ResolveProductCategories` je seznam dreves dobil s
  `CROSS JOIN (SELECT DISTINCT CategoryTreeCode FROM map.CategoryPathMap WHERE SourceCode = @SourceCode ...)`.
  Vir brez ene same preslikave torej ni imel nobenega drevesa, CROSS JOIN je vrnil nič vrstic in
  postopek zanj ni naredil ničesar — **niti vrstice v katalogu niti vrstice v delovnem seznamu**.
  Da bi se dobaviteljeva kategorija pokazala, bi morala zanjo že obstajati preslikava; da bi
  nastala preslikava, bi jo moral nekdo videti. Kura in jajce, in luknja je bila tiha.

  Drugič: **Braytron kategorij sploh ni izluščil.** `map.FieldMapping` je imel `ProductCategory.*`
  samo za `NW_XML`. Braytron družine pošilja kot lastnosti `main_family` in `sub_family` znotraj
  `<attributes>`, preslikave zanje pa ni bilo — zato v `raw.Inbox` ni bilo niti strani
  `Classification`, le `Attribute` in `Media`.

  **Kaj je narejeno** (odločitev uporabnika 2026-08-24: »kategorije dobaviteljev se bodo same
  generirale in uporabnik jih bo zmaperal z našo«):
  - `map.SourceCategory` — register dobaviteljevih kategorij, ki se polni sam iz zajema. Ne pozna
    ne dreves ne preslikav; hrani berljive ravni, ne le normaliziran ključ.
  - `map.SourceCategoryToMap` — pogled za človeka: kaj je dobavitelj poslal in še nima cilja.
  - Seznam dreves se bere iz `canon.WebSite` in samo za drevesa, ki dejansko **imajo** kategorije.
    Dvoje naenkrat: nov vir ni več neviden, drevo brez kategorij pa ne dela hrupa. Danes to
    pomeni natanko `svetila_si`; `videlektro` ima 0 kategorij in se vklopi sam, ko bo vnesen.
  - `BT_XML` dobi entiteto `Classification` in preslikavi za `main_family` / `sub_family`, pri
    vseh štirih podjetjih.

  **Dokaz.** Migrator: `091` uporabljena, drugi zagon ne uporabi nobene, `--verify` izhod 0.
  Ponoven zajem Braytronove datoteke za vsa štiri podjetja (lokalna datoteka, brez klica navzven)
  je ustvaril strani `Classification` in jih preslikal: ujetih 7 / 294 / 1.086 / 0 po podjetjih —
  natanko toliko, kolikor je ujemanj po EAN. Po tem: `map.SourceCategory` **78** kategorij
  Braytrona (prej 0), `map.MissingCategoryMap` za `BT_XML` **78** (prej 0), delovni seznam na
  vrhu »Indoor Lighting > LED Small Panel«, »Outdoor Lighting > LED Wall Light«.
  `PIM.F5.CategoryMappingTests` in `PIM.F5.Integration` uspeta **nespremenjena**, izhod 0;
  gradnja `PIM.sln` 0 opozoril / 0 napak.

  **`canon.ProductCategory` se ni spremenil (12.507) in to je pravilno:** ta korak ničesar ne
  preslika, samo odkrije. Katera Braytronova družina sodi v katero našo kategorijo, je odločitev
  uporabnika — delovni list s predlogom za 70 od 103 parov je v
  `PIM_Solution\docs\Braytron_druzine_predlog.csv`.

  **Dopolnjeno pospravljanje testov:** oba testa zdaj pobrišeta tudi svoje vrstice v
  `map.SourceCategory`. Tabela ob njunem nastanku ni obstajala, brez tega pa bi testni vir
  `F5_CATEGORY` smetil delovni seznam za človeka. Test ni bil spremenjen zato, da bi šel skozi —
  uspel je že prej in uspe tudi potem.

  **Znana meja:** `ProductCount` v registru pove, koliko izdelkov je kategorijo nosilo ob
  **zadnjem zajemu, ki jo je videl**; pri štirih podjetjih je to zadnje podjetje z ujemanjem
  (tu Vidadria). Za razvrščanje dela je dovolj, za poročilo po podjetjih ne — natančen razrez
  sodi k strani za preslikavo v intranetu.


- **[MERITEV] Zakaj Ediito iz dobaviteljev ne dobi ničesar — in kje je pravi strop obogatitve**
  — kdo: Claude Opus 5 — 2026-08-24.

  **Vprašanje.** Ediito ima 39.137 artiklov, od tega **0** s kategorijo in **0** s sliko, Vidadria
  pa 2.568 oziroma 3.657. Migracija `069` je konektorja `NW_XML` in `BT_XML` dala vsem štirim
  podjetjem, zato je bilo videti kot napaka.

  **Ni napaka.** Ediito ima EAN-e — 33.423 od 39.137, najboljša polnost od vseh štirih — a
  **nobenega z GS1 predpono kateregakoli dobavitelja** (Nowodvorski `5903139*`, Braytron
  `5949097*`). Njegova ponudba je italijanska (28.113 EAN) in španska (3.500); teh dveh
  dobaviteljev preprosto ne prodaja. Ujemanje po EAN dela pravilno.

  **Ob tem se je pokazal pravi strop.** Datoteki v `fixtures\` sta z 29. in 30. julija:

  | Podjetje | Nowodvorski v katalogu | od tega v datoteki | Braytron v katalogu | od tega v datoteki |
  |---|---|---|---|---|
  | DEMO | 3.075 | 1.145 | 7 | 7 |
  | IQLighting | 4.569 | 2.543 | 371 | 294 |
  | Vidadria | 4.930 | 2.571 | 1.345 | 1.086 |
  | Ediito | 0 | 0 | 0 | 0 |

  **6.651 artiklov obeh dobaviteljev v katalogu v datotekah sploh ni**; obratno **1.979
  Braytronovih EAN iz datoteke ne ustreza nobenemu artiklu v nobenem katalogu.** Strop torej ni
  v preslikavi in ne v konektorjih, ampak v vsebini datoteke — kar je cena odločitve o prevzemu
  svežih datotek (glej TODO).

  **Dokaz.** EAN izluščeni neposredno iz `fixtures\nw\products_en_US.xml` (2.619) in
  `fixtures\bt\BRaytron_xml_2026_07_29.xml` (3.072), primerjani s 110.874 EAN iz
  `canon.Product`. Nobene spremembe kode ali podatkov; samo branje.

  **Odločitev uporabnika 2026-08-24:** Ediito artiklov Nowodvorskega in Braytrona nima in to je
  pričakovano; obogatitev zanj pride takrat, ko bodo dodani dobavitelji, ki te artikle imajo.
  Zato to ni odprta postavka in ne potrebuje ne konektorja ne preslikave — zapisano zato, da
  naslednjič ne izgleda kot pozabljeno.

- **[OPERATIVA] Nočno opravilo ugasnjeno, zataknjeni zagoni zaprti** — kdo: Claude Opus 5 —
  2026-08-24, na izrecno zahtevo uporabnika (brez nje tega ne bi bilo: `AGENTS.md` §4.1 in §4.7).

  Načrtovana naloga `NoviPIM - nocni zajem SAOP` je `Disabled`. V `ops.PipelineRun` je bilo
  **14** zagonov `Running` brez konca (najstarejša dva z 2026-07-30, najnovejši štirje z
  2026-08-24 00:00, vsi z `RowsRead = 0`); vsi so zaprti kot `Failed`. Po posegu `Running` **0**,
  `Failed` 30, `Succeeded` 56. `EndedUtc` je pri teh štirinajstih namenoma ostal `NULL` — kdaj se
  je ubit proces res končal, ne ve nihče, izmišljen čas konca pa bi bil videti kot izmerjen
  podatek. `UPDATE` je imel varovalko `StartedUtc < DATEADD(hour, -1, ...)`, da se ne bi dotaknil
  zagona, ki res teče.


- **[WORKERJI] Dnevniki nočnih opravil so bili v pokvarjeni slovenščini — kriva je bila kodna
  stran, ne dnevnik** — kdo: Claude Opus 5 — 2026-08-24.

  **Kaj je bilo narobe.** V dnevniku je pisalo `┼Żiv SAOP zajem`, `kon─Źnih to─Źkah` in `ÔÇö`
  namesto pomišljaja. Worker piše UTF-8, konzola tega računalnika pa je v kodni strani **852**;
  PowerShell izpis zunanjega programa dekodira po `[Console]::OutputEncoding`, zato je `Ž`
  (UTF-8 `C5 BD`) postal `┼` + `Ż`. Dnevnik pri tem sploh ni bil pokvarjen — bil je pravilen
  UTF-8, ki je pošteno shranil že pokvarjene znake (preverjeno na bajtih: `e2 94 bc c5 bb`).
  Napaka je nastala na meji med `dotnet` in PowerShellom.

  Drugi del iste zgodbe: obe skripti sta bili shranjeni **brez BOM**. PowerShell 5.1 tako
  datoteko bere kot ANSI, zato so bila njuna lastna sporočila napisana brez šumnikov — obvod
  okoli iste napake, ne odločitev o jeziku.

  **Kaj je narejeno** (`scripts/Nocni-zajem.ps1`, `scripts/Nocno-vse.ps1`):
  `[Console]::OutputEncoding` in `$OutputEncoding` na UTF-8, preden se prebere prva vrstica;
  obe datoteki dobita UTF-8 BOM in s tem lastna sporočila v pravi slovenščini; `Zapisi` piše
  prek `[System.IO.File]::AppendAllText` kot UTF-8 **brez** BOM (`Add-Content -Encoding UTF8`
  v 5.1 BOM doda); pot dnevnika je razrešena v absolutno, ker .NET relativne poti razreši po
  delovni mapi procesa, ki je `Set-Location` ne spremeni. `Nocno-vse.ps1` je ob tem dobil še
  isto obravnavo stderr kot `Nocni-zajem.ps1` — doslej je stderr ubil korak in razlog izgubil,
  čeprav ga je `Korak` ujel; merilo uspeha ostane izhodna koda.

  **Dokaz.** Razčlenjevalnik PowerShell nad obema datotekama: brez napak. Popravljena
  `Nocni-zajem.ps1` je pognana v celoti z lažnim workerjem, ki piše šumnike na stdout in stderr,
  brez ene zahteve navzven: v dnevniku je `— MEJNIK STOJI (že zajeto, ta zagon nima česa
  preslikati)` in `STDERR: Napaka pri končni točki GetPrices: preveč zahtevkov, počakaj.`, `č`
  je zapisan kot `c4 8d`, datoteka je brez BOM, lastno sporočilo skripte pa se glasi `Začetek:`.
  `Nocno-vse.ps1` je dobil isto spremembo in je razčlenjen brez napak, ni pa pognan od začetka
  do konca — njegovi koraki pišejo v pravo bazo.


- **[WORKERJI] Nočni zajem iz SAOP je padal tiho; zdaj razlog konča v dnevniku** — kdo: Claude
  Opus 5 — 2026-08-24.

  **Kaj je bilo narobe.** Načrtovana naloga `NoviPIM - nocni zajem SAOP` se je 2026-08-24 ob
  02:00 sprožila in vrnila `LastTaskResult = 1`. Dnevnik `logs/zajem_2026-08-24_0200.log` ima
  pet vrstic in se konča pri »Meja na klic…«; vrstice `Konec, izhodna koda` ni. V
  `ops.PipelineRun` so za vsa štiri podjetja ostali zagoni `SAOP_PRODUCTS` v stanju `Running`
  z `RowsRead = 0`. **Zadnja stran iz SAOP v `raw.Inbox` je z 2026-08-21 12:21** — katalog je
  bil tri dni star, ne da bi to kdo videl.

  Vzrok je bil `scripts/Nocni-zajem.ps1`: `& dotnet @argumenti 2>&1 | ForEach-Object { Zapisi $_ }`
  pod `$ErrorActionPreference = 'Stop'`. Prva vrstica, ki jo worker napiše na stderr, postane
  `ErrorRecord` in s tem terminirajoča napaka — skripta umre sredi pipeline, razloga ne zapiše
  nikamor in s pipeline ubije tudi proces workerja, zato `ops.CompleteRun` ni bil poklican.
  Worker sam to zna (`OperationsRun.DisposeAsync`), ubit proces pa tega nima kje izvesti.

  **Kaj je narejeno.** Obravnava napak je `Continue` samo okoli tega klica; vsaka vrstica gre v
  dnevnik, tiste s stderr označene z `STDERR:`; nepričakovana PowerShell napaka pade v `catch`
  in se zapiše kot `NAPAKA:`; `Konec, izhodna koda` se zapiše vedno; `$izhod`, ki ostane `$null`,
  je izrecno neuspeh, da se prazna koda navzven ne bere kot uspeh.

  **Dokaz (RED → GREEN, brez klica na SAOP).** Stari vzorec je reproduciran z lažnim workerjem,
  ki piše na stdout in stderr in konča z 1: stdout se zabeleži, stderr ubije skripto, `Konec`
  ne pride nikoli — enako kot v produkcijskem dnevniku. Popravljena skripta je pognana v celoti
  z istim lažnim `dotnet` na `PATH` in nadomestnim korenom, torej brez ene same zahteve navzven:
  padec → `STDERR: Unhandled exception: SqlException: Login failed.` + `Konec, izhodna koda: 1.`,
  izhod 1; uspeh → `Konec, izhodna koda: 0.`, izhod 0; manjkajoča mapa → `NAPAKA: Cannot find
  path …`, izhod 1. Razčlenjevalnik PowerShell nad datoteko vrne brez napak.

  **Potrjeno v živo isti dan.** Uporabnik je zajem pognal ob 13:38. V dnevniku je zdaj tole,
  osem sekund po začetku:

  ```
  13:38:26  STDERR:   Cenikov ni bilo mogoče prebrati (A connection attempt failed because the
                      connected party did not properly respond ... (192.168.178.12:81))
  ```

  To je vrstica, ki je 2026-08-24 ob 02:00 ubila skripto in za sabo ni pustila ničesar. Zdaj je
  zapisana, poleg nje pa še 44 vrstic `NAPAKA` s časovnimi iztekami na isti naslov. Zajem ob
  13:49 je stekel čisto: 69 strani, 280.407 zapisov, `Konec, izhodna koda: 0.` V `raw.Inbox` je
  po tem 79 novih strani vseh štirih podjetij (zadnja 2026-08-24 11:54 UTC namesto 2026-08-21),
  `canon.Product` 196.515 → 196.531, `Pending` 0. Novih zagonov v stanju `Running` ni.

  **Vzrok padca ob 02:00 je torej omrežje do SAOP (`192.168.178.12:81`), ne koda.** Skripta ga
  je le skrila.

  **Kaj ni narejeno in zakaj:** prevezava načrtovane naloge na `Nocno-vse.ps1` je sistemska
  nastavitev (`AGENTS.md` §4.7). Štirinajst zataknjenih zagonov `Running` je zaprtih — glej
  naslednji vpis.

- **[BAZA + DOMENA + WORKERJI] Vhodi so zaključeni: vse končne točke, vsi dobaviteljevi XML,
  vse zaloge dobaviteljev, in nočno opravilo, ki to poganja** — kdo: Claude Opus 5 — 2026-08-23.

  **Kaj je bilo narobe.** Štiri od šestnajstih SAOP končnih točk so se zajemale brez cilja in
  ležale v `raw.Inbox` kot `Pending`. Hujše: migracija `082` je registrirala šifrante, konte
  zaloge in planiranje ter zanje ustvarila tri postopke — **poklical pa jih ni nihče**, zato so
  bile tabele prazne kljub vrsticam v registru. Dobaviteljeva zaloga je tekla samo za IQLighting.

  **Kaj je narejeno.**
  - Migracija **087**: cilj za `Customers`, `GetItemCustomerDataV2`, `CustomerItemGroupDiscounts`
    (nove tabele `b2b.CustomerItem`, `b2b.CustomerItemGroupDiscount`, 19 novih stolpcev na
    `b2b.Customer`) in `TechnologicalProcess` kot šifrant `TECHPROCESS`; Braytronove slike;
    konektorji in pravila identitete za dobaviteljevo zalogo pri vseh podjetjih. Preverba v
    migraciji zahteva, da ima **vsak** SAOP konektor vseh 16 končnih točk v registru.
  - Migracija **088**: `stock.ApplyLandingRecord` je od `018` iskal artikel brez pogoja po
    podjetju. Nevidno, dokler je zalogo imelo eno podjetje; po `087` je vezalo zalogo enega
    podjetja na artikel drugega.
  - `PIM.XmlMapping.MappingProcedures` — seznam svet → postopek na enem mestu, vključno s
    tremi iz `082`, ki jih ni klical nihče. `PIM.F5.Integration` odslej pade, če kateri
    dejaven `TargetDomain` nima postopka ali če postopka v bazi ni.
  - `PIM.KatalogWorker --preslikaj-zaostanek` — preslika vsak zagon, ki ima še vrstice
    `Pending`, brez klica na SAOP in brez iskanja `RunId` po rokah.
  - `PIM.StockFileWorker`: ista nespremenjena datoteka drugič ni več neujeta `SqlException 2627`.
  - `scripts\Nocno-vse.ps1` — vsi vhodi na en zagon; `scripts\Namesti-nocno-opravilo.ps1` za
    registracijo načrtovane naloge (požene človek, `AGENTS.md` §4.7).

  **Dokaz.** Migrator: `087` in `088` uporabljeni, drugi zagon ne uporabi nobene, `--verify`
  izhod 0. `--preslikaj-zaostanek`: 223 strani štirih podjetij preslikanih, `Pending` 0.
  V bazi po tem: `canon.Codebook` 0 → **708**, `canon.ProductPlanning` 0 → **196.512**,
  `canon.ProductStockAccounting` 0 → **176.086**, `b2b.Customer` 0 → **11.558**,
  `b2b.CustomerItem` **9.207**, `b2b.CustomerItemGroupDiscount` **4.270**, Braytronove slike
  0 → **1.384**. Dobaviteljeva zaloga za vsa štiri podjetja: NW 2.697 in BT 1.361 vrstic na
  podjetje, 0 v karanteni; ujetih po podjetju NW 1.066/2.455/2.461/131, BT 5/215/1.296/40 in
  **nobene** pozicije, vezane na artikel tujega podjetja. Testa `PIM.F5.Integration` in
  `PIM.F6.Integration` izhod 0. Nočno opravilo brez koraka 1 (živ klic na SAOP je odločitev
  človeka): 6 korakov, 0 padlih, 2 min 39 s, `Pending` 0.

  **Kaj ni narejeno in zakaj:** Braytronove kategorije (potrebujejo odločitev o drevesu, glej
  TODO), prevzem datotek s FTP (zunanji klic), registracija načrtovane naloge (sistemska
  nastavitev). `scripts\run_tests.ps1` v tej seji ni bil pognan do konca, ker je v delovnem
  drevesu hkrati tekla druga seja (odhodna pot) in je bila rešitev vmes neprevedljiva —
  pognani so bili ciljni testi in gradnja prizadetih projektov.

- **[BAZA + IZVOZ]** Cenik B2B/B2C v register namesto trdo v kodi — kdo: Claude Opus 5 —
  2026-08-23, migracija `083`. `MagentoExportCommand` je bral `WHERE PriceList = N'B2B'`
  oziroma `N'B2C'`; vsako podjetje pa svoje cenike imenuje po svoje, zato je imel
  **IQLighting stolpec „Cena B2B" prazen pri vseh 43.503 izdelkih** (cenika `B2B` sploh nima)
  in **Ediito „Cena B2C" pri vseh 33.304**. Ni bila napaka podatka — nastavitev podjetja na
  napačnem mestu. Isti vzorec kot glave stolpcev (`045`), spletne strani (`059`) in
  skladišča (`064`).
  Nastane `out.ExportPriceList`: podjetje → kanonična koda cenovnega stolpca → šifra cenika,
  s `SortOrder` kot prednostjo, kadar je cenikov za isti stolpec več.
  **Seme ne odloča ničesar:** vpiše natanko to, kar je bilo v kodi (`B2B` → „Cena B2B",
  `B2C` → „Cena B2C" za vsa štiri podjetja), zato je izvoz po migraciji do zadnjega znaka
  enak kot prej.
  **Odločitev uporabnika 2026-08-23:** manjkajoča vrstica ni napaka — če se cenik tako
  imenuje in ga podjetje nima, stolpec ostane prazen. Zato izvoz ob manjkajoči vrstici ne
  pade; pade samo ob manjkajočem profilu, ker je profil oblika datoteke, cenik pa vsebina.
  **Dokaz (RED/GREEN, ne samo trditev):** `PIM.F7.MagentoExportTests` posadi ceno v cenik
  `F7_CENIK` — šifre ni nikjer v programu in v nobeni migraciji — in vrstico registra s
  `SortOrder 5`; cena pride v stolpec „Cena B2B". Po izklopu iste vrstice (`IsActive = 0`)
  je stolpec prazen, „Cena B2C" pa nedotaknjena. Negativni preizkus nad **privzeto** vrstico
  (org 2, `Product.PriceB2C`) je test pričakovano podrl (`Cena B2C ... pričakovano 111.11,
  dejansko prazno`), po vrnitvi `IsActive = 1` pa spet uspe — izvoz res visi na registru.
  **Ostali dokazi:** migrator 1. in 2. zagon (druga je migracijo preskočila — idempotentna),
  `--verify` → `Preverjanje F0–F10 baze je uspešno.`, izhod **0**;
  `PIM.F7.MagentoExportTests` → **PASS**, izhod 0; izvoz za vsa štiri podjetja po zamenjavi
  vrne iste številke kot pred njo (polnih stolpcev 125/167/180/21, Cena B2B 1.109/0/9.691/33.296,
  Cena B2C 3/43.196/9.757/0).
  **Odprto za človeka:** ali ima IQLighting B2B cenik pod drugo šifro (uporabnik preveri pri
  viru). Če ga ima, je to en `INSERT` v `out.ExportPriceList` in nobena sprememba programa.

- **[IZVOZ]** Meritev izvozov in objava za Vidadrio in Ediito — kdo: Claude Opus 5 —
  2026-08-23. Nova analiza [`docs/ANALIZA_IZVOZI.md`](docs/ANALIZA_IZVOZI.md) nadomešča
  razdelek „B — IZVOZ" iz `ANALIZA_A_B_C.md`, ki je bil star 22 migracij (059–080).
  **Merjeno na resničnih datotekah, ne v dokumentaciji:** izvoz pognan za vsa štiri podjetja,
  vsaka datoteka preštéta stolpec za stolpcem.
  **Kaj je odpravljeno med meritvijo:** `val.Promote` za organizaciji 3 in 4 od migracije
  `077` ni bila pognana, zato je objava zaostajala za katalogom — `pim.Product` je imel
  dobavitelja in mersko enoto pri **0** izdelkih, čeprav sta v `canon` pri 24.364 oziroma
  38.171. Po zagonu (3 in 4 sekunde): dobavitelj **10.593 / 33.304**, `DESCRIPTION`
  12.064 → **35.613**, `WEB_TITLE` 20.623 → **48.203**, `TITLE_ERP2` 48.968 → **63.437**.
  V izvozu: Vidadria 169 → **180** polnih stolpcev (naziv 0 → 8.671), Ediito 10 → **21**.
  Isti zagon za organizaciji 1 in 2 je bil prazen tek — ti dve sta bili že objavljeni.
  **Stanje izvozov:** od sedmih izvoznih profilov v obratovanju teče **en** (Magento
  izdelki). 180 od 213 stolpcev ima vsaj pri enem podjetju vrednost, polnost celic pa je
  **8,2 %**: ERP hrbtenica je 100-odstotna, spletna vsebina ne (naziv 10,6 %, kategorija in
  slika 5,2 %, lastnosti 8,6 %).
  **Pet vrzeli, ki jih je meritev razkrila** (podrobno v analizi, §5): cenika `B2B`/`B2C` sta
  v `MagentoExportCommand` zapisana s trdo roko in IQLighting cenika `B2B` sploh nima,
  Ediito pa ne `B2C`; opisi pridejo v objavo, a Magento predloga nima stolpca za opis;
  zaloga je v bazi (278.160 pozicij), izvoz je ne bere (11 praznih stolpcev); datoteka
  strank je povsod samo glava (`b2b.Customer` = 0); pet procedur `out.Export*Csv` in dva
  profila nimajo nobenega klicatelja v produkcijski kodi.
  **Dokaz:** `dotnet build workers\PIM.B2bWorker` → 0 napak, 0 opozoril;
  `PIM.B2bWorker --export-magento --organization-id 1..4` → štirje pari datotek z oznako
  `magento-export.complete`; `dotnet run --project tests\PIM.F7.MagentoExportTests` →
  **PASS**; ~20 poizvedb nad `PIM` (migracija 080).
  **Odprto za človeka:** cenik B2B/B2C v register, stolpec za opis v predlogi, katero
  skladišče v kateri stolpec `VID *`, in vstopnica za objavo (`ERP_L1` 89.129 VALID proti
  `ERP_L1_SLO` 156.141).

- **[ZAJEM]** Spletni nazivi iz delovnih zvezkov — kdo: Claude Opus 5 — 2026-08-23, migracija
  `078`. Odločitev uporabnika: spletni naziv in ERP naziv sta dve različni stvari — ERP naziv je
  v SAOP omejen na dvakrat 30 znakov, spletni je poljuben in so ga sestavljali ročno.
  Sestavljeni nazivi živijo v **58 delovnih zvezkih** (`PIM_test\1-Uvoz artiklov_Splet`), povsod
  z istimi naslovi stolpcev: `Šifra artikla`, `Naziv artikla`, `Naziv angleški`, `Naziv nemški`,
  `Naziv hrvaški`.
  **Zvezek ni nov tok podatkov, ampak druga oblika istega.** `PIM.XmlFileWorker` ga pretvori v
  isti generični XML, ki ga že zna zajeti, in gre po isti poti — nabiralnik, izluščanje po XPath,
  preslikave iz registra, karantena, mejnik. Imena elementov nastanejo iz naslovov stolpcev
  (`Naziv angleški` → `NazivAngleski`); pravilo je na enem mestu, v `WorkbookReader.SanitizeName`.
  Rezultat po vseh štirih podjetjih: **31.500 slovenskih spletnih nazivov** (Vidadria 15.676,
  IQLighting 9.946, DEMO 4.724, Ediito 1.158) in 19.273 angleških. V izvozu za IQLighting je to
  4.593 slovenskih in 3.265 angleških nazivov; polnih **167 od 213 stolpcev**.
  **Tri pasti, ki jih je razkril prvi zagon:**
  1. Zvezek brez lista s šifro artikla je ustavil cel zajem in vse za njim je ostalo nezajeto;
     zdaj se preskoči z izpisom (dva taka: »Uvoz oddelek in kategorija«, »Uvoz opisov«).
  2. Datoteka, odprta v Excelu, je zajem ubila; zdaj se bere v načinu, ki to dopušča.
  3. Napaka formule v celici je pristala v katalogu kot spletni naziv `#N/A`. Zdaj se celica z
     napako bere kot prazna; 17 takih vrstic v katalogu in 7 v objavi je pobrisanih (nastale so
     v tem istem zagonu, pred popravkom).
  **Kar ta migracija namenoma ne naredi:** opisov iz istih zvezkov ne prenaša — `DESCRIPTION`
  danes prihaja iz SAOP in bi ga spletni opis prepisal. Kaj je pravi vir opisa, je ločena
  odločitev.

- **[IZVOZ]** Dobavitelj in merska enota prideta do izvoza — kdo: Claude Opus 5 — 2026-08-23,
  migracija `077`. Stolpca 7 in 9 sta bila prazna, čeprav podatka v katalogu obstajata od prvega
  zajema (`canon.Product.Supplier`, `canon.Product.UoM`). Objava (`pim.Product`) ju ni poznala —
  tabela je imela šifro, EAN, naziv in proizvajalca. Izvoz bere objavo, ne kataloga; isti razred
  napake kot `058`, `075` in `077`.
  Merska enota je hkrati obvezno polje profila `ERP_L1_SLO`, zato je bila njena odsotnost v
  izvozu še posebej zavajajoča: validacija je izdelek priznala, izvoz pa je stolpec pustil prazen.
  Rezultat: **43.502 izdelkov z dobaviteljem in mersko enoto**; izvoz ima **165 od 213** polnih
  stolpcev. **Opomba:** dobavitelj je šifra (`91086973`), ne ime — šifranta dobaviteljev SAOP med
  16 končnimi točkami ne pošilja.

- **[ZAJEM]** Lastnosti po meri, pravilo najmanjše/največje zaloge in ločena naziva — kdo:
  Claude Opus 5 — 2026-08-23, migracija `076`.
  **Lastnosti po meri** (`GetItemsCustomProperties`, 10 strani, ki so čakale od prvega zajema):
  zapis je par — ime lastnosti in vrednost. Isti razlog za svoj postopek kot pri nazivih: ključ
  pride iz podatka, ne iz imena ciljne kode. Ime lastnosti se ne prevaja — kar SAOP imenuje
  `BUG`, se v katalogu imenuje `BUG` (3.841 izdelkov).
  **Pravilo zaloge** (`GetItemsStockData`, 5 strani): to ni količina na zalogi, ampak koliko naj
  bi je bilo. Zato svoja tabela `canon.ProductStockPolicy` in ne `stock.*`, kjer živijo posnetki
  količin. **2.099 pravil pri 2.097 izdelkih v treh skladiščih.**
  **ERP naziv in spletni naziv sta različna** — odločitev uporabnika 2026-08-23. Migracija `074`
  je ERP naziv uporabila kot rezervo za spletni stolpec; to je zdaj odpravljeno. `pim.Product.Name`
  ostaja ERP naziv (in ima ga 43.502 od 43.503 izdelkov), stolpca »Naziv artikla« in »Naziv
  artikla EN« pa polni izključno `WEB_TITLE`. Danes sta zato prazna — in to je resnica: spletnih
  nazivov v katalogu (še) ni.
  Izvoz: polnih **163 od 213 stolpcev**.

- **[ZAJEM/IZVOZ]** Nazivi po jezikih, šifrant jezikov in trgovinski podatki do izvoza — kdo:
  Claude Opus 5 — 2026-08-23, migracije `072`–`075`.
  **Šifrant jezikov (`072`).** SAOP govori v šifrah (1, 2, 3), katalog v kodah jezika
  (`sl`, `en`, `de`), ker tako je zapisan `canon.ProductText.Lang`. Prevod imena v kodo je
  vrstica slovarja (`map.ValueLookup`, domena `SAOP jezik`), ne veja v programu. Pet jezikov
  pri vseh štirih podjetjih.
  **Nazivi po jezikih (`072`).** `map.ProcessRawInbox` tega ne zna, ker jezik pozna samo kot del
  imena ciljne kode; tu pride iz podatka. Zato svoj postopek `map.ProcessProductTextInbox`, po
  vzorcu skladišč. Šifra artikla je v tem odgovoru en nivo višje, zato pot `../../ItemID` —
  XPath 1.0 to zna in nova koda ni bila potrebna.
  Rezultat: **angleških nazivov 67.880**, nemških 12.349, hrvaških 12.398, drugih vrstic naziva
  (`TITLE_ERP2`) 83.281. 45 strani, ki so čakale od prvega zajema, je obdelanih.
  **Kar je razkrila ista pot:** ponovna preslikava je uveljavila tudi preslikave iz `057` —
  `canon.ProductCommercial` ima **196.513 vrstic namesto ene**. Trgovinski podatki so bili
  preslikani avgusta, a nikoli pognani čez že zajete strani.
  **Tri napake, ki so bile do zdaj nevidne:**
  1. `073` — `TITLE_ERP2` ni bil dovoljena vrsta besedila, zato je 92.735 izluščenih vrednosti
     padlo na `CK_CanonProductText_Type`. Naziv ima v SAOP dve vrstici in obe sta naziv.
  2. `074` — `pim.Product.Name` je bil `NULL` pri **vseh** izdelkih: objava ga je brala samo iz
     spletnega naziva, teh pa je v katalogu ena sama vrstica. Stolpec »Naziv artikla« je bil
     zato prazen pri 43.503 izdelkih, čeprav naziv obstaja pri 196.515. Odslej velja: spletni
     naziv, če obstaja, sicer ERP naziv istega jezika.
  3. `075` — objava ni nesla volumna in mer pakiranja: stolpci so bili dodani v `canon`
     (migracija `057`), v `pim.ProductCommercial` pa ne. Isti razred napake kot `058`, eno
     nadstropje nižje.
  **Izvoz:** polnih **165 od 213 stolpcev** (prej 156). Naziv 43.502, angleški naziv 11.193,
  volumen in mere pakiranja 43.502, enota mer 41.555.
  Nov ukaz `--znova-preslikaj <RunId>` tudi v `PIM.KatalogWorker` (prej samo v XML workerju).

- **[ZAJEM]** Dobavitelj se veže na vsa štiri podjetja — kdo: Claude Opus 5 — 2026-08-23,
  migraciji `069` in `070`. Odločitev uporabnika: dobavitelj ni last enega podjetja; njegov XML
  se poveže z vsemi štirimi katalogi po EAN.
  Konektorja `NW_XML` in `BT_XML` sta bila registrirana samo pri podjetju 2, zato je Vidadria
  ostala brez vsega, čeprav ima **več** ujemanj kot IQLighting. Prepis entitet, preslikav in
  pretvorb je narejen iz konektorja podjetja 2, ne na novo — vir resnice ostane ena, že
  dokazana nastavitev.
  **Ob tem je padla ista varovalka kot 2026-08-20 pri SAOP:** `ops.BeginRun` je zavrnil zagon z
  »Razpored ni omogočen«, ker je `GENERIC_XML` imelo vrstico v `ops.ScheduleProfile` samo pri
  podjetju 2. Varovalke nismo obšli; register je dopolnjen (`070`), kot je bilo takrat storjeno
  z `043`.
  **Izmerjeno po zagonu vseh šestih kombinacij:** Vidadria 2.571 (NW) + 1.086 (BT) obogatenih,
  DEMO 1.145 + 7, Ediito 0 (njenih EAN-ov v datotekah dobaviteljev ni). Lastnosti ima zdaj
  **7.645 izdelkov** namesto 2.835: Vidadria 3.657 (143.493 vrstic), IQLighting 2.835 (112.819),
  DEMO 1.153 (45.959). Kategorijo ima 6.254 izdelkov, sliko 6.261.
  **Kar ostaja odprto in je zdaj vidno v številkah:** zapisi brez ujemanja (Braytron 1.996 pri
  Vidadrii, Nowodvorski 48) so nove dobaviteljeve šifre. Te ne smejo v katalog mimo SAOP —
  šifra artikla je last SAOP (`068`), zato dobaviteljev konektor ostaja `CanCreateProducts = 0`.
  Pot zanje je opisana v `docs/TVOJE_NALOGE.md` in čaka na potrditveni seznam.

- **[ODHODNA POT]** C8: lastništvo polj iz preglednice — kdo: Claude Opus 5 — 2026-08-22,
  migracija `068`. **To je bil manjkajoči kos odhodne poti, ne dispatcher.**
  `out.EnqueueMessage` zavrne vsako spremembo, za katero ni vrstice v `out.OwnershipPolicy` z
  `Owner = 'PIM'` (napaka 51010); tabela je bila prazna, zato v `out.OutboxMessage` ni moglo
  nikoli vstopiti nobeno sporočilo. Zdaj je napolnjena iz stolpcev »Smer« in »Master« v
  `Mapiranje_SAOP_API_PIM.xlsx`: od 259 polj s smerjo je 50 pisljivih.
  **Pravilo O9 je izvedeno in ne le zapisano:** pravica nastane samo za polja, ki imajo aktivno
  vhodno preslikavo — česar ne beremo nazaj, ne moremo preveriti, zato ne sme biti pisljivo.
  Rezultat: **20 polj s pravico do pisanja in 8 samo za branje** na podjetje. Polja, ki so po
  preglednici pisljiva, a jih (še) ne beremo, pravice ne dobijo; ko preslikava nastane, jo
  dobijo brez spremembe kode.
  Dokaz: nov `PIM.F8.OwnershipPolicyTests` — preveri pravilo O9 nad celotno tabelo, potrdi
  `Product.ItemID` kot pisljiv in `ProductPrice.Net` kot samo za branje, nato v transakciji, ki
  se povrne, res pošlje eno spremembo skozi `out.EnqueueMessage` in dokaže, da druga pade s
  51010; v bazi ne ostane nobeno sporočilo.
  **Kar ni zajeto:** stranke (10 pisljivih polj lista »Stranke«) — odhodna pot za stranke danes
  ne obstaja, `TargetKind` bi bil `SAOP_CUSTOMER`.

- **[PREVODI]** Delovni list s predlogi prevodov — kdo: Claude Opus 5 — 2026-08-22.
  `map.MissingTranslation` ima **213 vrednosti v 16 lastnostih**, ki v izvozu ostanejo v
  angleščini. Nastal je `PIM_Solution\docs\Prevodi_predlog.csv`: za vsako vrednost lastnost,
  jezik, število izdelkov, kandidati iz uporabnikove preglednice in **moj predlog**.
  Predlog je pri **120 od 213 vrstic**, kar pokrije **96 % pojavitev** (19.036 od 19.792).
  Oblika je izbrana po lastnosti, ker je od nje odvisna: barva je ženskega spola (`White` →
  `bela`), material je samostalnik (`Painted steel` → `barvano jeklo`), tehnične oznake
  materialov (`PC+PC`, `FPCB`) pa ostanejo, kot so.

- **[WORKERJI/BAZA]** Zaloga iz SAOP: šifrant skladišč, profili in worker, ki ni več izpis —
  kdo: Claude Opus 5 — 2026-08-22, migracije `064`, `065`, `066`.
  **Kaj se je pokazalo najprej:** med šestnajstimi zajetimi končnimi točkami dejanskih količin
  ni. `GetItemsStockData` nosi najmanjšo in največjo zalogo po skladišču,
  `GetItemsStockAccountingData` pa konte. Količine so na ločenem vmesniku, zato je bila naloga
  drugačna, kot je izgledala: ne »preslikaj že zajeto«, ampak »napiši pot do vmesnika, ki ga
  še nismo klicali«.
  **Šifrant skladišč (`064`).** `canon.Warehouse` s šifro in imenom — DEMO 7, IQLighting 35,
  Vidadria 74, Ediito 15. Podatek je bil že zajet in je čakal v `raw.Inbox`; nov klic ni bil
  potreben. Ob tem je register dobil razliko med šifrantom in izdelkom
  (`map.EntityMapping.TargetDomain`): `map.ProcessRawInbox` zna samo izdelke in bi skladišče
  zavrnil kot artikel brez šifre, zato ga zdaj preskoči, obdela pa ga
  `map.ProcessWarehouseInbox`. Isti vzorec je odslej pot za valute, cenike in jezike.
  **Profili (`065`, `066`).** Odločitev uporabnika: `GetStocks` za vsa štiri podjetja,
  `RegisteredViewData` za Vidadrio (dela samo tam). Registrirani pogled je vpisan izklopljen,
  ker njegove šifre ne poznamo — dobi se z živim klicem `api/registeredviews`. Skladišča se
  jemljejo iz registra (`ActiveFromRegister`); v zahtevo gre samo šifra, ime je za prikaz.
  Zaloga ima svoje konektorje (`SAOP_*_STOCK`) in pravila identitete po šifri artikla brez
  predpone — SAOP pošlje našo šifro, dobavitelj tujo.
  **Napaka, ki jo je razkrilo pisanje workerja:** `SaopStockProviderRegistry` je za `GetStocks`
  in `StockAdvance` gradil `POST` z JSON telesom. Swagger SAOP pravi `GET` s parametri v naslovu
  in odgovorom v XML. Klica ni nikoli nihče izvedel, zato je bila napaka nevidna.
  **Dokaz brez živega SAOP:** nov `PIM.F6.SaopStockIntegration` v izoliranem podjetju 9606 —
  lokalni strežnik na `127.0.0.1` vrne odgovor in posname zahtevo. Preverjeno: zahteva gre na
  `api/Stock/GetStocks`, nosi šifre skladišč in ne imen, ima glavo `OrganisationId`, znan
  artikel dobi pozicijo s količino, neznan pa pozicijo brez izdelka (`MatchKey = 'Unmatched'`)
  namesto da bi izginil. Test za sabo pobriše vse svoje vrstice.
  **Kar ostane človeku:** šifra registriranega pogleda za Vidadrio in prvi živi klic
  (`PIM_SAOP_MODE=Live`), oboje po `AGENTS.md` §4.5.
  Ob tem se je `StockLandingWriter` preselil iz `PIM.StockFileWorker` v `src\PIM.StockMapping`:
  pisalna pot je skupna vsem virom zaloge, sicer bi worker referenciral drugega workerja.

- **[WORKERJI/TESTI]** Zaloga dobavitelja pride v bazo; paket brez baze ne laže več — kdo:
  Claude Opus 5 — 2026-08-22.
  **`PIM.StockFileWorker` je dobil pravi `Program.cs`.** Bralna stran (NW CSV, BT XML) in
  pisalna stran (`StockLandingWriter`, `stock.ApplyLandingRecord`) sta obstajali in bili
  dokazani, manjkal je zapisan vhodni dogovor — čigava zaloga je in v kateri vir gre. Zdaj:
  `--file <pot>` z izbirnimi `--source`, `--organization-id`, `--endpoint`, `--date-format`
  in `--samo-preberi`. Vir se privzeto ugane iz končnice (`.xml` = Braytron, ostalo =
  Nowodvorski CSV), oblika datuma iz vira (Braytron ISO, Nowodvorski evropsko). Konektorja in
  pravila identitete si worker ne izmišlja — morata biti v registru.
  Dokaz proti bazi: `NOWODVORSKI.csv` → 2.697 uporabljenih, 0 v karanteni;
  `Braytron_stocks.xml` → 1.361 uporabljenih, 0 v karanteni. Vhodni dogovor pokriva
  `PIM.F6.FileWorkerTests` (privzetki, prevlada `--source`, pet napačnih klicev).
  **Kar ostaja:** datoteko je treba položiti v mapo; prevzem s FTP je zunanji klic.
  **Pet projektov, ki so brez baze padli, se zdaj preskoči.** Izmerjeno z odmaknjenim
  `appsettings.Local.json` in praznim `PIM_CONNECTION_STRING`: prej izhod 1, 38 uspeli,
  1 preskočen, **5 padlih**; zdaj **izhod 0, 36 uspeli, 10 preskočenih, 0 padlih**.
  Preskoči se samo, kadar povezave ni nikjer; kjer je nastavljena, dokaz teče kot prej, in
  izpis paketa izrecno pove, da preskočeno ni dokaz. Popravljenih je osem projektov (pet s
  table, plus `PIM.F5.ValueTransformTests`, `PIM.F5.CategoryMappingTests` in
  `PIM.F7.Integration`, ki so padli iz istega razloga).
  **Kar je bilo za to treba prevzeti nazaj:** trije testi so imeli v kodi zapisano »ni
  dovoljeno preskočiti«. Namen te trditve je bil, da se dokaz ne izgubi tiho; ostaja
  izpolnjen, ker se preskoči izključno takrat, ko povezave ni nikjer.

- **[BAZA]** Kategorija ne sme kazati na spletno stran, ki je v registru ni — kdo:
  Claude Opus 5 — 2026-08-22, migracija `063`. Po odobritvi je pobrisana zadnja vrstica
  `canon.ProductCategory` s spletno stranjo `svetila.si` (s piko) in potjo `Svetila/Test`;
  naredil jo je dokazni izdelek `F2-PROOF-001`, ki ga `PIM.F2.Integration` namenoma pušča v
  razvojni bazi, koda pa v registru ne obstaja — od `059` se stran imenuje `svetila_si`.
  Da se ne ponovi, je pravilo zdaj omejitev baze (`FK_ProductCategory_WebSite`), test pa
  uporablja registrirano kodo. Ob tem je `canon.WebSite.WebSiteCode` razširjen na
  `nvarchar(100)`, ker tuji ključ zahteva enak tip kot `canon.ProductCategory.WebSite`.

- **[BAZA]** Enajst poti tračnih sistemov, odstranjene dobaviteljeve kategorije in napaka, ki
  jo je to razkrilo — kdo: Claude Opus 5 — 2026-08-22, migraciji `060` in `062`.
  Uporabnik je potrdil vseh enajst predlogov (`PIM_Solution\docs\Kategorije_manjkajoce.csv`):
  Nowodvorski pošilja te poti na treh ravneh, stari slovar jih je imel na štirih, zato gredo
  v nadrejeno kategorijo, ki v drevesu že obstaja. `map.MissingCategoryMap` je prazen,
  kategorijo ima **2.540 izdelkov** (prej 2.382).
  Ob tem so po odobritvi pobrisane vrstice, ki jih je delala preslikava, izklopljena v `059`
  — 2.541 vrstic `canon.ProductCategory` in enako v `pim.ProductCategory` s spletno stranjo
  `B2C` in dobaviteljevo kategorijo prve ravni v angleščini. Brisanje je omejeno na natanko
  pet znanih poti; kategorije istih izdelkov pod `svetila_si` ostanejo.
  **Napaka, ki jo je to razkrilo (migracija `062`):** vrstice so se ob prvi ponovni preslikavi
  vrnile. `map.ProcessRawInbox` bere `map.ExtractedValue` in ni gledal, ali je preslikava, ki
  je vrednost izluščila, še aktivna — izluščene vrednosti namenoma ostanejo kot sled, zato je
  izklopljena preslikava pisala naprej. `IsActive = 0` je bil s tem samo napol resničen: novih
  vrednosti ni več luščil, stare pa so tekle v katalog. Popravljenih je vseh pet mest, kjer
  postopek bere vrednosti za vpis (identiteta zapisa, preverba cene, zmagovalne vrednosti,
  kategorije, cene); nespremenjeno ostane branje, ki ob karanteni zapiše v `map.UnmappedValue`,
  ker tam je pravilno videti vse, kar je vhodna vrstica nosila.
  Dokaz: po `062` ponovna preslikava istega zajema vrstic pod `B2C` **ne vrne** (prej 2.540),
  `svetila_si` ostane 2.540; migrator uporabi `060` in `062`, 2. zagon nobene, `--verify` 0;
  `scripts\run_tests.ps1` → 46 uspeli, 0 padlih.
  **Opomba za pregled veje:** moja datoteka je bila najprej oštevilčena `061`, kar je trčilo z
  `061_ReleaseRunApplock.sql` druge seje. Preimenovana je v `062`, njena vrstica v
  `dbo.SchemaMigration` pa je bila pobrisana, da se je uporabila pod novim imenom — šlo je za
  mojo vrstico, staro nekaj minut, na tem računalniku.

- **[ODHODNA POT / Agent C + BAZA]** Zanka dispatcherja utrjena; ob tem najdena kljucavnica,
  ki je nihce ni sprostil — kdo: Claude Opus 5 — 2026-08-22.
  **Tri luknje v zanki, ki sem jo dodal v `70c677f`:**
  1. *Zastrupljeno sporočilo je zaprlo vso vrsto.* Lovljena je bila samo `HttpRequestException`
     in `TaskCanceledException`. `out.ClaimMessage` bere vrsto po `OutboxMessageId`, zato bi
     eno sporočilo s pokvarjeno nastavitvijo (`HttpOperation`, ki ni POST/PATCH, neveljaven
     `EndpointTemplate`) ob **vsakem** zagonu vrglo na istem mestu in nobeno sporočilo za njim
     ne bi prišlo nikoli na vrsto. Zdaj se ujame vsaka izjema; sporočilo gre v `Retry`.
     V bazo gre samo **vrsta** izjeme — sporočilo izjeme lahko nosi naslov s poverilnico.
  2. *Prekrivanje s samim sabo je bilo neobravnavana izjema.* `51101` je za načrtovan worker
     normalno stanje; zdaj se drugi zagon umakne in vrne `AlreadyRunning`.
  3. *Meja `maxMessages` je bila tiha.* Odrezana vrsta je izgledala kot prazna; zdaj se izpiše.
  **Kaj je pri tem prišlo na dan (in je večje):** `ops.BeginRun` vzame `sp_getapplock` z
  `@LockOwner=N'Session'`, `ops.CompleteRun` pa je ni nikoli sprostil. Ker `OperationsRun` svojo
  `SqlConnection` ob `Dispose` vrne v bazen namesto da bi jo ubil, je ključavnica preživela
  logično zapiranje za nedoločen čas. **To zadene vsak worker, ne le dispatcherja** — le da je
  bilo doslej nevidno, ker je vsak worker v svojem procesu opravil eno izvajanje in končal.
  Popravljeno z migracijo **061**.
  **Dokaz — RED:** `PIM.F8.Integration` z novimi trditvami → izhod 82, `Error Number:51101`
  na testovem lastnem `BeginAsync`. Neposredna meritev v eni seji: `po BeginRun Exclusive`,
  `po CompleteRun` **`Exclusive`** — tam bi moralo biti `NoLock`.
  **Dokaz — GREEN:** po 061 `po CompleteRun NoLock` in drugi `BeginRun` v isti seji uspe.
  Testi: **F8 vseh sedem izhod 0**, **F9 vseh šest izhod 0** (drugi uporabnik
  `ops.CompleteRun`), **F3 vsi štirje izhod 0**. Migrator: 1. zagon uporabi 061, 2. zagon
  nobene, `--verify` izhod 0.
  **Trk številk migracij:** moja je najprej nastala kot `060`, ker je druga seja svojo `060`
  uporabila na bazo, ne da bi jo commitala. Preštevilčena v `061`. **V `dbo.SchemaMigration`
  zato ostaja vrstica `060_ReleaseRunApplock.sql`, ki ji datoteka ne pripada** — brisanje je
  na zaprtem seznamu `AGENTS.md` §4.1, zato je nisem odstranil. Isto vrsto ostanka imata že
  `047_ValueDictionaryAndTransforms.sql` in `048_...`.

- **[ODHODNA POT / Agent C]** Dispatcher: razpored pred prevzemom, zanka čez čakalno vrsto in
  prvi test, ki `Program.cs` sploh pokriva — kdo: Claude Opus 5 — 2026-08-22.
  **Napaka, ki je bila najdena:** `ops.BeginRun` vrže `51100 'Razpored ni omogočen.'`, če za
  par (organizacija, `OUTBOUND`) ni omogočene vrstice v `ops.ScheduleProfile` — te vrstice ni
  za nobeno podjetje. `PIM.OutboxDispatcher\Program.cs` pa je klical `out.ClaimMessage`
  **pred** `BeginRun`. Ob prvem resničnem sporočilu bi ga torej prevzel, povečal `AttemptCount`,
  vpisal vrstico v `out.OutboxAttempt` in šele nato umrl — poskus porabljen, zahteva nikoli
  poslana. Ob dovolj ponovitvah bi sporočilo prišlo v `Dead` od poskusov, ki se niso zgodili.
  **Zakaj tega ni ujel noben test:** `F8.DispatcherTests` preizkuša `SaopOutboundHandler` in
  `DispatchClassifier`, `F8.Integration` in `F8.HardeningTests` pa kličeta procedure
  neposredno. `Program.cs` do zdaj ni pokrival noben test.
  **Kaj je spremenjeno:** logika je izluščena v `OutboxDispatchRunner` (zato je sploh
  preizkusljiva); razpored se prebere pred prvim prevzemom in manjkajoč razpored je izid
  zagona, ne izjema; zagoni za vsa podjetja se odprejo pred prvim prevzemom; obdelava je
  zanka do prazne vrste z mejo `maxMessages`; utrip gre po vsakem sporočilu. Sporočilo
  podjetja brez razporeda se ne ubije — zaključi se kot `Transient` in gre v `Retry`,
  ker je to nastavitvena in ne poslovna napaka.
  **Dokaz — RED:** `PIM.F8.Integration` z novimi trditvami → izhod 82,
  `Error Number:51100` iz `OperationsRun.BeginAsync`, klicanega iz
  `OutboxDispatchRunner.RunAsync`.
  **Dokaz — GREEN:** vseh sedem F8 projektov posamično → **izhod 0**
  (`BehaviorTests`, `ContractTests`, `DispatcherTests`, `EchoTests`, `HardeningTests`,
  `Integration`, `IntranetTests`). Build `PIM.OutboxDispatcher` in `PIM.F8.Integration`:
  0 opozoril, 0 napak. Živ zagon workerja proti bazi:
  `Za pipeline OUTBOUND ni omogocenega razporeda v ops.ScheduleProfile; nobeno sporocilo ni
  bilo prevzeto.`, izhod 1 — prej bi na tem mestu crknil s 51100 sredi prevzema.
  Po zagonih: `out.OutboxMessage` 0, `ops.ScheduleProfile` za `OUTBOUND` 0, org 9808 0 —
  test počisti izključno svoje vrstice.
  **Česa NI:** poln `scripts\run_tests.ps1` v tej seji ni bil izveden. Build celotne rešitve
  pade izključno na `MSB3021`/`MSB3027` — druga seja hkrati poganja svoj
  `PIM.F5.CategoryMappingTests` in drži `PIM.XmlMapping.dll` zaklenjeno. Nobene `error CS`;
  po `AGENTS.md` §3 to ni napaka v kodi, tujih procesov pa nisem ustavljal.
  **Ostane:** vrstica `OUTBOUND` v `ops.ScheduleProfile` za prava podjetja (migracija 060,
  čaka, da se sprosti migracijska steza — druga seja ima odprto 059) in vrstica o dispatcherju
  v `docs/WORKERS.md` (datoteka je bila ob commitu odprta v drugi seji).

- **[ZAJEM/IZVOZ]** Dobaviteljev XML se prvič prebere v celoti; kategorije so naše —
  kdo: Claude Opus 5 — 2026-08-22, migracija `059_CategoryTreeAndSupplierMapping.sql`.
  **Kaj je bilo narobe:** preslikave iz migracij `054`/`055` so obstajale, brala pa se je
  samo 336 KB izrezek Nowodvorskega (25 izdelkov) in 30 KB izrezek Braytrona (3 izdelki).
  Polna datoteka (19 MB) je 4. 8. končala v karanteni in od takrat je ni nihče pognal.
  Lastnosti je imelo **29 izdelkov** — zato so bili atributni stolpci izvoza v praksi prazni,
  čeprav je bil mehanizem dokazan.
  **Zakaj polna datoteka ni šla skozi:** trije razlogi, vsi izmerjeni.
  1. `SqlMappingPipeline` je bral strani in preslikave z enim JOIN-om, zato je vsaka vrstica
     nosila cel `PayloadXml`: 37 MB × 112 preslikav ≈ 4 GB po žici za eno stran. Zdaj sta to
     dve poizvedbi in vsebina strani gre po žici enkrat.
  2. `XPathMappingExtractor` je pot prevajal ob vsakem zapisu — 2.619 × 112 = 293.000 prevodov
     istih 112 izrazov. Zdaj se prevede enkrat na preslikavo.
  3. Vsaka izluščena vrednost je bila svoj obhod do strežnika (`IF NOT EXISTS` + `INSERT`),
     torej 293.000 obhodov na stran. Zdaj gredo množično v začasno tabelo, vstavi pa jih en
     stavek z istim pravilom »kar že obstaja, se ne vstavi znova«.
  Merjeno na isti datoteki: prej **prek 20 minut brez konca**, zdaj **110 s** za vse tri
  entitete. `canon.ProductAttribute` 1.064 → **112.820** vrstic, 29 → **2.548** izdelkov.
  Braytron: od 3.082 izdelkov v datoteki jih je 291 v našem katalogu (ujemanje po EAN).
  **Kategorije (naloga 3):** dobaviteljeva kategorija ni naša. Iz stare baze `PIM_test`
  (samo branje) je prenesenih 132 kategorij, 225 prevodov in 190 poti slovarja; nastali so
  `canon.WebSite`, `canon.Category`, `canon.CategoryTranslation`, `map.CategoryPathMap`,
  `map.MissingCategoryMap` in pogled `canon.CategoryPathTranslated`. Ključ poti je isti kot v
  starem sistemu (male črke, presledek je podčrtaj, ravni loči `___`) in pokrije 44 od 56 poti
  Nowodvorskega, kar je 93 % izdelkov; preostalih 11 poti (tračni sistemi, 161 izdelkov) gre
  v `map.MissingCategoryMap` in čaka človeka.
  Katera spletna stran gre v kateri stolpec, je zdaj vrstica v `canon.WebSite` — prej stikalo
  v C# (`"B2C" => SLO`), zaradi katerega je bila nova spletna stran nova različica programa.
  **Izvoz:** polnih **152 od 213 stolpcev** (prej 12). Stolpca 24/25 sta polna pri 2.113
  izdelkih (`Cameleon sistem > Rozete` / `Cameleon System > Canopies`).
  **Nov ukaz** `--znova-preslikaj <RunId>`: iste datoteke ni mogoče zajeti dvakrat (`raw.Inbox`
  je enoličen po vsebini), zato ta ukaz strani zagona postavi nazaj na `Pending` in jih požene
  skozi dopolnjeno preslikavo. Nič ne briše; preslikava je združevalna.
  **Kar namenoma ostaja:** 2.267 starih vrstic `canon.ProductCategory` z dobaviteljevo
  kategorijo pod `B2C`; preslikava, ki jih je delala, je izklopljena, brisanje pa je odločitev
  uporabnika (`AGENTS.md` §4.1).
  Dokaz: migrator uporabi `059`, 2. zagon nobene, `--verify` izhod 0; nov test
  `PIM.F5.CategoryMappingTests` (ključ poti, naša pot v obeh jezikih, delovni seznam neznanih,
  ponoven zagon brez podvojitev), ki za sabo pobriše vse svoje vrstice;
  `dotnet build PIM_Solution\PIM.sln -warnaserror` → 0 opozoril, 0 napak.

- **[IZVOZ]** `MagentoExportRunner.cs` ostane, a je zavarovan — kdo: Claude Opus 5 —
  2026-08-22, odločitev uporabnika (naloga 6). Mrtva koda se ne briše; namesto tega
  `PIM.F7.MappingTests` pade, če se nanjo sklicuje karkoli razen komentarja. RED dokazan z
  začasno datoteko, ki jo uporabi (`sklicujejo se nanj: ZzzRedProbe.cs`), GREEN po njeni
  odstranitvi.

- **[WORKERJI]** `PIM.FoundationWorker` in ostanek `PIM.NwXmlWorker` sta arhiv — kdo:
  Claude Opus 5 — 2026-08-22, odločitev uporabnika (naloga 7). Nič ni pobrisano;
  `FoundationWorker` to pove v svojem izpisu, `NwXmlWorker` pa sta samo še `bin\`/`obj\`,
  ni ne v rešitvi ne v Gitu.

- **[DOKUMENTACIJA]** Analiza treh delov A/B/C proti živi bazi — kdo: Claude Opus 5 —
  2026-08-22. Nastal je [`docs/ANALIZA_A_B_C.md`](docs/ANALIZA_A_B_C.md); `STATUS.md` in
  ta tabla sta popravljena tam, kjer sta bila zastarela.
  **Dokazi:** `dotnet build PIM_Solution\PIM.sln` → **Build succeeded**, 0 napak
  (3× MSB3026, zaklenjena `.dll`, ker je tekel `PIM.F3.Integration`);
  `dotnet run --project src\PIM.Migrator -- --verify` → `Preverjanje F0–F10 baze je
  uspešno.`, izhod **0**; `dotnet run --project workers\PIM.B2bWorker -- --export-magento
  --organization-id 1 --output-dir <temp>` → nastali `magento-products.csv` (**1.729
  vrstic**, 433 KB), `magento-customers.csv` in `magento-export.complete`; ~20 poizvedb nad
  bazo `PIM` (migracija **058**).
  **Kaj je meritev pokazala:** A zajem ~90 % mehanizma / ~55 % v obratovanju,
  B izvoz ~85 % / **~10 %**, C odhodna pot ~50 % / **0 %**. Razkorak ni v kodi, ampak med
  kodo in podatkom.
  **Tri trditve na tabli in v `STATUS.md` so bile napačne** in so popravljene:
  (1) „162 atributnih stolpcev nima vira" — 156 od 160 ga ima (054/055);
  (2) „`canon.ProductCommercial` nima preslikave" — ima jo (057), manjka ponovna preslikava
  zajetih strani; (3) „`val.Promote` polni samo `pim.Product`" — 058 to odpravi,
  `pim.ProductText` 44.511, `pim.ProductPrice` 85.777.
  **Novo, kar prej ni bilo nikjer zapisano:** izvožena datoteka ima vrednost v **15 od 213
  stolpcev**; `out.OutboxMessage`/`OutboxAttempt`/`SaopItemAssignment`/`OwnershipPolicy`
  imajo **0** vrstic; `PIM.OutboxDispatcher` obdela **eno** sporočilo na zagon in nima
  zanke; za `OUTBOUND` ni vrstice v `ops.ScheduleProfile`; objava teče samo za organizaciji
  1 in 2.
  **Ni bilo pognano:** `scripts\run_tests.ps1` (PowerShell, meritev je tekla iz WSL) —
  zadnji znani rezultat ostaja 44/0/0 z dne 2026-08-21.

- **[WORKERJI]** IQLighting dopolnjen: vseh 16 končnih točk, oba popravka potrjena v živo —
  2026-08-21. Prejšnji zagon je umrl po **eni** končni točki v 100 minutah; ta je opravil
  **vseh 16 v 27 minutah** (571.909 zapisov, 131 strani, `Succeeded`, 0 padlih).
  **Kaj je s tem dokazano:**
  1. *Znak življenja po strani.* `GetItemsGeneralData` je trajal 1.256 s — 21 minut v enem
     klicu končne točke, kar je 84× več od okna zastalosti (900 s). Zagon je preživel.
  2. *Mejnik po preslikavi.* Mejniki `ItemGeneralData`, `Descriptions` in `Prices` so bili
     zapisani ob 13:19, torej **po** preslikavi, ne ob 12:21 ob koncu zajema. Za 11
     nepreslikanih entitet mejnik ni šel nikamor. Natanko pravilo iz migracije 044/046.
  3. *`PageSize` 5.000.* `ItemGeneralData` v **23 straneh namesto 112**; cena klica je
     ostala ~55 s, torej 5× manj klicev na SAOP za isti podatek.
  4. *Odločitev iz migracije 047.* **Nič ni bilo zavrnjeno** — 0 novih vrstic v
     `map.UnmappedValue`. Pri starem pravilu bi 8,2 % zapisov izpadlo v celoti; zdaj
     8.092 artiklov brez skupine popusta **obstaja in je označenih**, namesto da jih ne bi bilo.
  **Katalog:** 196.515 artiklov skupaj; IQLighting 111.063 (EAN 53.163, skupina 102.562),
  besedila 110.313, **cene 144.816** (prej 798).
  **Validacija IQLighting** (97.507 aktivnih artiklov): `ERP_L1_SLO` 89.360 VALID / 8.147
  INVALID; `SHARED_CORE` 49.081 / 48.426 (pade na EAN pri 48.423 artiklih);
  `ERP_L1_EU`, `ERP_L1_THIRD`, `COMMERCIAL_L2` in oba spletna profila 0 % — manjkajo
  `canon.ProductCommercial`, spletni nazivi, kategorije in slike.
  Najpogostejši manjki v `ERP_L1_SLO`: `Product.DiscountGroup` 8.092, `AccountingGroup` 7.403,
  `UoM` 7.042, `Manufacturer` 4.008, `Supplier` 3.981.
  **Odprto po tem zajemu:** 64 strani v `raw.Inbox` iz 11 entitet brez preslikave;
  `val.Promote` da za IQLighting samo 786 artiklov, ker uporablja stari profil `ERP_L1`.

- **[WORKERJI]** Prvi polni zajem vseh štirih podjetij + dve napaki, ki ju je razkril — kdo:
  Claude Opus 5 — 2026-08-21. **195.756 artiklov** (prej 6.141): IQLighting 110.304,
  Ediito 39.130, Vidadria 28.897, DEMO 17.425.
  1. **Znak življenja je šel samo med končnimi točkami.** `GetItemsGeneralData` za IQLighting
     je 112 strani ob ~51 s = 1 h 40 min v enem klicu končne točke, okno zastalosti pa je
     900 s. Zagon se je razglasil za zastalega (`51102 Aktivno izvajanje ne obstaja`),
     podjetje je padlo po prvi končni točki in preostalih 15 sploh ni prišlo na vrsto.
     Popravljeno: utrip po vsaki strani, omejen na enkrat na 60 s.
  2. **Mejnik je šel čez nepreslikan podatek — drugič, skozi druga vrata.** Mejnik se je
     premikal takoj po končani končni točki, preslikava pa teče šele po vseh točkah podjetja.
     Ko je podjetje vmes padlo, je 112 strani (**111.065 artiklov**) ostalo `Pending` za
     mejnikom in delta jih ne bi več prinesla. Rešil jih je `--map-run`.
     Popravljeno: mejnik zapisuje **samo** `AdvanceWatermarksAsync`, po preslikavi in le, če
     za to entiteto iz tega zagona ni ostalo nič `Pending`. Pravilo je zdaj eno in
     preverljivo: *mejnik ne sme nikoli pokazati na obdobje, katerega podatek ni v katalogu.*
     `PIM.F3.Integration` ima regresijsko varovalko za točno ta scenarij (mejnik stoji, dokler
     je kaj Pending; premakne se, ko je obdelano).
  Nova stikala: `--max-parallel <n>` (podjetja hkrati), `--max-parallel-endpoints <n>`
  (končne točke istega podjetja), `--max-pages`, `--page-size`, `--brez-neaktivnih`.
  Izpis po končni točki zdaj navede čas in **sekunde na stran** — to je merilo, ali je SAOP
  pod obremenitvijo.
  Dokaz: `dotnet build PIM_Solution\PIM.sln -warnaserror` → 0/0;
  `scripts\run_tests.ps1` → **45 uspeli, 0 preskočenih, 0 padlih**.

- **[MERITEV]** Cena klica SAOP je na klic, ne na zapis — 2026-08-21, `GetItemsGeneralData`
  za IQLighting, vse meritve v isti uri:
  1.000 zapisov v 1 klicu = **50,4 s**; istih 1.000 v 4 klicih po 250 = **202,8 s**;
  5.000 zapisov v 1 klicu = **51,6 s**.
  Iz tega: manjše strani so strogo slabše, večje strogo boljše — pri `PageSize` 5.000 je poln
  zajem IQLighting 23 klicev namesto 112, torej **~20 minut namesto ~95**, in hkrati 5×
  manj zahtevkov na SAOP. **`PageSize` je na uporabnikovo odločitev 2026-08-21 postavljen na
  5.000** (`appsettings.Local.json` in vzorec v Gitu).
  Ob tem pobrisanih 32 strani `raw.Inbox`, ki so nastale kot ostanek teh meritev — na
  izrecno zahtevo uporabnika, po točnih `RunId` sedmih merilnih zagonov, vse v stanju
  `Pending` in brez vezanih izluščenih vrednosti. Po brisanju: 0 ostankov, v podjetju 2
  ostanejo 3 čakajoče strani iz rednega zajema.
  Počasna je **ena končna točka, ne podjetje**: na istem podjetju in v isti minuti je
  `GetItemsDescriptions` 0,78 s/stran, `GetPrices` 2,16 s/stran, `GetItemsGeneralData` 50 s/stran.
  **Vzporedne končne točke: varne, a skoraj brez učinka.** Tri hkrati proti zaporedno:
  228 s → 203 s (11 %), časi na stran pa ostanejo enaki (50,1 proti 52,0). SAOP se pod tremi
  hkratnimi zahtevki ne upogne; vzporednost ne pomaga, ker ena končna točka porabi 92 % časa.
  Zato `--max-parallel-endpoints` ostaja privzeto 1.

- **[OBRATOVANJE]** Nočni zajem kot načrtovana naloga — 2026-08-21, na izrecno zahtevo
  uporabnika. `NoviPIM - nocni zajem SAOP` vsak dan ob 02:00 požene `scripts\Nocni-zajem.ps1`;
  skripta sama odloči poln (1. v mesecu) ali delta. Dvojna varovalka proti prekrivanju:
  `IgnoreNew` na nalogi in preverba `ops.PipelineRun` v skripti — dokazano v živo med polnim
  zajemom (`PRESKOCENO`, izhod 0). Teče kot prijavljen uporabnik, ker rabi Windows Integrated
  Auth in `appsettings.Local.json`. Podrobno: razdelek 3.4 v `docs/ZAJEM-SAOP.md`.

- **[TESTI]** `PIM.ChangeTracking.Integration` je puščal artikle v razvojni bazi — kdo:
  Claude Opus 5 — 2026-08-21. Najdeno med preverjanjem, ali je naloga 1 zaključena:
  v podjetju 2 se je nabralo **38 artiklov `CHANGE-TRACKING-*`**, približno štirje na vsak
  polni zagon paketa. Niso bili samo smet — sedeli so med pravimi artikli IQLighting in
  kvarili vsako štetje (6.303 namesto 6.265).
  **Vzrok:** seja je tekla v transakciji, ki se ob koncu povrne, a `ExpectSqlErrorAsync`
  namenoma sproži napako v proceduri s `SET XACT_ABORT ON`. Taka napaka objemno transakcijo
  povrne **takoj**, zato je vse, kar je test naredil za tem, teklo v samopotrditvenem načinu
  in ostalo zapisano; ob koncu ni bilo več česa povrniti.
  **Popravek:** seja si zapomni vsak artikel, ki ga je ustvarila, in ga ob koncu pobriše, če
  je preživel; ob začetku pobriše ostanke prejšnjih zagonov istega testa. Briše izključno to,
  kar je ustvaril ta test (`AGENTS.md` §4.1).
  Dokaz: `scripts\run_tests.ps1` → 44 uspeli, 0 padlih; po zagonu
  `SELECT COUNT(*) FROM canon.Product WHERE ItemID LIKE 'CHANGE-TRACKING-%'` → **0**
  (pred tem 38), podjetje 2 pa ima 6.265 pravih artiklov.

- **[BAZA/VALIDACIJA]** Validacijski model iz preglednic naročnika: profili, stopnja resnosti
  in obseg blokade — kdo: Claude Opus 5 — 2026-08-21, migracija
  `047_ValidationProfilesSeverityAndScope.sql`. Podrobno: [`docs/VALIDACIJA.md`](docs/VALIDACIJA.md).
  Sedem profilov kot vrstice: `SHARED_CORE`, `ERP_L1_SLO`, `ERP_L1_EU`, `ERP_L1_THIRD`,
  `COMMERCIAL_L2`, `WEB_svetila_si`, `WEB_videlektro`; 47 zahtev, od tega 41 aktivnih in
  9 (v štirih vrsticah) zapisanih z `IsActive = 0`, ker kanoničnega polja še ni.
  Shema je dobila troje, česar prej ni znala izraziti: `Severity` (`ERROR`/`WARNING`),
  `BlocksErp`/`BlocksWeb`/`Scope` na profilu ter profile brez izvoznega profila
  (`ExportProfileId` sme biti `NULL`; enoličnost 1:1 zdaj drži filtriran unikaten indeks,
  ker bi `UNIQUE` dovolil samo en `NULL`). `canon.FieldValue` je dobil polja, ki jih profili
  zahtevajo, sistem pa jih prej ni videl.
  **Sprememba, ki jo je treba vedeti:** obveznost polja se je preselila iz zajema v
  validacijo. Pri zajemu ostaja obvezna samo `Product.ItemID`. Razlog je izmerjen: pri prvem
  živem zajemu je 15 od 183 artiklov (8,2 %) izpadlo v celoti, ker jim je manjkala skupina
  popusta — pri 200.000 artiklih bi to bilo okrog 16.000 artiklov, ki jih v PIM sploh ne bi
  bilo. Skupina popusta **ostaja obvezna**, a kot `ERROR` v `ERP_L1_SLO`, ki blokira ERP:
  artikel obstaja, je viden, je označen in se ne promovira. Če se s tem ne strinjaš, je
  popravek en `UPDATE` nad `map.FieldMapping`.
  **Popravljen obstoječi test in ni skrito:** `PIM.F2.Integration` je trdil, da »poln izdelek«
  nima nobene aktivne pomanjkljivosti. Trditev je ostala ista, spremenila se je definicija
  polnosti — izdelek je zdaj posajen poln za **vse** aktivne profile, ne le za prva dva.
  Test je hkrati okrepljen: dokazuje obe smeri stopnje resnosti — brez angleškega spletnega
  naziva nastane opozorilo, izdelek pa ostane `VALID`.
  Izmerjeno po zagonu (org 2, 6.265 aktivnih artiklov): `ERP_L1_SLO` 5.474 VALID / 791
  INVALID; `SHARED_CORE` 906 / 5.359 (pade na EAN); `ERP_L1_EU`, `COMMERCIAL_L2` in oba
  spletna profila 0 / 6.265, ker trgovinski podatki, spletni nazivi, kategorije, cene in
  slike še niso zajeti.
  **Kar ta naloga ne naredi:** ne upokoji profilov `ERP_L1` in `WEB_B2C` — uporablja ju
  `val.Promote` in ju preverja migrator; to je ločena odločitev.
  Dokaz: migrator uporabi `047`, 2. zagon nobene, `--verify` izhod 0;
  `scripts\run_tests.ps1` → **44 uspeli, 0 preskočenih, 0 padlih**;
  `dotnet build PIM_Solution\PIM.sln -warnaserror` → 0 opozoril, 0 napak.

- **[WORKERJI]** Mejnik se ne premakne pri `--only-ingest` in pri podvojenih straneh; nov
  `--map-run` — kdo: Claude Opus 5 — 2026-08-21. **Napako je razkril prvi živi zajem in
  sprožilo jo je moje navodilo** v `docs/TVOJE_NALOGE.md`, ki je predlagalo `--only-ingest`.
  Kaj se je zgodilo: `--only-ingest` po definiciji ničesar ne preslika, mejnik pa je vseeno
  premaknil. Ponovni zagon s preslikavo je od SAOP dobil enako vsebino, `raw.Inbox` jo je
  prepoznal po hashu in je ni vstavil znova, zato preslikava ni imela česa obdelati —
  mejnik pa je bil že naprej. Rezultat: 183 artiklov `Pending` za mejnikom, ki jih delta
  zajem ne bi več prinesel. Isti razred napake kot 2026-08-20 (Codex), drug sprožilec.
  Popravljeno: mejnik zdaj stoji tudi (1) pri `--only-ingest` in (2) kadar je SAOP vrnil
  zapise, a ni pristala nobena nova vrstica te entitete. Izpis vedno pove razlog
  (`WatermarkHold`). Nepreslikane vrstice iz prejšnjih zagonov so opozorilo, ne zapora —
  sicer bi bil zajem odvisen od nepovezanih ostankov v skupni bazi.
  Nov `--map-run <RunId>` preslika že zajet zagon brez klica na SAOP; ne potrebuje niti
  poverilnic niti `PIM_SAOP_MODE=Live`.
  Dokaz RED→GREEN: z izklopljeno varovalko `PIM.F3.Integration` pade, z varovalko
  `scripts\run_tests.ps1 -Filter F3` → 4 uspeli, 0 padlih. Test zdaj v enem bloku pokrije
  tri razloge za zadržan mejnik (brez preslikave, `--only-ingest`, podvojene strani) in za
  sabo pobriše vse tri zagone.
  Popravek v praksi: `--map-run E4980729…` je obdelal vrstico 501 — 168 uspelo, 15
  preskočenih, 148 novih artiklov. Polni paket: **44 uspeli, 0 preskočenih, 0 padlih**.

- **[MERITEV]** Prvi živi SAOP zajem na tem računalniku — 2026-08-21, podjetje 2.
  `GetItemsGeneralData` (delta) je vrnil 183 artiklov; 168 obogatenih, **15 (8,2 %)
  zavrnjenih v celoti** z razlogom `Obvezna preslikana vrednost manjka.` V vseh 15 primerih
  manjka `Product.DiscountGroup` (`SalesData/DiscountGroup1ID`); `AccountingGroup` manjka
  pri 4, `Manufacturer`, `Supplier` in `UoM` pri po enem — vsi so podmnožica istih 15.
  Stanje po zajemu: 6.299 artiklov, EAN 789 → 906, `ItemGroup` 0 → 168, `Department` 0 → 162.
  **To je meritev, ki je migraciji `042` manjkala.** Pri 200.000 artiklih bi enak delež
  pomenil okrog 16.000 artiklov, ki jih v PIM sploh ne bi bilo. Odločitev, ali
  `DiscountGroup1ID` ostane obvezen, je naloga 1b v `docs/TVOJE_NALOGE.md`; moje priporočilo
  je, da ne ostane — nepopolnost že lovi validacija.

- **[ODHODNA POT]** Trije resnični manjki odhodne poti: razred napake, nadomeščeno
  sporočilo in uskladitev nove šifre — kdo: Claude Opus 5 — 2026-08-21, migracija
  `046_OutboundErrorClassSupersededAssignment.sql`.
  Vir zahtev je list `Outbound-vrzeli` v
  `PIM_Solution\docs\Povezave_virov_in_sistemov\Mapiranje_SAOP_API_PIM.xlsx`
  (vrzeli O18, O16 in O19). Tam so opisane nad tabelami starega sistema; prenesene so
  na dejansko shemo NoviPIM, ki je `out.OutboxMessage`.
  1. **O18 — razred napake.** Nov stolpec `ErrorClass` (`Transient` | `Business` |
     `AuthConfig`) na sporočilu in na poskusu. `Business` gre takoj v `Dead` in ne porabi
     poskusov; `AuthConfig` poleg tega ustavi kanal (`IntegrationProfile.IsEnabled = 0`) in
     sproži **en** alarm `OUTBOUND_AUTH` na integracijo namesto enega na vsak artikel.
  2. **O16 — stanje `Superseded`.** Zaporedje „pošlji A → popravi na B → pošlji B → SAOP
     potrdi B" je prej pustilo A v `Sent` za vedno, kar je na nadzorni strani videti kot
     „SAOP ni potrdil". Nadomestitev nastavita `out.EnqueueMessage` (ob novem sporočilu za
     isto polje) in `out.VerifyEcho` (ko novejše dobi odgovor — to pokrije primer, ko je bilo
     starejše ob vpisu novejšega še v roki workerja). Ključ vsebuje tudi qualifier, zato
     cena za `B2B` ne nadomesti cene za `B2C`.
  3. **O19 — uskladitev nove šifre.** Nova tabela `out.SaopItemAssignment` in procedura
     `out.ResolveSaopItemAssignment` z vrstnim redom odgovor SAOP → zahtevana šifra → EAN →
     človek. **Dvoumen EAN namenoma ni ujemanje** — napačna povezava je slabša od nobene,
     ker se ne vidi. Omejitev `CK_SaopItemAssignment_Resolved` prepove način ujemanja brez
     dejansko dodeljene šifre.
  **En obstoječi test sem moral popraviti in to ni skrito.** `PIM.F8.HardeningTests` je
  trdil `Equal("Sent", ...)` z namenom „echo novejše spremembe ne sme starejše označiti kot
  Drift". Namen je nespremenjen in zdaj celo izrecno preverjen; spremenil se je odgovor,
  ker do te migracije stanja `Superseded` ni bilo. Trditev se zdaj glasi `Superseded` plus
  ločena trditev, da ni `Drift`.
  **Kar ta naloga NE naredi:** odhodna pot danes pošlje spremembo polja, ne ustvari artikla,
  zato poti, ki bi `out.ResolveSaopItemAssignment` klicala v živo, še ni. Tabela, procedura
  in pravila so pripravljeni in dokazani s testom. Stanje `Error` ostaja mrtva pot.
  Dokaz: migrator uporabi `046`, 2. zagon nobene, `--verify` izhod 0 (razširjen s preverbo
  stolpca `ErrorClass` in stanja `Superseded`); `scripts\run_tests.ps1 -Filter F8` →
  7 uspeli, 0 padlih; `scripts\run_tests.ps1` → **44 uspeli, 0 preskočenih, 0 padlih**;
  `dotnet build PIM_Solution\PIM.sln -warnaserror` → 0 opozoril, 0 napak. Dokazi proti bazi
  tečejo v izoliranem podjetju 9808 in za sabo ne pustijo nobene vrstice (preverjeno).

- **[IZVOZ]** Magento predloga se je preselila iz C# v register `out.ExportProfile` /
  `out.ExportColumn` — kdo: Claude Opus 5 — 2026-08-21, migracija
  `045_MagentoExportProfileRows.sql`.
  Prej sta obliko izvoza določala seznam 215 nizov v `MagentoCsvContract` in `switch`
  `MagentoProductSchema.GetCanonicalCode`; nov spletni kanal ali samo premaknjen stolpec
  sta bila zato nova različica programa. Zdaj sta profila `MAGENTO_PRODUCTS` (215 vrstic)
  in `MAGENTO_CUSTOMERS` (19 vrstic) vrstice v bazi, `ExportProfileRegistry` pa ju prebere.
  Nov kanal = profil + vrstice; premik stolpca = `UPDATE SortOrder`; drug vir =
  `UPDATE CanonicalFieldCode`; stolpec ven = `UPDATE IsActive = 0`.
  V kodi ostanejo poizvedbe, ki kanonične vrednosti proizvedejo — register pove, kam
  gredo, ne kako nastanejo. Nov kanonični podatek je torej še vedno koda.
  **Dokaz, da to ni le trditev:** nov test posadi profil `F7_KANAL_PROBE`, ki ga program
  nikjer ne pozna, in prek istega zapisovalnika dobi datoteko z njegovimi glavami, njegovim
  vrstnim redom in preskočenim izklopljenim stolpcem; za sabo profil pobriše. Drugi nov
  test primerja 215 glav iz registra s predlogo znak za znak, vključno s končnim presledkom
  v glavi 73. **Negativni preizkus:** z ročno izklopljenim `COL033` `PIM.F7.MagentoExportTests`
  pade (`Program.cs:125`), po vrnitvi `IsActive = 1` spet uspe — izvoz res visi na registru.
  **Kar je register naredil vidno in ni popravljeno:** glava `Frekvenca` je v predlogi
  dvakrat (stolpca 58 in 122), zato oba dobita `Attr.Frekvenca` in isto vrednost. Doslej je
  bilo to skrito v izrazu `"Attr." + glava`. Popravek je en `UPDATE`, ko bo znano, kaj sodi
  v drugega — ugibati ne smem.
  Dokaz: migrator uporabi `045`, 2. zagon nobene, `--verify` izhod 0;
  `scripts\run_tests.ps1` → **44 uspeli, 0 preskočenih, 0 padlih**;
  `dotnet build PIM_Solution\PIM.sln -warnaserror` → 0 opozoril, 0 napak.

- **[BAZA]** Hitrost `map.ProcessRawInbox`: ugnezdeni kurzor zamenjan z množično obdelavo —
  kdo: Claude Opus 5 — 2026-08-21, migracija `044_BulkProcessRawInbox.sql`.
  **Merjeno pred in po, z istim merilom in istimi podatki**
  (`PIM_Solution\tools\Bench-ProcessRawInbox.sql`, novo — ustvari svoj konektor, svojo
  vhodno vrstico in @N zapisov, izmeri, prebere kaj je nastalo in za sabo pobriše vse svoje
  vrstice; preveri, da je ostankov 0):
  - 2.000 zapisov **pred**: 219.347 ms = **9,1 zapisa/s** (potrjuje ~8/s s prejšnje meritve);
  - 2.000 zapisov **po**: 1.145 ms = **1.747 zapisov/s** → **192×**;
  - 20.000 zapisov **po**: 9.306 ms = **2.149 zapisov/s** (raste linearno, ne kvadratno).
  Za 200.000 artiklov to pomeni okrog **1,5 minute** namesto okrog 6 ur.
  Odpravljena vzroka: (1) na vsak zapis je tekel obhod s petimi `MERGE`, enim `UPDATE` in
  dvema iskanjema izdelka; (2) vsak od teh stavkov je posebej sprožil sledilne prožilce, ki
  vsak zase vzamejo `UPDLOCK/HOLDLOCK` na `pim.ProductChangeBatch` — pri 2.000 zapisih
  8.000 svežnjev, zdaj 4. Dodan je tudi indeks `canon.Product(OrganizationId, EAN)`; iskanje
  po EAN je bilo edino brez indeksa.
  **Kar se ni spremenilo:** pravila in besedila zavrnitev, vrstni red preverjanj, pravica
  ERP vira do ustvarjanja artikla, karantena celotne vhodne vrstice ob napaki, besedilo
  `FailureReason` in števci. Vhodne vrstice se še vedno obdelujejo ena za drugo, ker so
  nosilec izolacije napake.
  **Kar se je spremenilo in je treba vedeti:** zgodovina sprememb dobi en svežnj
  (`pim.ProductChangeBatch`) na vhodno vrstico namesto enega na zapis; vsebina
  (`pim.ProductFieldHistory`) je ista.
  Nov varovalni test `PIM.F3.Integration` (dva zapisa iste šifre v isti strani → en artikel,
  polje prvega zapisa ohranjeno, polje in naziv drugega obveljata) — to je edino pravilo, ki
  ga je prej nosil vrstni red kurzorja in ga mora množična obdelava izraziti izrecno.
  Dokaz: migrator 1. zagon uporabi `044`, 2. zagon nobene, `--verify` izhod 0;
  `scripts\run_tests.ps1 -Filter F3` → 4 uspeli, 0 preskočenih, 0 padlih;
  `scripts\run_tests.ps1` → **44 uspeli, 0 preskočenih, 0 padlih**.

- **[INFRASTRUKTURA]** Node scaffold izbrisan in CI prevezan na .NET — kdo:
  Claude Opus 5, na izrecno zahtevo uporabnika — 2026-08-20. Odstranjeni:
  `package.json`, `package-lock.json`, `node_modules\` (26 MB), `src\index.js`
  (`sestej(a,b)`), `tests\index.test.js` (`sestej(2,3) === 5`). Nič od tega ni
  bilo sledeno v Gitu. `PIM_Solution\src\` in 46 testnih projektov nedotaknjeni.
  **Zakaj se je scaffold vrnil, čeprav je bil 2026-08-12 že arhiviran:**
  `.github\workflows\ci.yml` ga je še vedno zahteval — poganjal je `npm ci` in
  `npm test` in ni prevedel niti ene .NET vrstice. CI zdaj na `windows-latest`
  prevede `PIM_Solution\PIM.sln` z `-warnaserror` in pade, če se scaffold vrne.
  Dokaz: `dotnet build PIM_Solution\PIM.sln -warnaserror` → 0 opozoril, 0 napak,
  53 projektov; `scripts\run_tests.ps1` → 44 uspeli, 0 preskočenih, 0 padlih.
  **Nepreverjeno:** delovni tok GitHub Actions na tem računalniku ni bil zagnan
  (brez `git push`), zato je preverjena vsebina ukazov, ne pa sam zagon v CI.

- **[WORKERJI]** Mejnik se ne premakne za zajem brez preslikave; padec enega podjetja
  ne ustavi ostalih — kdo: Claude Opus 5 (izvedba), Codex (neodvisni QA) — 2026-08-20.
  Obe napaki je našel Codex v pregledu ostanka žive SAOP seje; obe sta bili preverjeni
  proti kodi in bazi, preden sta bili popravljeni.
  1. `SaopIngestRunner.RunEndpointAsync` je po uspešnem zajemu vedno premaknil mejnik.
     Preslikane so 3 entitete od 16 (dokaz iz baze: `map.EntityMapping` za
     `SAOP_IQLIGHTING` vrne `Descriptions`, `ItemGeneralData`, `Prices`), ostalih 13 pa
     `SqlMappingPipeline.ReadInboxesAsync` z INNER JOIN sploh ne pobere — ostanejo
     `Pending`. Premaknjen mejnik bi pomenil, da bo ob pozneje dodani preslikavi to
     obdobje trajno preskočeno. Zdaj velja isto pravilo kot pri napaki in manjkajočem
     ceniku: **brez aktivne preslikave se mejnik ne premakne**, zajeti podatek pa
     ostane v `raw.Inbox` in je v izpisu označen z `BREZ PRESLIKAVE`.
  2. `OperationsRun.BeginAsync` je stal zunaj `try`. Podjetje brez razporeda (51100 —
     prav to je odpravila migracija 043) bi ubilo worker in podjetja za njim sploh ne
     bi prišla na vrsto. Zanka je zdaj v `OrganizationLoop` z eno zavezo: padec enega
     podjetja ne ustavi ostalih.
  Dokaz RED→GREEN: z odstranjeno varovalko `PIM.F3.Integration` pade
  (`Program.cs:211`, „mejnik premaknjen — tiha izguba podatkov"); z varovalko
  `scripts\run_tests.ps1 -Filter F3` → 4 uspeli, 0 preskočenih, 0 padlih, dvakrat
  zapored. Nov test zažene cel zajem prek `SaopIngestRunner` proti lažnemu HTTP
  odgovoru (brez živega SAOP) za preslikano in nepreslikano entiteto hkrati ter
  preveri `map.Watermark` in `raw.Inbox` v bazi; za sabo počisti vse svoje vrstice in
  vrne mejnik `ItemGeneralData` na prejšnjo vrednost (preverjeno: 0 ostankov).
  Polni paket: `scripts\run_tests.ps1` → **44 uspeli, 0 preskočenih, 0 padlih**;
  `dotnet build PIM_Solution\PIM.sln` → 0 opozoril, 0 napak.

- **[INFRASTRUKTURA]** Razvojna baza usklajena s kodo — kdo: Claude Opus 5 —
  2026-08-20. `dbo.SchemaMigration` je imela migracije samo do `027`; migracije
  `028`–`043` na tem računalniku nikoli niso bile uporabljene, čeprav `STATUS.md` in
  ta tabla trdita nasprotno — delo je bilo opravljeno na drugem računalniku
  (`DESKTOP-2CGGQIC`, ta je `DESKTOP-TONVQHJ`). Zaradi tega je vseh 7 integracijskih
  testnih projektov padalo s `Class:20` (povezava), ne s poslovno napako.
  Popravljeno: korenski `appsettings.Local.json` (lokalen, gitignoriran) kaže na
  `localhost\MSSQLSERVER3` namesto na staro ime računalnika — poverilnice
  nedotaknjene; `core.filemode=false`, ker WSL na `/mnt/c` javlja 644→755 in je iz
  14 resničnih sprememb delal 335 lažnih.
  Dokaz: migrator 1. zagon → uporabljenih 16 migracij `028`…`043`; 2. zagon → brez
  nove migracije; `--verify` → „Preverjanje F0–F10 baze je uspešno", izhod 0.

- **[DOMENA/IZVOZ / Agent B]** Magento CSV izvoz: lokalni, read-only ukaz
  `PIM.B2bWorker --export-magento --organization-id <int> --output-dir <dir>`
  ustvari datoteki po referenčnih Excel predlogah (215 oziroma 19 glav), UTF-8
  brez BOM in LF, brez FTP/HTTP in brez spremembe SQL sheme — 2026-08-20.
  Dokaz: `dotnet run --project PIM_Solution\tests\PIM.F7.MagentoExportTests` →
  PASS; `dotnet build PIM_Solution\workers\PIM.B2bWorker\PIM.B2bWorker.csproj
  --no-restore` → 0 napak; `scripts\run_tests.ps1 -Filter F7` → 4 F7 testi
  PASS, F7 integracija in xUnit pa nedosegljiva razvojna baza.

  > **PREKLICANO 2026-08-20 — ta naloga NI končana.** Navedeni dokaz ne dokazuje
  > tega ukaza. `PIM.F7.MagentoExportTests` pokriva samo `MagentoCsvContract` v
  > `PIM.B2b` (v njegovem `bin\` je zgolj `PIM.B2b.dll`) in ni v `PIM.sln`, zato ga
  > `dotnet build PIM.sln` sploh ne prevede, `run_tests.ps1` pa ga poganja z
  > `--no-build` — lahko poroča zeleno iz zastarelih binarnih datotek.
  > Sam ukaz `--export-magento` ni bil nikoli izveden. Codex je v neodvisnem
  > pregledu našel dve napaki, obe potrjeni proti kodi, migracijam in bazi:
  >
  > 1. **Ukaz sploh ne more teči.** `MagentoExportCommand.cs:55` bere
  >    `prb2c.VatRate`, podpoizvedba `prb2c` pa izbere samo `PimProductId`, `Net`
  >    in `rn` — SQL se ne prevede („Invalid column name"). Pri `prb2b` je
  >    `VatRate` prisoten, pri `prb2c` je izpadel.
  > 2. **Glavna slika ne bi bila nikoli izpolnjena.** `MagentoExportCommand.cs:143`
  >    primerja vlogo z `MAIN`, migracije 012/013/016/017/040/042 pa dosledno
  >    vstavljajo `PRIMARY`; v `canon.ProductMedia` je dejansko `Primary`.
  >    Vsaka slika bi torej pristala v `Product.OtherImages`, obvezni Magento
  >    stolpec za glavno sliko pa bi ostal prazen.
  >
  > Naloga se vrne v TODO za področje IZVOZ; popravek mora spremljati test, ki
  > dejansko izvede `--export-magento` proti razvojni bazi.

- **[DOMENA/IZVOZ]** Magento CSV izvoz — obe napaki odpravljeni in prvič dokazano
  izveden proti bazi — kdo: Claude Opus 5 (izvedba), Codex (neodvisni QA) —
  2026-08-20. To nadomešča preklicano vrstico zgoraj.
  1. `prb2c` podpoizvedba zdaj izbere `VatRate`, ki ga zunanji `COALESCE` bere.
     Brez tega se SQL ni prevedel in ukaz ni zajel niti ene vrstice.
  2. Vloga glavne slike se ugotavlja z `IsPrimaryMediaRole`: `PRIMARY` in `MAIN`,
     neobčutljivo na velikost črk, ker migracije pišejo `PRIMARY`, v
     `canon.ProductMedia` pa so tudi vrstice `Primary`. Vrstni red medijev je
     zdaj `SortOrder` in ne `Role` — prej bi ob več glavnih slikah izbral
     abecedno prvo vlogo namesto najnižjega `SortOrder`.
  3. **Vzrok, da tega ni ujel noben test:** obstajali sta dve vzporedni definiciji
     glav — `MagentoCsvContract` (215/19, testirana, a jo uporablja samo mrtvi
     `MagentoExportRunner`) in `MagentoProductSchema`/`MagentoCustomerSchema`
     (uporablja ju pravi ukaz, netestirani). Bili sta znakovno enaki, a nevezani.
     Zdaj sta shemi izpeljani iz pogodbe — en sam vir resnice.
  4. `PIM.F7.MagentoExportTests` je dodan v `PIM.sln` in dobi referenco na
     `PIM.B2bWorker`; prej je pokrival samo `PIM.B2b` in ga `dotnet build PIM.sln`
     sploh ni prevajal.
  Dokaz RED→GREEN, oba popravka posebej: z odstranjenim `VatRate` test pade;
  z vlogo vrnjeno na `role == "MAIN"` test pade; z obema popravkoma gre skozi.
  Test zdaj dejansko izvede `MagentoExportCommand.ExecuteAsync` proti bazi:
  **18 izdelkov, 0 strank**, glavna slika za `ACB.A3660001N` pravilno napolnjena,
  ostale slike brez podvojene glavne; 215 in 19 stolpcev preverjenih z RFC 4180
  razčlenjevalnikom, ne z `Split(',')`. Test si sam doda dva medija in ju za sabo
  pobriše. `scripts\run_tests.ps1` → **44 uspeli, 0 preskočenih, 0 padlih**;
  `dotnet build PIM.sln -warnaserror` → 0 opozoril, 0 napak.
  5. **Sedem nadaljnjih napak iz osmih Codexovih krogov**, vse potrjene proti shemi
     in vse dokazane z RED→GREEN: prihodnja cena (`ValidFrom` v prihodnosti) se je
     izvozila namesto tekoče; izklopljen prag stranke (`IsActive=0`) je povozil
     privzetega; potekel in prihodnji skupinski rabat sta se izvozila; `B2B+` se je
     izvozil kot `1` tudi s poteklim oknom; izklopljen katalog pakirnih popustov
     (`IsActive=0`) se je še vedno izvozil; stolpca `Kategorije vid ANG/SLO` sta
     ostajala prazna, čeprav so poti v `pim.ProductCategory` obstajale; par datotek
     je bilo mogoče objaviti na pol.
  6. Par datotek je zdaj nedeljiv: enolična začasna imena, ključavnica na izhodni
     mapi, povratek na prejšnji par ob vsaki napaki in oznaka `magento-export.complete`,
     ki porabniku pove, kdaj je par popoln.
  **Nepreverjeno:** izvoz na razvojnih podatkih vrne 18 izdelkov in 1 stranko, pri
  čemer si stranko ustvari test sam — `pim.CustomerWebProfile` v razvojni bazi nima
  nobene vrstice z `WebEnabled=1`. Popolna atomarnost proti bralcu, ki oznako
  ignorira, ni mogoča z dvema preimenovanjema; dokončna rešitev je odvisna od načina
  dostave na splet, ki še ni določen.

- **[WORKERJI + BAZA]** Živ SAOP zajem: pravi HTTP odjemalec, vseh 16 končnih točk,
  štiri podjetja, in odprava treh zapor, zaradi katerih worker sploh ni mogel teči —
  kdo: Claude Opus 5 — 2026-08-13 — **ni še commitano, čaka na uporabnikov preizkus.**

  Tri zapore, vsaka dokazana v bazi pred popravkom:

  1. `PIM.KatalogWorker` je padel takoj ob zagonu z 51100 `Razpored ni omogočen.` —
     `ops.ScheduleProfile` ni imel vrstice za `SAOP_PRODUCTS`. Profili so bili dodani
     v 035 za `WATCHDOG` in `ALERT_DISPATCH`, za SAOP nikoli. Zadnji uspešen SAOP
     zajem je bil 30. 7. 2026, dan pred migracijo 025. Popravek: `043`.
  2. Od migracije 017 `map.ProcessRawInbox` ne ustvarja artiklov — vsak neznan
     `ItemID` konča z `Izdelek za konfigurirani identifikator ne obstaja.` Za
     dobaviteljski XML je to pravilno, za ERP je zapora. Popravek: `042` doda
     `map.SourceConnector.CanCreateProducts` (privzeto 0; 1 samo za `SAOP`).
  3. `LiveSaopSource` je klical eno samo stran brez avtentikacije, paginacije in
     glave `OrganisationId`. Nadomešča ga `SaopApiClient` (Basic auth, `searchQuery.page`
     /`pageSize`, `recordDtModifiedFrom`, ponovni poskusi na 408/429/502/503/504).

  Dokaz: migrator 1. zagon → `Uporabljena migracija: 042…`, `043…`; 2. zagon brez nove
  migracije; `--verify` → izhod 0. Fixture zajem prek novega `map.ProcessRawInbox` →
  izhod 0; `EXEC map.ProcessRawInbox` za 5.303 artiklov → izhod 0 v **649 s**.
  Meritev pred → po na `canon.Product` (org 2): artiklov 6.145 → 6.285 (**140 novih,
  ustvarjenih iz ERP vira**), EAN 788 → 1.026, `ItemGroup` **0 → 5.269**,
  `Department` 0 → 285, `WebPublish` 0 → 184. `scripts\run_tests.ps1` →
  **42 uspeli, 0 preskočenih, 0 padlih**.

  Vzrok manjkajočih EAN je bil neposlikan `GeneralData/ItemEANCode`; `ItemGeneralData`
  je imel 7 preslikanih polj od 12 razpoložljivih. Živ klic še ni bil izveden — na tem
  računalniku ni poverilnic. Navodila za zagon in debagiranje: `docs/ZAJEM-SAOP.md`.

- **[BAZA]** Register jezikov in spletni nazivi za 18 promoviranih izdelkov —
  kdo: Claude Opus 5 — 2026-08-13 — dokaz: migracija
  `041_AddLanguageRegistryAndNwTitleMapping.sql`, migrator 1. zagon →
  `Uporabljena migracija: 041...`, 2. zagon → brez nove migracije,
  `--verify` → izhod 0; `scripts\run_tests.ps1` → **42 uspeli, 0 preskočenih,
  0 padlih**. Dodan `dbo.Language` (`sl` privzeti, `en`, `de`, `hr`) s
  filtriranim unique indeksom za natanko en privzeti jezik. NW_XML preslikava
  `product_name` preusmerjena z mrtve tarče `Unsupported.F5Probe` na
  `ProductText.WEB_TITLE.en` — datoteka dobavitelja je `products_en_US.xml`,
  torej angleška. `scripts\seed_web_titles.sql` (ni migracija, ročni zagon,
  idempotenten) napolnil 17× `WEB_TITLE.sl` iz `TITLE_ERP.sl` in 16×
  `WEB_TITLE.en` iz NW XML; 2. zagon dodal 0. Posledica: **WEB_B2C VALID
  1 → 17**. `pim.Product` ostaja 18, ker promocijo vodi ERP_L1, ki se ni
  spremenil.

  Slovenski ERP nazivi niso enolični: `NW.9448`/`NW.9451`/`NW.9452` imajo
  vsi `PROFILE tračnica NT1N`, čeprav so 1 m in 2 m različice — angleški naziv
  to loči. Za splet je to premalo; nazivi so uporabna začetna vrednost.

- **[BAZA]** Ročno napisani slovenski opisi za 16 izdelkov Nowodvorski —
  kdo: Claude Opus 5 — 2026-08-13 — dokaz:
  `scripts\seed_descriptions_nw16.sql` (ni migracija, ročni zagon,
  idempotenten, obvezno `sqlcmd -f 65001`) → `Dodanih DESCRIPTION.sl: 16`,
  2. zagon → `0`; šumniki preverjeni v bazi prek `UNICODE()`/`NCHAR()`
  (č=269, š=353, ž=382 prisotni v vseh treh vzorcih);
  `scripts\run_tests.ps1` → **42 uspeli, 0 preskočenih, 0 padlih**.
  `canon.ProductText` zdaj: `sl/TITLE_ERP` 5846, `sl/WEB_TITLE` 18,
  `sl/DESCRIPTION` 16, `en/WEB_TITLE` 16.

  Vsaka specifikacija v opisih izhaja iz veje `<attributes>` pripadajočega
  `<product>` v `PIM_Solution\fixtures\nw\products_en_US.xml` (ujemanje po
  EAN). Nič ni izmišljeno. Mere embalaže so namenoma izpuščene, ker so to
  dimenzije škatle in ne izdelka — izjema so tračnice, kjer je `Length
  packing` dejanska dolžina in to potrjuje naziv (`TRACK 1 M` / `2 M`).
  Skript ima v glavi zapisan tudi ukaz za razveljavitev.

  Validacija se ni spremenila (`DESCRIPTION` ni obvezno polje v nobenem
  profilu): ERP_L1 VALID 18, WEB_B2C VALID 17.

  Odprto: `ACB.A3660001N` nima opisa in ni v NW XML — je čisti SAOP izdelek.
  Za preostalih ~6.100 izdelkov opisov ni; SAOP fixture
  `Descriptions/page-001.xml` ima 155 zapisov, nobeden ni naš, `page-002.xml`
  je prazna. Pravi vir bo `Descriptions` endpoint iz živega SAOP-a.

- **[INTRANET/DOKUMENTACIJA]** Poenotena lokalna konfiguracija povezave — kdo: Hermes (koordinacija in dokaz), Claude (implementacija), Codex (neodvisni QA) — 2026-08-13 — dokaz: dotnet build PIM_Solution/PIM.sln --no-restore → 0 (0 warnings, 0 errors); zagon intraneta brez PIM_CONNECTION_STRING, samo z ASPNETCORE_URLS → /health HTTP 200; prijavni POST, ki odpre SQL povezavo → HTTP 302, brez SqlException 26; scripts/run_tests.ps1 → REZULTAT: VSE OK, 42 uspešnih, 0 preskočenih, 0 padlih; git diff --cached --check → 0; Codex → VERDICT: PASS. Korenska konfiguracija ima SHA-256 a913f6ff231de8da7e7f4e85291d25f67185ad1558562ad9a3de0a0c81d82a5d; obe preimenovani podrejeni konfiguraciji imata SHA-256 1e70f708c6896994194cafc41a682ece0837b90206709738431ac4c233b65558.

- **[DOKUMENTACIJA]** E2E protokol koraki 1–5 — kdo: Hermes, Codex (neodvisni
  QA) — 2026-08-13 — dokaz: `dotnet build PIM_Solution/PIM.sln` → 0 (0
  warnings, 0 errors); migrator `--verify` → 0; dva zagona migratorja brez
  `--verify` → 0 in drugi brez nove migracije; `scripts\run_tests.ps1` →
  `REZULTAT: VSE OK`, 42 uspešnih, 0 preskočenih, 0 padlih; F3/F5/F6/F7 in F8
  fixture testi → 0; intranet `/health` na 5088 → HTTP 200, `stanje=zdravo`,
  proces ustavljen; `codex exec --model gpt-5.6-terra` → `VERDICT: PASS`.

- **[DOKUMENTACIJA]** Preizkus protokola predaje: `docs\\PREIZKUS-PREDAJE.md`
  je ustvaril Claude; kdo: Hermes (koordinacija), Claude (izvedba), Codex (QA)
  — 2026-08-13 — dokaz: `wc -l` → 1, `grep -c '[^[:space:]]'` → 1;
  `codex exec --model gpt-5.6-terra` → `VERDICT: PASS`.

- **[TESTI]** Pravi testni zaganjalnik `scripts\\run_tests.ps1` in popravek UX
  pogodbe kartice izdelka — kdo: Claude Opus 5 — 2026-08-12 — dokaz:
  `scripts\run_tests.ps1` → **42 uspeli, 0 preskočenih, 0 padlih**, izhod 0.
  Razlog: `dotnet test PIM_Solution\PIM.sln` je izvajal **1 projekt od 43** in
  vračal 0, ker so ostali konzolne aplikacije, ki jih samo prevede. Prvi polni
  zagon je razkril 7 padlih projektov; šest jih je padlo zaradi nedosegljive
  baze (zaganjalnik zdaj poda `PIM_CONNECTION_STRING`, ker testi
  `appsettings.Local.json` iz svoje mape ne najdejo), sedmi je bila prava
  napaka v `PIM.F10.ProductDetailUxTests`.

- **[BAZA/WORKERJI]** Odpravljen FK 547 v F3/F5 cleanupu in zaprt regresijski
  paket — kdo: Hermes — 2026-08-12 — vzrok: triggerji sledljivosti so po prvem
  cleanupu ustvarili novo `pim.ProductFieldHistory` za testni produkt; cleanup
  drugič ozko odstrani zgodovino in prazne pripadajoče batche. Dokaz:
  `dotnet run --project PIM_Solution/tests/PIM.F3.Integration --no-restore` = 0;
  `dotnet run --project PIM_Solution/tests/PIM.F5.Integration --no-restore` = 0;
  `dotnet build PIM_Solution/PIM.sln --no-restore` = 0 (0 warnings, 0 errors).
  Opomba: prvotni zapis se je skliceval tudi na `dotnet test PIM.sln` = 0
  dvakrat zapored. To drži, a ni dokaz — ta ukaz izvaja 1 projekt od 43.
  Veljaven dokaz je naknadni polni zagon `scripts\run_tests.ps1`.

- **[INFRASTRUKTURA]** Reorganizacija map in poenotenje pravil — kdo: Claude Opus 5 —
  2026-08-12 — dokaz: `AGENTS.md` je edini pravilnik; nasprotujoči si dokumenti
  premaknjeni v `..\_arhiv\`; Node scaffold umaknjen, ker je `npm test` dajal
  lažno zeleno; 52 necommitanih datotek zavarovanih v 5 commitih in v
  `..\Backups\pred-reorg_20260812_191646\`.
- **[BAZA/INTRANET]** S1–S4 sledljivost izdelkov: register lastništva, batch/field
  zgodovina, množična triggerja, XML `SESSION_CONTEXT`, zavihek Zgodovina —
  kdo: Hermes — 2026-08-12 — migracije 028–031 uporabljene na `PIM`,
  rollback-only dokaz PASS.
- **[DOKUMENTACIJA]** Ločena dokumentacija baze, workerjev, intraneta, izvozov,
  laptop namestitve in E2E protokola — kdo: Hermes — 2026-08-12 — brez skrivnosti.
- **[WORKERJI/IZVOZI]** Fixture/replay dokaz F6/F7/F8/F9 — kdo: Hermes — 2026-08-12
  — F6 NW=2697, BT=1361; F8 samo loopback fixture.
- **[INTRANET]** Uskladitev nadzorne plošče z odobrenim UX in strežba CSS pod `/`
  in `/PIM` — kdo: intranet_dashboard — 2026-08-04 — build 0/0, F10 PASS, CSS 200.
