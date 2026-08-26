# ERP validacijska pravila — kaj je narobe

Merjeno 2026-08-26 nad bazo `PIM` (migracija 099). Vprašanje uporabnika: »povej, kaj je razlika
med temi ERP pravili, ker se mi zdi, da je napačno sestavljeno.«

**Je. Trije od štirih očitkov so dokazljivi iz same vsebine registra.**

## Kaj kateri profil zahteva

| Profil | Obseg | Blokira ERP | Blokira splet | Zahteva |
|---|---|---|---|---|
| `SHARED_CORE` | SHARED | ✅ | ✅ | ItemID, EAN |
| `ERP_L1` | **LEGACY** | ❌ | ❌ | AccountingGroup, DiscountGroup, EAN, ItemID, Manufacturer, Supplier, UoM, VatRate, TITLE_ERP.sl |
| `ERP_L1_SLO` | ERP | ✅ | ❌ | AccountingGroup, DiscountGroup, **IsActive**, Manufacturer, Supplier, UoM, TITLE_ERP.sl |
| `ERP_L1_EU` | ERP | ✅ | ❌ | CountryOfOrigin, CustomsTariff, GrossWeight, NetWeight |
| `ERP_L1_THIRD` | ERP | ✅ | ❌ | CountryOfOrigin, CustomsTariff, GrossWeight, NetWeight |
| `COMMERCIAL_L2` | COMMERCIAL | ❌ | ❌ | teh istih 4 + Volume, Pak1, Pak2, dolžina/širina/višina paketa |

## Napaka 1 — EU in TRETJE DRŽAVE sta dobesedno ista profila

Oba zahtevata **natanko iste štiri** vrednosti. Nobene razlike ni. Zato imata tudi enako število
veljavnih izdelkov pri vseh štirih podjetjih:

| | DEMO | IQLighting | Vidadria | Ediito |
|---|---|---|---|---|
| `ERP_L1_EU` | 5.500 | 43.466 | 12.315 | 35.757 |
| `ERP_L1_THIRD` | 5.500 | 43.466 | 12.315 | 35.757 |
| `COMMERCIAL_L2` | 5.500 | 43.466 | 12.315 | 35.757 |

Trije profili, tri identične številke. Delitev na EU in tretje države torej danes ne nosi nobene
informacije — obstaja v imenu, ne v pravilu.

**Poslovno pa razlika je**: pri izvozu v tretje države sta carinska tarifa in poreklo obvezna za
carinsko deklaracijo, znotraj EU pa gre za Intrastat in prag poročanja. Če se ta razlika ne
zapiše, profila nista dva — je eden z dvema imenoma.

## Napaka 2 — »SLO« profil nima nič slovenskega

`ERP_L1_SLO` zahteva sedem polj, ki so vsa splošna (šifranti, dobavitelj, enota mere, naziv).
Nobeno ni vezano na slovenski trg. Hkrati **ne zahteva stopnje DDV**, čeprav jo `ERP_L1` zahteva —
za domači trg je to najbolj slovensko polje od vseh.

Zahteva pa `Product.IsActive`. To je zastavica, ne podatek: vrednost »ne« je prav tako izpolnjena
vrednost, zato zahteva »mora biti izpolnjeno« pri njej ne pomeni nič.

## Napaka 3 — vstopnica za objavo je profil, ki po lastni nastavitvi ne blokira

`val.Promote` ima privzeti parameter `@ValidationProfileCode = N'ERP_L1'`. Ta profil ima
`Scope = LEGACY` in **`BlocksErp = 0`, `BlocksWeb = 0`** — torej je označen kot star in kot tak,
ki ne blokira ničesar, pa vendar odloča, kateri izdelek gre v objavo. Danes objavi **89.129**
izdelkov; po `ERP_L1_SLO` bi jih bilo **156.131**.

Ob tem `ERP_L1` podvaja `SHARED_CORE`: EAN in ItemID zahtevata oba.

## Kako bi moralo biti sestavljeno

Po tvojem lastnem opisu — »ERP validacija je level ena, ta se pa deli na ERP SLO in EU/tretje« —
je pravilna oblika **jedro plus dodatki**, ne štirje samostojni profili:

```
SHARED_CORE      identiteta: ItemID, EAN                    blokira vse
   └── ERP_L1    skupno za vse trge: šifranti, dobavitelj,   blokira ERP
                 enota mere, DDV, ERP naziv
         ├── ERP_L1_SLO     kar je obvezno samo doma
         ├── ERP_L1_EU      Intrastat: poreklo, tarifa, teža
         └── ERP_L1_THIRD   carina: poreklo, tarifa, teža + kar carina zahteva več
COMMERCIAL_L2    mere, volumen, pakiranje                    ne blokira
```

Vsak dodatek pove **samo razliko** glede na jedro; danes vsak ponavlja jedro ali pa je prazen.

## Kaj rabim od tebe, da to popravim

Trije odgovori, vsak je nekaj vrstic registra:

1. **Kaj je res obvezno samo za Slovenijo** in ne za EU (če nič, se `ERP_L1_SLO` ukine in ostane
   samo `ERP_L1`).
2. **Kaj EU zahteva več kot tretje države ali obratno** — sicer profila združim v enega.
3. **Ali gre DDV v jedro** (`ERP_L1`), kar bi pomenilo, da je obvezen za vse trge.

Dokler to ni odločeno, vstopnice za objavo ne preklapljam: sprememba iz `ERP_L1` v `ERP_L1_SLO`
objavi 67.000 izdelkov več, in to mora biti odločitev, ne stranski učinek čiščenja.
