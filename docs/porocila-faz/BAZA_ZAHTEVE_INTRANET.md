# Kaj potrebuje intranet iz baze

Zapisano: 2026-08-27. Stanje migracij ob pisanju: **104**.

Ta dokument je pogodba za bralne vrzeli, ki jih intranet pokaže s komponento `PimMissing`.
Ne predlaga nove poslovne resnice v uporabniškem vmesniku; ta mora nastati v bazi ali v
cevovodu in šele nato napolniti že pripravljene poglede.

## 1. Manjkajoče procedure bralnega modela

| Predlagano ime | Stran | Kaj mora vrniti | Iz katerih tabel | Brez tega |
|---|---|---|---|---|
| `intranet.GetPriceChecks` | `/preverbe`, `/cene`, kartica izdelka | Ena vrstica na `(OrganizationId, ProductId, CheckCode, PriceList)`: šifra in naziv izdelka, koda preverbe, razlaga, čas opažanja, prodajna in prevzemna cena, faktor ter potrjenost merske osnove; drugi nabor je natančen `COUNT_BIG`. | `canon.Product`, `canon.ProductPrice`, `out.ExportPriceList`, `canon.ProductCommercial` in novi šifrant preverb/pragov | KPI kažejo `—`, seznam preverb je prazen, prevzemna cena in faktor nista prikazana. |
| `intranet.GetStockChecks` | `/preverbe`, kartica izdelka | Ena vrstica na `(OrganizationId, ProductId, CheckCode, WarehouseCode)`: količina, prihod, min/max, svežina in razlaga; drugi nabor je natančen `COUNT_BIG`. | `stock.Snapshot`, `stock.Position`, `stock.UnmatchedPosition`, `canon.ProductStockPolicy` | KPI kažejo `—`, zalogovnih preverb ni. |
| `intranet.GetProductLinks` | `/nastavitve/povezave-izdelkov` | Pare izdelkov vrste `VARIANT`, `SIMILAR`, `RELATED`, vlogo, skupino, vodilnega člana, vrstni red, vir in revizijske podatke; za oba izdelka tudi glavni medij; drugi nabor je skupno število. | Nova `pim.ProductLink`, `canon.Product`, `canon.ProductMedia` | Vsi trije razdelki so prazni in stran ostane samo pogodba. |
| `intranet.GetAttributeValues` | `/nastavitve/atributi`, `/nastavitve/atributi/{koda}` | Različne vrednosti atributa, `COUNT(DISTINCT ProductId)`, prevod, izvorni konektor, uporaba v spletnem profilu in število manjkajočih prevodov; drugi nabor je skupno število. | `canon.ProductAttribute`, `map.FieldMapping`, `map.SourceConnector`, `map.ValueLookup`, `map.MissingTranslation`, `out.ExportColumn` | Podrobnost atributa je prazna; vir, prevod in spletna uporaba na seznamu so `—`. |
| `intranet.GetExportPreview` | `/izvozi/profili/{id}` | Prvih največ 20 vrstic z dejanskimi izhodnimi glavami iz profila in popolnoma isto projekcijo kot datoteka workerja. | `out.ExportProfile`, `out.ExportColumn` in skupna projekcija `PIM.B2bWorker` | Predogleda ni; intranet namenoma ne podvaja izvozne logike. |
| `intranet.GetWebExportDeliveries` | `/splet` | Čas, profil, število vrstic, velikost, rezultat in cilj vsake izdelave/dostave spletne datoteke. | Trajni dokaz, ki ga po izdelavi zapiše `PIM.B2bWorker` in dostavni transport | Zgodovina dostav je prazna. |
| `intranet.GetCategoryTranslations` | `/nastavitve/kategorije` | Kategorije izbranega spletnega mesta z imenom v jeziku mesta, neposrednim in dedupliciranim številom izdelkov s podkategorijami ter stanjem preslikave poti. | `canon.WebSite`, `canon.Category`, `canon.CategoryTranslation`, `canon.ProductCategory`, `map.CategoryPathMap` | Prevod je `—`; neposredne povezave na posamezno preslikavo poti ni. |

Vse procedure morajo obvezno sprejeti `@OrganizationId`, kjer vrnejo podatke izdelkov.
Stranjenje se izvede v SQL-u; vsota ni `Rows.Count`, temveč ločen natančen nabor.

## 2. Manjkajoče tabele

### `pim.ProductLink`

Predlagana oblika:

| Stolpec | Tip / pravilo |
|---|---|
| `ProductLinkId` | `bigint identity`, primarni ključ |
| `OrganizationId` | `int NOT NULL`, tuji ključ na organizacijo in obvezni izolacijski ključ |
| `ProductId`, `LinkedProductId` | `bigint NOT NULL`, tuja ključa na `canon.Product`; oba izdelka morata biti iz iste organizacije |
| `LinkType` | `nvarchar(20) NOT NULL`: `VARIANT`, `SIMILAR`, `RELATED` |
| `LinkRole` | `nvarchar(40) NULL`: pribor, rezervni del, razlikovalni atribut ipd. |
| `GroupKey` | `nvarchar(100) NULL`, skupina variant |
| `IsPrimary` | `bit NOT NULL`, vodilni izdelek variante |
| `SortOrder` | `int NOT NULL` |
| `Source` | `nvarchar(40) NOT NULL`: `MANUAL`, `FEED`, `DERIVED` |
| `CreatedBy`, `CreatedUtc` | obvezna revizijska podatka |

Unikatnost: `(OrganizationId, ProductId, LinkedProductId, LinkType)`. `OrganizationId` je
potreben, ker sistem hrani štiri kataloge in par ne sme nikoli prečkati organizacijske meje.
Kdo tabelo polni, je odprta poslovna odločitev v §6. Če je ni, `/nastavitve/povezave-izdelkov`
ostane varen bralni osnutek brez gumbov za urejanje.

### Šifrant poslovnih preverb in pragov

Enum `PimCheckCode` je začasna pogodba za 12 šifer, ne trajni šifrant. Potrebni sta najmanj:

- definicija preverbe (`CheckCode`, opis, področje `PRICE`/`STOCK`, aktivnost);
- nastavitev po `OrganizationId` in po potrebi kategoriji (`ThresholdKind`, decimalna
  vrednost, veljavnost, merska osnova, revizijska polja).

Privzeti faktor `2,00` je do nastanka registra izrecno prikazan kot privzet. Organizacijski
ključ prepreči, da bi cenik ali prag enega podjetja postal pravilo drugega.

## 3. Manjkajoči stolpci ali nabori v obstoječih bralnih modelih

| Objekt | Manjka | Za kaj ga stran potrebuje | Od kod bi prišel |
|---|---|---|---|
| `intranet.GetProductCard` | čas zajema in izvor na ravni posameznega polja; ERP DDV, planiranje/rezervacija, knjigovodske šifre; komercialni kosi v paketu in nabavni podatki | Stolpca »Vir« in »Svežina« ter celotna kanalska tabela brez opombe »ni v bralnem modelu« | `map.ExtractedValue`, `raw.Inbox`, `canon.ProductPlanning`, `canon.ProductStockAccounting`, `canon.Codebook`, razširjeni `canon.ProductCommercial` |
| `intranet.GetOutboundMessages` | odobritelj, čas odobritve, čas pošiljanja, stara in nova poslana vrednost, `VerifiedUtc`; ločen nabor poskusov | `/saop/zgodovina` in razširitev operacije v poskuse | `out.OutboxMessage`, `out.OutboxAttempt`, `out.OutboundBatch` |
| `intranet.GetOutboundMessages` | strukturiran nespremenljiv posnetek dejansko poslanih polj in strukturiran echo iz SAOP | `/saop/odkloni`; drift se mora primerjati s poslanim posnetkom, ne s trenutnim PIM | odhodni payload/posnetek, `ops.OutboundEvent` in povratni SAOP zajem |
| `intranet.GetWritableSaopFields` | lastnik polja in dokaz, da je isto polje vključeno v povratno branje | `/saop/polja`: »varno za pisanje« je dovoljeno šele, ko je potrjeno branje nazaj | `pim.FieldOwnership`, `out.OwnershipPolicy`, `out.SaopXmlField`, vhodne preslikave |

Dokler teh podatkov ni, `Sent` ostaja rumen »poslano, nepotrjeno«; zelen je samo `Verified`
oziroma drug dokazano potrjen uspeh.

## 4. Manjkajoči ali še nepotrjeni poslovni podatki

- Register `out.ExportPriceList` obstaja, vendar privzeti vrstici `B2B`/`B2C` ne določata
  prevzemnega cenika. Za vsako organizacijo je treba poslovno označiti cenik PRC oziroma
  drug dejanski prevzemni cenik. Identiteta je vedno `(OrganizationId, PriceListCode)`.
- Za faktor je treba potrditi primerljivost merske osnove prodajne in prevzemne cene.
  Nepotrjen faktor je lahko prikazan z opozorilom, ne sme pa v KPI »pod pragom«.
- `canon.ProductStockPolicy` z `MinimumStock` in `MaximumStock` obstaja od migracije 076 in
  se lahko uporabi za `ZALOGA_POD_MIN`; manjka dogovor, kako ravnati, ko je prag `NULL` ali
  za skladišče ni vrstice.
- Za spletne datoteke manjka trajen dokaz izdelave in dostave (vrstice, velikost, cilj,
  rezultat). Brez njega UI ne sme sestaviti navidezne zgodovine iz trenutnega stanja profila.

## 5. Zahteve za cevovod, ne za bazo

1. Za Nowodvorski naj preslikava medija dobi korak `PREFIX` v `map.FieldTransform`, ki naslovu
   `//pim.nowodvorski.com/...` trajno doda `https:`. UI normalizira le prikaz; kanonična in
   izvožena vrednost sicer ostaneta brez sheme.
2. Worker za poslovne preverbe mora periodično izvesti cenovne in zalogovne preverbe ter
   ustvarjati alarma `PRICE_CHECK` in `STOCK_CHECK` prek obstoječega `ops.UpsertAlert`.
   Dostava ostane obstoječa `ops.Alert` → `ops.AlertDelivery` → `ops.AlertRecipientConfig`.
3. `PIM.B2bWorker` mora po izdelavi in po dostavi spletne datoteke zapisati trajen dokaz, iz
   katerega bo bral `intranet.GetWebExportDeliveries`.
4. Echo obdelava SAOP mora `Verified` ali `Drift` izračunati proti posnetku dejansko poslane
   vrednosti. Primerjava s pozneje spremenjeno trenutno vrednostjo PIM je napačna.

## 6. Odprta vprašanja za uporabnika

1. **Ali je povezava »podobni« usmerjena?** Brez odgovora ni mogoče določiti, ali `A → B`
   samodejno pomeni tudi `B → A`. Brez odločitve se shrani le izrecno podana smer.
2. **Ali variante nosi vodilni izdelek ali ločena skupina?** Odgovor določi pomen `GroupKey`
   in omejitev `IsPrimary`. Brez odločitve UI ostane samo bralen.
3. **Kdo ustvarja povezave izdelkov?** Določiti je treba, ali so dovoljeni `MANUAL`,
   dobaviteljski `FEED` in/ali `DERIVED`. Brez odgovora se ne odpre zapisovalna pot.
4. **Kateri cenik je prevzemni po organizaciji in kategoriji?** Brez odgovora se faktor ne
   izračuna; šifra `PRC` se ne sme privzeti za vsa podjetja.
5. **Kateri prag faktorja velja po organizaciji/kategoriji?** Do odgovora je `2,00` samo vidno
   označena privzeta vrednost.
6. **Kako obravnavati manjkajoči min/max?** Brez odgovora `NULL` pomeni »ni pravila« in ne
   ničelnega praga; preverba `ZALOGA_POD_MIN` se za tako vrstico ne sproži.

## 7. Kaj deluje že danes

- Kartica izdelka se napolni iz `intranet.GetProductCard` in `intranet.GetProductOrigin`:
  identiteta, tri kanalske skupine, dejanski mediji in dokumenti, cene, zaloga, validacija,
  SAOP stanje, zgodovina in izvor.
- `/mediji` bere dejanske `canon.ProductMedia`; varno prikaže HTTP/HTTPS, opozori na HTTP in
  za naslov `//...` pri prikazu doda `https:`.
- `/kakovost`, `/kakovost/napake` in `/pravila/validacija` berejo obstoječe profile, zahteve
  in težave ter jih z enim razvrščevalnikom delijo v `ERP_SLO`, `ERP_EU/THIRD`, `KOMERCIALA`
  in `SPLET`. Števci uporabljajo različne izdelke.
- `/saop` in `/outbound` bereta obstoječo odhodno vrsto in izvajata obstoječe auditirane
  postopke odobritve, preklica in ponovitve. `Sent` ni prikazan kot potrjeno stanje.
- `/splet` uporablja `intranet.GetExportReadiness`, registre profilov/stolpcev in isti
  izračun spletne validacijske vrzeli kot `/kakovost`.
- `/nastavitve/kategorije` bere dejanska drevesa, spletna mesta in deduplicirano število
  izdelkov neposredno ter s podkategorijami; obstoječi pregledi atributov, kanalov, jezikov in
  skladišč ostajajo vezani na aktivno organizacijo, kjer je to del podatkovnega modela.
