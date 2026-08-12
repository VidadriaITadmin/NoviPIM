# Sledenje sprememb polj + razveljavitev (Ctrl+Z)

**Datum:** 12. 8. 2026
**Stanje:** načrt, koda še ni pisana
**Povod:** neto teža je bila 1,5 kg, popravljena na 1,8 kg. Danes se nikjer ne vidi, **kdo** je to spremenil, **kdaj**, **iz katerega vira** in ali je sprememba prišla do SAOP. Razveljaviti je ni mogoče.

---

## 1. Kaj danes obstaja

Sledenje ni na ničli, je pa **luknjasto** — pokrit je samo en od šestih virov sprememb.

| Pot, po kateri se vrednost spremeni | Kdo piše | Zabeleženo danes |
|---|---|---|
| Izkaznica artikla v intranetu | `dbo.usp_stg_SaveProductFromIntranet` | 🟡 `stg.ProductEditAudit` — **cel** JSON pred/po, ne po poljih |
| Paketni uvoz Excela | `usp_stg_BulkEditImport_Apply` | 🔴 privzeto samo glava paketa (`@WriteAudit = 1`), brez odtisov |
| Delta nakladalci iz SAOP / XML | `usp_stg_*_LoadFromRaw*` | 🔴 nič — `StgBusinessHash` pove le, da se je *nekaj* spremenilo |
| Promocija STG → PIM | `usp_pim_PromoteValidatedProducts` | 🔴 nič |
| PATCH nazaj v SAOP | `pim.SaopItemOutboundQueue` + worker | 🟡 vrsta hrani payload, ni pa vezan na spremembo polja |
| Kategorije in uvrstitve | `pim.usp_CategoryHistory_Write` | 🟢 **po poljih, s starim in novim** |

Dvoje je pomembno:

1. **Vzor že imamo.** `pim.CategoryHistory` (migracija `1008`) je natanko prava oblika: `FieldName`, `OldValue`, `NewValue`, `ChangedBy`, `ChangedAtUtc`, `BatchId`, `SourceSystem`. Za artikle je treba isto, ne nekaj novega.
2. **Register polj že imamo.** `pim.FieldOwnership` (migracija `1203`) za vsako polje pove lastnika **in** kje v STG vrednost živi:

   | FieldKey | Owner | StgTable | StgColumn |
   |---|---|---|---|
   | `ItemWeightPerUnit` | PIM | `ProductCommercial` | `NetWeightPerUnit` |
   | `ItemGroup` | SAOP | `ProductCore` | `ItemGroup` |

   Isti register torej lahko poganja tudi dnevnik sprememb. Brez tega bi imeli dva seznama polj, ki bi sčasoma zdrsnila narazen — točno to se je zgodilo pri `0010` z dvema SAOP builderjema.

Trigerji v tem sistemu **niso novost**: `pim.TR_ProductCore_SetUpdatedAtUtc` in sorodni že tečejo nad `pim.*` tabelami.

---

## 2. Odločitev: triger, ne klici po procedurah

Vrednost pride v STG po **petih** poteh (izkaznica, paketni uvoz, trije delta nakladalci) in vsaka je svoja koda.

| | Klic v vsaki proceduri | **Triger nad STG tabelo** |
|---|---|---|
| Nova pot čez pol leta | jo pozabiš instrumentirati | ujeta samodejno |
| Delta nakladalec povozi popravek | ni zabeleženo | **zabeleženo** — to je bistvo |
| Cena | nič | nekaj odstotkov na zapis |
| Kdo in zakaj | ve klicatelj | triger konteksta ne vidi → `SESSION_CONTEXT` |

Odločitev: **triger nad `stg.ProductCore`, `stg.ProductCommercial`, `stg.ProductAttribute`**.

STG je križišče — tja pišeta tako intranet kot nakladalci. `pim.*` je prepozno (za promocijo se več sprememb zlije v eno), `raw.*` prezgodaj (tam je posnetek vira, ne naša sprememba).

**Tri omejitve, brez katerih triger naredi več škode kot koristi:**

1. **Množinski, nikoli po vrsticah.** `inserted` JOIN `deleted` + `UNPIVOT`. Paketni uvoz gre skozi en `MERGE` z ~28.000 vrsticami; kurzor v trigerju bi vrnil uro izvajanja, ki jo je `1200` ravno odpravila.
2. **Beleži samo dejansko razliko.** NULL-varna primerjava. Delta nakladalec ob spremembi hasha prepiše **celo vrstico** — brez primerjave po vrednosti bi vsak dotik SAOP zapisal 30 »sprememb«, kjer se ni spremenilo nič.
3. **Telo trigerja se generira iz `pim.FieldOwnership`**, ne piše na roko. Migracija sestavi `CREATE TRIGGER` iz vrstic registra. Novo polje v registru = ponovni zagon generatorja, brez ročnega popravljanja.

### Kontekst: kdo in zakaj

Triger ne ve, kdo je klical. Reši `SESSION_CONTEXT` (SQL 2016+, mi smo na 2019):

```sql
EXEC sys.sp_set_session_context @key = N'ChangeSource', @value = N'INTRANET';
EXEC sys.sp_set_session_context @key = N'ChangedBy',    @value = N'dplaninsek';
EXEC sys.sp_set_session_context @key = N'BatchId',      @value = @BatchId;
```

Triger prebere s **privzetkom**, ki ne laže:

```sql
DECLARE @src NVARCHAR(32) = CONVERT(NVARCHAR(32), SESSION_CONTEXT(N'ChangeSource'));
IF @src IS NULL SET @src = N'NEZNANO';     -- ne ugibaj vira
```

`NEZNANO` v dnevniku je **koristen podatek** — pomeni pot, ki še ni instrumentirana. Če bi privzeto pisali `SAOP_DELTA`, bi si sami zlagali zgodovino.

> Povezovalni bazen ob vrnitvi povezave (`sp_reset_connection`) kontekst počisti. To je dobro (ne uhaja med uporabniki), pomeni pa, da ga mora **vsak klic nastaviti znova** — ne enkrat ob zagonu workerja.

---

## 3. Tabeli

```sql
/* Glava: ena uporabnikova akcija = ena vrstica = en Ctrl+Z */
CREATE TABLE pim.ProductChangeBatch
(
    ChangeBatchId   BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_pim_ProductChangeBatch PRIMARY KEY,
    BatchId         UNIQUEIDENTIFIER NOT NULL,
    ChangeSource    NVARCHAR(32)  NOT NULL,   -- INTRANET|BULK|SAOP_DELTA|XML_FEED|PROMOTE|UNDO|NEZNANO
    ChangedBy       NVARCHAR(128) NOT NULL,
    ChangedAtUtc    DATETIME2(0)  NOT NULL CONSTRAINT DF_pim_PCB_At DEFAULT (SYSUTCDATETIME()),
    OrganizationId  INT           NULL,
    Note            NVARCHAR(400) NULL,       -- npr. ime uvozne datoteke
    UndoOfBatchId   BIGINT        NULL        -- razveljavitev je sama zapis, ne izbris
        CONSTRAINT FK_pim_PCB_Undo REFERENCES pim.ProductChangeBatch (ChangeBatchId)
);

/* Vrstica: eno polje, ena sprememba */
CREATE TABLE pim.ProductFieldHistory
(
    ChangeId         BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_pim_ProductFieldHistory PRIMARY KEY,
    ChangeBatchId    BIGINT        NOT NULL
        CONSTRAINT FK_pim_PFH_Batch REFERENCES pim.ProductChangeBatch (ChangeBatchId),

    OrganizationId   INT           NOT NULL,
    ItemID           NVARCHAR(64)  NOT NULL,
    StgProductCoreId BIGINT        NULL,

    FieldKey         NVARCHAR(128) NOT NULL,   -- iz pim.FieldOwnership (ime v SAOP)
    StgTable         NVARCHAR(64)  NOT NULL,
    StgColumn        NVARCHAR(128) NOT NULL,   -- pri atributu: AttributeCode
    Owner            NVARCHAR(8)   NOT NULL,   -- posnetek lastnika ob spremembi

    OldValue         NVARCHAR(400) NULL,
    NewValue         NVARCHAR(400) NULL,

    ChangedAtUtc     DATETIME2(0)  NOT NULL CONSTRAINT DF_pim_PFH_At DEFAULT (SYSUTCDATETIME()),

    /* pot do SAOP — brez tega ne veš, ali je sprememba sploh prišla ven */
    OutboundQueueId  BIGINT        NULL,
    SentToSaopAtUtc  DATETIME2(0)  NULL,

    UndoOfChangeId   BIGINT        NULL
        CONSTRAINT FK_pim_PFH_Undo REFERENCES pim.ProductFieldHistory (ChangeId)
);

CREATE INDEX IX_pim_PFH_Item
    ON pim.ProductFieldHistory (OrganizationId, ItemID, ChangedAtUtc DESC)
    INCLUDE (FieldKey, OldValue, NewValue, Owner);

CREATE INDEX IX_pim_PFH_Field
    ON pim.ProductFieldHistory (FieldKey, ChangedAtUtc DESC);
```

**Zakaj glava in ne samo vrstice.** Ena shranitev izkaznice spremeni pet polj. Ctrl+Z mora vrniti vseh pet, ne enega — sicer uporabnik pritisne petkrat in vmes ustvari stanja, ki jih nikoli ni bilo.

**Zakaj `Owner` kot posnetek.** Lastništvo se lahko v registru spremeni. Zgodovina mora povedati, kdo je bil lastnik **takrat**, sicer čez pol leta ne veš, zakaj je sprememba šla ali ni šla v SAOP.

**Zakaj `NVARCHAR(400)` za vrednost.** Isti tip kot `usp_Saop_CompareItemFields`, da primerjava in zgodovina govorita isti jezik. Za dolga besedila (opisi) se hrani odtis in prvih 400 znakov — cel opis je v `stg.ProductText`, zgodovina ni arhiv besedil.

### Skica trigerja (izsek, telo se generira)

```sql
CREATE OR ALTER TRIGGER stg.TR_ProductCommercial_FieldHistory
ON stg.ProductCommercial AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF ROWCOUNT_BIG() = 0 RETURN;

    DECLARE @src NVARCHAR(32)  = COALESCE(CONVERT(NVARCHAR(32),  SESSION_CONTEXT(N'ChangeSource')), N'NEZNANO');
    DECLARE @by  NVARCHAR(128) = COALESCE(CONVERT(NVARCHAR(128), SESSION_CONTEXT(N'ChangedBy')),    SUSER_SNAME());
    DECLARE @bid UNIQUEIDENTIFIER = CONVERT(UNIQUEIDENTIFIER, SESSION_CONTEXT(N'BatchId'));

    DECLARE @batch BIGINT;
    INSERT INTO pim.ProductChangeBatch (BatchId, ChangeSource, ChangedBy)
    VALUES (COALESCE(@bid, NEWID()), @src, @by);
    SET @batch = SCOPE_IDENTITY();

    INSERT INTO pim.ProductFieldHistory
        (ChangeBatchId, OrganizationId, ItemID, StgProductCoreId,
         FieldKey, StgTable, StgColumn, Owner, OldValue, NewValue)
    SELECT @batch, i.OrganizationId, i.ItemID, i.StgProductCoreId,
           v.FieldKey, N'ProductCommercial', v.StgColumn,
           COALESCE(fo.Owner, N'SAOP'), v.OldValue, v.NewValue
    FROM inserted AS i
    INNER JOIN deleted AS d ON d.StgProductCommercialId = i.StgProductCommercialId
    CROSS APPLY (VALUES
        /* ↓ ta blok generira migracija iz pim.FieldOwnership */
        (N'ItemWeightPerUnit', N'NetWeightPerUnit',
            CONVERT(NVARCHAR(400), d.NetWeightPerUnit), CONVERT(NVARCHAR(400), i.NetWeightPerUnit)),
        (N'ItemGrossWeight',   N'GrossWeight',
            CONVERT(NVARCHAR(400), d.GrossWeight),      CONVERT(NVARCHAR(400), i.GrossWeight))
    ) AS v (FieldKey, StgColumn, OldValue, NewValue)
    LEFT JOIN pim.FieldOwnership AS fo
           ON fo.FieldKey = v.FieldKey AND fo.IsActive = 1
          AND (fo.OrganizationId = i.OrganizationId OR fo.OrganizationId IS NULL)
    WHERE EXISTS (SELECT v.OldValue EXCEPT SELECT v.NewValue);   -- NULL-varna razlika
END
```

Vzorec `WHERE EXISTS (SELECT a EXCEPT SELECT b)` je NULL-varna primerjava brez `ISNULL` na obeh straneh — pomembno, ker je pri težah in dimenzijah `NULL` pogosta vrednost in bi jo `<>` tiho izpustil.

---

## 4. Razveljavitev (Ctrl+Z)

Ta del je težji od beleženja in ga je treba zastaviti prav, sicer naredi škodo.

### Štiri pravila

**1. Razveljavitev gre po navadni poti shranjevanja, nikoli z neposrednim `UPDATE`.**
Klic `usp_stg_SaveProductFromIntranet` s staro vrednostjo. Neposreden `UPDATE` bi obšel validacijo, uvrstitev v vrsto za SAOP in lastništvo polj — dobil bi vrednost v bazi in nič drugega.

**2. Razveljavitev je nov zapis, ne izbris starega.**
`UndoOfChangeId` kaže nazaj. Zgodovina se nikoli ne skrajša. Redo je razveljavitev razveljavitve — isti mehanizem, nič posebnega.

**3. Razveljavitev preveri, ali je vmes kdo drug posegel.**

```
trenutna vrednost = NewValue spremembe, ki jo razveljavljam   → varno
trenutna vrednost ≠ NewValue                                  → USTAVI in vprašaj
```

Drugi primer je pogost, ne izjemen: uporabnik popravi težo, čez uro jo prepiše SAOP delta, čez dva dni uporabnik pritisne Ctrl+Z. Če bi razveljavitev slepo vpisala staro vrednost, bi povozila **novejšo** spremembo, o kateri ne ve nič. Prikaži oboje in naj odloči človek.

**4. Razveljavitev spoštuje lastništvo polja.**

| Lastnik polja | Kaj naredi Ctrl+Z |
|---|---|
| `PIM` | vpiše staro vrednost in jo uvrsti v vrsto za PATCH v SAOP |
| `SAOP` | **zavrne z razlago** — vrednost bi ob naslednjem delta zajemu spet izginila |

Razveljavitev polja v lasti SAOP je videti, kot da deluje, in se čez uro tiho izniči. To je najslabša možna oblika napake: uporabnik verjame, da je popravil.

### Kaj, če je sprememba že šla v SAOP

`SentToSaopAtUtc` ni `NULL` → razveljavitev ni samo lokalna. Poslati je treba **nov** PATCH s staro vrednostjo. Uporabniku to povej vnaprej: »Ta sprememba je bila 12. 8. ob 14:32 poslana v SAOP. Razveljavitev bo poslala nov popravek.«

> `Sent` pomeni *oddano v vrsto in poslano*, ne *potrjeno v SAOP*. To razlikovanje že velja za izhodne vrste in tu ni nič drugače.

---

## 5. Faze

| Faza | Kaj | Rezultat |
|---|---|---|
| **S1** | Tabeli `pim.ProductChangeBatch` + `ProductFieldHistory`, razširitev `pim.FieldOwnership` z `TrackHistory BIT` | shema stoji, nič se še ne beleži |
| **S2** | Generator trigerjev iz registra + trigerja na `ProductCore` in `ProductCommercial` | vse spremembe teh dveh tabel se beležijo, tudi iz nakladalcev |
| **S3** | `SESSION_CONTEXT` v vseh poteh pisanja (izkaznica, paketni uvoz, nakladalci, promocija) | `NEZNANO` v dnevniku izgine |
| **S4** | Zavihek **Zgodovina** na izkaznici artikla + stran s spremembami po vseh artiklih | vidiš, kdo je spremenil težo in od kod |
| **S5** | Razveljavitev enega polja (pravila 1–4) | Ctrl+Z za eno vrednost |
| **S6** | Razveljavitev celega paketa + pot v SAOP | Ctrl+Z za celo shranitev |
| **S7** | `stg.ProductAttribute` (garancija!) in mediji | pokritost vseh polj |

Migracije gredo v razpon **`0500–0599`** (nov delovni tok; razpone dopolni v `sql/migrations/README.md`).

**Merilo uspeha S2–S3:** primer iz povoda mora dati odgovor v eni poizvedbi.

```sql
SELECT b.ChangedAtUtc, b.ChangeSource, b.ChangedBy, h.OldValue, h.NewValue, h.SentToSaopAtUtc
FROM pim.ProductFieldHistory AS h
JOIN pim.ProductChangeBatch  AS b ON b.ChangeBatchId = h.ChangeBatchId
WHERE h.OrganizationId = 3
  AND h.ItemID = N'G14.4V1CW.50'
  AND h.FieldKey = N'ItemWeightPerUnit'
ORDER BY h.ChangedAtUtc DESC;
```

---

## 6. Pasti, ki so v tem sistemu že bile

| Past | Kje se je že zgodila | Kako se ji tu izognemo |
|---|---|---|
| Vrstica-za-vrstico namesto množinsko | uvoz Excela pred `1200` (1 ura → minute) | triger dela nad `inserted`/`deleted`, brez kurzorja |
| Skalarna funkcija ubije vgrajevanje | `fn_stg_NormalizeDaNeFlag`, `WITH INLINE = OFF` | v trigerju nobene skalarne UDF, samo izrazi |
| Signal, ki ga nihče ne oddaja | nadzornik `SAOP_STOCKS` je leta javljal molk | `NEZNANO` je vidna vrednost, ne tiha predpostavka |
| Dva seznama polj zdrsneta narazen | dve telesi SAOP builderjev po `0010` | telo trigerja se **generira** iz `pim.FieldOwnership` |
| Preverba dokazuje samo, kar meri | `Verify_Faza1_Contract` je bil zelen pri napačnem semenu | preverba S2 primerja **vrednosti** pred/po, ne le obstoja vrstic |
| `OUTPUT` brez `INTO` na tabeli s trigerjem | še ni; danes v STG procedurah ni takega mesta | zapiši kot pravilo — nova koda mora uporabiti `OUTPUT … INTO @tabela` |

## 7. Kar ta načrt namenoma ne pokriva

- **Zaloga in cene.** Zaloga je samo za branje, spremembe količin se ne beležijo po poljih — pri milijonih dotikov dnevno bi bil dnevnik večji od podatkov.
- **Arhiv besedil.** Zgodovina hrani prvih 400 znakov, ne celotnih opisov.
- **Razveljavitev čez promocijo.** S5/S6 razveljavljata v STG. Če je bila vrednost že promovirana v `pim.*` in izvožena, popravek pride po običajni poti (validacija → promocija → izvoz), ne z vračanjem izvoza nazaj.
