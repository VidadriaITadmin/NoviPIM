# PIM baza — operativna dokumentacija

## Namen in meja

Razvojna baza je izključno `PIM` na lokalni SQL instanci. `PIM_test` ni dovoljen za ta cikel. Vse spremembe sheme so samo v `PIM_Solution/sql/migrations`; ročne spremembe v SSMS niso dovoljene.

Povezava uporablja Windows Integrated Authentication, šifriranje in zaupan lokalni certifikat. Povezovalni niz ostane lokalna skrivnost (`PIM_CONNECTION_STRING` oziroma `appsettings.Local.json`) in se nikoli ne zapisuje v Git, dokumentacijo ali testne izpise.

## Model

| Shema | Vloga |
|---|---|
| `raw` | nespremenjeni zajeti payloadi in karantena |
| `map` | konfiguracija virov, XPath/preslikave, watermarki, staging sled |
| `canon` | virsko neodvisen kanonični katalog |
| `val` | validacijski profili, zahteve polj, težave in promocija |
| `pim` | potrjeni katalog in B2B domena |
| `stock` | landing, posnetki, pozicije in neusklajene zaloge |
| `out` | izvozni kontrakti in outbox |
| `ops` | teki cevovodov, heartbeat, watchdog, alarmi in dnevniki |
| `sec` | uporabniki, vloge in navigacija |
| `intranet` | bralne/zapisovalne procedure za UI |

Tok: `raw.Inbox` → `map.ExtractedValue` → `canon.*` → `val.*` → `pim.*` → CSV/outbox. `OrganizationId` je obvezen izolacijski ključ.

## Migracije

Trenutni paket zajema migracije 001–038. Migrator sledi `dbo.SchemaMigration` in preveri hash vsake že uporabljene datoteke. Nameščenih migracij se ne ureja; popravek je vedno nova številka.

### Varni postopek

V PowerShellu na cilju nastavi skrivnost lokalno, nato v korenu `PIM_Solution`:

```powershell
$env:PIM_CONNECTION_STRING = '<lokalno-nastavljen-povezovalni-niz>'
$env:PIM_MIGRATIONS_PATH = 'C:\PIM\Source\NoviPIM\PIM_Solution\sql\migrations'
pwsh -File .\deploy\Apply-Migrations.ps1
pwsh -File .\deploy\Apply-Migrations.ps1
pwsh -File .\deploy\Apply-Migrations.ps1 -VerifyOnly
```

Dokaz uspeha:
1. prvi zagon uporabi samo manjkajoče migracije;
2. drugi zagon ne spremeni ničesar;
3. `--verify` izpiše `Preverjanje F0–F10 baze je uspešno.`

Pred migracijami vedno naredi COPY_ONLY backup z `deploy/Backup-PIM.sql` in preveri `RESTORE VERIFYONLY`.

## Dokazni podatkovni cikli

- F3: SAOP fixture → raw → mapiranje → kanonični katalog → CSV.
- F5: NW XML → EAN obogatitev kategorije, medija in atributa → validacija → promocija → B2C CSV; test preveri karanteno, manjkajoče obvezne vrednosti, neveljavno ceno/DDV/datum in deduplikacijo.
- F6: NW CSV in Braytron XML zaloge → `stock.LandingRecord`/snapshot/position → intranet read model.
- F7: B2B kupci, pravila popustov in CSV.
- F8: outbox le proti lokalnemu `127.0.0.1` fixture; dedup, retry, dead, sent, verified in drift.
- F9: watchdog, alarmi, lease/recovery in intranet integracije.

## Meje in tveganja

- Nove worker/input poti se dodajajo prek `map.*` konfiguracije in ne prek novih virsko-specifičnih tabel.
- Živi SAOP write-back, produkcijski endpointi in `PIM_test` niso del razvojnega dokaza.
- Testna konfiguracija in testne sledi se ne brišejo neposredno, če so povezane z `map.ExtractedValue`; zgodovina je namenoma zaščitena s tujimi ključi.
- Če integracijski test preseže SQL timeout, najprej preveri aktivne zahteve/blokade; ne zvišuj timeouta kot nadomestek za diagnostiko.

## Sledenje spremembam izdelkov

Migracija `028_AddProductChangeTracking.sql` uvaja sledljivost na dejanskem skupnem zapisovalnem sloju tega projekta, `canon.Product` in `canon.ProductCommercial` (ta rešitev nima tabel `stg.ProductCore`/`stg.ProductCommercial`).

- `pim.FieldOwnership` je register 17 sledljivih polj in trenutnega lastnika (`PIM`, `SAOP`, `SHARED`). Lastništvo je podatek in se ne podvaja v triggerjih.
- `pim.ProductChangeBatch` združi več polj ene poslovne akcije pod en `BatchId`.
- `pim.ProductFieldHistory` hrani polje, staro/novo vrednost, vir, izvajalca, čas in posnetek lastnika ob spremembi.
- množična triggerja nad `canon.Product` in `canon.ProductCommercial` primerjata `inserted`/`deleted` NULL-varno; brez razlik ne ustvarita prazne zgodovine;
- `pim.SetChangeContext` / `pim.ClearChangeContext` nastavita vir, izvajalca, paket in opombo na isti SQL povezavi kot zapis. Manjkajoč kontekst se pošteno zapiše kot `NEZNANO`.

`SqlMappingPipeline` za XML/SAOP mapping že nastavi `XML_FEED`, connector in `RunId`, zato se bodo novi mapping zapisi v zgodovini označili z resničnim virom. Sledljivost za nove nepovezane zapisovalne poti je treba dodati na njihovo lastno SQL povezavo; ne sme se jim pripisati lažen vir.

Migracija `029_AddProductHistoryIntranetReadModel.sql` doda zgodovino kot četrti rezultatni nabor `intranet.GetProductDetail`. Migraciji `030` in `031` popravita vrstni red `ROWCOUNT_BIG()`/`SET NOCOUNT ON` v triggerjih; sicer SQL Server po `SET NOCOUNT ON` vidi nič vrstic in bi sled tiho preskočil.

Migracije 032–038 dodajo omejeni poslovni Ctrl+Z: `pim.UndoProductField` in `pim.UndoProductBatch`. Pot preveri, da trenutna vrednost še ustreza izbrani spremembi, zavrne ponovno razveljavitev, prazen batch in SAOP/SHARED polja. `TRY/CATCH` pri obeh procedurah ob napaki rollbacka transakcijo in počisti `SESSION_CONTEXT`, da neuspešni undo ne kontaminira izvora naslednjega zapisa na isti povezavi. Trenutno sta eksplicitno podprti samo PIM-lastni polji `Product.WebPublish` in `Product.IsActive`; za novo polje je potreben nov preverjen poslovni adapter in test. Paketni undo uporabi eno transakcijo in en nov skupni undo batch.

`tests/PIM.ChangeTracking.Integration` je xUnit integracijski test (ni console proof) in pokriva uspešen undo polja, redo/conflict blokadi, skupni batch undo, SAOP/SHARED ownership blokado, prazen batch in čiščenje session konteksta po uspehu.

Migracija 034 razširi množično sledljivost na `canon.ProductText`, `canon.ProductAttribute` in `canon.ProductMedia`. Vrednosti so omejene na prvih 400 znakov prek `CONVERT(nvarchar(400), ...)`; za tekste se v zgodovini hrani kvalifikator `TextType.Lang`, za atribut koda atributa in za medij `Role.SortOrder`.
