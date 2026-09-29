# Dobre prakse profesionalnih PIM sistemov — povzetek za gradnjo našega PIM

Stanje raziskave: 2026-09-29. Viri: uradna dokumentacija Akeneo (help.akeneo.com, api.akeneo.com),
Pimcore (docs.pimcore.com), inriver, Plytix, Adobe Commerce (experienceleague.adobe.com) in nekaj
strokovnih člankov o povezavi PIM–ERP. Besedila so povzeta s svojimi besedami; ob vsakem razdelku
so navedeni viri. Marketinške trditve proizvajalcev (npr. Syndigo o konkurenci) so označene kot take.

Na koncu sta razdelka **Primerjava z našim PIM** (s potmi v kodi) in **Pravila gradnje strani**.

---

## 1. Podatkovni model profesionalnega PIM

### 1.1 Družine (families) in skupine atributov (attribute groups)

- **Družina** je predloga nabora atributov. Izdelek pripada natanko eni družini in s tem »podeduje«
  seznam atributov, ki jih sme imeti. Družina hkrati določa, kateri atributi so **obvezni po kanalu**
  (npr. splet zahteva opis in sliko, tisk ne zahteva slike). To je osnova za izračun popolnosti.
- Ko atribut dodaš v družino, privzeto **ni obvezen** za noben kanal; obveznost se nastavi posebej.
  Edini samodejno obvezen atribut je identifikator (šifra).
- **Skupina atributov** je organizacijska enota (»Tehnični podatki«, »Marketing«, »Logistika«). Ne
  vpliva na to, katere atribute izdelek ima, ampak na (a) razporeditev obrazca, (b) **pravice** (kdo
  sme videti/urejati skupino) in (c) delovne tokove (korak obogatitve zajame določene skupine).
- Pimcore namesto družin uporablja **razrede** (classes) z definiranimi polji; za spremenljive nabore
  ima **Object Bricks** (dodatni blok polj, ki ga pripneš le določenim izdelkom, npr. »svetilo«) in
  **Classification Store** (dinamičen ključ/vrednost z ravnmi ključ → skupina → zbirka skupin; podpira
  dedovanje in jezike). Classification Store je v bistvu nadzorovan EAV za tehnične lastnosti.
- Magento/Adobe Commerce ima **nabor atributov** (attribute set) kot predlogo po vrsti izdelka.

Za nas: naš ekvivalent družine je `canon.CategoryAttributeSet` (nabor po drevesu/kategoriji z ravnmi
REQUIRED/RECOMMENDED/EXCLUDED in dedovanjem po drevesu navzdol). To je bližje Plytix/inriver pristopu
»nabor po kategoriji« kot Akeneo »družina neodvisno od kategorije«. Za distributerja svetil je to
smiselno, ker kategorija že opisuje vrsto izdelka.

Viri: https://api.akeneo.com/concepts/catalog-structure.html ·
https://help.akeneo.com/serenity-build-your-catalog/30-serenity-manage-your-families-and-variant-families ·
https://docs.pimcore.com/platform/Pimcore/Objects/ ·
https://docs.pimcore.com/platform/Pimcore/Objects/Object_Classes/Data_Types/Classification_Store/ ·
https://experienceleague.adobe.com/en/docs/commerce-admin/catalog/product-attributes/create/attribute-sets

### 1.2 Vrste atributov in njihove lastnosti

Akeneo ima zaprt seznam vrst: identifikator, kratko besedilo, dolgo besedilo, enojna izbira, večkratna
izbira, da/ne, datum, število, **meritev** (število + enota), **cena** (zbirka po valutah), slika,
datoteka, zbirka sredstev (DAM), povezava na referenčno entiteto/referenčne podatke, **tabela**
(vrstice s stolpci, npr. sestavine ali tehnične tabele) in povezava na izdelek.

Lastnosti atributa, ki so v profesionalnih PIM standard:

| Lastnost | Pomen |
|---|---|
| koda | stabilen, nespremenljiv ključ; oznake so ločene in prevedene |
| skupina | obvezna, za obrazec, pravice in tokove |
| enoličnost | vrednost se ne sme ponoviti med izdelki (EAN) |
| vrednost po jeziku (localizable) | za vsak jezik svoja vrednost |
| vrednost po kanalu (scopable) | za vsak kanal svoja vrednost (npr. krajši opis za tisk) |
| jezikovno specifičen | atribut obstaja samo v določenih jezikih |
| uporaben kot filter/stolpec mreže | ali gre v iskalni indeks in mrežo |
| iskalen v glavnem iskalniku | največ ~20 besedilnih atributov |
| samo za branje (read-only) | ni urejanja v UI; piše samo uvoz, API ali pravilo (Enterprise) |
| validacija | največja dolžina, regularni izraz, e-pošta/URL, min/max, decimalke, negativna števila, dovoljene končnice in velikost datotek, datumski razpon |
| možnosti (options) | pri izbirah; oznake po jezikih, razvrščanje, združevanje podvojenih možnosti, samodejno ustvarjanje ob uvozu (nastavljivo) |
| zgodovina | vsaka sprememba definicije atributa je sledljiva |

inriver ima podobno: polja z vrsto (String, LocaleString, Integer, Double, Boolean, DateTime, CVL,
File, XML), **CVL** (kontrolirani seznami vrednosti) in izraze v slogu Excela za izračunane vrednosti.

Viri: https://help.akeneo.com/serenity-build-your-catalog/serenity-manage-your-attributes ·
https://api.akeneo.com/concepts/catalog-structure.html ·
https://sivertbertelsen.dk/articles/inriver-pim-system

### 1.3 Jeziki in kanali (locales, channels/scopes)

- Vrednost izdelka je v Akeneo zapisana kot trojček **(podatek, jezik, kanal)**; jezik in kanal sta
  prazna, če atribut ni lokaliziran oz. kanalski. Isti atribut ima torej lahko do »jeziki × kanali«
  vrednosti.
- **Kanal** (npr. e-trgovina, tisk, mobilno) določa: katere jezike ima, katere valute, katero drevo
  kategorij izvaža in v katere **enote** se pretvorijo meritve ob izvozu.
- Magento ima analogne **obsege** (scope): globalno, spletno mesto (npr. cena po državi), pogled
  trgovine (jezik). Menjava obsega atributa po vnosu podatkov lahko izgubi vrednosti — pravilo:
  obseg odloči pred polnjenjem.
- Uporabnik v mreži in obrazcu izbere **delovni jezik in delovni kanal**; to vpliva na prikazane
  vrednosti, popolnost in iskanje. To je ločeno od jezika vmesnika.

Viri: https://api.akeneo.com/concepts/products.html ·
https://help.akeneo.com/serenity-take-the-power-over-your-products/serenity-get-familiar-with-the-product-grid ·
https://experienceleague.adobe.com/en/docs/commerce-admin/catalog/product-attributes/product-attributes-add

### 1.4 Variante (product models)

- Akeneo: **produktni model** združi izdelke, ki se razlikujejo le po nekaj lastnostih. **Družina
  variant** določi **osi variacije** (npr. barva, moč) in do dve ravni (model → pod-model → variantni
  izdelek). Vsak atribut družine se ureja na natanko eni ravni.
- V obrazcu so podedovane vrednosti na nižji ravni prikazane **zaklenjeno s pojasnilom**, kje se
  urejajo; navigacija med variantami je na vrhu obrazca.
- Popolnost modela je razmerje **»X/Y variant popolnih«** z barvo (rdeče/rumeno/zeleno).
- inriver: Product (skupni) → Item (prodajni SKU); Pimcore: dedovanje starš/otrok na ravni objekta
  in polja (Object Bricks polno podpirajo dedovanje po polju).

Viri: https://help.akeneo.com/v7-take-the-power-over-your-products/v7-enrich-your-products-with-variants ·
https://api.akeneo.com/concepts/products.html · https://sivertbertelsen.dk/articles/inriver-pim-system

### 1.5 Kategorije in drevesa

- Kategorije tvorijo **drevesa** poljubne globine; izdelek je lahko v več kategorijah in več drevesih.
- Drevesa imajo dve vlogi: **poslovno/prodajno** (splet, tisk — vsak kanal izvozi svoje drevo) in
  **upravljavsko** (governance — za pravice in odgovornost). Pri pravicah Akeneo za kombinacijo dreves
  uporabi najstrožjo pravico (izdelek vidiš le, če smeš v obeh).
- Kategorije imajo lahko lastne atribute (opis, slika, SEO), prevode in zgodovino.

Viri: https://api.akeneo.com/concepts/catalog-structure.html ·
https://help.akeneo.com/serenity-permissions/40-serenity-set-rights-on-your-catalog

### 1.6 Asociacije (povezani izdelki)

- **Vrste asociacij** so šifrant (navzkrižna prodaja, nadgradnja, nadomestni, pribor, rezervni del).
  Asociacija kaže na izdelke, produktne modele ali skupine.
- **Kvantificirane asociacije** nosijo še količino (komplet: 1 svetilo + 2 žarnici).
- Asociacije se urejajo v zavihku obrazca, množično iz mreže in prek uvoza; variante jih podedujejo.

Viri: https://api.akeneo.com/concepts/products.html ·
https://help.akeneo.com/v7-take-the-power-over-your-products/v7-bulk-actions-on-products

### 1.7 Mediji in DAM

- Preprosti PIM ima atribut **slika/datoteka**; zreli imajo **Asset Manager/DAM**: sredstvo je
  samostojen zapis z lastnimi atributi (avtorske pravice, jezik, vrsta pogleda, datum veljavnosti),
  **različicami** in pretvorbami (sličice, format za kanal), povezano na več izdelkov.
- inriver: **Resource** je lastna entiteta z metapodatki in verzijami. Plytix: mediji so ločena
  knjižnica, filtri »ima/nima medij«.
- Dobre prakse: vloga slike (glavna, galerija, tehnična risba, certifikat), vrstni red, samodejno
  pripenjanje po pravilu imena datoteke, zamenjava brez izgube povezav.

Viri: https://help.akeneo.com/serenity-manage-your-images-files-assets/16-serenity-work-on-your-assets ·
https://help.akeneo.com/akeneo-dam-prepare/how-to-view-and-restore-a-previous-version-of-an-asset ·
https://sivertbertelsen.dk/articles/inriver-pim-system

### 1.8 Enote (measurement families)

- **Družina mer** združuje enote iste količine (dolžina, masa, moč, svetlobni tok). Ena enota je
  **standardna**; vsaka druga ima pretvorbo do nje, pretvorba med poljubnima enotama gre prek standardne.
- Vrednost se hrani **skupaj z enoto, v kateri je bila vnesena**; **kanal** določi, v katero enoto se
  ob izvozu pretvori. Tako uvoz ne izgubi izvirnika, izhod pa je enoten.
- Pimcore ima podoben tip »Quantity Value« z enotami.

Viri: https://help.akeneo.com/serenity-discover-akeneo-concepts/serenity-what-about-measurements ·
https://help.akeneo.com/serenity-build-your-catalog/35-serenity-manage-your-measurements ·
https://github.com/akeneo/MeasureBundle

### 1.9 Referenčni podatki (reference entities)

- Za pojme, ki so več kot seznam možnosti (proizvajalec/znamka, kolekcija, material, certifikat),
  ima Akeneo **referenčne entitete**: vsak zapis ima svoje atribute (logotip, opis, država), izdelek
  pa samo povezavo nanj. Sprememba zapisa velja za vse izdelke hkrati.
- Pravilo: če ima vrednost izbire lastne podatke ali prevode, ki niso samo oznaka, naj bo
  referenčna entiteta, ne besedilo na izdelku.

Viri: https://api.akeneo.com/concepts/catalog-structure.html ·
https://api.akeneo.com/concepts/target-market-settings.html

---

## 2. Kakovost podatkov

### 2.1 Popolnost (completeness)

- Popolnost se računa **za vsak par kanal × jezik**: delež obveznih atributov družine za ta kanal,
  ki imajo vrednost v tem jeziku. 100 % pomeni »vse obvezno je izpolnjeno«, ne »vse je izpolnjeno«.
- Preračuna se **ob vsakem dogodku**, ki lahko spremeni rezultat: shranjevanje, uvoz, množično
  dejanje, pravilo, sprememba družine. Rezultat je shranjen (ni izračun ob prikazu), zato ga mreža
  lahko filtrira in razvršča.
- Prikaz na štirih mestih: (1) **nadzorna plošča** — napredek po kanalu/jeziku; (2) **stolpec v
  mreži** z odstotkom za izbrani kanal/jezik in filter »popoln/nepopoln«; (3) **glava obrazca** z
  vrstico napredka; (4) **plošča manjkajočih atributov** — seznam praznih obveznih polj, klik skoči na
  polje. Pri modelih razmerje popolnih variant.
- Plytix: **atribut popolnosti** je poimenovan po cilju (»Pripravljeno za splet«, »Amazon«); filter
  »ni enako 100« in lebdeči prikaz manjkajočih polj. inriver: **skupine popolnosti** po kanalu in
  pregled pripravljenosti kanala.
- Pimcore: ocene kakovosti kot dodatni stolpci mreže (filtrirni in razvrstljivi), zavihek »Data
  Quality Details« s seznamom izpolnjenih/manjkajočih polj; ocena se preračuna ob shranjevanju.

Viri: https://help.akeneo.com/serenity-your-first-steps-with-akeneo/serenity-understand-product-completeness ·
https://help.plytix.com/en/completeness-tracking ·
https://community.inriver.com/hc/en-us/articles/360019449334-Can-you-have-different-completeness-rules-for-different-products ·
https://docs.pimcore.com/platform/Data_Quality_Management/ ·
https://docs.pimcore.com/platform/next/Data_Quality_Management/Visualization/

### 2.2 Ocena kakovosti in pravila validacije

- Akeneo **Data Quality Insights**: dve osi — **obogatitev** (izpolnjenost obveznih in neobveznih
  atributov) in **doslednost** (črkovanje, velike začetnice, dolžine, oblika besedila). Rezultat je
  ocena **A–E**, porazdelitev po katalogu, kanalu in jeziku ter trend po dnevih/tednih/mesecih; v
  obrazcu so **konkretna priporočila**, kaj popraviti.
- Validacija je na treh ravneh: (1) **tip in omejitve atributa** (ne da se shraniti napačne vrednosti),
  (2) **obveznost po kanalu** (ne blokira shranjevanja, zniža popolnost), (3) **pravila** (rules
  engine), ki samodejno nastavijo, kopirajo ali sestavijo vrednosti in jih uporabljajo tudi kot
  popravek (npr. odstranjevanje presledkov).
- Syndigo poudarja validacijo na ravni atributa in skladnost po zahtevah trgovca (tržna trditev, a
  vzorec je pravi: pravila po ciljnem kanalu).

Viri: https://help.akeneo.com/serenity-your-first-steps-with-akeneo/serenity-understand-data-quality ·
https://help.akeneo.com/serenity-take-the-power-over-your-products/serenity-improve-data-quality ·
https://help.akeneo.com/v7-build-your-catalog/v7-get-started-with-the-rules-engine ·
https://syndigo.com/syndigo-vs-akeneo/

### 2.3 Pravila (rules engine)

- Pravilo = **pogoji** (filtri kot v mreži) + **dejanja** (nastavi, kopiraj iz atributa v atribut ali
  jezik v jezik, sestavi/združi, dodaj/odstrani kategorije, izračunaj, počisti). Pravila se ustvarijo
  v UI ali uvozijo; zaženejo se ročno, po urniku in samodejno na koncu uvozov/množičnih dejanj.
- Atribut, ki ga polni pravilo, je običajno **samo za branje** v UI — da uporabnik ne ureja nečesa,
  kar bo pravilo povozilo.
- Pomembna podrobnost: kopiranje med izbirnimi atributi uporablja kode možnosti; ciljne možnosti
  morajo obstajati.

Viri: https://help.akeneo.com/serenity-build-your-catalog/manage-your-rules ·
https://help.akeneo.com/v7-boost-your-productivity/v7-manage-your-rules

---

## 3. Delovni tokovi, vloge in zgodovina

### 3.1 Obogatitev in odobritev (drafts & proposals)

- Akeneo EE: kdor ima na kategoriji pravico **urejanja**, ne pa **lastništva**, s shranjevanjem ustvari
  **osnutek** (stanje »v delu«); spremenjena polja so označena. Z gumbom **»Pošlji v odobritev«** (z
  neobveznim komentarjem) postane **predlog** (»čaka odobritev«).
- **Lastnik** v pregledu vidi razliko staro/novo in lahko **odobri vse, zavrne vse ali delno
  odobri/zavrne posamezna polja**. Odobreno se združi v delovno kopijo, zavrnjeno ostane v osnutku.
  Obe strani dobita obvestilo (s komentarjem).
- Izdelek med čakanjem ostane nespremenjen za vse ostale — osnutek je ločen sloj.
- **Collaboration Workflows** (novejše): zaporedni koraki **obogatitve** in **pregleda**; vsak korak ima
  skupino uporabnikov, nabor kanalov, jezikov in skupin atributov, rok v dneh. Izdelki vstopijo po
  filtru (enkratno ali stalno — ob spremembi določenega atributa znova). Uporabnik ima **»Moja
  opravila«** z roki in opozorili, pregledovalec lahko **vrne s komentarjem**. Dnevnik toka 30 dni.
- Pimcore: splošen **workflow** z **mesti** (places) in **prehodi** (transitions); prehod ima pogoje
  (guards), lahko zahteva opombo; na mesto so vezane **pravice** (npr. »zaključen« = zaklenjen) in
  prilagojen pogled obrazca; vsak prehod gre v »Notes & Events«.

Viri: https://help.akeneo.com/en_US/serenity-boost-your-productivity/serenity-workflow-proposals ·
https://help.akeneo.com/serenity-boost-your-productivity/manage-your-enrichment-workflows ·
https://docs.pimcore.com/platform/Pimcore/Workflow_Management/ ·
https://docs.pimcore.com/pimcore/10.4/Development_Documentation/Workflow_Management/Permissions.html

### 3.2 Vloge in pravice

Dve ločeni plasti:

1. **Pravice vlog (ACL)** — katere strani in dejanja obstajajo zame (uvoz, izvoz, množična dejanja,
   brisanje, nastavitve). Vsako množično dejanje ima svojo pravico **in** splošno pravico za množična
   dejanja.
2. **Pravice nad katalogom** po oseh **kanal → jezik → kategorija → skupina atributov**, z ravnmi
   *ni / ogled / urejanje* (+ *lastnik* pri kategorijah). Za podrejeno os moraš imeti vsaj ogled
   nadrejene.

Pravila kombiniranja: več kategorij ali več skupin uporabnikov → **najbolj ohlapna** pravica; več
dreves (upravljavsko + prodajno) → **najstrožja**. Ogled na kategoriji povozi urejanje na skupini
atributov.

**UI pravilo (pomembno):** *brez pravice* → element se **ne prikaže** (kategorija, zavihek, skupina
atributov, stolpec in filter v shranjenih pogledih); *samo ogled* → polje je **prikazano, a sivo**.
Isti pravice veljajo za uvoz/izvoz in API (uvoz lahko glede na pravico posodobi, ustvari osnutek ali
zavrne).

Viri: https://help.akeneo.com/serenity-permissions/40-serenity-set-rights-on-your-catalog ·
https://www.bounteous.com/insights/2022/03/01/understanding-akeneo-catalog-rights-and-workflow-management/ ·
https://api.akeneo.com/documentation/permissions.html

### 3.3 Zgodovina verzij in razveljavitev

- Vsako shranjevanje ustvari **verzijo**: avtor, čas na sekundo, stara in nova vrednost po polju.
  Uvoz ima nastavitev, ali zgodovino piše sproti (počasneje) ali ne.
- **Obnova verzije** (Akeneo EE, Pimcore) ne briše zgodovine, ampak ustvari **novo verzijo**, ki je
  enaka izbrani stari. Pimcore omogoča primerjavo dveh verzij in objavo izbrane verzije, število
  hranjenih verzij je nastavljivo.
- Ustavitev dolgega opravila **ne razveljavi** že narejenega — to UI pove izrecno.

Viri: https://help.akeneo.com/v7-take-the-power-over-your-products/v7-restore-a-previous-product-version ·
https://docs.pimcore.com/platform/Pimcore/Content_Management_Features/Versioning/ ·
https://www.sitation.com/blog/akeneo-product-version-history/

---

## 4. Uvozi in izvozi

### 4.1 Profili

- **Profil** = shranjena konfiguracija opravila (vrsta, datoteka, ločilo, ovojni znak, decimalni
  ločilnik, oblika datuma, privzeto stanje izdelka, stolpci za kategorije/družino, »primerjaj
  vrednosti« — preskoči nespremenjene, »sprotna zgodovina« da/ne). Profil ima pravice (kdo ga sme
  zagnati/urejati), zaženeš ga ročno ali po urniku.
- Izvozni profil ima še **filtre** (kanal, jeziki, popolnost, kategorije, obdobje sprememb — »samo
  spremenjeni od zadnjega izvoza«) in **izbor atributov**.
- **Hitri izvoz** iz mreže: izbrani izdelki ali ves filter, z izbiro »stolpci mreže« ali »vsi atributi«.
- Akeneo Tailored Import/Export: **preslikava stolpec → atribut** z verigo **pretvorb** (razdeli,
  počisti, pretvori enoto, preslikaj vrednost) in predogledom na vzorčni vrstici.
- Pimcore Data Importer: urejevalnik preslikav z **živim predogledom vira in vsakega koraka
  pretvorbe**; zagon ročno, po cron izrazu, iz ukazne vrstice ali prek potisnega (push) vmesnika.

Viri: https://help.akeneo.com/v7-importexport-data/v7-import-your-data ·
https://help.akeneo.com/import-export-data/13-serenity-quick-export-your-products ·
https://help.akeneo.com/import-export-data/schedule-and-automate-your-product-imports-exports ·
https://docs.pimcore.com/platform/Data_Importer/

### 4.2 Opravila v ozadju, napredek, poročila

- Vse, kar je dolgo (uvoz, izvoz, množično dejanje, pravila, odobritev predlogov), gre **v vrsto** in
  teče v ozadju; uporabnik dela naprej. Ob zagonu kratko sporočilo, ob koncu **obvestilo** z
  **povezavo na poročilo**. Obvestilo dobi samo sprožitelj.
- **Sledilnik opravil** (process tracker): seznam z imenom, vrsto, sprožiteljem in stanjem (*v vrsti,
  teče, ustavljanje, ustavljeno, zaključeno, neuspešno, začasno ustavljeno*), filtri po imenu, vrsti,
  uporabniku, stanju.
- **Podrobnost opravila**: koraki z ocenjenim časom, števci (prebrano, zapisano, preskočeno),
  opozorila; na zaslonu največ ~100 napak, **celotno poročilo kot XLSX** z vrstico, stolpcem in
  razlogom. Klasični uvoz izdelek z napako **preskoči**, ostale uvozi.
- **Ustavitev** je mogoča za izvoze, večino uvozov, množična dejanja, pravila; izrecno piše, da se
  že narejeno ne povrne.
- Pimcore Data Importer loči **pripravo** (branje in razbitje vira v vrsto) in **obdelavo** (delavci iz
  vrste, zaporedno ali vzporedno). Priprava se ne zažene, dokler vrsta ni prazna (prepreči tekme).
  **Delta preverjanje** preskoči zapise, ki se od zadnjega uvoza niso spremenili. **Čistilni korak**
  obravnava zapise, ki jih v viru ni več (skrij ali izbriši — nastavljivo). Zavihek dnevnika po profilu.

Viri: https://help.akeneo.com/import-export-data/12-serenity-follow-your-jobs-execution ·
https://help.akeneo.com/v7-take-the-power-over-your-products/v7-bulk-actions-on-products ·
https://docs.pimcore.com/platform/Data_Importer/Import_Execution_Details/

---

## 5. UX vzorci (najpomembnejše)

### 5.1 Mreža izdelkov (product grid)

**Filtri**
- Filtri na sistemskih lastnostih (družina, stanje, popolnost, datum ustvarjanja/spremembe,
  identifikator, pravice) in **na vsakem atributu, ki je označen kot filtrabilen** — za vsako vrsto
  atributa ustrezni operatorji (vsebuje, je prazno, med, je eden od …).
- **Upravljanje filtrov** na enem mestu (iskanje, dodaj/odstrani), **»počisti vse«**, omejitev
  števila aktivnih filtrov (Akeneo: 30) z jasnim obvestilom.
- **Filter kot povezava**: stanje mreže se da kopirati in deliti.
- Filter drevesa kategorij v levem stolpcu (z možnostjo »vključi podkategorije« in »nerazvrščeni«).

**Stolpci**
- **Izbira stolpcev** (dodaj/odstrani), **premikanje s povleci-spusti**, **pripenjanje** (npr. naziv
  ostane levo ob vodoravnem drsenju), **podvojen stolpec** za primerjavo dveh jezikov drug ob drugem.
  Omejitev (Akeneo: 50), nad katero se izklopi urejanje v celici.
- Urejanje v celici (inline) v novejših mrežah (Akeneo Advanced Grid, Plytix »kot preglednica« z
  lepljenjem več celic, inriver Table View). Syndigo trdi, da ga Akeneo nima — to je zastarela tržna
  trditev.

**Shranjeni pogledi (views)**
- Pogled shrani **celotno stanje**: filtre, stolpce, razvrščanje, kanal, jezik. Izbirnik pogledov je
  na vrhu. **Zvezdica** označuje neshranjene spremembe trenutnega pogleda. Ob naslednjem obisku se
  naloži zadnji uporabljeni; uporabnik nastavi **privzeti pogled**. Pogledi so osebni ali javni
  (skupni ekipi).
- Plytix loči **pametne sezname** (dinamični, po filtrih — npr. »stanje = končano in popolnost =
  100 %«) in **statične sezname** (ročno dodani izdelki, npr. za stranko); seznam je tudi vhod za
  izvoz in kanal. inriver: **Workareas** = shranjena iskanja kot skupni delovni prostori.

**Izbira in množična dejanja**
- Potrditveno polje na vrstici; spustni meni v glavi: **»Vse« (vsi, ki ustrezajo filtru, tudi na
  drugih straneh)**, **»Vse vidne«** (trenutna stran), **»Nič«**. Pri izbiri se prikaže **orodna
  vrstica** s številom izbranih in dejanji.
- Nabor dejanj: uredi vrednosti atributov (zamenjaj), dodaj vrednosti (večkratne izbire), odstrani
  vrednosti, spremeni družino, spremeni stanje, dodaj/premakni/odstrani kategorije, poveži izdelke,
  dodaj v delovni tok, zaporedno urejanje, hitri izvoz, izbriši.
- Množično dejanje velja **samo za izbrani kanal/jezik**, teče v ozadju, na koncu se samodejno
  zaženejo pravila, rezultat v sledilniku.
- **Zaporedno urejanje** (sequential edit): izbrane izdelke odpreš enega za drugim v obrazcu s
  »prejšnji/naslednji« — zelo uporabno za urednike.

**Iskanje**
- Iskalna vrstica išče po identifikatorju in nazivu (+ označenih besedilnih atributih), »vsebuje«,
  rezultati sproti, upošteva izbrani jezik. **Globalno iskanje** (Ctrl+K) po vseh entitetah.

**Listanje**
- 25/50/100 na stran, izbira se zapomni; mreža prikaže največ 10.000 zadetkov (nad tem je treba
  filtrirati) — to je zavestna omejitev za odzivnost.

Viri: https://help.akeneo.com/serenity-take-the-power-over-your-products/serenity-get-familiar-with-the-product-grid ·
https://help.akeneo.com/v4-boost-your-productivity/140-v4-manage-your-views ·
https://help.akeneo.com/v7-boost-your-productivity/v7-sequentially-edit-your-products ·
https://help.plytix.com/en/create-and-manage-product-lists ·
https://help.plytix.com/en/navigating-the-product-overview-page ·
https://sivertbertelsen.dk/articles/inriver-pim-system

### 5.2 Obrazec izdelka

- **Zavihki**: atributi, sredstva (mediji), kategorije, asociacije, **zgodovina**, **komentarji**
  (+ v EE predlogi, kakovost).
- **Navigacija po skupinah atributov** (spustni seznam ali stranski meni) in filter **»samo manjkajoči
  obvezni«** — urednik vidi natanko tisto, kar mora izpolniti.
- **Glava**: naziv, slika, družina, stanje, **popolnost** za izbrani kanal/jezik, izbira kanala in
  jezika; kanal/jezik lahko menjaš, urejaš več kombinacij in shraniš vse naenkrat.
- **Primerjaj/prevedi**: ob urejanem jeziku se pokaže referenčni jezik (ali kanal) samo za branje;
  gumb za kopiranje vrednosti (vse, vidne, nobene) iz referenčnega v ciljni jezik.
- **Zaklenjena polja**: atribut »samo za branje« (npr. ker ga piše ERP ali pravilo) je siv; podedovana
  polja variant so siva z napotkom, kje se urejajo. Polje ima majhno oznako jezika/kanala, če je
  lokalizirano/kanalsko.
- **Shranjevanje**: en gumb »Shrani« zgoraj desno; spremenjena polja označena; opozorilo ob odhodu.
- **Zgodovina** v zavihku: verzija, avtor, čas, polje, staro → novo; v EE gumb »Obnovi«.
- **Plošča kakovosti** s priporočili (npr. »opis vsebuje črkovalno napako«).

Viri: https://help.akeneo.com/serenity-take-the-power-over-your-products/serenity-enrich-your-product ·
https://help.akeneo.com/v7-take-the-power-over-your-products/v7-enrich-your-products-with-variants ·
https://help.akeneo.com/v7-build-your-catalog/v7-manage-your-attributes

### 5.3 Nadzorna plošča in obvestila

- Nadzorna plošča: **popolnost po kanalu/jeziku** (vrstice napredka), porazdelitev kakovosti A–E s
  trendom, zadnja opravila, pri EE **predlogi, ki čakajo name**, pri tokovih **»Moja opravila«** z
  roki in zamudami.
- Obvestila: zvonec z neprebranimi; dogodki — konec mojega opravila (s povezavo na poročilo), predlog
  za odobritev, odobren/zavrnjen predlog (s komentarjem), vrnjeno opravilo toka. Nastavitve obvestil
  po uporabniku; e-poštni tedenski povzetek in dnevni opomnik za zavrnjena opravila.

Viri: https://help.akeneo.com/serenity-your-first-steps-with-akeneo/serenity-understand-product-completeness ·
https://help.akeneo.com/serenity-boost-your-productivity/manage-your-enrichment-workflows ·
https://help.akeneo.com/en_US/serenity-boost-your-productivity/serenity-workflow-proposals

### 5.4 Pravice v UI

- **Ni pravice → skrij** (menijska postavka, zavihek, skupina atributov, stolpec, filter, jezik v
  izbirniku). **Samo ogled → prikaži sivo** (uporabnik vidi podatek, ne more ga spremeniti, in ve,
  zakaj). Dejanja, ki jih uporabnik ne sme izvesti, se ne pojavijo v meniju množičnih dejanj.
- Pravica se **vedno** preveri tudi na strežniku (uvoz, API, množično dejanje).

Vir: https://help.akeneo.com/serenity-permissions/40-serenity-set-rights-on-your-catalog

---

## 6. Zmogljivost in arhitektura pri 100k+ izdelkih

- **Akeneo je opustil klasični EAV** (ena vrstica na vrednost). Pri stranki z 1,3 milijona SKU je EAV
  dal slabe poizvedbe in slabo vertikalno skalabilnost. Danes: **MySQL + vrednosti izdelka kot en JSON
  dokument v stolpcu (`raw_values`) + Elasticsearch** za iskanje, filtre, mrežo in popolnost.
  Relacijski del hrani strukturo (družine, atributi, kategorije), JSON celoten izdelek (branje enega
  izdelka = ena vrstica), indeks pa vse, kar se filtrira.
- Indeks se osveži **ob vsaki spremembi izdelka** (asinhrono). Mreža nikoli ne bere relacijske baze
  vrstico za vrstico — dobi ID-je iz indeksa in nato naloži samo prikazano stran.
- Zato mreža omeji zadetke (10.000), število stolpcev (50) in filtrov (30); atribut mora biti
  **izrecno** označen kot filtrabilen/iskalen, da gre v indeks.
- Vse težko (množična dejanja, uvozi, izvozi, preračun popolnosti, pravila) je **asinhrono** v vrsti z
  delavci; uvoz ima »primerjaj vrednosti« (preskoči nespremenjene) in izklop sprotne zgodovine za
  hitrost. Pimcore dodaja **delta preverjanje** in vzporedne delavce.
- Pimcore: vsak razred ima svojo **tabelo s stolpci** (ne EAV) + ločene tabele za lokalizirana polja;
  EAV le v Classification Store, kjer je dinamika potrebna.
- Pravilo palca, ki ga navajajo vsi: **shrani izračunano** (popolnost, ocena, pripravljenost) in to
  filtriraj, namesto da računaš ob prikazu.

Viri: https://medium.com/akeneo-labs/single-product-storage-28d92f35cbd7 ·
https://medium.com/akeneo-labs/story-of-storage-9dbc27090de0 ·
https://www.bounteous.com/insights/2019/11/25/akeneo-turducken-product-information-management/ ·
https://medium.com/@ankit.yadav726/elastic-indexes-in-akeneo-44f2fd94b37c ·
https://docs.pimcore.com/platform/Data_Importer/Import_Execution_Details/

Za nas (MSSQL, ~90.000 izdelkov na podjetje, ~200.000 skupaj): Elasticsearch ni nujen. Ekvivalent je
**bralni model za mrežo** (ena široka tabela/indeksiran pogled na izdelek × podjetje s predizračunano
popolnostjo, stanjem ERP/splet, številom slik, glavno kategorijo), osvežen po spremembi, in
**full-text indeks** MSSQL za iskanje. Naše izkušnje (218, 286, 292/293: validacija na izdelek v
zanki, okenska funkcija namesto NOT EXISTS) potrjujejo isto načelo.

---

## 7. Integracija z ERP

- **Lastništvo po polju, ne po sistemu.** Vsako polje ima enega lastnika (sistem zapisa); drugi
  sistemi imajo kopijo samo za branje. Tipično: ERP ima šifro, ceno, nabavo, zalogo, davek, dobavni
  čas, pakiranje; PIM ima marketinška besedila, prevode, medije, kanalske vsebine, spletne
  kategorije. Tehnične lastnosti pogosto izvirajo pri dobavitelju (sloj dokazov).
- Lastništvo je lahko vezano tudi na **fazo življenjskega cikla** (nov artikel: PIM predlaga, po
  odprtju v ERP lastnik postane ERP).
- **Uveljavitev tehnično**: polje ERP je v PIM samo za branje (Akeneo: atribut read-only, ki ga piše
  samo integracija); obratno PIM polja v ERP niso urejiva. Dokumentiran **seznam polj z lastnikom**, ki
  ga vidijo vse ekipe.
- **Dvosmerna sinhronizacija s filtrom po lastništvu**, da ni zank (polje, ki ga PIM prejme iz ERP, se
  ne pošlje nazaj).
- **Zapis v ERP po tveganju**: nizko tvegano (opis) lahko samodejno; vse, kar vpliva na poslovanje
  (pakiranje, enote, nove šifre, cene), gre skozi **človeško odobritev** z dokazom. Vsak zapis mora
  biti sledljiv in reverzibilen.
- **Konflikti**: ne »zadnji zapis zmaga« za upravljana polja; hrani oba kandidata, rang vira, čas,
  rezultat validacije, izbrano vrednost in kdo je odločil.
- **Idempotenca in potrditev**: ustvarjanje/posodobitev z ključem idempotence; »izvoz brez potrditve
  ni zaključena integracija« — uskladi potrditve in zavrnitve ERP, prikaži zavrnjene in omogoči varen
  ponovni poskus.
- **Verzioniraj preslikave** (kode, taksonomije, stanja) z datumom veljavnosti.
- **Zlati zapis** (golden record, Syndigo/MDM): en potrjen zapis, sestavljen iz več virov po pravilih
  prednosti, s sledjo izvora vsake vrednosti.

Viri: https://getclaro.ai/resources/guides/pim-erp-integration/ ·
https://catsy.com/blog/catsy-pim-erp-integration/ ·
https://humcommerce.com/knowledge-center/the-pim-data-governance-playbook-who-owns-what-and-why-it-matters/ ·
https://www.bluestonepim.com/blog/pim-integration-guide ·
https://help.akeneo.com/v7-build-your-catalog/v7-manage-your-attributes ·
https://syndigo.com/syndigo-vs-akeneo/

---

## 8. Primerjava z našim PIM

Legenda prednosti: **V** = visoka (velik učinek za uporabnike ali tveganje), **S** = srednja,
**N** = nizka / ko bo čas. Poti so relativne na koren repozitorija.

| Funkcija | Profesionalni PIM | Naš PIM (preverjeno) | Priporočilo |
|---|---|---|---|
| Nabor atributov (družina) | družina z obveznostjo po kanalu | `canon.CategoryAttributeSet` po drevesu/kategoriji, ravni REQUIRED/RECOMMENDED/EXCLUDED, dedovanje navzdol (147); stran `/nastavitve/nabori-atributov` (`CategoryAttributeSets.razor`) | Ohrani model po kategoriji. **S**: na kartici in mreži prikaži »nabor« kot vir obveznosti (od kod je zahteva). |
| Skupine atributov | skupina = obrazec + pravice + tok | ni izrecnih skupin; kartica ima fiksne razdelke (ERP, Splet, Kakovost in zgodovina) v `ProductCard.razor` | **S**: uvedi skupine atributov (tehnično, svetlobno, logistika) za razporeditev kartice in filtre; pozneje pravice. |
| Validacija atributa ob vnosu | tip, dolžina, regex, min/max | validacija je po profilih po shranjevanju (`val.FieldRequirement`, `val.RunValidation`); ob vnosu delno | **S**: omejitve na definiciji atributa (`canon.AttributeDefinition`), preverjanje v obrazcu in uvozu. |
| Jeziki in kanali | vrednost (jezik, kanal) | `canon.ProductText.LanguageCode`, `canon.WebSite` (spletišča), kanali `/nastavitve/kanali` (samo branje), profili izvoza po kanalu | Ustrezno. **N**: delovni jezik kot izbira na mreži. |
| Variante | produktni modeli z osmi | ni modela variant (le analitika omenja variante) | **N/S**: za svetila (barve, moči) ovrednoti skupine variant pred Magento konfigurabilnimi izdelki; ne zdaj. |
| Kategorije | več dreves, več kategorij | `svetila_si`, `videlektro`; `ProductCategoryOverride`; `/nastavitve/kategorije`, urejevalnik na kartici | Ustrezno. |
| Asociacije | vrste + kvantificirane, urejanje v obrazcu in množično | `/nastavitve/povezave-izdelkov` samo branje (povezave dobavitelja); `docs/procesi/08-upravljanje/jeziki-kanali-skladisca-povezave.md` | **S**: zavihek »Povezani izdelki« na kartici + ročno dodajanje (pribor/nadomestni) za splet. |
| Mediji / DAM | sredstvo z metapodatki, verzije | `canon.ProductMedia` (vloga PRIMARY, vrstni red), `canon.ProductDocument`, `/mediji`, galerija na kartici | **N**: vloga/tip slike in licenca; DAM ni potreben. |
| Enote | družine mer, standardna enota, pretvorba po kanalu | 301: `canon.AttributeDefinition.Unit`, `canon.UnitConversion`, normalizacija v `val.Promote`; glava katalog.csv »[mm]« (216) | Ustrezno Akeneo pristopu. **S**: prikaz enote ob polju na kartici in opozorilo ob uvozu (že načrtovano v 301). |
| Referenčni podatki | referenčne entitete (znamka …) | partnerji prek `canon.PartnerName`, šifranti `canon.Codebook` | **N**: znamka kot entiteta z logotipom za splet. |
| Popolnost | po kanalu × jeziku, shranjena, 4 prikazi | `val.ProductValidationState.Completeness`, filter `popolnost` (EMPTY/LOW/MID/FULL) v `Products.razor`, glava kartice »skupna popolnost« | **V**: popolnost **po cilju** (ERP, splet svetila, splet videlektro) namesto ene skupne; plošča »manjka« s skokom na polje. |
| Ocena kakovosti / priporočila | A–E, doslednost, trend | `/kakovost`, `QualityProducts.razor`, `PimTrendChart` | **N**: trend popolnosti po tednih na nadzorni plošči. |
| Pravila (rules engine) | pogoj + dejanje, samodejno po uvozu | pravila nazivov (`pim.TitleRule`, `/pravila/nazivi`), slovar, preslikave, S-popusti | **S**: splošna pravila »nastavi/kopiraj« (npr. privzeta vrednost atributa po kategoriji) s predogledom. |
| Osnutki in odobritve | osnutek → predlog → delna odobritev | SAOP: vrsta z odobritvijo (`out.OutboxMessage`, `out.ApproveMessage`, `/saop`, `/outbound`), varovalke 277 (`/varovalke`, `SafeguardReview.razor`) | Za ERP imamo boljše od povprečja. **N**: osnutki za spletna besedila niso potrebni pri naši velikosti ekipe. |
| Delovni tokovi / »Moja opravila« | koraki, roki, dodeljevanje | ni; Nadzorna plošča `Dashboard.razor`, demo »Moj dan« (Desktop\PIM-demo-Akeneo-stil) | **S**: »Moj dan« — moja odprta opravila (varovalke, SAOP odobritve, manjkajoče kategorije) z roki. |
| Vloge (ACL) | pravica na dejanje | 4 vloge, politike v `PIM_Solution/src/PIM.Intranet/Services/PimAuthorization.cs` (CatalogWrite, SaopWrite, BusinessWrite …), `/administracija/vloge` | Ustrezno. Nova pot = nova politika (že pravilo v CLAUDE.md). |
| Pravice po kategoriji/jeziku/skupini | view/edit/own na osi | ni; meja je podjetje (`OrganizationId`) | **N**: ni potrebe, dokler ni zunanjih sodelavcev (prevajalci, dobavitelji). |
| Ni pravice = skrij, ogled = sivo | dosledno | `ReadOnly="@(!CanEdit)"` na kartici, `PimAccessRouteView`, »Samo za branje« prek `PimState` | Ustrezno; drži dosledno na vseh straneh. |
| Zgodovina polja | verzija ob vsakem shranjevanju | `pim.ProductFieldHistory` prek triggerjev (028–038), `pim.SetChangeContext`; razdelek »Kakovost in zgodovina« na kartici | Ustrezno. |
| Razveljavitev | obnova verzije kot nova verzija | procedure `pim.UndoProductField`, `pim.UndoProductBatch` obstajajo, v intranetu jih ne kliče nobena stran; uvoz: `/uvozi` + `?povrni=N` (280) | **V**: gumb »Povrni« ob vrstici zgodovine na kartici (procedura je že tu). |
| Uvozni profili | shranjena konfiguracija, urnik | uvoz delovnega lista `/izdelki/uvoz` (245), XML viri `map.SourceConnector`, preslikave `/pravila/preslikave`, urniki `ops.ScheduleProfile` | Ustrezno. **S**: predogled preslikave na vzorčni vrstici (kot Pimcore). |
| Izvozni profili | filtri + atributi + urnik | `out.ExportProfile`, `out.ExportColumn`, `/izvozi`, `ExportProfileDetail.razor` | Ustrezno. |
| Opravila v ozadju | vrsta, napredek, ustavitev, poročilo | `ExportJobService` (okno izvozov v kotu vsake strani), `HeavyWorkGate`, `/sistem` (`Monitor.razor`, `MonitorJob.razor`), `ops.PipelineRun` | Ustrezno za izvoze. **S**: enoten »sledilnik opravil« za uporabnika (moji uvozi, izvozi, množična dejanja) s prenosom poročila napak XLSX. |
| Poročilo napak uvoza | vrstica, stolpec, razlog, XLSX | `ImportGapsDialog`, `/uvozi` (`ImportRunView.razor`), karantena `/kakovost/karantena` | Ustrezno. **N**: prenos v XLSX, če ga še ni. |
| Delta / preskoči nespremenjeno | »compare values«, delta check | `raw.Inbox` hash, `map.Watermark` | Ustrezno. |
| Mreža: filtri v URL | da | da, vsi filtri, razvrščanje, stran (`[SupplyParameterFromQuery]` v `Products.razor`) | Ustrezno. |
| Mreža: shranjeni pogledi | osebni/javni, privzeti, zvezdica | **ni**; »pogled« v kodi je vnaprej določen filter napak (`ProductListFilter.View`) | **V**: shranjeni pogledi (ime, filtri iz URL, stolpci, razvrščanje; osebni/skupni; privzeti). Poceni, ker je stanje že v URL. |
| Mreža: izbira prikazanih stolpcev | da, povleci, pripni | izbira stolpcev samo za **izvoz** Excel (`Products.razor` ~vrstica 228); prikaz fiksen | **S**: izbira prikazanih stolpcev (vključno z atributi) in shranjevanje v pogled. |
| Mreža: filter po poljubnem atributu | vsak filtrabilen atribut | fiksni filtri (proizvajalec, dobavitelj, skupina, oddelek, ERP, splet, popolnost, slika, kategorija, S, rabat) | **S**: filter »atribut X je prazen / enak / vsebuje« z izbiro atributa (`PimPicker`). |
| Izberi vse, ki ustrezajo filtru | »Vse« / »Vse vidne« / »Nič« | izbira vrstic; S-popust »za izbrane« ali »za cel pogled« (`ApplyBulkAsync`); izvoz izbranih ali celega pogleda | Delno. **V**: enoten gradnik izbire (stran/vse po filtru/nič) in vrstica množičnih dejanj v `Components/Shared`. |
| Množično urejanje atributov | zamenjaj/dodaj/odstrani, kategorije, stanje | množično prek Excel izvoz → uvoz (245); S-popust; ni neposrednega »nastavi atribut za izbrane« | **V**: množična dejanja v mreži: nastavi atribut, dodaj/odstrani kategorijo, objava da/ne — v ozadju, z zgodovino in razveljavitvijo. |
| Zaporedno urejanje | prejšnji/naslednji v obrazcu | ni | **S**: »Uredi izbrane zaporedno« — kartica z »Naslednji (3/40)«; zelo poceni, velik učinek za urednike. |
| Obrazec: skok na manjkajoče | plošča manjkajočih + filter | `MissingRequired(...)` na kartici; izdaje po plasteh (ERP, komerciala, splet) | Delno. **S**: filter »pokaži samo manjkajoče« in sidra na polja. |
| Obrazec: zaklenjena ERP polja | read-only atribut | `pim.FieldOwnership` (PIM/SAOP/SHARED), `pim.SaveProductAttributes` zavrne SAOP polja (52402), `out.OwnershipPolicy`; od 273 PIM takoj + SAOP po odobritvi | Boljše od povprečja (lastništvo po polju + vrsta). **S**: ob polju ikona/čip lastnika (»SAOP«, »čaka odobritev«). |
| Obrazec: primerjava jezikov | referenčni jezik ob strani, kopiraj | nazivi/opisi po jezikih na kartici; `/kakovost/prevodi`; AI predlog v jeziku | **S**: pogled »sl ↔ en/hr« drug ob drugem s kopiranjem in AI prevodom. |
| Opozorilo ob odhodu | da | števec »neshranjenih« in Prekliči/Shrani na kartici | Preveri, da odhod s strani sproži opozorilo (CLAUDE.md §2). |
| Komentarji na izdelku | zavihek komentarjev | ni (le `pim.CustomerNote` pri strankah) | **N**: opombe urednikov na izdelku. |
| Nadzorna plošča | popolnost po kanalu, opravila | `/nadzorna-plosca` (`Dashboard.razor`, `intranet.GetDashboard`) | **S**: popolnost po cilju in trend. |
| Obvestila | zvonec + povezava na rezultat | zvonec samo za skrbnika (`MainLayout.razor`), okno izvozov za vse | **S**: osebna obvestila (moj uvoz/izvoz končan, moja sprememba zavrnjena v SAOP). |
| Iskanje | »vsebuje« po šifri/nazivu, globalno Ctrl+K | strežniško, a `/izdelki` in `/cene` iščeta samo po šifri/EAN (ne po nazivu); `PimText.Fold` uporablja le `/splet` (glej `docs/PREGLED_STRANI.md`) | **V**: iskanje po nazivu brez šumnikov povsod. **N**: globalno iskanje (izdelek, stranka, kategorija). |
| Arhitektura mreže | JSON + Elasticsearch | MSSQL procedure `intranet.GetProductList`, strežniško listanje (`PimPager`) | **S**: predizračunan bralni model za mrežo, full-text indeks — ko bodo filtri po atributih. |
| Integracija ERP | lastništvo po polju, odobritev, idempotenca, potrditev | lastništvo po polju, vrsta z odobritvijo, echo/verifikacija (`out.VerifyEcho`), `/saop/zgodovina`, nikoli samodejno | Na ravni najboljših praks. Ohrani. |

---

## 9. Pravila gradnje strani za naš PIM

Izpeljana iz zgornjih virov; dopolnjujejo `CLAUDE.md` §2–3 in ne nadomeščajo pravil tam.

1. **Stanje seznama je v URL-ju** (filtri, iskanje, razvrščanje, stran, izbrani stolpci). Povezava je
   vedno deljiva in gumb Nazaj deluje.
2. **Vsak večji seznam ima shranjene poglede**: ime, osebni ali skupni, privzeti pogled; oznaka
   »spremenjeno« (npr. `*`), ko se trenutno stanje razlikuje od shranjenega pogleda.
3. **Izbira ima tri načine**: »ta stran«, »vse, ki ustrezajo filtru (N)«, »nič«. Število izbranih je
   vedno vidno; izbira pri »vse po filtru« je filter, ne seznam ID-jev.
4. **Vrstica množičnih dejanj** se pokaže ob izbiri in uporablja skupni gradnik; nevarna dejanja so
   rdeča in ločena na desni.
5. **Množično dejanje nad več kot eno stranjo teče v ozadju**: napredek, preklic (z opozorilom, da se
   narejeno ne povrne), rezultat s povezavo, sled v zgodovini in pot nazaj.
6. **Potrditev pove število in obseg**: »Nastaviti ›Moč [W]‹ na 12 za 340 izdelkov v podjetju IQ
   Lighting?«.
7. **Popolnost se prikaže po cilju** (ERP, splet svetila, splet videlektro), ne kot eno skupno število,
   in se da filtrirati po vsakem cilju.
8. **Izračunane vrednosti** (popolnost, pripravljenost, število slik, stanje) se berejo iz shranjenega
   stanja, nikoli ne računajo na vrstico ob prikazu.
9. **Filtri po atributih** uporabljajo operatorje glede na vrsto (prazno/ni prazno, enako, vsebuje,
   med) in `PimPicker` za izbiro atributa; »Počisti filtre« in čipi aktivnih filtrov z »×«.
10. **Izbira prikazanih stolpcev** je del pogleda; naziv in šifra sta pripeta levo; številke desno.
11. **Brez pravice skrij, samo ogled prikaži sivo z razlogom** (»Samo za branje — vloga Komerciala«);
    pravico vedno preveri tudi servis (`PimWriteGuard`).
12. **Polje, ki ga ima v lasti drug sistem, ima čip lastnika** (»SAOP«) in pojasnilo, kam gre
    sprememba (»v vrsto za SAOP, čaka odobritev«); ročnega vnosa ERP podatka mimo vrste ni.
13. **Obrazec ima filter »samo manjkajoče«** in seznam manjkajočih polj s skokom na polje; polja so
    razporejena po skupinah atributov.
14. **Obrazec ima en »Shrani«**, oznako spremenjenih polj, opozorilo ob odhodu in po shranjevanju
    sporočilo s posledico (»Validacija ponovljena; izdelek je zdaj pripravljen za splet svetila«).
15. **Vsaka vrstica zgodovine ima »Povrni«**; povratek je nova sprememba z avtorjem, ne brisanje
    zgodovine.
16. **Iz seznama v obrazec se da iti zaporedno**: »Uredi izbrane zaporedno« s prejšnji/naslednji in
    števcem »3 od 40«.
17. **Lokalizirana polja imajo primerjavo jezikov**: referenčni jezik samo za branje ob strani, gumb
    »Kopiraj« in AI predlog; oznaka jezika ob polju.
18. **Vsak uvoz** ima predogled (prvih N vrstic po preslikavi), štetje (prebrano/zapisano/preskočeno/
    napake), poročilo napak z vrstico, stolpcem in razlogom v Excelu, in razveljavitev (`ops.ImportRun`).
19. **Vsak izvoz** izvozi točno to, kar je na zaslonu (filtri + izbrani stolpci) ali izbrane vrstice;
    gumb pove obseg (»Izvozi 340 izdelkov«).
20. **Dolgo opravilo pošlje osebno obvestilo** sprožitelju s povezavo na rezultat; uporabnik sme med
    tem zapustiti stran.
21. **Nadzorna plošča in »Moj dan«** kažeta samo dejanja, ki čakajo name (odobritve, varovalke,
    manjkajoče kategorije), z roki; vsak števec je povezava na filtriran seznam.
22. **Podjetje je vedno vidno** (`PimOrganizationScope`) in je del filtra, pogleda in izvoza; podatki
    dveh podjetij se ne pomešajo brez stolpca »Podjetje«.
23. **Novi atribut ali šifrant se definira z omejitvami** (vrsta, enota, dolžina, dovoljene vrednosti),
    ki jih uveljavita obrazec in uvoz enako.
24. **Omejitve so izrecne**: če filter vrne preveč za prikaz ali izvoz, stran to pove in predlaga ožji
    filter, ne zmrzne.
25. **Vsaka prikazana vrednost ima pot do izvora**: izdelek → zajem/uvoz, iz katerega je prišel;
    napaka → pravilo, ki jo je sprožilo; SAOP polje → zgodovina pošiljanja.
