# 🎛️ KAKO IMETI PIM POD KONTROLO KOT SOLO DEVELOPER
**David Planinšek | avgust 2026**
*Prilagojeno dejanskemu stanju repozitorija `PIM_test` — z orodji, ki jih res uporabljamo*

> Ta različica je predelava splošnega načrta. Vsak predlog je preverjen proti repozitoriju:
> kar že obstaja, je označeno kot **obstaja**, in namesto novega orodja je navedeno tisto,
> ki ga sistem že ima. Nova orodja se uvajajo samo tam, kjer resnično ni ničesar.

---

## 0. NAJPREJ — PREOKVIRJENJE PROBLEMA

> **"Imeti pod kontrolo" NE pomeni vedeti vse.**
> Pomeni: **sistem ti sam pove, kdaj je kaj narobe, in ti znaš to varno popraviti.**

Noben človek ne drži v glavi 325 tabel, 7 workerjev, 176 starih SQL skript in 69 strani intraneta. Razlika med teboj in seniorjem ni v tem, da on to ve na pamet — razlika je, da ima **sistem, ki mu pove**.

Trije stebri, in kje si pri vsakem **danes**:

| Steber | Kaj ti da | Stanje avgusta 2026 |
|--------|-----------|---------------------|
| **1. VIDLJIVOST** | Veš, kaj se dogaja, ne da bi gledal | 🟡 Ogrodje stoji (`ops.*`, Faza 0), a **ni na produkciji** in **ni na zaslonu** |
| **2. PONOVLJIVOST** | Vsako okolje lahko zgradiš iz nič | 🟡 Migracijski okvir dela (70 migracij), a **baze se še vedno ne da zgraditi iz kode** |
| **3. MAJHNI KORAKI** | Sprememba je testirana in povratna | 🟡 Migracije in primerjalniki so, **avtomatiziranih testov cevovoda ni** |
| **4. SLEDLJIVOST** | Za vsako vrednost veš, kdo jo je nazadnje spremenil | 🔴 Pokrita ena od šestih poti (glej Fazo 3.5) |

Četrti steber v prvotnem dokumentu ni obstajal. Dodan je, ker je vprašanje »kdo je težo spremenil s 1,5 na 1,8 kg« danes neodgovorljivo — in ker je to vprašanje, ki ga v praksi dobiš najpogosteje.

Nič ni na ničli. To je pomembno, ker prvotna ocena ("nimam ničesar") vodi v napačno prioriteto — v gradnjo tega, kar že stoji, namesto v **dokončanje** treh konkretnih vrzeli.

---

## 0.1 KAJ JE ŽE POSTAVLJENO (in kar torej ne gradiš znova)

| Področje | Kaj obstaja | Kje |
|---|---|---|
| Migracijski okvir | `ops.SchemaVersion`, checksum zaklep, ena migracija = ena transakcija, `-WhatIf` / `-Verify` / `-AllowProduction` | [`scripts/Invoke-PimMigrations.ps1`](../scripts/Invoke-PimMigrations.ps1), [`sql/migrations/README.md`](../sql/migrations/README.md) |
| Dnevniki | `ops.ErrorLog`, `ops.EventLog`, `usp_LogError`, `usp_LogEvent`, `usp_Heartbeat`, `usp_PurgeLogs` | migracija `0002` |
| Obveščanje | `ops.OutboundAlertQueue` z dušenjem + `usp_EnqueueAlert` + atomarni prevzem | migracija `0003` |
| Zaklep zagonov | `usp_TryAcquireRunLock` / `usp_ReleaseRunLock` nad `sp_getapplock`, `ops.vRunLockStatus` | migracija `0004` |
| Varovani zagoni | `ops.usp_Run_FullIngestion`, `usp_Run_DetectValidatePromote`, `usp_Run_OneOrgIngestion` | migracija `0005` |
| **Nadzornik molka** | `ops.HealthExpectation` + `usp_Watchdog_Check` + `ops.vSystemHealth`, 12 pričakovanj | migracija `0006` |
| Ozadje in obvestila | `ops.BackgroundJob`, `ops.UserNotification`, `ops.vJobQueue` | migracija `0011` |
| Pošiljanje alertov | prevzem iz vrste → webhook (Discord / Telegram / Generic), ponovni poskusi | [`scripts/Send-PimAlerts.ps1`](../scripts/Send-PimAlerts.ps1) |
| Testno okolje | COPY_ONLY backup → restore → SIMPLE → popravek uporabnikov | [`scripts/New-PimTestDatabase.ps1`](../scripts/New-PimTestDatabase.ps1) |
| Izhod kot podatek | `pim.OutputChannel` / `pim.OutputColumn` / `export.usp_BuildChannel` + **primerjalnik izhodov** | migracije `0007`, `0008`, `0101`–`0107` |

**Nadzornik je bistven detajl.** Ne čaka na napako — preverja **odsotnost pričakovanega signala** (`EVENTLOG` / `INGEST` / `TABLE` / `AGENTJOB`). To je bila prava odločitev, ker deluje takoj, brez sprememb v .NET workerjih. Napake vidiš; molk je tisto, kar te ubije.

---

## 0.2 TRI VRZELI, KI OSTAJAJO

Vse tri so majhne. Ravno zato so nevarne — vsaka posamič izgleda kot "še ni prišla na vrsto", skupaj pa pomenijo, da **postavljena vidljivost ne pride do tebe**.

| # | Vrzel | Posledica danes |
|---|---|---|
| **V1** | Faza 0 je na testni bazi (`DAVID\MSSQL19`), **ne na produkciji** (`IQ-SAOP\SQL01`) | nadzornik molka na produkciji sploh ne teče |
| **V2** | Noben .NET worker ne kliče `ops.usp_Heartbeat` — v `src/` in `windows_services/` ni nobenega klica `ops.EventLog` | signal `EVENTLOG` je prazen; nadzornik se lahko opre samo na posredne signale |
| **V3** | Stran `/system/status` bere `dbo.SyncState` in `dbo.DeltaJobState`, **ne** `ops.vSystemHealth` | nadzorna plošča kaže surovo stanje sinhronizacije, ne pa presoje "OK / MOLČI" |

Faza 1 spodaj je natanko zapiranje teh treh vrzeli. Nič novega se ne izumlja.

---

## 0.3 KORENSKI VZROK — natančneje, kot je bil prvotno zapisan

Prvotna formulacija: *"baza je modelirana po virih podatkov, ne po domeni."* Drži, a je pretirano splošna. Natančneje:

> **Izhodna stran je že rešena kot podatek. Vhodna stran še ni.**

- **Izhod:** `pim.OutputChannel` + `pim.OutputColumn` opisujeta izvozno pogodbo kot **vrstice v tabeli**. Nov atribut ali cenik v obstoječi kanal je danes konfiguracija, ne koda. (Prvotna ocena, da je izvoz trdo kodiran, je bila napačna — glej `sql/migrations/README.md`, Faza 1.)
- **Vhod:** vsak vir ima še vedno svoje `raw.{Org}_*_current` tabele, svoje `usp_stg_*_LoadFromRaw` in svoje posebnosti. Nov vir je še vedno drag.
- **Delno že popravljeno:** sloj `raw.Product*Normalized` je natanko prvi korak k skupni obliki, migraciji `1203` in `1205` pa uvajata **lastništvo polj** — kdo sme katero polje pisati. To je isti vzorec kot `OutputColumn`, samo na vhodni strani.

Torej: Faza 4 ni "velika arhitekturna sprememba, ki jo predlagam". Je **dokončanje vzorca, ki v tem repozitoriju že dela na dveh mestih**. To je bistveno lažja prodaja — samemu sebi in vodstvu.

---

# FAZA 1 — VIDLJIVOST DO KONCA (3–5 dni)

## 1.1 V1 — Faza 0 na produkcijo

Vrstni red je zapisan v [`sql/migrations/README.md`](../sql/migrations/README.md) in ga ne izumljaj na novo. Skrajšano:

```bash
powershell -ExecutionPolicy Bypass -File scripts\Invoke-PimMigrations.ps1 -Server "IQ-SAOP\SQL01" -Database "PIM_test" -WhatIf
```

```bash
powershell -ExecutionPolicy Bypass -File scripts\Invoke-PimMigrations.ps1 -Server "IQ-SAOP\SQL01" -Database "PIM_test" -AllowProduction
```

> **Past, ki te čaka prav tu.** Zaganjalnik namesti **vse** nenameščene migracije, ne samo Faze 0. Če je v mapi delo iz druge seje, gre zraven. Zato je `-WhatIf` obvezen prvi korak — ne kot obred, ampak da vidiš seznam.

Nato po vrsti: `tools/Verify_Faza0.sql` (razdelka 1 in 2 brez `MANJKA`) → poverilnice → `PIM_ALERT_WEBHOOK_URL` → jobi → preizkus alerta. Koraka z jobi in preizkusom sta edina, ki spremenita vedenje produkcije.

## 1.2 V2 — workerji naj oddajajo signal

Nadzornik zna štiri vrste signalov. Trije so posredni in delujejo brez sprememb v kodi, a imajo vsak svojo slepo pego:

| Signal | Kaj res dokazuje | Slepa pega |
|---|---|---|
| `INGEST` (`dbo.IngestRunLog`) | endpoint je nekaj vrnil | pišeta ga samo SAOP workerja |
| `TABLE` (svežina stolpca) | podatki so novi | ne loči "ni novih podatkov" od "worker je mrtev" |
| `AGENTJOB` (msdb) | job je tekel | nič ne pove o tem, ali je znotraj kaj naredil |
| **`EVENTLOG`** | **proces je bil živ ob času T** | — |

`SAOP_STOCKS` je to že pokazal v praksi: bral je `INGEST` za endpoint, kamor `SaopStockWorker` sploh ne piše. Vrstica je **trajno javljala molk**, dokler je `0201` ni deaktivirala. Signal, ki ga nihče ne oddaja, ni nadzor — je šum, ki te nauči ignorirati rdečo barvo.

Zato ena majhna ovojnica v vsak worker. Kliče **obstoječe** procedure iz `0002` — nobene nove tabele:

```csharp
/// <summary>
/// Zapiše potek zagona v ops.EventLog / ops.ErrorLog. Uporaba:
///   await using var run = await OpsRun.StartAsync(conn, "SaopCatalogWorker", orgId, "GetPrices");
///   ... delo ...
///   run.Success(prebrano, zapisano);
/// Če pride do izjeme, se ob Dispose zapiše napaka — uspeh je treba potrditi izrecno.
/// </summary>
public sealed class OpsRun : IAsyncDisposable
{
    private readonly SqlConnection _conn;
    private readonly string _source;          // = SignalKey v ops.HealthExpectation
    private readonly int? _orgId;
    private readonly Stopwatch _sw = Stopwatch.StartNew();

    private bool _ok;                          // privzeto false — molk = napaka
    private long? _rows;
    private string? _message;

    private OpsRun(SqlConnection conn, string source, int? orgId)
        { _conn = conn; _source = source; _orgId = orgId; }

    public static async Task<OpsRun> StartAsync(
        SqlConnection conn, string sourceObject, int? organizationId = null, string? note = null)
    {
        var run = new OpsRun(conn, sourceObject, organizationId);
        await run.LogEventAsync("START", note, rows: null);
        return run;
    }

    /// <summary>Klic med dolgim tekom, da nadzornik ne javi molka sredi dela.</summary>
    public Task HeartbeatAsync(string? note = null)
    {
        using var cmd = new SqlCommand("ops.usp_Heartbeat", _conn)
            { CommandType = CommandType.StoredProcedure };
        cmd.Parameters.AddWithValue("@SourceObject",   _source);
        cmd.Parameters.AddWithValue("@Layer",          "WORKER");
        cmd.Parameters.AddWithValue("@Message",        (object?)note ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@OrganizationId", (object?)_orgId ?? DBNull.Value);
        return cmd.ExecuteNonQueryAsync();
    }

    public void Success(long rowsWritten, string? note = null)
        { _ok = true; _rows = rowsWritten; _message = note; }

    public async ValueTask DisposeAsync()
    {
        if (_ok)
        {
            // FINISH je poleg HEARTBEAT edini dogodek, ki ga usp_GetLastSignalUtc šteje za znak življenja
            await LogEventAsync("FINISH", _message, _rows);
            return;
        }

        using var cmd = new SqlCommand("ops.usp_LogError", _conn)
            { CommandType = CommandType.StoredProcedure };
        cmd.Parameters.AddWithValue("@Layer",           "WORKER");
        cmd.Parameters.AddWithValue("@SourceObject",    _source);
        cmd.Parameters.AddWithValue("@Severity",        "Error");
        cmd.Parameters.AddWithValue("@OrganizationId",  (object?)_orgId ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@MessageOverride",
            (object?)(_message ?? "Zagon se ni zaključil z uspehom.") ?? DBNull.Value);
        await cmd.ExecuteNonQueryAsync();
    }

    private Task LogEventAsync(string kind, string? note, long? rows)
    {
        using var cmd = new SqlCommand("ops.usp_LogEvent", _conn)
            { CommandType = CommandType.StoredProcedure };
        cmd.Parameters.AddWithValue("@Layer",          "WORKER");
        cmd.Parameters.AddWithValue("@EventKind",      kind);
        cmd.Parameters.AddWithValue("@SourceObject",   _source);
        cmd.Parameters.AddWithValue("@Message",        (object?)note ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@OrganizationId", (object?)_orgId ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@RowsAffected",   (object?)rows ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@DurationMs",     (int)_sw.ElapsedMilliseconds);
        return cmd.ExecuteNonQueryAsync();
    }
}
```

**Privzeto stanje je napaka.** Namerno: če se worker sesuje na pol poti, ostane zapisan kot napaka. Uspeh moraš potrditi izrecno. Tako te tišina nikoli ne zavede.

Ko so signali v `ops.EventLog`, se pričakovanja prestavijo z `INGEST` na `EVENTLOG` — brez spremembe kode, samo vrstica v šifrantu:

```sql
UPDATE ops.HealthExpectation
   SET SignalKind = N'EVENTLOG', SignalKey = N'SaopStockWorker', IsActive = 1
 WHERE Code = N'SAOP_STOCKS';
```

Vrstni red uvajanja: `SaopStockWorker` (ker je njegov nadzor danes izklopljen) → `SaopCatalogWorker` → `NowodvorskiXmlIngest` → `NowodvorskiCsvStockWorker` → `BraytronXmlIngest` / `BTWindowsService_Stock` → `SAOP_Insert_products`. En worker = en commit.

> **Pred tem uredi V2-predpogoj:** workerji so v `.gitignore` in strežnik gradi iz **svoje** kopije. Dokler je tako, ne veš, katera različica na strežniku sploh teče — in ovojnica, ki je nikoli ne zgradiš iz repozitorija, ne pomaga. Glej Fazo 2.

## 1.3 V3 — nadzorna plošča na zaslon

`/system/status` že obstaja in kaže `dbo.SyncState`, `dbo.DeltaJobState` in števce PIM tabel. To je koristno, a je **surovo stanje** — od tebe zahteva presojo. Dodaj razdelek nad obstoječimi:

```sql
SELECT Code, DisplayName, Severity, LastSignalUtc, SilenceMinutes, MaxSilenceMinutes, Health
FROM ops.vSystemHealth
ORDER BY CASE WHEN Health = N'MOLČI' THEN 0 ELSE 1 END, Severity DESC, Code;
```

Zeleno / rumeno / rdeče, in pod tem zadnjih 50 vrstic `ops.ErrorLog`. Nič drugega. **To je prva stran, ki jo odpreš zjutraj.**

Za zapis v `ops.EventLog` iz intraneta velja ista konvencija kot za dnevnik dejavnosti (`security.AuditLog`): en servis, ne raztreseni klici po straneh.

## 1.4 Alarm — SQL Agent, ne n8n

Veriga obveščanja je že narejena in je boljša, kot bi bil zunanji orkestrator, ker SQL nikoli ne kliče HTTP:

```
ops.usp_LogError  ─▶  ops.usp_RaiseAlertsFromErrorLog  ─┐
                                                         ├─▶ ops.OutboundAlertQueue ─▶ Send-PimAlerts.ps1 ─▶ webhook
ops.usp_Watchdog_Check ─▶ ops.usp_EnqueueAlert ──────────┘
```

```bash
powershell -ExecutionPolicy Bypass -File scripts\Send-PimAlerts.ps1 -Server "IQ-SAOP\SQL01" -Database "PIM_test" -DryRun
```

Kot SQL Agent korak vsakih 5 minut, brez `-DryRun`.

**Pravilo "alarm pošlji enkrat" je že vgrajeno** — `usp_EnqueueAlert` ima `@DedupKey` in `@ThrottleMinutes` (nadzornik uporablja 60). Petkratna ista napaka da **eno** vrstico z `OccurrenceCount = 5`, ne pet sporočil. Prepričaj se sam, preden se zaneseš: preizkus je opisan v README migracij.

Prevzem je atomaren (`UPDATE ... OUTPUT`), zato dva vzporedna zagona ne pošljeta istega alerta dvakrat.

### ✅ Rezultat faze 1
Ne sprašuješ se več, ali workerji delajo. Ob molku dobiš sporočilo, ob prihodu v pisarno pa eno stran, ki pove vse. **To je 80 % občutka kontrole za nekaj dni dela — in polovica je že plačana.**

---

# FAZA 2 — PONOVLJIVOST (2 tedna)

## 2.1 Migracije — pravila, ki že veljajo

Okvir stoji. Kar je pomembno, je **disciplina**, in ta je zapisana v [`sql/migrations/README.md`](../sql/migrations/README.md):

| Pravilo | Zakaj |
|---|---|
| Brez `USE [PIM_test]` v migracijah | bazo določi zaganjalnik, isti paket teče na `PIM_test_ci` |
| Idempotentno (`CREATE OR ALTER`, `IF NOT EXISTS`) | ponovni zagon ne sme pokvariti ničesar |
| Nameščene datoteke se ne popravljajo | checksum to prepreči; popravek je **nova** migracija |
| Predpogoji z `THROW 5010x` | jasna napaka namesto čudnega vedenja |
| Ena migracija = ena transakcija | pade sredi → razveljavi se cela |
| **Svoj razpon številk** (`0001–0099`, `0100–0199`, `1000–1099` …) | dve vzporedni seji si ne stopita na prste |
| Nobene spremembe sheme ročno v SSMS | če je ni v migraciji, se ni zgodila |

Zadnje pravilo je edino, ki ga zares kršiš sam sebi, in edino, ki ga ne ujame noben mehanizem.

## 2.2 Kar še ni ponovljivo (in to je zdaj glavna vrzel)

**A. Baze se ne da zgraditi iz izvorne kode.** Paket `deploy_new_database` kaže na poti izpred reorganizacije in pokriva približno polovico objektov. 176 starih skript v `sql/` ima vrstni red zapisan v komentarjih in v tvoji glavi. Zato okolje nastane z **obnovitvijo kopije**, ne z gradnjo.

To je sprejemljivo stanje — a ga je treba **imenovati**, ne pa se pretvarjati, da imaš baseline. Poštena formulacija:

> Shemo naprej vodijo migracije. Izhodišče je backup. Baseline "iz nič" je cilj, ne stanje.

Pravi baseline se splača generirati šele, ko bo Faza 4 pojedla del starih objektov — sicer boš v git zapisal 325 tabel, od katerih je del mrtvih (`tools/Diagnose_Dead_Stock_Tables.sql` že zna pokazati katere).

**B. Workerji niso v gitu.** So v `.gitignore`, strežnik gradi iz svoje kopije, in nekateri imajo vklopljen samodejni DDL. To je večja luknja v ponovljivosti kot baza, ker je nevidna: koda na strežniku se lahko razlikuje od tvoje in tega ne pokaže nič. **Prvi korak Faze 2 je spraviti workerje v repozitorij** — brez tega ovojnica iz Faze 1.2 ni preverljiva.

**C. Objava intraneta.** Self-contained `win-x64` (vsiljeno v `.csproj`), IIS in-process, restart prek `app_offline`. Za AD prijavo je potrebna **popolna** objava. Zapiši to kot skripto, ne kot spomin.

## 2.3 Okolja — kakor v resnici so

| Okolje | Instanca | Baza | Namen |
|---|---|---|---|
| **TEST** | `DAVID\MSSQL19` | `PIM_test` | polna kopija (~25 GB, 325 tabel); sem kaže `src/appsettings.json` |
| **CI / peskovnik** | `DAVID\MSSQL19` | `PIM_test_ci` | preizkušanje migracij in agentovega dela |
| **PROD** | `IQ-SAOP\SQL01` | `PIM_test` | prava baza |

**Obe se imenujeta `PIM_test`.** Ločita ju samo imeni instanc — zato ima zaganjalnik zaščito `-AllowProduction`. Ne odstranjuj je in ne dodajaj bližnjic. Ta ovira je namerna.

Osvežitev okolja ni bash in ni Docker, ampak:

```bash
powershell -ExecutionPolicy Bypass -File scripts\New-PimTestDatabase.ps1 -SourceServer "IQ-SAOP\SQL01" -TargetServer "DAVID\MSSQL19" -TargetDatabase "PIM_test_ci"
```

> **Najpomembnejša podrobnost je že v skripti:** backup je `COPY_ONLY`. Brez tega bi navaden full backup prekinil verigo diferencialnih backupov produkcije in obnovitev ob resnični nesreči ne bi delovala. Ne "poenostavljaj" tega parametra stran.

Ko je osvežitev en ukaz, jo boš delal tedensko. Dokler je 20 korakov, je ne boš nikoli.

### ✅ Rezultat faze 2
Vsaka sprememba sheme je v gitu in preverljiva z `-Verify`. Workerji so v gitu. Testno okolje postaviš z enim ukazom. **Baza je pod kontrolo naprej, tudi če izhodišče ostane backup.**

---

# FAZA 3 — MAJHNI KORAKI (sproti)

## 3.1 Veje

```
master                  ← stanje, ki gre v PROD
 └─ prenova/faza-0-1     ← večji delovni tok
     └─ <naloga>         ← ena naloga, ena veja
```

Nikoli neposredno na `master`. Vsaka sprememba: veja → preveri na `PIM_test_ci` → merge.

## 3.2 Testi, ki jih solo developer res zmore

Pozabi na odstotke pokritosti. Tri vrste, po prioriteti:

**A. Preverbe stanja (obstajajo — uporabljaj jih)**

V `sql/migrations/tools/` je že vrsta preverb: `Verify_Faza0.sql`, `Verify_Faza1_Contract.sql`, `Verify_Faza1_Projection.sql`, `Verify_K1_Kategorije.sql`, `Verify_Zaloge_Z1.sql`, `Diag_K0_Kategorije.sql`. Vse so samo za branje.

> **Poženi jih znova po vsaki migraciji, ki se dotakne istega registra — ne samo prvič.**
> `Verify_Faza1_Contract` je pri `0007` izpisal `UJEMA SE`, nato je `0102` pokazal 256 stolpcev namesto 248. Prva preverba je bila veljavna v trenutku zagona; naslednja migracija je pod njo spremenila predpostavko.

Vse skripte iz `tools/` poganjaj s `sqlcmd -I`.

**B. Primerjalnik izhodov — vzorec, ki ga posnemaj (najpomembnejše)**

`export.usp_CompareChannelOutput` primerja star in nov izhod **vrstico po vrstico** in vrne `IDENTICNO` ali seznam razlik. To je natanko golden-file test, samo da živi v bazi in dela na pravih podatkih.

Isti vzorec prenesi na cevovod:

```sql
-- 1) fiksni nabor artiklov z robnimi primeri (brez EAN, več skladišč, prazen naziv, šumniki …)
-- 2) posnetek pričakovanega stanja v pim.* za ta nabor
-- 3) po spremembi: EXEC ops.usp_Run_DetectValidatePromote, nato primerjava proti posnetku
```

Ko se izhod spremeni, imaš dve možnosti: nekaj si pokvaril, ali nekaj si popravil in moraš posodobiti pričakovanje. **Oboje je informacija.** Brez tega pri spremembi validacije ali promocije samo upaš.

Nabor izbiraj iz znanih pasti, ne naključno: artikel z 20 skladišči, artikel brez feeda (generični builder iz STG), artikel z garancijo v vseh treh oblikah, `1,5` v številskem polju, podvojen artikel v paketu, artikel z `Aktivnost = D` in `Splet = N`.

**C. Unit testi — samo za zapleteno logiko brez baze**

`SaopCatalogWorker.Tests/SyncWatermarkTests.cs` je pravi primer: izračun delta okna je čista logika in test ga pokrije v milisekundah. Za CRUD ne piši unit testov.

## 3.3 Definicija končanega

```
□ koda je na veji, commit ima jasen opis
□ sprememba sheme je migracija v svojem razponu (ne ročni SSMS)
□ Invoke-PimMigrations -WhatIf pregledan, nato zagon na PIM_test_ci
□ ustrezni Verify_*.sql pognan PO migraciji (tudi če je bil pognan prej)
□ TEST_REPORT.md po predlogi iz ARCHITECTURE.md
□ nameščeno na TEST in preverjeno na zaslonu, ne samo v SSMS
□ vrstica v README migracij: kaj migracija doda in zakaj
```

Zadnja točka izgleda kot birokracija in ni. README migracij je danes de facto tvoj dnevnik odločitev — razdelki "Nauk iz 0102", "Past: filtriran indeks", "Zrno je celotna stvar" so vredni več kot katera koli ločena dokumentacija, ker so **na mestu, kjer jih boš iskal**.

---

# FAZA 3.5 — SLEDLJIVOST PODATKA (3–4 tedne)

Vidljivost iz Faze 1 odgovarja na vprašanje **"ali sistem teče"**. Ne odgovarja na vprašanje, ki ga v resnici dobiš največkrat:

> *"Neto teža je bila 1,5 kg, zdaj je 1,8 kg. Kdo je to spremenil in kdaj?"*

Danes tega ni mogoče odgovoriti. Vrednost v STG se lahko spremeni po petih poteh in beleži se ena.

| Pot | Zabeleženo danes |
|---|---|
| Izkaznica artikla | 🟡 `stg.ProductEditAudit` — cel JSON pred/po, ne po poljih |
| Paketni uvoz Excela | 🔴 privzeto samo glava paketa |
| Delta nakladalci iz SAOP / XML | 🔴 nič — `StgBusinessHash` pove le, da se je *nekaj* spremenilo |
| Promocija STG → PIM | 🔴 nič |
| PATCH nazaj v SAOP | 🟡 vrsta hrani payload, ni vezan na spremembo polja |
| Kategorije | 🟢 `pim.CategoryHistory` — **po poljih**, vzor za vse ostalo |

Manjkajoča vrstica je tretja in je najbolj boleča: **nakladalec, ki povozi tvoj popravek, tega ne zapiše nikamor.** Prav ta primer je izmerjen v migraciji `1203` (teža 1,4 v PIM proti 1,2 v SAOP).

## Kaj se gradi

Dve tabeli (`pim.ProductChangeBatch` + `pim.ProductFieldHistory`) in **generiran triger** nad STG tabelami. Triger, ne klici po procedurah — ker je poti pisanja pet in bo šesta nastala takrat, ko boš nanjo pozabil.

Ključno je, da se telo trigerja generira iz **`pim.FieldOwnership`** — registra, ki že obstaja in za vsako polje pove lastnika in mesto v STG. En register, ne dva seznama polj, ki bosta zdrsnila narazen.

Razveljavitev (Ctrl+Z) je izvedljiva, a ima štiri pogoje, brez katerih dela škodo:

1. gre po navadni poti shranjevanja, nikoli z neposrednim `UPDATE`
2. je nov zapis (`UndoOfChangeId`), ne izbris zgodovine
3. se ustavi, če je vmes kdo drug posegel (trenutna vrednost ≠ vrednost, ki jo razveljavljaš)
4. zavrne razveljavitev polja v lasti SAOP — takšna razveljavitev je videti uspešna in se čez uro tiho izniči

Cel načrt s shemami, skico trigerja in fazami S1–S7: [`docs/specifikacije/Nacrt_Sledenje_Sprememb.md`](specifikacije/Nacrt_Sledenje_Sprememb.md). Migracije v razponu `0500–0599`.

## Zakaj šele zdaj in ne prej

Sledljivost brez Faze 3 je past. Triger nad STG tabelami se dotakne vseh poti pisanja hkrati — vključno s paketnim uvozom, ki je bil ravno optimiziran iz ene ure na minute. Brez primerjalnika cevovoda iz 3.2 nimaš načina, da dokažeš, da si z beleženjem ničesar ne pokvaril.

---

# FAZA 4 — VHODNA STRAN KOT PODATEK (2–3 mesece, postopno)

**Ne rewrite.** Vzorec je že dokazan dvakrat: `OutputChannel` na izhodu in `raw.Product*Normalized` na vhodu. Faza 4 ju dokonča.

## 4.1 Kaj manjka

| Opravilo | Danes | Cilj |
|---|---|---|
| Dodaj nov vir | nove `raw.*` tabele, nova `usp_stg_*_LoadFromRaw`, novi jobi, koda | adapter + vrstice v šifrantu preslikav |
| Popravi preslikavo polja | sprememba procedure + namestitev | `UPDATE` v šifrantu |
| Kdo zmaga pri konfliktu | delno v `1203` / `1205`, delno skrito v procedurah | eno mesto, vidno kot podatek |
| Stanje delta-sinhronizacije | `dbo.SyncState` + `dbo.DeltaJobState` + `dbo.IngestRunLog` | **eno** mesto z `LastSuccessAt` |

Zadnja vrstica je pomembnejša, kot izgleda. Trije viri resnice o tem, kdaj je vir nazadnje uspel, so tudi razlog, da je delta-sync tako težko razumeti. Pravilo je trivialno, **ko je stanje na enem mestu**:

```
LastSuccessAt IS NULL ali starejši od 7 dni   → poln zajem
sicer                                          → delta od (LastSuccessAt − 1h)
po USPEŠNEM zaključku                          → LastSuccessAt = zdaj
0 zapisov IN LastSuccessAt starejši od 24 h    → Warning v ops.ErrorLog
```

Datum posodobiš **samo ob uspehu**. To je cel popravek — vse ostalo je posledica tega, da se je datum posodabljal tudi takrat, ko zajem ni uspel.

## 4.2 Vrstni red

```
1. Konsolidiraj stanje sinhronizacije (SyncState + DeltaJobState + IngestRunLog → en register)
2. Adapter za NAJPREPROSTEJŠI vir — Braytron XML
3. Mesec dni teče VZPOREDNO s staro potjo; primerjaj z istim vzorcem kot usp_CompareChannelOutput
4. Ko se ujemata, ugasni staro pot za ta vir
5. Nowodvorski
6. SAOP zadnji — največ endpointov, največ posebnosti, največ tveganja
```

> **Nikoli ne ugasneš stare poti, dokler nova en mesec ne daje enakih rezultatov.** Faza 1 je to že delala tako (`_Legacy` preimenovanje ob preklopu) in se je obneslo. Ponovi vzorec.

Migracije za to gredo v razpon `0200–0299`.

---

# FAZA 5 — INTRANET (3–4 tedne)

## 5.1 Kaj je že narejeno

Navigacija je bila julija 2026 preurejena v 13 področij (`Components/Layout/PimShellNav.razor`) — to poglavje torej **ni** več "meni je po tabelah". Predlog sedmih skupin iz prvotnega dokumenta je zastarel; ne vračaj se nanj.

## 5.2 Kar ostaja: inventura 69 strani

Ne meni, ampak **vsebina**. Za vsako stran en status:

| Stran | Pot | Kdo uporablja | Status |
|---|---|---|---|
| `Products` | `/products` | nabava, marketing | 🟢 OBDRŽI |
| `PimSystem` | `/system/status` | ti | 🟡 POPRAVI (dodaj `ops.vSystemHealth`) |
| `XmlMonitor` | `/ingestion/xml-monitor` | ? | ❓ PREVERI |
| `ModelReferences` | ? | ? | ❓ PREVERI |
| … | | | |

Trije stolpci so lahki, četrti ("kdo uporablja") je edini, ki šteje. **Če ne znaš imenovati osebe, je stran kandidat za brisanje.**

**Brisanje mrtvih strani je najhitrejša izboljšava, kar jih premoreš.** Manj kode = manj vzdrževanja = več kontrole. Pri 69 straneh in enem developerju je to najbolje plačano popoldne v celem načrtu.

## 5.3 Preden dodaš novo funkcijo

Vprašaj se: **kdo jo bo uporabljal in kako pogosto?** Če ne znaš imenovati osebe, je ne gradi. Vsaka nepotrebna funkcija je dolg, ki ga plačuješ mesece.

---

# FAZA 6 — AGENTI

## 6.1 Kaj delajo dobro in kaj slabo

| Delajo DOBRO ✅ | Delajo SLABO ❌ |
|---|---|
| Migracijske skripte po tvoji specifikaciji | Arhitekturne odločitve |
| Preverbe (`Verify_*.sql`) in primerjalniki | Presoja, kaj je poslovno pravilno |
| Refaktoriranje ponavljajoče se kode | Preslikava polj (rabi domensko znanje) |
| Analiza dnevnikov in iskanje vzorcev | Karkoli na PROD |
| Dokumentacija iz kode | Presoja, ali je sprememba tvegana |
| Boilerplate (DTO, adapterji, CRUD) | Prioritete |

**Ti si arhitekt. Agenti so implementacija.** Ta meja mora biti neomajna, sicer čez tri mesece ne boš razumel lastnega sistema — in takrat res ne boš imel nič pod kontrolo.

## 6.2 Trdna pravila (ta so že v `TASKS.md` — spoštuj jih)

```
1. Baze NE spreminjaj samodejno. Agent piše .sql + navodila; zaganjaš ti.
2. Delo gre na PIM_test_ci, nikoli na produkcijsko PIM_test.
3. Vsaka shema gre skozi migracijo — v svojem razponu številk.
4. Pred vsakim zagonom migracij: -WhatIf. Zaganjalnik potegne s sabo tudi tuje
   nenameščene migracije iz vzporednih sej.
5. Ustrezni Verify_*.sql mora iti skozi PO migraciji.
6. Če ne razumeš, kaj je agent napisal, tega ne mergeaš.
   (Pravilo 6 je najpomembnejše in najlažje ga je prekršiti.)
```

Dodatek, ki ga ni v prvotnem dokumentu, izhaja pa iz izkušnje s tem repozitorijem: **`.ps1` datoteke rabijo UTF-8 z BOM**, sicer se šumniki v izpisih razsujejo. In v SQL komentarjih ne piši literalnega začetka blokovnega komentarja — SQL Server šteje gnezdene komentarje in datoteka se tiho pokvari.

## 6.3 Delitev vlog

| Vloga | Kdo | Naloge |
|---|---|---|
| **Implementacija** | Claude Code | koda, SQL migracije, preverbe, dokumentacija |
| **Pregled** | `/code-review`, Codex | robni primeri, druga presoja pred mergeom |
| **Urnik in alarmi** | **SQL Agent + `Send-PimAlerts.ps1`** | zaganja jobe, prevzema vrsto alertov, pošilja na webhook |
| **Odločitve** | **TI** | arhitektura, prioritete, kaj gre na produkcijo |

Zunanjega orkestratorja za urnik ne rabiš — SQL Agent že poganja `PIM_FullIngestion`, `PIM_DetectValidate_Global`, `PIM_ProductAllCsv_Export` in `PIM_WebExport_Customers_Csv`, nadzornik pa vse štiri opazuje prek signala `AGENTJOB`.

## 6.4 Dobre naloge za agente (začni s temi)

```
□ "Dodaj OpsRun ovojnico v SaopStockWorker, potem prestavi pričakovanje
   SAOP_STOCKS z INGEST na EVENTLOG. En commit."
□ "Dodaj razdelek ops.vSystemHealth na /system/status, nad obstoječe tabele."
□ "Napiši Verify skripto, ki primerja shemo PIM_test na DAVID\MSSQL19 in na
   IQ-SAOP\SQL01 ter izpiše razlike."
□ "Popiši vseh 69 Blazor strani: pot, kateri servisi, katere tabele."
□ "Analiziraj ops.ErrorLog zadnjih 30 dni, najdi vzorce, napiši poročilo."
□ "Poženi tools/Diagnose_Dead_Stock_Tables.sql in pripravi migracijo za DROP
   tistih brez odvisnosti — ločeno, ne izvedi."
```

Vse to je delo, ki ga je treba narediti, in nobeno ne zahteva tvoje presoje o tem, **kaj** je prav — samo **kako**.

---

# 7. RITEM — KAKO DELATI 8 UR IN NE IZGORETI

## 7.1 Dan

| Čas | Kaj |
|---|---|
| 08:00–08:15 | Odpri `/system/status`. Če je vse zeleno, ne odpiraj ničesar drugega. |
| 08:15–10:00 | Incidenti in popravki. Če jih ni → razvoj. |
| 10:00–12:30 | **Globoko delo — ena naloga.** Brez maila, brez Teamsov. |
| 12:30–13:00 | Odmor |
| 13:00–15:00 | Globoko delo (ista naloga) |
| 15:00–16:00 | Pregled agentskega dela, merge, namestitev na TEST |
| 16:00–16:30 | Zapis: kaj je narejeno, kaj je naslednje. Zapri. |

## 7.2 Teden

- **Ponedeljek:** izberi **3 naloge** za teden. Ne 10.
- **Sreda:** vmesni pregled — je katera zataknjena?
- **Petek popoldne:** osveži `PIM_test_ci`, dopolni README migracij, zapiši eno odločitev.

## 7.3 Železno pravilo: WIP = 2

**Nikoli več kot dve stvari hkrati odprti.** Preklapljanje med konteksti je tvoj največji požiralec časa. Raje ena končana stvar kot pet 80-odstotnih.

To pravilo ima v tem repozitoriju tudi tehnično posledico: vsaka vzporedna seja pomeni migracije v drugem razponu številk in tveganje, da zaganjalnik potegne tuje delo. Manj vzporednosti = manj presenečenj ob namestitvi.

## 7.4 Beleženje odločitev

Dnevnik odločitev že imaš na dveh mestih: `_SPEC/PIM_SISTEM_MENI_Master_Specifikacija.txt` in razdelki "Nauk iz…" v README migracij. Za večje odločitve, ki niso vezane na eno migracijo, dodaj `docs/specifikacije/Odlocitve/ADR-xxx.md`:

```markdown
# ADR-004: Vhodna stran kot podatek

**Datum:** 2026-08-12
**Status:** Sprejeto

## Kontekst
Izhod je od Faze 1 opisan kot podatek (pim.OutputChannel). Vhod ne — vsak vir ima
svoje raw tabele in svojo LoadFromRaw proceduro. Nov vir je zato drag.

## Odločitev
Isti vzorec prenesemo na vhod. Konsolidiramo SyncState / DeltaJobState /
IngestRunLog v en register z LastSuccessAt.

## Posledice
+ Nov vir = adapter + konfiguracijske vrstice
+ Delta-sync stanje na enem mestu; popravek postane trivialen
− Prehodno obdobje z dvema potema za vsak vir
− Migracija obstoječih virov je postopna (strangler), ne enkratna

## Zavrnjene alternative
- Ostati pri obstoječem: dodajanje virov ostane drago
- Popoln rewrite: pretvegano, ko si sam — Faza 1 je dokazala, da vzporedna pot deluje
```

Čez pol leta te bo to rešilo. Sam sebi si takrat tuj developer.

---

# 8. VRSTNI RED — KAJ DELATI KDAJ

```
TEDEN 1     V1: Faza 0 na produkcijo (-WhatIf → -AllowProduction → Verify_Faza0)
            V3: ops.vSystemHealth na /system/status
            Send-PimAlerts.ps1 kot SQL Agent korak + preizkus dušenja
            → Nadzor dela tam, kjer šteje, in pride do tebe.

TEDEN 2     Workerji v git (predpogoj za vse ostalo pri workerjih)
            V2: OpsRun v SaopStockWorker, prestavi SAOP_STOCKS na EVENTLOG
            → Prvi worker, ki res pove, da je živ.

TEDEN 3     OpsRun v preostalih workerjih, en commit na worker
            Po tednu opazovanja zategni meje v ops.HealthExpectation

TEDEN 4     Inventura 69 strani. Zbriši mrtve.
            → Manj kode, manj vzdrževanja.

TEDEN 5–6   Primerjalnik cevovoda po vzorcu usp_CompareChannelOutput
            → Zdaj lahko varno spreminjaš validacijo in promocijo.

MESEC 2     Sledenje sprememb S1–S4: tabeli, generiran triger, kontekst,
            zavihek Zgodovina na izkaznici
            → »Kdo je spremenil težo« dobi odgovor v eni poizvedbi.
            Nato S5–S6: razveljavitev polja in paketa.

MESEC 2–3   Konsolidacija stanja sinhronizacije + popravek delta-sync
            (zdaj imaš primerjalnik, da veš, da si res popravil)

MESEC 3–4   Adapter za Braytron, vzporedno s staro potjo

MESEC 5–6   Nowodvorski, nato SAOP. Ugasni staro pot.

SPROTI      Agenti: preverbe, dokumentacija, refaktoring — na vejah, na PIM_test_ci
```

---

# 9. IZKRENO — KAJ MORAŠ SLIŠATI

**1. Del tega ni tehnični problem.**
Solo developer, ki ima v lasti kritičen sistem za štiri organizacije, brez avtomatiziranih testov cevovoda in z nadzorom, ki še ni na produkciji — to ni tvoja osebna pomanjkljivost, to je **organizacijsko tveganje podjetja**. Faktor avtobusa je 1.

To povej vodstvu kot dejstvo z rešitvijo: *"Nadzor delovanja je zgrajen, ta teden ga postavim na produkcijo. To je tudi razlog, zakaj določene stvari trajajo — gradim temelje, ki jih doslej ni bilo."*

Vidljivost je tudi tvoja **zaščita**: ko obstaja stran, ki kaže, kaj vse teče, postane vidno, koliko sistema pravzaprav držiš pokonci.

**2. Ne delaj rewrita — in tokrat imaš dokaz, da ni potreben.**
Faza 1 je pokazala, kako se dela velika sprememba brez rewrita: nova pot ob stari, primerjalnik podatkov, preklop šele ob `IDENTICNO`. Isti postopek velja za vhodno stran. Nova shema na domačem računalniku naj bo **cilj**, do katerega prideš z migracijami, ne zamenjava.

**3. Prvotna ocena stanja je bila prestroga.**
"Nimam ničesar" ni držalo — ops shema, migracijski okvir, veriga obveščanja, nadzornik molka in izhodni kanal kot konfiguracija so postavljeni. Prestroga ocena ni nedolžna: vodi v gradnjo tega, kar že stoji, namesto v zapiranje treh majhnih vrzeli, ki ločijo "zgrajeno" od "deluje in mi pove". Prvi teden tega načrta zapre vse tri.

Enako velja za oceno izvoza kot "trdo kodiranega" — ni bil. Preverjaj stanje, preden načrtuješ delo; pri sistemu te velikosti se spomin moti sistematično v smer črnogledosti.

**4. Popolne kontrole ne boš imel. Nikoli.**
Cilj ni "vem vse". Cilj je: **kadar se kaj pokvari, izvem v 15 minutah in vem, kako varno popraviti.** To je vse, kar ima tudi senior. Razlika je samo v mehanizmih — in te v tem repozitoriju že večinoma imaš.

---

*Predelano avgusta 2026 iz splošne različice · Naslednji pregled: po zaključku Faze 1 (vse tri vrzeli zaprte)*
