# Rezultati testiranja vseh vej

Datum: 2026-09-08. Okolje: lokalna razvojna baza `PIM`; živi SAOP samo branje;
lokalni CSV; brez SAOP `--send` in brez dostave v Magento.

## Povzetek

| Veja | Rezultat | Dokaz |
|---|---|---|
| Build | PASS | vsi ciljni zagoni so prišli skozi `Build OK` |
| Živi SAOP org. 2 | PASS | 165 prebranih, 165 uspešnih, 0 padlih |
| F3 SAOP katalog | DELNO | 3/4 PASS; DB integracija SQL timeout |
| F5 XML | DELNO | 5/6 PASS; DB integracija SQL timeout |
| F6 zaloge | PASS | 6/6 |
| F7 splet/B2B | FAIL | 6/7; star `WebExportFileService.cs` še obstaja |
| F8 SAOP outbound | PASS lokalno | 12/12; samo lokalni fixture |
| F9 nadzor | PASS avtomatsko | 6/6 |
| F10 intranet | PASS avtomatsko | 16/16 |
| Hitri spletni CSV | PASS | 2.071 vrstic, 14 stolpcev |
| Polni spletni CSV | FAIL SAFE | manjka obvezni `WEB_TITLE.sl` |
| En SAOP primer | PRIPRAVLJEN V UI | `0.S.LGD500`, org. 1, batch 143 |
| Živi SAOP write-back | NI IZVEDEN | nič ni bilo poslano |

Celoten sistem danes ni zelen, čeprav živo SAOP branje deluje, F6/F8/F9/F10 pa imajo zelene
ciljne pakete.

## Živi SAOP read-only test

Izveden je bil omejen delta zajem `GetItemsGeneralData` za organizacijo 2, ena stran do 1000
zapisov, zaporednost 1. Rezultat v `ops.PipelineRun`:

| RunId | Status | Read | Succeeded | Failed |
|---|---:|---:|---:|---:|
| `9172937E-73F2-4C26-8F43-433EEE449B45` | Succeeded | 165 | 165 | 0 |

`ops.IntegrationHealth` za `SAOP_PRODUCTS`, org. 2, je `Healthy` (heartbeat
2026-09-08 08:18:33 UTC). Druge organizacije niso bile klicane in ostajajo s starim statusom
`Failed`; rezultat org. 2 ni dokaz za vse štiri.

Pred tem je merilni zagon s stranjo velikosti 1 prebral in preslikal eno vrstico, a je bil
pravilno označen `Failed`: polna zadnja dovoljena stran ne dokazuje, da naslednje ni. To ni bil
padec SAOP povezave.

## Avtomatski paketi

### F3 — SAOP katalog

`scripts\run_tests.ps1 -Filter F3`: Behavior, Contract in SaopClient PASS;
`PIM.F3.Integration` FAIL z `Execution Timeout Expired`. Živi zagon je ločeno dokazal pravi
SAOP → RAW → mapping tok, avtomatski F3 paket pa ostaja rdeč.

### F5 — XML dobaviteljev

`scripts\run_tests.ps1 -Filter F5`: AttributeDiscovery, Behavior, CategoryMapping, Contract in
ValueTransform PASS; `PIM.F5.Integration` FAIL s SQL timeoutom na vrstici 37. Parserji,
pogodbe in transformacije so zeleni, skupni DB integracijski dokaz v tem zagonu ni.

### F6 — zaloge

`scripts\run_tests.ps1 -Filter F6`: 6 uspešnih, 0 preskočenih, 0 padlih,
`REZULTAT: VSE OK`.

### F7 — splet in B2B

`scripts\run_tests.ps1 -Filter F7`: 6 uspešnih, 0 preskočenih, 1 padec.
`PIM.F7.WebExportTests` zahteva odstranitev starega datotečnega branja, vendar
`src/PIM.Intranet/Services/WebExportFileService.cs` še obstaja in vsebuje `File.ReadLines`.
Test ni bil spremenjen. Brisanje datoteke ni bilo izvedeno.

### F8 — povratna pot SAOP

`scripts\run_tests.ps1 -Filter F8`: 12 uspešnih, 0 preskočenih, 0 padlih,
`REZULTAT: VSE OK`. Lokalno so dokazani priprava, ownership, dokument, XML, dispatcher, retry,
echo, hardening in UI. To ni živi SAOP klic.

### F9 — nadzor

`scripts\run_tests.ps1 -Filter F9`: 6/6 PASS, `REZULTAT: VSE OK`.

### F10 — intranet

`scripts\run_tests.ps1 -Filter F10`: 16/16 PASS, `REZULTAT: VSE OK`.

## Dejanski spletni izvoz

### Hitri profil — PASS

Datoteka: `izvoz/qa-20260908/magento_stock_prices_org2_20260908.csv`

| Kontrola | Rezultat |
|---|---:|
| vrstice podatkov | 2.071 |
| stolpci | 14 |
| prazna šifra | 0 |
| prazen EAN | 0 |
| velikost | 119.465 B |
| SHA-256 | `A55F025AFEB986212982272AC9F78E44264FD6D8C4691A0D6352C72FCA035B0D` |
| UTF-8 BOM | ne |

CSV uporablja vejico. Ni bil dostavljen Magentu.

### Polni `WEB_B2C_PRODUCTS` — FAIL SAFE

Izvoz se je ustavil z:

```text
PIM.B2b.ExportContractException: Obvezna vrednost ProductText.WEB_TITLE.sl je prazna.
```

Zaščita je preprečila nastanek lažno uspešnega polnega kataloga. Izbor objavljenih/veljavnih
izdelkov očitno vključuje najmanj eno vrstico brez zahtevanega slovenskega spletnega naslova.

## En primer za povratni SAOP

V vrsti že obstaja en artikel, zato nov dvojnik ni bil ustvarjen:

| Podatek | Vrednost |
|---|---|
| organizacija | 1 |
| artikel | `0.S.LGD500` |
| batch | 143 |
| cilj/operacija | `SAOP_PRODUCT` / UPDATE |
| stanje | 14 × `PendingApproval`, 1 × `Dead` |

Suhi zagon `--saop-documents --org 1 --max 1` je vrnil 0 dokumentov, ker spremembe še čakajo
odobritev. Izpis je potrdil, da ni bilo nič poslano in se baza ni spremenila.

### Kaj preveriš v spletnem pogledu

1. Na `/saop` ali `/saop/zgodovina` poišči `0.S.LGD500` oziroma batch `143`.
2. Preglej 15 polj; posebej `ProductCommercial.DimensionUnit`, ki je `Dead`.
3. Odobri samo pravilne vrednosti.
4. Pred živim pošiljanjem ponovno pripravi suhi XML in zahtevaj `nepopolnih: 0`.
5. Šele nato se ločeno odloči za živi `--send` in spremljaj odgovor ter echo.

## Operativno zdravstveno stanje

- `SAOP_PRODUCTS` org. 2: `Healthy`;
- `SAOP_PRODUCTS` org. 1, 3 in 4: star `Failed`;
- `SAOP_STOCK` org. 1–4: `Failed` z dne 2026-09-07;
- `GENERIC_XML` org. 1–4: `Healthy`, zadnji heartbeat 2026-09-04.

F9 testna logika je zelena, dejanski zunanji teki pa niso vsi zdravi ali sveži.

## Ni bilo izvedeno

- pravi FTP/HTTPS prevzem;
- SAOP read za org. 1, 3 in 4;
- živi SAOP write-back;
- dostava CSV v Magento;
- prava e-pošta/webhook;
- brisanje starega `WebExportFileService.cs`;
- sprememba testov ali timeoutov.

## Sklep

Branje iz SAOP za organizacijo 2 deluje. Zaloge, lokalna outbound pot, nadzor in intranet imajo
zelene ciljne pakete. Za trditev »vse veje delujejo« je treba odpraviti F3/F5 SQL timeoute,
stari F7 datotečni servis ter manjkajoči obvezni spletni naslov v polnem izvozu.
