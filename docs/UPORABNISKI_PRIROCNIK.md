# PIM intranet — uporabniški priročnik

Za urednike kataloga, komercialo in vse, ki v PIM-u urejajo podatke o izdelkih. Priročnik
odgovarja na dve vprašanji: **kaj moram narediti** in **kje se to nahaja**. Ne razlaga
tehnike; za to so drugi dokumenti v mapi `docs\`.

Stanje strani ustreza kodi na dan 2026-09-03. Kadar se stran in priročnik ne ujemata, velja
stran.

---

## 0. Preden začneš

### 0.1 Prijava in odjava

1. V brskalniku odpri naslov PIM-a. Če je nameščen pod IIS, je to običajno
   `http://<strežnik>/PIM`. Vse poti v tem priročniku so zapisane brez te predpone:
   kjer piše `/izdelki`, odpri `http://<strežnik>/PIM/izdelki`.
2. Na strani `/prijava` vpiši uporabniško ime in geslo. Domenski uporabnik vpiše ime v
   obliki `DOMENA\uporabnik`; geslo je isto kot za Windows.
3. Kljukica **Zapomni me** obdrži prijavo 14 dni. Brez nje prijava velja do zaprtja brskalnika.
4. Po prijavi pristaneš na **Nadzorni plošči** (`/nadzorna-plosca`).
5. Odjava je gumb v zgornji vrstici. Po odjavi te brskalnik vrne na `/prijava`.

Če geslo ne drži, stran pove samo, da prijava ni uspela — ne pove, kaj je narobe. Gesla
domenskih uporabnikov PIM ne hrani in ga ne more spremeniti.

### 0.2 Kako je zgrajen meni

Levi meni je razdeljen po poti podatkov skozi sistem. Vsaka stran je v meniju natanko
enkrat; podstrani odpreš s kartic na razdelilni strani (te imajo v meniju puščico).

| Skupina | Postavka | Pot | Kaj je tam |
|---|---|---|---|
| — | Nadzorna plošča | `/nadzorna-plosca` | stanje vseh podjetij na enem zaslonu |
| Vhodni podatki | Zajem podatkov | `/zajem` | kaj beremo iz SAOP in dobaviteljev, kdaj in s kakšnim izidom |
| PIM katalog | Izdelki | `/izdelki` | delovni seznam in kartica izdelka |
| PIM katalog | Mediji | `/mediji` | slike in dokumenti |
| Kakovost | Kakovost podatkov | `/kakovost` | kaj manjka in kaj zaradi tega stoji |
| Izhodi ERP in splet | Izhod v SAOP | `/saop` | kaj gre nazaj v ERP |
| Izhodi ERP in splet | Izhod na splet | `/splet` | datoteke za spletne trgovine |
| Poslovanje | Stranke | `/stranke` | kupci, dobavitelji, proizvajalci |
| Poslovanje | Zaloga | `/zaloge` | stanje zaloge po virih |
| Poslovanje | Cene in ceniki | `/cene` | cene po cenikih, cenik za tisk |
| Poslovanje | Preverbe cen in zaloge | `/preverbe` | opozorila o cenah, maržah in zalogi |
| Upravljanje | Nastavitve kataloga | `/nastavitve` | atributi, kategorije, kanali, jeziki |
| Upravljanje | Pravila in izvor podatkov | `/pravila` | validacija, slovar, preslikave, nazivi |
| Administracija | Sistem | `/sistem` | uporabniki, urniki, integracije, alarmi |

V zgornji vrstici vedno piše, v katerem delu toka si (npr. »Kakovost«), tudi na podstraneh.

### 0.3 Vloge — kaj vidiš in kaj smeš

| Vloga | Koda | Kaj sme |
|---|---|---|
| Pregledovalec | `VIEWER` | gleda; ne vidi Nastavitev, Pravil, Sistema, Strank in Izhoda v SAOP |
| Urednik kataloga | `CATALOG_EDITOR` | ureja izdelke, kategorije, nabor atributov, validacijo, nazive, pošilja v SAOP |
| Urednik komerciale | `COMMERCIAL` | stranke, popusti, prag marže, odobritve v čakalni vrsti, pravila |
| Skrbnik | `ADMIN` | vse zgoraj in Administracija (uporabniki, urniki, integracije) |

Če neke postavke v meniju ne vidiš, je nimaš zaradi vloge. Pravico dodeli skrbnik na
`/sistem/uporabniki`.

### 0.4 Oznake, ki se ponavljajo na vseh straneh

- **obvezno** ob polju: brez vrednosti je izdelek za ta kanal neveljaven.
- **SAOP** ob polju: polje piše SAOP. Sprememba ne gre takoj v katalog, ampak v čakalno
  vrsto za SAOP in čaka odobritev.
- **čaka SAOP**: sprememba tega polja je že v vrsti; do potrditve ga ne moreš znova urejati.
- **Blokira** (rdeče): napaka, ki ustavi ERP ali splet. **Opozorilo** (rumeno): vidno, ne
  ustavi ničesar.
- **Uporabi filtre**: filtri na seznamih se uveljavijo šele s tem gumbom (ali z Enter v
  iskalnem polju), ne ob vsakem kliku.
- Vsi seznami so **za vsa podjetja**, dokler ne izbereš podjetja v filtru **Podjetje**.

---

## 1. Nadzorna plošča (`/nadzorna-plosca`)

**Kaj vidim.** Pet številk na vrhu in pet panelov: **Po podjetjih**, **Kakovost po
profilih**, **Zadnji procesi / Status integracij**, **Opozorila in prioritete**, **Stanje
integracij**. Vse številke so za vsa podjetja skupaj.

**Kaj lahko naredim.** Plošča je samo za branje. Povezave **Vsi izdelki**, **Poglej vse** in
**Podrobnosti** vodijo na `/izdelki`, `/napake-validacije`, `/teki-obdelave` in
`/system/integracije`.

**Tipično opravilo — jutranji pregled**

1. Poglej **Opozorila in prioritete**. Če je kaj rdečega, odpri **Stanje integracij →
   Podrobnosti** (glej §10 in postopek 10).
2. Poglej **Zadnji procesi**. Če zadnji zajem zaloge ali kataloga ni od danes, glej
   postopek 10.
3. Poglej **Kakovost po profilih** in odpri **Poglej vse**, če se je število napak čez noč
   povečalo.

---

## 2. Vhodni podatki → Zajem podatkov (`/zajem`)

**Kaj vidim.** Šest številk: **Tokovi v redu**, **Čaka**, **V karanteni**, **Nerazvrščene
vrednosti**, **Zavrnjena zaloga**, **Tehnične težave**. Pod njimi seznam vseh registriranih
vhodov: kaj beremo, od kod, kdaj je bil zadnji poskus in kdaj zadnji uspeh (ločeno, da
neuspeh ne ostane skrit za starim zelenim stanjem).

**Filtri.** Podjetje, Vir, Vrsta (SAOP API / Dobaviteljev XML / Zaloga / Ročni uvoz), Stanje
(V redu / Zamuja / Neuspešno / V teku / Še brez teka), Aktivni in ustavljeni.

**Podstrani** (odpreš jih s številk ali iz seznama):

| Pot | Kaj je tam |
|---|---|
| `/zajem/teki` | zgodovina vseh izvedb; filtri Podjetje, Vir, Postopek, Status (V teku / Uspešno / Uspešno — zaloga / Neuspešno / Preklicano) |
| `/zajem/teki/{id}` | koraki, vhodne strani in napake ene izvedbe |
| `/zajem/tezave` | karantena, zavrnjena zaloga, mrtva pisma in napake na enem seznamu; enaki vzroki so združeni |
| `/zajem/cakalna-vrsta` | zajete strani, ki čakajo na preslikavo (»Pending« ni napaka) |
| `/zajem/neujemanja` | vrednosti iz virov, ki jih preslikava ne pozna; združene po vrednosti |
| `/zajem/viri/{koda}` | en vir: entitete, preslikave, svežina, zadnje izvedbe |
| `/zajem/atributi` | kaj je dobavitelj poslal in v katero našo lastnost to gre |

**Kaj lahko naredim.** Strani zajema so bralne. Zagon, ustavitev in ritem postopkov se
urejajo na `/sistem/urniki` (samo skrbnik). Neujemanja in manjkajoče prevode rešuješ v
slovarju (`/pravila/slovar`) in na `/kakovost/prevodi`.

---

## 3. PIM katalog → Izdelki (`/izdelki`)

### 3.1 Seznam izdelkov

**Kaj vidim.** Delovni seznam vseh podjetij po 50 vrstic. Stolpci: Izbor, Slika, Izdelek,
Podjetje, Proizvajalec, Dobavitelj, **ERP**, **Splet**, Popolnost, Težave, Vrzeli, Zadnja
sprememba. ERP in Splet povesta, ali je izdelek za ta kanal veljaven.

**Shranjeni pogledi** (zavihki nad seznamom, s števci): Vsi izdelki, Za urediti, Brez slike,
Brez spletnega naziva, Brez kategorije, Brez EAN, Neobjavljeni, Čaka SAOP.

**Iskanje in filtri.** Polje **Išči po šifri artikla ali EAN**. Gumb za filtre odpre:
Podjetje, Proizvajalec, Dobavitelj, Skupina artikla, Slika (Ima sliko / Brez slike), ABC
klasifikacija, Pripravljenost za ERP, Pripravljenost za splet, Aktivnost artikla, Zastavica
za splet (Označeni / Neoznačeni), Popolnost (0 % / Pod 50 % / 50–99 % / 100 %). Potrdi z
**Uporabi filtre**; **Počisti vse** vrne privzeti seznam. **Razvrstitev**: po šifri,
popolnosti, zadnji spremembi ali podjetju.

**Gumbi nad seznamom**

| Gumb | Kaj naredi |
|---|---|
| **Uredi izbrane (N)** | množično urejanje označenih izdelkov; dela samo, če so vsi iz istega podjetja |
| **Izvozi Excel** | trenutni filtriran pogled kot delovni zvezek (do 20.000 vrstic) |
| **Predloga SAOP** | isti nabor izdelkov v predlogi s stolpci SAOP — za izpolnjevanje in vračanje |
| **Excel → čakalna lista SAOP** | odpre `/saop/artikli`, kjer izpolnjeno predlogo uvoziš (postopek 8) |

**Tipično opravilo — najdi izdelke, ki jih moram urediti za splet**

1. Odpri `/izdelki`, izberi zavihek **Za urediti** ali filter **Pripravljenost za splet →
   Blokirani za splet**.
2. Po potrebi zoži na **Podjetje** in **Dobavitelj**, klikni **Uporabi filtre**.
3. Klikni naziv izdelka — odpre se kartica.

### 3.2 Kartica izdelka (`/izdelki/{id}`)

**Kaj vidim.** Glava z nazivom, podjetjem, šifro in EAN; glavna slika; **Ključni podatki**;
**Odprte naloge** (Dopolni ERP podatke / Dopolni spletne podatke / Preglej komercialne
podatke) in vrstica zavihkov, ki ostane vidna med drsenjem:

| Zavihek | Kaj je v njem |
|---|---|
| **Pregled** | tri kartice kanalov (ERP, Komerciala, Splet) s stanjem in številom napak |
| **ERP** | identiteta, šifranti ERP, partnerja, nazivi za ERP, logistika |
| **Komerciala** | uvrstitev, aktivnost, nabavni pogoji, **Cene** po cenikih (→ **Odpri poslovni pogled**) |
| **Splet** | objava, nazivi in opisi po jezikih, kategorije, atributi (**Atributi kategorije (nabor)** / **Atributi izven nabora — ne gredo na splet**) |
| **SAOP endpoint** | posnetek, kaj o artiklu ve SAOP |
| **Mediji** | vse slike in dokumenti (→ **Vsi mediji tega izdelka**) |
| **Zaloga** | stanje po skladiščih in virih (→ **Odpri poslovni pogled**) |
| **Kakovost in zgodovina** | odprte zahteve, **Zapisi v SAOP**, **Zgodovina sprememb**, **Izvor podatkov** |

Glava vsakega kanala pokaže **Blokirajoče napake**, **Opozorila** in **Validirano** (kdaj
nazadnje). Na dnu kanala je seznam **Odprte težave kanala**: sporočilo, polje, profil in ali
blokira.

**Kaj lahko naredim.**

1. Vpiši ali popravi vrednost v polje. Polja, ki jih PIM sme urejati, so vnosna; polja z
   oznako **SAOP** tudi, a gredo po drugi poti (glej spodaj); polja brez vnosa so samo za
   branje.
2. Zgoraj desno se pokaže **N neshranjenih**. Klikni **Shrani spremembe (N)** ali
   **Prekliči**.

**Kaj se zgodi potem.**

- Polje, ki je last PIM-a (spletni naziv, opis, atribut): shrani se takoj, izdelek se **takoj
  znova preveri** — popolnost in število težav se spremenita v istem trenutku.
- Polje z oznako **SAOP** (npr. merska enota): nastane skupina v čakalni vrsti `/outbound`,
  ki čaka odobritev. Do potrditve polje nosi oznako **čaka SAOP**. Stanje spremljaš na
  zavihku **Kakovost in zgodovina → Zapisi v SAOP** ali na `/saop`.
- Vsaka sprememba je v **Zgodovini sprememb** z imenom in časom.

**Tipično opravilo — izdelek ima rdečo napako za splet**

1. Na kartici odpri **Odprte naloge → Dopolni spletne podatke** (odpre zavihek Splet).
2. Polja, ki manjkajo, so označena **obvezno** in so v skupini z napisom »N brez vrednosti«.
3. Izpolni jih, klikni **Shrani spremembe**. Napaka izgine sama, ko je polje izpolnjeno;
   ni je treba »zapirati«.
4. Če manjka **kategorija** (spletna stran), je ne urejaš tu — glej postopek 1.

---

## 4. PIM katalog → Mediji (`/mediji`)

**Kaj vidim.** Slike, videe in dokumente vseh izdelkov izbrane organizacije v eni mreži ali
seznamu. Vrste medijev so čipi s števci (klik filtrira).

**Kaj lahko naredim.** Iskanje po artiklu, naslovu ali vlogi; **več besed zoži** iskanje
(npr. »203 pdf«). Filter **Vloga**, razvrstitev (Artikel A → Ž / Ž → A, Vloga, Vrsta
medija, Naslov), preklop **Mreža / Seznam**, **Počisti**. Klik na predogled odpre večjo sliko
ali prvo stran PDF-ja; **Zapri** zapre. Stran je bralna — medije prinese dobavitelj.
Datoteke, ki jih brskalnik ne zna pokazati (`.rar`, `.dwg`, `.ldt`), ostanejo povezava.

---

## 5. Kakovost → Kakovost podatkov (`/kakovost`)

### 5.1 Pregled (`/kakovost`)

**Kaj vidim.**

- **Pripravljenost za objavo**: štirje nivoji — **ERP_SLO**, **ERP_EU/THIRD**,
  **KOMERCIALA**, **SPLET**. Pri vsakem številka izdelkov, ki jih nivo ustavi, in delež
  izdelkov **brez** odprte zahteve. KOMERCIALA so opozorila in ne blokira ničesar.
  Povezava **Odpri napake →** odpre seznam napak tega nivoja.
- **Kaj popraviti — po polju**: isto polje zahteva več profilov, zato je delo združeno po
  polju; vidiš, koliko izdelkov ustavi eno polje.
- Tabela vseh profilov (zavihek `kakovost?pogled=profili`).
- **Kje popraviti**: kartice **Napake validacije**, **Karantena**, **Manjkajoči prevodi**,
  **Nepreslikane kategorije**. Karantena je *pred* PIM-om (zapis iz vira ni bil sprejet,
  izdelka ni); napaka validacije je *za* PIM-om (izdelek je, nekaj mu manjka).

### 5.2 Napake validacije (`/kakovost/napake`, tudi `/napake-validacije`)

**Kaj vidim.** Tri številke: **Blokira ERP**, **Blokira splet**, **Samo opozorilo**. Seznam
izdelkov z napakami, po 50 na stran, pri vsakem polje, profil in kaj blokira. Spodaj
**Katera zahteva ustavi največ izdelkov** in **Pri katerem dobavitelju se napake kopičijo**.

**Filtri.** Nivo, iskanje po šifri ali EAN, Profil, Spletno mesto, Resnost (Samo napake /
Samo opozorila), Kaj blokira (Blokira ERP / Blokira splet / Ne blokira), Polje. **Uporabi
filtre**.

**Kaj lahko naredim.** Klik na izdelek odpre kartico. Napake **ni mogoče označiti za
rešeno** — izgine sama, ko je izdelek popravljen in znova validiran.

### 5.3 Ostale strani kakovosti

| Pot | Kaj je tam | Kaj lahko naredim |
|---|---|---|
| `/kakovost/karantena` | zapisi iz virov, ki jih preslikava ni sprejela | iskanje; bralno |
| `/kakovost/prevodi` | vrednosti brez prevoda v slovarju | pregled; prevod vpišeš v slovar |
| `/kakovost/kategorije` | dobaviteljeva pot kategorije brez cilja v našem drevesu | **Uredi** → izberi cilj → **Shrani**; **Ugasni preslikavo**; velja za vsa podjetja |

---

## 6. Izhodi ERP in splet → Izhod v SAOP (`/saop`)

Zavihki: **Pregled** (`/saop`), **Artikli** (`/saop/artikli`), **Čakalna vrsta**
(`/outbound`), **Zgodovina** (`/saop/zgodovina`), **Odkloni** (`/saop/odkloni`). Bralni
šifrant polj, ki smejo nazaj v SAOP, je na `/saop/polja`.

### 6.1 Pregled (`/saop`)

**Kaj vidim.** Številke **Čaka odobritev**, **V vrsti**, **Poslano, nepotrjeno**,
**Potrjeno**, **Napake**, **Odkloni**. Tabela po entitetah (Artikli, Cene, Ceniki, Stranke,
Dokumenti). Pomembno: **HTTP uspeh ni potrditev** — zeleno je šele stanje **Potrjeno**, ki
nastane, ko naslednja sinhronizacija iz SAOP vrne isto vrednost.

**Kaj lahko naredim.**

- Pri neuspelih sporočilih gumb **Pošlji znova**; pri skupini **Pošlji znova vse neuspele**.
- Na `/outbound` (Čakalna vrsta): **Odobri**, **Prekliči**, **Ponovi** za posamezno
  sporočilo. Odobritev sporočilo samo uvrsti v vrsto; odda ga odhodni worker.
- `/saop/odkloni`: kjer se poslana vrednost ne ujema z vrednostjo, ki jo je SAOP vrnil.

### 6.2 Artikli v SAOP (`/saop/artikli`)

Nov artikel in sprememba obstoječega sta ista pot. Za vsako šifro PIM sam ugotovi: šifre
**ni** v katalogu → nov artikel (**POST / ADD**); šifra **je** → sprememba (**PATCH**).
Podrobni koraki so v postopku 8.

---

## 7. Izhodi ERP in splet → Izhod na splet (`/splet`)

**Kaj vidim.** Filter **Spletno mesto** in povezava **Pripravi izvoz**. Pet številk:

| Številka | Pomen |
|---|---|
| **V datoteki** | objavljen, s spletno stranjo in veljaven za splet — ta gre na splet |
| **Brez spletne strani** | objavljen, a stolpec *Spletne strani* je prazen — na splet **ne** gre; klik odpre `/izdelki/kategorije` |
| **S stranjo, a neveljaven** | blokira ga spletna zahteva; klik odpre napake nivoja SPLET |
| **Gre, a z opozorilom** | gre v datoteko, a ima odprto opozorilo |
| **Stolpcev brez vira** | stolpci profila, ki ostanejo prazni |

Sledijo razdelki **Zakaj izdelek ne pride do datoteke** (zahteve, ki blokirajo, s številom
izdelkov), **Stolpci profila brez vira**, **Izvozni profili tega spletnega mesta**,
**Datoteke za splet** in **Zgodovina dostav** (še ni evidence).

**Kaj lahko naredim — Datoteke za splet.**

1. V tabeli je vrstica za vsako datoteko (Izdelki ali Stranke) z imenom datoteke in številom
   stolpcev.
2. **Poglej** pokaže prvih nekaj vrstic natanko take datoteke, kot bo odšla; **Skrij** jo
   skrije.
3. **Prenesi** prenese celo datoteko (CSV). Datoteka nastane iz kataloga ob vsakem prenosu.

Urejanje datoteke tukaj ni mogoče in ne bi imelo učinka: popravek sodi na kartico izdelka
ali stranke, od koder pride v naslednjo datoteko.

### 7.1 Pripravi spletni izvoz (`/splet/izvoz`)

1. Izberi **Izvozni profil** (izdelki ali stranke).
2. Po želji **Spletno mesto** (samo pri izdelkih), **Iskanje** (šifra, EAN ali naziv) in
   kljukico **Samo objavljeni**.
3. Klikni **Prikaži** — predogled trenutnih podatkov po stolpcih profila.

---

## 8. Poslovanje

### 8.1 Stranke (`/stranke`)

**Kaj vidim.** Kupci, dobavitelji in proizvajalci aktivne organizacije; zavihki po vrsti,
iskanje **Poišči po šifri ali nazivu**, filter tipa, **Prejšnja / Naslednja** (25 na stran).

**Kartica stranke (`/stranke/{id}`)** — kaj lahko shranim:

| Razdelek | Gumb | Kaj se zgodi |
|---|---|---|
| **Kontakti** | **Shrani kontakte** / **Počisti ročni prepis** | ročno vpisan e-naslov in osebe prekrijejo vir; »Počisti« vrne vrednosti iz vira |
| **B2B spletne nastavitve** | **Shrani nastavitve** | tip stranke in vrsta za spletni B2B |
| **Vrednostni rabat** | **Shrani prag** | prag na vrednost košarice (bruto brez DDV) |
| **Poslovne enote in tranziti** | **Dodaj enoto** → **Dodaj** | poveže obstoječo stranko ali vpiše novo enoto |
| **Nov zaznamek** | **Zapiši zaznamek** | opomba z imenom in časom |

Vsak zapis se beleži z imenom prijavljenega uporabnika. Popusti po tipu stranke, pragovi in
poštnina so na `/pravila-popustov` (**Shrani preslikavo**, **Shrani prag**, **Dodaj override**).

### 8.2 Zaloga (`/zaloge`)

**Kaj vidim.** Zalogovne pozicije: artikel, skladišče, vir, količina, naročeno / za odpremo
/ naročeno dobaviteljem, datum prihodnje dobave, kdaj je bil posnetek narejen. Spodaj
**Svežina po viru** in **Izpeljane težave** (pozicije, ki nimajo svojega artikla).

**Filtri.** **Poišči po artiklu ali EAN**, Podjetje, Vir, Vrsta vira (**ERP (SAOP)** /
**Dobaviteljeva zaloga**), Svežina posnetka (do 24 ur / 3 dni / 7 dni). **Uporabi filtre**.

**Kaj lahko naredim.** Zaloga je samo za branje — PIM je nikoli ne piše v ERP. Edino dejanje
je prenos v CSV (postopek 6). Viri so tu **ločeni**; seštevajo se samo v izvozni datoteki za
splet (postopek 2).

### 8.3 Cene in ceniki (`/cene`)

**Kaj vidim.** Cene izdelkov po cenikih. Filtri: **Išči po šifri artikla**, Podjetje, Cenik,
Število cenikov (Vsi izdelki s ceno / Vsaj 2 / 4 / 8 cenikov), Veljavnost (Ima vsaj eno
veljavno ceno / Brez veljavne cene). Vrstica se razpre; v njej **Odpri kartico izdelka**.

**Gumbi.** **Cenik za tisk** (`/cene/tisk`, postopek 7) in **Preverbe cen in zaloge**.

### 8.4 Preverbe cen in zaloge (`/preverbe`)

**Kaj vidim.** Opozorila, ne napake — nič od tega ne ustavi izvoza. Številke po vrsti
preverbe (klik filtrira), razdelek **Faktor marže — prag** (postopek 5), filtri (šifra/EAN/
naziv, **Cenik ali skladišče**, kljukice **Vrsta preverbe**, **Uporabi filtre**) in razdelek
**Obvestila** z gumbi **Potrdi** in **Reši**.

---

## 9. Upravljanje

### 9.1 Nastavitve kataloga (`/nastavitve`) — samo ADMIN in CATALOG_EDITOR

Kartice: **Atributi** (`/nastavitve/atributi`), **Kategorije** (`/nastavitve/kategorije`),
**Povezave izdelkov**, **Spletni kanali**, **Jeziki**, **Skladišča**. Vse razen kategorij so
bralni šifranti.

**Kategorije (`/nastavitve/kategorije`)**

- Zgoraj: pokritost imen po jezikih (sl, en, de, hr, it); klik na jezik ga postavi v ospredje.
- Filtri: Drevo, Jezik v ospredju, Podjetje, Veja, Nivo (1–4), iskanje po imenu ali poti,
  **Razpri vse**, **Zloži na prvi nivo**.
- Pri vsaki kategoriji: število izdelkov neposredno v njej in s podkategorijami vred.
- **Klik na ime** odpre imena v vseh jezikih: **Shrani imena** / **Prekliči**.
- Gumb **Atributi** odpre nabor atributov kategorije (postopek 3).
- Kartici spodaj: **Preslikave kategorij** (`/kakovost/kategorije`) in **Uvrstitev izdelka**
  (`/izdelki/kategorije`).

### 9.2 Pravila in izvor podatkov (`/pravila`)

Kartice: **Validacijski profili** (`/pravila/validacija`, postopek 9), **Slovar vrednosti**
(`/pravila/slovar`), **Preslikave polj** (`/pravila/preslikave`), **Komercialna pravila**
(`/pravila-popustov`), **Pravila za nazive** (`/pravila/nazivi`, postopek 4).

- **Slovar vrednosti**: izvorna vrednost → ciljna vrednost po domeni in jeziku. Iskanje po
  izvorni ali ciljni vrednosti. Iz slovarja pridejo prevodi atributov v nazivih in izvozih.
- **Preslikave polj**: od kod polje pride in kam se zapiše. »Obvezno« tu pomeni, da brez
  elementa zapisa sploh ni mogoče zajeti — poslovna obveznost sodi v validacijo.

---

## 10. Administracija → Sistem (`/sistem`) — samo ADMIN

Kartice: **Urniki obdelav** (`/sistem/urniki`), **Integracije in alarmi**
(`/sistem/integracije`), **Uporabniki** (`/sistem/uporabniki`), **Vloge** (`/sistem/vloge`).
Dnevnik napak je na `/sistem/napake` (varni povzetek; podrobnosti so v dnevnikih workerjev).

**Uporabniki (`/sistem/uporabniki`)**

1. **Dodaj domenskega uporabnika**: vpiši `DOMENA\uporabnik`, **Najdi v AD**, **Dodaj**.
2. **Dodaj lokalnega uporabnika**: izpolni obrazec, **Ustvari račun**.
3. Pri obstoječem uporabniku: označi vloge in **Shrani**; lokalnemu lahko nastaviš novo geslo;
   gumb za vklop/izklop računa.

---

## 11. Delovni postopki po korakih

### Postopek 1 — Kako pride artikel na splet

Pravilo (velja od 2026-09-02): v datoteko za splet gre izdelek, ki hkrati

1. **je objavljen** (zastavica za splet),
2. **ima spletno stran** — stolpec **Spletne strani** ni prazen, kar pomeni, da ima na tem
   spletnem mestu vsaj eno kategorijo,
3. **je veljaven za splet** — nima rdeče (blokirajoče) spletne napake.

Če katerikoli pogoj ne drži, izdelka v datoteki ni, ne glede na vse ostalo.

**Kje to vidim**

| Kje | Kaj pove |
|---|---|
| `/splet` → **V datoteki** | koliko izdelkov gre |
| `/splet` → **Brez spletne strani** | objavljeni brez kategorije — najpogostejši razlog |
| `/splet` → **S stranjo, a neveljaven** | imajo kategorijo, blokira jih spletna zahteva |
| `/splet` → **Zakaj izdelek ne pride do datoteke** | katera zahteva ustavi koliko izdelkov |
| `/kakovost/napake` s filtrom **Kaj blokira → Blokira splet** | seznam izdelkov po napaki |
| kartica izdelka → zavihek **Splet** | stanje kanala, **Blokirajoče napake**, **Odprte težave kanala** |
| `/izdelki` → zavihek **Brez kategorije** / **Neobjavljeni** | hitri seznami |

**Kako popravim — manjka kategorija**

1. Odpri `/izdelki/{šifra}/kategorije` (ali `/izdelki/kategorije`, vpiši šifro v **Kateri
   izdelek** in klikni **Poišči**).
2. V razdelku **Kje je izdelek zdaj** je ena vrstica na spletno stran. Oznaka **brez
   uvrstitve** pomeni prazen stolpec Spletne strani. **iz vira** pomeni kategorijo iz
   dobaviteljevega XML-ja, **ročno** pomeni tvojo odločitev.
3. Klikni **Uredi** pri spletni strani.
4. Pri **Dodaj kategorijo** izberi pot iz drevesa in klikni **Dodaj na seznam**. Lahko dodaš
   več kategorij; z **odstrani** jo umakneš.
5. Po želji **Opomba**, nato **Shrani uvrstitev**.
6. Ročna uvrstitev je močnejša od vira: naslednji zajem XML-ja je ne povozi. **Vrni pod vir**
   jo umakne in kategorijo spet določa dobavitelj.

Pozor: shranjen **prazen seznam** pomeni *namenoma brez kategorije* — to ni isto kot »še ni
preslikano« in izdelek na splet ne gre.

Če dobaviteljeva kategorija sploh nima cilja v našem drevesu, to popraviš enkrat za vse
izdelke na `/kakovost/kategorije` (**Uredi** → cilj → **Shrani**).

**Kako popravim — manjkajoča polja**

1. Odpri kartico izdelka, **Odprte naloge → Dopolni spletne podatke**.
2. Izpolni polja z oznako **obvezno**, **Shrani spremembe**.
3. Napaka izgine takoj; na `/splet` se izdelek prešteje pod **V datoteki** ob naslednjem
   nalaganju strani, v datoteko pa pride ob naslednjem izvozu (postopek 2).

### Postopek 2 — Zaloga na spletu

**Kaj gre v datoteko.** Za Vidadrio se v izvozni datoteki **sešteje** zaloga VID (iz
registriranega pogleda SAOP) in zaloga IQLighting iz skladišča **Glavno skladišče Brnčičeva
13**. Seštevek nastane **samo v datoteki**; na `/zaloge` sta vira ločena in vsak s svojim
posnetkom.

**Kdaj se osveži**

| Datoteka | Ritem | Kje |
|---|---|---|
| hitra datoteka cen in zalog `magento-stock-prices.csv` | **vsakih 5 minut** (opravilo »PIM zaloga«) | `izvoz\magento\<podjetje>\` |
| polna datoteka izdelkov | **ponoči ob 02:30** (opravilo »PIM nocni tok«) | isti izhod |

Hitra datoteka ne gre skozi validacijo — zaloga in cena se osvežita tudi za izdelke, ki so
sicer blokirani; v polno datoteko pa pride izdelek samo po pravilu iz postopka 1.

**Ročni prenos**

1. `/splet` → **Datoteke za splet** → **Poglej** za predogled, **Prenesi** za celo datoteko.
2. `/splet/izvoz` → profil → **Prikaži** za predogled po stolpcih, filtriran po iskanju.

**Če zaloga na spletu stoji.** Poglej `/zaloge` → **Svežina po viru**. Če je posnetek SAOP
starejši od nekaj ur, glej postopek 10 (najverjetneje je postopek zaloge izklopljen).

### Postopek 3 — Nabor atributov po kategoriji

Nabor določa, kateri atributi veljajo za izdelke neke kategorije. Dokler nabor ni določen,
gredo v izvoz **vsi** atributi izdelka.

1. Odpri `/nastavitve/kategorije`, najdi kategorijo (iskanje ali **Razpri vse**).
2. Klikni gumb **Atributi** pri kategoriji. Odpre se tabela **Atribut / Raven / Določen na /
   Ima vrednost**.
3. Pri **Dodaj atribut** izberi atribut, pri **Raven** izberi:
   - **obvezen** — manjkajoč atribut **blokira splet** (rdeča napaka na kanalu Splet),
   - **priporočen** — manjkajoč atribut da opozorilo, ne blokira,
   - **izločen** — razveljavi atribut, podedovan od nadkategorije.
4. Klikni **Dodaj v nabor**. Raven obstoječega spremeniš v spustnem polju v vrstici;
   **Odstrani** ga umakne (podedovanega se ne da odstraniti, le izločiti).
5. Pod tabelo je seznam **Atributi, ki jih izdelki te kategorije že nosijo, a niso v naboru**
   — z gumboma **priporočen** / **obvezen** jih dodaš z enim klikom.

**Kaj se zgodi potem**

- **Podkategorije dedujejo** nabor; stolpec **Določen na** pove, ali je vrstica »tu« ali
  »podedovan: <kategorija>«. Najbližja kategorija zmaga.
- Na kartici izdelka (zavihek **Splet**) so atributi iz nabora v skupini **Atributi
  kategorije (nabor)** — tudi tisti brez vrednosti, da jih lahko vpišeš. Ostali so v skupini
  **Atributi izven nabora — ne gredo na splet**.
- Obvezen atribut brez vrednosti se pokaže kot blokirajoča napaka na `/kakovost/napake` in
  na `/splet` pod **S stranjo, a neveljaven**. Na seznamu napak je polje zapisano kot
  `ProductAttribute.<slovensko ime atributa>` (npr. `ProductAttribute.Garancija`); zahteva
  nastane in ugasne sama, ko atribut dodaš v nabor ali ga odstraniš — na
  `/pravila/validacija` je ni treba vpisovati ročno.

### Postopek 4 — Pravila za nazive (`/pravila/nazivi`)

Pravilo pove, kako se iz podatkov izdelka sestavi spletni naziv v posameznem jeziku. Velja
za kategorijo in njene podkategorije; najbližje zmaga.

1. V razdelku **Novo pravilo** izpolni:
   - **Koda pravila** (npr. `SVETILA_VISECA`; kasneje se ne spreminja), **Ime**,
   - **Drevo (spletna stran)** — ali »— vse —«,
   - **Kategorija** — prazno pomeni privzeto za celo drevo,
   - **Jezik** — prazno pomeni vsi jeziki, **Vrstni red**.
2. Vpiši **Predlogo** z žetoni, npr.
   `{ErpName} {Category:2} {Attr:Nazivna moč|unit:W} {Attr:Garancija|years}`.
   Razdelek **Žetoni in modifikatorji** našteje vse: `{ItemID}`, `{ErpName}`, `{WebName}`,
   `{Manufacturer}`, `{Category}` (list), `{Category:2}` (nivo), `{Attr:Ime atributa}`; za
   `|` pa `omitIf:`, `onlyIf:`, `omitIfAttr:`, `onlyIfAttr:`, `unit:W`, `years` (sklanjatev
   let), `lower`, `upper`, `prefix:`, `suffix:`. Prazen žeton izpade, presledki se strnejo,
   vrednost, ki je že v nazivu, se ne ponovi, prva črka je velika.
3. Klikni **Predogled te predloge**. V razdelku **Predogled** izberi **Podjetje** in **Jezik**;
   tabela pokaže šifro, naziv ERP, trenutni spletni naziv in **sestavljeni naziv**. Kjer je
   angleška vrednost ostala angleška, manjka prevod v slovarju (`/pravila/slovar`).
4. Kljukica **Pravilo je aktivno**; neaktivno pravilo se v predogledu še vedno da preizkusiti.
5. **Shrani pravilo**.
6. Zapis nazivov: kljukica **Samo izdelki brez spletnega naziva v tem jeziku** določa
   obseg. Gumb se glasi **Zapiši nazive (samo manjkajoče)** oziroma **Zapiši nazive (tudi
   prepis obstoječih)**. Gumb dela samo pri shranjenem in aktivnem pravilu.

**Kaj se zgodi potem.** Nazivi se zapišejo kot spletni nazivi izdelkov v izbranem jeziku; na
kartici so vidni na zavihku **Splet**, sprememba je v **Zgodovini sprememb**. Seznam
**Pravila** spodaj pokaže vsa pravila; klik na kodo ga odpre za urejanje; **Novo pravilo**
izprazni obrazec.

### Postopek 5 — Prag faktorja marže (`/preverbe`)

Faktor je prodajna cena deljeno z nabavno (cenik NAB). Izdelek pod pragom pride v preverbo
**FAKTOR_MARZE**; predlagana prodajna cena je nabavna × prag.

1. Odpri `/preverbe`, razdelek **Faktor marže — prag**.
2. Polje **Privzeto (vsa podjetja)** velja, kjer podjetje nima lastnega. Polje z imenom
   podjetja (npr. »… (lasten prag)«) velja samo zanj.
3. Vpiši vrednost (npr. `2.00`) in klikni **Shrani prag**.

Kdo sme: **ADMIN** in **COMMERCIAL**. Drugim so polja zaklenjena. Preverbe berejo prag ob
naslednjem nalaganju strani.

### Postopek 6 — Izvoz zalog v CSV (`/zaloge`)

1. V filtru **Podjetje** izberi podjetje (brez tega vrstica pove »najprej izberi podjetje
   zgoraj«).
2. V vrstici **Prenesi zalogo (CSV):** izberi **Obseg izvoza**: **Vsi izdelki podjetja** ali
   **Samo izdelki na spletu**.
3. Klikni **SAOP (ERP)**, **Dobavitelj** ali **Oboje**. Datoteka se odpre v novem zavihku in
   prenese.

Datoteka je po podjetju in vsebuje ločene vire (tu se nič ne sešteva).

### Postopek 7 — Cenik za tisk (`/cene` → **Cenik za tisk**, `/cene/tisk`)

1. Izberi **Podjetje**, **Cenik** (**B2C (maloprodaja)** ali **B2B (veleprodaja)**),
   **Jezik** (sl/en/de/hr/it) in po želji **Spletno mesto**.
2. Vpiši **Kategorija (pot)**, npr. `Notranja svetila > Viseča svetila`, **ali** šifre
   artiklov, ločene z vejico ali novo vrstico.
3. Kljukici **samo objavljeni** in **s slikami** po potrebi.
4. Klikni **Pripravi cenik**. Cenik se izriše po kategorijah s stolpci Šifra, Naziv,
   Proizvajalec, Cena brez DDV, DDV %, Cena z DDV.
5. Klikni **Natisni / PDF**. Odpre se tiskalni pogovor brskalnika (isto kot Ctrl+P); za PDF
   izberi **Shrani kot PDF**.

Če ima podjetje samo enega od cenikov (npr. brez B2B), bo tabela za drugi prazna.

### Postopek 8 — Uvoz artiklov v SAOP iz Excela (`/izdelki` → **Excel → čakalna lista SAOP**)

**Priprava predloge**

1. Na `/izdelki` nastavi filtre tako, da vidiš izdelke, ki jih boš urejal (za povsem nove
   artikle to ni potrebno).
2. Klikni **Predloga SAOP**. Preneseš delovni zvezek, katerega glave stolpcev so imena polj
   SAOP.
3. V Excelu izpolni vrstice. **Prazna celica pomeni »tega polja se ne dotakni«**, ne
   »izprazni«. Za nov artikel dodaj vrstico z novo šifro.

**Uvoz (`/saop/artikli`)**

4. Klikni **Excel → čakalna lista SAOP** (odpre `/saop/artikli`). Na vrhu piše, ali je kanal
   odprt in ali sporočila čakajo odobritev. Če piše, da profil SAOP_PRODUCT ni omogočen ali
   ne obstaja, uvrstitev ne bo mogoča — obrni se na skrbnika.
5. **1. Katere artikle urejaš**: izberi **Podjetje**. Nato bodisi vpiši šifre (ena na vrstico
   ali z vejico) in klikni **Dodaj v tabelo**, bodisi pri **Ali uvozi izpolnjeno predlogo
   (XLSX)** izberi datoteko. Vrstice se dodajo v tabelo; nič se še ne pošlje.
6. Pod tabelo piše, koliko je artiklov: **N novih (POST)** = šifer še ni v katalogu →
   dodajanje (**ADD**); **N sprememb (PATCH)** = obstoječi artikli → sprememba.
   **Počisti tabelo** začne znova.
7. **2. Katera polja spreminjaš**: klik na polje ga doda kot stolpec. Polja z zvezdico so
   **obvezna pri novem artiklu**. Polja brez gumba so v lasti SAOP ali jih PIM ne hrani.
8. **3. Vrednosti**: vpiši vrednosti po artiklih. Vrstica **Velja za vse** vpiše isto
   vrednost vsem. Pri vsakem artiklu vidiš **Metodo** (POST/PATCH) in lahko odpreš
   **Dokument** — natanko to, kar bo poslano.
9. **4. Uvrstitev v vrsto**: piše »Pripravljenih N artiklov s skupno N polji«; ustavljeni so
   tisti z manjkajočim obveznim poljem ali napačno vrednostjo. Klikni **Uvrsti N sprememb v
   vrsto**.

**Odobritev in pošiljanje**

10. Če kanal zahteva odobritev, se pokažeta **Odobri skupino N** in **Prekliči skupino**.
    Odobriš lahko tu ali kasneje na `/outbound` (**Odobri** / **Prekliči**).
11. Uvrstitev ničesar ne pošlje. Dokument sestavi in odda odhodni worker; do takrat je vsako
    sporočilo mogoče preklicati.
12. Stanje spremljaš na `/saop`: **Čaka odobritev → V vrsti → Poslano, nepotrjeno →
    Potrjeno**. Potrjeno je šele, ko naslednja sinhronizacija iz SAOP vrne isto vrednost.
    Odgovor ERP je v `/saop/zgodovina`.
13. Če sporočilo pade v **Napake**, na `/saop` klikni **Pošlji znova** pri sporočilu ali
    **Pošlji znova vse neuspele** pri skupini. Razlog zavrnitve je v tabeli **Zavrnjene
    vrstice in razlog** takoj po uvrstitvi in v **Dnevniku seje** na dnu strani.

### Postopek 9 — Validacija: kaj je obvezno in kaj blokira

**Nivoji.** Zahteve so razvrščene v štiri nivoje, isti kot na kartici izdelka in v napakah:

| Nivo | Profili | Kaj ustavi |
|---|---|---|
| **ERP_SLO** | `ERP_L1_SLO`, skupni `SHARED_CORE` | zapis v SAOP za Slovenijo |
| **ERP_EU/THIRD** | `ERP_L1_EU`, `ERP_L1_THIRD` | zapis v SAOP za EU / tretje države (dodatek k SLO) |
| **KOMERCIALA** | `COMMERCIAL_L2` | nič — samo opozorila |
| **SPLET** | `WEB_<spletno mesto>` | objavo na splet |

**Resnost.** **Napaka — blokira** naredi izdelek neveljaven za ta kanal. **Opozorilo — ne
blokira** je vidno, kanal ostane veljaven. Popolnost v odstotkih se šteje po vseh zahtevah.

**Dodaj zahtevo (`/pravila/validacija`)**

1. V razdelku **Dodaj zahtevo** izberi **Profil**.
2. Vpiši **Polje (koda iz canon.FieldValue)**, npr. `Product.EAN`.
3. Izberi **Resnost** in klikni **Dodaj**.
4. Zahteva nad kodo, ki je katalog ne pozna, se zapiše kot **neaktivna** in pristane v
   **Zahteve, ki čakajo na polje** — tam jo lahko kasneje **Vklopi**.

**Uredi zahtevo.** V tabeli nivoja spremeni **Resnost** v spustnem polju (velja takoj) ali
klikni **Umakni**. Umik ni brisanje: odprte napake še kažejo nanjo, dokler ne izginejo ob
naslednji validaciji.

**Kje vidim učinek.** `/kakovost` (pripravljenost po nivoju in po polju) in
`/kakovost/napake` (seznam izdelkov, filtra **Nivo** in **Profil**).

### Postopek 10 — Ko nekaj ne dela

**Korak 1 — alarmi (`/sistem/integracije`, tudi `/system/integracije`; samo ADMIN)**

1. Zgoraj: **Integracije**, **Omogočene**, **Odprta opozorila**, **Mrtva / odkloni**. Gumb
   **Osveži stanje**.
2. Tabela **Integracije aktivne organizacije**: Ponudnik, Postopek, Omogočeno, Stanje, Zadnji
   utrip, Zadnji uspeh, Zadnja napaka, Vodni žig, Naslednje izvajanje.
3. Tabela **Operativna opozorila**: Resnost, Postopek, Naslov, Redigiran povzetek, Pojavitve.
   **Potrdi** pomeni »videl sem« (zapiše tvoje ime in čas), **Razreši** pomeni »odpravljeno«.
   Ne razrešuj, dokler vzrok ni odpravljen — alarm se sicer izgubi.

**Korak 2 — urniki (`/sistem/urniki`)**

1. Vsak postopek ima vrstico: Podjetje, **Vklopljen / Izklopljen**, razmik v minutah, stanje,
   naslednji zagon, zadnji uspeh, zadnja napaka.
2. Pravilo **»pet zamahov in izklop«**: po petih zaporednih napakah se postopek **sam
   izklopi** in nastane alarm `PipelineDisabled`. Najpogostejši vzrok je nedosegljiv SAOP
   (VPN, omrežje) — PIM v tem primeru ni pokvarjen, samo ustavljen.
3. Ko je vzrok odpravljen, klikni **Vklopi** pri postopku in podjetju. Načrtovano opravilo
   Windows teče vsakih 5 minut in postopek pobere ob naslednjem tiku. **Izklopi** ustavi
   postopek takoj.
4. **Shrani razmik** spremeni, kako pogosto postopek teče (1–1440 minut).

**Korak 3 — kaj se je dejansko zgodilo (`/zajem/teki`)**

1. Filtriraj po **Podjetje**, **Postopek** in **Status → Neuspešno**.
2. Klik na vrstico odpre `/zajem/teki/{id}`: koraki, vhodne strani, napake. Skrbnik vidi tudi
   tehnični predogled vhoda.
3. Tehnične težave na enem seznamu: `/zajem/tezave`. Sistemski dnevnik: `/sistem/napake`.

**Korak 4 — dnevniki na strežniku** (kadar stran ne pove dovolj; skrbnik)

| Dnevnik | Kaj je v njem |
|---|---|
| `logs\zaloga-<datum>.log` | petminutni cikel zaloge in hitra datoteka cen in zalog (vrstica »Izvoz cen in zaloge za splet«) |
| `logs\nocno_*.log` | nočni tok ob 02:30: poln zajem kataloga in polna datoteka za splet |
| `logs\nadzor-<datum>.log` | nadzornik, ki vsakih 5 minut preverja zastale obdelave in razpošilja alarme |

**Hitri seznam simptomov**

| Simptom | Kje pogledati | Najverjetnejši vzrok |
|---|---|---|
| zaloga na spletu stoji | `/zaloge` → Svežina po viru; `/sistem/urniki` | postopek zaloge izklopljen po petih napakah |
| izdelek ni v datoteki za splet | `/splet` → tri številke; postopek 1 | brez kategorije ali blokirajoča spletna napaka |
| sprememba ne pride v SAOP | `/saop` → Čaka odobritev / Napake; `/outbound` | čaka odobritev ali zavrnjena; **Pošlji znova** |
| novi artikli dobavitelja se ne pojavijo | `/zajem` → V karanteni; `/kakovost/karantena` | zapis brez šifre ali nesprejeta preslikava |
| atribut ima angleško vrednost | `/kakovost/prevodi`; `/pravila/slovar` | manjka prevod v slovarju |
| ne vidim menija ali strani | `/sistem/uporabniki` (skrbnik) | manjka vloga |

---

## 12. Kratek slovar

| Izraz | Pomen |
|---|---|
| **Kanal** | cilj podatkov: ERP (SAOP), Komerciala, Splet. Vsak ima svoja obvezna polja. |
| **Profil** | seznam zahtev za en kanal ali eno spletno mesto (npr. `WEB_svetila_si`). |
| **Nivo** | skupina profilov na kartici in v napakah: ERP_SLO, ERP_EU/THIRD, KOMERCIALA, SPLET. |
| **Blokira** | napaka, ki izdelek ustavi za ta kanal. Opozorilo ga ne ustavi. |
| **Spletna stran / Spletne strani** | spletno mesto, na katerem ima izdelek kategorijo; brez tega ne gre na splet. |
| **Nabor atributov** | atributi, ki veljajo za kategorijo (obvezen / priporočen / izločen). |
| **Čakalna vrsta (outbound)** | sporočila za SAOP, ki čakajo odobritev ali pošiljanje. |
| **Potrjeno** | SAOP je pri naslednji sinhronizaciji vrnil poslano vrednost. |
| **Odklon** | poslana vrednost se ne ujema s tisto, ki jo je SAOP vrnil. |
| **Karantena** | zapis iz vira, ki ga preslikava ni sprejela; izdelka iz njega ni. |
| **Posnetek** | trenutek, ko je bila zaloga prebrana iz vira. |
| **Tek** | ena izvedba postopka (zajem, zaloga, izvoz). |
