# Slovar podatkov procesov

Procesi so v glavnem grafu povezani **prek podatkov**: proces A zapiše podatek, proces B ga bere, torej je B odvisen od A.
Zato morata oba uporabiti **isto oznako** iz tega seznama (polji `bere:` in `pise:` v glavi procesa).

Nova oznaka je dovoljena, vendar jo najprej dodaj sem. Skripta `scripts/Procesi-Graf.ps1` opozori na vsako oznako, ki je tu ni, in na podatek, ki ga nihče ne zapiše ali ga nihče ne bere.

| Oznaka | Kaj je | Kje živi |
|---|---|---|
| `saop.artikli` | Šifrant artiklov v SAOP (osnovna polja, aktivnost) | SAOP |
| `saop.cene` | Ceniki in cene v SAOP | SAOP |
| `saop.zaloge` | Zaloge po skladiščih v SAOP | SAOP |
| `saop.stranke` | Kupci, dobavitelji, proizvajalci v SAOP | SAOP |
| `saop.popusti` | Popusti in pogoji kupcev v SAOP | SAOP |
| `saop.narocila` | Naročila kupcev (VNK) in dobaviteljem (VND), računi, prevzemi, Barkawi izvozi v SAOP | SAOP |
| `pim.narocila` | Naročila kupcev in dobaviteljem v PIM (`sales.*`, `purch.*`) | PIM |
| `pim.analitika` | Kazalniki analitike: prodaja po mesecih, predlogi naročil, zaležano, dobavitelji (`ana.*`) | PIM |
| `dobavitelj.xml` | Katalogi dobaviteljev (NW, BT …) po HTTP/FTP | dobavitelj |
| `excel.izdelki` | Delovni list izdelkov (uvoz/izvoz Excel) | uporabnik |
| `excel.odprodaja` | Seznam za odprodajo (Excel) | uporabnik |
| `excel.stranke` | Delovni list kupcev (Excel) | uporabnik |
| `excel.cenik` | Uvoz cenika (Excel) | uporabnik |
| `pim.izdelek` | Osnovni podatki artikla v PIM (šifra, naziv, EAN, aktivnost, ERP polja) | PIM |
| `pim.atributi` | Vrednosti atributov artikla | PIM |
| `pim.besedila` | Opisi in spletna besedila (tudi AI) | PIM |
| `pim.prevodi` | Prevodi nazivov, opisov, kategorij | PIM |
| `pim.kategorije` | Drevo kategorij | PIM |
| `pim.kategorije-izdelka` | Uvrstitev artikla v kategorije | PIM |
| `pim.mediji` | Slike in dokumenti artikla | PIM |
| `pim.kandidati` | Novi artikli dobaviteljev (kandidati po EAN) | PIM |
| `pim.surovi-zajem` | Surovi podatki zajema (staging, teki, težave, neujemanja) | PIM |
| `pim.cene` | Cene in ceniki v PIM (tudi B2B) | PIM |
| `pim.zaloge` | Zaloge in rezervacije v PIM | PIM |
| `pim.stranke` | Kupci v PIM (tipi, referent, e-maili, opombe) | PIM |
| `pim.popusti` | Pravila popustov (S-popusti, P2) | PIM |
| `pim.odprodaja` | Artikli v odprodaji, razstavni eksponati | PIM |
| `pim.validacija` | Rezultati validacije, karantena, pripravljenost za izhod | PIM |
| `pim.pravila` | Pravila validacije, slovar, preslikave, nazivi | PIM |
| `pim.nastavitve` | Definicije atributov, nabori, jeziki, kanali, skladišča, povezave | PIM |
| `pim.saop-vrsta` | Čakalna vrsta sprememb za SAOP (čaka odobritev / poslano / zavrnjeno) | PIM |
| `pim.varovalke` | Zadržane objave in potrditve | PIM |
| `pim.zgodovina-uvozov` | Zapisi uvozov in sprememb (povratek) | PIM |
| `pim.uporabniki` | Uporabniki, vloge, dovoljenja | PIM |
| `pim.urniki` | Posli, urniki, teki, zakupi | PIM |
| `splet.katalog-csv` | katalog.csv za splet | EXPORT_ROOT |
| `splet.stranke-csv` | stranke.csv za splet | EXPORT_ROOT |
| `splet.magento` | Izvozi po Magento profilih | EXPORT_ROOT |
| `obvestila` | E-mail obvestila in alarmi | e-pošta |
