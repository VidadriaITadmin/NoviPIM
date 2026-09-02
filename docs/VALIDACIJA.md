# Validacija — profili, stopnja resnosti in obseg blokade

Zapisano 2026-08-21 po modelu, ki ga je določil naročnik (migracija
`047_ValidationProfilesSeverityAndScope.sql`). Vse, kar je tu opisano, so **vrstice v bazi**,
ne koda: nov profil ali nova zahteva sta `INSERT`, ne nova različica programa.

## Zakaj sploh

Do te migracije je bila obveznost polja zapisana na dveh mestih z isto besedo, a z zelo
različnim učinkom:

| Kje | Kaj v resnici pomeni |
|---|---|
| `map.FieldMapping.IsRequired` | **brez tega zapisa sploh ne bo** — `map.ProcessRawInbox` ga zavrne v celoti, skupaj s šifro, nazivom in EAN |
| `val.FieldRequirement.IsRequired` | polje manjka; artikel obstaja in je označen |

Izmerjeno na živem zajemu 2026-08-21: **15 od 183 artiklov (8,2 %) je izpadlo** in v vseh 15
primerih je manjkala samo skupina popusta. Pri 200.000 artiklih bi to pomenilo okrog 16.000
artiklov, ki jih v PIM sploh ne bi bilo.

Zato zdaj velja:

- **pri zajemu** je obvezna samo `Product.ItemID` — brez šifre zapisa ni mogoče niti nasloviti;
- **vse ostalo** je zahteva validacijskega profila, z lastno stopnjo resnosti in obsegom.

Skupina popusta torej ostaja obvezna — kot `ERROR` v profilu `ERP_L1_SLO`, ki blokira ERP.
Artikel obstaja, je viden, je označen kot neveljaven za ERP in se ne promovira.

## Profili

| Profil | Obseg | Blokira ERP | Blokira splet | Zahtev |
|---|---|---|---|---|
| `SHARED_CORE` | `SHARED` | da | da | 2 |
| `ERP_L1_SLO` | `ERP` | da | ne | 7 aktivnih + 2 čakata |
| `ERP_L1_EU` | `ERP` | da | ne | 4 |
| `ERP_L1_THIRD` | `ERP` | da | ne | 4 |
| `COMMERCIAL_L2` | `COMMERCIAL` | **ne** | **ne** | 6 aktivnih + 4 čakajo |
| `WEB_svetila_si` | `WEB` | ne | da | 9 |
| `WEB_videlektro` | `WEB` | ne | da | 9 |

`ERP_L1_EU` in `ERP_L1_THIRD` sta **dodatek** k `ERP_L1_SLO`, ne njegova zamenjava: artikel
za EU mora zadostiti obema.

`ERP_L1` in `WEB_B2C` ostajata. Izpeljana sta iz izvoznih profilov prek
`val.SyncFieldRequirementsFromExportProfiles`, uporablja ju `val.Promote` (privzeti profil je
`ERP_L1`) in ju preverja migrator. Njuna upokojitev je ločena odločitev.

## Stopnja resnosti

`val.FieldRequirement.Severity` je `ERROR` ali `WARNING`.

- **`ERROR`** — profil postane `INVALID`.
- **`WARNING`** — pomanjkljivost se zabeleži v `val.ProductIssue` in jo urednik vidi, profil
  pa ostane `VALID`.

Popolnost (`Completeness`) se šteje po **vseh** aktivnih zahtevah, ker meri polnost podatka,
ne blokade.

## Skupni status artikla

`canon.Product.ValidationStatus` posluša samo profile, ki kaj blokirajo
(`BlocksErp = 1` ali `BlocksWeb = 1`), in samo zahteve s stopnjo `ERROR`.

`COMMERCIAL_L2` je izrecno označen kot profil, ki ne blokira ničesar: njegove pomanjkljivosti
so vidne, artikla pa ne razglasijo za neveljavnega. Pred to migracijo je **vsak** aktiven
zapis pomanjkljivosti, katerekoli resnosti in kateregakoli profila, postavil `INVALID`.

## Kaj profil vidi

Validacija bere `canon.FieldValue` — pogled, ki katalog splošči v pare
`(FieldCode, Value)`. Migracija `047` mu je dodala polja, ki jih profili zahtevajo, sistem pa
jih prej ni videl: `Product.ItemGroup`, `Product.Department`, `Product.IsActive`,
`Product.WebPublish` in trgovinske podatke (`ProductCommercial.NetWeight`, `.GrossWeight`,
`.CustomsTariff`, `.CountryOfOrigin`, `.Pak1`, `.Pak2`).

`Product.IsActive` in `Product.WebPublish` sta `bit NOT NULL`, zato vrednost vedno obstaja in
zahteva zanju ne more sprožiti pomanjkljivosti. Vseeno sta zapisani, ker bi bil profil brez
njiju druga stvar kot dogovorjeni model.

## Zahteva z obsegom in nabor atributov po kategoriji (migraciji 146–148, 2026-09-03)

- `val.ValidationProfile.CategoryTreeCode` veže spletni profil na drevo (`WEB_svetila_si` →
  `svetila_si`, `WEB_videlektro` → `videlektro`). Spletni izvoz zahteva `VALID` v vseh profilih z
  `BlocksWeb = 1`, ki veljajo za stran (brez drevesa = vse strani).
- `val.FieldRequirement` ima obseg `CategoryTreeCode`, `CategoryCode`: zahteva brez obsega velja
  za vse izdelke profila (kot doslej), zahteva z obsegom samo za izdelke v tej kategoriji ali pod
  njo. Enoličnost je (profil, polje, drevo, kategorija).
- Register `canon.CategoryAttributeSet` (drevo, kategorija, koda atributa iz
  `canon.AttributeDefinition`, raven `REQUIRED` / `RECOMMENDED` / `EXCLUDED`) se deduje navzdol;
  najbližja vrstica zmaga, `EXCLUDED` pri otroku razveljavi `REQUIRED` pri staršu
  (`canon.CategoryAttributeEffective`). `canon.SaveCategoryAttributeSet` sam vzdržuje zahteve:
  REQUIRED → `ERROR`, RECOMMENDED → `WARNING`, EXCLUDED/odstranitev → zahteva ugasne. Polje
  zahteve je `ProductAttribute.<slovensko ime atributa>`, ker artikli nosijo ime, register kodo.
- `val.RunValidation` upošteva obseg pri napakah, stanju profila in statusu artikla. Vse, kar
  bere `val.ProductIssue` (`/kakovost`, kartica izdelka, pripravljenost izvoza), dela
  nespremenjeno. Urejanje: `/nastavitve/kategorije` → gumb **Atributi** pri kategoriji.
- Dokaz 2026-09-02: REQUIRED `GARANCIJA` na `notranja_svetila` → izdelek 541 (Viseča svetila,
  brez garancije) dobi `MISSING_REQUIRED_FIELD` `ERROR`, `WEB_svetila_si` postane `INVALID`; po
  odstranitvi iz nabora napaka ugasne.

## Devet zahtev, ki čakajo na polje

Te zahteve so zapisane z `IsActive = 0`, da je model viden v celoti in se vidi, kaj manjka.
Nobena od njih danes ne obstaja v `canon`:

| Profil | Zahteva | Kaj manjka |
|---|---|---|
| `ERP_L1_SLO` | `Product.PiecesInPackage` (WARNING) | število kosov v paketu (`ItemCustomProperty`) |
| `ERP_L1_SLO` | `Product.QtyReservationExcluded` | izločitev iz rezervacije (`ItemPlanningData`) |
| `COMMERCIAL_L2` | `ProductCommercial.Volume` | volumen na enoto |
| `COMMERCIAL_L2` | `ProductCommercial.PackageLength/Width/Height` | mere pakiranja; `canon.ProductCommercial` ima samo besedilno polje `Dimensions` |

Ko polje nastane, se zahteva prižge z enim `UPDATE`.

## Kaj je izmerjeno

Po prvem živem zajemu (org 2, 6.265 aktivnih artiklov):

| Profil | VALID | INVALID |
|---|---|---|
| `ERP_L1_SLO` | 5.474 | 791 |
| `SHARED_CORE` | 906 | 5.359 |
| `ERP_L1_EU` / `THIRD` | 0 | 6.265 |
| `COMMERCIAL_L2` | 0 | 6.265 |
| `WEB_svetila_si` / `WEB_videlektro` | 0 | 6.265 |

Branje: podatki za ERP so večinoma tu. `SHARED_CORE` pade na EAN (ima ga 906 artiklov).
`ERP_L1_EU`, `COMMERCIAL_L2` in oba spletna profila padejo, ker `canon.ProductCommercial`,
spletni nazivi, kategorije, cene in slike še niso zajeti — teh podatkov SAOP
`GetItemsGeneralData` ne prinese.
