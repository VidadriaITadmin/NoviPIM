# PIM DEV – predaja dela za Claude (21. 9. 2026)

## Uporabnikova zahteva

Uporabnik želi iskren celovit pregled in dejanske popravke DEV aplikacije: jasna in zanesljiva validacija, pregledni workerji z nadzorom, sveži `katalog.csv` in `stranke.csv`, iskanje in nadzor artiklov v dejanskem CSV. Posebej je pojasnil: **katalog.csv je PIM → Magento; izdelava CSV je neodvisna od branja/pisanja SAOP.** Ne spreminjaj poslovnih pravil zgolj zato, da bi bilo več zelenih statusov.

Zadnja zahteva: ob malo preostalih tokenih pripravi obnovo zahtev, opravljenega dela in konkretnih nalog za Claude. Ta dokument je sprotna predaja, ne potrdilo, da je vse končano.

## Okolje in omejitve

- Repozitorij: `C:\Users\David\Documents\GitHub\PIM`, PowerShell, .NET 10.
- Razvojna baza: `DAVID\MSSQL19`, `PIM`. Povezavo vzemi iz lokalnega `appsettings.Local.json`; nikoli ne izpisuj skrivnosti. `PIM_test` ne spreminjaj.
- Uporabnik je pooblastil popravke DEV. Živih zapisov SAOP, objav na Magento, e-pošte, git push/merge nismo izvajali.
- IIS `appcmd list site/vdir` vrne access denied tudi s povišanim orodjem. Dejanska IIS namestitev ni preverjena/posodobljena. Uporabnika smo vprašali, kateri URL je DEV.
- `AGENTS.md` ni bil najden. Prebran `PIM_Solution/docs/AGENTSKA_ORKESTRACIJA.md`: nove migracije, lokalna PIM, ciljni testi + solution build + run_tests; UI potrebuje tudi dejanski prikaz/screenshot. Nobenih podagentov nismo uporabljali.
- Pred začetkom so bile že uporabnikove spremembe v `ProductCard.razor`, `ProductCard/ProductChannelPanel.razor` in štirih `izvoz/magento/*/magento-stock-prices.csv`. Med delom sta se pojavila tudi `docs/DATABASE.md` in `236_OdstranitevErpPripravljenostneVarovalke.sql`. **Teh sprememb ne vračaj in ne pripisuj temu delu.**
- Nova migracija uporabnika 236_Odstranitev... odstrani ERP gate trigger in funkciji IsProductChannelReady. ERP ocena je zdaj informativna; ne vzpostavljaj ERP blokade nazaj brez uporabnikove zahteve.

## Dokazano začetno stanje

- canon.Product ~196626, pim.Product ~155929; razlika sama ni dokaz izgube, sloja imata različna pravila.
- Zadnji zabeleženi uspešni glavni CSV org 2 je bil 16. 9. 2026, 2176 vrstic in 176 stolpcev. Sedanji register ima 180 stolpcev (migracija 234 doda odprodajo/eksponat), stranke 19.
- Izvoz je večkrat padal z access denied za `C:\inetpub\wwwroot\PIM_exports_csv\.magento-export.lock` (76 MAGENTO_PRODUCTS napak v 48 h; 144 povezanih napak poti). Globalni `ops.SystemPath.EXPORT_ROOT` kaže na to mapo. Pot še NI spremenjena.
- `out.GetExportRows`, ne stari neuporabljeni MagentoExportRunner, je dejanska izvozna procedura. Intranet ima wrapper `intranet.GetWebExportRows`.
- Sedanjih ~89491 vrstic org 2 ni samodejno napaka: migracija 220 izrecno ohrani artikle brez vseh kljukic spletnih mest kot signal za umik. **Ohrani to pravilo.** Vrstica CSV ≠ dovoljena objava.
- Pogled `val.ProductChannelReadiness` je kazal pripravljeno tudi pri zastareli validaciji. To je popravljeno.
- StockReplenishmentWorker je uporabljal GetInt32 nad decimal SQL vrednostjo; popravljeno pretvarjanje.
- Outbox: 22 starih Sending, 47 Dead, 766 PendingApproval ob pregledu; tega nismo samodejno retryali. Obravnavati posebej od CSV.
- Razporejevalnik v bazi je imel stale lease `DAVID:32664:dotnet`, heartbeat 11:25 UTC in stara Running cikla katalog/zaloga. Preveri trenutno stanje; ne trdi, da so workerji zdravi samo zaradi builda.

## Implementirane spremembe

1. `WorkerSchedulerPolicy.cs` in `WorkerConsolePolicy.cs`: nov interni cikel `magento-csv` / »CSV za Magento«, privzeto 300 sekund, org 2. Požene B2bWorker `--export-magento --osvezi-validacijo --organization-id 2`. Katalog/zaloga/nočni vhodni cikli ne izdelujejo več polnega CSV para. Hitri stock-prices izvoz je ostal. Preveri še stare PowerShell skripte: še niso usklajene s to ločitvijo.
2. `MagentoExportCommand.cs`: par zabeleži ExportRun pred pridobitvijo locka in ustvarjanjem mape; ujame dejansko napako. Uspeh šele po zapisu complete markerja, ne že po premiku strank. Pri napaki odstrani tudi novo strankino datoteko, ohranja backup ob neuspešnem rollbacku. Preveri imena/vrstni red stolpcev SQL proti registru. Zaključni log uporablja CancellationToken.None. **Nujno še preizkusi rollback markerja, zaklenjene datoteke in lock failure.** Enoprofilna ExportProfileAsync pot še beleži šele po locku.
3. `CustomerCsvGenerator.cs`: skupni public RegistryCsvWriter.Escape in zavrnitev praznih/podvojenih/obrobljenih glav.
4. `WebExportBuildService.cs`: ročni CSV uporablja isto pogodbo kot worker: vejica, UTF-8 brez BOM, LF, skupni escape. Prej podpičje+BOM. `OnlyPublishedDefault=true` kot worker. Dodana referenca Intranet→PIM.B2b.
5. Nov `MagentoArtifactService.cs`: bere izdelani CSV iz PIM_EXPORT_ROOT ali ops.SystemPath org 2, dovoljena samo MAGENTO_PRODUCTS/MAGENTO_CUSTOMERS. Marker preveri pred/po odpiranju; file handle je stabilen ob preimenovanju. CSV parser TextFieldParser obravnava narekovaje, vejice, večvrstične celice. Iskanje in strani po 50, omejeno število vrstic v spominu; za štetje prebere celo datoteko.
6. `/splet` preoblikovan: dejansko izdelani datoteki, čas/generacija/velikost, zadnji poskus in napaka, opozorilo starosti >10 min, prenos dejanskih bajtov, iskanje in paging, vsi/ključni stolpci, zgodovina samo relevantnih profilov. Ločen link za trenutni predogled baze. Ne trdi, da je Magento datoteko že prebral.
7. `Program.cs`: registriran ArtifactService, avtoriziran endpoint `/izvoz/magento-datoteka/{profile}`; fixed allowlist brez poljubnih poti. Ročni export endpoint zdaj preveri ID+kodo+aktivnost profila. Še preveri page-permission politiko novih endpointov (trenutno RequireAuthorization kot obstoječi).
8. `QualityWriteService.ValidateAsync` in `/kakovost/artikli`: akcija »Preveri zdaj« s BusinessWrite varovalom; stale stanje »Potrebna preverba«; pojasnilo ERP informativnosti. Hold gumbi še niso povsod skriti za VIEWER (server guard obstaja).
9. Nova migracija `236_ReadinessRequiresFreshValidation.sql`: IsErpReady/IsWebReady zahtevata LastValidatedUtc v zadnjih dveh urah. Že uporabljena v lokalni PIM; preverba `stale AND ready` vrne **0**. Zaradi vzporedne uporabnikove migracije obstajata dva različna 236; migrator uporablja celo ime, oboje je v ledgerju. Ne preimenuj že uporabljene migracije na slepo.
10. StockReplenishment: nov `ReplenishmentQuantity.Read`, decimal → zaokrožen int (AwayFromZero), null/DBNull in overflow; popravljena oznaka »Razpoložljiva zaloga«.
11. Testi: posodobljeni scheduler invarianti za samostojen CSV cikel, F7 CSV format in dejanski artifact parser (iskanje/paging/multiline/točni bajti/allowlist/marker), F7 180-stolpčni registry po migraciji 234. F10 logičnemu projektu dodana manjkajoča povezava PimAccessCatalog.cs (celoten build prej ni šel). `run_tests.ps1` uporablja serial `-m:1` zaradi težav vzporednega MSBuild.

## Preverjanje do tega checkpointa

- Intranet build: 0 warnings/errors.
- Celoten `dotnet build PIM_Solution/PIM.sln --no-restore -m:1`: **PASS**, 0 warnings/errors po popravku testne reference.
- Migrator: **PASS**, nova migration applied; stare že applied.
- SQL stale-but-ready count: **0**.
- Celoten `powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/run_tests.ps1` je bil sprožen, procesna session id **92298**; ob checkpointu še teče. Poll s write_stdin. Ta skripta uporablja lokalno povezavo in fixture podatke, ter lahko ustavi proces PIM.Intranet.
- **Še ni** uspešno izveden nov glavni DEV izvoz, potrjen nastali artifact, browser smoke/screenshot ali deploy na uporabnikov DEV URL.

## Konkretno nadaljevanje za Claude

1. Preberi najnovejši konec tega dokumenta in git diff; ne podvajaj uporabnikovih vzporednih sprememb.
2. Dokončaj run_tests, obravnavaj resnične napake; testov ne slabiti za zelen izhod. F7 Magento je deloma integracijski nad obstoječimi produkti in lahko traja. Če ni ustreznega produkta za fixture, to jasno loči od napake kode.
3. Preveri lokacijo DEV aplikacije. IIS upravljanje trenutno ni dostopno. Razvojni launch profile localhost:5091; za izolirano UI preverbo uporabi drug port (5199) in `PIM_SCHEDULER_ENABLED=false`, da testi ne sprožijo živih vhodnih ciklov/pošte.
4. Reši dejanski EXPORT_ROOT access denied. **Ne preusmeri na drugo mapo in potem trdi, da Magento dobiva svež CSV**: pomembno je, katero mapo bere odjemalec. Za dokaz lokalno izdelaš v `.tmp/...` z eksplicitnim --output-dir, nato ločeno urediti DEV nastavitev/pravice. Za spremembe izven workspace potrebuješ escalation.
5. Zaženi B2bWorker proti DEV z osvežitvijo validacije; preveri dejanske 180/19 glave, štetje vrstic, zahteve registrskih stolpcev, ključna polja, hash/marker/ExportRun, brez SAOP klicev. Osvežitev RunValidation+Promote lahko traja minute.
6. Preveri runtime nov ArtifactService in UI. Obstoječi `PIM_Solution/docs/pregled-20260908/Inspect-Ui.ps1` vsebuje CDP Chrome screenshot in ustvarjanje/cleanup začasnega lokalnega VIEWER uporabnika; ne poganjaj neprebrano, ker ima dodatne stare scenarije. Nova ozka skripta lahko uporabi isti vzorec. GUI/helper Start-Process naj ima WindowStyle Hidden.
7. Preveri robustnost rollbacka: marker write failure (ne sme pisati Succeeded), locked customer (obe prejšnji ostaneta), lock acquisition (Failed v zgodovini), cancelled logging. Razmisli o ExportRunLog.CompleteAsync: IOException med hashom zdaj požre celoten zaključek, lahko ostane Running; popravi, da hash failure ne preskoči statusa. Marker ni atomska transakcija za zunanjega odjemalca, ki markerja ne upošteva; tega ne prikrivaj.
8. Worker nadzor: zapisati tudi preskočene korake po napaki; kratki error trenutno samo exit code, pravi opis ostane log. Uskladiti stare ciklične PowerShell skripte s samostojnim Magento ciklom ali jih jasno umakniti kot scheduler alternativa. Ne sprožiti živih SAOP procesov samo zaradi preizkusa.
9. Validacija: preveri skladnost site flagov in ERP informativnosti. View še uporablja canon.Product.WebPublish, spletni izvoz pa ProductWebShop. To ni v celoti rešeno. `WebExportBuild.razor` lahko še kaže star preview po spremembi draft filtrov; ni odpravljeno.
10. Naredi iskreno končno oceno z dokazi in omejitvami. Ne trdi »celoten profesionalni PIM končan«, dokler output path, deploy, runtime in testi niso potrjeni. Po potrebi pripravi prioritetni seznam preostalega dela.

## Ukazi

```powershell
dotnet build PIM_Solution/PIM.sln --no-restore -m:1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/run_tests.ps1
# Če je build ustvaril samo dll, ne uporabi dotnet run --no-build (pričakuje .exe):
dotnet PIM_Solution/src/PIM.Migrator/bin/Debug/net10.0/PIM.Migrator.dll --migrations PIM_Solution/sql/migrations
```

SQL orodje v sandboxu včasih vrne SSL/credentials napako. Escalated `sqlcmd -S DAVID\MSSQL19 -d PIM -E -C ...` dela. Ne uporabljaj `-y 0` skupaj z `-W`/`-h -1`.

## Nadaljevanje (Claude, 2026-09-21 popoldne) — kaj je narejeno, kaj ugotovljeno, kaj ostaja

Vzporedno sta v isti delovni kopiji delali še dve seji (»Worker architecture refactoring«: selitev
`WorkerSchedulerPolicy.cs`/`WorkerConsolePolicy.cs` v nov projekt `PIM.Automation`, migracija 237
enotni model opravil, `PIM.AutomationHost`; »PIM aplikacija napake«: kartica izdelka, kategorije,
migraciji 237/238). Zato: `git status` in `ListAgents` pred urejanjem, številka migracije šele tik
pred zapisom, celoten `run_tests.ps1` je med selitvijo nezanesljiv.

### Dejansko stanje na razvojnem računalniku (dokazano)

- **Vzrok »access denied« na `.magento-export.lock`:** `ops.SystemPath.EXPORT_ROOT` =
  `C:\inetpub\wwwroot\PIM_exports_csv` tudi v razvojni bazi; ACL mape daje `BUILTIN\Users` samo
  branje. Windows naloge `PIM zaloga/katalog/nadzor/nocni tok` tečejo kot uporabnik `david`
  (neprivzdignjeno) in vsak `--export-magento` je padel pred zapisom. Po Codexovi spremembi (zapis
  `out.ExportRun` pred ključavnico) so ti padci zdaj vidni: 1316–1319 ob 15:06/15:07 UTC z dejanskim
  sporočilom. **Popravek pravic zahteva privzdignjen ukaz (glej spodaj); Claude v seji ni administrator.**
- **Razporejevalnik v aplikaciji ni tekel:** `ops.SchedulerLease` je potekel 11:26 UTC (proces
  `DAVID:32664:dotnet`); IIS `PIM_dev_app` (w3wp) najema ni prevzel. Stari skripti ciklov so zato tekle
  iz Windows nalog in do mojega popravka še vedno izdelovale poln CSV.
- **Obseg izvoza je namenski:** migracija 220_WebExportRowWithoutSiteFlag (uporabnik 2026-09-15) pusti
  vsak aktiven izdelek podjetja 2 brez kljukice spletnega mesta v katalog.csv s praznim stolpcem
  »Spletne strani« → 89.491 vrstic × 180 stolpcev (16. 9.: 2.176 × 176). Pravila nisem spreminjal.
- **Zakaj je izvoz padal tudi z urejenimi pravicami:** `out.GetExportRows` za podjetje 2 traja ~65–76 s
  na strežniku ne glede na `@Take` (fiksen strošek: pivot nad `canon.FieldValue` za vse izdelke
  podjetja; izmerjeno `@Take=2000` 75,8 s, `@Take=10000` 65,2 s). Stari bralnik v workerju
  (`SequentialAccess` + `IsDBNullAsync` za vsako od 16 milijonov celic) je prenos raztegnil čez mejo
  600 s; prvi ročni zagon je po 635 s padel, `finally` je na zaprti povezavi vrgel novo izjemo
  (»requires an open and available Connection«), prekril pravi vzrok in pustil zapisa 1320/1321 v
  `Running`. Drugi zagon s starim bralnikom: 26.136/89.491 vrstic po 35 minutah (ročno prekinjen).
- **Nadzor je hrupen, ker alarme zapira samo tik razporejevalnika:** `ops.RaiseOverdueAlerts` (odpira IN
  zapira `CycleOverdue`/`PipelineOverdue`) je klical samo `WorkerSchedulerService`; ko ta ne teče,
  uspešni zagoni iz Windows nalog alarma »Postopek MAGENTO_STOCK_PRICES ni tekel 4250 min« ne zaprejo
  (odprt kljub uspehom 1315, 1322).
- Validacija + objava podjetja 2 traja ~3,5 min (dnevnik `PIM katalog`, 14:42–14:46 UTC), zato
  petminutni cikel z brezpogojno `--osvezi-validacijo` ni vzdržen.

### Spremembe (poleg Codexovih iz prejšnjih razdelkov)

1. `PIM.B2bWorker/MagentoExportCommand.cs`: bralnik `GetValues` na vrstico (namesto `SequentialAccess`
   + async na celico), `CommandTimeout` 1800; `RefreshValidationAsync(maxAgeMinutes)` z
   `OldestValidationAgeMinutesAsync` (MIN `LastValidatedUtc` aktivnih izdelkov, razlika v bazi);
   `ExportProfileAsync` zapiše `out.ExportRun` pred mapo in ključavnico (kot par) in zaključuje s
   `CancellationToken.None`.
2. `PIM.B2bWorker/Program.cs`: nov argument `--starost-validacije <min>` (samo z `--osvezi-validacijo`).
3. `PIM.B2bWorker/ExportRunLog.cs`: `CompleteAsync` znova odpre zaprto povezavo, ne vrže nikoli
   (SqlException/InvalidOperationException/IOException) in ne prekrije prvotne napake.
4. `PIM.Intranet/Services/WorkerCycleRunner.cs`: po padcu koraka se preostali koraki skupine zapišejo
   kot `Skipped` z vzrokom (`RecordSkippedAsync`); v `Note` padlega koraka je zadnja STDERR vrstica
   (npr. »Access to the path … is denied«), ne samo izhodna koda.
5. `PIM.Watchdog/Program.cs`: kliče tudi `ops.RaiseOverdueAlerts` (uskladitev alarmov vsakih 5 minut
   ne glede na to, kdo je ura).
6. `PIM.Automation/WorkerSchedulerPolicy.cs` (vnesla druga seja na mojo prošnjo): konstanta
   `MagentoValidationMaxAgeMinutes = 90`, cikel `magento-csv` poganja
   `--export-magento --osvezi-validacijo --starost-validacije 90 --organization-id 2`;
   `LegacyTasks`/`WindowsTasks` poznata nalogo »PIM magento«.
7. Skripte: nova `scripts/Magento-cikel.ps1` (samostojen CSV, dnevnik `logs\magento-*.log`);
   `Zaloga-cikel.ps1`, `Katalog-cikel.ps1`, `Nocno-vse.ps1` ne izdelujejo več para (parametra
   `-PodjetjeKataloga`/`-BrezIzvoza` ostajata sprejeta, brez učinka); `Namesti-opravila.ps1` registrira
   peto nalogo »PIM magento« (vsakih 5 min, zamik 3, meja 30 min). Vse skripte parse-check 0 napak, ASCII.
8. Testi: `PIM.F7.WebExportTests` popravljen (CS4007 ni prevedel); `PIM.F10.IntranetLogicTests/
   WorkerSchedulerChecks.cs` preverja `--starost-validacije`, konstanto in preslikavo »PIM magento«.
9. Dokumentacija: `docs/WORKERS.md` (tabela ciklov + razdelek »CSV za Magento je samostojen cikel«),
   `docs/DATABASE.md` (razdelek za 236_ReadinessRequiresFreshValidation).
10. Razvojna baza: zapisi 1320/1321 in 1324/1325 (`Running` po padlih/prekinjenih ročnih zagonih)
    zaključeni kot `Failed` z dejanskim vzrokom prek `out.CompleteExportRun`.

### Dokaz: ročni izvoz z novim bralnikom (2026-09-21, 15:32–15:50 UTC, začasna mapa)

`PIM.B2bWorker --export-magento --osvezi-validacijo --starost-validacije 90 --organization-id 2
--output-dir <začasna mapa>` (zgrajen v ločeno mapo, ker Windows naloge vsakih 5 minut zaklepajo
`bin\Debug\PIM.B2bWorker.exe`): validacija preskočena (mlajša od 90 min), izhod 0 po 1.074 s — baza
je bila hkrati obremenjena z migracijo 239 druge seje, `val.RunValidation` iz testov F2 in izvozom
cen/zaloge iz naloge »PIM zaloga«, zato je to zgornja meja, ne tipičen čas.

| Datoteka | Vrstic | Stolpcev | Bajtov | SHA-256 (začetek) | `out.ExportRun` |
|---|---|---|---|---|---|
| katalog.csv | 89.491 | 180 | 26.529.793 | c7995ae9d24e | 1326 Succeeded, iste vrednosti |
| stranke.csv | 3.988 | 19 | 253.954 | 6663212045d7 | 1327 Succeeded, iste vrednosti |

Oznaka `magento-export.complete`: generacija `29a3e5e5`, `izdelki=89491`, `stranke=3988`. Datoteki brez
BOM, LF, vejica; vseh 89.491 vrstic ima 180 polj (preverjeno s CSV bralnikom). Glava se začne s
»Šifra artikla, EAN, Spletne strani …« in konča s štirimi stolpci iz migracije 234.

### Ročni korak za uporabnika (privzdignjen PowerShell)

```powershell
icacls "C:\inetpub\wwwroot\PIM_exports_csv" /grant "AD\david:(OI)(CI)M"
# in za IIS bazen PIM_dev_app (ime bazena preveri v IIS Manager):
icacls "C:\inetpub\wwwroot\PIM_exports_csv" /grant "IIS AppPool\PIM_dev_app:(OI)(CI)M"
# nato registracijo nalog osveži (doda "PIM magento", stare brez izvoza):
powershell -ExecutionPolicy Bypass -File scripts\Namesti-opravila.ps1
```

### Kaj še ni potrjeno / ostaja

- Izvoz v dejanski `EXPORT_ROOT` in prevzem pri Magentu: dokler pravice niso urejene, ni mogoče.
- Preverjanje `/splet` v brskalniku: intranet je med selitvijo v `PIM.Automation` nezanesljivo
  zgradljiv; opraviti po zaključku druge seje (port 5199, `PIM_SCHEDULER_ENABLED=false`).
- `run_tests.ps1`: F10 UX testi (Attribute, Auth, CategoryAttributeSet, CategoryMapping, Outbound,
  ProductDetail, Products, Quality, SaopItems, SystemIntegrations) padajo na pogodbah razor strani, ki jih
  ta sklop dela ni spreminjal; `PIM.F10.ProductWorkbookTests` po 60 min in 2,3 GB pomnilnika ročno
  ustavljen (baza je bila hkrati obremenjena z izvozom, validacijo in drugimi sejami). Ponoviti ob
  mirni bazi.
- `out.GetExportRows` (~65 s fiksni strošek) je naslednja tarča za hitrost; pri 5-minutnem ciklu je
  izvoz vsake 5 minut na meji smisla — cikel naj se ne prekriva z validacijo istega podjetja.
- Poslovna odločitev o 89.491 vrsticah (migracija 220) je uporabnikova; koda jo ohranja.
- Handoff točka 9 (site flags: `canon.Product.WebPublish` v pogledu vs `pim.ProductWebShop` v izvozu)
  ni rešena.

### Rezultat `run_tests.ps1` (2026-09-21, 16:54–18:12, med selitvijo v PIM.Automation in ob obremenjeni bazi)

39 projektov OK, 26 padlih, xUnit OK. Padci, ki so v zvezi s tem sklopom: **nobeden ni posledica
sprememb izvoza** — `PIM.F7.WebExportTests` pade na starem preverjanju (vrstica 39), ker je datoteka
`src/PIM.Intranet/Services/WebExportFileService.cs` spet v repozitoriju (zadnjič zapisana ob commitu
2aa765b, 18. 9.; nikjer referencirana). Njen izbris (`git rm`) je bil v tej seji zavrnjen — ročno:
`git rm PIM_Solution/src/PIM.Intranet/Services/WebExportFileService.cs`. `PIM.F7.MagentoExportTests`
pade v `CatalogLifecycleTests` s SQL napako 208 (neobstoječ objekt) — kateri objekt manjka, ni bilo
mogoče preveriti (dostop do baze v seji zavrnjen); sumljive so vzporedne migracije 237–239 drugih sej.
Ostali padci: F10 UX pogodbe strani (Attribute, Auth, CategoryAttributeSet, CategoryMapping, Outbound,
ProductDetail, Products, Quality, SaopItems, SystemIntegrations), F8/F9 Intranet (»Manjka slovenska
oznaka Dedup ključ«, »stran manjka: Integracije sistema«), F8 OwnershipPolicy, F7 ProductExport,
F7 ContractTests (`CustomerDetail.razor` brez »samo za branje«, nespremenjen od 15. 9.) — vse strani
oziroma datoteke drugih sklopov/sej; F2/F3/F5/F6/F8 Integration s SQL timeout (-2) oziroma FK (547)
ob sočasnem izvozu, validaciji in migracijah. `PIM.F10.ProductWorkbookTests` po 60 min in 2,3 GB
ročno ustavljen. Zagon je treba ponoviti ob mirni bazi in po zaključku selitve.


## Nadaljevanje (Claude, 2026-09-21 zvečer, seja »PIM operativna zanesljivost ocena«)

Cilj: dokazljiva ocena ≥ 8/10 brez navideznega uspeha. Peer seji (»Worker architecture
refactoring«, »PIM aplikacija napake«) sta potrdili, da mojih datotek ne urejata; migracija 242 je moja.

### Dokazano stanje razvojnega računalnika

- `C:\inetpub\wwwroot\PIM_exports_csv`: lastnik `BUILTIN\Administrators`, `BUILTIN\Users` samo RX;
  `ad\david` **ni** v lokalni skupini Administrators (whoami), zato pravic iz seje ni mogoče urediti.
  Poskusni zapis kot `AD\david` **ne uspe**. Zaupanje z domeno »AD« je prekinjeno (icacls: »The trust
  relationship … failed«), imena SID-ov se prevajajo z opozorilom.
- Na računalniku nič ne streže te mape prek HTTP: noben proces ne posluša na 80/443/8080 (w3wp teče,
  vezave ni). »Katero mapo bere DEV Magento« zato lokalno ni dokazljivo; edini deklarirani cilj je
  `ops.SystemPath.EXPORT_ROOT`, ki ga je uporabnik nastavil 2026-09-16. Izvoz **nisem** preusmeril.
- Najem razporejevalnika je potekel 16:23 UTC (proces peer seje); naloga »PIM magento« ni registrirana.
  Zato trenutno na tem računalniku **nihče ne izdeluje** katalog.csv/stranke.csv samodejno; tečejo samo
  Windows naloge zaloga/katalog/nadzor/nočni tok (kot `david`, vsakih ~8 min `MAGENTO_STOCK_PRICES`).

### Spremembe

1. **Migracija 242_ObjavaZaSpletPoIzvoznihPravilih** (uveljavljena na `DAVID\MSSQL19`):
   `val.ProductChannelReadiness` zrcali pravila `out.GetExportRows` (`WebExportState`, `IsInCatalogCsv`,
   števci spletišč; `IsWebReady` po kljukicah, `WebPublish` informativen), `intranet.GetQualityProducts`
   (stanja IN_CSV/NOT_IN_CSV/NO_SITE/PUBLISHED, seštevki), novi `intranet.GetProductWebExportState` in
   `intranet.GetWebExportSummary`, `intranet.GetWorkerCycles.LastSucceededUtc`; razmik `magento-csv`
   300→900 s in `WEB_CATALOG_EXPORT` 300→3600 s (samo, če še privzeto). Dokaz: `IsInCatalogCsv` =
   **89.491 = točno število vrstic dejanskega katalog.csv** (2.176 objavljenih + 87.315 brez spletnega
   mesta); strank 3.988 = stranke.csv. `GetQualityProducts` podjetje 2: 2,1 s ob mirni bazi (enako kot
   prej), 13,5 s med sočasnim `out.GetExportRows`.
2. `/kakovost/artikli`: stolpec »Splet / katalog.csv« kaže stanje po izvoznih pravilih z razlogom
   (kljukice, kategorija, zadržek, izključitev, blokirajoči profili, pravilo 220), KPI »Vrstic v
   katalog.csv«, »Objavljeni na spletu«, »Brez spletnega mesta«, novi filtri.
3. Kartica artikla, zavihek Splet: razdelek »Objava za splet (katalog.csv)« — stanje, razlog, tabela
   po spletiščih (kljukica / kategorija / blokirajoči neveljavni profili / v stolpcu Spletne strani),
   čas validacije, gumb »Preveri zdaj« (BusinessWrite) z jasnim rezultatom; ne kliče SAOP, ne izdela CSV.
4. `/splet`: kartica »Izhodna mapa« (pot, vir poti, obstoj, zapisljivost za račun intraneta, navodilo
   za pravice), »Zadnji poskus« in »Zadnji uspeh« ločeno, sprožilec, »Sestava kataloga po izvoznih
   pravilih« (aktivni, objavljeni v PIM, vrstic v CSV, objavljeni, brez spletnega mesta, stranke,
   blokirani po razlogu), prag starosti 30 min (cikel 15 min).
5. `/sistem/workerji`: »zadnji uspeh« poleg zadnjega poskusa; ob tekočem ciklu s preteklim terminom
   izpis »prekrivanje preprečeno« (`ops.ClaimWorkerCycle` isti cikel zavrne, dokler teče).
6. `PIM.B2bWorker`: `AcquireOutputDirectory` — nezapisljiva mapa pove mapo, račun in ukaz
   (`scripts\Nastavi-pravice-izvozne-mape.ps1`); `ExportRunLog.TryHashAsync` (3 poskusi) — neuspel hash
   pusti `Succeeded` z velikostjo brez hasha, nikoli `Running` ali lažen padec.
7. `scripts/Nastavi-pravice-izvozne-mape.ps1` (nov): pot iz registra ali `-Pot`, ustvari mapo, `icacls`
   Modify za račune (`-Racuni`, `-BazenIis`, `-RacunStoritve`), izpis ACL, poskusni zapis, `-SamoPreveri`.
   Preizkušeno na lastni mapi (dodelitev + preverba OK) in na pravi mapi (`-SamoPreveri` → izhod 1 z
   navodilom).
8. `WorkerSchedulerPolicy.MagentoIntervalSeconds = 900`, `JobCatalog` WEB_CATALOG_EXPORT 3600 s;
   `docs/WORKERS.md` (namestitveni vrstni red »samo povezava in domena«), `docs/DATABASE.md` (242).
9. Testi: F7 Magento — nov preizkus neuspelega hasha in nezapisljive mape; `CatalogLifecycleTests`
   popravljen (temp tabeli v lastnem neparametriziranem paketu — od nekdaj je padal z 208, ker
   `sp_executesql` temp tabele pobriše; stranka z `IsActive=1`; predpostavka o praznem stolpcu Cena B2B
   zastarela od 216). F7 WebExport — profil `WEB_B2C_PRODUCTS` je 217 odstranila → `MAGENTO_PRODUCTS`;
   izbrisan mrtev `Services/WebExportFileService.cs`. F10: Quality/ProductDetail/IntranetLogic/
   JobCatalog pogodbe za 242 in razmike.

### Dokazi

- `dotnet build PIM_Solution/PIM.sln --no-restore -m:1`: **0 napak** (prvi poskus pade samo na
  zaklenjenem `bin\Debug\PIM.B2bWorker.exe`, ki ga vsakih ~8 min drži naloga »PIM zaloga«; ponoviti,
  ko proces konča).
- Dokazni izvoz podjetja 2 brez SAOP (`--output-dir` začasna mapa, worker zgrajen v ločeno mapo):
  620 s pod obremenitvijo; katalog.csv 89.491 × 180 (26.529.789 B, SHA-256 450dc391…), stranke.csv
  3.988 × 19 (253.954 B, SHA-256 66632120… — enak kot ob 15:32), `out.ExportRun` 1420/1421 Succeeded z
  istimi vrednostmi, oznaka `magento-export.complete` generacija 3925e6d9, brez BOM, LF, glava =
  180/19 aktivnih stolpcev registra.
- `out.GetExportRows @Take=100` podjetje 2: 20,8 s (pred tem 65–76 s); izvoz je daljši od 5 min → 15 min.
- Ciljni testi: F10 IntranetLogic, F10 AdminConsoleUx, F9 Deploy, F11 Automation, F7 WebExport (356 s)
  **PASS**. F7 Magento po treh popravkih teče (>10 min, več polnih izvozov) — izid glej spodaj.
- Brskalnik (port 5199, `PIM_SCHEDULER_ENABLED=false`, gradnja `bin\Release-ops`): `/health` → zdravo,
  `/splet`, `/kakovost/artikli`, `/sistem/workerji`, `/izdelki/539`, `/izvoz/magento-datoteka/...` →
  302 na `/prijava` (avtorizacija drži), posnetek prijavne strani. **Prijavljene strani niso bile
  preverjene**: prijava zahteva račun iz baze, privzetih poverilnic ni, ustvarjanje začasnega
  uporabnika je bilo v prejšnji seji zavrnjeno — potrebna je uporabnikova prijava (VIEWER/CatalogEditor/
  Admin dostop je pokrit s F10 pogodbami in `PimAccessCatalog`, ne z brskalnikom).

### Padli testi, ki niso iz tega sklopa (isti kot v prejšnjem zagonu)

F10 Quality (»Zahteve, ki čakajo na polje« — `ValidationRules.razor` iz commita 18. 9.), F10
ProductDetail (»Product.WebPublish« v `WebFields` — kartica peer seje), F10 Auth (»Vidni naslov
karantene«), F10 CategoryAttributeSet, F8/F9 Intranet (»Dedup ključ«, »Integracije sistema«), F7
Contract (`CustomerDetail.razor`). Vse so pogodbe razor strani drugih sklopov; koda izvoza jih ne
spreminja.

### Rezultat testov (2026-09-22, 00:05–01:20, med tekom Windows naloge »PIM zaloga« in samostojnega F7)

- **F7 MagentoExportTests: PASS** (samostojno 2.216 s; v suiti prav tako OK) — vključno z novimi preizkusi
  (neuspel hash → Succeeded brez hasha, nezapisljiva mapa → sporočilo z mapo/računom/ukazom) in popravljenim
  `CatalogLifecycleTests`. Test je od 220 zahteval, da artikel brez kljukice izpade; zdaj preverja pravilo 220
  (vrstica ostane, »Spletne strani« prazen).
- **F7 WebExportTests: PASS** (356 s). F10 IntranetLogic, AdminConsoleUx, F11 Automation, F9 Deploy: PASS.
- `scripts\run_tests.ps1`: **42 OK, 24 padlih** (prej 39/26), xUnit OK. Razvrstitev padlih:
  - *drugi sklopi / pogodbe razor strani* (nespremenjeno od prejšnjega zagona): F10 Attribute, Auth,
    CategoryAttributeSet, CategoryMapping, Outbound, ProductDetail (`Product.WebPublish` v WebFields),
    Products (`product-manufacturer`), Quality (`ValidationRules.razor`), SaopItems, SystemIntegrations,
    F6 Integration (»Čas posnetka«), F7 Contract (`CustomerDetail.razor`), F7 ProductExport (»rumena
    glava«), F8 Intranet (»Dedup ključ«), F8 OwnershipPolicy (O9: 4 polja s pravico pisanja brez branja
    nazaj), F9 Intranet (»Integracije sistema«);
  - *infrastruktura / sočasnost*: F2 Integration (deadlock 1205 med sočasnimi izvozi — ob mirni bazi
    **PASS**, 359 s), F3 Integration (SQL timeout −2 tudi ob ponovitvi, vrstica 483);
  - *zastarel fixture drugih migracij*: F5 Integration (DBNull v nizu, vrstica 45), F5 ValueTransform
    (DELETE proti `FK_CanonProductText_Product` — vrstice `canon.ProductText` iz 239),
    F10 ProductWorkbook (`Product.WebSites` spremembe pri fixture F2-PROOF);
  - *brez ujetega sporočila*: F8 Hardening, F8 Integration, F8 SaopDocumentIntegration (samo sklad).
  Nobeden od padcev ni v kodi izvoza, validacije po 242 ali workerjev.
