# Popravki PIMa — seznam iz `Popravki_PIMa.docx` (prejeto 2026-08-28)

Vir: `C:\Users\david\Downloads\Popravki_PIMa.docx`. Ta datoteka je delovni prepis
zahtev v oštevilčene postavke, da se da vsako posebej odkljukati z dokazom.

Stanje: `TODO` / `DELAM` / `NAREJENO` / `VPRAŠANJE` (potrebna odločitev človeka).

---

## A. Nadzorna plošča

| # | Zahteva | Ozemlje | Stanje |
|---|---|---|---|
| A1 | Številke na nadzorni plošči kažejo samo DEMO organizacijo — kazati morajo celotno tabelo (vse organizacije). | INTRANET | NAREJENO |
| A2 | Uporabna sta „skupaj izdelkov" in „ERP veljavni"; ostalo ni pametno — pregledati in odstraniti neuporabne kazalnike. | INTRANET | NAREJENO |

## B. Vhodni podatki

| # | Zahteva | Ozemlje | Stanje |
|---|---|---|---|
| B1 | Navigacijsko drevo: ime „Zajem in preslikava" ni všeč — preimenovati. | INTRANET | NAREJENO |
| B2 | Vhodi: ostane kot je (pohvala) — brez spremembe. | — | NAREJENO |
| B3 | Tabela virov naj bo skupaj s filtri (en blok, ne ločena bloka). | INTRANET | NAREJENO |
| B4 | Klik na worker → izpis zanj: ostane (pohvala). | — | NAREJENO |
| B5 | Teki: ostane (pohvala). | — | NAREJENO |
| B6 | Težave: odstrani besedilo, ki napotuje na neujemanja/prevode/dobavitelje/kategorije — to so druge strani. | INTRANET | NAREJENO |

## C. Izdelki

| # | Zahteva | Ozemlje | Stanje |
|---|---|---|---|
| C1 | Odstrani globalni iskalnik v glavi strani (podvaja iskalnik na Izdelkih). | INTRANET | NAREJENO |
| C2 | Zavihki (vse / za uredit / brez slike …) so manj pomembni — glavni poudarek na dobre filtre, da uporabnik vidi izdelke v napaki. | INTRANET | TODO |
| C3 | Izvoz v Excel: polja, ki manjkajo, obarvaj blago rdeče. | DOMENA/IZVOZ | NAREJENO |
| C4 | Izvoz v Excel: polja, ki so nujna za validacijo, obarvaj rumenkasto. | DOMENA/IZVOZ | NAREJENO |
| C5 | Izvoz v Excel mora vsebovati ERP, komerciala in SPLET podatke; odvečna polja odstrani. | DOMENA/IZVOZ | NAREJENO |
| C6 | Atributi za SPLET v izvozu — odprto vprašanje: atributi se določijo po kategorijah. | — | VPRAŠANJE |
| C7 | Odstrani polje/izbiro „Pregled – cel pregled" (sprememba nima učinka). | INTRANET | NAREJENO |
| C8 | Komercialni podatki: „pakiranje" in „dimenzije pakiranja" premakni pod ERP podatke. | INTRANET | NAREJENO |
| C9 | Filtri: dodaj filter „ima sliko / nima slike". | INTRANET | NAREJENO |
| C10 | Povsod preimenuj „Oddelek" → „ABC klasifikacija" (kjer gre za A/B/C podatke). | INTRANET | NAREJENO |
| C11 | „Razvrstitev" premakni nad tabelo (ločeno od filtrov). | INTRANET | NAREJENO |
| C12 | Klik na izdelek: kartica se dolgo nalaga in vmes se pokaže seznam izdelkov — dodaj takojšen prikaz s kolescem nalaganja in/ali pohitri. | INTRANET | NAREJENO |

## D. Kartica artikla

| # | Zahteva | Ozemlje | Stanje |
|---|---|---|---|
| D1 | Dobavitelji in proizvajalci: prikaži ime **in** kodo, ne samo kode. | INTRANET | NAREJENO |
| D2 | Nazivi (spletni in ERP) morajo imeti vse jezike. | INTRANET | NAREJENO |
| D3 | „Lastnosti izdelka" pri spletu preimenuj v „Atributi". | INTRANET | NAREJENO |
| D4 | Medij in zaloga sta v istem zavihku — loči ju. | INTRANET | NAREJENO |
| D5 | Pri medijih razjasni ali prikazujemo vse slike ali samo glavno; prikaži vse. | INTRANET | NAREJENO |

## E. Medij

| # | Zahteva | Ozemlje | Stanje |
|---|---|---|---|
| E1 | Dokumenti: namesto napisa „PDF" in ikone mape prikaži predogled prve strani PDF-ja. | INTRANET | NAREJENO |
| E2 | Odstrani naslov „Filter vs stanja" (nesmiseln). | INTRANET | NAREJENO |
| E3 | Odstrani opombe pri dodanem `https:` — uporabnika ne zanima. | INTRANET | NAREJENO |

## F. Kakovost

| # | Zahteva | Ozemlje | Stanje |
|---|---|---|---|
| F1 | Naslov „Validacija in vrzeli" ni všeč — preimenuj. | INTRANET | NAREJENO |
| F2 | Kakovost kaže samo DEMO artikle — mora kazati vse. | INTRANET | NAREJENO |
| F3 | Filter „spletna mesta" ni relevanten — odstrani (gre za ERP, komercialo in splet hkrati). | INTRANET | NAREJENO |
| F4 | Odstrani „načrt odblokiranja". | INTRANET | NAREJENO |
| F5 | Razloži/poenoti razliko med karanteno in napakami validacije; poenostavi razdelitev. | INTRANET | NAREJENO |
| F6 | Polje „kje popraviti" — vsak pomen mora biti razložen. | INTRANET | NAREJENO |

## G. Izhodi ERP in splet

| # | Zahteva | Ozemlje | Stanje |
|---|---|---|---|
| G1 | Preimenuj „SAOP – pisanje nazaj". | INTRANET | NAREJENO |
| G2 | Odstrani oblačke (tooltipe/obvestilne bloke) na strani SAOP. | INTRANET | NAREJENO |
| G3 | Preveč gumbov v obliki oblačkov — zamenjaj z nekaj zavihki, ki se res rabijo. | INTRANET | NAREJENO |
| G4 | Tabela stanja ostane (pohvala). | — | NAREJENO |
| G5 | Preimenuj „Splet – kar gre ven". | INTRANET | NAREJENO |
| G6 | Na strani za splet naj se vidi dejanski CSV s prenosom; urejanje mora priti nazaj v izvozni CSV. | INTRANET + IZVOZ | TODO |
| G7 | Več CSV-jev za splet (artikli in stranke) — oba morata biti na voljo za pogled. | INTRANET + IZVOZ | TODO |
| G8 | Stran „Izvozni profili in datoteke" podvaja „Splet – kaj gre ven" — odstrani. | INTRANET | NAREJENO |

## H. Poslovanje — Stranke

| # | Zahteva | Ozemlje | Stanje |
|---|---|---|---|
| H1 | Dodaj vrsto stranke: kupec, kupec+dobavitelj, dobavitelj, proizvajalec. | BAZA + INTRANET | NAREJENO |
| H2 | Klik na celotno vrstico odpre stranko; odstrani povezave (naj bo navadno besedilo) in puščico na koncu. | INTRANET | NAREJENO |
| H3 | Kartica stranke v zavihkih; prvi zavihek „Splošni podatki" z osnovnimi podatki. | INTRANET | NAREJENO |
| H4 | Zavihek „Komercialni podatki": B2B spletne nastavitve, skupine popusta, tip stranke, vrsta stranke, popust na polno pakiranje, vrednostni rabat, B2B, popust NW, posebni popusti za stranke. | BAZA + INTRANET | NAREJENO |
| H5 | Zavihek „Poslovne enote in tranziti" — dodajanje PE iz seznama ali na novo, in tranzitov. | BAZA + INTRANET | NAREJENO |
| H6 | Zavihek „Zaznamki" — prosto besedilo, vidno med uporabniki, z imenom avtorja. | BAZA + INTRANET | NAREJENO |
| H7 | Zavihek „Dokumenti" (kasneje), „Finančni podatki" (kasneje). | — | VPRAŠANJE — zavihek obstaja in pošteno pove, da vira še ni; potrebna je odločitev, kateri vir jih prinese. |
| H8 | Zgodovina sprememb stranke. | BAZA + INTRANET | NAREJENO |
| H9 | Stran „Partnerji" odstrani — stranke bodo ločene po dobavitelj/proizvajalec. | INTRANET | NAREJENO |

## I. Poslovanje — Zaloga

| # | Zahteva | Ozemlje | Stanje |
|---|---|---|---|
| I1 | Prikazuje samo dobaviteljsko zalogo — dodaj SAOP zalogo. | INTRANET + DOMENA | NAREJENO |
| I2 | Prikaži datume v prihodu. | INTRANET + DOMENA | NAREJENO |
| I3 | Odstrani oblačke. | INTRANET | NAREJENO |
| I4 | Odstrani filtra „vsa razpoložljivo" in „ujemanje". | INTRANET | NAREJENO |

## J. Poslovanje — Cene in ceniki

| # | Zahteva | Ozemlje | Stanje |
|---|---|---|---|
| J1 | Namesti bralni sistem (branje cen/cenikov iz vira). | DOMENA | NAREJENO |
| J2 | Odstrani oblačke. | INTRANET | NAREJENO |
| J3 | Dodaj pametne filtre. | INTRANET | NAREJENO |
| J4 | Ena vrstica = en artikel; v tabeli število cenikov oz. največ trije ceniki, potem „+N". | INTRANET | NAREJENO |
| J5 | Klik kjerkoli v vrstici odpre pogled cenikov (ne kartice artikla). | INTRANET | NAREJENO |
| J6 | Dokončaj stran „Preverbe cen in zaloge", da deluje. | INTRANET | NAREJENO |

## K. Upravljanje — Nastavitve kataloga

| # | Zahteva | Ozemlje | Stanje |
|---|---|---|---|
| K1 | Preimenuj „lastnost" → „atribut". | INTRANET | NAREJENO |
| K2 | Boljša tabela atributov: slovenski atributi, prevodi, preslikave. | INTRANET | TODO |
| K3 | Kategorije: privzeto prikaži slovenske, ne italijanskih. | INTRANET | TODO |
| K4 | Imena kategorij po jezikih v vrstnem redu: sl, en, de, hr, it. | INTRANET | TODO |
| K5 | V tabeli kategorij dodaj imena polj (glave stolpcev). | INTRANET | TODO |
| K6 | Dokončaj „Povezave izdelkov". | INTRANET | TODO |
| K7 | Spletni kanali so samo za prikaz — kaj se doda? | — | VPRAŠANJE |
| K8 | Jeziki so samo za prikaz — kaj se doda? | — | VPRAŠANJE |
| K9 | Odstrani oblaček „Pravila in preslikave" v nastavitvah kataloga. | INTRANET | TODO |

## L. Upravljanje — Pravila in izvor

| # | Zahteva | Ozemlje | Stanje |
|---|---|---|---|
| L1 | Validacijski profil: način je v redu, dizajn ne; omogoči urejanje — uporabniki dodajajo napake in opozorila. | BAZA + INTRANET | TODO |
| L2 | Slovar vrednosti — zakaj prevajamo vrednosti? | — | VPRAŠANJE |
| L3 | Preslikave polj: zamisel je dobra, dizajn ne; omogoči urejanje in jasno pokaži od kod polje pride in kam se piše v PIM. | INTRANET | TODO |
