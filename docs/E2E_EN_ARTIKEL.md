# End-to-end test enega artikla

Datum načrta: 2026-09-08  
Cilj: slediti enemu umetnemu artiklu skozi vse lokalno varne dele sistema in natančno pokazati,
kje se tok danes konča.

## Kaj ta test dokaže

```text
SAOP fixture ─┐
              ├─> RAW ─> preslikava ─> kanonični artikel ─> kakovost ─> CSV
NW/BT fixture ┘                                      └─> outbox ─> 127.0.0.1 SAOP fixture ─> echo
```

Test ne kliče živega SAOP-a, FTP-ja ali Magenta. Zato lahko dokaže celotno aplikacijsko
obdelavo, ne pa dosegljivosti in pogodbe zunanjih sistemov.

## Stabilna testna identiteta

Uporabi vrednosti, rezervirane samo za ta test:

| Podatek | Vrednost |
|---|---|
| Organizacija | izolirana testna organizacija, ki jo ustvari test; ne 1–4 |
| ItemID | `E2E-ONE-20260908` |
| EAN | `2999999909087` (testna vrednost, ne prava stranka/izdelek) |
| Ime | `E2E svetilka Črna; "Test"` |
| Vir ERP | `SAOP_E2E_FIXTURE` |
| Vir XML | `NW_E2E_FIXTURE` |
| CorrelationId | nov GUID ob vsakem zagonu |

Fixture naj vsebuje najmanj identiteto, naziv, mersko enoto, davčno/komercialno vrednost,
opis, en zahtevan atribut, kategorijo, sliko ter zalogo. Posebno ime hkrati preveri UTF-8 in
CSV escaping.

## Predpogoji

1. Delovni imenik je koren `NoviPIM`.
2. Connection string kaže izključno na lokalno razvojno bazo `PIM` in se ne izpisuje.
3. `PIM_SAOP_MODE` ni `Live`; outbound uporablja samo dinamični `127.0.0.1` listener.
4. Testni projekt sam ustvari in na koncu odstrani samo svoje podatke.
5. Pred E2E morajo biti zelene skupne kontrole:

```powershell
dotnet run --project PIM_Solution\src\PIM.Migrator -- --verify
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\run_tests.ps1
```

Na dan 2026-09-08 drugi ukaz še ni zelen zaradi build izhoda 1. E2E zato do odprave tega
stanja ne sme dobiti končne oznake PASS.

## Predlagani avtomatski projekt

Implementira naj se konzolni test `PIM_Solution/tests/PIM.E2E.OneProduct`, ki ga vključi
`scripts/run_tests.ps1`. En test, en proces in en `try/finally` omogočijo dokaz istega artikla
skozi vse korake; klicanje obstoječih F3/F5/F7/F8 testov zapored ni pravi E2E, ker vsak uporablja
druge podatke in cleanup.

## Koraki in pričakovani dokazi

### 1. Setup

- Ustvari izolirano organizacijo in aktivne fixture konektorje.
- Ustvari minimalne entity/field mappinge, validacijski profil, izvozni profil in izklopljen
  outbound profil za lokalni fixture.
- Za vsak ustvarjeni ključ vodi seznam za ozko čiščenje v `finally`.

PASS: setup se izvede v transakcijsko varnem vrstnem redu in ne spremeni organizacij 1–4.

### 2. SAOP vhod

- Zaženi isti ingest runner, ki ga uporablja `PIM.KatalogWorker`, s SAOP XML fixture za artikel.
- Shrani `RunId`.

PASS:

- `ops.PipelineRun.Status = 'Succeeded'`;
- `raw.Inbox` vsebuje fixture in pravi source/organization;
- `canon.Product.ItemID = 'E2E-ONE-20260908'` in EAN je pravilen;
- ponovitev istega vhoda ne ustvari drugega artikla.

### 3. XML obogatitev

- Vstavi NW fixture z istim EAN in drugim `RunId`.
- Poženi produkcijsko mapping pot, ne testnega nadomestka.

PASS: isti `ProductId` dobi opis, atribut, kategorijo in medij; ne nastane drugi artikel.
Vsaka vrednost ima dokazljiv izvor.

### 4. Zaloga

- Uporabi lokalni stock fixture za isti EAN.
- Zapiši en posnetek in nato isti posnetek ponovi.

PASS: prvi tek doda pričakovano zalogo, drugi je idempotenten; vir in čas posnetka sta pravilna.

### 5. Kakovost in promocija

- Najprej namerno izpusti zahtevani atribut.
- Poženi validacijo in dokaži BLOCKED.
- Nato dodaj vrednost prek XML mappinga in ponovno validiraj.

PASS: prvi rezultat pove točno manjkajoče polje in kdo ga lahko popravi; drugi je VALID za
izbrani spletni profil. Prehod ima zgodovino.

### 6. Kartica izdelka

- Preberi isti read model, ki ga uporablja intranetna kartica.

PASS: identiteta, SAOP polja, XML obogatitev, zaloga, kakovost in izvor se nanašajo na isti
`ProductId`; organizacijski kontekst je viden.

### 7. Spletni CSV

- Izvozi samo ta `ItemID` oziroma izolirano organizacijo v začasno mapo.

PASS:

- CSV vsebuje glavo in natanko eno podatkovno vrstico;
- `E2E svetilka Črna; "Test"` se po branju CSV vrne nespremenjeno;
- obvezni stolpci niso prazni;
- kategorija, atribut, slika in zaloga so iz pričakovanih virov;
- datoteka oziroma complete marker nastane šele po uspehu.

Končna dostava v Magento je v tem testu `SKIP`.

### 8. Sprememba v PIM in outbox

- Spremeni eno polje z lastništvom `PIM`, na primer dovoljeni spletni/ERP naziv.
- Ustvari outbound batch in sporočilo po produkcijski enqueue poti.
- Preveri, da sprememba SAOP-lastnega polja ne gre v vrsto.

PASS: v outboxu je eno sporočilo za testni artikel, dokument vsebuje novo in ne staro vrednost,
akter ter correlation ID sta zabeležena.

### 9. Lokalni SAOP write-back

- Zaženi lokalni HTTP listener na `127.0.0.1`.
- Prvi odgovor naj bo začasna napaka, drugi poslovni uspeh.
- Dispatcher mora uporabiti isti handler/run pot kot produkcijski worker.

PASS: vidna sta dva poskusa, retry je dovoljen, končni status je `Sent`, zajeti method/path/XML
pa se ujemajo s pogodbo. Noben zahtevek ne zapusti loopback vmesnika.

### 10. Echo

- Lokalni fixture naj najprej vrne drugačno vrednost, nato pričakovano.

PASS: prvi pregled zapiše drift in opozorilo, drugi spremeni stanje v `Verified`. Sam HTTP 200
ni dovolj.

### 11. Nadzor

- Preveri teke, heartbeat in alarme za correlation ID.

PASS: uspešen zaključek nima odprtega kritičnega alarma; namerno povzročena napaka iz koraka 9
je sledljiva in razrešena po uspehu.

### 12. Cleanup

- V `finally` odstrani samo vrstice testne organizacije in testnega artikla, v pravilnem FK
  vrstnem redu.
- Po čiščenju preveri, da ni ostal testni ItemID, EAN, RunId, batch ali message.

PASS: ni ostankov testnega scenarija in števci organizacij 1–4 so enaki kot pred testom.

## Izhod testa

Test naj izpiše samo varne identifikatorje in enovrstični rezultat vsakega koraka:

```text
E2E-01 SETUP              PASS
E2E-02 SAOP_TO_RAW        PASS RunId=<guid>
E2E-03 RAW_TO_CANON       PASS ProductId=<test-id>
E2E-04 XML_ENRICHMENT     PASS
E2E-05 STOCK              PASS
E2E-06 QUALITY            PASS blocked-then-valid
E2E-07 WEB_CSV            PASS rows=1
E2E-08 OUTBOX             PASS MessageId=<test-id>
E2E-09 LOCAL_DISPATCH     PASS attempts=2
E2E-10 ECHO               PASS drift-then-verified
E2E-11 MONITORING         PASS
E2E-12 CLEANUP            PASS
RESULT                    PASS
```

Gesla, connection string, pravi URL-ji in celotni payloadi se ne izpisujejo.

## Ročni živi dodatek po lokalnem PASS

To ni del avtomatskega E2E in zahteva odobritev za zunanji svet:

1. izberi potrjen neprodukcijski SAOP artikel;
2. izvedi read-only GET in primerjaj kartico;
3. dostavi en CSV v testni Magento/prevzemno mapo ter primerjaj hash in eno vrstico;
4. odobri eno nenevarno spremembo v SAOP;
5. preberi artikel nazaj in zahtevaj `Verified`;
6. dokumentiraj povrnitev vrednosti.

Šele ta dodatek odgovori, ali delujejo tudi resnični zunanji sistemi. Lokalni E2E odgovori,
koliko dela sama PIM rešitev.
