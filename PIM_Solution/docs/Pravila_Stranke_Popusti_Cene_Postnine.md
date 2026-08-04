# Pravila: stranke, popusti, cene in poštnine (B2B)

> **Namen:** en sam vir resnice za vsa poslovna pravila okrog **strank, popustov, cenikov in poštnine** za B2B spletno trgovino.
> Ta dokument **definira pravila** (kaj velja). *Kako* jih spravimo v CSV in v Magento je predmet ločenega dokumenta (glej [§10 Naslednji korak](#10-naslednji-korak)).
>
> **Status:** delovni osnutek · **Verzija:** 0.3 · **Zadnja sprememba:** 2026-07-30
> **Vir:** `Pravila_za_stranke_in_popusti.docx` + sestanek 2026-07-22 + odgovori 2026-07-30 + analiza baze PIM_test.
>
> **Dnevnik:**
> - v0.3 (odgovori 30. 7.): odgovorjena vsa odprta vprašanja; nov §5d (4 kaskadni popusti + spletni 2 % + akcija↔S ekskluzivnost);
>   bruto VPC = brez rabatov brez DDV (§6); plačnik POSLOVNA ENOTA vs TRANZIT (§4b, skrivanje rabatov zaenkrat umaknjeno).
> - v0.2 (sestanek 22. 7.) dodano — plačnik in pravilo skrivanja rabatov, vrsta stranke (kupec/dobavitelj), override skupinskih popustov (po tipu/stranki), urejljiv vrednostni rabat (3 stolpci), S na artiklu + per-stranka S override.

---

## Kazalo

1. [Kontekst in obseg](#1-kontekst-in-obseg)
2. [Slovar pojmov](#2-slovar-pojmov)
3. [Tipi strank (customer group)](#3-tipi-strank-customer-group)
4. [Zastavice na stranki (kljukice)](#4-zastavice-na-stranki-kljukice)
   - 4b. [Plačnik in vrsta stranke (iz SAOP)](#4b-plačnik-in-vrsta-stranke-iz-saop)
5. [Popust na polno pakiranje (S1–S4)](#5-popust-na-polno-pakiranje-s1s4) *(+ S na artiklu, per-stranka S override)*
6. [Vrednostni rabat (glede na vrednost naročila)](#6-vrednostni-rabat-glede-na-vrednost-naročila) *(urejljiv, 3 stolpci)*
   - 6b. [Override skupinskih popustov (po stranki / po tipu)](#6b-override-skupinskih-popustov-po-stranki--po-tipu)
7. [Poštnina](#7-poštnina)
8. [B2B+ ugodnost](#8-b2b-ugodnost)
9. [Cenik stranke](#9-cenik-stranke)
10. [Kje živijo podatki (vir resnice)](#kje-živijo-podatki-vir-resnice)
11. [Odprta vprašanja](#odprta-vprašanja)
12. [Naslednji korak](#10-naslednji-korak)

---

## 1. Kontekst in obseg

Trenutno imamo postavljeno **B2C** trgovino. Gradimo **B2B** trgovino, ki potrebuje dodatne
podatke o **strankah**, njihovih **rabatnih skupinah** in **popustih** (na količino, vrednost
naročila, poštnino ipd.).

**Delitev odgovornosti (pomembno):**

| Kdo | Kaj naredi |
|-----|-----------|
| **PIM (mi)** | definira pravila v šifrantih, poveže artikle/stranke s pravili, podatke izvozi v CSV |
| **Magento** | pravila ovrednoti **ob nakupu** (tier cene, cart rules, poštnina) |

> **Načelo:** pravila živijo v **šifrantih PIM** (en vir resnice), ne v izvozni proceduri in ne
> na več mestih v Magentu. Ko se pravilo spremeni, se spremeni na **enem mestu**.

Za urejanje teh pravil je predvidena **nova navigacijska stran »Pravila«** v intranetu
(pravila dobaviteljev in dokumentov · pravila validacije · pravila popustov). Uporabnik jih
lahko spreminja, sistem spremembe upošteva pri naslednjem izvozu.

**Treba je imeti nivoje urejanja.**

---

## 2. Slovar pojmov

| Pojem | Pomen |
|-------|-------|
| **PAK2** | Polno (transportno) pakiranje. V bazi polje `ItemQuantityOfPackaging2` — koliko kosov je v enem polnem pakiranju. |
| **S1–S4** | Šifre popusta na polno pakiranje: S1 = 3 %, S2 = 5 %, S3 = 10 %, S4 = 15 %. |
| **Customer group (skupina stranke)** | Magento skupina, v katero spada stranka. **Ključna vez** med stranko in pravili/cenami. Izhaja iz »tipa stranke«. |
| **Tier price (stopenjska cena)** | Magento cena na artiklu, ki velja »od določene količine navzgor« in za določeno skupino strank. Tu jo uporabimo za PAK2 popust. |
| **Cart price rule** | Magento pravilo na ravni **celotne košarice** (npr. vrednostni rabat, brezplačna poštnina). Ni na artiklu. |
| **Vrednostni rabat** | Popust glede na skupno vrednost naročila (ne na artikel). |
| **Cenik (price list)** | Cenovni seznam, dodeljen stranki; stranka vidi svoje cene. |

---

## 3. Tipi strank (customer group)

Vsaka stranka ima **tip**, ki v Magentu postane **customer group**. Tip je izhodišče za skoraj
vsa pravila (cene, rabati, poštnina).

> ⚠️ **Tip stranke NI v SAOP.** Polje `raw.Customers.CustomerType` **ne** predstavlja teh tipov
> (INŠTALATER, MIZAR, …) — pomeni nekaj drugega. Zato je tip stranke **nov podatek**, ki ga:
> 1. definiramo v **novem šifrantu** v PIM (`pim.CustomerTypeCatalog` — seznam 18 tipov spodaj), in
> 2. dodelimo stranki prek **novega stolpca** na profilu stranke (`pim.CustomerWebProfile.CustomerTypeCode`).
>
> Potrebno je še **mapiranje tip → Magento skupina**.

**Seznam tipov (18):**

| # | Tip stranke | # | Tip stranke |
|---|-------------|---|-------------|
| 1 | INŠTALATER | 10 | TRGOVEC – PE – NEAKTIVEN |
| 2 | MAX INŠTALATER | 11 | KONČNI KUPEC – B2B – PE |
| 3 | MIZAR | 12 | INŠTALATER – PE |
| 4 | TRGOVEC – TRANZIT | 13 | INŠTALATER – TRANZIT |
| 5 | KONČNI KUPEC – B2B | 14 | TRGOVEC – TRANZIT – NEAKTIVEN |
| 6 | TRGOVEC | 15 | TRGOVEC – neaktiven |
| 7 | INŠTALATER MAX | 16 | PROJEKTANT |
| 8 | TRGOVEC – PE | 17 | NEAKTIVEN |
| 9 | NADALJNJA PRODAJA | 18 | JAVNI SEKTOR |

> **Opomba:** »NEAKTIVEN« tipi verjetno ne smejo v spletno prodajo — glej [Odprta vprašanja](#odprta-vprašanja).

---

## 4. Zastavice na stranki (kljukice)

Poleg tipa ima vsaka stranka nekaj **zastavic (DA/NE)**, ki povedo, katera pravila zanjo veljajo.
Če stranka zastavice nima, se ji pripadajoče pravilo **ne** upošteva v B2B trgovini.

| Polje | Pomen | Posledica |
|-------|-------|-----------|
| **Tip stranke** (dropdown) | Kateri od 18 tipov (§3) — določa Magento skupino | Izhodišče za cene/rabate/poštnino |
| **Popust na polno pakiranje** (DA/NE) | Ali stranka dobi S-popust na PAK2 | Če DA → vidi tier ceno za polno pakiranje (§5) |
| **Vrednostni rabat** (DA/NE) | Ali za stranko velja rabat po vrednosti naročila | Če DA → velja cart rule vrednostnega rabata (§6) |
| **B2B+ ugodnost** (DA/NE) | Ali ima stranka B2B+ | Če DA → vedno brezplačna poštnina (§8) |

Vsa ta polja + cenik se **izvozijo v CSV strank** (glej §10). Vsa (razen cenika) živijo v
**novem PIM stolpcu/tabeli** profila stranke — **ne** v SAOP.

---

## 4b. Plačnik in vrsta stranke (iz SAOP)

Dve dodatni polji stranke, ki **prihajata iz SAOP** (ne izmišljamo ju).

### Plačnik (CustomerPayer)

- Na izkaznici stranke se prikaže **koda plačnika (`raw.Customers.CustomerPayerCode`) + ime plačnika**.
- **Pravilo izvoza (dopolnjeno, glej O11):** obnašanje je odvisno od **vrste plačnika**:
  - **POSLOVNA ENOTA** (ima plačnika v SAOP) → popuste **VIDI** (rabatov NE skrivamo).
  - **TRANZIT / zunanja stranka** → popustov **NE** sme videti (skrij).
  - 3. opcija: plačnik izda svoje popuste; splet jih prikaže, ob prenosu naročila v iCenter se **zamenjajo na plačnika**.
- Za to **rabimo dodaten podatek na plačniku/stranki: POSLOVNA ENOTA ali TRANZIT.**

> **Zaenkrat NE implementiramo** skrivanja rabatov po plačniku (le predvidimo) — ker ENOTA/TRANZIT podatka še ni.
> Izvoz strank torej **osnovnih rabatov po plačniku NE skriva** (prej predlagano skrivanje = umaknjeno do razjasnitve).

### Vrsta stranke (kupec / dobavitelj / oboje)

- Novo polje **»Vrsta stranke«** z vrednostmi *kupec*, *dobavitelj*, *kupec in dobavitelj*.
- Uporablja se kot **filter** v registru strank (**dropdown**); vrednosti prihajajo iz SAOP in jih
  uredniki vzdržujejo sami.
- ⚠️ **Ne mešati z »Tip stranke«** (INŠTALATER, MIZAR… iz §3). »Tip« je poslovni tip za B2B skupino;
  »vrsta« pove le, ali je partner kupec ali dobavitelj.

> **Vir:** `raw.Customers` že vsebuje kupca in dobavitelja pod isto šifro (obstajajo `Supplier*` stolpci).
> Katero polje natančno določa »vrsto«, je [odprto vprašanje](#odprta-vprašanja).

---

## 5. Popust na polno pakiranje (S1–S4)

### Pravilo

Artiklu se lahko dodeli **popust na polno pakiranje**, izražen s šifro:

| Šifra | Popust |
|-------|--------|
| **S1** | 3 % |
| **S2** | 5 % |
| **S3** | 10 % |
| **S4** | 15 % |

Popust se **upošteva na vrednost polnega pakiranja (PAK2)** in **samo za stranke**, ki imajo
kljukico *»Popust na polno pakiranje«* (§4).

### Kako deluje (mehanika)

1. Artikel ima **PAK2** = količino v polnem pakiranju (npr. PAK2 = 5).
2. Artiklu določimo **S-šifro** (npr. S2 = 5 %).
3. Popust velja, ko stranka kupi **PAK2 ali več** kosov (npr. 5 ali več).
4. Popust velja **samo**, če ima stranka omogočeno zastavico za PAK2 popust.

**Primer:** artikel s ceno 100 €, S2 (5 %), PAK2 = 5.
Stranka s kljukico kupi 5 kosov → cena na kos 95 € (100 € − 5 %).
Stranka **brez** kljukice kupi 5 kosov → cena ostane 100 €/kos.

### Magento preslikava

To je **tier price** na artiklu, vezan na skupino strank:
> qty ≥ PAK2 · skupina = upravičene stranke · cena = redna cena × (1 − S %)

### Kaj potrebujemo

- ✅ **Nova tabela popustov** S1–S4 v PIM (šifrant %) — `pim.PackagingDiscountCatalog`.
- ✅ Na **osebni izkaznici artikla** polje *»Popust na polno pakiranje«* kot **dropdown** (polni se iz te tabele); izbira se hrani v `pim.ProductPackagingDiscount`.
- ⏳ Vrednost **PAK2** prenesti do izvoza (je v STG, potrjeno **ni** v `pim.ProductCommercial`).
- ⏳ Oba podatka (S-šifra, PAK2) vključiti v **izvoz artiklov** (naslednji sklop).

### 5b. S na artiklu — prikaz in urejanje

- **S-šifra (S1/S2) je prikazana na artiklu** (osebna izkaznica) in **urejljiva** tam.
- Če ima stranka kljukico **PAK2** (§4), se pri nakupu **≥ PAK2** upošteva **privzeti S artikla** (npr. S1).

### 5c. Per-stranka S override (drugačen S za določeno stranko)

Za posamezno stranko lahko na določenih artiklih uveljavimo **drugačen S** (druge %), viden **samo tej stranki**.
Osnovni S artikla ostane nespremenjen za vse ostale.

- **Nova tabela »spremembe S popustov«**: (**artikel** × **stranka(e)** × **nov S / %**). Ena sprememba
  lahko velja za **več strank**.
- Pri **izvozu artiklov** se doda **dodaten stolpec s ciljnimi strankami** + **stolpec z novim S** —
  velja samo za navedene stranke; ostali vidijo privzeti S.
- Primerjava »stari S → novi S« se **ne izvaža** (preveč podatkov); hranimo jo lahko le v aplikaciji za pregled.

> **Magento pomen:** to je še ena raven tier price / cena po skupini, a ciljana na **specifične stranke**
> (praviloma prek namenske skupine ali kupec-specifične cene). Podrobnosti so predmet načrta izvoza.

### 5d. Kombiniranje popustov — KASKADNO (verižno) · 4 popusti

Popusti se **ne seštevajo**, ampak veljajo **kaskadno (verižno)**: vsak naslednji se obračuna od **nove osnove**
(cene po prejšnjem popustu). Vrstni red:

1. **Osnovni (skupinski) rabat** — rabat skupine stranke × skupine artikla (SAOP ComercialTerms).
2. **S-popust (PAK2)** — na polno pakiranje (§5).
3. **Vrednostni rabat** — po vrednosti naročila (§6).
4. **Spletni rabat 2 %** — vsi B2B kupci imajo za **spletno naročanje 2 %** (samodejno omogočeno B2B strankam v PNV).

> **Izjema (ekskluzivnost):** artikel z **akcijskim popustom** (npr. 20 %) **NE** dobi še **S-popusta**.
> Akcijski in S sta izključujoča. Primer: sijalka `ba.ba13.00921`.

**Posledice za izvoz/Magento:**
- Spletni 2 % je **globalno pravilo** za B2B skupino (cart rule), **ne** stolpec na stranki/artiklu.
- Kaskado sestavi Magento (4 pravila po vrsti); PIM izvozi le sestavne dele.
- **Akcija ↔ S** rabi izkey: kjer je artikel v akciji, se S ne sme uporabiti (rabimo vir akcijskih popustov — [odprto](#odprta-vprašanja)).

---

## 6. Vrednostni rabat (glede na vrednost naročila)

### Pravilo

Popust glede na **skupno vrednost naročila** (bruto brez DDV):

| Vrednost naročila | Rabat |
|-------------------|-------|
| 800 € – 1.500 € | 1 % |
| 1.500 € – 3.000 € | 2 % |
| nad 3.000 € | 3 % |

Rabat velja **samo za stranke**, ki imajo kljukico *»Vrednostni rabat«* (§4).

### Kako deluje

- Ni vezan na artikel — vezan je na **celotno košarico**.
- V Magentu je to **cart price rule**: pas vrednosti + ciljna skupina strank → % popust.
- Naša naloga: **definirati pasove** v tabeli + na strankah označiti, da rabat velja.
  Za 1.000 strank to pomeni **eno pravilo** + članstvo v skupini — **ne** 1.000 stolpcev/vrstic na artiklih.

### Kaj potrebujemo

- **Nova tabela** privzetih vrednostnih pasov (prag–%), **urejljiva** v intranetu (šifrant).
- Vrednostni rabat je **posebno, urejljivo polje na stranki** — pasovi se lahko za posamezno stranko
  prilagodijo (mapping stranka → 3 vrednosti).
- V **izvoz strank** gre kot **trije stolpci** (trije pragovi → trije %), npr.:

  | `rabat_prag_1` | `rabat_prag_2` | `rabat_prag_3` |
  |---|---|---|
  | nad 800 € = 1 % | nad 1.500 € = 2 % | nad 3.000 € = 3 % |

  Magento prebere te tri vrednosti in sestavi cart rule. Privzetki pridejo iz šifranta, po potrebi
  jih urednik na stranki prepiše.

---

## 6b. Override skupinskih popustov (po stranki / po tipu)

Popusti skupin (SAOP `ComercialTerms`, desni stolpec izkaznice) so privzeto **samo za branje**.
Poslovno pa je treba **spreminjati popust na skupino artiklov**, in to na **dva nivoja**:

| Nivo override | Primer |
|---|---|
| **Po tipu stranke** | vsi *Inštalaterji* → skupina artiklov **BA = 50 %** |
| **Po posamezni stranki** | *Topdom* → skupina artiklov **BA = 50 %** |

### Kaj potrebujemo

- **Nova tabela »override skupinskih popustov«**: (nivo = *tip* \| *stranka*, ciljna **skupina artiklov**,
  **popust %**, velja od / do).
- **Prioriteta pri izvozu:** *stranka* > *tip stranke* > *privzeti SAOP popust*.
- V intranetu se ureja (dodaj / uredi override); v izvoz gre **efektivni** popust (po prioriteti).

---

## 7. Poštnina

### 7.1 Osnovno pravilo (vrednost naročila)

| Vrednost naročila (bruto brez DDV) | Poštnina |
|------------------------------------|----------|
| manj kot 150 € | **4,10 € + DDV** |
| 150 € ali več | **brezplačno** |

### 7.2 Pravilo za velike pakete (dimenzija)

| Pogoj | Poštnina |
|-------|----------|
| paket **daljši od 2 m** **IN** vrednost naročila **manj kot 300 €** (bruto) | **10 € + DDV** |

> Za to pravilo potrebujemo **dimenzije paketa** artikla (dolžina). Te podatke izvoz že vsebuje
> (`PackageLength` in enota), zato dodaten vir ni potreben — potrebno je le pravilo v Magentu.

### 7.3 Izjema

Če ima stranka **B2B+** (§8), je poštnina **vedno brezplačna**, ne glede na vrednost ali dimenzijo.

### Magento preslikava

Poštninska pravila (cart price / shipping rules), definirana **enkrat**. Naša naloga je le
**definirati pragove** v šifrantu in po potrebi izvoziti relevantne podatke (dimenzije so že v produktnem izvozu).

---

## 8. B2B+ ugodnost

### Pravilo

Stranka z **B2B+** ima **brezplačno poštnino ne glede na vrednost ali dimenzijo naročila**.

### Kako deluje

- Na stranki polje **DA / NE** (zastavica, §4).
- V Magentu: stranke z B2B+ so v skupini / imajo atribut, ki sproži brezplačno poštnino.
- Doda se še datum veljavnosti. 
- Povežemo z mailingom.

### Kaj potrebujemo

- Na stranki zastavica **B2B+**.
- V **izvoz strank** vključiti to zastavico.

---

## 9. Cenik stranke

### Pravilo

Stranka ima lahko **svoj cenik** (ponavadi poimenovan po imenu stranke). Če ga ima, na spletni
strani vidi **svoje artikle po svojih cenah**.

### Vir

Cenik že prihaja iz SAOP: `raw.Customers.PriceList` (in `DiscountPriceList`). Ne ustvarjamo ga na novo.

### Magento preslikava

Cenik stranke se v Magentu izrazi prek **cen po skupinah / deljenih katalogov (shared catalog)**
ali prek dodeljenega cenika stranki. Naša naloga: cenik iz SAOP **izvoziti v CSV strank**.

---

## Kje živijo podatki (vir resnice)

Pregled, od kod prihaja vsak podatek — da ne podvajamo virov.

| Podatek | Vir | Status |
|---------|-----|--------|
| **PAK2** (`ItemQuantityOfPackaging2`) | `raw.[ORG]_data_current` → STG (`Create_STG_ProductCommercial_LoadFromRaw`) | ✅ v raw + STG; ⚠️ potrjeno **NI** v `pim.ProductCommercial` (tam je le `PackageQuantity2`=VPAK) — rabi pot v pim + izvoz |
| **S-šifra popusta** (na artiklu) | `pim.ProductPackagingDiscount` (per org+item; PIM-side, preživi promote) | ✅ zgrajeno · ⚠️ rabi deploy `Create_PIM_PackagingDiscount.sql` |
| **S1–S4 odstotki** | `pim.PackagingDiscountCatalog` (šifrant, urejljiv %) | ✅ zgrajeno · ⚠️ rabi deploy |
| **Tip stranke** (INŠTALATER, MIZAR, …) | **nov** šifrant `pim.CustomerTypeCatalog` + **nov** stolpec na profilu stranke | 🆕 dodati · ⚠️ `raw.Customers.CustomerType` NI to |
| **Cenik stranke** | `raw.Customers.PriceList` / `DiscountPriceList` | ✅ obstaja |
| **Rabatne skupine** | `raw.Customers.DiscountGroupID`, `FirstGroupCode`, `SecondGroupCode` | ✅ obstaja (preveriti pomen) |
| **Kljukice** (PAK2 / vrednostni rabat / B2B+) + tip | **nova** PIM tabela profila stranke `pim.CustomerWebProfile` (spletne zastavice) | 🆕 dodati |
| **Vrednostni pasovi** rabata (privzetki + per-stranka 3 vrednosti) | **nova** tabela šifranta + mapping na stranko | 🆕 dodati |
| **Pragovi poštnine** | **nova** tabela šifranta (PIM) | 🆕 dodati |
| **Dimenzije paketa** | `pim.ProductCommercial` (že v izvozu) | ✅ obstaja |
| **Plačnik** (`CustomerPayerCode` + ime) | `raw.Customers` (SAOP) | ✅ obstaja · če izpolnjen → skrij osnovne rabate iz CSV |
| **Vrsta stranke** (kupec / dobavitelj / oboje) | `raw.Customers` (SAOP) | ✅ obstaja · filter (polje potrditi) |
| **Override skupinskih popustov** (po tipu / stranki) | **nova** tabela `pim.CustomerGroupDiscountOverride` | 🆕 dodati |
| **Per-stranka S override** (artikel × stranka → nov S) | `pim.ProductCustomerSOverride` | ✅ tabela zgrajena (deploy) · UI kasneje |
| **S-šifra na artiklu** (urejljiva) | `pim.ProductCommercial` (novo polje) + šifrant S1–S4 | 🆕 dodati |

> **Zakaj so kljukice PIM-side, ne SAOP:** so **spletne** (B2B) odločitve, ki v ERP (SAOP) ne
> obstajajo. Zato jih hranimo v PIM in ne pošiljamo nazaj v SAOP.

---

## Odprta vprašanja

| # | Vprašanje | Predlog | Odgovor
|---|-----------|---------|---------|
| 1 | »800–1500 **bruto** eurov **brez DDV**« — bruto in brez DDV si nasprotujeta. Kaj je mišljeno? | Predvidevamo **neto (brez DDV)** vrednost naročila; potrditi. | **Bruto VPC** = vrednost **brez upoštevanih rabatov in brez DDV**. Prag vrednostnega rabata se meri na to osnovo. |
| 2 | Meje pasov (1.500, 3.000, 150, 300) — so **vključujoče** na spodnji ali zgornji meji? | Predlog: spodnja meja vključujoča (`≥`), zgornja izključujoča (`<`). | Tako je pravilno spodnja meja mora imeti se je enako.
| 3 | »NEAKTIVEN« tipi strank — smejo v spletno prodajo? | Verjetno **izključiti** iz B2B; potrditi. | Potrjujem odgovor. 
| 4 | PAK2 popust — se meri po **kosih** artikla ali po **številu polnih pakiranj**? | Iz besedila: po kosih (»PAK2 = 5 → za 5 ali več«); potrditi. | Ja za 5 ali več. 
| 5 | Se S-popust in vrednostni rabat **seštevata** na istem naročilu? | Potrditi vrstni red / kombiniranje popustov. | S popust se ne sešteva, ampak gre za verižni popust. Serpavi najprej en popust potem od novve osnove drug popust itd.
| 6 | Ali obstaja zgornja meja PAK2 popusta (npr. samo večkratniki PAK2)? | Potrditi. | Ni zgronje meje. Geldamo PAK2 vrednost in, če je količina večja ali enaka kot ta številka potem damo popust. 
| 7 | Mapiranje 18 tipov strank → konkretne Magento skupine | Pripraviti tabelo mapiranja. | Mapiranje **pripravi poslovni**. |
| 8 | Kaj dejansko pomeni `raw.Customers.CustomerType` (če ni tip stranke)? | Preveriti; morda uporabno za kaj drugega. | Morda = **vrsta stranke** (kupec/dobavitelj/oboje) — **nepotrjeno**; glej O10. |
| 9 | Kje se tip stranke dodeli (ročno v intranetu, uvoz iz Excela, drug SAOP podatek)? | Predlog: ročni dropdown na strani stranke + možnost paketnega uvoza. | **Ročno** ob novi stranki / **ob prijavi v B2B** (obrazec iql.eu/kontakt). Vir za začetni uvoz = obstoječa **B2B tabela popustov** (kasneje jo nadomesti PIM). |
| 10 | »Vrsta stranke« — katero polje v `raw.Customers` jo določa (ali izpeljemo iz obstoja `Supplier*` podatkov)? | Preveriti SAOP; sicer izpeljati kupec/dobavitelj/oboje. | V SAOP **ni urejeno** → ročno; verjetno **izpeljemo iz izpisa računov** (prejeti/poslani), kdo je kupec/dobavitelj. |
| 11 | Ko je **plačnik** izpolnjen — se skrijejo **vsi** rabati ali le osnovni skupinski (S / vrednostni ostanejo)? | Predlog: skrij osnovne skupinske rabate; potrditi obseg. | **Odvisno od vrste plačnika:** **POSLOVNA ENOTA** (ima plačnika v SAOP) → popuste **VIDI**; **TRANZIT / zunanja stranka** → popustov **NE** sme videti. 3. opcija: plačnik izda popuste, splet jih prikaže, ob prenosu naročila v iCenter se **zamenjajo na plačnika**. → Rabimo podatek na plačniku: **POSLOVNA ENOTA ali TRANZIT**. **Ne implementiramo zdaj** (le predvidimo). |
| 12 | Per-stranka S override — kako v Magentu ločimo ceno za eno stranko (namenska skupina na stranko ali kupec-specifična cena)? | Odločiti v načrtu izvoza. | *(še odprto)* |
| 13 | Override skupinskih popustov — se **veriži** s S-popustom in vrednostnim rabatom, ali je ekskluziven? | Potrditi pravilo kombiniranja. | *(nejasno — pustimo odprto; verjetno se veriži kot ostali, glej §5d)* |

---

## 10. Naslednji korak

Ko so pravila potrjena, sledi **kako jih spravimo v CSV in Magento**:

- **Ločeni izvozi** (ne en CSV): **PRODUCTS** (artikli + PAK2 + S-popust kot tier price) in
  **CUSTOMERS** (stranke + skupina + kljukice + cenik). Artikel in stranka se srečata v Magentu
  **prek skupine (customer group)**, ne v isti vrstici.
- **Šifranti pravil** (S1–S4, vrednostni pasovi, poštnina) → v Magento kot **pravila**, definirana enkrat.

Podrobnosti CSV strukture, SQL objektov in intranet strani so v ločenem načrtu izvoza.

---

*Konec dokumenta.*
