# Intranet aplikacija PIM — celovit načrt izgleda in sestave

Verzija: 1.0 · Datum: 2026-08-26 · Status: referenčni dokument za (re)gradnjo intranet aplikacije

## 0. Namen in viri tega dokumenta

Ta dokument pove, **kako naj bo sestavljena intranet aplikacija PIM** — vizualno, navigacijsko in po
sklopih — da se lahko preda novemu sistemu/razvijalcu kot enotno vodilo. Ne podvaja poslovnih pravil
(ta so v [`_SPEC/PIM_SISTEM_MENI_Master_Specifikacija.txt`](../../_SPEC/PIM_SISTEM_MENI_Master_Specifikacija.txt)),
ampak pove, kako naj bodo predstavljena in kako naj bo aplikacija sestavljena.

Sestavljen je iz treh virov:
1. **Potrjena vizualna zasnova** — maketa v [`UX_pictures/`](../../UX_pictures/) (Nadzorna_plosca, Izdelki,
   Osebna_izkaznica_izdelka, Kakovost, Mediji, Stranke, Partnerji, Zaloga, Cene_in_ceniki, uvozi,
   uvozi_izvozi, nastavitve_kataloga) in HTML makete v [`docs/PIM_OS_Mockup/`](../PIM_OS_Mockup/). To je
   izgled, ki je uporabniku **všeč** in naj postane ciljni izgled — v nasprotju s trenutno postavitvijo
   navigacije, ki ni všeč.
2. **Arhitekturna pravila in stanje repozitorija** iz master specifikacije (poglavje K — Intranet
   aplikacija, in pravila 2.1–2.7).
3. **Vsa dogovorjena funkcionalnost** iz razvoja sistema (jun–avg 2026) — kaj je bilo zahtevano, zakaj,
   in kako je (ali naj bi bilo) rešeno.

---

## 1. Vizualna zasnova (design system)

Referenca: maketa v `UX_pictures/`. Ključne značilnosti, ki jih mora vsaka stran spoštovati:

- **Postavitev**: ozka temna leva navigacija (~200 px, skoraj črna/temno grafitna), z oranžno znamko
  ("P") na vrhu. Vsebinsko polje je svetlo/belo. Meni se da skrčiti ("Skrči meni") na samo ikone.
- **Zgornja vrstica** (nad vsebino, ne del levega menija): eno samo globalno iskalno polje ("Poišči
  izdelke, EAN, nazive …"), nato trije globalni kontekstni izbirniki — **Organizacija**, **Kanal /
  spletna stran**, **Jezik** — nato zvonec z obvestili (števec) in uporabniški meni spodaj levo v meniju.
  Ti trije izbirniki veljajo za CELO aplikacijo (glej razdelek 3).
- **Glava strani**: naslov + en stavek namena strani, na desni en primaren gumb akcije (npr.
  "+ Nov izdelek", "+ Nov uvoz") + gumb "…" za redkeje uporabljene akcije. Brez drobtinic na seznamskih
  straneh — drobtinica se pojavi šele na podstraneh (npr. `Izdelki › AZ_0002`).
- **Zavihki po STANJU**: kjer ima entiteta življenjski cikel (izdelki, mediji, stranke, partnerji,
  kakovost, uvozi/izvozi), je prva vrsta pod naslovom niz zavihkov, ki loči po statusu (npr. Vsi izdelki /
  Za urediti / Pripravljeni / Objavljeni / Arhivirani), vsak s števcem v oklepaju. To je isto načelo, ki
  je že potrjeno in izvedeno na `/products` ("zavihki = status") — velja naj dosledno povsod.
- **KPI kartice**: vrstica 3–5 okroglih ikon-kartic s številko in trendom puščice (npr. "Skupaj izdelkov
  12.480 · +134 ta teden"). Na nadzorni plošči, na Kakovosti, Uvozih, Zalogi — povsod, kjer je koristen
  en pogled "kje smo, kaj se je spremenilo".
- **Filtrirna vrstica**: iskalno polje + gumb "Filtri" (odpre panel z več polji naenkrat) + **aktivni
  filtri kot odstranljivi čipi** (npr. "Proizvajalec: Braytron ✕") + "Počisti vse". Pod tem po potrebi
  vrstica **hitrih štetnih čipov/značk** (npr. "Napake 346", "Brez slike 64", "Brez kategorije 41") —
  to so bližnjice do pogostih podmnožic, NE podvojitev iste izbire v filtrskem panelu (glej načelo v
  razdelku 5).
- **Tabela**: checkbox stolpec za množične akcije, sličica (kjer relevantno), ključni identifikatorji,
  status kot **barvna značka** (zelena = veljavno/OK, rdeča = napaka, oranžna = opozorilo, siva =
  neaktivno/neznano), stolpec popolnosti kot mini vrstica napredka z odstotkom, datum zadnje spremembe,
  na koncu "…" akcije po vrstici. Nad tabelo desno: izbirnik pogleda (moj/privzeti pogled), izbirnik
  stolpcev, gumb Izvozi. Paginacija spodaj z izbiro števila vrstic na stran.
- **Kartica/detajl entitete**: na vrhu naslov + identifikatorji, vrstica statusnih kartic **po kanalu**
  (ERP / Komerciala / Splet), kartica Popolnost z odstotkom, nato zavihki (Pregled / ERP / Komerciala /
  Splet po straneh / Atributi / Kategorije / Mediji / Cene / Zaloga / Zgodovina). Glavni prostor je
  obrazec, ozek desni stolpec je kontekstna kartica "Napake in opozorila" za trenutni pogled.
- **Barve stanja** (dosledno povsod, ista paleta na značkah/karticah/vrsticah): zelena = v redu/veljavno,
  rdeča = napaka/blokira, oranžna/rumena = opozorilo (ne blokira), modra = informativno, siva =
  neaktivno/ni podatka.
- **Nedokončana funkcionalnost ostane vidna, a označena.** Stran, ki še ni pripravljena, se v meniju ne
  skriva — pove jasno "ta del še ni na voljo" (obstoječ vzorec placeholder strani), namesto da izgine
  brez sledu ali vrže napako.

---

## 2. Navigacijski sistem

Levi meni ima dve ravni gostote:
- **Neposredne povezave** — klik takoj odpre stran (moduli brez podstrani ali najpogosteje obiskani).
- **Skupine s podpanelom** — klik odpre stranski panel s podpostavkami (moduli, sestavljeni iz več
  povezanih strani).

### 2.1 Osnovna razporeditev

Glavni sklop (od zgoraj navzdol):

1. **Nadzorna plošča** — neposredna povezava; začetna stran po prijavi.
2. **Izdelki** — neposredna povezava; glavno delovno mesto uporabnika.
3. **Mediji** — neposredna povezava.
4. **Stranke** — register + B2B profili (neposredna povezava).
5. **Partnerji** — dobavitelji/proizvajalci kot viri kataloga (ločeno od Strank, razdelek 4.6).
6. **Zaloga** — pregled zaloge / dobavni roki / težave (skupina s podpaneli).
7. **Cene in ceniki** — cene izdelkov / ceniki / posebne cene (skupina s podpaneli).
8. **Kakovost** — pregled kakovosti / napake / karantena (skupina s podpaneli).
9. **Uvozi** — hub-stran: viri / novi izdelki / Excel / zgodovina (skupina s podpaneli).
10. **Izvozi** — hub-stran: SAOP / splet (CSV) / Magento / zgodovina (skupina s podpaneli).

Ločeno, pod naslovom **Nastavitve**:

11. **Nastavitve kataloga** — atributi, kategorije, preslikave, spletni kanali, jeziki in prevodi,
    referenčni podatki (vse kot podpaneli ene skupine, glej maketo `nastavitve_kataloga.png`).
12. **Pravila** — validacijska pravila po profilih, B2B pravila, integracijski profili po viru/proizvajalcu.

Ločeno, pod naslovom **Administracija** (samo Admin/ITAdmin):

13. **Sistem** — uporabniki in vloge, integracije/endpointi, dnevnik dejavnosti (audit), tehnični
    zemljevid, status/zdravje sistema (nadzornik molka).

### 2.2 Načela, ki jih navigacija mora spoštovati

- **En koncept = eno mesto.** Če zavihek ali značka že pokriva neko stanje, se isto stanje ne ponavlja
  še kot ločena vrednost v spustnem seznamu drugje (potrjeno pravilo, glej razdelek 5).
- **Vloge omejujejo VIDNOST, ne le dostop.** Kdor nima pravice do modula, ga v meniju sploh ne vidi —
  ne vidi sivega/onemogočenega elementa.
- **Kontekstni izbirniki (Organizacija/Kanal/Jezik) se prikažejo samo tam, kjer imajo pomen** — na
  čisto administrativnih/sistemskih straneh jih ni.
- **Brez dvojnih poti do istega rezultata.** Ena stran = en jasen namen. Če nastane nov način za isto
  stvar, se stari ukine ali preusmeri — ne ostaneta vzporedno.
- **Stare poti se preusmerijo**, ne izginejo brez sledu — uporabnik s starim zaznamkom pristane na
  pravem mestu, ne na napaki 404.
- **Poimenovanje je razumljivo, ne tehnično.** "Za urediti", "Pripravljeni", "Objavljeni" namesto
  "PENDING/PARTIAL/VALID" — tehnični izraz sme ostati v oklepaju ali tooltipu za administratorja.

---

## 3. Globalni kontekst — Organizacija / Kanal / Jezik

Trije izbirniki v zgornji vrstici niso filtri ene strani, ampak **kontekst cele seje**:

- **Organizacija** = `OrganizationId` (DEMO/IQLighting/Vidadria/Ediito). Določa, katere podatke
  uporabnik sploh vidi (artikli, cene, zaloga, stranke so vsi org-vezani — arhitekturno pravilo "OrganizationId
  povsod"). Menjava organizacije preklopi CELO aplikacijo na nov nabor podatkov.
- **Kanal / spletna stran** = izbrani `WebSite` (npr. svetila.si, videlektro.com) oz. B2C/B2B znotraj
  njega. Vpliva na: katera spletna validacija/status se prikazuje na izdelku, kateri cenik se uporablja
  za prikaz cene, kateri izvozni kanal je privzet na straneh Izvozi/Kakovost.
- **Jezik** = jezik VSEBINE (naziv/opis v SL/EN/DE/HR), ne jezik vmesnika. Vpliva na katera polja
  besedila se urejajo/prikazujejo na kartici izdelka in v izvozih.

Vsi trije se dajo spremeniti kadarkoli, brez izgube mesta, kjer je uporabnik trenutno bil (samo osveži
podatke glede na nov kontekst).

---

## 4. Sklopi aplikacije — kaj mora uporabnik videti in imeti omogočeno

Sledi pregled po sklopih na splošni ravni (podrobna polja/pravila so v master specifikaciji), s
poudarkom na **filtrih, glavni tabeli, kartici artikla in izvozu**, kot je bilo posebej zahtevano.

### 4.1 Nadzorna plošča

Ena stran, ki v nekaj sekundah pove "kje smo": KPI kartice (skupaj izdelkov, za urediti, z napakami,
v karanteni, popolnost za splet), "Moja opravila" (osebni seznam stvari, ki čakajo TA uporabnika —
izdelki brez slik, novi XML artikli za pregled, uvozi z napakami …), "Kakovost po profilih" (vrstica
napredka ERP/Komerciala/Splet), "Zadnji procesi / status integracij" (SAOP katalog, SAOP zaloga, BT/NW
XML uvoz, Magento izvoz — z zadnjim zagonom in statusom OK/Napaka/Opozorilo), "Nedavne aktivnosti" (kdo
je kaj naredil, iz dnevnika dejavnosti) in "Hitri dostopi" (bližnjice na najpogostejše akcije). Vsebina
se prilagaja vlogi uporabnika — administrator vidi vse, urejevalec kataloga vidi svoj del.

### 4.2 Uvozi (vhodi)

**Kateri vhodi obstajajo** (in jih mora uporabnik videti na eni pregledni strani "Viri"):
- SAOP API (katalog, cene, zaloga/dobavni roki, register strank, popusti po skupinah — vsak svoj tir);
- BT XML (Braytron — mapa ali HTTP vir);
- NW XML (Nowodvorski — mapa/dogodek);
- NW CSV (Nowodvorski zaloga — FTP);
- Excel/ročni paketni uvoz (uporabnik naloži datoteko, sistem razdeli po entitetah);
- Ročni vnos (osebna izkaznica artikla, en artikel naenkrat);
- "Novi artikli" (XML artikli, ki še niso v pripravi — čakajo na pregled in uvrstitev).

**Kaj mora uporabnik videti za vsak vir**: trenutni status (OK / Napaka / Opozorilo), datum in čas
zadnjega uvoza, število uvoženih vrstic, število napak, in dostop do nastavitev vira ter zgodovine.

**Kaj mora imeti omogočeno**: ročno sprožiti uvoz kjer je to smiselno (Excel, ponovni poskus po
napaki); pregledati podrobnosti napake (kaj točno je manjkalo/bilo narobe); pregledati zgodovino VSEH
uvozov (kdaj, kdo, koliko vrstic, uspeh/napaka) na eni skupni podstrani; za "Nove artikle" — pregledati,
povezati z obstoječim (če se artikel že pojavi v pripravi) in uvrstiti naprej.

### 4.3 Izdelki

**Filtri** (kombinacija hitrih čipov + panela "Filtri"): organizacija in kanal (iz globalnega konteksta),
zavihek po **statusu** (Vsi / Za urediti / Pripravljeni / Objavljeni / Arhivirani), proizvajalec,
dobavitelj, vir podatka (SAOP/BT/NW/ročno), kategorija, ABC klasifikacija, popolnost podatkov, značke
polnosti kot bližnjice (Brez slike, Brez kategorije, Brez EAN, Brez proizvajalca — prek gumba "Več" če
jih je preveč naenkrat), prosto besedilno iskanje (šifra/EAN/naziv).

**Glavna tabela** — stolpci: checkbox (za množične akcije), sličica, šifra (ItemID), EAN, naziv,
proizvajalec, status **ERP**, status **Splet**, **Popolnost** (%, vrstica napredka), datum zadnje
spremembe, akcije ("…" — odpri, kopiraj v drugo organizacijo, hitro uredi). Nad tabelo: izbirnik
pogleda (poln/kompakten), izbirnik vidnih stolpcev, gumb Izvozi (izvozi trenutno filtriran/izbran
nabor). Množično urejanje (izbrane vrstice) omogoča izvoz v Excel → urejanje → uvoz nazaj, brez skoka
na drugo stran in brez ponovnega izbiranja vrstic.

**Osebna izkaznica artikla** (klik na vrstico): na vrhu naziv, šifra, EAN; takoj pod tem tri statusne
kartice **po kanalu** — ERP (s podrejeno delitvijo po trgu SLO/EU), Komerciala, Splet (po izbrani
strani) — vsaka pove "Veljavno" / "Opozorilo" / "Napaka" in število odprtih težav; poleg teh kartica
skupne **Popolnosti** z odstotkom. Pod tem zavihki: Pregled (povzetek), ERP (samo ERP polja, filtrirano
po trgu), Komerciala, Splet (izbira strani + kanala B2C/B2B), Atributi, Kategorije, Mediji, Cene,
Zaloga (samo za branje), Zgodovina sprememb. Desno ob obrazcu ozek stolpec "Napake in opozorila",
kontekstno vezan na zavihek, ki ga uporabnik trenutno gleda. Akcije zgoraj desno: **Shrani** (validacija
se sproži samodejno ob shranjevanju), **Pošlji v ERP** (na voljo šele, ko so izpolnjeni pogoji — sistem
jasno pove, kateri pogoj manjka, ne samo da je gumb onemogočen), in "Napredno urejanje" za redkeje
potrebna polja.

### 4.4 Mediji

Samostojen sklop (ne le zavihek na artiklu): pregled vseh slik/dokumentov s filtriranjem po tipu (Slika/
Dokument/Nevezano), mrežni in seznamski pogled, oznaka glavne slike, povezanost s številom izdelkov na
posamezen medij (isti medij se lahko uporablja na več izdelkih). Cilj: en medij = ena resnica (ne
podvojene URL kopije), z jasno vlogo (glavna slika / dodatna slika / tehnična risba / certifikat).

### 4.5 Stranke

Register vseh strank (kupci/dobavitelji/oboje) z B2B profilom: tip stranke, plačnik, cenik, popusti (S
polno pakiranje, vrednostni rabat, B2B+ status), z zavihki na detajlu (Splošno / Komercialno /
Finančno / Poslovne enote in tranziti / Zaznamek / Dokumenti / Zgodovina). Filtri: vrsta stranke
(kupec/dobavitelj/oboje), tip stranke, ima popuste, B2B+ da/ne. Izvoz/uvoz profila prek Excela.

### 4.6 Partnerji

Ločeno od Strank: to je pogled na dobavitelje/proizvajalce **kot vire kataloga** — kateri vir podatkov
uporabljajo (XML/FTP/API/brez vira), koliko artiklov prihaja od njih, kdaj je bil zadnji uvoz. Ista
stranka je lahko hkrati v obeh sklopih (npr. Nowodvorski je proizvajalec z lastnim XML virom IN stranka
v SAOP registru) — povezava med njima je eksplicitna (šifra stranke po organizaciji), ne podvojena.

### 4.7 Zaloga

Samo za branje (namerna arhitekturna odločitev — PIM ne piše zaloge nazaj v ERP). Pregled po artiklu
ali po skladišču (preklop zrna), dobavni roki po časovnih pasovih, in ločen seznam izpeljanih težav
(brez zaloge, zastareli podatki, napake sinhronizacije) — težave se NE shranjujejo ročno kot "rešeno",
izginejo same, ko vzrok izgine.

### 4.8 Cene in ceniki

Tri podstrani: cene izdelkov (po ceniku, z virom SAOP/PIM in možnostjo posebne cene), ceniki (pregled
aktivnih cenikov, koliko artiklov ima vsak), posebne cene (izjeme na artikel/stranko). Jasno ločeno, kaj
je uradna SAOP cena (zaklenjeno, samo za branje) in kaj je PIM-side popust/izjema (urejljivo).

### 4.9 Kakovost

Tri podstrani: pregled kakovosti (skupna popolnost, izdelki brez napak, odprte napake, karantena — s
KPI karticami in razčlenitvijo po profilu ERP/Komerciala/Splet), napake (seznam z vsemi filtri —
resnost/profil/polje/artikel, brez ročnega gumba "označi rešeno", ker se napaka zapre sama ob popravku
in ponovni validaciji), karantena (artikli, ki so bili avtomatsko izločeni, z razlogom in množično
revalidacijo).

### 4.10 Izvozi — splošna pravila

To je namenoma poseben razdelek, ker je bilo izrecno vprašano "kako mora biti izvoz narejen":

1. **Izvozni kanal je PODATEK, ne posebna procedura za vsak primer.** Nabor stolpcev, njihov vrstni red
   in oznake so nastavljivi v šifrantu (vzorec `pim.OutputChannel` / `pim.OutputColumn`), ne trdo
   kodirani v vsakem novem SQL-u. Nov kanal (nova spletna stran, nov ERP izvoz) pomeni novo
   konfiguracijsko vrstico, ne novo veliko proceduro.
2. **Predogled pred prenosom**, z ISTIMI filtri, kot jih bo uporabil dejanski izvoz — "kar vidiš, je to,
   kar se izvozi", brez presenečenj po prenosu datoteke.
3. **Ločeni izvozi za ločene entitete.** Artikli, stranke in cene se NE mešajo v eno široko vrstico —
   vsak ima svoj izvoz, ki se v ciljnem sistemu (npr. Magento) srečata prek skupnega ključa (npr.
   skupina stranke), ne prek podvajanja podatkov.
4. **Format je prilagojen cilju**: CSV s podpičjem in UTF-8 BOM za sisteme, ki to zahtevajo (Magento);
   XLSX za vse, kar človek odpre in ureja (bulk edit, register strank).
5. **Vsak izvoz ima svojo zgodovino** — kdaj, kdo, koliko vrstic, uspeh/napaka — vidno na eni skupni
   podstrani "Zgodovina izvozov", ne razpršeno po log datotekah.
6. **Nič ne sme tiho odpasti.** Če izvoz izpusti vrstice (npr. ker manjka obvezno polje), to mora biti
   vidno kot število in razlog na predogledu, ne skrito v razliki med "koliko jih je v katalogu" in
   "koliko jih je prišlo ven".
7. **Gumb "Izvozi" na seznamski strani** (npr. na Izdelkih) izvozi trenutni filtriran/izbran pogled — to
   je ločeno od velikih kanalskih izvozov (SAOP celoten katalog, Magento CSV), ki imajo svojo namensko
   hub-stran pod "Izvozi" v meniju.

### 4.11 Nastavitve kataloga

Ena hub-stran s karticami: Atributi (šifrant atributov, prevodi, vidnost), Kategorije (drevo, ne ploska
tabela — razširi/skrči/povleci-in-spusti premik, urejanje imena/prevoda/vidnosti), Preslikave
(atributi/kategorije iz zunanjih virov na PIM šifrant — z jasnim stanjem Mapirano/Delno/Nemapirano),
Spletni kanali (spletne strani in njihovi kanali B2C/B2B s ceniki), Jeziki in prevodi (slovar prevodov,
manjkajoči prevodi kot filtrirljiv seznam), Referenčni podatki (enote, države, valute in drugi skupni
šifranti).

### 4.12 Pravila

Urejevalnik validacijskih profilov in obveznih polj po profilu (ERP_L1_SLO/EU, Komerciala, Splet po
strani) — brez potrebe po spremembi SQL kode za novo pravilo. B2B pravila (popusti, tipi strank,
poštnina) na enem mestu. Integracijski profil po proizvajalcu/viru — kaj ima na voljo (XML/FTP/API),
ali teče avtomatska validacija, kako je povezan s skladiščem.

### 4.13 Sistem / Administracija

Uporabniki in vloge (lokalni + domenski/AD), integracije/endpointi (kje je test/produkcijski naslov za
vsak zunanji sistem), dnevnik dejavnosti (kdo/kdaj/kaj — prijave in vse ključne mutacije), tehnični
zemljevid (stran → tabela → procedura, za IT), status/zdravje sistema (kateri viri so tiho obstali —
nadzornik odsotnosti signala, ne le napak).

---

## 5. Načela oblikovanja, ki naj vodijo vsako novo stran

- **En koncept = eno mesto.** Ne dodajaj filtra/gumba/stolpca, ki podvaja nekaj, kar je že pokrito z
  zavihkom ali značko drugje na isti strani. Če se zdi nova možnost res potrebna, jo najprej preveri z
  uporabnikom, preden jo dodaš — ne dodajaj "za vsak slučaj".
- **Jasna privzeta akcija.** Vsaka stran ima en očiten primarni gumb (kaj uporabnik najverjetneje želi
  narediti tu) — ne pet enako poudarjenih gumbov.
- **Sistem pove, kaj manjka, ne le da je nekaj narobe.** "Država porekla je obvezna za izvoz v EU" je
  uporabno; "Napaka" samo zase ni.
