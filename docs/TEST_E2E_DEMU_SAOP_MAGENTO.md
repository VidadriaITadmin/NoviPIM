# E2E test: DEMU → PIM → SAOP → validacija → Magento

Ta preizkus teče samo nad **DEMU** podatki. Dokazuje dejanski prenos in zapise workerjev, ne le prikaza v aplikaciji.

## Pričakovani rezultat

1. Nov BOVA artikel iz DEMU je v PIM-u enkrat in brez podvajanja.
2. Dopolnitev v PIM-u pride v SAOP; povratni zajem jo potrdi brez odklona.
3. Validacija pokaže manjkajoča polja; po vnosu jih odstrani in popravi popolnost.
4. Uvoz/izvoz delovnih listov za izdelke in stranke dejansko zapiše spremembe.
5. Magento worker izdela `katalog.csv` in `stranke.csv`.
6. BOVA ne-IQ artikel ni v `katalog.csv`; testna stranka je v `stranke.csv`.

> **Pomembno:** `NO_SITE` (brez spletnega mesta) ni dovolj za zahtevo, da artikla v CSV ni. Tak artikel je lahko v CSV kot odjavna vrstica s praznim stolpcem »Spletne strani«. BOVA mora biti izrecno izključen iz Magento/IQ kataloga (`EXCLUDED` oziroma `NOT_IN_CSV`).

## Podatki in predpogoji

| Podatek | Vrednost |
| --- | --- |
| Oznaka teka | `E2E-BOVA-YYYYMMDD-HHMM` |
| DEMU artikel | BOVA z oznako teka v nazivu |
| EAN | nov, veljaven, unikaten 13-mestni EAN |
| Namerno manjkajoča vrednost | ERP naziv ali neto masa — aktivno obvezno polje validacije |
| PIM → SAOP vrednost | prepoznavna testna vrednost, npr. `E2E BOVA ...` |
| DEMU stranka | samo testna stranka z oznako teka |
| Sprememba stranke | npr. `e2e-bova-...@example.test` ali testni popust |
| Magento podjetje | `2` (IQLighting) |

Na `/sistem/opravila` preveri omogočene posle **Artikli iz SAOP**, **Validacija artiklov**, **Objava v PIM** in **Katalog in stranke za splet**. **Pošiljanje v SAOP** ostane izklopljeno; za test ga ročno odobri in poženi samo za označeni zapis. Pred začetkom shrani posnetke `/sistem/zagoni`, `/outbound` in `/splet`.

## 1. DEMU → PIM

1. V DEMU ustvari BOVA artikel z dogovorjenim EAN-om in oznako teka; izbrano obvezno polje pusti prazno.
2. Zahtevaj **Artikli iz SAOP**. Na `/sistem/zagoni` mora biti `Succeeded`; shrani številko zagona in korak podjetja.
3. Na `/izdelki` poišči EAN. Pričakovano: natanko en `ProductId`, pravilen EAN in vrednosti iz DEMU. Če je artikel prej kandidat iz XML, preveri `/zajem/novi-artikli`: potrjeni artikel ne sme ustvariti drugega PIM artikla za isti EAN.
4. Na kartici zapiši `ProductId`, `ItemID`, EAN, začetno popolnost in izvor začetnih vrednosti.

**PASS:** en artikel za EAN, uspešen worker, nič nepojasnjenega v karanteni oziroma čakalni vrsti.

## 2. PIM urejanje, validacija in popolnost

1. Na kartici in `/kakovost/napake` zapiši odstotek popolnosti ter seznam napak.
2. Na `/kakovost/artikli` poišči EAN in klikni **Preveri zdaj**. Napaka mora navajati namerno prazno obvezno polje.
3. Na kartici vnesi manjkajočo vrednost in dogovorjeno ERP spremembo za SAOP; shrani.
4. Znova klikni **Preveri zdaj**. Napaka za izpolnjeno polje mora izginiti, ne sme nastati nepovezana napaka, popolnost pa se mora povečati. Če ni 100 %, mora seznam preostalih napak v celoti pojasniti razliko.
5. Preveri svež čas validacije in odsotnost stanja `STALE`.

**PASS:** odstranjena je ravno popravljena napaka; popolnost in preostale napake so skladne.

## 3. PIM → SAOP → PIM

1. Na `/outbound` poišči `ItemID`/EAN. Sporočilo `SAOP_PRODUCT` sme vsebovati samo namerno spremenjena ERP polja; spletni opis in PIM-only vrednosti ne smejo biti del dokumenta.
2. Sporočilo odobri in enkrat ročno zahtevaj **Pošiljanje v SAOP (odhodna vrsta)**. Potrdi zunanji zapis.
3. Na `/sistem/zagoni` preveri uspeh, na `/outbound` pa `Sent` ali `Verified`, odgovor/korelacijsko oznako ter odsotnost `Dead`, `Retry` in `Drift`.
4. V DEMU/SAOP preveri točno poslano vrednost; nato ponovno zaženi **Artikli iz SAOP**.
5. Na `/saop/odkloni` za artikel ne sme biti odklona. Sled kartice mora pokazati PIM spremembo, odhodno sporočilo in povratni zajem.

**PASS:** SAOP in PIM imata enako vrednost, odhodna vrsta je zaključena in worker ima končni uspeh.

## 4. Delovni list izdelkov

1. Iz `/izdelki/uvoz` izvozi delovni list. Spremeni samo eno PIM-only vrednost testnega artikla in datoteko shrani z oznako teka.
2. Uvozi datoteko. Predogled in zaključek morata navesti eno obdelano vrstico in eno zapisano spremembo brez nepojasnjenih preskokov.
3. Na kartici preveri vrednost in sled; ponovni izvoz mora vrniti isto vrednost.
4. PIM-only uvoz ne sme ustvariti SAOP sporočila. Za ERP polje ponovi razdelek 3.

## 5. Delovni list strank

1. Iz `/stranke/uvoz` izvozi delovni list. Spremeni izključno testno stranko; ne spreminjaj pravih strank ali več vrstic hkrati.
2. Uvozi datoteko in preveri identiteto stranke, število zapisanih sprememb ter opozorila.
3. Na `/stranke/{CustomerId}` preveri vrednost in sled. Ponovni izvoz mora vrniti isto vrednost.

## 6. Magento: objava in izdelani datoteki

1. Na kartici BOVA preveri izključitev iz Magento/IQ kataloga. Na `/kakovost/artikli` mora biti `EXCLUDED` oziroma `NOT_IN_CSV`, ne le `NO_SITE`.
2. Ročno zahtevaj po vrsti **Validacija artiklov**, **Objava v PIM**, **Katalog in stranke za splet**. Vsak predhodnik mora uspešno končati; zapiši številke zagonov.
3. Na `/splet` preveri nov čas/generacijo obeh datotek, končni par, zadnji poskus `Succeeded` in zapisljivost izhodne mape.
4. V **izdelani datoteki**, ne predogledu baze, poišči EAN in `ItemID` BOVA artikla: v `katalog.csv` ne sme biti zadetka.
5. V `stranke.csv` poišči šifro testne stranke: biti mora natanko ena vrstica z vrednostjo iz razdelka 5 in 19 glavami Magento pogodbe.
6. Če je BOVA v CSV kot odjava, test ne uspe — popravi izključitev, ne pričakovanega rezultata.

**PASS:** Magento worker je izdelal obe datoteki, testna stranka je v `stranke.csv`, BOVA pa ni v `katalog.csv` in ni objavljen na spletu.

## Končna kontrolna tabela

| Kontrola | Dokaz | PASS |
| --- | --- | --- |
| DEMU → PIM | uspešen `SAOP_PRODUCT_IMPORT`, en `ProductId` za EAN | ☐ |
| PIM urejanje in validacija | sled; odstranjena napaka; skladna popolnost | ☐ |
| PIM → SAOP → PIM | `Sent/Verified`, vrednost v DEMU, brez odklona | ☐ |
| Delovni list izdelkov | uvoz zapiše eno vrstico, ponovni izvoz jo vrne | ☐ |
| Delovni list strank | uvoz zapiše testno stranko, ponovni izvoz jo vrne | ☐ |
| Magento | BOVA ni v `katalog.csv`; testna stranka je v `stranke.csv` | ☐ |
| Workerji | vsak uporabljeni posel ima končni uspešen zagon in sled | ☐ |

## Čiščenje

Testnega artikla in stranke ne briši neposredno iz SAOP ali baze. Označi ju kot testna in neaktivna po poslovnem postopku, nato enkrat ponovi zajem, validacijo, objavo in Magento izvoz. K rezultatu pripni oznako teka, `ProductId`, `ItemID`, EAN, `CustomerId`, ID odhodnega sporočila, številke zagonov, čas/generacijo obeh CSV datotek in posnetke pred/po.
