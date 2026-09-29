# Analiza baze PIM: ali je pripravljena za API, ki ga bere AI

Datum: 2026-09-24
Pregledana baza: `DAVID\MSSQL19 / PIM` (lokalna razvojna kopija, migracije do vključno 283, 39 GB).
Intranet v `appsettings.Local.json` kaže na `DESKTOP-TONVQHJ\MSSQLSERVER3`, ki s tega računalnika
ni dosegljiv. **Struktura je enaka kot v produkciji, številke v PRD se lahko razlikujejo** —
preden se kaj od tega odloči, je treba iste poizvedbe (spodaj, razdelek 9) pognati še na PRD.

Pregled je bil samo bralni. Nič v bazi ni bilo spremenjeno.

---

## 0. Odgovor v eni minuti (za direktorja)

**Ne, danes baza ni pripravljena za AI, ki bi delal analitiko prodaje.** Je pa dobro pripravljena
za AI, ki bi delal z **izdelki, cenami, zalogami in pravili**.

| Kaj bi AI rad vedel | Ali je v bazi? | Ocena |
|---|---|---|
| Kaj prodajamo (izdelki, opisi, atributi, slike) | Da, ~197.000 izdelkov v 4 podjetjih | **dobro**, a kakovost podatkov slaba (glej 3) |
| Po kakšni ceni (ceniki B2C, B2B, nabavna) | Da, a samo **trenutna** cena, brez zgodovine | **delno** |
| Koliko imamo na zalogi | Da, posnetki vsakih ~30 min od 31. 7. 2026 | **dobro za trend, slabo za skladišča** |
| Kdo so kupci in kakšne popuste imajo | Da, 11.637 kupcev, 4.315 skupinskih popustov | **delno, s protislovji** |
| **Kaj smo prodali, komu, s kakšno maržo** | **Ne. Tabeli prodaje sta prazni (0 vrstic).** | **manjka v celoti** |
| Kaj se prodaja v spletni trgovini (Magento naročila) | Ne, PIM samo pošilja v Magento, nazaj ne dobi nič | **manjka** |
| Nabava (naročila dobaviteljem) | Samo ViD (633 naročil od 2023) | **delno** |
| Ali so popusti in pravila smiselni | Da, se da preveriti — in našel sem napake (glej 5) | **treba počistiti** |

Največji problem ni API, ampak to, da **PIM ni bil zgrajen kot skladišče podatkov o prodaji**.
Je sistem za pripravo izdelkov. Če direktor želi »vprašaj AI, kaj se prodaja in kje izgubljamo
maržo«, je treba najprej **zajeti prodajo iz SAOP** (fakture, dobropisi, naročila) in iz Magenta
(spletna naročila). Brez tega bo AI odgovarjal samo o katalogu, ne o poslu.

Štiri stvari, ki jih je treba narediti **pred** kakršnimkoli API-jem za AI:

0. **Gesla v GitHubu:** geslo za SAOP in dostopi do dobaviteljev so zapisani v datoteki, ki je
   v repozitoriju na GitHubu. Zamenjati gesla, ne glede na AI (razdelek 7).
1. **Varnost baze:** SQL uporabnik `pim_hermes` (namenjen zunanjemu agentu) ima pravice `db_owner`,
   torej lahko bere gesla, briše tabele in piše v vrsto za SAOP. AI ne sme nikoli dobiti takega
   dostopa. Potreben je ločen uporabnik samo za branje nad posebnimi pogledi.
2. **Prodaja:** zajem prodajnih dokumentov iz SAOP v shemo `sales` (tabele in worker že obstajajo,
   a prodajno naročilo ni bilo nikoli preneseno; in tudi naročila niso fakture — razdelek 7b).
3. **En izračun končne cene:** danes je cena za kupca sestavljena iz 6+ virov (cenik, skupinski
   popust, popust na artikel kupca, S-popust, vrednostni rabat, P2 dodatni popust). Najdenih je
   **202 prekrivajočih se veljavnih popustov z različnim odstotkom** — za istega kupca in isto
   skupino artiklov baza ne pove enoznačno, kateri velja. AI bo tu izračunal napačno.

---

## 1. Kaj je v bazi (popis)

14 shem, ~190 tabel, 12 pogledov, ~400 procedur/funkcij. Vse tabele imajo primarni ključ.

| Shema | Namen | Velikost / vrstice | Uporabno za AI? |
|---|---|---|---|
| `canon` | ERP slika izdelka (kot v SAOP) | 196.634 izdelkov, 301.352 cen, 894.579 tekstov | **Da — glavni vir** |
| `pim` | urejena (»promovirana«) različica izdelka + nastavitve kupcev | 155.933 izdelkov | Da |
| `b2b` | kupci, skupinski popusti, popusti na artikel kupca | 11.637 kupcev | **Da** |
| `stock` | zaloge (SAOP + dobavitelji NW, BT), posnetki | 7,25 mio pozicij, 2.239 posnetkov | Da (agregirano) |
| `purch` | naročila dobaviteljem | 633 glav, 12.927 vrstic (samo ViD) | Delno |
| `sales` | prodajna naročila | **0 vrstic** | **Ne — prazno** |
| `val` | validacija, manjkajoča polja, pripravljenost za splet | 1,87 mio težav | Da (kakovost) |
| `out` | izvozi (Magento, katalog.csv, SAOP vrsta) | 2.279 izvozov | Da (stanje objave) |
| `map` | preslikave virov, surovi izvlečki | 31 mio vrstic (`ExtractedValue`) | **Ne** — tehnično |
| `ops` | opravila, urniki, opozorila, napake | | Samo za nadzor |
| `sec` | uporabniki, vloge, **gesla** | | **Nikoli** |

Podjetja (`dbo.OrganizationConfig`): 1 DEMO (neaktivno), 2 IQ Lighting, 3 Vidadria (ViD), 4 Ediito.
Skoraj vsaka poslovna tabela ima `OrganizationId` — to je dobro, AI API mora biti vedno omejen
na podjetje.

---

## 2. Arhitekturna ocena za API

### Kar je dobro

- **Jasno ločeni sloji:** surovo (`raw`, `map`) → ERP slika (`canon`) → urejeno (`pim`) →
  izvoz (`out`). API za AI bere samo `canon`/`pim`/`b2b`/`stock`, ostalo ga ne zanima.
- **Organizacija je v podatkih**, ne samo v aplikaciji.
- **Zgodovina sprememb izdelkov** (`pim.ProductFieldHistory`, 2,7 mio vrstic od 20. 8. 2026):
  kdo, kdaj, prej/potem. AI lahko odgovori »kdo je spremenil naziv tega artikla«.
- **Zgodovina zalog:** posnetki (`stock.Snapshot`) se ne brišejo — iz njih se da narediti trend
  zaloge in hitrost obračanja (približno, glej 4).
- **Validacija je že v bazi** (`val.ProductIssue`, pogled `val.ProductChannelReadiness`) — AI lahko
  takoj pove »kateri izdelki niso pripravljeni za splet in zakaj«.
- Obstajajo pogledi, ki so skoraj že »API«: `val.ProductChannelReadiness`, `pim.WebShopEligibility`,
  `out.CatalogStock`, `canon.FieldValue`, `canon.CategoryPathTranslated`.

### Kar je slabo (za API in AI)

| # | Težava | Zakaj moti AI |
|---|---|---|
| A1 | **Ni prodajnih podatkov** (`sales.*` prazno, faktur ni nikjer) | Brez tega ni analitike prodaje, marže, ABC analize kupcev, napovedi. |
| A2 | **Cene nimajo zgodovine.** `canon.ProductPrice` hrani samo zadnjo ceno, `ProductFieldHistory` cen ne beleži. | AI ne more odgovoriti »kdaj smo dvignili ceno« ali »kakšna je bila cena ob prodaji«. |
| A3 | **Ni enega izračuna končne cene za kupca** | Vsak odjemalec (izvoz, intranet, AI) bi računal po svoje → različni odgovori. |
| A4 | **Zaloga nima skladišča** — `stock.Position` nima stolpca skladišče; skladišča so skrita v URL-ju klica (`warehouseIdList=0000001,0000002,…`) | AI ne more reči »koliko je v Rakovniku in koliko na Brnčičevi«. |
| A5 | **Ni globalnega ključa izdelka.** Ista šifra je v več podjetjih 45.358-krat, a vsako podjetje ima svoj `ProductId`. | »Koliko skupaj prodamo artikla X v vseh podjetjih« zahteva ročno vezavo po šifri. |
| A6 | **Šifranti kodni, brez pomena.** Ceniki `PRC`, `KAR`, `LOM`, `ACB`, `BTT`, `IDE`, `EGL`, tip kupca `O/K/D` … nikjer v bazi ni zapisano, kaj pomenijo. | AI ugiba. Treba je dodati opisni šifrant (to je ena tabela in eno popoldne dela). |
| A7 | **Dva modela tipa kupca** — `b2b.Customer.CustomerType` (O/K/D iz SAOP) in `pim.CustomerWebProfile.CustomerTypeCode` (INSTALLER, RESELLER …) | Ni jasno, katerega uporabiti za segmentacijo. |
| A8 | **Ni pogledov za analitiko, ni columnstore indeksov** | Vprašanje »zaloga po skupinah artiklov čez 2 meseca« bo na 7 mio vrsticah počasno in bo motilo nočne izvoze. |
| A9 | **Velike tehnične tabele** (`map.ExtractedValue` 5,6 GB, `stock.LandingRecord` 4,5 GB) brez politike brisanja | Baza raste, AI jih ne rabi. |

---

## 3. Kakovost podatkov o izdelkih (kar bi AI videl)

| Podjetje | Aktivnih izdelkov | Brez EAN | Brez kategorije | Brez nabavne cene | Brez aktivne cene | Validacija VELJAVNO |
|---|---:|---:|---:|---:|---:|---:|
| IQ Lighting (2) | 98.289 | 40.320 (45 %) | 95.917 (98 %) | 81.501 (83 %) | 18.883 | 5.479 (6 %) |
| Vidadria (3) | 22.700 | 5.035 | 20.114 (89 %) | 15.422 (68 %) | 3.821 | 6.728 (30 %) |
| Ediito (4) | 39.155 | 2.288 | 39.154 (100 %) | 35.926 (92 %) | 848 | 2.037 (5 %) |

(EAN in cena iz `pim.Product`/`pim.ProductPrice`, kategorija, nabavna cena in validacija iz `canon`.)

Kritično:

- **Kategorij praktično ni** (v `canon.ProductCategory`). Vsaka analiza »po kategorijah« bo
  prazna. Za analitiko je treba uporabiti SAOP `ItemGroup` / `DiscountGroup` (izpolnjeno pri ~92 %).
- **Isti EAN 9008606274475 ima 423 različnih artiklov** v IQ Lighting; skupaj 391 EAN-ov se
  ponavlja. To je zamašek (izmišljen EAN) ali napaka v SAOP. AI, ki išče po EAN, bo vrnil napačen
  artikel.
- **1,56 mio odprtih težav »manjka obvezno polje«.** Validacija je v tej bazi označena kot
  zastarela pri vseh izdelkih (`IsValidationStale`), zato je `IsWebReady` povsod 0, čeprav je v
  katalogu 2.536 artiklov IQ. Na PRD preveriti; če je tam enako, pogled pripravljenosti laže.
- **679 izdelkov ima v istem ceniku več aktivnih cen hkrati** — katera velja, ni določeno.
- **Nabavna cena (NAB) pokriva samo 17 % izdelkov IQ Lighting.** Marže za preostalih 83 % ni
  mogoče izračunati. In NAB je *cenik* nabavne cene, ne dejanska nabavna cena z odvisnimi stroški.

---

## 4. Zaloge

- Viri: SAOP za vsako podjetje (vsakih ~30 min) + datoteke dobaviteljev NW in BT.
- Posnetki od 31. 7. 2026; zadnji danes 07:58. Na tem stroju so luknje (IQ SAOP samo 12 dni s
  posnetki), ker stroj ne teče stalno — na PRD bo zgodovina polnejša.
- IQ Lighting SAOP: 8.776 pozicij, **samo 936 z zalogo > 0**; nobena nima izpolnjene
  »razpoložljive količine« (`AvailableQuantity` = NULL povsod razen ViD). Za B2B je bistveno
  *razpoložljivo* (zaloga − rezervirano), ne fizična zaloga.
- Dobaviteljske zaloge se ne ujemajo z izdelki: BT_STOCK v IQ ima 1.174 od 1.389 pozicij brez
  izdelka, NW_STOCK v Ediito 2.619 od 2.749. Tega AI ne sme šteti kot »našo zalogo«.
- Sestava zaloge za splet (`out.ExportStockSource`) je dobro dokumentirana: npr. ViD zaloga =
  Rakovnik (BASE) + IQ Brnčičeva (ADD) + NW (SUPPLIER). To je pravilen vzorec in ga mora
  AI API uporabljati, ne pa sešteti vsega.

---

## 5. Kupci, ceniki in popusti — ali so pravila nastavljena dobro?

**Kratko: ne povsem. Našel sem konkretna protislovja.**

### Kupci (`b2b.Customer`)

| Podjetje | Kupcev | Aktivnih | Brez cenika | Brez popustnega cenika | Brez referenta |
|---|---:|---:|---:|---:|---:|
| IQ Lighting | 4.729 | 3.988 | 4.474 | 4.728 | 1.006 |
| Vidadria | 4.676 | **395** | 2.282 | 2.826 | 1.932 |
| Ediito | 618 | 4 | 614 | 617 | 141 |

- **ViD ima samo 395 aktivnih od 4.676 kupcev** — ali je zajem kupcev pravilen ali je večina
  res neaktivnih? Preveriti s SAOP.
- `RebatePercent` (rabat) je 0 pri vseh kupcih, `IsDefaulter` (dolžnik) 0 pri vseh. Ta polja
  torej **niso zajeta**, ne pa res prazna. AI bi napačno sklepal »nihče ni dolžnik«.
- `PaymentDays`, `IsDefaulter`, `UpfrontPayment` bi bili zlata vredni za B2B tveganje — treba
  jih je dejansko zajeti iz SAOP.

### Skupinski popusti (`b2b.CustomerItemGroupDiscount`) — ViD

- 4.300 pravil, 189 skupin kupcev, 35 skupin artiklov.
- **1.265 pravil je poteklo** in še vedno leži v tabeli (to je v redu za zgodovino, a API mora
  vedno filtrirati po datumu).
- **202 para veljavnih pravil za isto skupino kupca + skupino artiklov + količino z RAZLIČNIM
  odstotkom.** Kateri velja? Baza ne pove. To je treba počistiti v SAOP ali določiti pravilo
  prednosti (najnovejši `ValidFrom`).
- **86 pravil ≥ 50 %**, npr. skupine `VD7` in `BA` z 50 % za 10+ kupcev, brez datuma poteka.
  Mogoče pravilno (projektne cene), a to je točno tisto, kar mora direktor pregledati.
- **151 aktivnih kupcev ViD ima nastavljen popustni cenik, za katerega ni nobenega pravila**
  (npr. 62 kupcev ima kot popustni cenik vpisano »B2C«). Ti kupci na B2B dobijo 0 % popusta,
  čeprav je bil namen očitno drugačen.

### Popusti na artikel kupca (`b2b.CustomerItem`)

- ViD 5.237 vrstic, max popust **66,5 %**; IQ 3.963 vrstic, max 37 %.

### Marža — preverjeno za ViD (7.027 izdelkov, ki imajo B2B in NAB ceno)

| Preverba | Število izdelkov |
|---|---:|
| B2B cena je **pod nabavno** že brez popusta | **21** |
| B2C cena pod nabavno | 1 |
| Po največjem veljavnem skupinskem popustu cena **pod nabavno** | **29** |
| Po največjem popustu marža pod 5 % | **63** |

To je prvi konkreten rezultat, ki ga AI lahko prinese direktorju — in točno tako bi moral API
delovati: »pokaži mi artikle, kjer ob najboljšem popustu prodajamo z izgubo«.

### S-popusti, vrednostni rabati, P2

- `b2b.PackagingDiscountRule` (S-popusti, 274): 32 pravil, **vsa neaktivna** — to so testna
  pravila; v živo ni nastavljeno nič.
- `pim.PackagingDiscountCatalog`: S1 3 %, S2 5 %, S3 10 %, S4 15 %; dodeljen 216 izdelkom.
- `pim.ValueDiscountTier` (vrednostni rabat): 800 € → 1 %, 1.500 € → 2 %, 3.000 € → 3 %.
- `b2b.CustomerExtraGroupDiscount` (P2, 279): **0 vrstic** — ni zajeto ali ni v uporabi.
- `b2b.GroupDiscount`, `GroupDiscountOverride`: 0 vrstic — mrtvi tabeli.
- IQ Lighting nima lastnega cenika B2B; B2B cena se jemlje iz ViD. Za AI je to past:
  »B2B cena IQ« je v resnici podatek drugega podjetja.

---

## 6. B2B in B2C trgovina — kaj ima in kaj rabi

| Rabi trgovina | Stanje v PIM |
|---|---|
| Izdelki, teksti, slike, atributi | Da (Magento izvoz 89.491 × 180 stolpcev) |
| Kategorije po spletnih mestih | 4 spletna mesta (svetila.si, videlektro, SL/EN); kategorije pokrite slabo |
| Cena B2C | Da |
| Cena za B2B kupca (cenik + popusti) | Izvaža se (`stranke.csv`), a iz več virov, s protislovji (5) |
| Zaloga za splet | Da, s pravili virov (`out.ExportStockSource`) |
| **Naročila iz trgovine nazaj** | **Ne** — PIM ne ve, kaj je bilo prodano na spletu |
| **Iskalni izrazi, ogledi, košarice** | **Ne** (to je v Magento/Google Analytics) |
| Vračila, reklamacije | Ne |

---

## 7. Varnost — kaj mora biti urejeno, preden AI dobi dostop

**Najresnejša najdba, ni povezana z AI, ampak je treba urediti takoj:**
datoteka `appsettings.Local.json` v korenu repozitorija je **v gitu** (od 10. 9. 2026, čeprav je v
`.gitignore`), repozitorij je na GitHubu (`VidadriaITadmin/PIM`). V njej so **uporabniško ime in
geslo za SAOP**, geslo za NW zalogo ter povezave do BT/NW katalogov z vdelanimi žetoni. Gesla je
treba **zamenjati** (samo odstranitev iz gita ne zadostuje — ostanejo v zgodovini) in datoteko
odstraniti iz sledenja.

Ostalo:

- **Obstoječega API-ja ni.** Intranet ima samo prijavo s piškotkom in prenose Excel/CSV
  (`/izvoz/*`). Ni API ključev, ni žetonov. Vse za AI je treba zgraditi na novo.
- `pim_hermes` = **db_owner** (tudi `docs/SSMS_PIM_PROVISIONING.md` ga tako nastavlja na PIM;
  na PIM_test je samo bralec). Takoj znižati.
- `IIS APPPOOL\PIM_dev_app` = db_owner (razvojni, sprejemljivo lokalno, ne na PRD).
- **Omejitev na podjetje ni vezana na uporabnika.** Izbrano podjetje je samo piškotek
  (`pim_organizacija`), vsak prijavljen uporabnik lahko izbere katerokoli podjetje. V bazi ni
  »row-level security«. Za AI API to ne gre: ključ agenta mora biti vezan na dovoljena podjetja,
  filter pa že v SQL.
- `sec.LocalUser` hrani zgoščena gesla — AI uporabnik mora imeti izrecno `DENY` na shemo `sec`.

## 7b. Zakaj je prodaja prazna (iz kode)

- Zajem obstaja: `workers/PIM.SaopOrdersWorker` kliče SAOP `api/Order/GetOrderStatus` →
  `GetOrder/{leto}/{knjiga}/{št}` za prodajo (knjiga VNK) in enako za nabavo (VND); prvi zajem
  gre 24 mesecev nazaj; teče na uro.
- V `raw.Inbox` je **638 nabavnih naročil in 0 prodajnih.** Prodajni del se torej nikoli ni
  uspešno izvedel. Verjetni vzroki (po `docs/DATABASE.md`): SAOP servisni račun nima pravic za
  modul Naročila, ali pa podjetja brez nastavljene knjige so bila tiho preskočena (popravljeno
  23. 9. v kodi, morda še ne nameščeno).
- **Tudi ko bo delovalo, so to naročila, ne fakture.** Med 16 SAOP klici, ki jih PIM uporablja
  (`docs/ZAJEM-SAOP.md`), ni nobenega za fakture ali dobropise. Naročilo ≠ prodaja: ni vračil,
  ni dejanske fakturirane cene, ni nabavne vrednosti ob prodaji. Za pravo analitiko prodaje je
  treba pri SAOP pridobiti dostop do izdanih računov.
- Dokumentacija sama to prizna: »zgodovinskih analitičnih modelov še ni« in operativnih tabel se
  ne sme uporabljati kot zgodovine (`docs/PRODUKTNI_MODEL_PIM.md`, `docs/SISTEM_PIM.md`).

## 7c. Kje se danes izračuna končna cena kupca (iz kode)

- Skupinski popust + P2: funkcija `b2b.CustomerGroupDiscounts(@Today)` (migracija 279), P2 se
  nalaga kot `100 − (100 − osnovni)(100 − dodatni)/100`; ročni popust kupca prevlada, ročnih 0 %
  namerno povozi SAOP.
- S-popusti: `b2b.PackagingDiscountSpecials(@Org,@Date)` (274) — najbolj specifično pravilo zmaga.
- Vrednostni rabat in 2 % B2B splet: samo v C# `src/PIM.B2b/DiscountCalculator.cs` (`Cascade`),
  ki ga **kliče samo test**. V živo popuste uporabi **Magento** iz `katalog.csv`/`stranke.csv`.
- Posledica: **v PIM nikjer ne obstaja odgovor »koliko kupec X plača za artikel Y«.** To ve samo
  Magento, in to samo za splet. AI API mora dobiti SQL funkcijo `ai.CenaZaKupca`, ki je
  preverjena proti izračunu v Magentu, sicer bo AI in trgovina kazala različne cene.
- Obstoječi preverbi marže v validaciji: `FAKTOR_MARZE` (prag 2,00) in `CENA_POD_NABAVNO`
  (`131_BusinessChecks.sql`) — torej sistem že ve, da je 21 izdelkov ViD pod nabavno; nekdo
  mora opozorila tudi brati.

---

## 8. Priporočilo: kako zgraditi AI API (v zaporedju)

### Faza 0 — varnost (1 dan)
- Nova vloga `pim_ai_reader`: `GRANT SELECT` samo na shemo `ai` (nova), `DENY` na `sec`, `ops`,
  `map`, `raw`. `pim_hermes` odstraniti iz `db_owner`.

### Faza 1 — pogledi `ai.*` nad obstoječimi podatki (3–5 dni)
Ena plast pogledov, stabilnih, z lepimi slovenskimi/angleškimi imeni stolpcev in opisi (AI bere
opise!). Vsak ima `OrganizationId`.

| Pogled | Vsebina |
|---|---|
| `ai.Izdelek` | šifra, naziv, EAN, proizvajalec, dobavitelj, skupina, popustna skupina, aktiven, na spletu, pripravljenost |
| `ai.CenaTrenutna` | izdelek × cenik z **opisom cenika**, samo ena veljavna cena |
| `ai.ZalogaTrenutna` | lastna zaloga, razpoložljivo, dobaviteljska zaloga ločeno |
| `ai.ZalogaDnevno` | en posnetek na dan na izdelek (iz 7 mio vrstic naredi ~dnevni povzetek) |
| `ai.Kupec` | kupec, tip (en model!), referent, cenik, popustni cenik, plačilni rok |
| `ai.PopustVeljaven` | vsa veljavna pravila popustov na enem mestu, z virom (skupinski / artikel / S / vrednostni) |
| `ai.CenaZaKupca` (funkcija) | **končna neto cena za kupca X, artikel Y, količino Z** + razčlenitev |
| `ai.TezavaPodatkov` | odprte težave validacije po izdelku |
| `ai.Sifrant` | pomen vseh kod (ceniki, tipi kupcev, skupine) |

### Faza 2 — prodaja (največ dela, največ vrednosti; 2–3 tedne)
- Zajem **faktur in dobropisov** iz SAOP (ne samo naročil) v `sales.*`: datum, kupec, artikel,
  količina, neto, popust, **nabavna vrednost ob prodaji** (za maržo), referent, skladišče.
- Zajem **Magento naročil** (B2C) v isto shemo z oznako kanala.
- **Zgodovina cen**: tabela veljavnosti (od–do) za vsako spremembo cene.
- Columnstore indeks na prodajnih vrsticah → analitika v sekundah.

### Faza 3 — API (1 teden)
- Samo bralni HTTP API (ali MCP strežnik, ki ga AI kliče neposredno), nad pogledi `ai.*`.
- Ključ po uporabniku/agentu, vsak klic zabeležen (kdo, kaj, koliko vrstic).
- Omejitve: max vrstic na klic, časovna omejitev poizvedbe, nikoli med nočnim izvozom.
- **Nobenega pisanja.** Če bo AI kdaj predlagal spremembe cen/popustov, gredo v obstoječo vrsto
  z odobritvijo, tako kot SAOP.

### Faza 4 — AI preverjanja pravil (sprotno)
Poizvedbe iz razdelka 5 postanejo stalna opozorila (`ops.Alert`):
prodaja pod nabavno, prekrivajoči se popusti, kupci s popustnim cenikom brez pravil,
popusti ≥ 50 % brez datuma poteka, podvojeni EAN.

---

## 9. Poizvedbe za ponovitev na PRD

```sql
-- prodaja: ali je karkoli?
SELECT COUNT(*) FROM sales.OrderHeader; SELECT COUNT(*) FROM sales.OrderLine;

-- prekrivajoči se veljavni skupinski popusti z različnim %
SELECT COUNT(*) FROM b2b.CustomerItemGroupDiscount a
JOIN b2b.CustomerItemGroupDiscount b ON a.OrganizationId=b.OrganizationId
 AND a.CustomerGroupCode=b.CustomerGroupCode AND a.ItemGroupCode=b.ItemGroupCode
 AND a.MinQuantity=b.MinQuantity AND a.CustomerItemGroupDiscountId<b.CustomerItemGroupDiscountId
 AND ISNULL(a.ValidTo,'9999-12-31')>=GETDATE() AND ISNULL(b.ValidTo,'9999-12-31')>=GETDATE()
 AND a.DiscountPercent<>b.DiscountPercent;

-- aktivni kupci s popustnim cenikom brez pravil
SELECT OrganizationId, COUNT(*) FROM b2b.Customer c
WHERE IsActive=1 AND DiscountPriceListCode<>'' AND NOT EXISTS(
  SELECT 1 FROM b2b.CustomerItemGroupDiscount d
  WHERE d.OrganizationId=c.OrganizationId AND d.CustomerGroupCode=c.DiscountPriceListCode)
GROUP BY OrganizationId;

-- ViD: cena po največjem popustu pod nabavno
WITH d AS (SELECT ItemGroupCode, MAX(DiscountPercent) maxP FROM b2b.CustomerItemGroupDiscount
  WHERE OrganizationId=3 AND ValidFrom<=GETDATE() AND ISNULL(ValidTo,'9999-12-31')>=GETDATE()
  GROUP BY ItemGroupCode),
pr AS (SELECT cp.ProductId, cp.ItemID, cp.ItemGroup,
  b2b=(SELECT MAX(Net) FROM canon.ProductPrice x WHERE x.ProductId=cp.ProductId AND x.PriceList='B2B' AND x.IsActive=1),
  nab=(SELECT MAX(Net) FROM canon.ProductPrice x WHERE x.ProductId=cp.ProductId AND x.PriceList='NAB' AND x.IsActive=1)
  FROM canon.Product cp WHERE cp.OrganizationId=3 AND cp.IsActive=1)
SELECT pr.ItemID, pr.ItemGroup, pr.b2b, pr.nab, d.maxP, pr.b2b*(1-d.maxP/100) po_popustu
FROM pr JOIN d ON d.ItemGroupCode=pr.ItemGroup
WHERE pr.nab>0 AND pr.b2b>0 AND pr.b2b*(1-d.maxP/100) < pr.nab ORDER BY pr.ItemID;

-- podvojeni EAN
SELECT OrganizationId, EAN, COUNT(*) n FROM pim.Product WHERE EAN<>''
GROUP BY OrganizationId, EAN HAVING COUNT(*)>1 ORDER BY n DESC;

-- pravice zunanjih uporabnikov
SELECT m.name, r.name FROM sys.database_role_members rm
JOIN sys.database_principals r ON r.principal_id=rm.role_principal_id
JOIN sys.database_principals m ON m.principal_id=rm.member_principal_id;
```
