# Enotni tok novih artiklov

## Odločitev

PIM ne sme samodejno ustvariti novega artikla iz dobaviteljevega XML-ja ali iz ročnega Excela. Tak vhod ustvari samo **predlog novega artikla** na eni strani »Novi artikli«. Uporabnik ga pregleda in z dejanjem **Uvozi v PIM** zavestno ustvari PIM artikel.

Izjema je SAOP: artikel, ki že obstaja v SAOP/DEMU, je uradno ustvarjen ERP artikel in ga zajem SAOP samodejno ustvari oziroma posodobi v PIM-u. Zanj ni smiseln ročni predlog, ker bi uporabnik potrjeval nekaj, kar v ERP že obstaja.

## Poti danes

| Pot | Današnje vedenje | Ciljno pravilo |
| --- | --- | --- |
| SAOP/DEMU → PIM | SAOP konektor sme ustvarjati artikle. | Obdrži. Ustvari ali posodobi uradni ERP artikel, stanje `CONFIRMED_IN_ERP`. |
| Dobaviteljev XML → PIM | Neznan artikel se praviloma shrani kot kandidat; generično stikalo `CanCreateProducts` pa lahko vhodu dovoli neposredno ustvarjanje. | XML nikoli ne sme ustvariti artikla. Neujemanje vedno postane predlog s posnetkom XML podatkov. |
| Kandidat XML → PIM | Uporabnik izbere »Uvozi«; PIM nastane z EAN kot začasno šifro in `NOT_YET_IN_ERP`. | Obdrži, vendar kandidat po uvozu ostane v isti evidenci in jasno kaže povezavo do kartice ter stanje ERP. |
| Ročni »nov artikel« | Manjka; Excel pravilno zavrne neobstoječo šifro. | Nov obrazec ustvari ročni predlog, ne artikla. Nato ima popolnoma isti pregled, uvoz v PIM in pot v SAOP kot XML predlog. |
| Delovni list izdelkov | Spreminja samo obstoječe artikle; ERP vrednosti takoj zapiše v PIM in jih doda v SAOP vrsto. | Obdrži. Nikoli ne ustvari novega artikla. |
| Kartica izdelka / množično urejanje | Spreminja obstoječ PIM artikel; ERP spremembe gredo v vrsto. | Obdrži. Za nov artikel se najprej uporabi predlog. |
| Odprodaja, zaloga, cene | Ujemajo obstoječe artikle. | Obdrži: nikoli ne ustvarjajo artiklov. |
| Magento | Samo izvoz. | Nikoli ni vhod ali ustvarjanje artikla. |

## Ena stran: Novi artikli

Sedanja `/zajem/novi-artikli` postane poslovno enotna stran **Novi artikli**, ne le seznam dobaviteljev. Ima filtre: vir, dobavitelj, podjetje, status, EAN, šifra in ali je ERP že potrjen.

| Vir predloga | Kaj uporabnik vidi | Kaj sme narediti |
| --- | --- | --- |
| Dobaviteljev XML | Naziv, EAN, dobaviteljeva šifra, atributi, kategorije, slike, dokumenti, cena ter povezava na izvorni zajem. | Preglej, primerjaj z obstoječimi EAN-i, zavrni, združi z obstoječim ali **Uvozi v PIM**. |
| Ročni predlog | Obvezni minimum: podjetje, dobavitelj, EAN ali začasna interna oznaka, naziv in razlog. | Dopolni, zavrni ali **Uvozi v PIM**. |
| SAOP | Ne prikazuje se kot predlog; že nastane v PIM-u. | Na kartici le preveri izvor in sled. |

Gumb **Uvozi v PIM** mora v eni transakciji ustvariti en artikel, prenesti vse dovoljene XML vrednosti, nastaviti `NOT_YET_IN_ERP`, zagnati validacijo in shraniti povezavo nazaj na predlog. Predlog se ne izbriše; njegov status je `IMPORTED_TO_PIM` in kaže `ProductId`.

## Stanja brez dvoumnosti

Predlog in ERP pot nista isto stanje, zato se kažeta ločeno.

| Plast | Stanja | Pomen |
| --- | --- | --- |
| Predlog | `PENDING_REVIEW`, `IMPORTED_TO_PIM`, `REJECTED`, `MERGED` | Ali je človek odločil, kaj se zgodi z vhodnim predlogom. |
| PIM/ERP | `NOT_YET_IN_ERP`, `QUEUED`, `SENT`, `CONFIRMED_IN_ERP`, `FAILED` | Ali PIM artikel obstaja in kje je njegova pot v SAOP. |

Po `Uvozi v PIM` uporabnik lahko takoj ureja spletne podatke, atribute, slike, dokumente in ERP podatke. Ne čaka na SAOP. Gumb **Pripravi za SAOP** pokaže manjkajoča ERP polja; šele pripravljen artikel se lahko uvrsti v odobritveno vrsto. SAOP uspeh vrne uradno šifro, PIM jo prevzame in preide v `CONFIRMED_IN_ERP`. SAOP neuspeh pomeni `FAILED`; artikel in predlog ostaneta vidna za popravek, brez ustvarjanja dvojnika.

## Pravila ujemanja in varovalke

1. Pred ustvarjanjem predloga se preveri podjetje + dobaviteljeva šifra in podjetje + EAN.
2. Enolično ujemanje z obstoječim PIM artiklom ponudi **Dopolni obstoječ artikel**; ne ustvari novega.
3. Več ujemanj EAN-a je `NEJASNO` in zahteva ročno združitev; avtomatska izbira ni dovoljena.
4. XML lahko dopolnjuje že obstoječ artikel samo v poljih, katerih lastnik je dobavitelj. ERP in PIM-lastniških polj ne sme prepisati.
5. Excel, odprodaja, zaloga, cene in Magento ne morejo ustvarjati izdelkov.
6. `CanCreateProducts=1` je dovoljen samo SAOP konektorjem; za vse XML/Excel konektorje mora biti `0` in mora biti varovano tudi v proceduri, ne le v nastavitvi.

## Izvedbeni vrstni red

1. Zakleni politiko ustvarjanja: neposredno ustvarjanje samo iz SAOP; dodaj test, ki XML konektorju prepove `canon.Product` zapis.
2. Posploši obstoječo kandidatno stran v »Novi artikli« in ohrani XML predloge skupaj s stanjem SAOP po uvozu.
3. Dodaj ročni predlog na isti seznam; ne dodajaj gumba za neposredno ustvarjanje na seznam Izdelki ali v Excel uvoz.
4. Dodaj jasne oznake izvora in ERP stanja na kartico ter shranjen pogled »Novi / še ni v ERP«.
5. Dodaj E2E testa: XML predlog → PIM → SAOP in ročni predlog → PIM → SAOP; ločeno ohrani SAOP/DEMU → PIM samodejni test.

## Odgovornost posamezne poti

- **SAOP** je vir uradne šifre in ERP potrditve.
- **Dobavitelj** je vir predloga in obogatitvenih podatkov, ne samodejnega artikla.
- **PIM urednik** odloči, ali predlog postane artikel, ter uredi spletne podatke.
- **Odhodna vrsta** je edina pot PIM → SAOP; zahteva odobritev in ima dokazilo o uspehu ali napaki.
- **Magento** bere samo uspešno objavljeno stanje; ne vpliva na ustvarjanje ali ERP pot.
