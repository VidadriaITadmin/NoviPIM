# S popusti, odprodaja, uvozi/izvozi — ugotovitve testiranja (2026-09-24)

Okolje: DEV, baza **SONJA/PIM** (migracije do 275), koda `main` @ `a2f8cde`.
Viri pravil: `Magento_Pravila_Cene_Popusti_Postnine 1.pdf` (§ v nadaljevanju), cenik
`pdf_datoteke/ceniki_skupine_popusta_vpak.xlsx` (listi razsvetljava / elektro_material / ViD_Tech).

Oznake: **[POTRJENO]** = reproducirano na SONJA; **[KODA]** = najdeno v kodi, logika jasna;
**[ODLOČITEV]** = ni napaka v kodi, potrebna je poslovna odločitev.

## Kaj deluje (testi zeleni)

| Test | Rezultat |
|---|---|
| `PIM.F11.SPopustiTests` (uvoz cenika, pravila po tipu/stranki, katalog.csv, stranke.csv, filtri, delovni list strank in izdelkov) | 34 OK, 0 napak |
| `PIM.F7.MagentoExportTests` (pogodba CSV, izvoz proti bazi, 251 odjave, katalog lifecycle) | PASS |
| Odprodaja ročni vnos → katalog.csv (v transakciji z ROLLBACK) | »Odprodaja« DA, popust 30, količina 4, razstavni DA; količina 0 → NE; zaključitev → NE in razstavni NE |
| Svež katalog.csv IQLighting | 2355 vrstic, 181 stolpcev, brez podvojenih glav; S kode v katalogu = S kode v bazi (31/31) |

---

## A. Odprodaja

### A1. Uvoz istega vira v drugem podjetju zaključi odprodajo prvega podjetja — [POTRJENO] VISOKO
- **Kje:** `sql/migrations/275_OdprodajaPregledInRocniVnos.sql`, `pim.SaveClearanceItems`, veja
  `WHEN NOT MATCHED BY SOURCE AND target.Vir = @Vir AND target.IsActive = 1`.
- **Zakaj:** `pim.ClearanceItem` nima `OrganizationId`; cilj MERGE je cela tabela, filter je samo po `Vir`.
- **Koraki:** uvozi seznam z virom »Azzardo« v Vidadria (3), nato isti vir v IQLighting (2).
- **Pričakovano:** odprodaja v Vidadria ostane aktivna. **Dejansko:** vse vrstice vira v Vidadria se zaključijo
  (`EndedBy = 'uvoz: Azzardo'`). Enako za privzeti vir »Ročno« pri ročnem vnosu.
- **Popravek:** cilj MERGE omejiti na podjetje, npr.
  `WITH target AS (SELECT ci.* FROM pim.ClearanceItem ci JOIN canon.Product p ON p.ProductId = ci.ProductId WHERE p.OrganizationId = @OrganizationId AND ci.Vir = @Vir) MERGE target ...`.
  Nova migracija (276), ne popravljati 275.

### A2. Podvojena šifra v Excelu podre cel uvoz odprodaje — [POTRJENO] VISOKO
- **Kje:** `ClearanceService.PreviewAsync` (ne odstrani/ne opozori dvojnikov) + `pim.SaveClearanceItems`.
- **Dejansko:** `Violation of UNIQUE KEY constraint 'UQ_ClearanceItem_ProductVir'` — nič se ne zapiše, uporabnik
  dobi tehnično sporočilo. Predogled je pokazal, da je vse v redu.
- **Popravek:** v predogledu zaznaj dvojnike (opozorilo »šifra X je v datoteki večkrat, upoštevana bo zadnja/prva«),
  v `ApplyAsync` pošlji samo eno vrstico na šifro; v proceduri dodatno `ROW_NUMBER() ... PARTITION BY ProductId`.

### A3. Decimalna vejica v uvozu odprodaje: »29,78« → 2978 — [KODA] VISOKO
- **Kje:** `src/PIM.Intranet/Services/ClearanceService.cs`, `ParseDecimal`:
  `decimal.TryParse(trimmed, NumberStyles.Any, CultureInfo.InvariantCulture, ...)`.
- **Zakaj:** `NumberStyles.Any` vsebuje `AllowThousands`; z invariantno kulturo je vejica ločilo tisočic, zato
  prvi `TryParse` uspe z napačno vrednostjo in rezervna zamenjava `,`→`.` se nikoli ne izvede.
  Isti hrošč je bil že popravljen v `SameValue` (commit `35bea94`).
- **Vpliv:** celica kot besedilo (»29,78«, »12,5 %«) → redna cena 2978, popust 125 %. Številske celice Excela
  niso prizadete.
- **Popravek:** kot v 35bea94 — najprej `sl-SI`/zamenjava vejice, `NumberStyles.Number` brez `AllowThousands`.

### A4. Uvoz odprodaje ne preverja popusta 0–100 — [KODA] SREDNJE
- `pim.SaveClearanceItem` (ročni) preverja 0–100, `pim.SaveClearanceItems` (Excel) ne. V kombinaciji z A3 lahko
  gre v katalog.csv »Odprodaja - popust %« = 125 in negativna odprodajna cena.
- **Popravek:** opozorilo v predogledu + zavrni vrstico v proceduri.

### A5. Datoteka brez ujemajočih šifer (napačno podjetje/datoteka) zaključi celoten vir — [POTRJENO] SREDNJE
- Po zasnovi (»datoteka je celotno stanje vira«), a predogled ne pove, **koliko aktivnih vrstic bo zaključenih**.
- **Popravek:** v predogled dodaj »Zaključenih bo N aktivnih odprodaj tega vira« in zahtevaj potrditev, če je N > 0
  in je ujemanj 0.

### A6. Dva vzporedna sistema odprodaje v katalog.csv — [ODLOČITEV]
- Sistem 204/207: `COL030 Popust na artikel` in `COL217 Popust odprodaje %` (oba `Product.ClearancePercent`),
  `COL216 Količina odprodaje` (`Clearance.Quantity` = lastna zaloga pri ABC X/O).
- Sistem 232/275: `Odprodaja`, `Odprodaja - popust %`, `Odprodaja - količina`, `Razstavni eksponat`.
- V svežem katalogu IQLighting ima **84 artiklov »Količina odprodaje« > 0 s popustom 0 %** (sistem 204/207).
- Odločiti: kateri sistem bere Magento; drugega umakniti iz profila `MAGENTO_PRODUCTS` (15).
- Latentno: `Clearance.Quantity` se v `out.GetExportRows` vstavi dvakrat (B7 iz `pim.ProductClearance` in 207),
  kar bi dalo »5 | 0«. Tabele `pim.ProductClearance` danes ne piše noben zaslon (0 vrstic) — odstraniti B7.

### A7. Manjše — [KODA] NIZKO
- Ročni vnos ne zapiše redne cene → »Odprodajna cena« v pregledu prazna.
- Artikel z dvema virom: velja najnovejša aktivna vrstica; če ima ta količino 0, izvoz reče NE, čeprav ima starejši
  vir količino > 0.
- Neprepoznana vrednost v stolpcu »Razstavni eksponat« (npr. »yes«) tiho pomeni NE in oznako odstrani.

---

## B. S popusti (artikli)

### B1. Cenik Vid Adria je zapisan v IQLighting, ne v Vidadria — [ODLOČITEV] VISOKO
- Cenik: 2163 različnih šifer, 1012 s S kodo.

  | Podjetje | Šifer iz cenika v PIM | s S | objavljenih s S | S v PIM zdaj |
  |---|---|---|---|---|
  | 2 IQLighting | 799 | 239 | 190 | **190 (zapisal test F11)** |
  | 3 Vidadria | 2137 | 1003 | 993 | **0** |
  | 4 Ediito | 279 | 74 | 2 | 0 |

- 9 šifer s S iz cenika ni v PIM nikjer (npr. `TG.01001`–`TG.01008`, `LB.38.0791.30`, `LB.38.0820.30`).
- Test `PIM.F11.SPopustiTests` ima podjetje zapečeno (`const int Organization = 2`) in privzeto povezavo
  `DAVID\MSSQL19`.
- **Odločiti:** v katero podjetje (ali oba) gre cenik. Uvoz za Vidadria = isti delovni list izdelkov, izbrano podjetje 3.
  S se zapiše samo **objavljenim** artiklom (pim.Product) — 49 neobjavljenih v IQLighting ga ne dobi (opozorilo je).

### B2. Nasprotujoča S koda med listi cenika — [POTRJENO] SREDNJE
- `VD.VTCU02`, `VD.VTCU03`, `VD.VTCU05`: list elektro_material **S2**, list ViD_Tech **S3**.
- Uvoz vzame prvo (S2) z opozorilom »je v zvezku večkrat; upoštevana bo prva« — ne pove, da se **vrednost razlikuje**.
- **Popravek:** ločeno opozorilo za dvojnike z različno vrednostjo; **odločiti**, katera velja (verjetno ViD_Tech).
- Ostalih 67 dvojnikov je enakih (samo šum v opozorilih: 846 opozoril pri enem uvozu).

### B3. »Akcija in S se izključujeta« (§4.8) ni izvedeno — [POTRJENO] [ODLOČITEV]
- Artikel v odprodaji (30 %) ima v katalog.csv še vedno `Skupina popusta = S2`, `S popust % = 5`.
- V `out.GetExportRows` ni nobene logike za akcijo. **Odločiti:** ali je odprodaja »akcija« in ali pravilo izvaja PIM
  (prazna S koda pri artiklu v odprodaji) ali Magento.

### B4. S koda brez PAK2 / VPAK ≠ PAK2 — [POTRJENO] [ODLOČITEV]
- S koda pri artiklu s praznim ali 0 PAK2: **16** (IQLighting), **17** (Vidadria). Po §4.4 je tier cena pri
  količini ≥ PAK2 — pri PAK2 = 0 bi S veljal za vsako količino. Izvoz tega ne varuje (uvoz opozori).
- VPAK iz cenika ≠ PAK2 v SAOP: **216** (IQLighting), **248** (Vidadria), npr. `BA.BA23.70780` VPAK 100 / PAK2 1,
  `BA.BA24.00550` VPAK 100 / PAK2 10. Uvoz VPAK namenoma ne zapiše (PAK2 je last SAOP).
- **Popravek/odločitev:** izvoz naj ne pošlje S, kadar PAK2 ≤ 0; odločiti, ali se PAK2 v SAOP popravi po ceniku.

### B5. »Skupina popusta« pomeni dve različni stvari — [KODA] SREDNJE
- V ceniku in katalog.csv (`COL035`) = **S koda**.
- V intranetu (`ProductFieldLabels.cs:24,100`, `ProductCard.razor:957,1005`, `ProductExportService.cs:133` — izvoz
  »pregled«) = **rabatna skupina ERP** (`Product.DiscountGroup`, npr. BRAYTRON).
- Posledica: uporabnik zamenja podatka; izvoz »pregled« z /izdelki naložen v delovni list da pri vsaki vrstici
  »neznana S koda« (uvoz naslov »Skupina popusta« prebere kot S — `ProductWorkbookContract.cs:241`).
- **Popravek:** v intranetu preimenuj `Product.DiscountGroup` v »Rabatna skupina«.

### B6. Rabatna skupina z različnim zapisom velikih/malih črk — [POTRJENO] SREDNJE (podatki)
- IQLighting: `NOWODVORSKI` 5131 / `Nowodvorski` 111, `DAYLIGHT` 102 / `Daylight` 22, `TRIO` 902 / `Trio` 5,
  `BRAYTRON` 402 / `Braytron` 4, `OSTALO R2` 157 / `Ostalo R2` 4, `DURALAMP` 1967 / `Duralamp` 1.
- V katalog.csv gre kot dve različni vrednosti → Magento katalog pravila po skupini artiklov (§4.3) se razcepijo.
- **Popravek:** popraviti v SAOP ali normalizirati (`UPPER`) v izvozu stolpcev »Rabatna skupina …«.

### B7. Manjkajoči stolpec iz §3 — [KODA] NIZKO
- `Cena B2B (PAK2 popust)` (predračunana tier cena) ni v profilu 15. PDF pravi, da je neobvezna (sicer izračun iz S %).

---

## C. Okolje, orodja

### C1. Ročni izvoz z `--output-dir` zapiše objavo na splet — [POTRJENO] SREDNJE
- `workers/PIM.B2bWorker/Program.cs:106` kliče `ExecuteAsync(..., publishToMagento: true)` vedno, tudi z
  `--output-dir`. Komentar v `MagentoExportCommand.cs:37` trdi obratno.
- Na SONJA je poskusni izvoz v začasno mapo zapisal `out.WebPublication` (IQLighting: 2176 objavljenih, **179 novih
  odjav**). Pri podjetju z vklopljenim samodejnim umikom bi tudi **umaknil kljukice** (zdaj povsod izklopljen).
- **Popravek:** `publishToMagento: outputDirOverride is null`.

### C2. `appsettings.Local.json` v korenu repozitorija je v Gitu — [POTRJENO] SREDNJE
- Ima prednost pred `PIM_Solution/appsettings.Local.json` (LocalSettings, vir 2a). Ob vsakem merge se strežnik
  preklopi (`DAVID\MSSQL19` ↔ `SONJA`); obnova `a2f8cde` ga je vrnila na `DAVID\MSSQL19` — lokalno spet popravljeno
  na SONJA (ni commitano). Opomba v datoteki sama pravi »Ni v Gitu (.gitignore)«.
- **Popravek:** `git rm --cached appsettings.Local.json` + vpis v `.gitignore` (dogovor z Davidom).

### C3. Pet že uveljavljenih migracij ima spremenjeno vsebino — [POTRJENO] preveriti
- `187_ReservationExclusionAlerts`, `188_ReservationExclusionAlertsCritical`, `189_SystemIntegrationsAlertOrganization`,
  `190_ReservationFlagIgnoresArchived` (commit `ce6e1c1`, 2026-09-10), `200_CustomerGeneralManualOverride`
  (`009418d`, 2026-09-14). Runner jih preskoči → morebitni popravki v njih na SONJA niso.
- **Naslednji korak:** primerjati z definicijami na SONJA; če je sprememba vsebinska, jo prenesti v novo migracijo.

### C4. Opozorilo o kontrolni vsoti katalog.csv v testu F7 — NIZKO
- »kontrolne vsote izvoza ni bilo mogoče prebrati … being used by another process« — v testu datoteko hkrati bere
  test; izvoz se kljub temu zabeleži (po zasnovi). Najverjetneje artefakt testa.

---

## D. Delovni list izdelkov — krog izvoz → uvoz (`PIM.F10.ProductWorkbookTests`)

Test: izvozi list, ga brez urejanja uvozi nazaj → pričakovano 0 sprememb. **Dejansko 7 vrstic s »spremembo« — FAIL.**

### D1. Tabulatorji v besedilih povzročijo navidezno spremembo — [POTRJENO] SREDNJE
- `KL.213EW92740GO00`, `ProductText.SEARCH_NAME.sl` = `Dea Amata M⇥927⇥1140lm⇥90⇥2700K⇥12.5W` (v bazi so znaki TAB 0x09,
  podjetji 1 in 2). Po krogu skozi Excel pride nazaj s presledki → uvoz to prikaže kot spremembo in bi jo zapisal
  (pri ERP polju tudi uvrstil v vrsto za SAOP), čeprav uporabnik ni ničesar spremenil.
- **Popravek:** pri primerjavi (`Changed`/`SameValue` v `ProductWorkbookService`) obravnavaj vse bele znake kot enake;
  dolgoročno počisti kontrolne znake že ob zajemu iz vira.

### D2. Večvrednostni atributi, ki se razlikujejo samo po velikih/malih črkah — [POTRJENO] SREDNJE
- Npr. `Prevladujoča barva` = `Satine Chocolate | Satine chocolate` (3×), `Dopolnilna barva I` = `Satine Gold | Satine gold`,
  `Slog` = `Art Deco | Art deco`. Izvoz zapiše obe vrednosti, uvoz ju prebere kot drugačen seznam → navidezna sprememba;
  ob uvozu bi ena vrednost izginila.
- **Popravek:** primerjava seznamov neobčutljiva na velikost črk + enkratno čiščenje podvojenih vrednosti v bazi.

### D3. Posledica D1/D2 in počasnost testa — [POTRJENO]
- Tudi »ena spremenjena celica da eno spremembo« pade (vrstic 8 = 1 prava + 7 navideznih iz D1/D2) in
  »sprememba nosi kodo spletnega naziva«. Po popravku D1/D2 bi morala oba preiti.
- Test je po 15 min presegel časovno omejitev (del z bazo na SONJA ponavlja `intranet.GetProductList`).

## E. Izvoz izdelkov v Excel (/izdelki, predloga »pregled«)

### E1. Rumene glave (zahtevana polja) in rdeče celice (manjkajoče) se ne pokažejo nikoli — [POTRJENO] SREDNJE
- `PIM.F7.ProductExportTests` pade: »Vsaj eno polje mora biti označeno kot pogoj za validacijo (rumena glava)«.
- **Kje:** `intranet.GetProductExportSheet` (migracija 127), 2. rezultat: `INNER JOIN out.ExportProfile ON
  exportProfile.ExportProfileId = validationProfile.ExportProfileId`.
- **Zakaj:** vseh 7 aktivnih validacijskih profilov (`COMMERCIAL_L2`, `ERP_L1_*`, `SHARED_CORE`, `WEB_svetila_si`,
  `WEB_videlektro`) ima `ExportProfileId = NULL`; profili zdaj sami nosijo `BlocksErp`/`BlocksWeb`. JOIN izloči vseh
  622 zahtev → v zvezku ni nobene rumene glave in nobene rdeče celice; legenda obstaja, barv pa ne.
- **Popravek (nova migracija):** brez JOIN na `out.ExportProfile`;
  `BlocksErp = MAX(CONVERT(int, validationProfile.BlocksErp))`, `BlocksWeb = MAX(CONVERT(int, validationProfile.BlocksWeb))`.
  Pozor: profil `COMMERCIAL_L2` ima oba 0 → v kodi pade v vejo »validacija« (pravilno).

### E2. Spletni izvoz — PASS
- `PIM.F7.WebExportTests`: register, izdelki in stranke iz tabel — PASS.

## Še odprto
- Intranet: /izdelki/odprodaja, kartica izdelka (S popust, odprodaja), /izdelki filtri S — potrebna prijava.

---

## Popravki (2026-09-24, migracija 276 + koda, SONJA uveljavljeno)

| Točka | Popravek | Preverjeno |
|---|---|---|
| A1 | `pim.SaveClearanceItems`: cilj MERGE omejen na artikle podjetja | ROLLBACK test: uvoz v 2 ne zaključi več odprodaje v 3 |
| A2 | Proc: prva vrstica šifre; predogled: opozorilo »šifra je v datoteki večkrat« | ROLLBACK test: brez UNIQUE napake, ostane prva vrstica |
| A3 | `ClearanceService.ParseDecimal`: `NumberStyles.Float`, nato `sl-SI` (kot 35bea94) | build |
| A4 | Proc zavrne popust izven 0–100 z berljivim sporočilom; predogled opozori | ROLLBACK test (pozor: `%` v THROW sporočilu ga izprazni) |
| A5 | Predogled pove, koliko aktivnih odprodaj vira bo uvoz zaključil (`intranet.GetClearanceItemsToEnd`) | ROLLBACK test |
| B2 | Delovni list: dvojnik z drugačnimi vrednostmi dobi posebno opozorilo (npr. S2 -> S3) | build |
| C1 | **Ne** kot predlagano (produkcijska opravila podajajo `--output-dir` v pravo mapo Magento): nova zastavica `--brez-objave` | build |
| D1 | Primerjava delovnega lista: TAB = presledek | test v teku |
| D2 | `intranet.GetProductWorkbook`: STRING_AGG z binarnim drugim ključem (vrstni red en/sl ni več naključen) | test v teku |
| E1 | `GetProductExportSheet` in `GetProductWorkbook` (6. rezultat): kanal iz validacijskega profila, samo splošne zahteve | ROLLBACK test: 21 zahtevanih polj (prej 0) |

Odprto (odločitve): B1, B3, B4, A6, B6, C2, C3; D2b — atribut z vrednostmi v več jezikih je v delovnem listu en stolpec
(»Satine Chocolate | Satine chocolate«); če uporabnik celico spremeni, se ne ve, v kateri jezik gre.

### D4. Uvoz delovnega lista ne najde artikla, če se šifra razlikuje po velikih črkah — [POTRJENO] VISOKO → popravljeno
- `J4.8v2WWR90.5` v ceniku, `J4.8V2WWR90.5` v bazi → »artikla v podjetju Vidadria ni« (44 artiklov cenika).
- **Kje:** `ProductWorkbookService.OnlyChangedAsync` in `ApplyAsync`: `ResolveProductIdsAsync` vrne slovar brez
  razlikovanja črk, klicatelj pa ga je prepisal v `Dictionary<(int, string)>` s ključem iz BAZE in iskal s šifro iz DATOTEKE.
- **Popravek:** ključ je šifra iz datoteke, poiskana v neobčutljivem slovarju. Po popravku predogled najde vseh 2137.

## Odločitve uporabnika 2026-09-24
- Cenik (vsi trije listi) gre v **Vidadria (3)** — ujemanje: 2137 od 2163 šifer (IQLighting 799, Ediito 279).
- Vsi artikli cenika dobijo kljukico **Videlektro**; kdor je že na svetila.si, jo obdrži.
- Test samo na SONJA.

## F. Ugotovitve iz testiranja v aplikaciji (2026-09-24)

### F1. Izvoz celega pogleda (106 MB) ni mogoče uvoziti nazaj — omejitev 16 MB — [POTRJENO] SREDNJE
- `/izdelki` → »Izvozi Excel (cel pogled)« za vsa podjetja da 106 MB; `ProductImport.razor:171` dovoli 16 MB
  (enako `ClearanceImport.razor:269`, `CustomerImport.razor:149`).
- Krog izvoz → uvoz deluje samo za zožen pogled (podjetje + kategorija/filter). Odločiti: dvigniti mejo
  (in `MaximumReceiveMessageSize`/stream limit) ali izvoz sam razdeli po podjetjih/kategorijah.

### F2. Na /izdelki ni filtra po spletni trgovini (svetila / videlektro) — [KODA] NIZKO
- »Zastavica za splet« je SAOP WebPublish, »Pripravljenost za splet« je validacija — kljukice spletne trgovine
  (`pim.ProductWebShop`) ni mogoče filtrirati. Po uvozu Videlektro (164 artiklov) jih v seznamu ni mogoče najti.

### F3. Artikel v odprodaji ima še vedno S popust (glej B3) — [POTRJENO]
- `TG.03105` (Vidadria): ročna odprodaja 3 %, hkrati privzeti S2 (5 %).

## G. Predlog kategorij Videlektro (za potrditev — David)

Datoteka `docs/S_popusti/Predlog_kategorij_Videlektro.xlsx` (tudi v Prenosih). Vir: poglavja PDF cenikov Vid Adria
2026 (Elektro, Razsvetljava, ViD_Tech) + ključne besede naziva artikla (naziv ima prednost, kadar PDF zamakne naslov).

| Zanesljivost | Artiklov |
|---|---|
| visoka (poglavje ali poglavje + naziv se jasno ujema) | 1219 |
| srednja (po smislu, iz naziva, ali naziv ≠ poglavje — razlog v stolpcu) | 739 |
| že ima kategorijo Videlektro | 170 |
| nizka / ROČNO | 9 |
| artikla ni v Vidadria | 26 |

- Stolpec »Kategorije — Videlektro« je tak, da ga uvoz delovnega lista prebere neposredno (predogled na SONJA:
  1962 sprememb `ProductCategory.B2C`, brez napak). V bazo še NI zapisano.
- Znane slabosti: števci (10.1) nimajo svoje kategorije; grla za žarnice (6.6) in pohištvena svetila (1.6) sta ugibanje;
  stikala Carmen so vsa »Klasični program«.
- Po uvozu kategorij je treba kljukico Videlektro postaviti znova; slike (1650) in spletni nazivi (249) ostanejo ovira.

## H. Davidov test: artikel na splet + S → katalog.csv (SONJA, 2026-09-24) — USPEŠNO

Artikel `BA.BC17.00700` (IQLighting, PAK2 32), trije izvozi katalog.csv (`--brez-objave`):

| Stanje | Spletne strani | Skupina popusta | S popust % |
|---|---|---|---|
| prej (na spletu, brez S) | svetila | – | – |
| umaknjen s spleta | *(prazno — odjavna vrstica)* | – | – |
| vrnjen na splet + S2 | svetila | S2 | 5 |

### H1. katalog.csv se izvaža samo za IQLighting — [POTRJENO] [ODLOČITEV] VISOKO
- `ops.ScheduleProfile` `MAGENTO_PRODUCTS`: omogočen samo za podjetje 2 (IQLighting); 1, 3, 4 izklopljeni (migracija 213).
  Ročni izvoz za Vidadria: »razpored MAGENTO_PRODUCTS za podjetje ni omogočen; datoteka ni nastala«.
- Posledica: S kode (993) in kljukice Videlektro, zapisane v **Vidadria**, danes **ne pridejo v katalog.csv**.
  Na splet gre samo, kar je v IQLighting (tam je 799 šifer cenika, S ima 190).
- **Odločiti:** ali se cenik/Videlektro uvozi tudi v IQLighting, ali se omogoči izvoz Magento za Vidadria.

### H2. Kljukice Videlektro po uvozu kategorij (SONJA)
- Kategorije iz predloga zapisane pri 1962 artiklih Vidadria (brez napak). Na Videlektro zdaj **419** artiklov (prej 164).
- Še zavrnjenih 1718: brez slike 1650, brez spletnega naziva 249, brez EAN 63, neaktiven v ERP 40, brez ABC 32.
