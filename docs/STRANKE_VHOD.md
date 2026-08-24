# Stranke — kaj manjka, da izvoz ni več prazen

Merjeno 2026-08-24 nad bazo `PIM` (migracija 096).

## Kratek odgovor

**Mehanizem je cel. Manjka podatek.** `out.ExportB2bCustomersCsv` je napisan, registri obstajajo,
pragovi so vpisani — izvoz vrne prazno datoteko samo zato, ker je `pim.CustomerWebProfile`
prazen, ta pa nima vira.

| Kos | Stanje |
|---|---|
| `out.ExportB2bCustomersCsv` | napisan, bere profil, registre in pragove |
| `pim.CustomerTypeMagentoGroup` | **18 tipov** strank vpisanih, `MagentoGroupKey` **prazen pri vseh** |
| `pim.ValueDiscountTier` | 3 pragovi: ≥ 800 → 1 %, ≥ 1.500 → 2 %, ≥ 3.000 → 3 % (po dokumentu §4.6) |
| `pim.CustomerValueDiscountTier` | 0 (izjeme po stranki; privzetki zgoraj veljajo, dokler jih ni) |
| `b2b.Customer` | **11.558** strank iz SAOP |
| `b2b.CustomerItemGroupDiscount` | 4.271 vrstic, ključ je **skupina strank × skupina artiklov** |
| `pim.CustomerWebProfile` | **0** — tu se veriga pretrga |

## Zakaj profila ni mogoče napolniti iz SAOP

`pim.CustomerWebProfile.CustomerTypeCode` je nosilna vez: iz njega pride Magento skupina, iz
skupine pa cene in popusti (dokument §4.1). Teh 18 tipov je poslovna taksonomija —
`RESELLER`, `RESELLER_BRANCH`, `RESELLER_TRANSIT`, `INSTALLER`, `INSTALLER_MAX`, `CARPENTER`,
`DESIGNER`, `PUBLIC_SECTOR`, `END_B2B` in njihove neaktivne različice.

**SAOP tega ne pošlje.** Preverjeno na surovem odgovoru končne točke `Customers`:

| Polje SAOP | Vrednosti | Kaj je |
|---|---|---|
| `CustomerType` | `O` 11.514, `K` 47, `S` 1, `D` 4 | vrsta partnerja, ne poslovni tip |
| `EntityType` | `P` 4.784, `F` 2.643 | pravna/fizična oseba |
| `CompanyLinkType` | `I` pri **vseh 4.683** | konstanta |

`CompanyLinkType` je bil kandidat za razločevanje PE/tranzit iz §4.10 dokumenta. **Ni** — pri
vseh strankah ima isto vrednost. Tudi PE/tranzit torej nima vira v SAOP.

## Kaj mora priti iz preglednice STRANKE

Po stolpcih iz `pravila/Magento_Pravila_Cene_Popusti_Postnine 1.docx`:

| Stolpec preglednice | Cilj v PIM | Danes |
|---|---|---|
| Šifra stranke | `b2b.Customer.CustomerKey` | ✅ iz SAOP |
| Naziv | `b2b.Customer.Name` | ✅ iz SAOP |
| Cenik | `b2b.Customer.PriceListCode` | ✅ iz SAOP (B2B 1.303, B2C 1.337, brez 8.922) |
| Plačnik | `b2b.Customer.PayerCode` | ✅ iz SAOP |
| **Tip stranke** | `pim.CustomerWebProfile.CustomerTypeCode` | ❌ **samo iz preglednice** |
| **Skupina (Magento)** | `pim.CustomerTypeMagentoGroup.MagentoGroupKey` | ❌ 18 vrstic brez vrednosti |
| Vrsta stranke | `pim.CustomerWebProfile.CustomerKind` | ❌ |
| Popust polno pakiranje | `pim.CustomerWebProfile.PackagingDiscountEnabled` | ❌ |
| Vrednostni rabat | `pim.CustomerWebProfile.ValueDiscountEnabled` | ❌ |
| Rabat prag/% 1–3 | `pim.CustomerValueDiscountTier` (privzetki obstajajo) | ⚠️ samo izjeme |
| B2B+ | `pim.CustomerWebProfile.B2bPlusEnabled` + veljavnost | ❌ |
| Skupine popustov | `b2b.CustomerItemGroupDiscount` | ⚠️ podatek je, ključ je skupina — brez tipa ga ni mogoče pripeti |
| E-pošta, telefon, uporabniki | — | ❌ nikjer, tudi stolpec izvoza nima kanonične kode |

## Dve vrzeli, ki ju dokument sam našteje

1. **Neto ceniki po stranki** (primer Topdom): izvoz izdelkov pošilja le `Cena B2B` in
   `Cena B2C`. Per-cenik neto cene niso v izvozu.
2. **PE podeduje osnovne popuste od plačnika** (§4.10): ni izvedeno in — kot je izmerjeno
   zgoraj — brez podatka o PE/tranzit tudi ne more biti.

## Zakaj tu nisem pisal kode

Napolniti `pim.CustomerWebProfile` iz SAOP bi pomenilo izmisliti tip stranke. Izvoz bi potem
oddal 11.558 vrstic s prazno ali ugibano skupino — po dokumentu je skupina **nosilna vez za vse
cene in popuste**, zato bi bila napačna skupina dražja od prazne datoteke.

## Odločitev uporabnika 2026-08-24

> »Tipa stranke, ali je kupec, trgovec ali oboje, bo potrebno da uporabnik sam določi — tako da
> to bo dodatni stolpec. Za poslovno enoto ima ponavadi v nazivu PE poleg; je treba omogočiti,
> da uporabnik sam določi, kdo je poslovna enota in pa tranzit.«

S tem vrsta stranke in PE/tranzit **nista uvožena podatka, ampak PIM-lastni polji**, ki ju
postavi človek. To se ujema z izmerjenim: SAOP tega ne ve.

`pim.CustomerWebProfile.CustomerKind` je za to že pripravljen — `CHECK` dovoljuje
`CUSTOMER` / `SUPPLIER` / `BOTH`, torej natanko kupec / trgovec / oboje.

## Izvedeno 2026-08-24 (migraciji `097` in `098`)

- `pim.CustomerWebProfile.PayerKind` (`PE` / `TRANZIT`).
- `pim.PromoteCustomerWebProfile` — vrstica profila za vsako **aktivno** stranko (4.390 od
  11.566). Postopek je namenoma prazen: nobene od treh odločitev ne postavi in nobene ne
  prepiše, zato ga je varno pognati vsako noč. `WebEnabled` ostane 0, dokler stranka nima tipa,
  zato izvoz ostane prazen — po dokumentu je skupina nosilna vez in stranka brez nje v izvoz
  ne sme.
- `pim.CustomerWebProfileToDecide` — delovni seznam: **4.390** strank čaka odločitev, od tega
  ima **149** plačnika, ki ni ona sama (samo te potrebujejo PE/tranzit), in pri **52** naziv
  vsebuje »PE« kot ločeno besedo — to je predlog, ki se v profil ne zapiše sam.

## Kaj je potrebno, po vrsti

1. **Vmesnik, kjer uporabnik postavi tri polja** — vrsta (kupec/trgovec/oboje), tip stranke in
   PE/tranzit. Podatkovni sloj je narejen; ostane stran v intranetu.
2. **Imena 18 Magento skupin** — `RESELLER → b2b_trgovec` in podobno; 18 vrstic v registru.
3. **Preglednica STRANKE**, če pragovi rabata, B2B+ in »popust polno pakiranje« pridejo od tam
   in ne iz vmesnika.
