# Primerjava intraneta: PIM (NoviPIM) proti PIM_test

Merjeno 2026-09-02 nad `C:\Users\David\Desktop\NoviPIM\PIM_Solution\src\PIM.Intranet`
in `C:\Users\David\Desktop\PIM_test\src`. Vse številke so preštete iz kode, ne ocenjene.

---

## 1. Kaj sta

| | **PIM** (NoviPIM) | **PIM_test** |
|---|---|---|
| Vrstic `.cs` + `.razor` | **16.474** | **48.905** (3×) |
| Strani z `@page` | 62 | 71 |
| Datotek `.cs` | 41 | 92 |
| Največja datoteka | `PipelineReadService.cs` 849 | `PimQueryService.cs` **5.064** + 40 partialov |
| Dostop do baze | UI kliče **samo procedure `intranet.*`** (58 procedur) | inline SQL v C#, dinamični `UNION ALL` po organizacijah |
| Sheme baze | `raw → stg → canon → val → out`, ob strani `map`, `pim`, `b2b`, `stock`, `sec`, `ops`, `intranet` | `raw`, `stg`, `pim`, `dbo`, `etl`, `export`, `media`, `comm`, `ctrl`, `ops`, `security` |
| Migracije | **136 oštevilčenih**, zaporedne, z vgrajenimi `THROW` preverbami | **190 datotek** brez zaporedja (`Create_*`, `Alter_*`, `Fix_*`, `Cleanup_*`) |
| Ozadje | **11 ločenih workerjev** (procesov) | 3 Windows storitve + `JobRunnerHostedService` **znotraj spletne aplikacije** |
| Testi | **60 testnih projektov** | 0 (za intranet) |

Kratko: **PIM je tretjina kode za skoraj enako število strani.** Razlika ni v tem, da bi PIM
delal manj — razlika je v tem, da je PIM_test isto stvar napisal večkrat na več mestih.

---

## 2. Kaj ima PIM_test, česar PIM NIMA

### A. Zapis v ERP (SAOP) — artikli

| # | Funkcija | PIM_test | PIM |
|---|---|---|---|
| A1 | **Nov artikel v SAOP** (POST `AddItemsGeneralData`) | `/export/saop-item-new` — obrazec z vsemi polji, iz obstoječega artikla po šifri, ročni XML, predogled, `SuggestFirstFreeCode`, preverba obveznih polj | **ni strani** (zaledje to zna, glej spodaj) |
| A2 | **Sprememba enega artikla** (PATCH) v obrazcu | `/export/saop-item-edit` — vsa polja + uvoz iz Excela z isto predlogo | delno: kartica ureja samo 23 registriranih polj |
| A3 | **Množične spremembe s polnjenjem iz dobaviteljevega XML** | `/export/saop-item-bulk` | ni |
| A4 | **Izločanje iz rezervacije** (`ItemsPlanningData`) | `/export/planning-exclude` | ni (na kartici je »Planiranje in rezervacija« označeno kot manjkajoče) |
| A5 | **Ponovno pošiljanje neuspelih** | `/export/saop-item-queue`, `/export/saop-outbound` — gumb »pošlji znova« | `/saop`, `/saop/zgodovina` — samo pregled, brez ponovnega pošiljanja |
| A6 | **Nabor pisljivih polj SAOP** | **89** (`SaopItemFieldCatalog.cs`) | **24** (`out.SaopXmlField`, migracija 081) |

> **Ključno:** PIM ima v zaledju `SaopIntentResolver` (samodejno odloči ADD proti PATCH),
> `SaopDocumentBuilder`, `out.SaopDocument` z oblikami za artikle/stranke/cenike/cene ter
> `PIM.OutboxDispatcher`. **Manjka samo vmesnik in razširjen register polj.**

### B. Zapis v ERP — stranke

| # | Funkcija | PIM_test | PIM |
|---|---|---|---|
| B1 | **Nova stranka** (POST `AddCustomer`) | `/customers/new` | ni |
| B2 | **Sprememba stranke** (PATCH `UpdateCustomer`) s kartice | 15 polj (`SaopCustomerXmlBuilder.EditableFieldDefs`): naziv, naslov, pošta, kraj, država, Usage, tip, davčna, matična, splet, valuta, cenik, plačilni rok, skupina popusta, jezik | kartica je za splošne podatke **samo bralna** |
| B3 | **Uvoz strank iz Excela** z zapisom v `raw` + vrsto za SAOP | `ImportCustomerWebProfileXlsxAsync` (608 vrstic), pošlje samo dejansko spremenjene vrstice in samo ob izrecnem dovoljenju | ni |

### C. Izvozi

| # | Funkcija | PIM_test | PIM |
|---|---|---|---|
| C1 | **CSV kataloga za splet na zahtevo** | `/export/web-catalog` — filtri, ostranjen predogled, prenos celotnega CSV (`dbo.usp_pim_ExportWebCatalog`, pretočno, UTF-8 z BOM, ločilo `;`) | delno: PIM ima `/izvoz/izdelki.csv` (CSV **seznama izdelkov**: statusi, števci) in `/izvoz/izdelki.xlsx` (2 predlogi), za splet pa `/splet` samo **prebere datoteke z diska**, ki jih je naredil `PIM.B2bWorker`. **Manjka CSV tistega, kar gre res na splet, po izvoznem profilu in s filtri.** `/izvoz/izdelki.csv` poleg tega zloži vse v pomnilnik s 100 zaporednimi klici po 200 vrstic — isti vzorec, ki ga je pri XLSX že zamenjal en klic |
| C2 | **Magento CSV strank na zahtevo** (26 stolpcev: kontakti, popusti, plačnik, B2B+, pragovi) | `BuildCustomerMagentoCsvAsync` | samo prek workerja, brez gumba v intranetu |
| C3 | **Izvoz + uvoz strank v XLSX** | gumba na `/customers` | ni |
| C4 | **Uvoz izdelkov iz Excela nazaj v PIM** | `/import/excel`, isti katalog stolpcev kot izvoz | izvoz v XLSX ima (2 predlogi, do 20.000 vrstic), **uvoza nazaj v PIM nima** — uvoz obstaja samo za polja SAOP v `/izvozi/mnozicno` |
| C5 | Predogled za Magento | `/export/magento-preview` | `/izvozi/profili/{id}` ima predogled iz registra stolpcev — **primerljivo** |

### D. Delo z novimi artikli

| # | Funkcija | PIM_test | PIM |
|---|---|---|---|
| D1 | **Novi artikli iz XML → v SAOP** | `/artikli/xml-novi` — kar je v dobaviteljevem XML in ni v ERP; označi in pošlji za eno ali več organizacij | ni |
| D2 | **Potrditev za ERP z zaporo** | `/stg/erp-ready` — pošlje se samo, kar ima ERP in komercialo 100 % | ni ločene strani (podatek je v `/kakovost`) |

### E. Ostalo

| Področje | PIM_test | PIM |
|---|---|---|
| **Mediji** | 7 strani: pregled, knjižnica, sredstvo, manjkajoči, karantena, uvozi, nastavitve | **1 stran** |
| **Cene** | 4 strani: cene izdelkov, ceniki, detajl cenika, posebne cene | **1 stran** |
| **Zaloga** | 3 strani: pregled, dobavni roki, težave | 1 stran + `/preverbe` |
| **Karantena** | `/quality/quarantine/edit` — popravi in revalidiraj | `/karantena` bralna |
| **Kategorije** | uvoz drevesa s predogledom, premik kategorije | bralne |
| **Povezave med izdelki** | urejanje (variante, podobni, povezani) | bralno |
| **Partnerji** | 2 strani + `/reference/customers` (poveži stranko s proizvajalcem/dobaviteljem) | 1 stran |
| **Več spletnih mest** | `WebSiteSelector`, pravila sestave nazivov `/pim/multiwebsite/title-rules` | kanali obstajajo, pravil za sestavo nazivov ni |
| **Obvestila uporabniku** | `/notifications` + zvonec v glavi | ni (samo `/izvozi/obvestila` za SAOP dogodke) |
| **Revizijski dnevnik v UI** | `/system/audit` | zapisuje se v `b2b.AuditLog`, a **ni strani** |
| **Tehnični zemljevid** | `/system/tech-map` — katera stran bere/piše katero tabelo | ni |
| **Pomoč** | `/pomoc` | ni |

---

## 3. Kaj ima PIM, česar PIM_test NIMA

Tega je manj po številu, a je težje nadomestiti.

1. **Cel modul zajema (vhodi)** — 9 strani: viri, teki, podrobnosti teka, čakalna vrsta,
   težave, podrobnosti težave, neujemanja, atributi iz virov, podrobnosti vira.
   PIM_test ima samo `/ingestion/xml-monitor` in `/imports`.
2. **Kanonični model `canon.*` + lastništvo polja** (`out.OwnershipPolicy`, 50 pisljivih polj
   iz preglednice `Mapiranje_SAOP_API_PIM.xlsx`) + **izvor vrednosti** — na kartici artikla pri
   vsakem polju piše, kdo je njegov lastnik. PIM_test tega nima; polje je pisljivo, ker je nekdo
   tako napisal v kodo.
3. **Odhodna pot z odobritvijo** — `out.OutboundBatch` + `out.ApproveOutboundBatch` /
   `CancelOutboundBatch`: **nič ne odide, dokler človek ne potrdi skupine.**
   PIM_test pošlje takoj v vrsto in worker to odnese.
4. **Samodejna odločitev ADD proti PATCH** (`SaopIntentResolver`) — v starem sistemu je bilo
   **118 od 130 napak** natanko ta ena odločitev (ADD namesto PATCH in obratno).
5. **Prekrivka »čaka potrditev«** (`intranet.GetPendingOverlay`) in **odkloni** (`/saop/odkloni`):
   primerja poslano vrednost s tisto, ki jo je vrnil naslednji zajem.
6. **Validacijski profili z nivojem in resnostjo** — ERP blokira, komerciala samo opozarja,
   splet blokira; isto branje na kartici, v seznamu napak in v karanteni.
7. **11 ločenih workerjev** namesto opravil v spletni aplikaciji (spletna aplikacija se lahko
   kadarkoli reciklira; ura, ki teče v njej, se s tem ustavi).
8. **60 testnih projektov.**
9. **Oštevilčene migracije z vgrajenimi preverbami** — migracija sama vrže napako, če se stanje
   po njej ne ujema s pričakovanim.
10. **Navigacija po življenjskem ciklu podatka** — VHODI → PIM → KAKOVOST → IZHODI →
    POSLOVANJE → UPRAVLJANJE → ADMIN; vsaka stran je v meniju **natanko enkrat**, podstrani so
    dosegljive samo z razdelilne (hub) strani.
11. **`PimMissing`** — stran naravnost pove »tega podatka še ni in tole rabimo«, namesto da bi
    pokazala prazno tabelo.
12. **Urniki obdelav iz intraneta** (`/sistem/urniki`) in **alarmi** (AlertDispatcher, watchdog,
    pravilo »pet zaporednih napak in povej«).
13. **Izvoz v XLSX z dvema predlogama** (pregled / SAOP), do 20.000 vrstic v enem klicu (1,0 s).

---

## 4. Kartica artikla proti dejanskemu SAOP-u

Primerjano z zaslonskimi slikami v `pictures\SAOP_izgled\`. Legenda:
✅ je na kartici in se da pisati nazaj · 🟡 je vidno, a se **ne** da pisati nazaj (ni v
`out.SaopXmlField`) · ❌ ni nikjer.

### Zavihek »Splošni podatki«

| SAOP polje | Element | PIM |
|---|---|---|
| Šifra | `ItemID` | ✅ |
| Naziv | `ItemTitle1` | ✅ (`TITLE_ERP` po jezikih) |
| Naziv 2. del | `ItemTitle2` | ✅ |
| Uporaba | `IsActive` | ✅ |
| **Kratek naziv** | `ItemTitleShort` | ❌ |
| **Tip artikla** | `ItemType` | 🟡 samo privzetek v `out.SaopAddDefault`, na kartici ga ni |
| Merska enota | `ItemUnitOfMeas` | ✅ |
| **Stopnja DDV** | `VATRateID` | 🟡 na kartici je »Davčna stopnja«, a `inReadModel: false` — vrednosti ni |
| **Vračilo DDV** | `VATRefund` | ❌ |
| **Trošarina + pretvornik** | `ExciseTaxID`, `ExciseConverter` | ❌ |
| Skupina artikla | `ItemGroup` | ✅ |
| Objava v spletni trgovini | `WebPublish` | ✅ |
| **Datum vpisa v spletno trgovino** | `ItemFirstPublished` | ❌ |
| **Oznaka DDV** | `VATInvoiceType` | ❌ |
| **Klasifikacija** | `ItemClassification` | ❌ |
| Tarifna oznaka | `CustomsTariffNo` | ✅ (pod Komercialo) |
| **Razred (OEEO)** | `ClassOEEO` | ❌ |
| Črtna šifra | `ItemEANCode` | ✅ |
| Oddelek | `ItemDepartment` | ✅ (»ABC klasifikacija«) |
| Knjižna skupina | `AccountingBookGroupID` | ✅ |
| **Dodatna ME + količina** | `ExtraUOM`, `ItemQuantityExtraUOM` | ❌ |
| **Prioriteta** | `Priority` | ❌ |
| **Povezana šifra + faktor količin + faktor cen** | `ParentItemID`, `ParentItemQtyConverter`, `ParentItemPriceConverter` | ❌ |
| **Šifra za primerjavo** | `ItemComparisonCode` | ❌ |
| **Ime za iskanje** | `ItemSearchName` | ❌ |

### Zavihek »Prodaja«

| SAOP polje | Element | PIM |
|---|---|---|
| **Garancija** | `Warranty` | ❌ |
| Skupina popusta | `DiscountGroup1ID` | ✅ |
| **Skupina 2.–5. popusta** | `DiscountGroup2ID` … `DiscountGroup5ID` | ❌ |
| **Skupina provizij** | `CommissionGroupID` | ❌ |
| **Periodike** | `PeriodicID` | ❌ |
| **Hitra koda** | `FastCode` | ❌ |
| **Minimalna prodajna cena** | `MinSalesPrice` | ❌ |
| Oznaka aktivnosti | `IsActive` | ✅ |
| **Status artikla** (npr. »Odprodaja«) | `ItemStatus` | ❌ — pomembno za splet in nabavo |
| **Odstotek prodajne / maloprodajne cene** | `SalesPricePercentage`, `RetailPricePercentage` | ❌ |
| **Rabatni izračun TDR** | `RebateCalculation` | ❌ |
| **Dovoljeno spreminjanje PC / MPC** | `SalesPriceChange`, `RetailPriceChange` | ❌ |
| **Ohrani maržni način** | `MaintainTradeMargin` | ❌ |
| **Stalna (planska) cena** | `PlannedPrice` | ❌ |
| Lastnost 1 | `AdditionalProperty1ID` | ✅ (vezana na oddelek) |
| **Lastnost 2, Master** | `AdditionalProperty2ID`, `AdditionalProperty3ID` | ❌ |
| **Objava WEB** (`B2B`) | `AdditionalProperty4ID` | 🟡 v registru je, a brez `FieldKey` — ni vidna |

### Zavihek »Lastnosti«

| SAOP polje | Element | PIM |
|---|---|---|
| Masa na enoto | `ItemWeightPerUnit` | ✅ |
| Prostornina na enoto | `ItemVolumePerUnit` | 🟡 »Volumen« je na kartici, **ni** v registru |
| Količina pakiranja (1) / (2) | `ItemQuantityOfPackaging`, `…2` | 🟡 Pak1/Pak2 sta na kartici, **nista** v registru |
| **Masa v g/m²** | `PaperWeight` | ❌ |
| Bruto teža | `ItemGrossWeight` | ✅ |
| **Merska enota cenika + količina** | `ItemUOMPriceList`, `ItemQuantityUOMPriceList` | ❌ |
| **Artikel je embalaža / enonamenski vavčer** | `Package`, `Voucher` | ❌ |
| **Zaporedna številka** | `ItemSequenceNumber` | ❌ |
| **Okoljska dajatev** | `EnvironmentalTax` | ❌ |
| Država porekla | `ItemCountryOfOrigin` | ✅ |
| **Poreklo iz stranke uporabnika** | `OriginFromCustomerUser` | ❌ |
| **Prispevek + vrsta prispevka** | `Contribution`, `ContributionType` | ❌ |
| **Podatki o embalaži (šifra + ME)** | `ItemPackageID`, `ItemPackageUOM` | ❌ |
| Dimenzija X (dolžina) | `ItemLength` | 🟡 **»Dolžina paketa« je na kartici, a je NI v registru** — Y in Z sta, X ni |
| Dimenzija Y (širina) | `ItemWidth` | ✅ |
| Dimenzija Z (višina) | `ItemHeight` | ✅ |
| Merska enota dimenzij | `ItemDimensionUOM` | ✅ |
| **Nevarne snovi ADR** | `ADRID` | ❌ |

### Zavihek »Zaloge«

| SAOP polje | Element | PIM |
|---|---|---|
| **Zaloge po serijah / serijske številke** | `ItemHasSeries`, `SerialNo` | ❌ |
| **Dnevi za opozorilo** | `WarningDays` | ❌ |
| **Obvezno vzorčenje** | `MandatorySampling` | ❌ |
| **Stalna cena / brez odvisnih stroškov / odvisni stroški** | `FixedPrice`, `WithoutSharedCosts`, `SharedCostID` | ❌ |
| **Kalo / dodatek prenos** | `UllageID`, `CooperationAddOnID` | ❌ |
| **Konsignant** | `ConsignorID` | ❌ |
| Dobavitelj / Proizvajalec | `SupplierID`, `ManufacturerID` | ✅ |
| **Skupina predloga** | `TemplateGroupID` | ❌ |
| Tip skladišča + konti (zaloge, porabe, obračunski) | — | 🟡 »Knjigovodske šifre« kaže samo knjižno skupino |

### Zavihki brez ustreznice

| SAOP zavihek | Vsebina | PIM | PIM_test |
|---|---|---|---|
| **Pretvorniki** | **več črtnih šifer** na artikel (šifra, opis, količina, ME) | ❌ | ❌ |
| **Zaznamki** | opombe na artiklu (datum, vrsta, opis, priponka) | ❌ | ❌ |
| **Pl.teh.podatki** | tehnološki postopek, pretočni časi, optimalna količina, fantom, projektni artikel, **izločeno iz rezervacij**, SM, SN, Knjiga DN, glavno skladišče | ❌ | delno: samo »izločeno iz rezervacij« |
| **Nazivi** (po jezikih) | naziv 1, naziv 2, **kratek naziv, merska enota, ME pakiranja** po jeziku | delno: naziv 1 in 2 po jezikih | delno |
| **Cene** / **Opisi** | cenovna področja / opisi po jezikih | ✅ | ✅ |

**Povzetek kartice artikla:** od 89 polj SAOP jih ima PIM v registru `out.SaopXmlField` **24**,
od tega jih ima kanonično vrednost 22.

Dve stvari, ki ju je treba povedati naravnost:

1. **Štiri polja so na kartici vidna, a jih ni v registru:** dolžina (`ItemLength`), volumen
   (`ItemVolumePerUnit`), pakiranje 1 in 2 (`ItemQuantityOfPackaging`, `…2`). Sama vrstica v
   registru **ni dovolj** — po preglednici `Mapiranje_SAOP_API_PIM.xlsx` (vir migracije 068)
   ta štiri polja **niso pisljiva**, zato jih `out.OwnershipPolicy` označi kot `Owner='SAOP'`.
   Da bi jih PIM smel pisati, je treba spremeniti preglednico oziroma seznam v migraciji 068 —
   to je **poslovna odločitev, ne tehnična**. Širina in višina sta pisljivi, dolžina ni; to je
   po vsej verjetnosti pomota v preglednici in jo je vredno preveriti.
2. **Dve polji sta po preglednici pisljivi, a jih v registru ni:** `GeneralData/ItemSearchName`
   (Ime za iskanje) in `SalesData/Warranty` (Garancija). Ti dve se dasta dodati takoj, brez
   poslovne odločitve.
3. **Preglednica dovoljuje tudi tri dokumente, ki jih PIM sploh ne pošilja:**
   `ItemTitleLanguage/*` (nazivi po jezikih), `ItemDescription/*` (opisi po jezikih) in
   `ItemCustomProperty/*` (lastnosti po meri). To pomeni, da bi PIM smel prevode in atribute
   pisati nazaj v SAOP — danes tega ne dela ne PIM ne PIM_test.
4. `ItemPlanningData/ItemExcludeQtyReservation` je **že zdaj pisljiv** po preglednici; zajem
   `GetItemsPlanningData` že teče (migracija 082), manjka samo odhodna oblika dokumenta in stran.

---

## 5. Kartica stranke — kaj manjka

PIM ima 6 zavihkov (Splošni, Komercialni, Poslovne enote in tranziti, Zaznamki,
Dokumenti in finance, Zgodovina) — struktura je **enaka ali boljša od PIM_test**.
Manjkajo pa podatki:

| Podatek | Zakaj je potreben | PIM_test | PIM |
|---|---|---|---|
| **Kontakti: e-pošta, telefon, mobitel, uporabniki (osebe)** | so **obvezni stolpci Magento CSV**; brez njih izvoz strank ne more biti popoln | iz `raw.{Org}_CustomerContacts_current` + ročni prepis v `pim.CustomerWebProfile`, ki prevlada; več kontaktov zloženih z ` \| ` | ❌ **ni jih nikjer** |
| **Bančni račun (IBAN), SWIFT/BIC** | finančni zavihek | zavihek »Finančni podatki« iz `raw` | ❌ zavihek pokaže samo `PimMissing` |
| **Popust NW (%)** | poseben popust za Nowodvorski | ✅ | ❌ |
| **Prepis skupinskega popusta** (odstotek, količina, veljavnost) + skrivanje vrstic | popusti iz SAOP `ComercialTerms` niso vedno pravi | ✅ z zgodovino | ❌ samo branje |
| **»Skrij iz pregleda registra«** | register ima na tisoče neaktivnih strank | ✅ | ❌ |
| **Zapis nazaj v SAOP (PATCH)** | naslov, naziv, cenik, plačilni rok se popravljajo v PIM-u | ✅ 15 polj | ❌ |
| **Nova stranka (POST)** | | ✅ | ❌ |
| **Izvoz / uvoz XLSX** | množično popravljanje | ✅ | ❌ |
| **Magento CSV na zahtevo** | Tadej ga potrebuje ad hoc | ✅ | 🟡 samo prek workerja |
| Poslovne enote iz polja »Plačnik« samodejno | | ✅ samodejno + ročni popravek | 🟡 ročni vnos |

Kar ima PIM **bolje**: vrednostni rabat s pragovi (urejanje 1–3 stopenj), posebni popusti na
izdelek, revizijska sled v `b2b.AuditLog` na vsak zapis, tip stranke ↔ Magento skupina kot
preslikava v šifrantu.

---

## 6. Kako bi izgledala idealna stran

**Osnova = PIM.** Navigacija, postavitev baze, procedure `intranet.*`, lastništvo polj,
odobritev odhodne pošte, validacijski profili in workerji ostanejo, kot so. Iz PIM_test se
preseli **funkcionalnost, ne koda** — nič inline SQL-a v Blazor, vse skozi nove procedure.

### Navigacija (nespremenjena, dopolnjena)

```
NADZOR       Nadzorna plošča
VHODI        Zajem podatkov (hub)          ← +  Novi artikli iz XML
PIM          Izdelki · Mediji (hub)        ← Mediji postanejo hub s 5 podstranmi
KAKOVOST     Kakovost podatkov (hub)       ← + Karantena: popravi in revalidiraj
IZHODI       Izhod v SAOP (hub)            ← + Nov artikel · Sprememba · Množično · Planiranje · Ponovno pošiljanje
             Izhod na splet (hub)          ← + Izvoz na zahtevo (CSV artikli/stranke)
POSLOVANJE   Stranke · Zaloga · Cene · Preverbe
UPRAVLJANJE  Nastavitve kataloga (hub) · Pravila (hub)
ADMIN        Sistem (hub)                  ← + Dnevnik dejavnosti · Tehnični zemljevid · Pomoč
```

Nobene nove postavke v glavnem meniju — vse novo visi pod obstoječimi hub stranmi.
To je natanko tisto, kar je v PIM_test razpršeno na 13 skupin s po 6 podstranmi.

### Kartica artikla — ciljna oblika

Zavihki ostanejo: **Pregled · Osnovni podatki (ERP) · Komerciala · Splet · Kakovost in zgodovina**.
Dodati:

- V zavihku ERP tri nove skupine, ki sledijo SAOP zavihkom:
  **»Prodaja«** (status artikla, garancija, skupine popusta 2–5, min. prodajna cena,
  kalkulacija), **»Zaloge in šifranti«** (konsignant, kalo, serije, skupina predlog),
  **»Lastnosti«** (embalaža, okoljska dajatev, ADR, prispevek, ME cenika).
- Nov zavihek **»SAOP endpoint«** — surov posnetek `raw.{Org}_data_current` za ta artikel,
  s poudarjenimi polji, ki se razlikujejo od kanonične vrednosti. To je edina stvar iz
  PIM_test, ki je v PIM ni in je pri iskanju napak neprecenljiva.
- Nova zavihka **»Pretvorniki«** (več črtnih šifer) in **»Zaznamki«** — v obeh sistemih ju ni,
  v SAOP-u pa sta.

### Kartica stranke — ciljna oblika

Zavihki ostanejo (6). Dodati:

- V »Splošni podatki«: **kontakti** (e-pošta, telefon, mobitel, osebe) z ročnim prepisom nad
  SAOP izvorom, in gumb **»Uredi v SAOP«**, ki odpre 15 pisljivih polj.
- V »Finančni«: IBAN in SWIFT iz `raw`.
- V »Komercialni«: Popust NW, prepis skupinskega popusta z veljavnostjo.
- Na `/stranke`: **Nova stranka**, **Izvozi XLSX**, **Uvozi XLSX**, **Magento CSV**.

### Izhodi — ciljna oblika

```
/saop                    hub: stanje, skupine, čakajoče na odobritev
  /saop/nov              nov artikel (POST)         ← novo
  /saop/sprememba        sprememba enega artikla    ← novo
  /saop/mnozicno         obstoječe + polnjenje iz XML vira ← razširjeno
  /saop/planiranje       izločanje iz rezervacije   ← novo
  /saop/zgodovina        + gumb »pošlji znova«      ← razširjeno
  /saop/polja, /saop/odkloni  (obstajata)

/splet                   hub: datoteke z diska (obstaja)
  /splet/izvoz           izvoz na zahtevo s filtri in prenosom ← novo
```

---

## 7. Priporočilo

### Kaj urejati naprej: **PIM (NoviPIM)**

Ne zaradi lepote, ampak ker so razlike, ki jih je težko nadomestiti, **vse na strani PIM-a**:

1. **Postavitev baze.** PIM ima `raw → stg → canon → val → out` z lastništvom polja in
   revizijo. PIM_test bere `raw.{prefix}_*` tabele z dinamično sestavljenimi `UNION` stavki
   po organizacijah — vsaka nova organizacija je nov `if` v C#.
2. **UI ne pozna SQL-a.** Vsaka nova stran v PIM_test doda inline SQL v `PimQueryService.cs`,
   ki ima 5.064 vrstic in 40 partialov. To je natanko tisto, kar te moti pri vzdrževanju.
3. **Migracije so oštevilčene in preverjajo same sebe.** 190 datotek brez zaporedja se ne da
   ponoviti na čisti bazi.
4. **60 testnih projektov proti 0.**
5. **Odobritev pred pošiljanjem in samodejna odločitev ADD/PATCH** — dve stvari, ki sta v
   starem sistemu povzročili večino napak.

Manjkajoče funkcije so **manjkajoče strani nad obstoječim zaledjem**, ne manjkajoča
arhitektura. `SaopIntentResolver`, `SaopDocumentBuilder`, `out.SaopDocument` (artikli, stranke,
ceniki, cene) in `PIM.OutboxDispatcher` že obstajajo in so testirani.

### Kaj lahko imaš rešeno do jutri

Po vrsti, od najkrajšega:

| # | Naloga | Zakaj gre hitro | Ocena |
|---|---|---|---|
| 1 | **`ItemSearchName` in `Warranty` v `out.SaopXmlField`** | preglednica ju že označuje kot pisljiva, manjka samo vrstica v registru | ena migracija |
| 2 | **Gumb »pošlji znova« na `/saop/zgodovina`** | `out.OutboxMessage` že ima stanje in števec poskusov | ena procedura + gumb |
| 3 | **Izvoz na zahtevo `/splet/izvoz`** — filtri + prenos CSV | `intranet.GetExportPreview` in register stolpcev že obstajata; manjka pretočni zapis | pol dneva |
| 4 | **Kontakti na kartici stranke** | zajem `raw.{Org}_CustomerContacts_current` že teče; treba je razširiti `intranet.GetCustomerCard` | pol dneva |
| 5 | **Zavihek »SAOP endpoint« na kartici artikla** | branje `raw.{Org}_data_current` v eni poizvedbi; vzorec je v PIM_test | pol dneva |
| 6 | **Razširitev registra na vseh 89 polj SAOP** | mehansko delo iz `SaopItemFieldCatalog.cs`; **zahteva odločitev, katera polja sme PIM pisati** | dan |
| 7 | **Stran »Nov artikel v SAOP«** | zaledje že zna ADD (`SaopIntentResolver`) | dan |
| 8 | **Izločanje iz rezervacije** | lastništvo je že podeljeno, zajem teče; manjka `out.SaopDocument` za `SAOP_ITEM_PLANNING` + stran | dan |
| 9 | Stranke: PATCH in POST v SAOP | `out.SaopDocument` za `SAOP_CUSTOMER` že obstaja, lastništvo pa dovoli samo naziv → treba je razširiti `out.OwnershipPolicy` | dan in pol |

**Za jutri realno: 1, 2, 3, 4 in 5.** To je pet stvari, ki jih lahko sam preizkusiš v vmesniku,
in vsaka zapre eno konkretno luknjo. Rešitev je preverjena z `dotnet build PIM_Solution\PIM.sln`
(2026-09-02: prevede se brez napak).

Točna navodila za Codexa so v [`PROMPT_CODEX_PIM_INTRANET.md`](PROMPT_CODEX_PIM_INTRANET.md).
