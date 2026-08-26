# Produktni model NoviPIM

Ta dokument je trajni zemljevid aplikacije. Namen ni opisati videza posamezne strani,
ampak preprečiti, da bi se PIM skrčil na seznam artiklov ali da bi posamezen modul izgubil
povezavo z vhodom, kakovostjo, izhodom, opozorilom in odgovorno skupino uporabnikov.

## 1. Osnovni tok

```text
SAOP / XML / datoteke
        ↓
VHODI (raw + map) ── neujemanja, prevodi, kategorije, preslikave
        ↓
KANONIČNI MODEL (canon)
        ↓
PIM + KAKOVOST (pim + val) ── lastništvo, zgodovina, validacija
        ├──────────────→ ERP / SAOP (outbox, odobritev, echo, odklon)
        └──────────────→ SPLET (profili, CSV, predogled, zgodovina, dostava)
                              ↓
                   OBVESTILA / E-POŠTA / NADZOR
                              ↓
                       ANALITIKA IN ODLOČITVE
```

Organizacija je obvezna meja podatkov. Kanal in jezik sta dodatni meji spletnih podatkov.
Noben števec, dejanje ali opozorilo ne sme mešati podjetij samo zato, ker imajo skupno bazo.

## 2. Faze in dejanski viri

| Faza | Kaj mora uporabnik nadzorovati | Trenutni viri resnice | Trenutna vstopna pot |
|---|---|---|---|
| Vhodi | viri, teki, čakalna vrsta, napake zajema in nepreslikane vrednosti | `raw.Inbox`, `map.SourceConnector`, `map.PipelineStep`, `ops.PipelineRun`, `ops.PipelineStepLog` | `/zajem` |
| Preslikave | element vira → kanonično polje, slovar vrednosti/prevodov, kategorijske poti | `map.FieldMapping`, `map.EntityMapping`, `map.ValueLookup`, `map.CategoryPathMap`, `map.MissingTranslation`, `map.MissingCategoryMap`, `map.UnmappedValue` | `/pravila`, `/kakovost` |
| Kanonični katalog | izdelek, besedila, atributi, kategorije, mediji, komercialni podatki, cene in zaloga | `canon.Product*`, `canon.Category*`, `canon.Language`, `canon.WebSite`, `canon.Warehouse` | `/izdelki`, `/mediji`, `/cene`, `/zaloge` |
| PIM-lastni podatki | objavljene/lastne vrednosti, lastništvo polj in zgodovina sprememb | `pim.Product*`, `pim.FieldOwnership`, `pim.ProductChangeBatch`, `pim.ProductFieldHistory` | kartica izdelka; zapisovalni deli se dodajajo po pogodbi |
| Kakovost | profil, zahteva, odprta težava, pripravljenost za ERP ali splet in karantena | `val.ValidationProfile`, `val.FieldRequirement`, `val.ProductValidationState`, `val.ProductIssue`, `raw.Inbox` | `/kakovost` |
| ERP izhod | kaj želi PIM spremeniti v SAOP, kdo je odobril, poskusi, odgovor, echo in odklon | `out.OutboxMessage`, `out.OutboxAttempt`, `out.OutboundBatch`, `out.SaopDocument`, `out.VerifyEcho`, `ops.OutboundEvent` | `/outbound`, `/izvozi/obvestila` |
| Spletni izhod | izvozna oblika, pokritost stolpcev ter datoteke izdelkov, cen, zaloge in strank | `out.ExportProfile`, `out.ExportColumn`, `out.ExportProductsCsv`, `out.ExportPriceList`, `out.ExportStockCsv`, `out.ExportB2b*Csv` | `/izvozi` |
| Poslovanje | stranke, skupine, popusti, izjeme, partnerji, cene in zaloga | `b2b.Customer*`, `b2b.GroupDiscount*`, `pim.Customer*`, `pim.*Discount*`, `canon.ProductCommercial`, `canon.ProductPrice`, `canon.ProductStock*` | `/stranke`, `/pravila-popustov`, `/partnerji`, `/cene`, `/zaloge` |
| Obvestila | odprti alarmi, prejemniki, dostava, potrditev, razrešitev in stopnjevanje | `ops.Alert`, `ops.AlertRecipientConfig`, `ops.AlertDelivery`, `ops.ErrorLog`, `ops.IntegrationHealth`, `sec.LocalUser.Email` | zvonec, `/sistem/integracije`, `/izvozi/obvestila` |
| Varnost | uporabnik, organizacijska meja, vloga in revizijska sled | `sec.LocalUser`, `sec.Role`, `sec.LocalUserRole`, organizacijski filtri posameznih strani, domenski audit zapisi | `/sistem/uporabniki`, `/sistem/vloge` |
| Analitika | artikli, kakovost, zaloga, cene, izvoz, stranke in naročilnice skozi čas | operativni podatki obstajajo; namenski zgodovinski read modeli še ne | načrtovano, brez navidezne menijske poti |

## 3. Dva izhodna svetova se ne smeta mešati

### ERP / SAOP

To je zapis nazaj v sistem evidence. Zahteva strožji tok:

1. uporabnik ali potrjen proces pripravi spremembo;
2. validacija preveri, ali je polje dovoljeno in pravilno;
3. sporočilo čaka na odobritev, kadar jo politika zahteva;
4. dispatcher pošlje zapis in shrani tehnični odgovor;
5. echo preveri dejansko vrednost v SAOP;
6. odklon postane vidno opozorilo in po potrebi e-pošta.

Čakanje v outboxu ni enako spletnemu izvozu in uspešen HTTP odgovor ni enak potrjenemu echo.

### Spletni kanali

To je nadzorovana izdelava in dostava datotek za Magento oziroma druge spletne cilje:

1. profil pove entiteto, kanal in stolpce;
2. vsak stolpec ima dejanski kanonični vir ali je vidno nepokrit;
3. validacija pove, kateri izdelki smejo v izvoz;
4. uporabnik vidi predogled, količine in opozorila pred izdelavo;
5. izvoz ima čas, izvajalca, rezultat, datoteko in zgodovino dostave.

Profil, ki obstaja, vendar nima pokritih obveznih stolpcev, ni pripravljen izvoz.

## 4. Uporabniške skupine

| Vloga | Trenutna odgovornost |
|---|---|
| `VIEWER` | branje kataloga, kakovosti, vhodov in dovoljenih izhodnih pregledov |
| `CATALOG_EDITOR` | urejanje kataloških vrednosti, preslikav, kategorij, prevodov in kakovosti, kadar obstaja zapisovalna pogodba |
| `COMMERCIAL` | stranke, cene, ceniki, popusti ter odobritve dovoljenih izhodov |
| `ADMIN` | uporabniki, vloge, integracije, sistemske nastavitve in vse operativne preglede |

Pri poznejši delitvi odgovornosti se lahko dodajo ločene vloge operaterja integracij,
objavljavca in analitika. Dokler jih ni v `sec.Role` in avtorizacijskih pogodbah, jih UI ne
sme predstavljati kot obstoječe.

## 5. Obvezna pogodba vsake strani

Pred izdelavo ali prenovo strani morajo biti določeni:

1. faza življenjskega toka;
2. avtoritativni podatkovni vir in svežina;
3. organizacija, kanal, jezik in drugi obvezni filtri;
4. dovoljene vloge za branje in pisanje;
5. bralna procedura oziroma servis;
6. zapisovalna procedura, revizijska sled in možnost razveljavitve, če stran piše;
7. validacija pred spremembo ali izvozom;
8. opozorilo, prejemnik in stopnjevanje ob napaki;
9. prazno, nalagalno in napakovno stanje;
10. merljiv dokaz, da stran prikazuje resnične podatke.

Če zapisovalna pot ne obstaja, je stran jasno bralna in nima gumba, ki se pretvarja, da
shranjuje. Če analitični read model ne obstaja, modul ostane dokumentirana vrzel brez
izmišljenega grafa.

## 6. Znane vrzeli za prihodnje strani

- urejanje vseh vrst preslikav še nima enotne zapisovalne in revizijske pogodbe;
- spletni izvozi potrebujejo uporabniški predogled, zgodovino datotek in kontrolo dostave;
- ERP izhod nima še vseh proizvajalcev sporočil za artikle, cene, cenike in stranke;
- e-poštna infrastruktura obstaja, uporabniške politike naročanja in skupinske eskalacije pa
  še niso celovit nastavitveni modul;
- analize trendov artiklov, zaloge, cen in naročilnic potrebujejo namenske zgodovinske read
  modele; operativnih tabel se ne uporablja kot lažni zgodovinski vir;
- naročilnice še niso samostojen registriran domenski modul.

## 7. Vrstni red prenove strani

1. nadzorna plošča kot resnični operativni povzetek celotnega toka;
2. vhodni podatki in preslikave;
3. seznam in kartica izdelka;
4. kakovost, manjkajoči podatki in karantena;
5. ERP izhodi in njihova obvestila;
6. spletni izvozi in kontrola CSV-jev;
7. stranke, popusti, cene, ceniki, partnerji in zaloga;
8. uporabniki, vloge, obvestilne politike in sistemske nastavitve;
9. analitika, ko so potrjeni zgodovinski viri.
