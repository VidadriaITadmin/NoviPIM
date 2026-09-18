# Testni načrt za vse veje osnovnega grafa

Datum: 2026-09-08  
Cilj: za vsako puščico dokazati vhod, zapis, preslikavo, rezultat, ponovljivost in vidno napako.

## Pravila izvedbe

- Uporablja se samo lokalna razvojna baza `PIM`.
- Fixture, lokalna datoteka in `127.0.0.1` so dovoljeni brez zunanjih učinkov.
- Živi SAOP, pravi FTP/HTTP/Magento, e-pošta in webhook zahtevajo ločeno odobritev.
- Test ustvari prepoznavne podatke in pobriše samo svoje vrstice z ozkim pogojem.
- PASS pomeni izhodno kodo 0 in spodaj navedene podatkovne kontrole.
- Glavni regresijski dokaz je samo:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\run_tests.ps1
```

## Skupna vstopna kontrola

| ID | Test | PASS |
|---|---|---|
| G-01 | Build celotne rešitve | `dotnet build PIM_Solution\PIM.sln` vrne 0 |
| G-02 | Vse migracije | prvi in drugi zagon migratorja vrneta 0; drugi ne uporabi nič novega |
| G-03 | Shema | migrator `--verify` vrne 0 |
| G-04 | Celotni paket | `scripts\run_tests.ps1` vrne 0 in nič ni padlo |

Ob padcu katerekoli kontrole se veje lahko diagnosticirajo, celota pa ne sme biti označena PASS.

## Veja A — SAOP → RAW → PIM

| ID | Scenarij | Kontrole |
|---|---|---|
| A-01 | veljaven SAOP fixture za en artikel | nastaneta uspešen `ops.PipelineRun` in `raw.Inbox`; artikel je v `canon.Product` |
| A-02 | več strani | vse strani so enkrat zapisane, števci read/succeeded/failed se ujemajo |
| A-03 | delta/watermark | drugi zagon uporabi watermark in ne podvoji nespremenjenega zapisa |
| A-04 | isti payload dvakrat | deduplikacija prepreči podvojitev; tek ne pokvari obstoječega artikla |
| A-05 | manjkajoča obvezna vrednost | zapis je v karanteni, artikel ni lažno označen kot pripravljen |
| A-06 | neznano polje/entiteta | sled je vidna kot unmapped/napaka, brez tihe izgube |
| A-07 | HTTP 401/403/404/429/500/timeout | pravilen status teka, retry samo kjer je dovoljen, napaka brez skrivnosti |
| A-08 | ponovna preslikava obstoječega `RunId` | brez novega SAOP klica nastane pričakovana dopolnitev, brez dvojnikov |
| A-09 | organizacijska izolacija | artikel organizacije 2 ne spremeni podatkov organizacije 1/3/4 |
| A-10 | UI sled | tek, vir, čas in napaka so vidni na straneh za integracije in teke |

Avtomatska osnova: `PIM.F3.ContractTests`, `PIM.F3.BehaviorTests`,
`PIM.F3.SaopClientTests`, `PIM.F3.Integration`.

## Veja B — dobaviteljski XML → RAW → PIM

| ID | Scenarij | Kontrole |
|---|---|---|
| B-01 | veljaven NW XML | artikel se po EAN poveže; atribut, kategorija in medij imajo pravi vir |
| B-02 | veljaven BT XML | atributi in slike se povežejo s pravim artiklom |
| B-03 | napačen ali nepopoln XML | worker vrne napako; delni podatki niso promovirani |
| B-04 | EAN ne obstaja v PIM | vrstica gre v karanteno/unmatched z uporabnim razlogom |
| B-05 | neznan atribut | pojavi se v delovnem seznamu za preslikavo, brez tihega zavrženja |
| B-06 | transformacija vrednosti | slovar, tip, enota in decimalno ločilo dajo kanonično vrednost |
| B-07 | ista datoteka dvakrat | ni podvojenih RAW/kanoničnih rezultatov |
| B-08 | sprememba mappinga + replay | nova preslikava dopolni artikel brez ponovnega zunanjega prevzema |
| B-09 | konflikt SAOP/XML lastništva | zmaga vrednost po `OwnershipPolicy`; konflikt ima sled |
| B-10 | Braytron kategorija | pričakovani SKIP/BLOCKED, dokler ni določeno ciljno drevo |

Avtomatska osnova: vsi `PIM.F5.*` projekti.

## Veja C — FTP/HTTP/mapa → landing

| ID | Scenarij | Kontrole |
|---|---|---|
| C-01 | lokalna mapa, nova datoteka | datoteka se varno pojavi na landing mestu in šele nato jo vidi worker |
| C-02 | HTTP 200 | vsebina, ime, velikost/hash in čas prevzema so pravilni |
| C-03 | FTP uspeh | enak rezultat kot C-02; poverilnica ni v logu |
| C-04 | 401/403 ali napačno geslo | ni delne datoteke; alarm jasno pove vir in razlog |
| C-05 | prekinjen prenos | začasna datoteka ni obravnavana kot veljaven vhod |
| C-06 | ista oddaljena datoteka | politika ne povzroči dvojnega uvoza |
| C-07 | nova različica datoteke | nastane nov sledljiv prevzem in samo pričakovane spremembe |
| C-08 | path traversal/nevarno ime | zapis ostane znotraj dovoljene landing mape |
| C-09 | urnik in prekrivanje | drugi sočasni tek je zavrnjen; heartbeat ostane pravilen |

Za C-02 in C-03 najprej uporabi lokalni HTTP/FTP fixture. Pravi strežnik je ločen ročni test.

## Veja D — zaloge SAOP/NW/BT → PIM

| ID | Scenarij | Kontrole |
|---|---|---|
| D-01 | NW CSV zaloga | pravilno število vrstic, količina, čas posnetka in vir |
| D-02 | BT XML zaloga | enake kontrole kot D-01 |
| D-03 | SAOP stock fixture | skladišča in količine pripadajo pravi organizaciji |
| D-04 | neznan EAN/šifra | `stock.UnmatchedPosition`, brez povezave na napačen artikel |
| D-05 | ničelna/negativna/neveljavna količina | uveljavljeno poslovno pravilo in jasna napaka |
| D-06 | isti posnetek drugič | idempotenten rezultat, brez podvojenih količin |
| D-07 | novejši posnetek | read model uporablja pravo, najnovejšo vrednost |
| D-08 | artikel ima SAOP in dobaviteljsko zalogo | vira ostaneta ločena; filtri in CSV pokažejo pravilno semantiko |

Avtomatska osnova: vsi `PIM.F6.*` projekti in `PIM.F10.StocksUxTests`.

## Veja E — PIM kakovost in promocija

| ID | Scenarij | Kontrole |
|---|---|---|
| E-01 | popoln artikel | zahteve profila so VALID in artikel je pripravljen za ciljni kanal |
| E-02 | manjka obvezno polje | objava/izvoz je blokiran; prikazano je polje, razlog in odgovorna vloga |
| E-03 | napačen tip/vrednost | karantena ali validacijska napaka; stara veljavna vrednost ni tiho prepisana |
| E-04 | ročni popravek | audit vsebuje akterja, čas, staro in novo vrednost |
| E-05 | nov uvoz po ročnem popravku | lastništvo odloči pravilno; ni tihe izgube ročne vrednosti |
| E-06 | profil A veljaven, profil B ne | pripravljenost je ločena po cilju, ne en globalen status |
| E-07 | več organizacij | validacija in objava ne uhajata med organizacijami |

Avtomatska osnova: F5 integracija, `PIM.F10.QualityUxTests` in testi kartice izdelka.

## Veja F — PIM → CSV za splet

| ID | Scenarij | Kontrole |
|---|---|---|
| F-01 | en veljaven artikel | natanko ena podatkovna vrstica, pravilna glava in vrednosti |
| F-02 | neveljaven/neobjavljen artikel | ni izvožen oziroma je zavrnjen z razlogom |
| F-03 | vejica, podpičje, narekovaj, CR/LF, šumnik | pravilen CSV escaping in UTF-8 pogodba |
| F-04 | prazen neobvezen stolpec | stolpec ostane na pravem mestu |
| F-05 | prazen obvezen stolpec | izvoz ne ustvari lažno veljavne datoteke |
| F-06 | vrstni red stolpcev | natančno sledi aktivnemu `out.ExportColumn.SortOrder` |
| F-07 | filtri/paginacija/predogled | predogled in prenos uporabljata isti filter; prenos ni obrezan na prvo stran |
| F-08 | velik izvoz | pretočna izvedba, sprejemljiv čas in pomnilnik |
| F-09 | sočasna izvoza | zaklep prepreči prepis nepopolne datoteke |
| F-10 | atomarnost | marker/končna datoteka nastane šele po uspešnem zaključku |
| F-11 | dostava | lokalni prejemnik potrdi isto velikost/hash; pravi Magento ostane SKIP do odobritve |

Avtomatska osnova: `PIM.F7.*`, posebej `MagentoExportTests`, `ProductExportTests` in
`WebExportTests`.

## Veja G — PIM → SAOP povratna sinhronizacija

| ID | Scenarij | Kontrole |
|---|---|---|
| G-01 | sprememba pisljivega polja | nastane eno pravilno outbox sporočilo in batch |
| G-02 | sprememba SAOP-lastnega polja | ni enqueue; UI pojasni lastništvo |
| G-03 | enaka že potrjena vrednost | deduplikacija ne ustvari novega sporočila |
| G-04 | ročna odobritev | samo dovoljena vloga; audit vsebuje akterja in čas |
| G-05 | zavrnitev/preklic | dispatcher sporočila ne prevzame |
| G-06 | lokalni HTTP uspeh | pravilen method/path/XML; `Sent`, poskus in varen odgovor so zapisani |
| G-07 | HTTP 200 + SAOP poslovna napaka | status ni lažno `Sent/Verified`; razlog je prikazan |
| G-08 | 429/500/timeout | retry/backoff, omejeno število poskusov, nato `Dead` |
| G-09 | crash po claimu | lease recovery sporočilo varno vrne v obdelavo |
| G-10 | ADD vrne novo šifro | povezava na artikel se pravilno posodobi in rešitve ni treba ugibati |
| G-11 | echo enak | status `Verified` |
| G-12 | echo drugačen | drift/odklon in opozorilo; brez tihega PASS |
| G-13 | več organizacij | endpoint, dokument in pravice pripadajo isti organizaciji |
| G-14 | množični izbor | vsak artikel ostane atomski; delni neuspeh je jasno prikazan |

Avtomatska osnova: vsi `PIM.F8.*` projekti. Živi G-10–G-12 se izvedejo samo na potrjenem
neprodukcijskem endpointu in testnem artiklu.

## Veja H — nadzor in napake

| ID | Scenarij | Kontrole |
|---|---|---|
| H-01 | zdrav tek | heartbeat in `Healthy` brez lažnega alarma |
| H-02 | zastarel heartbeat | `StaleHeartbeat` z virom, organizacijo in stopnjo |
| H-03 | zaporedni padci | pravilno stopnjevanje in brez podvajanja istega alarma |
| H-04 | potrditev/razrešitev | dovoljena vloga in popoln audit |
| H-05 | izklopljena dostava | noben zunanji klic, opozorilo ostane v aplikaciji |
| H-06 | lokalni webhook fixture | vsebina in retry sta pravilna, skrivnosti niso v logu |

Avtomatska osnova: vsi `PIM.F9.*` projekti in sistemski UX testi F10.

## Končna matrika poročila

Za vsak ID se v poročilo vpiše `PASS`, `FAIL`, `SKIP` ali `BLOCKED`, ukaz, izhodna koda,
čas, varen RunId/MessageId in povezava do dokaza. Veja je zelena samo, če so vsi lokalni testi
PASS; zunanji `SKIP` mora ostati jasno ločen od produkcijske pripravljenosti.
