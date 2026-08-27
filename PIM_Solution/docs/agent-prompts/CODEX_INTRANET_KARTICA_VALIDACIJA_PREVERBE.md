# Prompt za Codexa — prenova intraneta NoviPIM

> **Ta dokument nadomešča** `docs/Sprecifikacije_starega_PIMa/Sestva_PIMa/Prompt_Codex_Delovna_Okolja_Reorganizacija.md`.
> Tisti opisuje **star sistem PIM_test** (mape `src/`, sheme `stg`/`pim`, strani `/products`,
> `/quality/issues`, tabele `pim.ProductValidationIssue`). **Nič od tega v NoviPIM ne obstaja.**
> Star dokument beri samo kot zamisel, kaj uporabnik želi — ne kot navodilo, kaj naj napišeš.
>
> Zapisano 2026-08-27. Piši v slovenščini. Komentar v kodi samo tam, kjer WHY ni očiten.

---

## 0. Kaj je tvoja naloga in kje se ustaviš

Delaš **samo v `PIM_Solution/src/PIM.Intranet`**. To je edino ozemlje te naloge.

**Ne delaj tega:**

- ne pišeš SQL migracij (`PIM_Solution/sql/migrations/` se v tej nalogi ne dotakneš),
- ne spreminjaš workerjev (`PIM_Solution/workers/`), cevovoda ali `map.*` konfiguracije,
- ne polniš tabel, ne poganjaš `INSERT`/`UPDATE` proti bazi,
- ne izmišljaš podatkov, da bi stran izgledala polna.

**Cilj naloge:** ko končaš, morava z uporabnikom intranet **videti** — odpreti vsako stran in
razumeti, kaj bo na njej, kje so podatki in kje jih še ni. Šele po tem gremo na bazo, nato na
cevovod, ki tabele polni. Vrstni red je namenoma tak: **najprej vidno, potem shema, potem polnjenje.**

Zato je ključno pravilo te naloge §4 (»manjkajoč bralni model«). Preberi ga, preden napišeš
prvo stran.

**Ko končaš**, napišeš `docs/porocila-faz/BAZA_ZAHTEVE_INTRANET.md` po predlogi iz §12 — natančen
seznam, kaj mora v bazo, da bo vsaka stran zaživela. Ta datoteka je drugi glavni izdelek naloge,
enakovreden kodi.

---

## 1. Obvezno branje pred prvo spremembo

| Datoteka | Zakaj |
|---|---|
| `AGENTS.md` | edina pravila; §3 pove, kaj šteje kot dokaz, §4 kdaj se ustaviš in vprašaš |
| `docs/VALIDACIJA.md` | dejanski validacijski profili, resnost, obseg blokade — podlaga za §6 |
| `docs/DATABASE.md` | sheme `raw`/`map`/`canon`/`val`/`pim`/`stock`/`out`/`ops`/`sec`/`intranet` |
| `docs/PRODUKTNI_MODEL_PIM.md` | sedem faz toka; vsaka stran mora vedeti, v kateri je |
| `src/PIM.Intranet/Services/PimNavigation.cs` | **vir resnice za meni in za faze toka** |
| `src/PIM.Intranet/Components/Pages/ProductCard.razor` | trenutna kartica izdelka, ki jo predelaš |
| `src/PIM.Intranet/Components/Shared/*.razor` | gradniki, ki jih moraš uporabiti (§3) |

Preveri stanje v kodi, preden karkoli gradiš. Ta dokument je nastal iz analize 27. 8. 2026 in
opisuje stanje ob migraciji 104 — koda se je lahko premaknila.

---

## 2. Dejansko stanje — kaj že obstaja (ne gradi na novo)

Migracij: **001–104**. Strani: 52 poti. Storitev v `Services/`: 18.

| Področje | Pot | Stanje |
|---|---|---|
| Nadzorna plošča | `/nadzorna-plosca` | deluje |
| Seznam izdelkov | `/izdelki` | deluje (`intranet.GetProductList`, migracija 101) |
| **Kartica izdelka** | `/izdelki/{id}` | deluje, 12 zavihkov (`intranet.GetProductCard`, migracija 100) — **predelaš v §5** |
| Stara kartica | `ProductDetail.razor` | brez poti, samo zgodovinska sled — **pusti pri miru** |
| Mediji | `/mediji` | seznam URL-jev brez slik — **predelaš v §5.4** |
| Kakovost | `/kakovost` | tabela po profilih — **predelaš v §6** |
| Napake validacije | `/kakovost/napake` | deluje (`intranet.GetQualityIssues`, migracija 102) |
| Karantena / prevodi / kategorije | `/kakovost/karantena`, `/kakovost/prevodi`, `/kakovost/kategorije` | deluje |
| Cene | `/cene` | gol seznam cen — **razširiš v §7** |
| Zaloga | `/zaloge` | deluje (`intranet.GetStockOverview`, migracija 103) |
| Izvozi | `/izvozi` | pripravljenost izvoza (`intranet.GetExportReadiness`, migracija 104) |
| Odhodna pošta | `/outbound` | deluje (`out.OutboxMessage`, odobri/prekliči/ponovi) |
| Množično urejanje | `/izvozi/mnozicno` | deluje |
| Obvestila odhodne poti | `/izvozi/obvestila` | deluje (`ops.OutboundEvent`) |
| Zajem | `/zajem/*` | deluje (viri, teki, čakalna vrsta, neujemanja) |
| Nastavitve kataloga | `/nastavitve/*` | atributi, kategorije, skladišča, kanali, jeziki — vse **samo bralno** |
| Pravila | `/pravila/*` | validacija, slovar, preslikave |
| Stranke, partnerji, popusti | `/stranke`, `/partnerji`, `/pravila-popustov` | deluje |
| Sistem | `/sistem/*` | uporabniki, vloge, integracije, napake |

### Tabele, ki obstajajo (izvleček)

```
canon.Product, ProductText, ProductAttribute, ProductCategory, ProductCommercial,
      ProductMedia, ProductDocument, ProductPrice, ProductPlanning,
      ProductStockAccounting, ProductStockPolicy, Category, CategoryTranslation,
      Codebook, Language, Warehouse, WebSite
val.ValidationProfile, FieldRequirement, ProductIssue, ProductValidationState
pim.Product, ProductPrice, ProductMedia, FieldOwnership, ProductFieldHistory,
     ProductChangeBatch, CustomerWebProfile, ...
stock.LandingRecord, Snapshot, Position, UnmatchedPosition, SyncRun
out.ExportProfile, ExportColumn, ExportPriceList, OutboxMessage, OutboxAttempt,
    OutboundBatch, OwnershipPolicy, SaopXmlField, SaopDocument
ops.Alert, AlertDelivery, OutboundEvent, PipelineRun, ErrorLog, Heartbeat
map.FieldMapping, FieldTransform, ValueLookup, MissingTranslation, ExtractedValue,
    CategoryPathMap, SourceCategory, SourceConnector
```

### Tabel, ki jih uporabnikova zahteva potrebuje, **ni**

`pim.ProductLink` (variante/podobni/povezani) · šifrant preverb cen in zaloge · pragovi marže ·
min/max zaloge · atributni šifrant z lastnimi metapodatki · prevodi naziva izdelka po jeziku.

**To je pričakovano.** Strani zanje vseeno zgradiš — po pravilu iz §4 — in jih vpišeš v poročilo §12.

---

## 3. Kako mora stran izgledati (konvencija, ki je ne kršiš)

Vsaka nova ali predelana stran uporabi obstoječe gradnike iz `Components/Shared/`. Ne pišeš
svojega HTML-a za stvari, ki gradnik že reši, in ne uvajaš novih CSS razredov, če obstoječi zadošča.

```razor
@page "/pot"
@attribute [Authorize]                      @* ali [Authorize(Roles = "...")] *@
@rendermode InteractiveServer               @* samo če stran res ima interakcijo *@
@inject ...

<PageTitle>Naslov</PageTitle>
<PimPage Title="Naslov" Subtitle="Ena poved: kaj ta stran pove in česa ne." Crumbs="Crumbs" />

<section class="kpi-grid" aria-labelledby="...">        @* števci; vsak klikljiv, če filtrira *@
  <PimStat Label="..." Value="..." Note="..." Href="..." />
</section>

<section class="ui-card toolbar" role="search">          @* filtri *@
  ...
</section>

<section class="ui-card data-card">
  <PimState Loading="Loading" Error="@Error" Empty="@(Rows.Count == 0)"
            EmptyText="..." LoadingText="...">
    <PimTable Caption="..." Columns="Columns"><Rows>...</Rows></PimTable>
    <PimPager Skip="Skip" Take="Take" Total="Total" SkipChanged="OnSkipChangedAsync" Label="..." />
  </PimState>
</section>
```

| Gradnik | Za kaj |
|---|---|
| `PimPage` | naslov, podnaslov, drobtine |
| `PimStat` | KPI števec; `Href` naredi kartico klikljivo v filtriran pogled |
| `PimState` | eno mesto za nalaganje / napako / prazen rezultat — **nikoli ne pišeš svojih treh vej** |
| `PimTable` + `PimColumn` | tabela s `caption`, `scope`, numeričnimi stolpci |
| `PimPager` | strani; vedno pri seznamih nad 50 vrsticami |
| `PimChip` | značka stanja (`Tone`: `good` / `warn` / `bad` / null) |
| `PimBar` | delež v odstotkih |
| `PimHubCard` | kartica na razdelilni strani |
| `PimContextPicker` | preklop organizacije |

**Zahteve, ki veljajo brez izjeme:**

1. **`OrganizationId` povsod.** Vsaka poizvedba, vsak seznam, vsak števec. Aktivno organizacijo
   dobiš z `Data.GetCurrentOrganizationAsync()`; če je `null`, stran pošteno pove
   »Aktivna organizacija ni na voljo.« in ne kaže ničesar.
2. **Vsaka pot v `PimNavigation.cs`.** Nova stran, ki ni v meniju, mora biti dosegljiva z
   razdelilne strani. Vsaka pot v meniju natanko enkrat. Novo pot uvrsti tudi v pravi
   `PimLifecycleArea.RoutePrefixes`, sicer je uporabnik ne bo znal umestiti v tok.
3. **En koncept = eno mesto.** Ne dodajaj filtra, stolpca ali gumba, ki ga nihče ni zahteval.
4. **Ni navideznih gumbov.** Če zapisovalna procedura ne obstaja, gumba za shranjevanje ni.
   Namesto tega §4.
5. **Zunanji URL ni klikljiv, dokler ni preverjen** — glej `MediaUrlPolicy` v §5.4.
6. **Dostopnost:** vsaka tabela ima `<caption>`, vsak filter `<label>` (lahko `visually-hidden`),
   vsak živi števec `role="status" aria-live="polite"`, `aria-selected` se izpiše kot niz
   (`"true"`/`"false"`), ne kot logična vrednost.
7. **Datum in čas** vedno `.ToLocalTime()`; številke `N0`/`N2`; odstotki `0.#`.
8. **Prazna vrednost je `—`**, nikoli prazna celica in nikoli `0`, če vrednosti ni.

---

## 4. Osrednje pravilo naloge: manjkajoč bralni model

Večino strani iz te naloge gradiš **pred** tabelami, ki jih hranijo. Da to ni laž, velja:

### 4.1 Kaj naredi storitev

Vsak nov klic v `Services/` je ovit tako, da **loči manjkajočo shemo od prave napake**:

```csharp
// SQL 2812 = procedura ne obstaja, 208 = objekt ne obstaja, 207 = stolpec ne obstaja.
// Dokler bralni model ni nameščen, to ni napaka aplikacije, ampak znano stanje,
// ki ga stran pokaže po imenu manjkajočega objekta.
public static bool IsMissingReadModel(SqlException error) =>
  error.Number is 2812 or 208 or 207;
```

Vrni rezultat, ki to nosi — npr. `PimReadResult<T>(IReadOnlyList<T> Rows, long Total, string? MissingObject)`.
Novo skupno kodo daj v `Services/PimReadResult.cs`.

### 4.2 Kaj naredi stran

Nova skupna komponenta `Components/Shared/PimMissing.razor`:

```razor
<PimMissing Object="intranet.GetPriceChecks"
            What="preverbe cen po artiklu in ceniku"
            Needs="canon.ProductPrice (obstaja) + šifrant preverb + prag marže" />
```

Izriše sivo, jasno označeno ploščo:

> **Bralni model še ni nameščen.**
> Ta pogled bere `intranet.GetPriceChecks`, ki v bazi še ne obstaja.
> Potrebuje: *preverbe cen po artiklu in ceniku* iz `canon.ProductPrice` + šifrant preverb + prag marže.
> Stran je pripravljena; ko procedura nastane, se napolni brez spremembe kode.

**Plošča ne sme:** izgledati kot napaka (ni rdeča), vsebovati izmišljenih številk, primerov
vrstic ali »demo« podatkov. Postavitev strani okoli nje (naslov, filtri, glava tabele, KPI
kartice z `—`) **ostane vidna**, ker je prav ta postavitev tisto, kar morava z uporabnikom videti.

### 4.3 Zakaj tako

Ker je besedilo v `PimMissing` **hkrati vnos v poročilo §12**. Ko končaš, se seznam manjkajočih
objektov sestavi iz istih besed, ki jih uporabnik vidi na zaslonu. Nič se ne izgubi med UI-jem
in bazo.

---

## 5. Sklop A — Kartica izdelka

**Pot:** `/izdelki/{ProductId:long}` · **Datoteka:** `Components/Pages/ProductCard.razor`
(razdeli na `Components/Pages/ProductCard/*.razor`, če preseže 400 vrstic)
**Bralni model:** `intranet.GetProductCard` (obstaja, 15 naborov), `intranet.GetProductOrigin`

Uporabnikova zahteva dobesedno: *»da se na kartici artikla vidi ERP podatke, potem komerciala in
splet. Potem da ima medije in da se vidijo slike.«*

### 5.1 Glava kartice (nad zavihki)

Ostane hero, ki že obstaja, s temi popravki:

- **Sličica namesto napisa `MEDIJ`.** Danes je v `product-hero` prazna ploščica. Zamenjaj jo z
  dejansko sliko glavnega medija (`<img>` z `loading="lazy"`, `alt="@Detail.Header.Name"`),
  naslov normaliziran po §5.4. Če slike ni ali se ne naloži, ostane ploščica z napisom
  »Brez slike« — ne pokvarjena ikona.
- **Trak kanalov.** Pod identiteto tri kartice, ena na kanal, v tem vrstnem redu:

  | Kartica | Kaj kaže | Klik |
  |---|---|---|
  | **ERP (SAOP)** | status `ERP_SLO` + `ERP_EU/THIRD`, število blokirajočih napak | odpre zavihek ERP |
  | **Komerciala** | status `KOMERCIALA`, število opozoril (nikoli ne blokira) | odpre zavihek Komerciala |
  | **Splet** | status `SPLET` **po spletnem mestu** (`canon.WebSite`), skupno stanje | odpre zavihek Splet |

  Barva kartice sledi `PimChip.Tone`. **Komerciala nikoli ni rdeča** — po `docs/VALIDACIJA.md`
  profil `COMMERCIAL_L2` ničesar ne blokira; njegove pomanjkljivosti so rumene.

### 5.2 Zavihki — nova razdelitev

Zamenjaj današnjih 12 ploskih zavihkov s tem zaporedjem. Vsak zavihek je **en kanal ali en
sklop dokazov**, ne ena tabela.

| # | Zavihek | Vsebina |
|---|---|---|
| 1 | **Pregled** | identiteta, ključna polja z lastnikom in čakajočo prekrivko (obstoječa `Detail.Fields`), povzetek treh kanalov |
| 2 | **ERP** | §5.3 |
| 3 | **Komerciala** | §5.3 |
| 4 | **Splet** | §5.3 |
| 5 | **Mediji** | §5.4 |
| 6 | **Cene** | cene po cenikih + preverbe iz §7, filtrirane na ta artikel |
| 7 | **Zaloga** | pozicije po skladišču + svežina posnetka + preverbe iz §7 |
| 8 | **Kakovost** | vse odprte težave artikla, **razvrščene po nivoju validacije** (§6), ne po profilu |
| 9 | **SAOP** | odhodna sporočila tega artikla in njihovo stanje (§8) |
| 10 | **Zgodovina** | `pim.ProductFieldHistory` (obstaja) |
| 11 | **Izvor** | `intranet.GetProductOrigin` (obstaja) |

Zavihek s številom v oklepaju ohrani obstoječi vzorec: `Mediji (7)`.

### 5.3 Trije kanalski zavihki — enaka zgradba, različna polja

Vsak od treh zavihkov ima **enako postavitev**, da se uporabnik nauči enkrat:

```
┌─ Stanje kanala ──────────────────────────────────────────────┐
│  PimChip status  ·  N blokirajočih napak  ·  M opozoril      │
│  Zadnja validacija: pred 14 min                              │
└──────────────────────────────────────────────────────────────┘

Polja kanala               (PimTable: Polje | Vrednost | Lastnik | Vir | Svežina | Čaka SAOP)
Odprte težave kanala       (PimTable: Resnost | Profil | Zahteva | Sporočilo | Zaznano)
```

**Stolpec »Svežina«** je nova skupna zahteva: ob vsaki vrednosti, ki pride iz ERP-ja ali vira,
piše »pred X« (`PimAgo` — nov statični pomočnik v `Services/PimFormat.cs`; ne podvajaj formatiranja
po straneh). Če časa zajema za polje ni, piše `—`, nikoli izmišljen čas.

**Kje so polja:**

| Zavihek | Polja | Vir v bazi |
|---|---|---|
| **ERP** | ItemID, EAN, naziv, enota mere, skupina artikla, oddelek, davčna stopnja, aktiven, skupina popusta, planiranje/rezervacija, knjigovodske šifre | `canon.Product`, `canon.ProductPlanning`, `canon.ProductStockAccounting`, `canon.Codebook` |
| **Komerciala** | neto/bruto teža, dimenzije, pakiranja (Pak1/Pak2, kosov v paketu), carinska tarifa, država porekla, dobavitelj, proizvajalec, nabavni podatki | `canon.ProductCommercial` |
| **Splet** | spletni naziv in drugi naziv, opisi po jezikih, kategorije po spletnem mestu, atributi za splet, `WebPublish`, slike za splet, spletni kanali | `canon.ProductText`, `canon.ProductCategory`, `canon.ProductAttribute`, `canon.WebSite` |

Polja, ki jih `intranet.GetProductCard` danes ne vrne, **ne izmisliš**: vrstica je v tabeli, v
stolpcu »Vrednost« pa `PimMissing`-slog opomba »ni v bralnem modelu« — in gre v poročilo §12.

**Zavihek Splet je edini, ki ima izbirnik spletnega mesta** (`canon.WebSite`), ker so spletni
podatki in spletna validacija per-mesto (danes `WEB_svetila_si`, `WEB_videlektro`). Brez izbirnika
bi stran mešala dve resnici.

### 5.4 Mediji na kartici in naslovi Nowodvorskega

Uporabnikova zahteva: *»da ima medije in da se vidijo slike in za NW je treba popraviti da se
doda `https:` spredaj pred njihovim linkom.«*

**Dejansko stanje, ki si ga preveril:** v `fixtures/nw/products_en_US.xml` so naslovi zapisani
brez sheme, kot `//pim.nowodvorski.com/media/files/203.jpg`. Trenutni
`SafeMediaUrl` (`Media.razor`) in `SafeUrl` (`ProductCard.razor:355`) zahtevata `UriKind.Absolute`,
zato tak naslov **odpade** — slika se ne prikaže in povezava se ne izriše. Enak izračun je
podvojen na dveh mestih z dvema imenoma.

**Naredi eno pot za oboje:** nov `Services/MediaUrlPolicy.cs`, čista funkcija brez odvisnosti.

```csharp
public sealed record MediaUrl(string? Href, string Display, string? Note);

public static MediaUrl Normalize(string? raw);
```

Pravila po vrsti:

1. `null`/prazno → `new(null, "—", "Naslov ni zapisan")`.
2. Obreži presledke in nevidne znake.
3. **Naslov brez sheme, ki se začne z `//`** → predpni `https:`.
   `//pim.nowodvorski.com/x.jpg` → `https://pim.nowodvorski.com/x.jpg`. **To je NW popravek.**
4. Naslov, ki se začne z `www.` in nima sheme → predpni `https://`.
5. Sprejmi samo shemi `http` in `https`. Karkoli drugega (`javascript:`, `data:`, `file:`, UNC)
   → `Href = null`, `Note = "Naslov ni varna spletna povezava"`. Dobaviteljski podatek ne sme
   postati izvedljiva shema.
6. `http://` **pusti pri miru**, a zapiši `Note = "Nešifrirana povezava"`. Ne nadgrajuj tihoma —
   za nekatere vire bi `https` vrnil 404 in bi izgubili sliko brez sledi.
7. Naslov, ki ostane neveljaven, se izpiše kot besedilo (skrajšano), ne kot povezava.

**Kje se uporabi:** `ProductCard` (sličica v glavi, zavihek Mediji), `Media.razor`, kjerkoli
drugje se izriše zunanji naslov. `SafeUrl` in `SafeMediaUrl` **izbriši** — ostane ena pot.

> **Trajni popravek je v bazi, ne v UI-ju.** Normalizacija v intranetu popravi *prikaz*; izvožena
> vrednost bo še vedno brez sheme. Prava rešitev je vrstica `PREFIX` v `map.FieldTransform` nad
> preslikavo NW medija (mehanizem obstaja, glej `docs/DATABASE.md`, migraciji 049 in 056).
> **To zapiši v poročilo §12 — ne izvedi je sam.**

**Zavihek Mediji na kartici** ni tabela naslovov, ampak galerija:

```
Mreža ploščic (CSS grid, min 160px):
  ┌───────────┐
  │  <img>    │   Vloga: GLAVNA · #1
  │           │   1200×1200 · jpg          (če je podatek; sicer se vrstica izpusti)
  └───────────┘   [Odpri izvirnik]  ⚠ Nešifrirana povezava
```

- razvrščeno po `Role`, znotraj po `SortOrder`;
- glavna slika prva in vidno označena;
- `<img loading="lazy">` z `onerror`, ki ploščico prestavi v stanje »Slike ni mogoče naložiti«
  (naslov ostane viden kot besedilo — to je diagnostika, ne napaka strani);
- pod galerijo ločena tabela **Dokumenti** (`canon.ProductDocument`): vloga, naziv, naslov;
- če artikel nima nobenega medija, `PimState` prazno stanje pove »Artikel nima nobenega medija.«
  in ponudi povezavo na `/mediji`.

### 5.5 Stran `/mediji`

Ostane seznam, dobi pa:

- **stolpec s sličico** (majhna, 48px, `loading="lazy"`) pred stolpcem Artikel;
- **preklop pogleda seznam / mreža** (mreža je za pregled slik uporabnejša) — en gumb, ne meni;
- filter **vloga** (`Role`) in filter **stanje naslova** z vrednostmi:
  `V redu` · `Popravljen (dodan https:)` · `Nešifrirano (http)` · `Neveljaven naslov`;
- KPI vrstica dobi četrto kartico **»Naslovov brez sheme«** — to je natanko NW primer in po
  popravku v `map.FieldTransform` mora pasti na nič. Kartica je merilo, ali je popravek uspel.

---

## 6. Sklop B — Validacija, razdeljena na štiri nivoje

Uporabnikova zahteva: *»da se res lepo validacija dela in da imamo lepo razdeljeno validacijo,
ERP_SLO, ERP_EU/THIRD, KOMERCIALA, SPLET.«*

### 6.1 Kaj v bazi že je (ne izumljaj novega)

Iz `docs/VALIDACIJA.md` in `val.ValidationProfile`:

| Profil | Obseg (`Scope`) | Blokira ERP | Blokira splet |
|---|---|---|---|
| `SHARED_CORE` | `SHARED` | da | da |
| `ERP_L1_SLO` | `ERP` | da | ne |
| `ERP_L1_EU` | `ERP` | da | ne |
| `ERP_L1_THIRD` | `ERP` | da | ne |
| `COMMERCIAL_L2` | `COMMERCIAL` | **ne** | **ne** |
| `WEB_svetila_si` | `WEB` | ne | da |
| `WEB_videlektro` | `WEB` | ne | da |
| `ERP_L1`, `WEB_B2C` | podedovana | — | — |

Profili so **vrstice v bazi**. Nov profil je `INSERT`, ne nova različica programa. Zato nivo
v UI-ju **ne sme biti seznam trdo zapisanih šifer.**

### 6.2 Nivo validacije — izpeljan, ne zapisan

Nova datoteka `Services/ValidationLayer.cs`:

```csharp
public enum PimValidationLayer { ErpSlo, ErpEuThird, Komerciala, Splet }
```

Razvrstitev profila v nivo se izpelje iz `Scope` in `BlocksErp`/`BlocksWeb`, ne iz šifre:

| Pogoj | Nivo |
|---|---|
| `Scope = 'COMMERCIAL'` | **KOMERCIALA** |
| `Scope = 'WEB'` | **SPLET** |
| `Scope = 'ERP'` in šifra vsebuje `EU` ali `THIRD` | **ERP_EU/THIRD** |
| `Scope = 'ERP'` sicer | **ERP_SLO** |
| `Scope = 'SHARED'` | **v vsak nivo, ki ga profil blokira** (glej spodaj) |

**Kako se ravna s `SHARED`.** `SHARED_CORE` blokira ERP in splet hkrati. Ne sme viseti v svojem
četrtem stolpcu, ker uporabnik dela po kanalih. Zato se njegove zahteve **prikažejo v vsakem
nivoju, ki ga blokira** (ERP_SLO, ERP_EU/THIRD, SPLET), vsaka vrstica pa nosi značko
`PimChip Text="SKUPNO" Tone="warn"`. Tako je jasno, da gre za isto zahtevo, ne za tri različne.

**Nikjer ne seštevaj artikla dvakrat.** Števec »koliko artiklov ima napako na nivoju X« šteje
**različne artikle** (`COUNT(DISTINCT ProductId)`), ne vrstic težav. Kjer to naredi poizvedba,
zapiši v komentar, zakaj je `DISTINCT` nujen.

`ERP_L1_EU` in `ERP_L1_THIRD` sta **dodatek** k `ERP_L1_SLO`, ne zamenjava — artikel za EU mora
zadostiti obema. Kartica nivoja ERP_EU/THIRD mora to povedati v podnaslovu, sicer bo uporabnik
mislil, da sta izključujoča.

### 6.3 Stran `/kakovost` — predelava

```
PimPage "Kakovost"

┌ Štiri kartice nivojev (kpi-grid), po vrsti ERP_SLO · ERP_EU/THIRD · KOMERCIALA · SPLET ┐
│  ERP_SLO                                                                                │
│  1.234 neveljavnih                                                                      │
│  od 6.265 artiklov · blokira ERP                                                        │
│  [PimBar delež veljavnih]                                                               │
│  → klik: /kakovost/napake?nivo=ERP_SLO                                                  │
└─────────────────────────────────────────────────────────────────────────────────────────┘

Za vsak nivo razdelek s tabelo profilov znotraj njega:
  Profil | Blokira | Zahtev | Veljavnih | Neveljavnih | Delež
  (vrstica profila SHARED nosi značko SKUPNO)

Spodaj obstoječa vrstica PimHubCard: Napake validacije · Karantena · Prevodi · Kategorije
```

Kartica **KOMERCIALA** ima izrecen podnapis: »ne blokira ničesar — pomanjkljivosti so vidne,
artikel ostane veljaven«. To je najpogostejši nesporazum in mora biti napisano na strani, ne
samo v dokumentaciji.

Kartica **SPLET** ima izbirnik spletnega mesta (vsa mesta / posamezno). Brez njega števec meša
`svetila.si` in `videlektro`.

### 6.4 Stran `/kakovost/napake` — predelava filtrov

Obstoječa stran (`intranet.GetQualityIssues`, migracija 102) dobi:

- **prvi filter je Nivo** s štirimi vrednostmi + »Vsi«; parameter v naslovu `?nivo=ERP_SLO`,
  da so kartice iz §6.3 klikljive;
- za njim: Profil (ožja izbira znotraj izbranega nivoja), Resnost (`ERROR`/`WARNING`),
  Zahteva/polje, Spletno mesto (viden samo ob nivoju SPLET), iskanje po šifri/EAN/nazivu;
- stolpec **Nivo** kot prvi stolpec tabele, značka SKUPNO na vrsticah iz `SHARED`;
- vsaka vrstica ima povezavo na `/izdelki/{ProductId}` **na zavihek kanala** (`#erp`, `#komerciala`,
  `#splet`) — uporabnik iz napake skoči naravnost tja, kjer jo popravi.

**Nivo mora dati enak odgovor kot kartica izdelka.** Če `/kakovost/napake?nivo=SPLET` pokaže 40
artiklov, mora imeti vseh 40 na kartici rdeč/rumen zavihek Splet. Isto razvrščanje uporabi na
obeh mestih — funkcija iz `ValidationLayer.cs`, ne dve različni poizvedbi.

### 6.5 Stran `/pravila/validacija`

Seznam zahtev preuredi po nivojih (isto razvrščanje). Za vsako zahtevo prikaži: polje, resnost,
aktivnost in — pomembno — **zahteve z `IsActive = 0`** ločeno, pod naslovom
»Zahteve, ki čakajo na polje«. `docs/VALIDACIJA.md` jih šteje devet. Ta seznam je delovni
seznam za bazo in cevovod; ne skrivaj ga za filtrom.

---

## 7. Sklop C — Cene in zaloga kot **preverbe** (ne validacija)

Uporabnikova zahteva: *»Cene in zaloge je treba dodati da je za preverbo, da bodo uporabniki
vedeli in dobivali obvestila, če bo kaj ne štimalo.«*

### 7.1 Konceptualna meja, ki je ne smeš zabrisati

Preverbe **niso** `val.ProductIssue`. Artikel zaradi manjkajoče cene **ne postane `INVALID`**,
ne gre v karanteno in ne izpade iz izvoza. Preverba je **opozorilo za človeka**: sistem javi,
človek presodi.

Zato:
- ne pišeš v `val.*`,
- ne dodajaš profila v `val.ValidationProfile`,
- preverbe imajo **svoj šifrant** (ki ga zaenkrat ni — §4 in §12),
- na kartici izdelka se prikažejo v zavihkih **Cene** in **Zaloga**, nikoli v zavihku Kakovost.

### 7.2 Nova stran `/preverbe`

**Meni:** skupina *Poslovanje*, za postavkama Zaloga in Cene:
`new("Preverbe cen in zaloge", "preverbe", "icon-quality", "Opozorila o cenah, maržah in zalogi — ne blokirajo izvoza.")`
**Faza toka:** `PimLifecycle.Business.RoutePrefixes` dobi `"preverbe"`.

```
PimPage "Preverbe cen in zaloge"
Subtitle: "Opozorila, ne napake. Nič od tega ne ustavi izvoza — pove, kje je vredno pogledati."

┌ KPI (klikljive, vsaka filtrira tabelo spodaj) ─────────────────────────────┐
│ Brez B2C cene │ Brez B2B cene │ Faktor marže pod pragom │ Brez zaloge in   │
│               │               │                         │ brez prihoda     │
│ Podvojen zapis cene │ Zaloga pod minimumom │ Zastarel posnetek            │
└───────────────────────────────────────────────────────────────────────────┘

Filtri: Organizacija · Cenik / skladišče · Vrsta preverbe (večizbirno) · Iskanje

Tabela: Šifra | Naziv | Vrsta preverbe (PimChip) | Kaj je narobe | Svežina | →
        VD.TF.0150PA.TR │ Sponka │ [FAKTOR MARŽE] │ B2B 0,59 € / PRC 0,11 € = 5,36 │ pred 2 h │ →
```

### 7.3 Seznam preverb

Šifre so v `Services/PimCheckCode.cs` kot `enum` **z opisom in privzetim pragom** — dokler ni
šifranta v bazi. Ko šifrant nastane, se enum umakne; zapiši to v poročilo.

**Cene**

| Šifra | Pomen |
|---|---|
| `CENA_MANJKA_B2C` | artikel nima aktivne cene na B2C ceniku |
| `CENA_MANJKA_B2B` | artikel nima aktivne cene na B2B ceniku |
| `CENA_NIC` | `Net = 0` na aktivnem ceniku |
| `DDV_MANJKA` | `VatRate = 0` tam, kjer se pričakuje stopnja |
| `CENIK_POTEKEL` | `ValidFrom` v prihodnosti ali veljavnost pretekla |
| `PODVOJEN_ZAPIS` | več aktivnih zapisov za isti `(ProductId, PriceList)` |
| `FAKTOR_MARZE` | prodajna / prevzemna cena pod pragom — §7.4 |
| `CENA_POD_NABAVNO` | B2B ali B2C nižja od prevzemne cene |

**Zaloga**

| Šifra | Pomen |
|---|---|
| `BREZ_ZALOGE_BREZ_PRIHODA` | količina ≤ 0 in ni napovedane dobave |
| `ZALOGA_POD_MIN` | pod minimalnim pragom — **prag v bazi ne obstaja**, §7.5 |
| `POSNETEK_ZASTAREL` | `stock.Snapshot` starejši od dogovorjenega okna |
| `POZICIJA_BREZ_ARTIKLA` | `stock.UnmatchedPosition` — pozicija brez artikla |

Vsaka preverba je **ena vrstica na (artikel, preverba, kontekst)**, nikoli ena na artikel s
skupkom razlogov — sicer se ne da filtrirati.

### 7.4 Faktor marže — natančna definicija

V SAOP je artikel hkrati na več cenikih; prevzemna (nabavna) cena **ni poseben stolpec**, ampak
**lastni cenik**. V uporabnikovem primeru (`VD.TF.0150PA.TR`): B2B = 0,59 €, PRC (prevzemni) = 0,11 €
→ faktor **5,36**.

```
faktor = prodajna cena (B2B, po potrebi B2C) / prevzemna cena (PRC)
```

- **Privzeti prag opozorila: faktor < 2.** Prag mora biti nastavljiv po organizaciji in kategoriji,
  ne trdo zapisan. Dokler šifranta ni, je privzetih `2` v `PimCheckCode.cs` in stran ima na vrhu
  vidno opombo »Prag 2,00 je privzet; nastavljiv prag še ni v bazi.«
- **Identiteta cenika je vedno `(OrganizationId, PriceList)`.** Ne sklepaj, da je šifra `PRC`
  enaka v vseh štirih organizacijah. Šifre preberi iz `canon.ProductPrice` / `out.ExportPriceList`,
  ne iz imena. Če šifre prevzemnega cenika za organizacijo ne najdeš, preverba za to organizacijo
  **ne teče** in stran to pove — ne privzame napačnega cenika.
- **Past z mersko osnovo.** Ena cena je lahko na kos, druga na pakiranje (blister 10 kosov).
  Če `canon.ProductCommercial` ne potrdi iste osnove za obe ceni, faktor **vseeno prikaži**,
  a ga označi z `PimChip Text="Osnova ni potrjena" Tone="warn"` in ga **ne štej** v KPI kartico
  »pod pragom«. Nizek faktor je lahko napaka ali zavestna odločitev (akcija, razprodaja) — zato
  je to opozorilo in ne blokada.
- Stolpci v tabeli za to preverbo: **B2B cena · PRC cena · Faktor (2 decimalki) · Osnova**.

### 7.5 Min/max zaloge — odprto, ne izmišljuj

Preveri `canon.ProductStockPolicy` in `stock.Position`, ali polji za minimalno/maksimalno zalogo
sploh obstajata. **Če ne obstajata, preverbe `ZALOGA_POD_MIN` ne implementiraj z izmišljeno
privzeto vrednostjo.** Kartica in vrsta preverbe ostaneta na strani, napolnjeni s `PimMissing`,
ki pove, kateri podatek manjka in iz katerega vira SAOP bi moral priti. To gre v poročilo §12
kot **odprto vprašanje za uporabnika**, ne kot tiha napačna izvedba.

### 7.6 Obveščanje

*»da bodo uporabniki dobivali obvestila, če bo kaj ne štimalo«* — mehanizem **že obstaja**:
`ops.Alert` → `ops.AlertDelivery` → `ops.AlertRecipientConfig`, s stranjo `/izvozi/obvestila`
in procedurama `intranet.AcknowledgeAlert` / `intranet.ResolveAlert`.

**Ne gradi novega kanala obveščanja.** Naredi to:

1. Stran `/preverbe` dobi zavihek ali razdelek **»Obvestila«**, ki bere iste alarme, filtrirane
   na vrsti `PRICE_CHECK` in `STOCK_CHECK`, z gumboma Potrdi in Reši (obstoječi proceduri).
2. Dokler alarmov teh vrst nihče ne ustvarja (to dela worker, ne intranet), razdelek pokaže
   `PimMissing` z natančnim besedilom: »Alarme vrste `PRICE_CHECK`/`STOCK_CHECK` mora ustvarjati
   worker prek `ops.UpsertAlert`; danes jih nihče ne ustvarja.«
3. To zapiši v poročilo kot **zahtevo za cevovod**, ne za bazo — tabele obstajajo.

### 7.7 Stran `/cene`

Obstoječa stran ostane seznam cen, dobi pa:

- filter **Stanje cene** z vrednostmi preverb iz §7.3 (brez cene, cena 0, brez DDV, potekla,
  podvojen zapis) — enake šifre kot `/preverbe`, ne druge besede za isto stvar;
- stolpca **Prevzemna cena** in **Faktor**, kjer je prevzemni cenik znan;
- KPI vrstico s tremi števci in povezavo »Vse preverbe →` /preverbe`«.

---

## 8. Sklop D — Skupna stran SAOP: kaj se piše nazaj in kaj se je zgodilo

Uporabnikova zahteva: *»da imava neko skupno stran SAOP kjer se piše nazaj in da se vidi zgodovina.«*

### 8.1 Kaj obstaja

`out.OutboxMessage` (+ `OutboxAttempt`, `OutboundBatch`), `ops.OutboundEvent`,
`pim.FieldOwnership`, `out.OwnershipPolicy`, `out.SaopXmlField`, `out.SaopDocument`.
Strani: `/outbound` (vrsta in dejanja), `/izvozi/mnozicno`, `/izvozi/obvestila`.
Procedure: `intranet.GetOutboundMessages`, `GetOutboundMessage`, `GetOutboundBatches`,
`GetOutboundEvents`, `GetWritableSaopFields`, `out.ApproveMessage`, `out.ApproveOutboundBatch`.

**Gradnikov je dovolj; manjka jim skupna streha.** Danes so razmetani pod »Izvozi«, kjer se
mešajo s spletnimi CSV-ji — dvema popolnoma različnima stvarema.

### 8.2 Nova razdelilna stran `/saop`

**Meni:** skupina *Izhodi*, nad obstoječo postavko za izvoze:
`new("SAOP — pisanje nazaj", "saop", "icon-export", "Kaj gre nazaj v ERP, v kakšnem stanju in kaj je ERP potrdil.", IsHub: true)`
`PimLifecycle.Outputs.RoutePrefixes` dobi `"saop"`.

```
PimPage "SAOP — pisanje nazaj"
Subtitle: "Vsak zapis nazaj v ERP: kdo ga je odobril, kdaj je odšel, kaj je ERP odgovoril
           in ali je naslednja sinhronizacija vrednost potrdila."

┌ KPI ────────────────────────────────────────────────────────────────────┐
│ Čaka odobritev │ V vrsti │ Poslano, nepotrjeno │ Potrjeno │ Napake │ Odkloni │
└─────────────────────────────────────────────────────────────────────────┘

Razdelilne kartice (PimHubCard):
  Čakalna vrsta      → /outbound              (obstaja)
  Zgodovina          → /saop/zgodovina        (novo, §8.4)
  Odkloni            → /saop/odkloni          (novo, §8.5)
  Kaj sme nazaj      → /saop/polja            (novo, §8.6)
  Množično urejanje  → /izvozi/mnozicno       (obstaja)
  Obvestila          → /izvozi/obvestila      (obstaja)

Spodaj: tabela po entitetah — Artikli · Cene · Ceniki · Stranke · Dokumenti
        Stolpci: Entiteta | Čaka | V vrsti | Poslano | Potrjeno | Napake | Zadnji zapis
```

Entiteta, za katero pot nazaj še ne obstaja (cene, ceniki), je v tabeli **prisotna** z vrednostjo
`—` in opombo »pot nazaj še ne obstaja«. Prazna vrstica pove več kot manjkajoča.

### 8.3 Pravilo, ki velja povsod na tej strani: `Sent` ni zeleno

**`Sent` pomeni samo, da je HTTP klic uspel.** Zeleno je rezervirano za `Verified` — ko naslednja
sinhronizacija iz SAOP vrne isto vrednost, kot smo jo poslali.

| Stanje | `PimChip.Tone` |
|---|---|
| `PendingApproval`, `Pending`, `Retry` | `warn` |
| `Sent` | `warn` + besedilo »poslano, nepotrjeno« |
| `Verified`, `Succeeded` | `good` |
| `Error`, `Dead`, `Drift`, `Cancelled` | `bad` |

Preveri obstoječi `Chip()` v `Outbound.razor` — danes šteje `Sent` med dobre. **Popravi.**

Odklon (drift) se **vedno** ugotavlja proti **poslani** vrednosti (posnetek poslanih polj), ne
proti trenutnemu stanju PIM-a. Sicer zaporedje »pošlji A → uredi na B → sinhronizacija vrne A«
lažno prijavi odklon. Če bralni model posnetka poslanih polj ne vrne, stolpec ne kaže odklona —
kaže `PimMissing` s tem razlogom.

### 8.4 `/saop/zgodovina` (nova)

Ena vrstica na **operacijo**, ne na poskus. Stolpci: Čas · Entiteta / ključ · Operacija ·
Polja (povzetek stara → nova) · Odobril · Poslano · Odgovor ERP · Potrjeno · Rezultat.
Razširitev vrstice pokaže vse poskuse (`out.OutboxAttempt`) z odgovori.

Filtri: entiteta, stanje, uporabnik, obdobje, iskanje po ključu.

Če `intranet.GetOutboundMessages` ne vrne polj za stara/nova vrednost in za odobritelja,
stolpci ostanejo s `PimMissing` opombo — in gredo v poročilo.

### 8.5 `/saop/odkloni` (nova)

Samo vrstice z odklonom: kaj smo poslali, kaj je ERP vrnil, razlika, kdaj je bila zaznana in
gumb »Pošlji ponovno« (obstoječa `RetryOutbound`). To je stran, ki jo bo uporabnik gledal
najpogosteje, ko bo pisanje nazaj zares teklo.

### 8.6 `/saop/polja` (nova)

Bralni pregled `pim.FieldOwnership` + `intranet.GetWritableSaopFields`: katero polje sme nazaj,
kdo je lastnik (`PIM` / `SAOP` / `SHARED`), ali se bere nazaj. **Brez branja nazaj ni pisanja** —
polje brez potrjenega branja mora biti vidno označeno kot »ni varno za pisanje«.

Zaenkrat samo bralno. Urejanje lastništva je zapisovalna pot, ki je ni — to gre v poročilo.

---

## 9. Sklop E — Skupni sloj: kaj gre na splet

Uporabnikova zahteva: *»da je skupni sloj kaj se izvaža na splet.«*

### 9.1 Nova razdelilna stran `/splet`

Danes je spletni izvoz pomešan s SAOP odhodno potjo pod `/izvozi`. Po §8 se SAOP odseli na
`/saop`; `/izvozi` naj postane **izključno spletni izvoz** in dobi pot `/splet` kot svojo streho.

**Meni:** skupina *Izhodi*: `new("Splet — kaj gre ven", "splet", "icon-export", "Po spletnem mestu: kaj gre v datoteko, kaj ne in zakaj.", IsHub: true)`.
Obstoječa postavka »Izvozi in dostava« ostane, a njen podnaslov se omeji na profile in datoteke.

```
PimPage "Splet — kaj gre ven"

Izbirnik spletnega mesta (canon.WebSite): svetila.si · videlektro · vsa

┌ KPI ───────────────────────────────────────────────────────────────┐
│ Gre na splet │ Ne gre │ Gre, a z odprto težavo │ Stolpcev brez vira │
└────────────────────────────────────────────────────────────────────┘

Razdelek 1 — "Zakaj izdelek ne pride do datoteke"
  (obstoječa tabela iz /izvozi: zahteva | profil | blokira | število izdelkov)
  vsaka vrstica → /kakovost/napake?nivo=SPLET&zahteva=...

Razdelek 2 — "Stolpci profila brez vira"
  (obstoječa tabela pokritosti; stolpec brez kanoničnega vira ne bo izpolnjen nikoli)

Razdelek 3 — "Izvozni profili tega spletnega mesta"
  Profil | Stolpcev | Pokritih | Zadnja datoteka | Vrstic | → /izvozi/profili/{id}

Razdelek 4 — "Zgodovina dostav"
  Čas | Profil | Vrstic | Velikost | Rezultat | Cilj
```

**Ena resnica z `/kakovost`.** Števec »ne gre na splet« na tej strani in števec nivoja SPLET na
`/kakovost` morata izhajati iz istega izračuna. Če se razideta, je ena od strani napačna — in
uporabnik ne bo vedel katera. Uporabi isto storitev, ne dveh podobnih poizvedb.

### 9.2 Predogled

Na `/izvozi/profili/{id}` dodaj **predogled prvih 20 vrstic** izvozne datoteke z dejanskimi
glavami stolpcev profila. Če predogledne procedure ni, `PimMissing` z imenom, ki jo predlagaš
(npr. `intranet.GetExportPreview`) — in v poročilo.

---

## 10. Sklop F — Nastavitve: atributi, kategorije, variante, podobnosti, povezanost

Uporabnikova zahteva: *»v nastavitvah imamo atribute, kategorije in doda se variante, podobnosti
izdelkov in povezanost.«*

### 10.1 `/nastavitve/atributi` — razširi

Danes: šifra atributa, število izdelkov, število vrednosti, primer vrednosti. Dodaj:

- **Vir** (iz katerega konektorja atribut prihaja — `map.FieldMapping` / `map.SourceConnector`),
- **Prevod** — ali ima vrednost prevod v slovarju (`map.ValueLookup`) in koliko vrednosti ga nima
  (`map.MissingTranslation`); klik pelje na `/kakovost/prevodi` filtrirano na ta atribut,
- **Uporaba na spletu** — ali je atribut v katerem izvoznem profilu (`out.ExportColumn`),
- filter: vir, ima/nima prevoda, uporabljen/neuporabljen na spletu,
- klik na vrstico odpre **podrobnost atributa** (`/nastavitve/atributi/{koda}`) s seznamom
  različnih vrednosti, številom izdelkov na vrednost in prevodom — to je delovni zaslon za
  čiščenje slovarja.

Šifrant atributov z lastnimi metapodatki (tip, enota, ali je za splet, ali je obvezen po kategoriji)
**v bazi ne obstaja** — atributi so izpeljani iz `canon.ProductAttribute`. Stolpce, ki jih to
zahteva, prikaži po §4 in zapiši v poročilo.

### 10.2 `/nastavitve/kategorije` — razširi

Drevo obstaja. Dodaj:

- prikaz **po spletnem mestu** (`canon.WebSite`) — isto drevo je lahko drugačno na drugem mestu,
- stolpec **Izdelkov** (neposredno / s podkategorijami vred),
- **prevod imena kategorije** (`canon.CategoryTranslation`) s praznimi jasno označenimi,
- povezavo na `/kakovost/kategorije` (nepreslikane poti iz vira) in na `map.CategoryPathMap`.

### 10.3 `/nastavitve/povezave-izdelkov` (nova) — variante, podobni, povezani

Ena stran, trije razdelki. Zrno je vedno par `(izdelek, povezani izdelek, vrsta)`.

| Razdelek | Kaj pomeni | Zrno |
|---|---|---|
| **Variante** | isti izdelek v več izvedbah (barva, moč, dolžina) — skupina z vodilnim izdelkom | skupina + člani + razlikovalni atribut |
| **Podobni** | zamenljiva alternativa, ki jo splet ponudi »podobni izdelki« | usmerjen ali neusmerjen par |
| **Povezani** | dodatek, pribor, rezervni del — pripada, ne nadomešča | **usmerjen** par + vloga |

**Vsak razdelek ima:**
- filter: organizacija, vir povezave (ročno / iz dobaviteljevega vira / izpeljano iz atributa),
- tabela: izdelek → povezani izdelek, vrsta, vloga, vir, kdo in kdaj je povezavo ustvaril,
- pri variantah dodatno: skupina, vodilni izdelek, razlikovalni atribut,
- **sličici obeh izdelkov** (`MediaUrlPolicy`) — brez slike se varianta ne da pregledovati.

Tabele `pim.ProductLink` **ni**. Predlagana oblika (v poročilo, ne v migracijo):

```
pim.ProductLink
  ProductLinkId   bigint identity
  OrganizationId  int            NOT NULL   -- izolacijski ključ
  ProductId       bigint         NOT NULL   -- izvor
  LinkedProductId bigint         NOT NULL   -- cilj
  LinkType        nvarchar(20)   NOT NULL   -- VARIANT | SIMILAR | RELATED
  LinkRole        nvarchar(40)   NULL       -- pribor, rezervni del, nadomestek …
  GroupKey        nvarchar(100)  NULL       -- skupina variante
  IsPrimary       bit            NOT NULL   -- vodilni izdelek skupine
  SortOrder       int            NOT NULL
  Source          nvarchar(40)   NOT NULL   -- MANUAL | FEED | DERIVED
  CreatedBy, CreatedUtc
  UQ (OrganizationId, ProductId, LinkedProductId, LinkType)
```

Odprta vprašanja, ki jih **vprašaš uporabnika in ne odločiš sam** (v poročilo):
1. Ali je »podobni« usmerjen (A→B ne pomeni B→A) ali obojestranski?
2. Ali variante nosi vodilni izdelek ali ločena skupina brez lastnega artikla?
3. Ali povezave prihajajo iz dobaviteljevih virov (NW/BT) ali jih vpisuje samo človek?

Dokler odgovorov ni, je stran bralna, s `PimMissing` in vidnimi filtri ter glavami tabel.

### 10.4 `/nastavitve` — razdelilna stran

Doda kartico **Povezave izdelkov** (variante, podobni, povezani). Vrstni red kartic naj sledi
temu, kako pogosto se uporabljajo: Atributi · Kategorije · Povezave izdelkov · Spletni kanali ·
Jeziki · Skladišča · Pravila.

---

## 11. Vrstni red dela

Delaj po tem zaporedju. Po vsakem koraku mora biti build čist.

| # | Korak | Zakaj tu |
|---|---|---|
| 1 | `MediaUrlPolicy`, `PimReadResult`, `PimMissing`, `PimAgo` (§4, §5.4) | vse ostalo stoji na tem |
| 2 | `ValidationLayer.cs` + testi (§6.2) | nivo mora biti definiran, preden ga stran uporabi |
| 3 | Kartica izdelka — trije kanalski zavihki + mediji (§5) | glavni zaslon; uporabnik ga vidi prvi |
| 4 | Stran `/mediji` (§5.5) | isti gradnik, majhen dodatek |
| 5 | `/kakovost` in `/kakovost/napake` po nivojih (§6.3, §6.4) | podatki obstajajo, takoj vidno |
| 6 | `/preverbe` + razdelka na `/cene` (§7) | prva stran, ki v veliki meri stoji na `PimMissing` |
| 7 | `/saop` in tri podstrani (§8) | preureditev obstoječega, brez nove sheme |
| 8 | `/splet` (§9) | preureditev obstoječega |
| 9 | `/nastavitve/*` in povezave izdelkov (§10) | najmanj podatkov, zato zadnje |
| 10 | Poročilo `BAZA_ZAHTEVE_INTRANET.md` (§12) | drugi glavni izdelek |

Meni (`PimNavigation.cs`) posodobi **sproti**, ne na koncu — sicer strani niso dosegljive in jih
ni mogoče pogledati.

---

## 12. Kaj napišeš, ko končaš

Datoteka: **`docs/porocila-faz/BAZA_ZAHTEVE_INTRANET.md`**

Ne opisuj, kaj si naredil — opiši, **kaj mora nastati v bazi, da bo to, kar si naredil, delovalo.**
To je vhod v naslednjo fazo.

### Predloga

```markdown
# Kaj potrebuje intranet iz baze

Zapisano: <datum>. Stanje migracij ob pisanju: <zadnja številka>.

## 1. Manjkajoče procedure bralnega modela

| Predlagano ime | Stran | Kaj mora vrniti | Iz katerih tabel | Brez tega |
|---|---|---|---|---|
| `intranet.GetPriceChecks` | `/preverbe` | ena vrstica na (artikel, preverba) … | `canon.ProductPrice`, … | stran je prazna |

## 2. Manjkajoče tabele

Za vsako: ime, predlagani stolpci, ključi, zakaj `OrganizationId`, kdo jo polni
(človek / worker / cevovod), in kaj se zgodi, če je ni.

## 3. Manjkajoči stolpci v obstoječih tabelah

| Tabela | Stolpec | Za kaj ga stran potrebuje | Od kod bi prišel |
|---|---|---|---|

## 4. Manjkajoči podatki (tabela obstaja, prazna je)

Npr. prevzemni ceniki po organizaciji, pragovi marže, min/max zaloge.

## 5. Zahteve za cevovod, ne za bazo

Npr. `PREFIX` transform za NW medije v `map.FieldTransform`; worker, ki ustvarja alarme
vrste `PRICE_CHECK`/`STOCK_CHECK` prek `ops.UpsertAlert`.

## 6. Odprta vprašanja za uporabnika

Oštevilčena, vsako z: kaj je vprašanje, zakaj ga ne moreš odgovoriti sam,
in kaj bi naredil, če odgovora ne bo.

## 7. Kaj deluje že danes

Kratek seznam strani, ki so po tej nalogi polne s pravimi podatki — da se vidi meja
med narejenim in čakajočim.
```

---

## 13. Definicija končanega

```powershell
dotnet build PIM_Solution\PIM.sln          # 0 napak, 0 opozoril
scripts\run_tests.ps1                      # izhodna koda 0
```

Poleg tega:

1. **Vsaka `@page` pot je unikatna** in je bodisi v `PimNavigation.cs` bodisi dosegljiva z
   razdelilne strani, ki je v meniju.
2. **Vsaka nova pot je v pravem `PimLifecycleArea.RoutePrefixes`.**
3. **Nova čista logika ima test.** Najmanj: `MediaUrlPolicy.Normalize` (NW `//` primer, `http`,
   `javascript:`, prazno, presledki) in razvrstitev profila v nivo iz `ValidationLayer.cs`
   (vseh sedem profilov iz `docs/VALIDACIJA.md` + `SHARED_CORE` v več nivojih). Testi so čiste
   funkcije brez baze — dodaj nov konzolni testni projekt po vzorcu obstoječih v `tests/`
   in ga vključi v `scripts\run_tests.ps1`.
4. **Nikjer ni izmišljenih podatkov.** Iskanje po `Random`, `Faker`, `Lorem`, `demo`, `TODO:
   fake` ne sme vrniti ničesar novega.
5. **Nikjer ni gumba, ki ne dela.** Vsak gumb kliče obstoječo proceduro ali pa ga ni.
6. **`docs/porocila-faz/BAZA_ZAHTEVE_INTRANET.md` obstaja** in vsebuje vse manjkajoče objekte,
   ki jih izpisujejo tvoje `PimMissing` plošče. Če je plošča na zaslonu, mora biti vrstica v
   poročilu — in obratno.

V poročilu ne navajaj `npm test`, `npm run lint` ali uspešnega builda brez testov kot dokaza
(`AGENTS.md` §3). Če česa ne moreš pokazati z izhodom ukaza, tega ne trdiš.
