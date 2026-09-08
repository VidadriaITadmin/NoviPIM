# PIM baza — operativna dokumentacija

## Namen in meja

Razvojna baza je izključno `PIM` na lokalni SQL instanci. `PIM_test` ni dovoljen za ta cikel. Vse spremembe sheme so samo v `PIM_Solution/sql/migrations`; ročne spremembe v SSMS niso dovoljene.

Povezava uporablja Windows Integrated Authentication, šifriranje in zaupan lokalni certifikat. Povezovalni niz ostane lokalna skrivnost (`PIM_CONNECTION_STRING` oziroma `appsettings.Local.json`) in se nikoli ne zapisuje v Git, dokumentacijo ali testne izpise.

## Lokalna konfiguracija povezave

Edina veljavna lokalna konfiguracija je korenska `appsettings.Local.json` (v korenu repozitorija, ob `AGENTS.md`). Intranet (`PIM.Intranet`) razrešuje povezavo po tej prednosti:

1. okoljska spremenljivka `PIM_CONNECTION_STRING`, če je nastavljena;
2. sicer `ConnectionStrings:Pim` iz korenske `appsettings.Local.json`.

Ta prednost velja dokazano za intranet. Drugi lokalni procesi (workerji, konzolni testi) niso nujno enaki — npr. `PIM.XmlFileWorker` bere pot iz trenutne mape, nekateri workerji uporabljajo samo okoljsko spremenljivko brez branja korenske datoteke. Pred sklepanjem o obnašanju posameznega procesa preveri njegovo kodo.

**Kako intranet najde korensko datoteko.** `Program.cs` ne sestavlja poti do korena s fiksnim številom `..` (to bi se podrlo takoj, ko se `ContentRootPath` spremeni — npr. po `dotnet publish`). Namesto tega `LocalSettingsLocator.FindRepositoryRootLocalSettingsPath` (`Services/LocalSettingsLocator.cs`) od `ContentRootPath` išče navzgor po nadrejenih mapah, dokler ne najde `PIM_Solution\PIM.sln`, kar zanesljivo označuje koren repozitorija ne glede na globino. To deluje enako, če intranet zaženemo iz korena repozitorija, iz `PIM_Solution\src\PIM.Intranet`, ali iz poljubno globoke `dotnet publish` izhodne mape, dokler je ta še vedno nekje pod repozitorijem. Če korena ne najde (prava objava izven repozitorija), iskanje vrne `null` in intranet korenske datoteke sploh ne poskusi naložiti — takrat velja samo `PIM_CONNECTION_STRING` oziroma `ConnectionStrings:Pim` iz objavljene `appsettings.json`/`appsettings.Production.json`.

Morebitne podrejene datoteke s pripono `.zastarelo` (npr. `PIM_Solution/appsettings.Local.json.zastarelo`, `PIM_Solution/src/PIM.Intranet/appsettings.Local.json.zastarelo`) so preimenovani ostanki prejšnje, podvojene konfiguracije. Niso v uporabi, se ne berejo in se ne commitajo.

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

### Slovar vrednosti in pretvorbe (migraciji 049 in 056)

Med `map.ExtractedValue` in `canon.*` stoji `map.ApplyValueTransforms`. Preslikava pove, **od kod** vrednost pride; te tri tabele povedo, **v kakšni obliki** pride v katalog.

| Tabela | Vloga |
|---|---|
| `map.FieldTransform` | koraki nad eno preslikavo: `TRIM`, `NUMBER`, `UNIT`, `PREFIX`, `STRIPPREFIX`, `BOOL`, `UPPER`, `LOWER`, `LOOKUP` |
| `map.ValueLookup` | slovar vrednosti; `Domain` je koda lastnosti, `'*'` pomeni »velja povsod« in ožja domena ga premaga |
| `map.MissingTranslation` | delovni seznam vrednosti, za katere prevoda še ni — ena vrstica na vrednost, ne na izdelek |

Zakaj obstajajo: isto lastnost dobavitelji pošiljajo različno. Nowodvorski loči vrednost in enoto v dve polji, Braytron ju stlači v en niz (`30 mm`); isti dobavitelj piše `CLASS II` in `Class I`; vsi pošiljajo angleško, predloga Magenta pa ima stolpce `ANG` in `SLO`. Brez tega sloja bi bil vsak nov dobavitelj sprememba programa.

Sledljivost: izvorna vrednost se prepiše v `map.ExtractedValue.RawValue` in tam ostane. Ponoven zagon iste vrstice ne pretvori dvakrat (obdela samo `RawValue IS NULL`).

Manjkajoč prevod ni napaka: vrednost gre naprej nespremenjena, zapiše se v `map.MissingTranslation`.

Začetna polnitev slovarja je `scripts\seed_prevodi_besede.sql` (ni migracija — podatki, ne shema). Dokaz je `tests\PIM.F5.ValueTransformTests`.

## Migracije

Trenutni paket zajema migracije 001–100. Migrator sledi `dbo.SchemaMigration` in preveri hash vsake že uporabljene datoteke. Nameščenih migracij se ne ureja; popravek je vedno nova številka.

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

## Bralni model kartice izdelka

Migracija `100_ProductCardReadModel.sql` doda izključno bralni proceduri:

- `intranet.GetProductCard` vrne 15 imenovanih naborov: glavo z ločenima statusoma ERP in
  splet, ključna polja z lastnikom, čakajočo prekrivko iz obstoječe
  `intranet.GetPendingOverlay`, besedila, lastnosti, kategorije, medije, dokumente, cene,
  zalogo, trgovinske podatke, validacijske profile, odprte težave, odhodna sporočila in
  zgodovino;
- `intranet.GetProductOrigin` pove, iz katerega `raw.Inbox` teka, strani in zapisa je bila
  izluščena identiteta izdelka. Povezuje po dejanski `map.ExtractedValue` identiteti in vedno
  ohrani mejo `OrganizationId`.

Meritev na razvojnem izdelku `NW.9072` (ProductId 5971, organizacija 2): kartica je vrnila
vseh 15 naborov v 81 ms; izvor 28 vrstic v 869 ms. Neposredno iskanje identitete nad
837.404 vrednostmi `Product.ItemID` je pred migracijo trajalo 415 ms. Poskus materializiranega
indeksa nad `nvarchar(max)` je bil zavrnjen kot nesorazmeren, ker je prekinil povezavo med
gradnjo; migracija zato ne spreminja `map.ExtractedValue` in ostane lahka ter aditivna.

## Žig seje (migracija 181)

Pregled 2026-09-08 (`docs/PREGLED_SISTEMA_IN_UX_2026-09-08.md`, ugotovitev **A3**) je pokazal, da
onemogočen račun ostane prijavljen: `IsEnabled` in vloge se preberejo samo ob prijavi, piškotek pa
velja še 14 dni. Dokaz je bil `DISABLED_ACCOUNT_COOKIE {"Status":200,"Path":"/izdelki"}`.

Migracija `181_LocalUserSecurityStamp.sql` doda:

- `sec.LocalUser.SecurityStamp uniqueidentifier NOT NULL DEFAULT NEWID()` — žig veljavnosti seje;
- sprožilec `sec.TR_LocalUser_SecurityStamp` (AFTER UPDATE) zavrti žig ob spremembi `IsEnabled`,
  `PasswordHash`, `AuthSource` ali `DomainIdentity`; sprememba prikaznega imena ali e-pošte žiga
  namenoma **ne** zavrti, ker ne spremeni ničesar, kar bi seja smela početi;
- sprožilec `sec.TR_LocalUserRole_SecurityStamp` (AFTER INSERT, DELETE) zavrti žig ob vsaki
  spremembi vlog, da odvzeta vloga velja takoj;
- `sec.GetUserSecurityState @UserName` vrne `UserName`, `DisplayName`, `IsEnabled`, `SecurityStamp`
  in vloge kot `STRING_AGG` — to je bralni model, ki ga intranet uporabi ob preverjanju piškotka.

Zakaj sprožilca in ne klic iz aplikacije: račun se v praksi izklopi tudi neposredno v bazi (tako je
bil narejen dokaz A3). Če bi žig obnavljala samo aplikacija, bi taka sprememba ostala neopažena.

Dokaz nad razvojno bazo `PIM`: prvi zagon migratorja `Uporabljena migracija:
181_LocalUserSecurityStamp.sql`, drugi `Preskočena že uporabljena migracija`, `--verify`
`Preverjanje F0–F10 baze je uspešno.` Ročna preverba nad začasnim računom `qa_stamp_probe`
(ustvarjen in pobrisan v istem skriptu): sprememba imena žiga ne zavrti, `IsEnabled = 0` ga zavrti,
dodana vloga ga zavrti; `sec.GetUserSecurityState` vrne `IsEnabled = 0` in vlogi `ADMIN,VIEWER`.
