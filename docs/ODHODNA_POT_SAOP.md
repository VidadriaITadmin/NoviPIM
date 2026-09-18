# Pisanje nazaj v SAOP — kako preizkusiš

Datum: 2026-08-23. Stanje: **mehanizem je narejen in dokazan lokalno. V SAOP ni bilo poslano nič.**

Ta dokument je navodilo zate. Vsak korak pove, kaj narediš, kaj moraš videti in kaj pomeni,
če vidiš kaj drugega. **Do koraka 5 ne gre v SAOP nič** — tudi če se zmotiš.

> **Kdo sme pošiljati.** Pošiljanje zahteva **dva neodvisna pogoja hkrati**: zastavico `--send`
> in poverilnice v okoljskih spremenljivkah. Brez obojega worker ne pošlje ničesar in to pove.
> Nobena koda, ki teče sama od sebe, teh dveh pogojev ne izpolni.

---

## 0. Kaj sploh gre v SAOP

| Entiteta | Nov zapis | Sprememba | Sme PIM pisati? |
|---|---|---|---|
| **Izdelki** | `POST api/Item/AddItemsGeneralData` | `PATCH api/Item/UpdateItemsGeneralData` | **da**, 20 polj (migracija 068) |
| **Stranke** | `POST api/Customers/AddCustomer` | `PATCH api/V2/Customers/UpdateCustomer` | **samo naziv** — glej §7 |
| **Ceniki** | `POST api/pricelists/AddPriceLists` | `POST api/pricelists/ModifyPriceLists` | **ne** — glej §7 |
| **Cene** | `POST api/Price/AddPrices` | `POST api/V2/Price/ModifyPricesV2` | **ne** — glej §7 |

Oblike dokumentov so v tabeli `out.SaopDocument`, polja v `out.SaopXmlField`. Nič od tega ni v
kodi — vse je podatek, ki ga lahko popraviš brez nove migracije.

---

## 1. Poglej, kakšen XML bi šel ven (nič ne odide)

```powershell
cd C:\Users\david\Desktop\PIM\NoviPIM\PIM_Solution
$j = Get-Content ..\appsettings.Local.json -Raw | ConvertFrom-Json
$env:PIM_CONNECTION_STRING = $j.ConnectionStrings.Pim

# predogled za resnične artikle iz baze
cd tools\PIM.SaopXmlPreview
dotnet run -- --org 2 --sample 5 --out C:\Temp\saop-predogled
```

**Kaj moraš videti:** tabelo z metodo (`PATCH`/`POST`), številom polj in imenom datoteke, ter na
koncu `Nič ni bilo poslano — to je samo predogled.`

**Odpri eno datoteko.** Tako izgleda dokument, ki bi šel v SAOP. Če se ti kaj ne zdi prav, se
popravi **zdaj** — ne po prvem pošiljanju.

> **Opozorilo o ničlah.** Predogled sestavi *cel* dokument iz vseh trenutnih vrednosti. Če
> vidiš `POZOR: n številčnih polj ima vrednost nič`, so to polja, ki bi v SAOP prepisala pravo
> vrednost z nič. Prava pot tega ne počne — pošlje **samo tisto, kar je urednik spremenil** —
> a pri predogledu je treba to videti.

---

## 1a. Isto iz intraneta: stran `/saop/artikli`

Dodano 2026-09-02. Kar je spodaj napisano s SQL-om, je od zdaj na strani
**Izhod v SAOP → Artikli** (`Pages/SaopItems.razor`, vloge `ADMIN, CATALOG_EDITOR`).

Kaj stran naredi in česa **ne**:

| Naredi | Ne naredi |
|---|---|
| za vsako šifro prebere `out.GetSaopItemWriteState` in pokaže, ali gre **POST (nov)** ali **PATCH (sprememba)** — z razlogom | ne ponuja preklopnika metode; ADD/PATCH ni izbira uporabnika |
| sestavi dokument z `SaopItemPlanner` (isti `SaopDocumentBuilder` in `SaopIntentResolver` kot pošiljatelj) in ga pokaže z metodo in potjo | ne uporablja `out.ClaimItemDocument` — prevzem bi porabil poskus in postavil lease (migracija 086) |
| uvrsti spremembe v vrsto prek `SaopWriteService.EnqueueAsync` → `out.EnqueueSaopItemChanges` | ne piše v bazo mimo te poti in ničesar ne pošlje v SAOP |
| ponudi samo polja iz `intranet.GetWritableSaopFields` (23 od 26 elementov pogodbe) | ne ponudi polja, ki bi ga `out.EnqueueMessage` zavrnil z 51010 |
| prebere delovni zvezek (isti stolpci kot `izvoz/izdelki.xlsx?predloga=saop`) | prazne celice ne pošlje — prazno pomeni »tega polja se ne dotakni«, ne »izprazni ga« |
| piše dnevnik: v okno (**Dnevnik seje**) in v dnevnik strežnika (`SaopItemWriteService`) | ne skriva zavrnitev — vsaka je v izidu skupine in v dnevniku |

**Zakaj metoda ni izbira uporabnika.** V stari vrsti (`..\PIM_test`,
`pim.SaopItemOutboundQueue`) je bilo 118 od 130 napak natanko ta ena ročna odločitev:
poslan ADD, kjer bi moral biti PATCH, in obratno. Zato sta stari strani
`/export/saop-item-new` in `/export/saop-item-edit` tu **ena** stran.

**Iz česa je metoda izpeljana (od migracije 169).** Merilo je `canon.Product.ErpExistence`:
`CONFIRMED_IN_ERP` → PATCH, `NOT_YET_IN_ERP` (ali artikla v `canon.Product` sploh ni) → POST.
Berejo ga vsa tri mesta, ki metodo določajo: `out.GetSaopItemWriteState` (kartica in predogled),
`out.ClaimItemDocument` (pravi prevzem) in `out.PeekItemDocuments` (suhi tek).

Do 169 je bilo merilo »ali vrstica obstaja v `canon.Product`«. To je držalo samo, dokler je
artikle smel ustvarjati izključno SAOP (`map.SourceConnector.CanCreateProducts = 1`, migracija
042). Ko artikle začnejo ustvarjati še viri, ki niso ERP (scraper, ročni Excel), je tak artikel
v PIM, v SAOP pa ga ni — staro merilo bi zanj izbralo PATCH na zapis, ki v SAOP ne obstaja.

Privzetek stolpca je `CONFIRMED_IN_ERP`, zato se za vse artikle, ki so v bazi nastali do 169,
metoda ne spremeni. Zapis `NOT_YET_IN_ERP` ob ustvarjanju iz ne-ERP vira je ločen korak
(skupaj z registracijo takega vira); `map.ProcessRawInbox` se v 169 ne dotika.

Varovalka ostaja: če je zastavica kljub temu napačna, odgovor SAOP prevlada nad njo —
`ItemAlreadyExists` preklopi na PATCH, `ItemNotFound` na POST (`SaopIntentResolver`), in to se
zgodi znotraj istega prevzema, brez porabe drugega poskusa.

**Pogoj, da se da uvrstiti v vrsto.** `dbo.IntegrationProfile` mora imeti omogočeno vrstico
za `SAOP_PRODUCT` in to organizacijo. Dokler je nima, stran to pove takoj in v vrsto ne gre
nič (`51001`). Vnos, predogled in dokument delujejo tudi brez profila — to je namenoma, da se
da vse pripraviti in pogledati, preden se kanal odpre.

> **Stanje razvojne baze 2026-09-02: kanal je odprt.** Na uporabnikovo zahtevo je
> `dbo.IntegrationProfile` dobila vrstico za `SAOP_PRODUCT` pri vseh štirih podjetjih
> (1 DEMO, 2 IQLighting, 3 Vidadria, 4 Ediito): `EndpointTemplate` =
> `https://192.168.178.12:82/iCenterAPI/` (**vrata 82 = TEST**), `ApprovalMode` =
> `ManualApproval`, `IsEnabled = 1`.
>
> **To ni migracija in ne sme postati migracija.** `docs/EXPORTS.md` §410: migracije ne
> zasejejo nobene vrstice v `dbo.IntegrationProfile`. Naslov SAOP je okoljska nastavitev;
> migracija bi kanal odprla v vsakem okolju, kjer se požene.
>
> **Odprt kanal še vedno ne pošilja.** Preverjeno ob vklopu, trije neodvisni razlogi:
> pot dokumenta zahteva `--send` **in** `SAOP_BASE_URL`/`SAOP_USERNAME`/`SAOP_PASSWORD`
> (`workers/PIM.OutboxDispatcher/Program.cs`); stara pot po enem sporočilu zahteva omogočen
> razpored `OUTBOUND` v `ops.ScheduleProfile`, ta pa je **prazen**; nobeno načrtovano
> opravilo (`PIM nadzor`, `PIM nocni tok`, `PIM zaloga`) dispatcherja ne poganja.
>
> Zapiranje kanala je ena vrstica:
> `UPDATE dbo.IntegrationProfile SET IsEnabled = 0 WHERE TargetKind = N'SAOP_PRODUCT';`

---

## 2. Naroči spremembo (v vrsto, ne v SAOP)

Sprememba mora najprej nastati kot naročilo. Brez omogočenega integracijskega profila naročilo
pade z napako `51001` — to je namerno.

```sql
USE PIM;
DECLARE @Batch bigint, @Msg bigint;

-- ena skupina za vse spremembe enega uvoza ali ene množične akcije
EXEC out.BeginOutboundBatch
  @OrganizationId = 2, @Source = N'SINGLE', @Note = N'Prvi ročni test', @Actor = N'david',
  @OutboundBatchId = @Batch OUTPUT;

EXEC out.EnqueueSaopItemChange
  @OrganizationId = 2, @ItemID = N'NW.12603',
  @FieldKey = N'ProductText.TITLE_ERP.sl', @Value = N'Testni naziv',
  @Actor = N'david', @OutboundBatchId = @Batch, @OutboxMessageId = @Msg OUTPUT;

SELECT * FROM out.OutboxMessage WHERE OutboundBatchId = @Batch;
```

**Kaj moraš videti:** eno vrstico s `Status = 'PendingApproval'` (ali `Pending`, če je profil
nastavljen na `Automatic`).

Kaj lahko gre narobe in kaj pomeni:

| Napaka | Pomen |
|---|---|
| `51001` | integracijski profil za to organizacijo ni omogočen — korak 4 |
| `51010` | polje ni v lasti PIM; poglej `out.OwnershipPolicy` |
| `52842` | polje ni del dokumenta `ItemsGeneralData` — poglej `out.SaopXmlField` |

---

## 3. Odobri in poglej, kaj bo poslano

Odobritev sporočilo **samo uvrsti v vrsto** — ne pošlje ga.

```sql
EXEC out.ApproveMessage @OutboxMessageId = <id>, @Actor = N'david';
```

Nato suhi tek celotne poti:

```powershell
cd C:\Users\david\Desktop\PIM\NoviPIM\PIM_Solution\workers\PIM.OutboxDispatcher
dotnet run -- --saop-documents --org 2 --out C:\Temp\saop-suhi
```

**Kaj moraš videti:**

```
Suhi tek: nič ne bo poslano in v bazi se nič ne spremeni.
  NW.12603: PATCH api/Item/UpdateItemsGeneralData (2 polj, 1 sprememb) — Artikel je v kanoničnem modelu…
Dokumentov: 1, poslanih: 0, neuspešnih: 0, nepopolnih: 0.
Nič ni bilo poslano — to je bil suhi tek.
```

`nepopolnih: 0` je pomembno. Če je večje od nič, dokumentu manjka obvezno polje in SAOP bi ga
zavrnil — popravi podatek, ne pošiljaj.

Suhi tek **ne porabi poskusa** in ne spremeni nobenega stanja. Poganjaš ga lahko kolikorkrat.

---

## 4. Odpri kanal (še vedno ne pošilja)

Šele zdaj nastane vrstica v `dbo.IntegrationProfile`. To je edino mesto, kjer se pove naslov
SAOP za posamezno organizacijo.

```sql
USE PIM;
INSERT dbo.IntegrationProfile
  (OrganizationId, TargetKind, EndpointTemplate, HttpOperation, ApprovalMode, IsEnabled,
   TimeoutSeconds, MaxAttempts, BaseRetrySeconds, UpdatedBy)
VALUES
  (2, N'SAOP_PRODUCT',
   N'https://192.168.178.12:82/iCenterAPI/',   -- :82 = TEST, :81 = PRODUKCIJA
   N'PATCH', N'ManualApproval', 1, 120, 5, 30, N'david');
```

> **Uporabi vrata 82 (test).** Vrata 81 so produkcija. V stari vrsti je 112 od 130 napak
> nastalo proti vratom 81 — pisalo se je v produkcijo, preden je bilo kaj preizkušeno.

`ApprovalMode = 'ManualApproval'` pomeni, da vsako sporočilo posebej odobriš. Pusti tako, dokler
si ne zaupaš.

Odpiranje kanala samo po sebi **še vedno ne pošlje ničesar** — worker je še vedno v suhem teku.

---

## 5. Prvo pravo pošiljanje

Zdaj gre res ven. Naredi to na **enem artiklu**, ki ti ni pomemben.

```powershell
cd C:\Users\david\Desktop\PIM\NoviPIM\PIM_Solution\workers\PIM.OutboxDispatcher

$j = Get-Content ..\..\..\appsettings.Local.json -Raw | ConvertFrom-Json
$env:PIM_CONNECTION_STRING     = $j.ConnectionStrings.Pim
$env:SAOP_BASE_URL             = 'https://192.168.178.12:82/iCenterAPI/'
$env:SAOP_USERNAME             = '<uporabnik>'
$env:SAOP_PASSWORD             = '<geslo>'
$env:SAOP_ACCEPT_UNTRUSTED_CERT = 'true'   # SAOP iCenter ima lasten certifikat

dotnet run -- --saop-documents --org 2 --max 1 --send
```

`--max 1` je varovalka: en dokument in konec.

**Kaj moraš videti:**

```
POZOR: pošiljanje v SAOP je vklopljeno. Naslov: https://192.168.178.12:82/iCenterAPI/
  NW.12603: PATCH uspešno
Dokumentov: 1, poslanih: 1, neuspešnih: 0, nepopolnih: 0.
```

**Poverilnic ne shranjuj v repozitorij.** Okoljske spremenljivke veljajo samo za to okno
PowerShella in izginejo, ko ga zapreš.

---

## 6. Kaj pomeni, kar SAOP odgovori

Napaka se zapiše kot **navodilo**, ne kot surov HTTP izpis. Poglej `LastError` in `SaopErrorKind`
na sporočilu, ali stran **Izvozi** v intranetu.

| Kaj vidiš | Kaj pomeni | Kaj narediš |
|---|---|---|
| `ItemAlreadyExists` | poslan nov artikel, SAOP ga že ima | **nič** — PIM takoj ponovi kot spremembo |
| `ItemNotFound` | poslana sprememba, SAOP artikla ne pozna | **nič** — PIM takoj ponovi kot nov artikel |
| `CodebookMissing` + `GeneralData/CustomsTariffNo` | carinska tarifa ni v šifrantu SAOP | popravi tarifo v PIM ali jo dodaj v SAOP |
| `CodebookMissing` + `GeneralData/ItemGroup` | skupina artikla ni v šifrantu | popravi skupino ali jo dodaj v SAOP |
| `CodebookMissing` + `GeneralData/ItemType` | napačen tip artikla | dovoljene oznake pove SAOP v sporočilu |
| `SupplierMissing` | dobavitelj ne obstaja ali ni aktiven | preveri šifro, sicer naj ga skrbnik aktivira |
| `AuthConfig` | poverilnica ali pravica | **kanal se sam ustavi**; popravi in ga znova omogoči |

Prvi dve vrsti sta bili v stari vrsti **118 od 130 vseh napak**. Zdaj ju popravi sistem sam, v
istem zagonu in brez porabe drugega poskusa.

> **HTTP 200 ni dokaz.** SAOP zna vrniti 200 z `ResultCode=Error` v telesu. Pot to prebere in
> šteje kot zavrnitev. Stari sistem je gledal samo HTTP kodo.

---

## 7. Česa namerno ni

**Cene in ceniki se ne pošiljajo.** Na listih `Cene` (18 polj) in `Ceniki` (13 polj) preglednice
`Mapiranje_SAOP_API_PIM.xlsx` je smer pri vseh `SAOP -> PIM` ali `samo RAW`, master pa povsod
SAOP. Oblika dokumenta in poti so zapisane in mehanizem dela — pravice do pisanja pa **nisem
podelil**, ker bi to nasprotovalo preglednici, na kateri stoji ves model lastništva.

Če hočeš, da PIM piše ceno, je to ena vrstica in tvoja odločitev:

```sql
UPDATE out.OwnershipPolicy SET Owner = N'PIM'
WHERE TargetKind = N'SAOP_PRICE' AND FieldName = N'Price.Net' AND OrganizationId = 2;
```

**Stranke imajo eno pisljivo polje — naziv.** Po preglednici jih je pisljivih deset, a pravilo
O9 (*kar ne beremo nazaj, ne smemo pisati*) dovoli samo tista, ki jih tudi zajemamo.
`b2b.Customer` ima danes **0 vrstic** in štiri stolpce. Ko bo zajem strank tekel, se ostalih
devet polj doda po istem vzorcu.

---

## 8. Kaj še ni narejeno

Da ne bo nejasno, kaj je in kaj ni:

| Narejeno in dokazano | Še ni |
|---|---|
| pogodba XML za vse štiri entitete | množični izbor in urejanje v intranetu |
| naročilo spremembe z vsemi varovalkami | uvoz Excela |
| združevanje sprememb enega zapisa v en dokument | prekrivka »čaka potrditev« na kartici izdelka |
| suhi tek brez porabe poskusa | obvestila po korakih + e-pošta po 5 minutah |
| Basic + `OrganisationId` + `application/xml` | klic `out.VerifyEcho` iz vhodne preslikave |
| branje odgovora, vključno z `windows-1250` | ciljno delta branje po pošiljanju |
| samopopravek ADD/PATCH | razpored `OUTBOUND` in kaj poganja workerja |
| prevzem šifre, ki jo dodeli SAOP | |

Zadnji dve vrstici desnega stolpca sta iz `docs/NACRT_INTRANET_PRENOVA.md` §4.7 in sta pogoj,
da poslano sporočilo sploh kdaj postane `Verified`. Danes bi obstalo v `Sent`.

---

## 9. Če gre kaj narobe

**Ustavi vse:**

```sql
UPDATE dbo.IntegrationProfile SET IsEnabled = 0 WHERE TargetKind = N'SAOP_PRODUCT';
```

Od tega trenutka ne gre ven nič, tudi če worker teče.

**Prekliči čakajoča sporočila:**

```sql
EXEC out.CancelMessage @OutboxMessageId = <id>, @Actor = N'david';
```

**Poglej, kaj se je zgodilo:** vsak poskus je vrstica v `out.OutboxAttempt` z `WorkerId`, časi,
izidom, HTTP kodo in odgovorom, iz katerega so odstranjene skrivnosti.
