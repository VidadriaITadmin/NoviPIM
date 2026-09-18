# Katalog za splet: preslikava atributov Nowodvorski (NW) / Braytron (BT) / ERP

Stanje 2026-09-16, po migraciji `216`. Podlaga: `map.FieldMapping` (konektorja `NW_XML` 4002 in
`BT_XML` 4065), `map.SourceAttribute` (odkriti atributi vira), katalog `izvoz\magento\2\katalog.csv`
(2.176 vrstic: 2.090 NW, 86 BT) in stara razvojna baza `PIM_test` (`pim.AttributeSourceMap`,
uporabnikova ročna preslikava iz pomladi 2026).

Vprašanje uporabnika: *»enkrat imamo Napetost stolpec od Braytrona, enkrat pa od NW — to bi moralo
biti eno in isto in od obeh pokazat v enem stolpcu; takih atributov je še veliko, naredi seznam,
katere bi bilo treba mapirati in kako.«*

## 1. Kaj je migracija 216 že poenotila

| Stolpec kataloga | Prej | Zdaj |
|---|---|---|
| `Napetost [V]` | NW `~220-230` (+ ločen stolpec "Enota napetosti" = V); BT `220-240V 50/60Hz` v **dveh** stolpcih (Napetost **in** Nazivna napetost) | oba v enem stolpcu: NW `~220-230`, BT `220-240`; podvojena BT preslikava v "Nazivna napetost" izklopljena, njene vrstice izbrisane |
| `Frekvenca [Hz]` | samo NW (`50/60`, `50/60 Hz`, `50-60Hz` …); BT brez frekvence | NW `50/60` (enota odvzeta), BT `50/60` (izluščeno iz `220-240V 50/60Hz` — nova preslikava iz istega elementa, pretvorbe `REQUIRE Hz` → `AFTER ' '` → `BEFORE Hz`) |
| NW `NW.11710` | frekvenca `~220-230`, napetost `50/60` (zamenjano v XML) | zamenjava se popravi že pri zajemu (`map.ApplyValueTransforms`, blok `SwapVoltageFrequency216`) |
| `Garancija` | `2 leti`, `5 years`, `3 Years`, `2` | `pim.WarrantySl`: 1 leto / 2 leti / 3 leta / 4 leta / 5 let; pri zajemu (pretvorba `WARRANTY`), v izvozu in enkratno na obstoječih vrsticah |
| vsi stolpci `… SLO` / `… ANG` | `hodnik`, `kopalnica`, `lamp hanger` | velika začetnica: slovar `map.ValueLookup`, obstoječe vrednosti, izvoz, zajem (pretvorba `CAPITALIZE`) |
| 40 stolpcev `Enota …` | ločen stolpec z enoto (večinoma prazen) | enota v glavi (`Višina [mm]`, `Bruto teža [kg]` …), vrednost pretvorjena v enoto glave (`out.CatalogUnitRule`, `out.UnitFactor`) |
| `Proizvajalec`, `Dobavitelj` | šifri `00001625`, `91086973` | `Nowodvorski`, `ViD Adria d.o.o.` (`canon.PartnerName`) |
| `Kategorije vid ANG/SLO` | prazno (drevo videlektro brez preslikav dobaviteljev) | ista pot kot pri svetilih pod nadkategorijo `Razsvetljava > …` / `Lighting > …` (216 zrcalo, 217 premik pod `razsvetljava`; zrcaljeni tračni sistemi združeni z obstoječimi) |
| `Komentarji` | prosto besedilo NW | izklopljen |
| `Popust` → `Popust na artikel`, `PAK2` → `Pakirna količina` | stari glavi | preimenovani (217, sestanek 2026-09-16); vira nespremenjena |

## 2. Isti podatek, danes v dveh stolpcih — predlog združitve (čaka na odločitev)

Vsaka vrstica je en podatek, ki ga danes vsak dobavitelj pošlje v svoj stolpec. Predlagana
rešitev je vedno "ena kanonična koda, obe preslikavi vanjo" — sprememba je vrstica v
`map.FieldMapping`, ne koda.

| # | Podatek | NW danes | BT danes | ERP danes | Predlog |
|---|---|---|---|---|---|
| 1 | **Bruto teža** | — (ERP) | `gw` → `Bruto teža (2) [kg]` (`3,8 kgs`) | `Bruto teža [kg]` iz SAOP (101 vrstic = 0) | en stolpec `Bruto teža [kg]`: ERP je lastnik; kadar ERP pošlje 0 ali nič, izvoz vzame dobaviteljevo (BT `gw`). Stolpec "(2)" ukiniti. Enako **Neto teža** (`nw`). |
| 2 | **Mere izdelka** (višina/širina/dolžina) | NW jih **ne pošilja** (samo roke, senčnik, podnožje, stropna kapica) — zato 1.900 opozoril "Višina manjka" pri NW | `height/width/length` → `Višina/Dolžina/Širina [mm]`, `diameter` → `Premer [mm]` | — | stolpci ostanejo; opozorilo za NW izdelke naj se veže na kategorijo (nabor atributov 147/177), ne na vse — NW podatka nima |
| 3 | **Mere paketa** | `package_height`, `width_packaging`, `length_packing` (cm) → `… paketa I [cm]` | `package_*` (mm ali cm) → `… paketa I [cm]` | `Dolžina/Širina/Višina paketa [mm]` iz SAOP (pri NW 202 vrstic v "m", vse 0) | dva vira za isto: ERP stolpci (3) in dobaviteljevi "paket I" (3). Predlog: ERP je lastnik; ko je ERP 0, vzemi dobaviteljev paket I (pretvorba cm → mm je od 216 samodejna). Stolpce "paket II/III" pusti (NW pošlje več paketov). |
| 4 | **Nazivna moč** | NW `Clean_Wattage` v PIM_test; danes v NW preslikavi **ni** (NW pošlje `maximum_wattage` = "25W only LED" → `Max moč sijalke`) | `wattage` → `Nazivna moč [W]` | — | pravilno: NW "maximum wattage" je največja moč sijalke (svetilka brez vira), BT "wattage" je moč vgrajenega LED. Dva različna podatka — ostaneta dva stolpca. |
| 5 | **Vrsta svetlobnega vira** | `light_sources_type` (Replaceable/Built-in) → `Vrsta svetlobnega vira` | `light_source` (LED) → `Vrsta svetlobnega vira` | — | **napačno združeno**: NW pove "zamenljiv/vgrajen", BT pove tehnologijo "LED". BT `light_source` preusmeriti v `Tehnologija` (atribut obstaja v registru, 1.654 opozoril "Tehnologija manjka"), za BT dodati `Vrsta svetlobnega vira = vgrajen` kadar `light_source = LED` in `socket` prazen. |
| 6 | **Grlo** | `light_source` (E14, GU10) → `Grlo` | `socket` (Magnetic, E27) → `Grlo` **in** `Podnožje / socket` | — | BT `socket` gre v dva stolpca; `Podnožje / socket` ukiniti (0 vrstic v katalogu), obdržati `Grlo`. |
| 7 | **Število svetlobnih virov** | `number_of_light_sources` | `led_quantity` (`360led/mt`) **ni preslikan** | — | PIM_test ga je vezal na isto kodo; vrednost BT je število LED na meter, ne število virov — pustiti nepreslikano ali nov atribut `Število LED na meter`. |
| 8 | **Senzor gibanja** | `motion_sensor` (Yes/No → 1/0) | `sensor_type` (PIR) **ni preslikan** (PIM_test: → Senzor gibanja) | — | BT `sensor_type` → `Senzor gibanja` s pretvorbo `BOOL` (vrednost ≠ prazno → 1) ali ločen atribut `Vrsta senzorja` (PIR/mikrovalovni). |
| 9 | **Temperatura barve** | `colour_temperature` (`3000K`) | `color_temperature` (`3000K`, `3IN1`) | — | že en stolpec `Temperatura barve [K]`; `3IN1` (BT preklopna) ostane besedilo — Magento ga ne bo filtriral; predlog: ločen atribut `CCT preklop = da`. |
| 10 | **Kot svetlobnega snopa** | `beam_angle` (120 + enota ⁰) | `beam_angle` (`380` = 38°, `1200` = 120° — vir pošlje "°" kot "0") | — | en stolpec `[°]`; BT vrednosti so **napačne v viru** (znak stopinje pretvorjen v ničlo, 112 × "1200"); potreben popravek pri Braytronu ali pravilo "če > 360 in deljivo z 10 → /10". |
| 11 | **Življenjska doba** | `lifetime` (`20000 h`) | `lifetime` (`20000 h`) | — | en stolpec `[h]` ✔ |
| 12 | **CRI** | `cri` (`>80`, `≥80`) | `color_rendering_index_cri` (`>80`) | — | en stolpec ✔; poenotiti znak (`≥80` → `>80`) — pretvorba `LOOKUP` ali `STRIPPREFIX`. |
| 13 | **IP / IK** | `ip` (`IP20`) | `ip` (`IP65`), `ik` | — | en stolpec ✔ (IK samo BT). |
| 14 | **Zatemnljivo** | — (NW pošlje v `comments`/`symbol`) | `dimmable` (Not-Dimmable/Dimmable) → SLO `ne`/`dimmable` | — | slovar: `Dimmable` → `Da`, `Not-Dimmable` → `Ne` (danes `dimmable` ostane angleško, ker v `map.ValueLookup` ni prevoda). |
| 15 | **Električni razred** | `electrical_security_class` (`I`) | `class` (`CLASS II` → `II`) | — | en stolpec ✔ (samo ANG; SLO ni potreben). |
| 16 | **Energijski razred** | `energy_efficiency_class` | `energy_efficiency_level` | — | en stolpec ✔ |
| 17 | **Prevladujoča barva / material** | `leading_colour`, `leading_material` (+ slovar SL) | `body_color`, `material` (+ slovar SL) | — | en stolpec ✔; 44 od 45 barv in 28 od 35 materialov je bilo z malo — popravljeno v 216. Manjkajoči prevodi (`sage green`, `PP`, `ABS+PC`) so v `map.MissingTranslation`. |
| 18 | **Uporaba / Slog / Način montaže** | NW | BT ne pošilja | — | samo NW ✔ |
| 19 | **EAN koda** (atribut, COL113) | — | `ean` ni preslikan | `EAN` (stolpec 2) | atributni stolpec `EAN koda` je vedno prazen — ukiniti. |
| 20 | **Nazivna jakost toka** | — | `current` (`87 mA`) | — | enota v vrednosti (mA/A) — ko se pojavi še kak vir, dodati v `out.CatalogUnitRule` z enoto `A` in pretvorbo mA → A. |
| 21 | **Max moč sijalke** | `maximum_wattage` (`25W only LED`) | `max-wattage` (`2×9 w`, `40W`) | — | en stolpec ✔, ostane besedilo. |
| 22 | **Kategorija dobavitelja** | `category` (3 ravni) → `map.CategoryPathMap` | `main_family`/`sub_family`/`type` → `map.CategoryPathMap` | — | ✔; od 216 ista preslikava velja za `svetila_si` in `videlektro`. |
| 23 | **Videoposnetek, Model, Ikone, Velikost** | — | BT | — | samo BT ✔ |

## 3. Braytron: odkriti atributi brez preslikave

`map.SourceAttribute` (BT_XML) pozna 63 atributov, preslikanih je 58. Brez preslikave:
`capacity_watt` (4,5 w — moč polnilnika), `led_quantity` (glej #7), `main_family` / `sub_family` /
`type` (kategorija, gre po drugi poti), `sensor_type` (#8), `weight` (`380 gr` — PIM_test ga je
vezal na Bruto težo; danes je bruto teža BT v `gw`, `weight` je teža izdelka brez embalaže → to je
pravzaprav **neto teža**; predlog: `weight` → `Neto teža (2)`, `nw` ostane).

## 4. Nowodvorski: česar XML ne pošilja

Mere izdelka (višina/širina/dolžina/premer), nazivna moč, tehnologija, zatemnljivost kot ločen
atribut. Opozorila "manjka" za te atribute pri NW izdelkih (1.900 × Višina, 1.708 × Nazivna moč,
1.654 × Tehnologija) so zato napaka nabora, ne podatka — nabor kategorij (147/177) naj jih za
NW kategorije označi kot `RECOMMENDED`, ne `REQUIRED`.

## 5. Kako se preslikava spremeni (brez kode)

```sql
-- primer #5: BT light_source -> Tehnologija namesto Vrsta svetlobnega vira
UPDATE m SET TargetFieldCode = N'ProductAttribute.Tehnologija', UpdatedBy = N'urednik', UpdatedUtc = SYSUTCDATETIME()
FROM map.FieldMapping m JOIN map.SourceConnector c ON c.SourceConnectorId = m.SourceConnectorId
WHERE c.SourceCode = N'BT_XML' AND m.SourceElement LIKE N'%slug="light_source"%'
  AND m.TargetFieldCode LIKE N'ProductAttribute.Vrsta svetlobnega vira%';
```

Vsaka taka sprememba naj gre kot oštevilčena migracija (`sql/migrations`), da velja na vseh
štirih konektorjih BT_XML (4065, 4133, 4134, 4135) in na produkciji.
