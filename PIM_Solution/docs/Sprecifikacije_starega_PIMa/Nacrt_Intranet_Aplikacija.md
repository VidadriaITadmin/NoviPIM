# Intranet aplikacija PIM — izgled, sestava in navigacija (NoviPIM)

Verzija: 2.0 · Datum: 2026-08-26 · Status: referenčni dokument, **prepisan za NoviPIM**

> **Kaj je ta dokument in kaj ni.**
> Različica 1.0 je opisovala intranet **starega sistema** (`..\PIM_test`): njegove angleške
> poti, njegov meni in makete, ki v tem repozitoriju ne obstajajo. Ta različica ohrani
> oblikovna načela — ker so ostala v veljavi — in vse poti, imena strani, vloge ter podatkovne
> vire prepiše na dejansko aplikacijo `PIM_Solution\src\PIM.Intranet`.
> Izvirnik je v [`izvirniki_stari_PIM/`](izvirniki_stari_PIM/).
>
> **Delitev dela med dokumenti — da si ne nasprotujeta:**
>
> | Dokument | Kaj pove |
> |---|---|
> | `docs/INTRANET.md` | **dejansko stanje kode**: poti, končne točke, procedure, testi |
> | `NAVIGACIJSKI_SISTEM_IN_FUNKCIJE_STRANI.txt` | **funkcija za funkcijo** po straneh: TRENUTNO / DODATI |
> | `docs/NACRT_INTRANET_PRENOVA.md` | analiza in načrt prenove, vizualna združitev (§13) |
> | `docs/PRODUKTNI_MODEL_PIM.md` | trajni zemljevid faz, virov, vlog in pogodb |
> | **ta dokument** | **kako naj bo aplikacija sestavljena in kako naj izgleda** |
>
> Kjer se ta dokument razhaja z `docs/INTRANET.md`, velja `docs/INTRANET.md`.

---

## 1. Vizualna zasnova (design system)

Vizualni vir je referenca `src_navigation_ux_v2`, preslikana na razrede NoviPIM
(`docs/NACRT_INTRANET_PRENOVA.md` §13). Barvni žetoni živijo na enem mestu v
`wwwroot/app.css` kot `--pim-*`; posamezna stran svojih primarnih barv ne zakodira.

- **Postavitev**: temna skrilasta leva navigacija (18 rem) z oranžno identiteto na vrhu,
  svetla vsebina na podlagi `#f4f6f9`, bele kartice z 12-px zaokrožitvijo in mehko senco,
  meja `#e5e7eb`, indigo `#4f46e5` kot poudarek. Prelomnica za mobilni prikaz je 900 px;
  preklop menija je CSS/SSR, ne JavaScript.
- **Zgornja vrstica**: oznaka trenutne **faze toka** (`PimLifecycle`: Nadzor, Vhodni podatki,
  PIM katalog, Kakovost, Izhodi, Poslovanje, Upravljanje, Administracija), polje globalnega
  iskanja (danes povezava na seznam izdelkov; pravo iskanje po šifri, EAN, nazivu, stranki in
  viru je vrzel), zvonec s številom odprtih opozoril, prijavljeni uporabnik in odjava.
  Globalnih izbirnikov organizacije, kanala in jezika ni; večorganizacijski ali kanalski
  filter je lokalen na strani, kjer je poslovno potreben.
- **Glava strani** (`PimPage`): naslov, en stavek namena, drobtinice (`PimCrumb`) na
  podstraneh, na seznamskih straneh brez njih. Primarno dejanje je eno in vidno — a se
  prikaže **samo, če zanj obstaja varna zapisovalna pot**.
- **Skupni gradniki, ki jih stran ne sme podvajati**: `PimTable` (dostopen `caption`/`scope`),
  `PimState` (nalaganje / napaka / prazno), `PimPager` (strežniška paginacija), `PimStat`
  (KPI), `PimChip` (značka, aktiven filter), `PimBar` (popolnost), `PimHubCard` (razdelilna
  kartica), `PimColumn` (definicija stolpca), `IngestTabs` (zavihki modula).
- **Barve stanja** — dosledno povsod: zelena = veljavno, rdeča = napaka/blokira,
  oranžna = opozorilo (ne blokira), modra = informativno, siva = neaktivno/ni podatka.
- **Poimenovanje je slovensko in razumljivo.** Tehnični izraz (`ERP_L1_SLO`, `PendingApproval`)
  sme stati v oklepaju ali namigu, ne pa kot edino besedilo za uporabnika.
- **Brez Bootstrapa in brez zunanjih pisav.** Intranet mora delovati brez interneta; `Inter`
  je prva izbira samo, če je lokalno na voljo, sicer sistemski sklad.
- **Nedokončano ostane vidno, a označeno.** Stran, ki še ni pripravljena, jasno pove »ta del
  še ni na voljo« — ne izgine iz menija in ne vrže napake.
- **Zaradi Blazorjeve CSS izolacije** slog starševske komponente ne doseže sidra, ki ga izriše
  `NavLink`; navigacijski selektorji uporabljajo `::deep`.

---

## 2. Navigacijski sistem

Navigacija je **v kodi** (`Services/PimNavigation.cs`), ne v `sec.Navigation*`. Razlog je
zapisan v sami datoteki: v bazi je bila razdrobljena na šest postavk, ki niso pokrivale niti
obstoječih strani, vsaka nova stran pa bi zahtevala migracijo. Bralni model v bazi ostaja
nedotaknjen — a ne obstajata dve navigacijski resnici hkrati.

Poti so **base-relativne, brez začetne poševnice**, ker aplikacija teče tudi pod IIS
virtualno aplikacijo `/PIM` (`app.UsePathBase("/PIM")`).

### 2.1 Dejanska razporeditev menija

| Skupina (faza) | Postavka | Pot | Tip | Vloge |
|---|---|---|---|---|
| — | Nadzorna plošča | `nadzorna-plosca` | stran | vse |
| Vhodni podatki | Zajem in preslikave | `zajem` | HUB | vse |
| PIM katalog | Izdelki | `izdelki` | stran | vse |
| PIM katalog | Mediji | `mediji` | stran | vse |
| Kakovost | Validacija in vrzeli | `kakovost` | HUB | vse |
| Izhodi ERP in splet | Izvozi in dostava | `izvozi` | HUB | vse |
| Poslovanje | Stranke | `stranke` | stran | vse |
| Poslovanje | Partnerji | `partnerji` | stran | vse |
| Poslovanje | Zaloga | `zaloge` | stran | vse |
| Poslovanje | Cene in ceniki | `cene` | stran | vse |
| Upravljanje | Nastavitve kataloga | `nastavitve` | HUB | ADMIN, CATALOG_EDITOR |
| Upravljanje | Pravila in izvor podatkov | `pravila` | HUB | ADMIN, CATALOG_EDITOR, COMMERCIAL |
| Administracija | Sistem | `sistem` | HUB | ADMIN |

**Vsaka postavka je natanko ena destinacija.** Podstrani se odprejo z matične strani in v
meniju ne nastopajo:

- `zajem` → `zajem/viri`, `zajem/viri/{SourceCode}`, `zajem/teki`, `zajem/teki/{RunId}`,
  `zajem/tezave`, `zajem/tezave/{vrsta}/{id}`, `zajem/preslikave`, `zajem/cakalna-vrsta`,
  `zajem/neujemanja`
- `kakovost` → `kakovost/napake`, `kakovost/karantena`, `kakovost/prevodi`, `kakovost/kategorije`
- `izvozi` → `izvozi/profili/{Id}`, `izvozi/mnozicno`, `izvozi/obvestila`, `outbound`
- `nastavitve` → `nastavitve/atributi`, `nastavitve/kategorije`, `nastavitve/skladisca`,
  `nastavitve/kanali`, `nastavitve/jeziki`
- `pravila` → `pravila/validacija`, `pravila/slovar`, `pravila/preslikave`, `pravila-popustov`
- `sistem` → `sistem/integracije`, `sistem/uporabniki`, `sistem/vloge`, `sistem/napake`
- podrobnosti: `izdelki/{ProductId}`, `stranke/{CustomerId}`

**Stare poti ostajajo kot aliasi** (`napake-validacije`, `karantena`, `teki-obdelave`,
`system/uporabniki`, `system/integracije`), da zaznamki ne pristanejo na 404.

### 2.2 Načela, ki jih navigacija mora spoštovati

- **En koncept = eno mesto.** Če stanje že pokriva zavihek ali značka, ne dobi še svoje
  vrstice v spustnem seznamu drugje. Ena entiteta ima eno glavno stran; različna stanja so
  filtri ali shranjeni pogledi, ne nove strani. (Stari intranet je isti izdelek prikazoval na
  šestih seznamih — vsak popravek filtriranja je bil šestkratno delo.)
- **Vloge omejujejo vidnost, ne le dostop.** Kdor modula nima, ga v meniju ne vidi;
  onemogočenih sivih postavk ni. Avtorizacija na strani (`[Authorize(Roles = …)]`) je druga
  obramba, ne edina.
- **Poti so v enem jezikovnem registru** — slovenske, predvidljive. Nova stran mora imeti
  očitno pot; če je ni, je verjetno na napačnem mestu v arhitekturi.
- **Kontekstni izbirniki se pokažejo tam, kjer imajo pomen** — na čisto sistemskih straneh ne.
- **Brez dveh poti do istega rezultata.** Nova pot pomeni, da se stara ukine ali preusmeri.
- **Navigacija ni samo levi meni.** Iz problema do vzroka mora voditi vsebina:
  vir → tek → težava → izdelek; izdelek → napaka → pravilo → manjkajoče polje;
  izdelek/stranka → odhodno sporočilo → poskus → potrditev; profil → stolpec → kanonično polje.

---

## 3. Globalni kontekst — organizacija / kanal / jezik

To mi odstrani iz aplikacije.

---

## 4. Sklopi aplikacije

Spodaj je namen, vstopna pot in vir resnice vsakega sklopa. **Podroben seznam funkcij
TRENUTNO / DODATI je v `NAVIGACIJSKI_SISTEM_IN_FUNKCIJE_STRANI.txt`** in se tu namenoma ne
podvaja.

### 4.1 Nadzorna plošča — `nadzorna-plosca`

En zaslon, ki pove »kje smo«: skupno število kanoničnih izdelkov, ERP veljavni, objavljeni,
z napakami za splet, v karanteni; kakovost po profilih; zadnji teki; odprta opozorila; stanje
integracij; hitre povezave. Vsaka številka mora voditi na filtriran seznam, ki jo pojasni.
Vrzel: »Moja opravila«, svežina po domenah in trendi — ti potrebujejo zgodovinske vire.

### 4.2 Vhodni podatki — `zajem` (HUB s petimi pogledi)

Pregled · Viri · Teki · Težave · Preslikave. Združuje katalogske vhode (`raw.Inbox`,
`ops.PipelineRun`, `ops.PipelineStepLog`) in zalogovne (`stock.SyncRun`), pri čemer je
**zadnji poskus ločen od zadnjega uspeha** — neuspeh se ne sme skriti za starejšim uspehom.
Viri: SAOP API (16 bralnih končnih točk), NW XML, BT XML, NW CSV zaloga, datoteke, ročni vnos.
Poverilnice se ne prikažejo nikoli. Dostava je danes pošteno bralna: gumbov za dejanja brez
auditirane procedure ni.

*Znana vrzel:* neuspešen zalogovni tek nima trajnega zapisa `Failed`, ker writer ob izjemi
povrne celotno transakcijo — UI zato tega padca ne more prikazati.

### 4.3 Izdelki — `izdelki`, kartica `izdelki/{ProductId}`

Glavno delovno mesto. Seznam ima strežniško iskanje, filtriranje, paginacijo in izbor čez več
strani. Bralna kartica od 2026-08-26 uporablja `intranet.GetProductCard` in
`intranet.GetProductOrigin`: pokaže naslovni medij in dejanski naziv, ločeno pripravljenost za
ERP in splet, lastništvo polj, čakajočo SAOP prekrivko ter 12 zavihkov za vsa obstoječa
domenska dejstva izdelka. Zapisovalnih gumbov še nima, ker zapisovalna pogodba ni del te faze.

Cilj naslednjega koraka je, da seznam in kartica **samo z branjem** odgovorita na vprašanje:
*»Zakaj ta izdelek ni pripravljen za ERP ali za splet in od kod je prišel njegov podatek?«*

**Pravilo kartice — najpomembnejše pravilo celotnega vmesnika:**

1. **PIM-lastno polje** (`pim.FieldOwnership` = `PIM`) se sme urediti neposredno; zapiše se
   v `pim.ProductFieldHistory` z avtorjem, časom, staro in novo vrednostjo.
2. **SAOP-lastno polje** se ne prepiše. Nastane sporočilo v `out.OutboxMessage`
   (`PendingApproval`), ki gre skozi odobritev, pošiljanje in **echo potrditev**. Uporabnik
   mora videti razliko med »shranjeno v PIM« in »poslano v SAOP, čaka potrditev«.
3. **Polje brez varne zapisovalne poti nima gumba za urejanje.**

### 4.4 Mediji — `mediji`

Samostojen sklop, ne le zavihek na izdelku: število medijev, izdelki s sliko in brez,
iskanje po artiklu, URL in vlogi, povezava na izdelek. Cilj: en medij = ena resnica, z jasno
vlogo (glavna slika / dodatna / tehnična risba / dokument). Vira sta `canon.ProductMedia` in
`canon.ProductDocument`; danes prihajata iz dobaviteljskih XML.

### 4.5 Kakovost — `kakovost` (HUB)

Pregled po profilih, `kakovost/napake`, `kakovost/karantena`, `kakovost/prevodi`,
`kakovost/kategorije`. Vir je `val.*`; napaka **nima ročnega gumba »rešeno«** — zapre se sama
ob popravku in revalidaciji. Prikazati mora resnost (`ERROR`/`WARNING`) in **kaj blokira**
(`BlocksErp` / `BlocksWeb` / samo opozorilo), ker to dvoje ni isto.

### 4.6 Izhodi — `izvozi` (HUB) in `outbound`

Dva svetova, ki se ne smeta mešati:

- **ERP / SAOP** (`outbound`): čaka odobritev → v vrsti → poslano → **potrjeno** / odmik /
  mrtvo / preklicano. Uspešen HTTP odgovor ni potrditev.
- **Splet** (`izvozi`): profil (`out.ExportProfile`) pove entiteto, kanal in stolpce
  (`out.ExportColumn`); vsak stolpec ima kanonični vir ali je **vidno nepokrit**.

Podstrani: `izvozi/profili/{Id}`, `izvozi/mnozicno`, `izvozi/obvestila`.

### 4.7 Poslovanje — `stranke`, `partnerji`, `zaloge`, `cene`

- **Stranke** (`b2b.Customer`, `pim.CustomerWebProfile`): kupci/dobavitelji/oboje, Magento
  skupina, B2B+, popusti. Tip stranke in PE/tranzit sta **odločitvi človeka**, ne podatek iz
  SAOP — dokler nista postavljena, stranka v spletni izvoz ne gre.
- **Partnerji**: dobavitelji in proizvajalci **kot viri kataloga** — kateri vir uporabljajo,
  koliko izdelkov prihaja od njih. Ista pravna oseba je lahko hkrati stranka in partner;
  povezava je eksplicitna, ne podvojena.
- **Zaloga**: samo za branje. `stock.Position`, `stock.Snapshot`, `stock.UnmatchedPosition`,
  s starostjo posnetka in opozorilom o zastarelosti. **PIM zaloge nikoli ne piše nazaj.**
- **Cene in ceniki**: `canon.ProductPrice` po ceniku, neto/DDV/bruto, veljavnost. Uradna SAOP
  cena je zaklenjena; PIM-lastne izjeme so ločene in vidno označene.

### 4.8 Upravljanje — `nastavitve` in `pravila` (HUB, omejeni vlogi)

- **Nastavitve kataloga**: atributi, kategorije, skladišča, kanali, jeziki. Danes **bralno**.
  Stran »Atributi« pošteno pove, da prikazuje samo atribute, ki v katalogu res imajo vrednost
  — register atributov (ime, tip, enota, dovoljene vrednosti, prevod, vezava na kategorijo)
  v NoviPIM **še ne obstaja** in je pogoj za urejanje.
- **Pravila in izvor podatkov**: validacijski profili, slovar vrednosti, preslikave polj,
  komercialna pravila (`pravila-popustov`). Danes bralno; cilj je urejanje brez spremembe kode
  — s predogledom vpliva, testom nad vzorčnim zapisom in revizijsko sledjo.

### 4.9 Administracija — `sistem` (samo ADMIN)

Integracije in alarmi, uporabniki (lokalni + AD), vloge, dnevnik napak. Gesla domenskih
uporabnikov se v PIM ne shranjujejo; skrivnosti se v vmesniku ne prikazujejo nikoli.

---

## 5. Izvozi — kako mora biti izvoz narejen

Ta razdelek ostaja iz različice 1.0, ker je bil izrecno zahtevan. Prva točka je v NoviPIM že
izpolnjena, ostale so merilo za nadaljnje delo.

1. **Izvozni kanal je podatek, ne procedura.** ✔ izvedeno: `out.ExportProfile` /
   `out.ExportColumn` (migracija 045). Nov *kanal* je vrstica registra; nov *podatek* je še
   vedno koda, ker ga mora nekaj proizvesti.
2. **Predogled pred prenosom, z istimi filtri kot pravi izvoz.** — vrzel.
3. **Ločeni izvozi za ločene entitete.** Izdelki, stranke in cene se ne stlačijo v eno široko
   vrstico; v ciljnem sistemu se srečajo prek skupnega ključa (skupina strank).
4. **Format je prilagojen cilju**: CSV s podpičjem in UTF-8 BOM za Magento; XLSX za to, kar
   človek odpre in ureja.
5. **Vsak izvoz ima zgodovino** — kdaj, kdo, koliko vrstic, uspeh/napaka, na eni podstrani.
   — vrzel.
6. **Nič ne sme tiho odpasti.** Izpuščena vrstica mora biti vidna kot **število in razlog**,
   ne kot razlika med katalogom in datoteko. Danes je polnost celic 8,2 % — dokler ni te
   številke v vmesniku, uporabnik tega ne more videti.
7. **Gumb »Izvozi« na seznamu** izvozi trenutni filtriran ali izbran pogled. To je nekaj
   drugega kot kanalski izvoz na `izvozi` in se ne sme zamenjati.

---

## 6. Načela, ki vodijo vsako novo stran

Pogodba vsake strani je v `docs/PRODUKTNI_MODEL_PIM.md` §5 (deset točk: faza, vir, filtri,
vloge, bralna pot, zapisovalna pot, validacija, opozorilo, prazna stanja, dokaz). Poleg tega:

1. **En koncept = eno mesto.** Ne dodajaj filtra, gumba ali stolpca, ki podvaja nekaj, kar je
   že pokrito. Če se nova možnost zdi nujna, jo najprej preveri z uporabnikom.
2. **Jasna privzeta akcija.** Ena stran, en očiten primarni gumb.
3. **Sistem pove, kaj manjka, ne le da je nekaj narobe.** »Država porekla je obvezna za izvoz
   v EU« je uporabno; »Napaka« ni.
4. **Vsaka številka in vsak status vodita na filtriran seznam**, ki ju pojasni.
5. **Veliki seznami so strežniški** — filtriranje in paginacija na strežniku. Pri 196.531
   artiklih paginacija na odjemalcu ni izvedljiva.
6. **Filter in stran sta v URL**, da povezavo lahko deliš in gumb Nazaj deluje.
7. **Vsako zapisovanje ima uporabnika, čas, staro in novo vrednost ter razlog.**
8. **PIM-lastno in SAOP-lastno polje se obravnavata različno** (§4.3).
9. **Neuspeh se ne skrije za starejšim uspešnim stanjem.**
10. **VIEWER nikoli ne vidi zapisovalnega gumba.**
11. **Poslovni uporabnik vidi razumljiv vzrok, ADMIN in razvijalec tudi tehnične podatke.**
12. **Funkcija brez podatkovnega vira ali varne procedure se ne prikaže kot navidezno delujoč
    gumb.** To je razlog, zakaj je aplikacija danes pretežno bralna — in to je namerno.

---

## 7. Vrstni red prenove strani

Usklajeno z `docs/PRODUKTNI_MODEL_PIM.md` §7 in `NAVIGACIJSKI_SISTEM_IN_FUNKCIJE_STRANI.txt` §6:

1. nadzorna plošča kot resničen operativni povzetek;
2. vhodni podatki in preslikave — **izvedeno 2026-08-24**;
3. seznam in kartica izdelka (naslednji modul);
4. kakovost, manjkajoči podatki in karantena;
5. ERP izhodi in njihova obvestila;
6. spletni izvozi in kontrola CSV-jev;
7. stranke, popusti, cene, ceniki, partnerji in zaloga;
8. uporabniki, vloge, obvestilne politike in sistemske nastavitve;
9. analitika — šele ko so potrjeni zgodovinski viri.

Dokaz za vsak korak je po `AGENTS.md` §3 `scripts\run_tests.ps1` (za intranet vsaj
`-Filter F10`) in uspešen build celotne rešitve. »Videti je v redu« ni dokaz.
