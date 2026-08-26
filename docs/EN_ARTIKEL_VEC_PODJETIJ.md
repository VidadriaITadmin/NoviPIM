# En artikel na spletu, več podjetij v bazi

Vprašanje uporabnika 2026-08-26: v tabelah ločujemo po podjetjih, na svetila.si in videlektro pa
mora biti **en artikel**, čeprav obstaja v več podjetjih. Podjetja ostanejo zaradi računov in
prodaje.

Merjeno 2026-08-26 nad bazo `PIM`.

## Rešitev že obstaja — v vašem starem sistemu

Stari izvoz (`PIM_test`, `products_web.csv`) to reši v desetih vrsticah:

```sql
CREATE TABLE #CatalogOrg (OrganizationId INT, PickPriority INT);
INSERT #CatalogOrg VALUES (2, 1), (3, 2);      -- IQL pred VID

PickRn = ROW_NUMBER() OVER (PARTITION BY a.ItemID
                            ORDER BY catOrg.PickPriority, a.UpdatedAtUtc DESC, a.ProductCoreId DESC)
... WHERE PickRn = 1
```

Trije koraki, vsak pomemben:

1. **Ključ artikla za splet je `ItemID`, ne `(OrganizationId, ItemID)`.** Podjetje ni del
   identitete izdelka, ampak lastnost zapisa o njem.
2. **Ob podvojitvi zmaga podjetje z nižjo prioriteto**, ob izenačenju novejši zapis. Prioriteta
   je vrstica registra, ne pravilo v kodi.
3. **Zaloga in dobavni roki pridejo iz enega izbranega podjetja** (`@StockOrganizationId`),
   ločeno od kataloga. Zato je mogoče brati opis in cene iz IQL, zalogo pa iz VID.

## Ali predpostavka drži tudi pri nas

| Meritev | Vrednost |
|---|---|
| aktivnih vrstic v `canon.Product` (po podjetjih) | 177.635 |
| različnih šifer `ItemID` | **116.742** |
| šifra obstaja v več kot enem podjetju | **52.077** (44.918 v dveh, 5.502 v treh, 1.657 v štirih) |

Torej: združevanje po šifri stisne 177.635 vrstic na 116.742 artiklov. To je natanko tisto, kar
splet potrebuje.

**Ali ista šifra res pomeni isti artikel?** Da, v 99,8 %:

| | |
|---|---|
| EAN se ujema ali ga ni | **51.978** |
| **EAN se razlikuje** | **99** |

Teh 99 ni napaka združevanja, ampak podatek, ki ga je treba pogledati: ista šifra, dva različna
EAN. Ne smejo se združiti tiho — sodijo na delovni seznam.

## Past, ki jo je stari sistem že poznal

Pri 46.270 šifrah se **proizvajalec razlikuje** med podjetji. To ni protislovje: proizvajalec je
shranjen kot **šifra, lokalna za podjetje**. Stari sistem ima zato register z dvema stolpcema —
`ManufacturerCodeIQL` in `ManufacturerCodeVID` — in izvoz iz njiju sestavi eno ime:

```sql
WHERE UPPER(mf.ManufacturerCodeVID) = UPPER(cp.ManufacturerCode)
   OR UPPER(mf.ManufacturerCodeIQL) = UPPER(cp.ManufacturerCode)
```

Isto velja za dobavitelja. **Brez tega registra bi po združitvi vsak drugi artikel dobil
proizvajalca, ki je odvisen od tega, katero podjetje je zmagalo.** To je edini del rešitve, ki ga
v NoviPIM še ni.

## Predlog za NoviPIM

Trije registri in nobene nove logike v programu:

1. **`out.WebCatalogOrganization`** — katera podjetja sestavljajo spletni katalog in v kakšnem
   vrstnem redu. Ustreza `#CatalogOrg`.
2. **Podjetje za zalogo** kot lastnost izvoznega profila oziroma spletne strani — ustreza
   `@StockOrganizationId`. Katalog je združen, zaloga pride iz enega podjetja.
3. **`canon.ManufacturerAlias` in `canon.SupplierAlias`** — ena šifra na podjetje, eno ime.
   Brez tega združevanje pokvari proizvajalca pri 46.270 artiklih.

Ter **delovni seznam** za 99 šifer z različnim EAN, po istem vzorcu kot pri kategorijah in
prevodih: pokaži, ne odloči.

## Kaj se s tem spremeni pri validaciji

Danes se validira zapis po podjetjih. Ko splet dobi združen artikel, mora spletni profil
(`WEB_svetila_si`, `WEB_videlektro`) preverjati **združeni artikel**, ne posameznega zapisa —
sicer artikel pade zaradi manjkajoče slike v podjetju, ki na splet sploh ne gre.

ERP validacija ostane po podjetjih, ker ERP je po podjetjih. To je tudi razlog, zakaj sta
spletni in ERP profil ločena.

## Kaj rabim od tebe

1. **Vrstni red podjetij za katalog** — stari sistem ima IQL pred VID. Ali velja isto in kam
   sodita DEMO in Ediito?
2. **Iz katerega podjetja gre zaloga** za svetila.si in za videlektro.
3. **Kaj z 99 šiframi, kjer se EAN razlikuje** — jih pogledaš ti, ali naj zmaga isto podjetje kot
   pri katalogu?
