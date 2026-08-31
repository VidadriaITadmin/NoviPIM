# Popravki PIMa — drugi krog (prejeto 2026-08-31)

Vir: `C:\Users\david\Downloads\Popravki_PIMa_31_02_2026.docx`. Prvi krog je v
[`POPRAVKI_PIMA.md`](POPRAVKI_PIMA.md).

Stanje: `TODO` / `NAREJENO` / `VPRAŠANJE` (potrebna odločitev človeka).

---

## A. Izdelki — kartica artikla

| # | Zahteva | Stanje |
|---|---|---|
| A1 | Izpisati **vsa** polja, ki jih artikel ima, in omogočiti spremembo. | NAREJENO |
| A2 | ERP nazivi po dva stolpca. | NAREJENO |
| A3 | Kategorije ločene od ERP polj — kot spletna polja; uporabnik mora kategorijo popravljati. | TODO |
| A4 | Pri izvozu v Excel najprej okno, kjer uporabnik izbere, kaj bo urejal. | TODO |
| A5 | Prikaže samo glavno sliko — pokazati mora **vse** slike in **vse** dokumente. | NAREJENO |
| A6 | Nikjer se ne vidi, iz katere organizacije je artikel. | NAREJENO |
| A7 | Komercialne in spletne podatke ločiti. | NAREJENO |

## B. Mediji

| # | Zahteva | Stanje |
|---|---|---|
| B1 | PDF dokumentov ne odpira izvornikov. | TODO |
| B2 | Predlog: dokumente shranimo pri sebi, ker jih dobavitelji iz kataloga umaknejo. | VPRAŠANJE |

## C. Kakovost podatkov

| # | Zahteva | Stanje |
|---|---|---|
| C1 | Prikaz napak po nivojih in klik na filter — ostane (pohvala). | NAREJENO |
| C2 | Napake validacije nimajo izvoza artiklov s temi napakami. | TODO |
| C3 | Filter „Vsi profili" je preveč razdeljen. | TODO |

## D. Izhod v SAOP

| # | Zahteva | Stanje |
|---|---|---|
| D1 | Samo prikazuje — ni izvoza v Excel, uvoza nazaj in pošiljanja v SAOP. | TODO |
| D2 | Zgodovina zapisov v SAOP ni dokončana; enako Odkloni. | TODO |

## E. Izhod na splet

| # | Zahteva | Stanje |
|---|---|---|
| E1 | Prikazuje samo, koliko napak ima izdelek in kaj ga blokira. | TODO |
| E2 | Čemu služijo „stolpci brez vira"? | TODO (razložiti na strani) |
| E3 | Čemu služijo „izvozni profili tega spletnega mesta"? | TODO (razložiti na strani) |

## F. Stranke

| # | Zahteva | Stanje |
|---|---|---|
| F1 | Splošnih podatkov se ne da urejati — mora se dati. | TODO |
| F2 | Kje pošljemo podatke strank v SAOP? | TODO |
| F3 | Manjka veliko filtrov za iskanje pravih strank. | TODO |
| F4 | Iskalnik in filter sta previsoko in ju odreže na strani. | NAREJENO |

## G. Zaloga

| # | Zahteva | Stanje |
|---|---|---|
| G1 | Prikazuje samo dobavitelja in SAOP DEMO — dodati SAOP IQ, VID, Ediito. | NAREJENO |
| G2 | Odstrani oblačke; tabele so dovolj. | NAREJENO |
| G3 | V vseh tabelah so imena stolpcev in vrednosti zamaknjeni — popraviti po celi aplikaciji. | NAREJENO |

## H. Cene in ceniki

| # | Zahteva | Stanje |
|---|---|---|
| H1 | Filtri so porezani na strani. | NAREJENO |
| H2 | Vizija: cene se da spreminjati in pošiljati v SAOP. | TODO |

## I. Preverbe cen in zalog

| # | Zahteva | Stanje |
|---|---|---|
| I1 | Ni gotovo, da podatki držijo in da se prav računa — pokazati je treba račun. | TODO |

## J. Nastavitve kataloga — Atributi

| # | Zahteva | Stanje |
|---|---|---|
| J1 | Urejanje naj bo bolj moderno in pregledno. | TODO |
| J2 | Izvoz atributov v Excel in uvoz nazaj (prevodi na enkrat). | TODO |
| J3 | Zakaj so nekateri brez vira, če vse pride iz XML-jev? | TODO (razložiti) |
| J4 | Filtri niso uporabni — manjka „manjka EN prevod", „manjka HR prevod" … | TODO |

## K. Nastavitve kataloga — Kategorije

| # | Zahteva | Stanje |
|---|---|---|
| K1 | Filter „vsa podjetja" in kljukice odveč; raje filter „samo z izdelki". | TODO |
| K2 | Izvoz in uvoz Excela za celo drevo z jeziki. | TODO |
| K3 | Dodajanje nove kategorije, podkategorije in nadkategorije; prestavljanje veje. | TODO |

## L. Nastavitve kataloga — Povezave izdelkov

| # | Zahteva | Stanje |
|---|---|---|
| L1 | Excel za polnjenje povezav; šifre v stolpcu, ločene z `\|`. | TODO |
| L2 | Vsa podjetja, ne privzeto DEMO. | TODO |
| L3 | Samo slovenska imena vrst; zakaj toliko vrst, če so samo variante, podobni in povezani? | TODO |

## M. Spletni kanali, jeziki, skladišča

| # | Zahteva | Stanje |
|---|---|---|
| M1 | Zakaj `svetila_si` SLO in ANG? En kanal ima več jezikov. | TODO |
| M2 | Jeziki in skladišča ostanejo pregled. | NAREJENO |

## N. Pravila in izvor podatkov

| # | Zahteva | Stanje |
|---|---|---|
| N1 | Urejanje polj za validacijo — ostane (pohvala). | NAREJENO |
| N2 | Pomešana imena: `ERP_L1` in `ERP_L1_SLO`. | TODO |
| N3 | Dodajanje novega polja in odstranitev obstoječega. | TODO |
| N4 | Pri spletu filter po spletnih straneh. | TODO |
| N5 | Slovar vrednosti — čemu služi in kako bi ga uporabnik uporabil. | TODO (razložiti) |
| N6 | Preslikave polj — čemu služijo in kako bi jih uporabnik uporabil. | TODO (razložiti) |
| N7 | Komercialna pravila: zakaj posebej? | TODO |
| N8 | Štiri decimalke → cela števila; cene na dve decimalki. | TODO |
