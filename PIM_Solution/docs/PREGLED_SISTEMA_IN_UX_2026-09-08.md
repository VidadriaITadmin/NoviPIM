# NoviPIM — pregled sistema, baze in uporabniške izkušnje

Datum: 2026-09-08. Avtorja: Codex (prvi del, do ustavitve ob omejitvi) in Claude Code (nadaljevanje
in zaključek po uporabnikovem naročilu »nadaljuj in dokončaj«). Stanje: **KONČANO — samo pregled,
brez popravkov kode in brez posegov v poslovne podatke.**

Naročilo (TASKBOARD, DELAM): *en dokument z dokazi napak, natančnimi rešitvami in izboljšavami UX po
straneh; brez implementacije popravkov.* Ta dokument nadomešča delni
`PREGLED_SISTEMA_IN_UX_2026-09-08_DELNO.md`; njegove ugotovitve so vključene tukaj.

---

## 0. Povzetek v petnajstih vrsticah

| # | Resnost | Ugotovitev | Dokaz |
|---|---|---|---|
| A1 | **kritično** | Bralna vloga `VIEWER` na kartici izdelka dobi 14 urejivih polj in gumb »Shrani spremembe«; strežniška pot zapisa vloge ne preveri. | `VIEWER_FORM {"webEditable":14,"saveButtonPresent":true}`, posnetek `viewer-web-fields.png`, koda §2.1 |
| A2 | **kritično** | `/saop/zgodovina` brez parametra v naslovu pade s HTTP 500 (`Internal Server Error`). S parametrom `?stanje=…` dela. | `ui-results.json` → `saop-history`, `ui-focused-results.json` → `saop-history-plain` / `saop-history-filtered` |
| A3 | visoko | Onemogočen račun (`IsEnabled=0`) ostane prijavljen; piškotek se ne preverja znova. Prijava nima omejitve poskusov. | `DISABLED_ACCOUNT_COOKIE {"Status":200,"Path":"/izdelki"}`, koda §2.3 |
| A4 | visoko | Gumba »Potrdi« in »Reši« na `/preverbe` nista vezana na vlogo; stran je odprta vsem prijavljenim. | koda §2.4 (v brskalniku ni bilo alarmov za klik) |
| A5 | visoko | Zavrnjen dostop (403) vodi na prijavni obrazec, splošna napaka pa na angleško predlogo »Error.« | `Program.cs` vrstica 22, `Error.razor` |
| D1 | **kritično (podatki)** | `Product.VatRateId` je prazen pri **177.654 od 177.655** aktivnih izdelkov, ker ga noben vir ne polni; profil `ERP_SLO` zato blokira 100 % kataloga. | SQL §3.1 |
| D2 | visoko (podatki) | Spletna profila (`WEB_svetila_si`, `WEB_videlektro`) validirata tudi izdelke, ki niso za splet: 162.669 izdelkov z `WebPublish=0` nosi 882.033 spletnih napak. | SQL §3.2 |
| D3 | visoko (podatki) | 171.586 aktivnih izdelkov nima nobene kategorije; to je največji posamični vir napak (514.914). | SQL §3.3 |
| D4 | srednje (podatki) | Dobaviteljeva zaloga se podvaja v vsa štiri podjetja; pozicij »brez artikla« je 3.022 od 4.167 (DEMO) in 3.982 od 7.264 (Ediito). | SQL §3.4 |
| D5 | srednje (podatki) | Testni zapisi v produkcijskem katalogu (`ItemID` `0`, `0000000000001` trikrat, »TESTNA STORITEV z nazivom ena1«). | posnetek `products.png`, SQL §3.5 |
| U1 | visoko (UX) | Obseg podjetja ni enoten: `/kakovost` sešteva vsa podjetja, `/kakovost/napake` in `/mediji` privzeto samo prvo; `/izdelki` piše »v aktivni organizaciji«, čeprav kaže vsa. | posnetka `quality.png`, `validation-errors.png`, koda §4 |
| U2 | visoko (UX) | Pri širini 800 px je iskalno polje na `/izdelki` visoko 22 rem (prazen blok čez pol zaslona), odjava izgine pod 900 px, meni ni dosegljiv s tipkovnico. | `products-800.png`, `Products.razor.css:11`, `MainLayout.razor.css:70` |
| U3 | srednje (UX) | Devet strani nosi opozorilo »bralni model še ni nameščen« (`<PimMissing>`); `/nastavitve/atributi/{koda}` je brez vsebine. | `attribute-detail.png`, §4 |
| P1 | srednje (hitrost) | `/zajem` 21,7 s, `/zajem/viri/BT_XML` 19,3 s, `/nadzorna-plosca` 11,7 s, `/kakovost` 10,4 s. | `ui-results.json`, §5 |
| O1 | srednje (nadzor) | Opozorila se ne združujejo: en mrtev odhodni zapis šteje 738 »pojavov«, isti naslov »Posnetek zaloge je zastarel« je štirikrat, 616 opozoril `RESERVATION_EXCLUSION` ni vidnih na plošči. | SQL §3.6, `dashboard.png` |

Prednostni načrt je v §8. Kaj **ni** bilo preverjeno, je v §9.

---

## 1. Obseg, metoda in dokazi

### 1.1 Kaj je bilo narejeno

- Veja `feature/pravila-nazivi-atributni-izbirnik`, delovna kopija z necommitanimi spremembami
  (ni zamrznjena izdaja). Koda aplikacije in migracije **niso bile spremenjene**. Edina sprememba
  v repozitoriju je ta dokument, pomožna skripta pregleda in vnos v `TASKBOARD.md`.
- **Codex** (prvi del): produktni model, inventar poti, servisov, migracij, workerjev in testov;
  branje zagona, prijave, lupine, nadzorne plošče, seznama in kartice izdelka, uvoza Excel ter
  dejanskih definicij `pim.SaveProductTexts` in `pim.SaveProductAttributes` iz razvojne baze;
  metapodatkovni pregled baze (`DB_NAME()=PIM`, SQL Server 15.0.2180.2, compat 150, SIMPLE).
- **Codex** (drugi del, po odobritvi nadaljevanja): skripta
  [`pregled-20260908/Inspect-Ui.ps1`](pregled-20260908/Inspect-Ui.ps1), ki ustvari začasnega
  lokalnega uporabnika `qa_review_<guid>` z vlogo `VIEWER`, se prijavi prek `/auth/prijava`,
  vodi Chrome brez glave prek DevTools protokola, izmeri **55 strani** (čas nalaganja, naslov,
  število vrstic, urejiva polja, vidne napake, vidnost odjave), posname 17 zaslonov pri 1440 px in
  seznam izdelkov pri 800 px, nato uporabniku doda vlogo `ADMIN` in ponovi. Ob koncu uporabnika
  in njegove vrstice pobriše (`QA_ACCOUNT_CLEANUP_COMPLETE`). Rezultat:
  [`pregled-20260908/ui-results.json`](pregled-20260908/ui-results.json).
- **Claude Code** (zaključek): ponovni zagon skripte s stikalom `-Focused` (dokaz A1, A3, A4,
  padec A2, podrobnost atributa in vira), pregled vseh 26 posnetkov, potrditev vzrokov v kodi in
  bralne poizvedbe nad razvojno bazo `PIM` (samo `SELECT`; poizvedbe so v §3), ta dokument.

### 1.2 Kaj je bilo pognano in kaj je vrnilo

| Ukaz | Izid |
|---|---|
| `powershell.exe -NoProfile -File docs/pregled-20260908/Inspect-Ui.ps1` (Codex, 21:20–21:23) | 55 strani naloženih, `ui-results.json`, 17 posnetkov |
| `… Inspect-Ui.ps1 -Focused` (Codex 21:27, Claude ponovno ob zaključku) | `VIEWER_FORM {"webEditable":14,"saveButtonPresent":true}`; `DISABLED_ACCOUNT_COOKIE {"Status":200,"Path":"/izdelki"}`; `VIEWER_CHECK_ACTIONS []`; `saop-history-plain` → naslov `Internal Server Error`; `QA_ACCOUNT_CLEANUP_COMPLETE` |
| `sqlcmd -S … -d PIM -E -C -I -Q "SELECT …"` (bralne poizvedbe §3) | vse vrnile podatke; nobena ni spreminjala stanja |
| `Get-Process PIM.Intranet` | PID 14872, zagnan 21:17 (razvojno okolje, `ASPNETCORE_ENVIRONMENT=Development`) |
| `scripts\run_tests.ps1`, `dotnet build`, migrator `--verify` | **niso bili pognani** v tem pregledu; oznake PASS iz prejšnjih poročil za današnjo različico ne prevzemam |

### 1.3 Pravila, ki so veljala

`AGENTS.md` (koren repozitorija): brez brisanja, brez pisanja v produkcijo, brez živih klicev SAOP,
brez `git push`. Testni račun je skripta ustvarila in pobrisala sama (izjema §4.1). Dokumentacija
ni bila vzeta kot dokaz delovanja.

---

## 2. Napake v aplikaciji (z dokazom in natančnim popravkom)

Vsaka napaka ima: **kje**, **dokaz**, **vzrok v kodi**, **popravek**, **kako dokazati popravek**.

### 2.1 A1 — bralna vloga lahko ureja in shranjuje kartico izdelka

**Kje.** `/izdelki/{id}`, zavihek »Splet« (in ostali zavihki s polji).

**Dokaz.** Skripta se je prijavila kot `VIEWER` (edina vloga), odprla `/izdelki/3`, kliknila
`#tab-web` in preštela: `webEditable: 14`, `saveButtonPresent: true`. Posnetek
`viewer-web-fields.png` kaže prazna obvezna polja »Spletni naziv (sl)« in »(en)« kot urejiva ter
gumb »Shrani spremembe« zgoraj desno. Dejanski zapis z računom `VIEWER` **ni bil izveden**
(pregled ne sme spreminjati poslovnih podatkov); pot je preverjena po kodi in po definicijah
procedur v bazi.

**Vzrok.**
- [`ProductCard.razor:3`](../src/PIM.Intranet/Components/Pages/ProductCard.razor) ima samo
  `[Authorize]`. Urejivost polj se določa po vrsti polja, ne po vlogi.
- `SaveChangesAsync` (vrstica 833) kliče `Edits.SaveTextsAsync` (848) in `Edits.SaveAttributesAsync`
  (856); [`ProductEditService.cs`](../src/PIM.Intranet/Services/ProductEditService.cs) vloge ne
  preverja, `@Actor` (vrstica 65) je samo revizijski podatek.
- `pim.SaveProductTexts` in `pim.SaveProductAttributes` (prebrani z `OBJECT_DEFINITION`) preverita
  pripadnost izdelka podjetju in lastništvo polja, **ne** vloge izvajalca.
- Enak vzorec: `/preverbe` (§2.4), `/izdelki/uvoz` je omejen na `ADMIN,CATALOG_EDITOR,COMMERCIAL`
  (v redu), `/saop/*` na `ADMIN,CATALOG_EDITOR` (v redu).

**Popravek (INTRANET, en commit).**
1. Uvesti eno avtorizacijsko politiko za zapis, npr. `PimPolicies.CatalogWrite =
   RequireRole(ADMIN, CATALOG_EDITOR)`, registrirano v `Program.cs` ob `AddAuthorization`.
2. `ProductEditService` (in `SaopWriteService`, `IntranetDataService.AcknowledgeAlertAsync`,
   `ResolveAlertAsync`) dobijo `IAuthorizationService`/`ClaimsPrincipal` in vsak zapis začnejo z
   `if (!user.IsInRole(...)) throw new UnauthorizedAccessException(...)`. Preverjanje je na
   **strežniški** meji, ne v komponenti.
3. Kartica: `CanEdit = user.IsInRole(ADMIN) || user.IsInRole(CATALOG_EDITOR)`; brez tega so polja
   `readonly`, gumb »Shrani spremembe« se ne izriše, namesto njega značka »Samo za branje«.
4. Zvonec: `NavMenu` že filtrira po vlogah (`PimNavigation.For(roles)`); dodatno naj bralna vloga
   ne vidi povezav na `/saop`, `/stranke`, ki ji vrnejo 403 (glej §2.5).

**Dokaz popravka.** RED/GREEN v `PIM.F10.AuthTests`: (a) `ProductEditService.SaveTextsAsync` z
uporabnikom brez vloge vrže `UnauthorizedAccessException` in v `pim.ProductFieldHistory` ni nove
vrstice; (b) z `CATALOG_EDITOR` uspe; (c) UX test: HTML kartice za `VIEWER` ne vsebuje
`Shrani spremembe`. Nato `scripts\run_tests.ps1 -Filter F10` = 0 padlih.

### 2.2 A2 — `/saop/zgodovina` pade s HTTP 500

**Dokaz.** `ui-results.json` → `saop-history`: `title: "Internal Server Error"`,
`heading: "An unhandled exception occurred while processing the request."`, `logoutVisible: false`.
Isti naslov z `?stanje=PendingApproval` se naloži (`saop-history-filtered`, 14 vrstic).

**Vzrok.** [`SaopHistory.razor:51`](../src/PIM.Intranet/Components/Pages/SaopHistory.razor):
`[SupplyParameterFromQuery(Name = "stanje")] public string Status { get; set; } = "";`. Ko
parametra v naslovu ni, Blazor lastnost nastavi na `null` (privzeta vrednost se ne obdrži), izraz
`Filtered` v vrstici 60 pa bere `Status.Length` → `NullReferenceException` med predupodabljanjem →
500. To je edina stran s tem vzorcem (`grep SupplyParameterFromQuery … | grep -v 'string?'`).

**Popravek.** `public string? Status { get; set; }` in v filtru
`string.IsNullOrEmpty(Status) || row.Status == Status`. Enako pri `@bind="Status"` v izbirniku
(`Status ?? ""`).

**Dokaz popravka.** UX test v `PIM.F10.*UxTests`: GET `/saop/zgodovina` brez poizvedbe vrne 200 in
vsebuje `Zgodovina zapisov v SAOP`. Ročno: `Inspect-Ui.ps1 -Focused` → `saop-history-plain`
naslov ni več `Internal Server Error`.

### 2.3 A3 — onemogočen račun ostane prijavljen; prijava brez omejitve poskusov

**Dokaz.** Skripta je po prijavi nastavila `sec.LocalUser.IsEnabled=0` za svoj račun in z istim
piškotkom zahtevala `/izdelki`: `Status 200`, pot `/izdelki` (ni preusmeritve na prijavo).

**Vzrok.** [`Program.cs:18-23`](../src/PIM.Intranet/Program.cs): `AddCookie` brez
`Events.OnValidatePrincipal`; `IsEnabled` in vloge se preberejo samo ob prijavi
(`LocalUserAuthenticationService.cs:18-24`). Piškotek brez »zapomni me« ima privzeti drseči rok
14 dni. V `PIM.Intranet` ni nobenega zaklepanja po neuspelih poskusih (`grep -ri
'Lockout|RateLimit|FailedAttempts'` → nič).

**Popravek (BAZA + INTRANET).**
1. Migracija: `sec.LocalUser.SecurityStamp uniqueidentifier NOT NULL DEFAULT NEWID()`; procedure, ki
   spreminjajo `IsEnabled`, vloge ali geslo, žig obnovijo.
2. Ob prijavi žig v claim; `OnValidatePrincipal` vsakih 5 min (ali ob vsaki zahtevi, ker je
   poizvedba po ključu) primerja žig in `IsEnabled`; ob neujemanju `RejectPrincipal()` +
   `SignOutAsync`.
3. `AddRateLimiter` na `/auth/prijava`: npr. 10 poskusov / 15 min na uporabniško ime + IP; po
   preseganju 429 s slovenskim sporočilom; poskusi v `ops.UserActivity`.

**Dokaz popravka.** `PIM.F10.AuthTests`: prijava → `IsEnabled=0` → naslednja zahteva
preusmeri na `/prijava`; 11. napačna prijava vrne 429.

### 2.4 A4 — potrjevanje in reševanje alarmov brez vloge

**Kje.** `/preverbe`, tabela »Odprti alarmi poslovnih preverb«.

**Dokaz.** [`Checks.razor:2`](../src/PIM.Intranet/Components/Pages/Checks.razor) `[Authorize]`
(vsi prijavljeni); vrstici 112–113 izrišeta gumba »Potrdi« in »Reši« brez pogoja;
`AcknowledgeAsync` (267) in `ResolveAsync` (276) kličeta servis brez preverjanja vloge. Pri
zagonu z `VIEWER` je bil seznam alarmov prazen (`VIEWER_CHECK_ACTIONS []`), ker teh alarmov danes
nihče ne ustvarja (stran to sama pove s `<PimMissing>`), zato klik ni bil mogoč. Prag
(`CanEditThreshold`, vrstica 138) je edini del strani, ki je vezan na vlogo.

**Popravek.** Isti mehanizem kot §2.1: gumba samo za `ADMIN,COMMERCIAL`, servis zavrne ostale.

### 2.5 A5 — zavrnjen dostop vodi na prijavo; stran napake je angleška predloga

**Dokaz.** `Program.cs:22` `options.AccessDeniedPath = "/prijava"`. Prijavljen `VIEWER`, ki klikne
»Izhod v SAOP« ali »Stranke« v meniju (meni jih kaže, `viewer-product.png`), pristane na prijavnem
obrazcu brez pojasnila. [`Error.razor`](../src/PIM.Intranet/Components/Pages/Error.razor) je
nespremenjena predloga (»Error.«, »Development Mode«, angleško); v razvojnem okolju se namesto nje
pokaže surova stran razvijalca (to smo videli pri A2).

**Popravek.** `AccessDeniedPath = "/brez-dostopa"` z lastno stranjo (kdo si, katera vloga manjka,
komu pisati); `Error.razor` v slovenščini z ID zahteve in povezavo nazaj; `NavMenu` skrije vnose,
katerih ciljna stran vloge ne dovoljuje (podatek je že v `sec.NavigationItemRole`: VIEWER 5 vnosov,
a stranska vrstica jih kaže več — preveriti `PimNavigation.For`).

### 2.6 A6 — ozka širina: iskalno polje, odjava, tipkovnica

**Dokaz.** `products-800.png`: kartica iskanja je visoka približno pol zaslona, lupa lebdi na
sredini praznine; `ui-results.json` → `products-800`: `logoutVisible: false`.

**Vzrok.**
- [`Products.razor.css:11`](../src/PIM.Intranet/Components/Pages/Products.razor.css)
  `.search-field { flex: 1 1 22rem; }` — pod 900 px `.toolbar-row` postane
  `flex-direction: column` (vrstica 222), zato `flex-basis: 22rem` postane **višina**.
- [`MainLayout.razor.css:70`](../src/PIM.Intranet/Components/Layout/MainLayout.razor.css)
  `.signed-user strong, .logout-button { display: none; }`.
- Preklop menija je `label` ob skritem `checkbox` s `tabindex=-1` (Codex, branje `MainLayout.razor`).

**Popravek.** V `@media (max-width: 900px)`: `.search-field { flex: 0 0 auto; }`; odjavo prenesti v
izvlečni meni (zadnji vnos »Odjava«) namesto skrivanja; preklop menija kot `<button
aria-expanded aria-controls>`.

### 2.7 A7 — `/pravila/nazivi`: napis se prekriva z vnosom

**Dokaz.** `title-rules.png`: besedilo »Pravilo je aktivno (neaktivno se v predog…« izgine pod
poljem »Opomba«. Vidno tudi pri 1440 px.

**Vzrok.** [`TitleRules.razor:219`](../src/PIM.Intranet/Components/Pages/TitleRules.razor)
`label.filter-check` z dolgim besedilom stoji v isti vrstici kot polje z `flex`, brez `flex-wrap`
in brez `min-width: 0`.

**Popravek.** Kratek napis »Pravilo je aktivno« + pomoč pod njim; vrstica `flex-wrap: wrap`;
polje »Opomba« v svojo vrstico.

### 2.8 A8 — zvonec in plošča: »vse teče« ob napaki, podvojena opozorila

**Dokaz in vzrok.** [`MainLayout.razor:51`](../src/PIM.Intranet/Components/Layout/MainLayout.razor)
`AlertTitle => Attention.Total == 0 ? "Vse teče: ni odprtih opozoril" : …`; vrstica 68 ob izjemi
nastavi `AttentionSummary.Empty` → naslov laže. `dashboard.png`: štirje ločeni vnosi »Posnetek
zaloge je zastarel — SAOP_STOCK · 1 pojavov« (eden na podjetje, brez imena podjetja) in
»Odhodno sporočilo je mrtvo — 735 pojavov« za **eno** sporočilo (`out.OutboxMessage`: org 1 ima
1 `Dead`, 14 `PendingApproval`; `ops.Alert.OccurrenceCount=738`, ker vsak tek watchdoga šteje
znova).

**Popravek.** Tretje stanje zvonca (»stanja ni bilo mogoče preveriti«); na plošči združevanje po
`AlertKind` s seznamom podjetij (`SAOP_STOCK · 4 podjetja`); `OccurrenceCount` naj šteje nove
dogodke, ne ponovnih pregledov (`DedupKey` + `LastSeenUtc`); 616 odprtih `RESERVATION_EXCLUSION`
(vsi org 1) naj imajo svojo vrstico ali svojo stran, danes jih plošča ne kaže.

### 2.9 A9 — drobne napake izrisa

| Kje | Kaj | Popravek |
|---|---|---|
| `/splet` | `<select>` »Spletno mesto« brez razreda (`Web.razor:13`), izgleda kot surov element | `class="filter-select"` v `label.field-control` |
| `/nastavitve/kategorije` | prazna kontrola med »Vsi nivoji« in kljukicami; vrstica filtrov odrezana desno (`categories.png`) | `flex-wrap`, odstraniti prazen element |
| `/izdelki`, `/zaloge`, `/kakovost/napake` | tabela teče čez desni rob (stolpci TEŽAVE/VRZ…, STANJE odrezani), brez znaka, da je še vsebina | `overflow-x: auto` na ovoju + senca na robu; ključne stolpce (šifra, stanje) »lepljive« |
| `/mediji` | sličice so bele (`media.png`), `onerror` samo doda v `Failed`, brez vidnega »slike ni mogoče naložiti« | nadomestna sličica z napisom vira; preveriti, ali so URL dosegljivi iz brskalnika |
| poti | `/system/integracije`, `/system/uporabniki` (angleško) poleg `/sistem/*`; `/napake-validacije` in `/kakovost/napake`; `/pravila-popustov` poleg `/pravila/*` | obdržati eno slovensko pot, staro preusmeriti |

---

## 3. Podatki in baza (bralne poizvedbe nad razvojno bazo `PIM`)

Vse spodaj je `SELECT` prek `sqlcmd -I`; ničesar ni bilo spremenjeno. Podjetja: 1 = DEMO,
2 = IQLighting, 3 = Vidadria, 4 = Ediito (po vrstnem redu in številkah na nadzorni plošči).

### 3.1 D1 — `Product.VatRateId` ne polni nihče

```sql
SELECT COUNT(*) FROM canon.Product WHERE VatRateId IS NULL AND IsActive=1;   -- 177654
SELECT c.SourceCode, m.EntityType, m.SourceElement, m.TargetFieldCode
FROM map.FieldMapping m JOIN map.SourceConnector c ON c.SourceConnectorId=m.SourceConnectorId
WHERE m.TargetFieldCode LIKE '%Vat%';
-- samo Prices → ProductPrice.VatRate in Customers → Customer.SubjectToVat; Product.VatRateId ni nikjer
```

`/kakovost` kaže `VatRateId` kot polje z **100 %** manjkajočih (177.653), »popravi se v ERP in
pride nazaj z zajemom« — a preslikave ni, zato ne more priti. Profil `ERP_SLO` zato pokaže **9,6 %
pripravljenih**, kar ni slika kataloga, ampak ene manjkajoče preslikave.

**Odločitev za uporabnika:** (a) dodati preslikavo SAOP → `Product.VatRateId` (`map.FieldMapping`,
entiteta `ItemGeneralData`, element, ki nosi davčno stopnjo artikla) in ponovno validacijo, ali
(b) zahtevo umakniti iz `ERP_SLO`, dokler vira ni. Do odločitve naj stran `/kakovost` tako polje
označi kot »brez vira — ne da se popraviti v PIM«.

### 3.2 D2 — spletna profila validirata tudi izdelke, ki niso za splet

```sql
SELECT vp.ProfileCode, p.WebPublish, COUNT(*) issues, COUNT(DISTINCT i.ProductId) products
FROM val.ProductIssue i
JOIN val.ValidationProfile vp ON vp.ValidationProfileId=i.ValidationProfileId
JOIN canon.Product p ON p.ProductId=i.ProductId
WHERE i.IsActive=1 AND i.ResolvedUtc IS NULL GROUP BY vp.ProfileCode, p.WebPublish;
```

| Profil | WebPublish | Odprtih napak | Izdelkov |
|---|---:|---:|---:|
| WEB_svetila_si | 0 | 882.033 | 162.669 |
| WEB_svetila_si | 1 | 87.968 | 15.040 |
| WEB_videlektro | 0 | 873.812 | 162.444 |
| WEB_videlektro | 1 | 40.863 | 12.084 |
| WEB_B2C (LEGACY) | 0 | 750.011 | 161.797 |

Za splet je označenih ~15.000 izdelkov (`WebPublish=1`: 2.933 + 2.753 + 9.463 + 0), spletnih napak
pa je 2,6 milijona, večinoma na izdelkih, ki na splet ne gredo. Nadzorna plošča zato piše
»Z napakami 172.231 — neveljavni za splet«, kar ni operativno uporabno.

**Popravek (DOMENA + BAZA):** validacijski tek za profile `Scope='WEB'` omeji na izdelke z
`WebPublish=1` (ali z dodeljeno spletno stranjo), stare vrstice za ostale zapre
(`ResolvedUtc`, razlog `OUT_OF_SCOPE`); `WEB_B2C` in `ERP_L1` sta označena `LEGACY`, a še vedno
aktivna in štejeta — izklopiti ali izbrisati po odločitvi. Pričakovani učinek: `val.ProductIssue`
se skrči za ~2,5 milijona vrstic, `/kakovost` postane seznam dela, ne statistika.

### 3.3 D3 — kategorije so največja blokada

```sql
SELECT COUNT(*) FROM canon.Product p WHERE p.IsActive=1
  AND NOT EXISTS (SELECT 1 FROM canon.ProductCategory c WHERE c.ProductId=p.ProductId);  -- 171586
SELECT TOP 12 i.IssueCode, r.FieldCode, COUNT(*) FROM val.ProductIssue i
LEFT JOIN val.FieldRequirement r ON r.FieldRequirementId=i.FieldRequirementId
WHERE i.IsActive=1 AND i.ResolvedUtc IS NULL GROUP BY i.IssueCode, r.FieldCode ORDER BY 3 DESC;
```

| Polje | Odprtih |
|---|---:|
| ProductCategory.CategoryPath | 514.914 |
| ProductMedia.Url | 512.223 |
| ProductText.WEB_TITLE.sl | 462.630 |
| ProductText.WEB_TITLE.en | 322.768 |
| ProductAttribute.Garancija | 260.904 |
| ProductCommercial.CustomsTariff | 234.564 |
| Product.EAN | 222.303 |
| Product.VatRateId | 177.653 |

Skupaj **3.496.828 odprtih napak** (org 1: 343.435; org 2: 2.082.650; org 3: 415.696;
org 4: 655.047). Vrh seznama so polja, ki se ne popravljajo po izdelku, ampak po **kategoriji,
preslikavi ali pravilu**: kategorije (`/kakovost/kategorije`, `/izdelki/kategorije`), spletni
nazivi (`/pravila/nazivi`), slike (dobaviteljev XML). Stran `/kakovost` to že ve (stolpec »Kje se
popravi«), a številke ostajajo na ravni izdelka.

**Popravek (UX):** na `/kakovost` ob vsakem polju gumb »Popravi skupinsko« z oceno, koliko
izdelkov reši ena preslikava (npr. »42 dobaviteljevih poti brez kategorije pokrije 131.000
izdelkov«); pri §3.2 zožen obseg številke sploh naredi berljive.

### 3.4 D4 — dobaviteljeva zaloga v vseh štirih podjetjih

```sql
SELECT s.OrganizationId, SUM(CASE WHEN p.MatchedProductId IS NULL THEN 1 ELSE 0 END) brezArtikla, COUNT(*) vse
FROM stock.Position p JOIN stock.Snapshot s ON s.SnapshotId=p.SnapshotId
WHERE s.IsActive=1 GROUP BY s.OrganizationId;
```

| Podjetje | Brez artikla | Vseh pozicij |
|---|---:|---:|
| 1 DEMO | 3.022 | 4.167 |
| 2 IQLighting | 1.447 | 12.893 |
| 3 Vidadria | 380 | 7.307 |
| 4 Ediito | 3.982 | 7.264 |

`stock.png` to kaže kot vrstico `BA.BA09.00510 — brez artikla` štirikrat zapored. Datoteka
Braytron/Nowodvorski se naloži za vsako podjetje, čeprav artikel obstaja samo pri enem.
Popravek: dobaviteljev vir zaloge veže na podjetja, ki dobavitelja dejansko imajo
(`stock.SaopProviderProfile` / register vira), ali pa neujete pozicije ostanejo samo v
`stock.UnmatchedPosition` in ne v tabeli `/zaloge`.

### 3.5 D5 — testni zapisi v katalogu

`products.png`, prvih šest vrstic: `0` (šifra `0`, IQLighting), `AVANS` `0000000000001` v treh
podjetjih, `TESTNA STORITEV z nazivom ena1` `00000000000000000003`. SQL: `ItemID='0'` → 1,
`'0000000000001'` → 3. Ti zapisi so prvi, ki jih uporabnik vidi ob odprtju seznama (razvrstitev
»Šifra naraščajoče«). Popravek: označiti testno podjetje/artikle (`IsTest` ali seznam izjem) in jih
privzeto skriti; DEMO kot podjetje ločiti od produkcijskih.

### 3.6 O1 — stanje integracij in opozoril (razvojno okolje)

```sql
SELECT OrganizationId,Pipeline,Status,LastHeartbeatUtc,LastSuccessfulRunUtc,ConsecutiveFailures FROM ops.IntegrationHealth;
```

- `SAOP_STOCK` Failed pri vseh štirih (60 zaporednih napak, zadnji uspeh 2026-09-03), `SAOP_PRODUCTS`
  Failed (2 napaki, zadnji uspeh 2026-09-03). `ops.ErrorLog` zadnjih 7 dni: 275 napak workerjev,
  od tega 260 »A connection attempt failed …« — SAOP iz tega računalnika ni dosegljiv. To je
  pričakovano v razvoju, a **stran `/sistem` zato našteje 25 vnosov »molči«** (`system.png`), ker
  urniki tečejo samo, ko jih uporabnik zažene. Opozorila v razvoju niso ločena od produkcije.
- `raw.Inbox`: 3 vrstice `Pending` za org 2 od **2026-07-30** (40 dni); `/zajem` jih kaže kot
  »Čaka 3 — najstarejša 30. 07. 2026«. Popravek: samodejni prenos v karanteno po N dneh.
- `ops.DeadLetterQueue`: 16 vrstic `raw/SAOP_IQLIGHTING` (ItemGeneralData 6, Descriptions 4,
  Currencies/PriceLists/Prices po 2).
- Dve zastoji (`deadlock`) v 7 dneh med validacijo in zajemom (`RUN_VALIDATION_FAILED`).
- Skladnost številk na plošči: »ERP veljavni 89.152« in »Objavljeni 89.153« (IQLighting 43.504 :
  43.505) — en objavljen izdelek ni ERP-veljaven; 115 izdelkov ima `WebPublish=1` in `IsActive=0`
  (org 2: 15, org 3: 100).

### 3.7 Obseg in hramba (iz Codexovega metapodatkovnega pregleda)

| Tabela | Vrstic | Opomba |
|---|---:|---|
| `map.ExtractedValue` | 20.252.420 | brez načrta hrambe |
| `val.ProductIssue` | 6.365.344 | 3,5 mio odprtih + zgodovina; po §3.2 se zmanjša |
| `stock.Position` | 2.581.157 | aktivnih posnetkov 3 na podjetje, ostalo zgodovina |
| `pim.ProductFieldHistory` | 2.485.681 | |
| `val.ProductValidationState` | 1.599.399 | |
| `dbo.SchemaMigration` | 191 | v `sql/migrations` so necommitane datoteke s številkami, ki so v bazi že zasedene z drugimi imeni (153, 154, 169) — ledger vodi po imenu datoteke, zato migrator dela, a ponovljivost namestitve ni dokazana |

Predlog: politika hrambe (npr. `ExtractedValue` 90 dni, rešene napake 180 dni, posnetki zaloge
30 dni) kot nočno opravilo z merjenjem; uskladitev številk migracij pred naslednjim merge-em.

---

## 4. Pregled po straneh

Oznake: **OK** deluje in je razumljivo; **UX** izboljšava; **NAPAKA** je v §2; **PRAZNO** stran
nosi `<PimMissing>` (bralni model manjka). Čas = nalaganje z `ADMIN` pri 1440 px (`ui-results.json`).
Vloge = `@attribute [Authorize]` (prazno = vsi prijavljeni).

### 4.1 Nadzor

| Pot | Vloge | Čas | Stanje | Ugotovitve in izboljšave |
|---|---|---:|---|---|
| `/nadzorna-plosca` | vsi | 11,7 s | UX, NAPAKA A8 | Dober prvi zaslon (štiri podjetja, profili, integracije). Počasi, ker `Dashboard.razor:135-157` za vsako podjetje zaporedno kliče 4 servise. Povezave »Podrobnosti« vodijo na `/system/integracije` (samo ADMIN) tudi za druge vloge. Kartica »Z napakami 172.231« je po §3.2 zavajajoča. Predlog: en nabor `intranet.GetDashboardAll`, 60 s predpomnilnik, kartice s »kaj naj naredim« namesto surovih števil. |

### 4.2 Vhodni podatki

| Pot | Vloge | Čas | Stanje | Ugotovitve |
|---|---|---:|---|---|
| `/zajem` | vsi | **21,7 s** | UX | Vsebinsko najboljša stran (viri, stanje, mesto prevzema, kartice s številkami). Čas je nesprejemljiv: `GetInboundFlowsAsync/Overview/FilterOptions` tečejo vzporedno (`Ingest.razor:156`), a nekdo od njih dela 20 s — meriti z `SET STATISTICS TIME` in dodati indeks/materializiran povzetek. Filter »Vsa podjetja« je tu privzet, drugje ne (§4 U1). |
| `/zajem/viri/{koda}` | vsi | **19,3 s** | UX | Isti povzetek po zavihkih podjetij (`source-detail.png`); »Mesto prevzema: ni registrirano v sledilnem modelu« je tehnično. Predlog: naložiti samo izbrano podjetje. |
| `/zajem/teki` | vsi | 1,1 s | OK | 50 vrstic, 5 filtrov. |
| `/zajem/teki/{id}` | vsi | – | ni odprto | Samo koda. |
| `/zajem/tezave` | vsi | 1,1 s | OK | |
| `/zajem/tezave/{vrsta}/{id}` | vsi | – | ni odprto | Ima `IsAdmin` za dejanja (vrstica 74) — pravi vzorec za §2.1. |
| `/zajem/cakalna-vrsta` | vsi | 1,1 s | OK | 72 vrstic; 3 vrstice čakajo od 30. 7. (§3.6). |
| `/zajem/neujemanja` | vsi | 1,4 s | OK | Prazno (0 vrstic) — dobro. |
| `/zajem/atributi` | ADMIN, CATALOG_EDITOR | 1,1 s | OK | 8 vrstic. |
| `/karantena` | vsi | 1,1 s | OK | 0 vrstic; plošča kaže 5 v karanteni — razlika obsega podjetja (U1). |
| `/teki-obdelave` | vsi | – | ni odprto | Podvaja `/zajem/teki`? Preveriti in eno pot ukiniti. |

### 4.3 PIM katalog

| Pot | Vloge | Čas | Stanje | Ugotovitve |
|---|---|---:|---|---|
| `/izdelki` | vsi | 5,5 s | UX, NAPAKA A6 | Zavihek »Za urediti (196.558)« od 196.559 ne loči ničesar; naslov tabele »Izdelki v aktivni organizaciji« nasprotuje podnaslovu »privzeto vsa podjetja«; prvih šest vrstic so testni zapisi (§3.5); tabela odrezana desno; 5,5 s za prvo stran je preveč (šteje vse zavihke, 6 poizvedb COUNT). Predlog: štetja zavihkov lenobno ali iz povzetka; shranjeni pogledi; vrnitev s kartice na isto stran/filter (Codex ni potrdil). |
| `/izdelki/{id}` | vsi | 3,9 s | **NAPAKA A1** | Pet sklopov, jasna blokada (»1 napak blokira ERP«), odprte naloge — dobra zasnova. Pod polji so tehnični ključi (`ProductText.WEB_TITLE.sl`, `Product.WebPublish`), ki jih uporabnik ne potrebuje; shranjevanje je zaporedno (besedila → atributi → SAOP vrsta) brez skupnega izida in brez preverjanja sočasnosti (ni `rowversion`/pričakovane stare vrednosti). Predlog: ključe v »Podrobnosti«, ena transakcija ali jasen delni izid, `rowversion` v `SaveProductTexts/Attributes`. |
| `/izdelki/uvoz` | ADMIN, CATALOG_EDITOR, COMMERCIAL | 1,1 s | UX | Jasno pravilo »prazna celica = ne dotakni se«. Predogled 20 vrstic brez staro → novo (Codex). Predlog: celoten predogled s primerjavo, izrecna namera izpraznitve (`#PRAZNO`). |
| `/izdelki/kategorije` | ADMIN, CATALOG_EDITOR | 1,1 s | OK | |
| `/mediji` | vsi | 2,0 s | UX | Podnaslov omenja `canon.ProductMedia in canon.ProductDocument`; sličice bele; samo za izbrano organizacijo brez izbirnika; nalaganja slik v vmesniku ni (`InputFile` samo na uvozu, SAOP artiklih, množičnem urejanju). Predlog: nadomestne sličice, izbirnik podjetja, nalaganje z vlogo `PRIMARY/GALLERY`. |

### 4.4 Kakovost

| Pot | Vloge | Čas | Stanje | Ugotovitve |
|---|---|---:|---|---|
| `/kakovost` | vsi | 10,4 s | UX | Odlična zasnova (po profilu, po polju, »kje se popravi«), a §3.1–3.3 jo izpraznijo: 177.653 od 177.655 »z zahtevo«. Zaporedna zanka po podjetjih (`Quality.razor:353-363`) → 10 s. |
| `/kakovost/napake` | vsi | 1,9 s | UX (U1) | Samo prvo podjetje (`GetCurrentOrganizationAsync`, vrstica 315): 17.413 izdelkov proti 177.653 na `/kakovost`. Vsaka vrstica je visoka ~350 px zaradi štirih navedb napak; tehnična imena polj. Predlog: izbirnik podjetja, strnjen prikaz (»41 napak · 4 profili · prvi 3«), poslovna imena polj. |
| `/kakovost/prevodi` | vsi | 1,1 s | OK | 0 vrstic pri privzetem filtru. |
| `/kakovost/kategorije` | vsi | 1,2 s | OK | 50 vrstic, 4 filtri — to je stran, ki rešuje §3.3; naj bo dosegljiva neposredno iz `/kakovost` in kartice. |

### 4.5 Izhodi ERP (SAOP)

| Pot | Vloge | Čas | Stanje | Ugotovitve |
|---|---|---:|---|---|
| `/saop` | ADMIN, CATALOG_EDITOR | 1,1 s | OK | 7 vrstic; skupine in »Pošlji znova vse neuspele«. |
| `/saop/artikli` | ADMIN, CATALOG_EDITOR | 1,2 s | OK | Štiristopenjski potek, ročni vnos in Excel, »Povezava je pripravljena« (`saop-items.png`). Vzor za druge zapisovalne strani. |
| `/saop/zgodovina` | ADMIN, CATALOG_EDITOR | 1,1 s | **NAPAKA A2**, PRAZNO | Pade brez parametra; stolpca »Odobril« in »Poslano« sta »—« (bralni model brez `OutboxAttempt`). |
| `/saop/odkloni` | ADMIN, CATALOG_EDITOR, COMMERCIAL | 1,1 s | PRAZNO | 0 vrstic + `<PimMissing>`. |
| `/saop/polja` | vsi | 1,1 s | PRAZNO | Naslov strani »Polja za zapis v SAOP«, H1 »Kaj sme nazaj v SAOP« — uskladiti. |
| `/outbound` | ADMIN, CATALOG_EDITOR, COMMERCIAL | 1,1 s | OK | 10 vrstic. |
| `/izvozi/mnozicno` | isto | 1,1 s | OK | |
| `/izvozi/obvestila` | isto | 1,1 s | OK | Vidno opozorilo »1 obvestil ni bilo potrjenih … poslana po e-pošti« — pravilno, a se ponavlja na vsakem obisku, dokler ni potrjeno; potrditev naj bo tu z enim klikom. |
| `/izvozi` | vsi | – | ni odprto | |

### 4.6 Izhodi splet

| Pot | Vloge | Čas | Stanje | Ugotovitve |
|---|---|---:|---|---|
| `/splet` | vsi | 2,1 s | UX, PRAZNO ×2, A9 | Kartice »V datoteki 352 / Brez spletne strani 287 / Gre z opozorilom 1.727« in tabela blokad — razumljivo. Neoblikovan `<select>`. |
| `/splet/izvoz` | vsi | 1,1 s | OK | Predogled 200 vrstic, pretočni CSV. Dostopen tudi `VIEWER`-ju — sprejemljivo (branje), a naj bo zapisano v produktnem modelu. |
| `/izvozi/profili/{id}` | vsi | 1,1 s | PRAZNO | 9 stolpcev, `<PimMissing>`. |

### 4.7 Poslovanje

| Pot | Vloge | Čas | Stanje | Ugotovitve |
|---|---|---:|---|---|
| `/stranke`, `/stranke/{id}` | ADMIN, CATALOG_EDITOR, COMMERCIAL | – | ni odprto (osebni podatki) | Koda: kartica ima 7 zapisovalnih poti z ločenimi `catch` sporočili (dobro), 2× `<PimMissing>` (kontakti iz SAOP, dokumenti/finance). |
| `/partnerji` | vsi | – | ni odprto | |
| `/zaloge` | vsi | 1,3 s | UX (D4) | Pozicije brez artikla ×4 podjetja; tabela odrezana (STANJE); »Prenesi zalogo (CSV): najprej izberi podjetje« je dobro vodenje. |
| `/cene` | vsi | 1,5 s | UX | Privzeto DEMO; stolpec »Zadnja veljavnost« kaže `3. 08. 2022` ob stanju »2 veljavnih« — pomen ni jasen (velja od? do?). Preimenovati v »Velja od« ali dodati »do«. |
| `/cene/tisk` | vsi | 1,1 s | OK | |
| `/preverbe` | vsi | 5,1 s (10,2 s kot VIEWER) | **NAPAKA A4**, PRAZNO ×3 | Alarme PRICE_CHECK/STOCK_CHECK nihče ne ustvarja — stran je ogrodje. 100 vrstic. |
| `/pravila-popustov` | ADMIN, CATALOG_EDITOR, COMMERCIAL | – | ni odprto | Pot ni pod `/pravila/`. |

### 4.8 Nastavitve kataloga

| Pot | Vloge | Čas | Stanje | Ugotovitve |
|---|---|---:|---|---|
| `/nastavitve` | ADMIN, CATALOG_EDITOR | 1,1 s | OK | Razdelilna stran. |
| `/nastavitve/kategorije` | isto | 4,7 s | UX, A9 | Pokritost imen po jezikih (391 od 1.045) je odlična; gumb »Atributi« pod **vsako** vrstico je šum — prestaviti v vrstico kot ikono; koren »Cameleon sistem« ima 0 izdelkov in 1.041 v podkategorijah — pokazati skupno; 209 vrstic hkrati → 4,7 s. |
| `/nastavitve/nabori-atributov` | isto | 2,0 s | OK | Jasne kartice (13/132 kategorij z naborom, 5.126 izdelkov pod naborom). Videlektro 33/77, 0 izdelkov — drevo brez izdelkov naj to pove. |
| `/nastavitve/atributi` | isto | 3,7 s | UX | 182 vrstic z 4 vrsticami prevodov »ime manjka« vsaka — visoka stran; prevodi kot 4 značke v eni vrstici; 3,7 s za 182 vrstic je preveč. |
| `/nastavitve/atributi/{koda}` | isto | 1,1 s | **PRAZNO** | `intranet.GetAttributeValues` v bazi ne obstaja (`sys.procedures` potrjeno); stran »Vrednosti niso na voljo«. Bodisi dostaviti proceduro (migracija) bodisi povezavo iz seznama skriti. |
| `/nastavitve/kanali`, `/jeziki`, `/skladisca` | isto | 1,1 s | OK | 4 / 5 / 7 vrstic, samo branje. |
| `/nastavitve/povezave-izdelkov` | isto | 1,6 s | OK | 0 vrstic. |

### 4.9 Pravila in izvor podatkov

| Pot | Vloge | Čas | Stanje | Ugotovitve |
|---|---|---:|---|---|
| `/pravila` | ADMIN, CATALOG_EDITOR, COMMERCIAL | 1,1 s | OK | |
| `/pravila/validacija` | isto | 2,0 s | UX | **623 vrstic s 623 izbirniki resnosti** na eni strani (`ValidationRules.razor:61`) — ena sprememba pomeni iskanje po 623 vrsticah. Predlog: po profilu/skupini, iskanje, sprememba na vrstici. Profila `LEGACY` (`ERP_L1`, `WEB_B2C`) sta aktivna (§3.2). |
| `/pravila/slovar` | isto | 1,1 s | OK | 50 vrstic; `/zajem` pravi 58.778 nerazvrščenih vrednosti — povezava od tam sem naj nosi filter. |
| `/pravila/preslikave` | isto | 1,1 s | OK | |
| `/pravila/nazivi` | ADMIN, CATALOG_EDITOR | 3,7 s | NAPAKA A7 | Sicer dober tok (sestavni deli, predogled po jeziku, »zapiši samo manjkajoče«). |

### 4.10 Sistem (samo ADMIN)

| Pot | Čas | Stanje | Ugotovitve |
|---|---:|---|---|
| `/sistem` | 2,2 s | UX (O1) | »Potrebuje pozornost (25)« so skoraj vsi »molči« zaradi razvojnega okolja; 53 vrstic, 23 urejivih polj (urniki v isti tabeli). Ločiti »ni predvideno, da teče« od »zamuja«. |
| `/sistem/integracije` | 1,1 s | OK | 23 vrstic. |
| `/sistem/urniki` | 1,1 s | OK | 23 vrstic, 23 polj. |
| `/sistem/napake` | 1,1 s | UX | 277 vrstic hkrati, 260 istih sporočil — združiti po sporočilu s številom. |
| `/sistem/vloge`, `/sistem/zmogljivost`, `/sistem/izvozi`, `/sistem/samotest` | 1,1 s | OK | 4 / 19 / 166 / 3 vrstic. Samotest: 3 zagoni, zadnji 20:39. |
| `/sistem/mape`, `/sistem/sled`, `/system/uporabniki` | – | ni odprto | Koda: `AdminActivity.razor:94` splošen `catch`. |

### 4.11 Skupno vsem stranem (U1–U3)

- **Obseg podjetja.** Tri različne privzete vrednosti: vsa podjetja (`/nadzorna-plosca`, `/izdelki`,
  `/zajem`, `/kakovost`, `/zaloge`), prvo podjetje (`/kakovost/napake`, `/mediji`, `/karantena`,
  `/preverbe`), DEMO iz izbirnika (`/cene`, `/saop/artikli`). Uporabnik ne ve, katere številke se
  smejo primerjati. Predlog: en izbirnik podjetja v zgornji vrstici (»Vsa · DEMO · IQLighting …«),
  shranjen v seji, ki ga spoštuje vsaka stran; strani, ki po naravi delajo z enim podjetjem
  (zapis v SAOP), ga samo prikažejo.
- **Tehnični ključi** (`Product.VatRateId`, `ProductText.WEB_TITLE.sl`, `intranet.GetAttributeValues`,
  `canon.ProductMedia`) so na desetih straneh v prvem planu. Predlog: poslovno ime spredaj, ključ v
  razložljivi podrobnosti (`<details>`), za skrbnika stikalo »pokaži tehnične ključe«.
- **Filtri** so ponekod samodejni (`/izdelki`), ponekod z gumbom »Uporabi filtre« (`/zaloge`,
  `/kakovost/napake`) — izbrati eno.
- **Odzivnost** deluje do ~900 px, spodaj velja §2.6. Tabele nimajo vidnega znaka, da se dajo
  premakniti vodoravno.
- **Kontrast**: pomožna besedila (`--pim-text-muted` na belem) so na posnetkih blizu meje 4,5 : 1
  (WCAG 2.2 1.4.3); ni merjeno z orodjem — preveriti pri prenovi barv.
- **Stanja**: `PimState` (nalaganje/napaka/prazno) je dosledno; sporočila napak so večinoma
  »trenutno ni mogoče naložiti« brez razloga in brez ID zahteve za skrbnika.

---

## 5. Zmogljivost

| Stran | Čas (ADMIN, 1440 px) | Vzrok (kolikor je potrjen) |
|---|---:|---|
| `/zajem` | 21,7 s | ena od treh vzporednih poizvedb (`GetInboundFlows/OverviewSummary/FilterOptions`) |
| `/zajem/viri/BT_XML` | 19,3 s | povzetki za vsa štiri podjetja hkrati |
| `/nadzorna-plosca` | 11,7 s | 4 podjetja × 4 servisi zaporedno (`Dashboard.razor:135-157`) |
| `/kakovost` | 10,4 s | 4 podjetja × (profili + povzetki + vrzeli + načrt + zajem) zaporedno |
| `/preverbe` | 5,1–10,2 s | 100 vrstic + tri manjkajoče bralne modele |
| `/izdelki` | 5,5 s | štetja za 6 zavihkov nad 196.559 vrsticami |
| `/nastavitve/kategorije` | 4,7 s | 209 vrstic drevesa z imeni v 5 jezikih |
| ostalih 47 strani | 1,0–3,9 s | sprejemljivo |

Cilj za profesionalno rabo: seznam < 2 s, plošča < 3 s. Pot: (1) `SET STATISTICS TIME/IO` nad
štirimi zgornjimi procedurami, (2) en nabor za vsa podjetja namesto zanke, (3) povzetki v tabeli
(`ops.DashboardSnapshot`, osvežen po vsakem teku) namesto računanja ob vsakem prikazu,
(4) `Task.WhenAll` tam, kjer ostane več klicev. Meriti s to isto skripto pred in po.

---

## 6. Skupne delovne poti

| Pot | Kako gre danes | Kaj manjka |
|---|---|---|
| **Nov artikel iz SAOP do spleta** | zajem → `/izdelki` → kartica → kategorija (`/izdelki/kategorije`) → naziv (`/pravila/nazivi`) → slika (samo iz dobaviteljevega XML) → validacija → `/splet/izvoz` | nalaganje slike v vmesniku; »naslednji korak« na kartici, ki vodi po tem zaporedju; en gumb »Pripravi za splet« s seznamom manjkajočega |
| **Odprava napak validacije** | `/kakovost` po polju → »kje se popravi« → ciljna stran | obseg podjetja (U1), skupinski popravki (§3.3), polja brez vira (§3.1) označena kot nepopravljiva v PIM |
| **Zapis v SAOP z odobritvijo** | `/saop/artikli` (4 koraki) → `/saop` (čakalna vrsta, odobritev) → `/saop/zgodovina` | zgodovina pade (A2); odobritelj in čas pošiljanja manjkata v bralnem modelu; ni pregleda »kaj bo poslano« po poljih pred odobritvijo |
| **Spletni izvoz** | `/splet` → blokade → `/splet/izvoz` → CSV | zgodovina izvozov je pod `/sistem/izvozi` (samo ADMIN) — urednik ne vidi, kaj je šlo ven |
| **Dobaviteljev XML** | `/zajem` → vir → `/pravila/preslikave`, `/pravila/slovar`, `/zajem/neujemanja` | povezave iz kartic (58.778 nerazvrščenih) s filtrom; 40 dni stare vrstice v vrsti (§3.6) |
| **Skrbnik zjutraj** | `/sistem` + zvonec | zvonec laže ob napaki (A8); 25 »molči« zaradi okolja; opozorila brez združevanja |

---

## 7. Oblikovna ocena

Vizualna osnova (barve, kartice, tabele, značke, fokus, `PimPage/PimTable/PimState/PimChip`) je
enotna in mirna; stranska vrstica z opisi in »podatkovni tok« v zgornji vrstici dobro orientirata.
**Popolna zamenjava podobe ni potrebna.** Kar loči današnje stanje od profesionalnega PIM-a, ni
videz, ampak štiri stvari: (1) številke, ki jim uporabnik lahko verjame (§3.1–3.3, U1),
(2) zapisovalne poti z vlogami in jasnim izidom (A1, A3, A4, sočasnost), (3) hitrost prvih zaslonov
(§5) in (4) ravnanje z gostoto: dolge strani (623 vrstic pravil, 277 napak, 182 atributov s 4
vrsticami prevodov) potrebujejo skupine, strani ali strnjen prikaz.

---

## 8. Prednostni načrt za profesionalen PIM

Vrstni red je po škodi, ne po zahtevnosti. Vsaka točka ima ozemlje (AGENTS.md §7) in dokaz.

### P0 — ta teden (varnost in padci)

1. **Vloge na zapisovalni meji** (A1, A4): politika `CatalogWrite`, preverjanje v
   `ProductEditService`, `SaopWriteService`, potrjevanje alarmov; kartica samo za branje za `VIEWER`.
   Ozemlje INTRANET. Dokaz: `PIM.F10.AuthTests` RED → GREEN, `run_tests.ps1 -Filter F10` = 0 padlih.
2. **Padec zgodovine SAOP** (A2): `string? Status`. INTRANET. Dokaz: UX test GET 200.
3. **Seja onemogočenega računa in omejitev prijave** (A3): `SecurityStamp` + `OnValidatePrincipal`
   + `AddRateLimiter`. BAZA → INTRANET. Dokaz: `AuthTests`.
4. **Stran »brez dostopa« in slovenska stran napake** (A5). INTRANET.

### P1 — naslednja dva tedna (podatki, ki delajo kakovost uporabno)

5. **`Product.VatRateId`** (§3.1): odločitev uporabnika (preslikava ali umik zahteve). BAZA/DOMENA.
   Dokaz: `/kakovost` `ERP_SLO` ni več 9,6 %.
6. **Obseg spletnih profilov** (§3.2): validacija `WEB` samo za `WebPublish=1`, zaprtje starih
   vrstic, izklop `LEGACY` profilov. DOMENA + BAZA. Dokaz: SQL iz §3.2 vrne 0 za `WebPublish=0`.
7. **Kategorije skupinsko** (§3.3): povezava `/kakovost` → `/kakovost/kategorije` s filtrom in
   oceno učinka. INTRANET.
8. **Dobaviteljeva zaloga po podjetju** (§3.4) in **testni zapisi** (§3.5). DOMENA/BAZA.
9. **Migracije**: uskladiti številke 153/154/169/172/173 z ledgerjem pred merge-em (§3.7). BAZA.
   Dokaz: migrator 1. in 2. zagon + `--verify` na sveži bazi.

### P2 — naslednji mesec (izkušnja)

10. **En izbirnik podjetja** za celoten vmesnik (U1). INTRANET.
11. **Hitrost** štirih najpočasnejših strani (§5). BAZA (procedure) → INTRANET. Dokaz: skripta
    `Inspect-Ui.ps1` pred/po.
12. **Ozka širina in tipkovnica** (A6, A7, A9). INTRANET.
13. **Tehnični ključi v podrobnosti**, poslovna imena polj (U3). INTRANET.
14. **Opozorila**: združevanje, štetje dogodkov, tretje stanje zvonca, ločevanje razvojnega okolja
    (A8, O1). DOMENA + INTRANET.
15. **Prazne strani**: dostaviti `intranet.GetAttributeValues` in `OutboxAttempt` v zgodovino ali
    povezave skriti, dokler modela ni (9 strani z `<PimMissing>`). BAZA → INTRANET.
16. **Dolge strani**: pravila validacije po profilih, napake sistema združene, atributi s prevodi v
    eni vrstici. INTRANET.

### P3 — do »profesionalnega PIM-a«

17. **Sočasnost**: `rowversion` na `pim.*` in pričakovana vrednost v `SaveProductTexts/Attributes`;
    kartica pokaže konflikt s tujo vrednostjo.
18. **Ena transakcija ali jasen delni izid** pri shranjevanju kartice.
19. **Nalaganje medijev** v vmesniku z vlogo in vrstnim redom; predogledi.
20. **Delovni tok izdelka** (osnutek → pripravljen → objavljen) z lastnikom naloge in rokom;
    »moje naloge« na plošči po vlogi.
21. **Uvoz Excel** s primerjavo staro → novo za vse vrstice in izrecno namero izpraznitve.
22. **Hramba** (`map.ExtractedValue`, rešene napake, posnetki zaloge) kot nočno opravilo z merjenjem.
23. **Dostopnost**: kontrast z orodjem, `aria-*` na menijih in tabelah, fokus po shranjevanju.
24. **Stalna meritev**: `Inspect-Ui.ps1` v nočni samotest (čas strani, 500, urejiva polja za VIEWER),
    da regresije A1/A2 ne pridejo nazaj.

---

## 9. Kaj ni bilo preverjeno

- `scripts\run_tests.ps1`, `dotnet build`, migrator `--verify` — nista bila pognana; poročilo ne
  trdi, da današnja različica gradi ali da testi tečejo.
- Dejanski zapis z računom `VIEWER` (namerno; dokaz je prisotnost polj in gumba ter koda/procedure).
- Strani s podatki strank (`/stranke*`, `/partnerji`), `/pravila-popustov`, `/izvozi`,
  `/teki-obdelave`, podrobnosti tekov in težav, `/sistem/mape`, `/sistem/sled`, `/system/uporabniki`
  — samo koda.
- Živi SAOP, e-pošta, dostava datotek — prepovedano po AGENTS.md; stanje integracij (§3.6) opisuje
  razvojno okolje.
- Kontrast barv z orodjem; vedenje pri > 1440 px; tiskanje cenika.
- Sočasno urejanje v dveh sejah (Codex ni reproduciral; ugotovitev je iz pogodb procedur).

QA nauk (Codex): `[Authorize]`, revizijska sled in preverjeno lastništvo polja ne dokazujejo, da
ima trenutni uporabnik dovoljenje za zapis. Dodatek (Claude): vsaka številka, ki jo stran pokaže,
naj ima obseg (katera podjetja, kateri izdelki) zapisan zraven; brez tega je tudi pravilna
številka zavajajoča.
