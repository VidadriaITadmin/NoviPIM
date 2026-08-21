# Načrt prilagodljivosti — koda naj ne odloča o vsebini

Zapisano: 2026-08-21. Eno mesto resnice za to preureditev.
Pravila veljajo iz [`AGENTS.md`](../AGENTS.md); ta dokument jih ne podvaja.

## Zakaj

Sistem je danes ~80 % prilagodljiv prek registrov v bazi. Ostanejo tri mesta,
kjer nov vir, nov stolpec ali nov cilj pomeni **spremembo programa**, ne
spremembo podatka.

| Kje | Danes | Kako mora biti |
|---|---|---|
| `SaopEndpoints.All` | 16 končnih točk je seznam v C# | vrstice `map.SourceEndpoint` (pot, koren XML, vrsta klica, ključ) |
| `MagentoProductSchema` | 215 stolpcev in preslikava indeks→koda je `switch` v C# | vrstice `out.ExportColumn` — tabela `out.ExportProfile` že obstaja in ima pravo obliko |
| `map.ProcessRawInbox` | 5 ciljnih tabel je trdo zapisanih, ugnezdeni kurzor | množična obdelava, cilj iz `TargetFieldCode` |

Tretja vrstica je hkrati tista, ki povzroča **8 artiklov/s** (~7 ur za 200.000).

## Vrstni red

Potrjeno 2026-08-21: **A3 → B4 → C7.** A3 in B4 sta končana; naslednji je C7. A3 odklene 200.000 artiklov, B4 naredi
izvoze prilagodljive brez kode, C7 zapre tri resnične manjke odhodne poti.

## A — ZAJEM

1. `map.SourceEndpoint` kot register končnih točk; `SaopEndpoints.All` postane
   privzeti seed, ne resnica. Swagger (461 poti) je vir za nove — dodaš vrstico,
   ne kode.
2. Preslikave za preostalih 13 entitet v `map.FieldMapping` (XML poti so v
   dokumentu `Povezave_virov_in_sistemov` že eksplicitne). Mejnik jih že varuje
   (2026-08-20), zato dodajanje ne izgubi zgodovine.
3. **[KONČANO 2026-08-21]** Prepis `map.ProcessRawInbox` na množično obdelavo —
   migracija `044_BulkProcessRawInbox.sql`. Merjeno pred/po z istim merilom:
   **9,1 → 1.747 zapisov/s** pri 2.000 zapisih (192×), **2.149/s** pri 20.000.
   Za 200.000 artiklov ~1,5 minute namesto ~6 ur. Podrobnosti in kaj se ni
   spremenilo: `TASKBOARD.md`, razdelek 7 v `ZAJEM-SAOP.md`.

## B — IZVOZ

4. **[KONČANO 2026-08-21]** Magento shema se je preselila iz C# v
   `out.ExportProfile` / `out.ExportColumn` — migracija
   `045_MagentoExportProfileRows.sql`, profila `MAGENTO_PRODUCTS` (215 vrstic) in
   `MAGENTO_CUSTOMERS` (19 vrstic). Nov spletni kanal je zdaj profil + vrstice;
   dokazano s testom, ki posadi profil, ki ga program ne pozna. Podrobnosti:
   `TASKBOARD.md`, razdelek 3.1 v `EXPORTS.md`.
5. Atributi in kategorije se napolnijo, ko steče NW/BT XML zajem — ne prej.
   (To je isti manjko, ki je danes na tabli pod BLOKIRANO: 162 atributnih
   stolpcev je praznih, ker v `map.FieldMapping` ni vrstic
   `ProductAttribute.<glava>`.)

## C — ODHODNA POT

6. Register SAOP zapisovalnih končnih točk (`Add/UpdateItemsGeneralData`,
   `Customers`, kasneje cene) → `TargetKind`. `out.OutboxMessage` obstaja,
   manjka le vezava na pot iz Swaggerja.
7. Trije resnični manjki proti `out.OutboxMessage`:
   - `ErrorClass` (O18 — poslovna zavrnitev ne sme porabiti poskusov),
   - status `Superseded` (3.B.2 — sicer lažni alarmi ob normalnem urejanju),
   - `SaopItemAssignment` (O19 — nova šifra po ADD ne sme sloneti samo na EAN).
8. Sedaj `out.OwnershipPolicy` iz stolpcev „Smer" in „Master" — vključno s
   pravilom O9: polje, ki ga ne beremo nazaj, ne sme biti zapisljivo.

## Odprto

- `PIM_Solution/docs/Povezave_virov_in_sistemov/` **ni** v Gitu in tam ostaja,
  dokler ne odločiš drugače: vsebuje notranji naslov strežnika SAOP. Ni geslo, je
  pa notranji podatek, `AGENTS.md` §5.5 pa pravi „nobene skrivnosti v
  repozitorij". Do tvoje odločitve ostane samo lokalno.
