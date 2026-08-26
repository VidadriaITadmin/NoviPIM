# PIM sistem — celovita vizija, želje in stanje

Verzija: 1.0 · Datum: 2026-08-26 · Status: referenčni dokument (sinteza iz razvoja jun–avg 2026)

## 0. Namen dokumenta

Ta dokument je sinteza vsega, kar je bilo doslej dogovorjeno o tem, **kakšen naj bo PIM sistem kot
celota** — ne samo intranet aplikacija, ampak cel tok podatkov, integracije in poslovni cilj. Sestavljen
je iz:
- zahtev in odločitev direktorja/uporabnikov, zbranih skozi delavnice in sprotno delo,
- dejansko izmerjenega stanja repozitorija (kaj deluje, kaj je samo napisano, kaj je pokvarjeno),
- prepoznanih vrzeli in priporočil za naprej.

Arhitekturna pravila in podroben podatkovni model sta v
[`_SPEC/PIM_SISTEM_MENI_Master_Specifikacija.txt`](../../_SPEC/PIM_SISTEM_MENI_Master_Specifikacija.txt) —
ta dokument ju ne podvaja, ampak razlaga POMEN in NAMEN sistema ter kaj od njega uporabniki dejansko
pričakujejo.

---

## 1. Kaj PIM je in zakaj obstaja

PIM ni le "baza artiklov" — je **posredniška plast med tremi svetovi**, ki so si prej podajali podatke
ročno prek Excelov: ERP (SAOP iCenter), dobavitelji/proizvajalci (BT/NW XML, FTP) in spletna prodaja
(Magento). Pred PIM-om je podjetje uvažalo/izvažalo artikle prek **119 ročno vzdrževanih Excel datotek**
(61 za SAOP, 58 za splet), z 39 različicami glave na 61 datotek in ročnimi števci znakov namesto
validacije. PIM naj to nadomesti z enim, nadzorovanim tokom:

```
Vir (SAOP/XML/FTP/ročno) → RAW → NORMALIZE → STG (priprava) → VALIDACIJA → PIM (potrjeno) → IZVOZ
```

Trije kanali so **namenoma neodvisni**: ERP (kar mora priti nazaj v SAOP), Komerciala (interna kontrola)
in Splet (kar gre h kupcu) — artikel je lahko popoln za ERP, a nepripravljen za splet, in obratno.

---

## 2. Kaj sistem danes že zna (povzetek po domenah)

Za popolno sliko (ne le "kaj manjka") — kaj je dejansko zgrajeno in delujoče (stanje avg 2026, testna
baza `DAVID\MSSQL19`, produkcija `IQ-SAOP\SQL01` pogosto zaostaja za testom):

| Domena | Stanje |
|---|---|
| Zajem podatkov | 6 Windows workerjev (SAOP katalog/zaloga, BT XML/zaloga, NW XML/zaloga) z lookback delta sinhronizacijo in dnevnikom tekov |
| Validacija | Trinivojska, šifrant-gnana (ERP po trgu SLO/EU, Komerciala, Splet po strani), issue-driven — status izhaja iz odprtih napak, ne ročnega označevanja |
| Osebna izkaznica artikla | Ločeni zavihki po kanalu, statusi po nivoju vidni v UI, samodejna revalidacija ob shranjevanju |
| Kategorije | Nespremenljiv ID + stabilna koda + izpeljana pot; drevo, premik, zgodovina |
| Zaloga | Poenoten bralni model (`pim.vw_StockUnified`), namerno samo za branje, z atomarnim posnetkom za izvoz |
| Cene | Branje delno popravljeno (4 neodvisne okvare v verigi, glej razdelek 5); pisanje v SAOP še ne |
| Mediji | Ločena shema (`media.*`), a vir je samo XML (SAOP/Excel/ročni vnos slik še ne prispevajo) |
| Stranke / B2B | Register, tipi strank, popusti (skupinski + posebni + S-popust), plačniki, poslovne enote — obsežno zgrajeno |
| Vpis nazaj v SAOP | Tri vrste (artikli ADD/UPDATE, stranke, izločanje iz rezervacije), vse ročno sprožene, brez samodejnega enqueue ob promociji |
| Varnost | Domenska (AD) + lokalna prijava, vloge, dnevnik dejavnosti za ključne akcije |
| Izvoz na splet (Magento) | V prenovi (glej razdelek 5) — dolgo časa ni realno prišlo nič, sedaj v teku pravi kanal |
| Samopostrežna dokumentacija | Grafični prikaz toka + Word priročnik za končne uporabnike (da se zmanjša spraševanje IT-ja) |

---

## 3. Želje direktorja in uporabnikov — kaj sistem MORA omogočati

Zbrano iz vseh dosedanjih zahtev, delavnic in popravkov smeri:

1. **En sistem resnice namesto razpršenih Excelov.** Cilj ni "še ena tabela", ampak da nihče več ne
   vzdržuje ročno 50+ variant iste preglednice. Vsaka nova zahteva (nov proizvajalec, nova spletna
   stran, novo obvezno polje) mora iti skozi šifrant, ne skozi novo Excel kopijo.
2. **Nič ne sme priti na splet ali v ERP brez nadzora kakovosti.** Validacija ni administrativna ovira,
   ampak zaščita pred tem, da bi kupec videl artikel brez cene/slike/naziva, ali da bi ERP dobil
   nepopoln zapis.
3. **Zanesljiv, ne le "trenutno delujoč" tok v ERP in na splet.** Direktor je večkrat izrecno zahteval,
   da se stanje **izmeri**, preden se razglasi za dokončano (primer: izvoz v Magento je bil mesece
   "narejen" po dokumentaciji, dejansko pa ni šlo skozenj nič — glej razdelek 5.1). Vizija je sistem, ki
   pove resnično stanje, ne domnevno.
4. **B2B pravila (popusti, cenik, poštnina, tipi strank) urejena na enem mestu**, ne v glavah ljudi ali
   raztresenih dogovorih po e-pošti. Vsaka izjema (poseben popust za stranko, S-popust za polno
   pakiranje) mora biti podatek z zgodovino, ne enkratni ročni poseg.
5. **Sledljivost vsake spremembe** — kdo, kdaj, zakaj — z možnostjo razveljavitve tam, kjer je to varno
   (ne za polja, ki jih naslednji uvoz vseeno povozi).
6. **En pogled na artikel ne glede na izvor.** Ni pomembno, ali je artikel prišel iz SAOP, BT XML, NW
   XML ali ročnega vnosa — uporabnik vidi eno osebno izkaznico z istimi zavihki in enako logiko
   validacije.
7. **Nadzor nad zalogo in dobavnimi roki v realnem času**, brez tveganja, da bi PIM po pomoti pisal
   količine nazaj v ERP (to je zavestno izključeno — zaloga je pri izvoru).
8. **Odprtost za rast.** Nov proizvajalec, nova spletna stran, nov izvozni kanal mora biti mogoče dodati
   s konfiguracijo (vrstica v šifrantu), ne s prepisovanjem obstoječe kode vsakič znova.
9. **Manj klikov, manj zmede.** Navigacija in kartica artikla naj bosta takšni, da sistem SAM pove, kaj
   je narobe in kje — ne da mora uporabnik uganiti, v katerem od petih zavihkov je težava.
10. **Samopostrežna dokumentacija**, da se direktorja in IT-ja neha spraševati "kako in kaj" — cilj je,
    da "notri vse piše".

---

## 4. Kaj sistem trenutno ne omogoča, pa bi moral (funkcionalne vrzeli)

- **Atributi po kategoriji (Mastri).** Podjetje ima 53 kategorij izdelkov, vsaka s svojim naborom
  16–123 tehničnih atributov (dokazano iz 61 starih master Excelov). Danes je `pim.Attribute` raven
  slovar brez povezave na kategorijo — uporabnik na kartici vidi VSE atribute vseh kategorij naenkrat.
  Manjka `pim.CategoryAttributeMap`, ki bi to uredila in bi hkrati omogočila pravo, ozko uvozno/izvozno
  predlogo po kategoriji namesto ene široke tabele s 150+ stolpci.
- **Sledenje sprememb in razveljavitev (Ctrl+Z).** Načrtovano, ni še kodirano. Danes se popolna
  zgodovina beleži le za ročno urejanje z osebne izkaznice; paketni uvoz in delta nakladalci ne beležijo
  ničesar — če delta nakladalec povozi ročni popravek, sled o tem, kaj je bilo prej, ni ohranjena.
- **Admin urejevalnik kategorij in atributov v Akeneo/Magento slogu.** Drevo kategorij danes je ploska
  filtrirana tabela brez razširi/skrči/povleci; admin stran za atribute (prevodi, vrednosti, uporaba po
  kategorijah) ne obstaja sploh — to je bila izrecna želja uporabnika ("imata to lepo narejeno").
- **Poenoten uvozni/izvozni Excel motor.** Izdelki in Stranke danes uporabljata dve popolnoma različni
  generaciji kode (skupni motor z izbirnikom stolpcev proti ročnemu CSV-ju s fiksnimi glavami) — to
  oteži vzdrževanje in zmede uporabnika, ki pričakuje isto izkušnjo povsod.
- **Prenos artikla med organizacijami** ni prva-razredna funkcija na kartici artikla (obstaja pot prek
  SAOP vrste, a brez gumba "Kopiraj v organizacijo" neposredno iz izdelka).
- **Samodejni izhod v ERP po uspešni validaciji.** Danes je pošiljanje v SAOP vedno ročno sproženo
  (razen izjeme "izloči iz rezervacije") — cilj iz arhitekturnih odločitev je bil avtomatski enqueue ob
  ERP L1 VALID, kar še ni izvedeno.
- **Potrditev pošiljanja v SAOP (Verified, ne le Sent).** "Poslano" danes pomeni le, da je HTTP klic
  uspel — ne da je SAOP spremembo dejansko sprejel in obdržal. Brez echo primerjave se lahko obljublja
  napredek, ki dejansko ni zapisan.

---

## 5. Kaj je bilo pokvarjeno oz. na napačni poti — in kaj je (bilo) popravljeno

Ta razdelek je namenoma odkrit, ker je direktor izrecno cenil izmerjeno resnico nad domnevnim
napredkom.

### 5.1 Izvoz v Magento realno ni prišel nikamor

Mesece so obstajali TRIJE vzporedni izvozi izdelkov brez enotnega naslova — in noben ni pisal
Magentovih imen stolpcev, noben ni imel dejanskega odjemalca (ne SQL Agent job, ne gumb, ne koda). Ko je
bilo to izmerjeno (17. 8. 2026), je bil načrt prepisan od začetka namesto nadaljevan "kot da je bilo
narejeno". Danes je v teku prenova z jasnim kanonom (`pim.OutputChannel`/`OutputColumn`, samostojni
SELECT skripti, PowerShell izvoz brez odvečnih vmesnih tabel) — deloma nameščena na produkciji.

### 5.2 Krog artikla PIM ↔ SAOP je bil pretrgan na treh mestih

Popravek v PIM se je znal tiho izgubiti: (1) izhod v SAOP je bral posnetek SAOP namesto STG, torej je
pošiljal PROTI-spremembo; (2) nihče ni samodejno sprožil pošiljanja; (3) naslednji uvoz iz SAOP je
popravek povozil, ker vir ni vedel, da PIM "poseduje" to polje. Rešitev je register lastništva polj
(kdo sme pisati kaj) + zaklep vrstice po pošiljanju do potrditve — večinoma izvedeno na testu, na
produkciji še ne.

### 5.3 Cenovna veriga je imela štiri neodvisne okvare hkrati

Zamrznjen posnetek, neaktiven izvozni tek, podvojeno štetje zaradi manjkajočega pravila unikatnosti, in
izgubljena DDV-informacija (net/bruto) — vse štiri neodvisno popravljene z novimi migracijami, ne z eno
"popravi vse" zaplato.

### 5.4 Zaloga je imela dve različni resnici

Kartica artikla je brala eno pot (živ RAW), pregled zaloge drugo (predpripravljene izvozne tabele) — z
neskladnimi rezultati. Rešeno s poenotenim bralnim modelom; pisanje nazaj v ERP je bilo zavestno
odločeno, da NIKOLI ne obstaja (to ni vrzel, ampak namerna meja sistema).

### 5.5 Mediji so imeli izgubljeno "vlogo" slike

~85 % slik od enega dobavitelja ni imelo prepoznane vloge (glavna/dodatna/tehnična risba), ker je bil
prevod tipa slike na pol prazen — posledica je bila, da je bila včasih za glavno sliko izbrana tehnična
risba z merami namesto fotografije izdelka. Rešitev: brati izvorni (poljski) podatek namesto že
prevedenega, ker je izvorni ohranjen in deterministično preslikljiv.

### 5.6 Nadzorni sistem je kazal napačno stanje

Nadzornik "ali zaloga prihaja" je bil trajno v napačnem stanju že od uvedbe, ker je gledal dnevnik, kamor
ta worker sploh ni pisal — sistem je torej ves čas javljal alarm, ki ni bil pravi, kar zmanjšuje
zaupanje v VSE alarme. Popravljeno s signali po dejanski tabeli, ne po dnevniku enega procesa.

---

## 6. Strateška vprašanja, ki presegajo samo aplikacijo

- **Ali menjati ERP (Odoo)?** Analiza (avg 2026) je pokazala, da je poslovna logika v BAZI, ne v
  aplikaciji (36.000+ vrstic T-SQL) — "zamenjaj le aplikacijo" ni izvedljivo, ker je baza dejansko
  aplikacija. Priporočilo: ločiti odločitev o ERP od odločitve o bazi; PIM naj **nikoli** ne postane
  modul znotraj ERP-ja, ne glede na to, kateri ERP podjetje na koncu izbere — PIM je neodvisen sloj nad
  katerimkoli ERP-jem.
  Odprto vprašanje, ki blokira nadaljnjo presojo: kateri moduli obstoječega ERP-ja (fakturiranje,
  glavna knjiga, osnovna sredstva, plače) so sploh v uporabi — brez tega je obseg morebitne menjave
  neznan.
- **Migracija baze na PostgreSQL** je ocenjena kot srednje tvegana in izvedljiva (200–340 človek-dni),
  a šele na koncu poti, ne kot samostojen projekt danes.
- **Produkcija zaostaja za testom.** To je varnostna praksa (nič se ne namesti brez preverbe), a pomeni,
  da je treba redno spremljati razkorak — trenutno stanje kaže, da nekatere popravljene domene (cene,
  zaloga snapshot) so na produkciji, druge (K1–K5 krog PIM↔SAOP, del validacijskih poenostavitev) pa še
  čakajo.

---

## 7. Priporočila — kam naprej (prioritete)

Na podlagi potrjenega delovnega seznama (»ERP validacija«, avg 2026, ocena ~35–45 delovnih dni) in
odprtih arhitekturnih načrtov, razvrščeno po tem, kaj najbolj neposredno vpliva na to, da artikel
dejansko pride pravilno na splet in v ERP:

1. **Dokončati Magento izvoz** (produkti + stranke + cene v pravi obliki, z atributi po kategoriji) —
   to je edini kanal, ki neposredno prinaša prihodek, in je bil najdlje "navidezno narejen".
2. **Zapreti krog PIM↔SAOP na produkciji** (lastništvo polj + zaklep vrstice) — brez tega vsak ročni
   popravek v PIM tvega, da ga naslednji uvoz iz SAOP tiho povozi.
3. **CategoryAttributeMap** — brez tega ozka uvozna/izvozna predloga po kategoriji in pravilna kartica
   artikla (samo relevantni atributi) nista mogoča.
4. **Sledenje sprememb / Ctrl+Z** — potreben pogoj za zaupanje uporabnikov, da si upajo urejati v PIM
   namesto v Excelu "za vsak slučaj".
5. **Samodejni izhod v ERP ob validaciji + prava potrditev (Verified)** — zapre zanko avtomatizacije, ki
   je danes povsod ročna.
6. **Poenotenje uvozno/izvoznega motorja** (Izdelki + Stranke isti mehanizem) — zmanjša dvojno
   vzdrževanje in uporabniško zmedo.

---

## 8. Vodilo, ki naj ostane skozi ves nadaljnji razvoj

Iz arhitekturnih pravil master specifikacije, prevedeno v en stavek za vsako od njih:

- **En vir resnice.** Pravilo se doda v šifrant, ne v novo `IF` v proceduri.
- **Kakovost izhaja iz napak, ne iz ročnega označevanja.** Status se izračuna, ne kopira.
- **Trije kanali (ERP/Komerciala/Splet) so neodvisni.** Eden ne sme zahtevati polj drugega brez
  eksplicitnega pravila.
- **STG je prehod, ne skladišče.** Če se podatek tam "za vedno" ustavi, je nekaj narobe zgoraj ali
  spodaj v toku.
- **OrganizationId je povsod.** Brez izjeme — tudi kadar se zdi, da bi bilo "začasno" lažje brez njega.
