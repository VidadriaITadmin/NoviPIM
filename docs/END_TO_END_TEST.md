# PIM end-to-end testni protokol

Izvajaj po vrstnem redu. Vsak korak označi PASS/FAIL/SKIP z dokazom. `SKIP` je dovoljen samo za živ zunanji sistem, ki ni del lokalnega fixture scenarija; ne označi ga kot PASS.

## Predpogoji

- Baza: samo `PIM`.
- `PIM_CONNECTION_STRING` je nastavljen lokalno in se ne izpisuje.
- Zunanji endpointi, živ SAOP write-back, webhooki in produkcijska dostava so izključeni.
- Delovni imenik: `PIM_Solution`.

```powershell
$env:PIM_CONNECTION_STRING = '<lokalno-nastavljen-povezovalni-niz>'
$env:PIM_MIGRATIONS_PATH = 'C:\Users\David\Namizje\PIM\NoviPIM\PIM_Solution\sql\migrations'
```

> Pot je bila prej `C:\PIM\Source\NoviPIM\...`. To je kazalo na staro kopijo
> repozitorija, ki je zdaj v `..\_arhiv\`. Na tem računalniku je delovni
> repozitorij `C:\Users\David\Namizje\PIM\NoviPIM`.

## 1. Baza in zgradba

1. `dotnet build .\PIM.sln --no-restore`
   - PASS: 0 errors; zapiši tudi opozorila.
2. `dotnet run --project .\src\PIM.Migrator\PIM.Migrator.csproj -- --verify`
   - PASS: `Preverjanje F0–F10 baze je uspešno.`
3. Migrator brez `--verify`, nato še enkrat brez `--verify`.
   - PASS: drugi zagon ne uporabi nove migracije.

STOP ob failu migracije ali builda.

> Korak `npm test` je odstranjen. Node scaffold je arhiviran, ker je poganjal en
> izmišljen test (`2+3=5`) in vedno uspel — dajal je lažno zeleno.

## 2. Unit, behavior in pogodbeni testi

Iz **korena repozitorija** (ne iz `PIM_Solution`):

```powershell
scripts\run_tests.ps1
```

PASS: `REZULTAT: VSE OK`, izhod 0, **0 preskočenih**. Preskočen projekt ni
dokaz — pomeni, da povezava do baze ni bila na voljo.

> Prej je bila tu ročna zanka `Get-ChildItem .\tests\*\*.csproj | dotnet run`.
> Ta ne deluje: konzolni testi računajo poti do `workers\` relativno na trenutno
> mapo, zato padejo, če jih ne zaženeš iz njihove lastne mape. Zaganjalnik to
> uredi in poleg tega poda `PIM_CONNECTION_STRING`, ki ga testi iz svoje mape
> sicer ne najdejo.

Pričakuj posebej:
- F3/F5: konfiguracijsko vodeno mapiranje, karantena, validacija/promocija in CSV.
- F6: fixture datoteke NW=2697 in BT=1361; realni stock read model.
- F7: B2B pravila in vsi trije CSV izhodi.
- F8: lokalni HTTP fixture, dedup/retry/dead/sent/verified/drift; noben zunanji klic.
- F9: watchdog, alarmi, lease/recovery in integracijski read model.
- F10: auth + UX pogodbe za vse intranetne strani.

Če test preseže SQL timeout: najprej z `sys.dm_exec_requests` preveri blokade/čakanje; ne spreminjaj timeouta in ne ponavljaj slepo.

## 3. Fixture pipeline dokaz

1. F3 SAOP catalog fixture:
   - PASS: `raw.Inbox`, mapiranje, pipeline RunId `Succeeded`, CSV vsebuje vrstice.
2. F5 NW XML:
   - PASS: EAN obogati kategorijo, medij in atribut; neveljavne vrednosti so `Quarantined`; veljaven izdelek gre v `pim` in B2C CSV.
3. F6 zaloge:
   - PASS: NW in BT fixture števci; `/zaloge` vrača realno vrstico.
4. F7 B2B:
   - PASS: kupci, B2B produkti in shipping CSV so ustvarjeni v začasni lokalni mapi ter preverjeni.

## 4. Outbox / export meja

1. F8 integration uporabi samo izolirano organizacijo in `127.0.0.1` HTTP listener.
2. PASS: test dokaže dedup, retry, dead, sent, verified, drift, lease recovery in sočasnost.
3. PASS: izvozna datoteka nastane lokalno; ni FTP/HTTP/Magento dostave.
4. SKIP: živ SAOP write-back, dokler niso potrjeni testni endpoint, payload pogodba, testni artikel, skrivnosti, neodvisni pregled in izrecna odobritev.

## 5. Intranet runtime smoke test

Prvo okno:

```powershell
$env:ASPNETCORE_URLS = 'http://127.0.0.1:5088'
dotnet run --project .\src\PIM.Intranet\PIM.Intranet.csproj
```

Drugo okno:

```powershell
Invoke-WebRequest http://127.0.0.1:5088/health -UseBasicParsing
```

PASS, če je HTTP 200 in `stanje: zdravo`.

V brskalniku preveri po prijavi z lokalnim testnim uporabnikom:
1. `/nadzorna-plosca`: podatkovne KPI brez statičnih lažnih številk.
2. `/izdelki`: strežniško iskanje/status in paginacija; odpri obstoječo kartico izdelka.
3. `/zaloge`: količina, prihod, vir, posodobitev/status; nič izmišljenih skladišč ali rezervacij.
4. `/napake-validacije` in `/karantena`: resnična prazna/napaka/podatkovna stanja.
5. `/teki-obdelave`: realni pipeline teki.
6. `/outbound`: samo odobri/prekliči/ponovi testno outbox sporočilo; brez zagona živega dispatcherja.
7. `/system/integracije` kot ADMIN: Potrdi/Razreši testni alarm, preveri audit akterja in UTC čas.
8. Odjava, test VIEWER in ADMIN navigacije, tipkovnični fokus, konzola brskalnika brez 404 CSS/JS.

## 6. IIS smoke test (po lokalnem uspehu)

1. Publish script najprej z `-DryRun -WhatIf`.
2. Dejanski publish samo na laptop testni site.
3. PASS: `https://localhost/health` vrne 200.
4. PASS: `/PIM/prijava` (virtualna aplikacija) ima CSS in base-relative navigacijo.
5. FAIL: health ni 200; preveri samodejni rollback in ne nadaljuj z workerji.

## 7. Končno poročilo

Za vsak korak zapiši ukaz, čas, rezultat, RunId/HTTP status in varno anonimiziran dokaz. Posebej razdeli:
- uspešno avtomatizirano;
- uspešno ročno;
- SKIP zaradi izključenega živega sistema;
- FAIL z vzrokom in naslednjim ukrepom.

Končni status je “pripravljen za lokalno/laptop predstavitev” samo, če build, migrator verify, fixture testi, lokalni outbox fixture in intranet health uspejo. “Pripravljen za produkcijo” zahteva ločeno odobritev za vsako zunanjo povezavo.
