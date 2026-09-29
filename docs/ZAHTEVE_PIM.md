# Ključne zahteve PIM — kaj uporabniki potrebujejo in kje smo

Zapisano 2026-09-29 po besedah lastnika. Cilj: **čim več avtomatike, človek samo, ko je pri artiklu
kaj narobe.** Stanje je preverjeno v kodi (ne v bazi PRD — ali je posel na PRD vklopljen, je
nepreverjeno). Napake strani so v `docs/PREGLED_STRANI.md`, dobre prakse v `docs/PIM_DOBRE_PRAKSE.md`.

| # | Zahteva | Stanje |
|---|---|---|
| Z1 | Spremembe dobaviteljev iz XML vidne in samodejno na splet | DELNO |
| Z2 | Novi artikli: odobritev in zapis v SAOP | DELUJE (varnostna vrzel) |
| Z3 | Pravila validacije: kaj je obvezno, kaj se preverja | DELNO |
| Z4 | Popusti: dobavitelj, izdelek, skupina, izjeme za stranke | DELNO |
| Z5 | Aktivnost artikla takoj v PIM/SAOP/splet; na spletu do razprodaje ali do datuma | DELNO, kljukice manjkajo |
| Z6 | Pregled zaloge in stanja artiklov | DELUJE |
| Z7 | Zgodovina naročanja, trendi, obvestila o prodaji | DELNO (koda je, živih podatkov ni) |
| Z8 | Avtomatika, človek samo ob izjemah | DELNO |

---

## Z1. Spremembe v XML katalogih dobaviteljev
**Danes:** `SUPPLIER_CATALOG_IMPORT` na 6 h (`PIM.Automation/JobCatalog.cs:138`), zaloga dobaviteljev na 30 min;
veriga validacija → objava → `WEB_CATALOG_EXPORT` gre na splet samodejno. Vsaka sprememba iz XML je v
zgodovini polja (`ChangeSource = XML_FEED`), vidna pa samo na kartici posameznega artikla.
**Manjka:**
- [ ] stran »Kaj je dobavitelj spremenil« po teku/viru (prej/potem, filter, Excel) — **M**
- [ ] zaznava artiklov, ki jih v XML ni več → seznam »Ni več pri dobavitelju« s predlogom odprodaje — **M**
- [ ] cene dobaviteljev iz XML se ne berejo (preslikave NW/BT nimajo cene) — **S–M**, če XML ceno ima
- [ ] znani težavi: MERGE slik NW, časovna omejitev podjetja 4; `Fetch:BT_XML` na PRD

## Z2. Novi artikli dobaviteljev
**Danes:** `/izdelki/novi-artikli` — pregled, zavrnitev, dopolnitev ERP polj, vrsta za SAOP, odobritev.
Nič ne gre v SAOP samodejno (`SAOP_OUTBOUND_DISPATCH` izklopljen).
- [ ] **nujno:** `ApproveItemAsync`/`CancelItemAsync` nimata preverjanja pravic (`IntranetDataService.cs:421`) — **S**
- [ ] kandidat se zapre takoj po zajemu iz SAOP, ne šele ob naslednjem XML — **S**
- [ ] viri iz `map.SourceConnector`, ne trdo NW/BT — **S**

## Z3. Pravila validacije
**Danes:** `/pravila/validacija` (profil + polje + napaka/opozorilo), pravila iz nabora atributov kategorije (266),
nivoji ERP_SLO, ERP_EU/THIRD, KOMERCIALA, SPLET, urna validacija.
- [ ] shranjevanje pravila ne sme čakati na validacijo vseh podjetij (zdaj do 11 min) → zahteva posla v ozadju — **S**
- [ ] popravki filtrov na `/kakovost/napake` — **S**
- [ ] vrste pravil: oblika (EAN 13), min/max, dolžina, dovoljene vrednosti, »če X, potem Y« — **L**
- [ ] inkrementalna validacija samo spremenjenih artiklov — **M**

## Z4. Popusti
**Danes:** rabatna skupina z vrstnim redom (ročno stranka > ročno tip > SAOP rabatni cenik, P2 za osnovnim, 253/279);
izjeme za stranko/tip v skupini (`/pravila-popustov`); popust na izdelek samo kot S-popust za polno pakiranje (274);
odprodaja. Vse gre v `stranke.csv`, obračuna Magento.
- [ ] **pravila »popust na dobavitelja« ni** (deluje le, če je rabatna skupina v SAOP po dobavitelju) — **M**
- [ ] izjem ni mogoče urediti/izbrisati; izjema zahteva interni ID stranke — **S**
- [ ] »cenik stranke«: za artikel pokaži osnovno ceno → popusti → končno ceno z virom vsakega koraka (`PIM.B2b.DiscountCalculator` obstaja, ni uporabljen) — **M**
- [ ] splošen popust na posamezen artikel (ne samo pakiranje) — **M**

## Z5. Aktivnost artiklov in splet
**Danes:** »Aktiven« na kartici gre takoj v PIM in v vrsto za SAOP (273); neaktiven artikel pade s spleta ob
naslednjem izvozu; odprodaja pri 0 spremeni samo oznako Odprodaja = NE.
- [ ] **»na spletu do razprodaje zaloge«** — danes je obratno: neaktiven pade s spleta ne glede na zalogo — **M–L**
- [ ] **»na spletu do datuma«** — ni polja — v istem sklopu
- [ ] samodejni umik ob izteku datuma ali 0 zaloge, z obvestilom in vrstico na `/splet/umaknjeni`
- [ ] gumb »Umakni iz prodaje« = Aktiven Ne v vrsto za SAOP + »do razprodaje«
- [ ] napake na `/izdelki/odprodaja` (PREGLED_STRANI)

## Z6. Zaloga in stanje artiklov
**Danes:** `/zaloge` (lastna + dobaviteljeva zaloga, prihodi, min/max, posebnosti, Excel), zajem na 10/30 min.
- [ ] `/preverbe` brez listanja (vidnih 50+50) — **S**
- [ ] mail »Zaloga pod MID« šteje tudi zalogo dobaviteljev — **S**
- [ ] blok »Stanje« na kartici artikla (aktiven, splet, zaloga, odprodaja, zadnja prodaja) — **S–M**

## Z7. Zgodovina naročanja in trendi
**Danes:** shema `ana`, `SAOP_ANALYTICS_IMPORT` (4:00), `/analitika` s signali NAROCI/ZALEZANO/BREZ_ZALOGE in predlogom količine.
**Še nikoli ni tekla na živih podatkih.**
- [ ] prvi živi tek analitike (v omrežju) — **S**
- [ ] obvestila: rastoča prodaja, »ni zaloge, prodaja se«, predlog naročila → zvonec + mail po dobavitelju — **M**
- [ ] osnutek naročila dobavitelju iz predloga (z odobritvijo) — **L**

## Z8. Avtomatika in izjeme
**Danes samodejno:** zajem SAOP (1 h), XML (6 h), zaloge/cene (10 min), naročila (1 h), validacija → objava → izvoz,
alarmi (5 min), nočna uskladitev. **Namerno ročno:** odobritev za SAOP, novi artikli, varovalke.
- [ ] e-pošta alarmov je privzeto izklopljena (`PIM_ALERT_DELIVERY_ENABLED`) — vklop in preizkus na PRD — **S**
- [ ] en sam razporejevalnik (danes trije) — **M**
- [ ] stran »Izjeme danes« / »Moj dan«: varovalke, SAOP odkloni, novi kandidati, signali prodaje — **M**

---

## Odprta vprašanja za lastnika
1. Kdaj artikel pade s spleta, ko je v SAOP neaktiven, a ima zalogo? Šteje samo lastna zaloga? Ali ob razprodaji
   samodejno predlagamo »neaktiven« za SAOP (z odobritvijo)?
2. Prednost popustov: skupina stranke, dobavitelj ali artikel — kaj zmaga? Se seštevajo zaporedno ali velja najbolj
   specifičen? Je »dobavitelj« isto kot rabatna skupina v SAOP?
3. Naj večje spremembe iz XML (zamenjana glavna slika, izbrisan opis) počakajo na potrditev?
4. Obvestila o prodaji: kdo jih dobi, kako pogosto, kakšen prag?
5. Kaj sme komercialist (urejanje kartice, pravila, pošiljanje v SAOP)?
