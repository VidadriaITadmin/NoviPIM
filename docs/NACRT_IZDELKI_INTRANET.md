# Izdelki v intranetu — pregled stanja, uporabniški načrt in prompt za Codex

Datum: 2026-08-24. Avtor: Claude Code. Ozemlje: analiza (brez sprememb kode).

Vir trditev je koda in migracije: `src/PIM.Intranet/Components/Pages/Products.razor` in
`ProductDetail.razor`, `Services/IntranetDataService.cs`, procedure `intranet.GetProducts` (027),
`intranet.GetProductDetail` (029), `pim.GetProductHistory` (028), `sql/migrations/006, 028–037,
047, 057–058, 068, 072–077, 080, 086, 089`. Številke o vsebini baze so povzete iz `STATUS.md` in
opomb v migracijah (meritve 21.–24. 8. 2026), ne iz mojega poizvedovanja.

Sestrska dokumenta: [`NACRT_VHODI_INTRANET.md`](NACRT_VHODI_INTRANET.md) (vhodi),
[`PRODUKTNI_MODEL_PIM.md`](PRODUKTNI_MODEL_PIM.md) (faze in obvezna pogodba strani),
[`NACRT_INTRANET_PRENOVA.md`](NACRT_INTRANET_PRENOVA.md) §3–§5 (lastništvo polj, prekrivka, IA).

---

## 1. Kaj je danes

### 1.1 `/izdelki`

Ena tabela s šestimi stolpci: izbira, artikel, EAN, status, popolnost, gumb za odpiranje.
Orodna vrstica ima iskanje (`ItemID` ali `EAN`) in izbirnik statusa (`VALID` / `INVALID` /
`PENDING`). Paginacija je strežniška (`Take = 50`, `TotalCount` iz drugega nabora).
Izbira preživi menjavo strani in filtrov; gumb »Uredi izbrane« pelje na `izvozi/mnozicno?items=…`.

Vir: `intranet.GetProducts @OrganizationId, @Skip, @Take, @Search, @Status` — bere izključno
`canon.Product` in vrne pet stolpcev.

### 1.2 `/izdelki/{id}`

Glava (šifra, EAN, status, »Aktiven«, »Za splet«), kartice validacijskih profilov s popolnostjo
in štirje zavihki:

| Zavihek | Vsebina | Vir |
|---|---|---|
| Pregled | 9 polj iz `canon.Product` (šifra, EAN, enota, skupina, oddelek, proizvajalec, dobavitelj, popolnost, zadnja validacija) | `canon.Product` |
| Validacijski profili | profil, status, popolnost, čas | `val.ProductValidationState` |
| Odprte težave | profil, koda, sporočilo, zadnji pojav | `val.ProductIssue` |
| Zgodovina | polje, stara/nova vrednost, vir, kdo, čas, lastnik | `pim.ProductFieldHistory` prek `pim.GetProductHistory` |

**To je pošteno narejeno za tisto, kar pokriva.** Dostopnost je resna (merilniki z
`role="progressbar"`, tablist z `aria-controls`, čipi s skrito oznako »Status: «), vse vrednosti
so iz baze, paginacija seznama je strežniška. Problem ni izvedba, ampak **obseg**.

---

## 2. Ugotovitve

### 2.1 Kartica izdelka pokaže glavo, ne izdelka

O izdelku obstaja v bazi približno petnajst tabel. Kartica bere eno.

| Kaj obstaja | Tabela | Obseg (STATUS.md, meritve 8/2026) | Na kartici |
|---|---|---|---|
| Besedila po jezikih in vrstah (`TITLE_ERP`, `TITLE_ERP2`, `WEB_TITLE`, `DESCRIPTION`) | `canon.ProductText` | ~196.500 vrstic samo `TITLE_ERP` | **ne** |
| Lastnosti | `canon.ProductAttribute` | 112.820 vrstic | **ne** |
| Kategorije po drevesih | `canon.ProductCategory` | 6.494 objavljenih | **ne** |
| Slike | `canon.ProductMedia` | 1.384 samo Braytron | **ne** |
| Cene po cenikih | `canon.ProductPrice` | — | **ne** |
| Trgovinski podatki (teže, tarifa, država, Pak1/Pak2, dimenzije) | `canon.ProductCommercial` | 196.513 | **ne** |
| Planiranje | `canon.ProductPlanning` | 196.512 | **ne** |
| Konti zaloge | `canon.ProductStockAccounting` | 176.086 | **ne** |
| Pravilo najmanjše/največje zaloge | `canon.ProductStockPolicy` | — | **ne** |
| Dejanska zaloga | `stock.Position.MatchedProductId` | 168.594 pozicij | **ne** |
| Objava (kaj gre na splet) | `pim.Product` + 6 otroških tabel | 89.129 objavljenih | **ne** |
| Lastništvo polja | `pim.FieldOwnership`, `out.OwnershipPolicy` | registrirano | **ne** |
| Čakajoča sprememba za SAOP | `intranet.GetPendingOverlay` (089) | procedura obstaja | **ne** |

Urednik torej odpre izdelek in ne izve niti, kako mu je ime.

### 2.2 Seznama ni mogoče uporabiti za iskanje dela

Filtrira se po šifri, EAN in skupnem statusu. Ni filtra po proizvajalcu, dobavitelju, skupini,
oddelku, kategoriji, viru, popolnosti, »ima sliko«, »za splet«, »objavljen« ali po profilu.
Pri ~196.500 artiklih to pomeni: **izdelek najdeš le, če njegovo šifro že poznaš.** Delovnega
seznama (»kaj moram danes urediti«) ni.

### 2.3 Status je en, resnica pa je dvojna

Od migracije 047 validacija loči `Severity` (`ERROR`/`WARNING`) in obseg blokade
(`BlocksErp`, `BlocksWeb`). Seznam pokaže `canon.Product.ValidationStatus` — eno vrednost.
Najpogostejše dejansko stanje (»za ERP v redu, za splet ne«) v seznamu ni izrazljivo, čeprav ga
`val.ProductValidationState` pozna po profilih.

### 2.4 Ni shranjenih pogledov

`NACRT_INTRANET_PRENOVA.md` §5 zahteva: ena entiteta = ena stran, statusi so **shranjeni pogledi**.
Danes je zavihek en sam (»Vsi izdelki«), pogodbeni test celo izrecno prepoveduje dodajanje
zavihkov brez podatkovnega vira. Vir je treba torej najprej ustvariti.

### 2.5 Stanje seznama ni v naslovu

Iskanje, filter, stran in izbira živijo v komponenti. Posledice: osvežitev izgubi vse, povezave
ni mogoče deliti (»poglej teh 40 artiklov«), gumb »nazaj« iz kartice te vrne na prvo stran.
Načrt (§7/6.1) izrecno zahteva stanje v query stringu.

### 2.6 Izbira se tiho odreže na 200

`Products.razor` pošlje izbrane šifre skozi URL in jih omeji: `Selected.Take(MaxSelectionInUrl)`,
`MaxSelectionInUrl = 200`. Kdor izbere 500 artiklov in klikne »Uredi izbrane (500)«, jih uredi
200 — **brez opozorila**. Za množično urejanje je to najbolj tiha vrsta napake.

### 2.7 Množično urejanje živi v napačnem modulu

Gumb pelje na `/izvozi/mnozicno`. Urednik kataloga s tem pristane v odhodni poti, čeprav je
predmet izdelek. Pravilo iz načrta: »Vsako dejanje se zgodi tam, kjer je predmet.«

### 2.8 Kartica ne pozna kanala in jezika

Lupina ima izbirnik organizacije, kanala in jezika. Kartica ga ne upošteva — besedila po jezikih,
kategorije po drevesu in cene po ceniku so ravno tisti podatki, kjer je izbira pomembna.

### 2.9 Ni urejanja — niti tam, kjer je PIM lastnik

Zapisovalne poti za polja v lasti PIM (spletni naziv, opis, kategorija, medij, lastnost) ni.
`pim.FieldOwnership` in `out.OwnershipPolicy` pravita, katera polja PIM sme pisati; vmesnik tega
ne izkoristi. **PIM brez urejanja je poročilo o SAOP.**

### 2.10 Zgodovina je brez razveljavitve

`pim.UndoProductField` in `pim.UndoProductBatch` (032, 036, 037) obstajata in sprejmeta `@Actor`.
Zavihek »Zgodovina« nima gumba. Poleg tega izpiše vse spremembe naenkrat — brez filtra po polju,
paketu ali obdobju in brez paginacije.

### 2.11 Ni prekrivke »čaka potrditev«

Migracija 089 je dala `intranet.GetPendingOverlay` prav za to: pokazati vrednost, ki je poslana v
SAOP in še ni potrjena, nad kanonično vrednostjo. Kartica je ne kliče, zato uporabnik vidi staro
vrednost in ne ve, da je sprememba na poti — ali da je obtičala v `Drift`.

### 2.12 Kartica je slepa ulica

Iz izdelka ni povezave na medije, cene, zalogo, njegove kategorije, profil, ki ga blokira, niti
na vhodno stran (`raw.Inbox`), iz katere je podatek prišel. Vprašanje »zakaj ta izdelek ni na
spletu« zahteva pet strani in eno poizvedbo v SSMS.

### 2.13 Brez slik in brez naziva je seznam neberljiv

Za katalog svetil je sličica osnovno sredstvo prepoznave. Danes seznam nima ne slike ne naziva.

### 2.14 Zmogljivost bo vprašanje takoj, ko dodamo filtre

`intranet.GetProducts` išče z `ItemID LIKE N'%…%' OR EAN LIKE N'%…%'`. Na `EAN` ni indeksa
(edini je `UQ_CanonProduct_OrganizationItem`), vodilni `%` pa tudi obstoječega ne uporabi.
Globok `OFFSET` pri ~196.500 vrsticah je drugi strošek. Sortiranja po stolpcih ni — ko bo, bo
potrebovalo svoje indekse.

### 2.15 Pogodbena testa pinata trenutno obliko — in to je treba povedati naglas

- `PIM.F10.ProductsUxTests`: `Regex.Matches(markup, "class=\"page-tab(?!s)").Count == 1` in
  `<th scope="col">` točno **6**.
- `PIM.F10.ProductDetailUxTests`: `class="flag-chip"` točno **2**.

Vsak nov zavihek, stolpec ali čip ju podre. `AGENTS.md` §5.3 pravi: nikoli ne spremeni testa zato,
da bi šel skozi. To ni izgovor za zamrznitev izdelka — pomeni, da se **pogodba prepiše zavestno**:
v isti nalogi, z novim številom, z zapisanim razlogom v commitu in `TASKBOARD.md`, in **brez
odstranjevanja ene same dostopnostne trditve**. Kar se sme spremeniti, so pinana števila; kar se
ne sme, so `role`, `aria-*`, `caption`, `scope` in prepoved izmišljenih vrednosti.

---

## 3. Kaj hoče uporabnik — po vlogah

### 3.1 CATALOG_EDITOR — glavni uporabnik te strani

Vprašanje: **»Kaj moram danes urediti in ali sem s tem kaj odklenil?«**

Mora videti:
- delovni seznam, ne registra: »neveljavni za splet«, »brez slike«, »brez spletnega naziva«,
  »brez kategorije«, »popolnost pod 75 %«, in vsak s svojim številom;
- na vrstici: sličico, naziv, šifro, EAN, proizvajalca, popolnost ter **ločena** statusa za ERP
  in splet;
- na kartici vse, kar o izdelku obstaja, razdeljeno po zavihkih, z jasno oznako lastnika polja;
- pri vsaki odprti težavi natanko to, **katero polje** manjka in **kateri profil** ga zahteva —
  ne le kodo napake.

Mora znati narediti:
- urediti polja v lasti PIM (spletni naziv, opis, kategorija, medij, lastnost) in takoj videti
  učinek na popolnost in status;
- množično spremeniti eno polje nad izbiro, s predogledom učinka pred potrditvijo;
- razveljaviti svojo spremembo — posamično ali cel paket;
- označiti izdelek za splet oziroma ga umakniti, če je to polje v lasti PIM.

### 3.2 COMMERCIAL — komerciala

Vprašanje: **»Ali je ta izdelek prodajno pripravljen in po kakšni ceni?«**

Mora videti: cene po vseh cenikih z veljavnostjo, zalogo iz aktivnega posnetka in datum
razpoložljivosti, dobavitelja, komercialne podatke (teža, pakiranje, tarifa, država), status
profila `COMMERCIAL_L2` in ali je izdelek objavljen.
Mora znati narediti: naročiti spremembo komercialnih polj, ki gre skozi odobritev v `out.OutboxMessage`,
in videti, kje je ta zahtevek (čaka odobritev / poslano / potrjeno / odmik).

### 3.3 ADMIN

Vse zgoraj, plus: lastništvo polj, kdo je kaj spremenil in kdaj, povezava na vhodno stran
(`raw.Inbox`) in surov zapis, iz katerega je vrednost prišla, ter stanje odhodnih sporočil za ta
izdelek — vključno z `Drift`.

### 3.4 VIEWER

Bere vse, brez gumbov. Iste številke kot vsi ostali — da se ljudje sklicujejo na isto stvar.

### 3.5 Skupno vsem — en test uporabnosti

**Na eni strani mora biti odgovorjeno: »Zakaj ta izdelek ni na spletu?«** Danes to zahteva pet
strani. To je merilo, po katerem se prenova ocenjuje.

---

## 4. Načrt — seznam `/izdelki`

### 4.1 Zavihki so shranjeni pogledi, njihova števila pa iz iste poizvedbe

| Zavihek | Pogoj |
|---|---|
| Vsi | brez pogoja |
| Za urediti | ima vsaj eno odprto težavo z `Severity = ERROR` |
| Brez slike | ni vrstice v `canon.ProductMedia` |
| Brez spletnega naziva | ni `canon.ProductText` z `TextType = WEB_TITLE` za izbrani jezik |
| Brez kategorije | ni `canon.ProductCategory` za izbrano drevo |
| Ni objavljen | ni vrstice v `pim.Product` |
| Čaka SAOP | ima vrstico v `out.OutboxMessage` v stanju, ki še ni zaključeno |

Vsak zavihek ima število; števila pridejo v svojem naboru iste procedure, da se stran ne izriše
z osmimi poizvedbami.

### 4.2 Orodna vrstica

Iskanje (šifra, EAN, naziv), nato sestavljivi filtri: proizvajalec, dobavitelj, skupina, oddelek,
kategorija (drevo + pot), vir (`SourceCode`), popolnost (pod izbranim odstotkom), ima sliko,
za splet, aktiven, objavljen, status po profilu (ločeno ERP in splet), obdobje zadnje spremembe.
Aktivni filtri so vidni kot odstranljivi čipi. Vse se zrcali v query string.

### 4.3 Stolpci

Sličica · Artikel · Naziv · EAN · Proizvajalec · Dobavitelj · Skupina · Cena (privzeti cenik) ·
Zaloga · Status ERP · Status splet · Popolnost · Zadnja sprememba.
Privzeto ožji nabor, razširjen nabor prek preklopa (»Več stolpcev«), stanje v query stringu.
Sortiranje po šifri, nazivu, popolnosti in zadnji spremembi — samo po indeksiranih stolpcih.

### 4.4 Izbira in množična dejanja

- Izbira preživi strani (kot danes), a se **ne prenaša skozi URL**. Namesto tega gre v
  strežniško stanje (piškotek s ključem izbire ali tabela izbire), da tihega reza na 200 ni več.
- Če se izbira iz kakršnegakoli razloga omeji, mora biti to **vidno sporočilo**, ne tiho.
- Dejanja: »Uredi izbrane« (polja v lasti PIM, takoj), »Pošlji v SAOP« (polja v lasti SAOP, prek
  outboxa z odobritvijo — obstoječi tok iz `/izvozi/mnozicno`, a sprožen tu), »Izvozi izbor v CSV«.

---

## 5. Načrt — kartica `/izdelki/{id}`

**Izvedeno 2026-08-26 (bralni del):** migracija `100_ProductCardReadModel.sql`,
`ProductWorkbenchService` in `ProductCard.razor` uresničujejo spodnji hero ter vseh 12
zavihkov. Kartica je namenoma samo bralna: prikaže lastništvo, čakajočo SAOP prekrivko in
razloge blokade, ne ponuja pa gumba, dokler ni izvedena zapisovalna faza P3/P4. Seznam iz §4
še uporablja obstoječi `intranet.GetProducts` in ni del te dostave.

**Hero:** sličica, naziv (spletni, sicer ERP), šifra, EAN, čipi: Aktiven, Za splet, Objavljen,
Status ERP, Status splet, Popolnost. Desno gumbi glede na vlogo in lastništvo.

**Zavihki:**

| Zavihek | Vsebina | Vir |
|---|---|---|
| Pregled | ključna polja z značko lastnika (PIM / SAOP / SHARED) in prekrivko »čaka potrditev« | `canon.Product`, `pim.FieldOwnership`, `intranet.GetPendingOverlay` |
| Besedila | ERP naziv (1. in 2. vrstica), spletni naziv, opis — po jezikih | `canon.ProductText` |
| Lastnosti | koda, vrednost, vir; iskanje po kodi | `canon.ProductAttribute` |
| Kategorije | uvrstitve po drevesih, s potjo | `canon.ProductCategory`, `canon.Category` |
| Mediji | galerija z vlogo in vrstnim redom, povezava do vira | `canon.ProductMedia` |
| Cene | cenik, neto, DDV, velja od, aktivna | `canon.ProductPrice` |
| Zaloga | količina, datum razpoložljivosti, prihajajoča količina, skladišče, starost posnetka; pravilo min/max | `stock.Position`, `canon.ProductStockPolicy` |
| Trgovinski podatki | teže, tarifa, država, Pak1/Pak2, dimenzije | `canon.ProductCommercial` |
| Kakovost | profili s statusom in popolnostjo, odprte težave z zahtevanim poljem in resnostjo | `val.*` |
| ERP / odhodna pot | sporočila za ta izdelek: stanje, poskus, napaka, echo, odmik | `out.OutboxMessage`, `out.OutboxAttempt` |
| Zgodovina | spremembe po poljih, paket, avtor, vir; gumb »Razveljavi« | `pim.ProductFieldHistory`, `pim.UndoProductField/Batch` |
| Izvor | iz katerega vira, teka in strani `raw.Inbox` je podatek prišel | `raw.Inbox`, `map.ExtractedValue` |

**Pravilo prikaza polja:** vsako polje nosi lastnika. Polje v lasti PIM je urejljivo takoj; polje v
lasti SAOP je urejljivo samo prek odhodne poti in dobi oznako »čaka potrditev«, dokler echo ne
potrdi. Polje brez zapisovalne poti **nima gumba** — to je pravilo iz `INTRANET.md` §6.3.

---

## 6. Kaj mora nastati v bazi

### 6.1 Bralni model izdelkov — načrt 095, kartica izvedena z migracijo 100

| Procedura | Vrne |
|---|---|
| `intranet.SearchProducts` | nabor 1: vrstice s slikami, nazivi, cenami, zalogo in statusi po profilih; nabor 2: `TotalCount`; nabor 3: števila po shranjenih pogledih. Parametri: `@OrganizationId, @View, @Search, @Manufacturer, @Supplier, @ItemGroup, @Department, @CategoryTreeCode, @CategoryCode, @SourceCode, @MaxCompleteness, @HasMedia, @WebPublish, @IsActive, @IsPromoted, @ErpStatus, @WebStatus, @ChangedFromUtc, @Sort, @Skip, @Take` |
| `intranet.GetProductCard` | izvedeno v migraciji 100; 15 fizičnih naborov napaja 12 zavihkov iz §5, ker so mediji/dokumenti ter profili/težave ločeni nabori |
| `intranet.GetProductStock` | pozicije po skladiščih + pravilo min/max |
| `intranet.GetProductOrigin` | izvedeno v migraciji 100; zadnje strani `raw.Inbox` in zapis izluščenih vrednosti za ta izdelek |

Poleg tega indeksi, brez katerih filtri niso izvedljivi: `canon.Product (OrganizationId, EAN)`,
`(OrganizationId, Manufacturer)`, `(OrganizationId, Supplier)`, `(OrganizationId, ValidationStatus)
INCLUDE (ItemID, Completeness)`, `canon.ProductText (ProductId, TextType, Lang)`.
Vsak indeks se doda z izmerjenim razlogom (plan pred in po), ne na slepo.

### 6.2 Migracija 096 — zapisovalni model za polja v lasti PIM

`intranet.SaveProductText`, `SaveProductCategory`, `SaveProductMedia`, `SaveProductAttribute`,
`SetProductWebPublish` — vse z `@Actor`, vse skozi `pim.ProductChangeBatch` +
`pim.ProductFieldHistory` (obstoječi mehanizem sledenja), vse idempotentne in v transakciji.
Plus `intranet.UndoProductChange` in `intranet.UndoProductBatch` kot tanka ovoja nad `pim.Undo*`.

Vsaka od njih mora **zavrniti** polje, ki po `pim.FieldOwnership` ni v lasti PIM — z razumljivim
sporočilom, ne z izjemo strežnika.

---

## 7. Vrstni red dela

| Korak | Ozemlje | Vsebina | Dokaz |
|---|---|---|---|
| P1 | BAZA | migracija 095 (bralne procedure + indeksi) | migrator ×2 + `--verify` = 0; `EXEC` vsake procedure z izpisom vrstic; meritev seznama pred/po |
| P2 | INTRANET | nov seznam in nova kartica, **samo branje**; prepis obeh pogodbenih testov z zapisanim razlogom | `run_tests.ps1 -Filter F10` = 0, build 0/0, ročni klik skozi zavihke |
| P3 | BAZA | migracija 096 (zapisovalne poti + zavrnitev tujih polj) | pred/po vrstica za vsako proceduro; poskus pisanja v polje v lasti SAOP mora pasti |
| P4 | INTRANET | urejanje polj v lasti PIM, razveljavitev, prekrivka »čaka potrditev«, množična dejanja iz seznama | sprememba je vidna v `pim.ProductFieldHistory`; razveljavitev jo vrne; test preveri vloge |

P1+P2 sta uporabna sama zase: urednik dobi delovni seznam in celo kartico, brez enega samega
lažnega gumba.

---

## 8. Prompt za Codex

````text
KONTEKST

Delaš v repozitoriju NoviPIM. Preberi in upoštevaj AGENTS.md v celoti (posebej §2.1, §3, §4, §5,
§7, §8), docs/PRODUKTNI_MODEL_PIM.md §5, docs/INTRANET.md §6 in docs/NACRT_IZDELKI_INTRANET.md
(ta načrt). Stack: .NET 10, Blazor Server, MS SQL. Vmesnik je slovenski, vse notranje povezave so
base-relativne (aplikacija teče tudi pod IIS na /PIM).

NALOGA (korak P1 — ozemlje BAZA)

Napiši sql/migrations/095_ProductWorkbench.sql. Samo dodajanje, idempotentno, brez DROP/DELETE.

1. Indeksi na canon.Product in canon.ProductText po §6.1 tega načrta. Pred vsakim indeksom v
   komentar zapiši, katera poizvedba ga potrebuje.

2. intranet.SearchProducts s parametri:
   @OrganizationId int, @View nvarchar(40) = N'ALL', @Search nvarchar(200) = NULL,
   @Manufacturer nvarchar(200) = NULL, @Supplier nvarchar(200) = NULL,
   @ItemGroup nvarchar(100) = NULL, @Department nvarchar(100) = NULL,
   @CategoryTreeCode nvarchar(50) = NULL, @CategoryCode nvarchar(200) = NULL,
   @SourceCode nvarchar(100) = NULL, @MaxCompleteness decimal(5,2) = NULL,
   @HasMedia bit = NULL, @WebPublish bit = NULL, @IsActive bit = NULL, @IsPromoted bit = NULL,
   @ErpStatus nvarchar(30) = NULL, @WebStatus nvarchar(30) = NULL,
   @ChangedFromUtc datetime2(3) = NULL, @Sort nvarchar(40) = N'ItemID',
   @Language nvarchar(20) = NULL, @PriceList nvarchar(100) = NULL,
   @Skip int = 0, @Take int = 50
   Nabor 1 (vrstice): ProductId, ItemId, Name (WEB_TITLE izbranega jezika, sicer TITLE_ERP),
     Ean, ThumbnailUrl (canon.ProductMedia, najnižji SortOrder), Manufacturer, Supplier,
     ItemGroup, Department, Net + PriceList (privzeti ali @PriceList), StockQuantity in
     StockAsOfUtc (aktiven stock.Snapshot), ErpStatus, WebStatus, Completeness, IsActive,
     WebPublish, IsPromoted, OpenErrorCount, LastChangedUtc
     ErpStatus in WebStatus izpelji iz val.ProductValidationState prek val.ValidationProfile
     BlocksErp / BlocksWeb (migracija 047), NE iz canon.Product.ValidationStatus.
   Nabor 2: TotalCount
   Nabor 3: števila po pogledih ALL, TO_FIX, NO_MEDIA, NO_WEB_TITLE, NO_CATEGORY,
     NOT_PROMOTED, PENDING_SAOP — vsak s svojim pogojem iz §4.1 načrta.
   @Sort dovoli samo znane vrednosti (ItemID, Name, Completeness, LastChanged) in vsako
   preslikaj v fiksen ORDER BY — nobenega dinamičnega SQL-a iz uporabnikovega niza.

3. intranet.GetProductCard @OrganizationId int, @ProductId bigint, @Language nvarchar(20) = NULL
   12 naborov po tabeli v §5 tega načrta (glava, besedila, lastnosti, kategorije, mediji, cene,
   zaloga, trgovinski podatki, profili, težave, odhodna sporočila, zgodovina).
   Prekrivko čakajočih sprememb vzemi iz obstoječe intranet.GetPendingOverlay (089) — ne piši
   nove logike za isto stvar.

4. intranet.GetProductOrigin @OrganizationId int, @ProductId bigint
   Zadnje strani raw.Inbox in izluščene vrednosti (map.ExtractedValue), iz katerih ta izdelek
   izvira; brez PayloadXml (ta je na vhodni strani).

DOKAZ ZA P1
- migrator dvakrat zapored + --verify => izhod 0
- EXEC vsake procedure proti lokalni bazi PIM z izpisom števila vrstic po naboru
- meritev: intranet.SearchProducts brez filtrov in z najtežjo kombinacijo filtrov, čas izvedbe
  pred in po indeksih; številke prilepi v poročilo
- dotnet build PIM_Solution\PIM.sln => 0 napak
- docs/DATABASE.md in TASKBOARD.md posodobljena v istem commitu
- commit: feat(baza): bralni model delovne mize izdelkov (095)

PREPOVEDANO
- spreminjanje obstoječih migracij, DROP/DELETE/TRUNCATE
- dinamični SQL iz uporabnikovega vnosa
- karkoli v src/PIM.Intranet v tem commitu
````

Ko je P1 potrjen:

````text
NALOGA (korak P2 — ozemlje INTRANET, samo branje)

Predpogoj: migracija 095 je uporabljena in preverjena.

Prenovi /izdelki in /izdelki/{id} po docs/NACRT_IZDELKI_INTRANET.md §4 in §5. Ves dostop do
podatkov gre skozi nov Services/ProductWorkbenchService.cs, ki kliče izključno procedure
intranet.SearchProducts, intranet.GetProductCard in intranet.GetProductOrigin. Nobenega SQL-a v
.razor, preslikava stolpcev po IMENU.

SEZNAM /izdelki
- zavihki = shranjeni pogledi (Vsi, Za urediti, Brez slike, Brez spletnega naziva, Brez
  kategorije, Ni objavljen, Čaka SAOP), vsak s številom iz tretjega nabora procedure
- orodna vrstica po §4.2: iskanje + sestavljivi filtri; aktivni filtri kot odstranljivi čipi
- stolpci po §4.3, s sličico in nazivom; sortiranje samo po dovoljenih stolpcih
- STANJE SEZNAMA JE V QUERY STRINGU (pogled, iskanje, vsak filter, sort, stran). Osvežitev,
  deljena povezava in gumb "nazaj" morajo delovati.
- izbira preživi strani in filtre; izbira se NE prenaša skozi URL. Če obstaja kakršnakoli meja
  izbire, mora biti izpisana kot vidno sporočilo — tihega reza (danes Take(200)) ne sme biti.
- množična dejanja pripravi kot povezave na obstoječi tok /izvozi/mnozicno; ZAPISOVALNIH gumbov
  v tem koraku ne dodajaj.

KARTICA /izdelki/{id}
- hero z sličico, nazivom, šifro, EAN in čipi (Aktiven, Za splet, Objavljen, Status ERP,
  Status splet, Popolnost)
- 12 zavihkov po §5; prazen zavihek pokaže pošteno prazno stanje ("Izdelek nima medijev."),
  ne izgine
- vsako polje v zavihku Pregled nosi značko lastnika (PIM / SAOP / SHARED) iz podatkov, ne iz
  kode; polje s čakajočo odhodno spremembo dobi oznako "čaka potrditev" in stanje sporočila
- zavihek Izvor pokaže, iz katerega vira, teka in strani raw.Inbox podatek izvira, s povezavo na
  zajem/stran/{InboxId}
- povezave v kontekst: medije, cene, zalogo, kategorijo in profil, ki blokira

OBVEZNE OMEJITVE
- nobene izmišljene vrednosti; vsaka številka, naziv, cena in datum iz baze
- nobenega gumba, ki bi videti shranjeval — ta korak je izključno bralen
- skupni gradniki: PimPage, PimTable, PimState, PimPager, PimChip, PimStat, PimColumn, PimCrumb
- brez Bootstrap razredov (row, col, card, table, form-control, form-select, form-check, btn)
- dostopnost: caption, scope, role="alert" za napako, role="status" za nalaganje,
  role="progressbar" z aria-valuenow/min/max/label za popolnost, aria-labelledby na vsak sklop,
  skrita oznaka "Status: " na vsakem čipu, aria-hidden na okrasnih ikonah, :focus-visible
- organizacija vedno iz Data.GetCurrentOrganizationAsync(); vzorec "Async(2," je prepovedan
- brez HttpClient
- vsaka stran ima svoj .razor.css; brez <style> v .razor
- sličice: brez zunanjih zahtevkov, če URL ni dosegljiv — pokaži nadomestno CSS ploščico, nikoli
  zlomljene slike

POGODBENA TESTA — PREBERI POZORNO
PIM.F10.ProductsUxTests pina en zavihek in šest stolpcev, PIM.F10.ProductDetailUxTests pina dva
flag-čipa. Nova oblika ju nujno podre. NE odstranjuj trditev, da bi test šel skozi. Namesto tega:
1. posodobi pinana ŠTEVILA na novo obliko in ob vsakem zapiši komentar, zakaj se je pogodba
   spremenila in kdo je to odločil (ta načrt, §2.15);
2. ohrani VSE dostopnostne trditve nespremenjene;
3. dodaj nove trditve za novo obliko: vsak zavihek ima aria-controls na obstoječ panel, vsak
   filter ima <label for>, stanje seznama je v query stringu (išči uporabo NavigationManager z
   gradnjo naslova), sličica ima alt, prazna stanja obstajajo za vsak zavihek kartice;
4. v TASKBOARD.md in commit sporočilo zapiši, kateri trditvi sta se spremenili in zakaj.
Če presodiš, da je sprememba testa kršitev pravila, ustavi se in javi BLOKIRANO — ne ugibaj.

DOKAZ ZA P2
- scripts\run_tests.ps1 -Filter F10 => izhod 0
- dotnet build PIM_Solution\PIM.sln => 0 opozoril, 0 napak
- ročni zagon: naštej, katere zavihke in filtre si preizkusil in kaj si videl
- meritev: čas nalaganja seznama pri privzetem pogledu in pri najtežjem filtru
- docs/INTRANET.md (§2, §3, §7) in TASKBOARD.md posodobljena v istem commitu
- commit: feat(intranet): delovna miza izdelkov s shranjenimi pogledi in celo kartico
````

Koraka P3 (migracija 096) in P4 (urejanje, razveljavitev, prekrivka) se napišeta po istem vzorcu,
ko je P2 potrjen. Ključni stavek za P4: **polje brez zapisovalne poti nima gumba**, polje v lasti
SAOP pa gumb ima, a ta gumb naroči odhodno sporočilo in to tudi pove.

---

## 9. Česa ta načrt ne obljublja

- Nobenega urejanja polj v lasti SAOP mimo odhodne poti in odobritve.
- Nobenega grafa trendov popolnosti — zgodovinskega read modela za to ni.
- Nobenega upravljanja datotek medijev; `canon.ProductMedia` hrani samo `Url`, `Role` in
  `SortOrder`, zato je zavihek Mediji pregled povezav, dokler ne obstaja shramba.
- Nobenega »hitrega urejanja v tabeli« v prvem krogu; urejanje se zgodi na kartici, kjer je
  lastništvo polja vidno.
