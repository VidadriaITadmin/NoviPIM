# PIM — navodila za Claude

PIM ViD Adrie: izdelki pridejo iz SAOP (ERP) in XML katalogov dobaviteljev, v PIM se uredijo in
preverijo, nato gredo nazaj v SAOP in na splet (Magento, `katalog.csv`). Intranet je Blazor Server
(.NET), baza je MSSQL, avtomatika teče po urniku.

**Jezik:** z uporabnikom piši samo slovensko. Koda, ukazi in identifikatorji ostanejo, kot so.
Uporabnik ni programer; piši tako, da razume komerciala.

---

## 0. Skupno delo več sej (tabla nalog)

Na PIM hkrati dela več sej. Vse delo teče prek **table nalog** `scripts/Koordinacija.ps1`
(stanje je v `<git-common-dir>/pim-koordinacija`, vidijo ga vse seje in vse delovne kopije).

1. **Začetek seje:** `powershell -ExecutionPolicy Bypass -File scripts/Koordinacija.ps1 -Ukaz Stanje`
   in `ListAgents`. Delaj na nalogi s table; če je uporabnik prosil za nekaj novega, jo najprej ustvari
   (`-Ukaz Nova`). Seznam napak strani je `docs/PREGLED_STRANI.md`, zahteve `docs/ZAHTEVE_PIM.md`.
2. **Prevzem:** `-Ukaz Prevzemi -Id N -Seja "<ime seje>"`. Skripta zavrne, če se območje (datoteke) prekriva
   z nalogo druge seje — takrat se dogovori (`SendMessage` ali `-Ukaz Sporocilo`), ne urejaj mimo.
   Priporočeno: vsaka seja v svoji delovni kopiji (worktree), glavna kopija `main` samo za združevanje.
3. **Migracije:** številko dobiš samo z `-Ukaz Migracija -Id N -Ime …` (rezervacija velja za vse seje).
4. **Vloge agentov** (`.claude/agents`): `pim-vpliv` (analiza vpliva pred spremembo), `pim-razvijalec`
   (izvedba), `pim-preverjalec` (vrata + preverjanje kot človek: brskalnik, posnetki, scenarij, hitrost).
   Pri nalogi, ki se dotika podatkov, SQL, izvozov ali SAOP, najprej `pim-vpliv`.
5. **Vrata pred »končano«:** `-Ukaz Preveri -Id N` (build Release, testi naloge, procesi, klikalnik na
   spremenjenih straneh), nato preverjalec pogleda strani v brskalniku in šele potem `-Ukaz Koncaj`.
   Brez uspešnih vrat naloga ni končana. Klikalnik ne klika Shrani — shranjevanje preveri preverjalec.
   Vrata tečejo največ `vrataHkrati` (3) naenkrat, ostali čakajo v vrsti — to ni napaka.
6. **Odločitve lastnika:** poslovno vprašanje zapiši z `-Ukaz Odlocitev` in ne ugibaj. Lastnik odgovarja
   na **nadzorni plošči** (`scripts/Tabla.cmd` → http://localhost:5099/), kjer vidi tudi agente, vrata,
   časovnico in združevanje.
7. **Čakanje:** vsaka zanka ali čakanje v Bashu ima časovno mejo (največ 15 min; vrata in združevanje do
   60 min, ker čakajo v vrsti) in ob izteku javi, zakaj.
8. **Utrip:** vsak agent se javlja (`-Ukaz Utrip -Seja -Vloga -Id -Besedilo`) in na koncu odjavi
   (`-Ukaz Odjava`). Brez utripa ga plošča pokaže kot »zastal«.
9. **Združevanje:** `-Ukaz Zdruzi -Id N` (po `Koncaj`): veja naloge dobi vse iz integracijske veje,
   se ponovno zgradi in šele nato združi v glavno kopijo; naenkrat ena. Integracijska veja in razvojni SQL
   strežnik sta v `<git-common-dir>/pim-koordinacija/nastavitve.json` (odvisno od računalnika).
10. **Dispečer** (seja, v kateri lastnik reče »delaj naloge«): prebere tablo (`-Ukaz Json`), vzame
    `pripravljena` naloge brez odprte odločitve (ali naštete številke), jih po potrebi dopolni (opis,
    kriteriji) in zažene tok `pim-naloge` z `args: {ids, seja, zdruzi: true}`. Med tekom lastniku sproti
    poroča; na koncu povzetek po §7 in kaj čaka njega. Objave na produkcijski strežnik in pošiljanja v SAOP
    ekipa ne dela nikoli.

---

## 1. Najprej sistem, potem stran

Nobena sprememba ni »samo ena stran«. Pred vsako spremembo odgovori (sebi, ne uporabniku) na:

1. **Kateri proces to je?** Poišči ga v `docs/procesi/NN-podrocje/*.md` (glava `bere`, `pise`,
   `strani`, `posli`, `koda`). Če ga ni, je to vrzel; na koncu jo omeni.
2. **Kdo še bere podatek, ki ga spreminjam?** Glej `docs/procesi/_PODATKI.md` in zaženi
   `powershell -ExecutionPolicy Bypass -File scripts/Procesi.ps1 -Ukaz Vpliv -Od origin/main`.
   Tipične verige:
   - polje izdelka → validacija (`val.*`) → pripravljenost za splet → `katalog.csv` / Magento;
   - polje, ki izvira iz SAOP → vrsta za SAOP (nikoli samodejno) → `/saop/zgodovina`;
   - cena / popust / S-popust → cenik stranke → B2B izvoz (`stranke.csv`);
   - zaloga → register virov zaloge → izvoz zaloge;
   - kategorija / atribut → nabor atributov po kategoriji → validacija → splet;
   - uvoz (Excel, XML) → `ops.ImportRun` / zgodovina uvozov → razveljavitev.
3. **Kaj naredi avtomatika?** Workerji in urniki (`docs/AVTOMATIZACIJA.md`, `docs/WORKERS.md`,
   `ops.ScheduleProfile`) lahko moj zapis prepišejo ali ga pošljejo naprej. Ali bo naslednji zajem
   iz SAOP povozil ročno vrednost? Ali bo nočni izvoz odnesel napol pripravljen podatek?
4. **Katero podjetje?** Podatki so po organizacijah (IQ Lighting = org 2, ViD …). Stran mora
   jasno povedati, v katerem podjetju dela (`PimPage OrganizationScope`), in ne sme pomešati podatkov.
5. **Katera vloga?** Pravice se preverjajo v servisu (`PimWriteGuard`, politike v
   `Services/PimAuthorization.cs`), skrivanje gumba je samo videz. Nova zapisovalna pot = politika.
6. **Koliko podatkov?** Okoli 90.000 izdelkov, ~180 izvoznih stolpcev. Filtri in listanje morajo
   biti strežniški, brez poizvedbe na vrstico, brez validacije na izdelek v zanki
   (glej `docs/SISTEM_PIM.md`, zmogljivost 218).
7. **Sled in razveljavitev.** Vsaka množična ali nepovratna sprememba mora pustiti zgodovino
   (kdo, kdaj, prej/potem) in imeti pot nazaj ali vsaj jasno potrditev.

Pri večji spremembi v povzetku napiši **»Vpliv na sistem«**: katere procese, izvoze, workerje in
strani zadane.

Vir resnice za sistem: `docs/SISTEM_PIM.md` (tok, sheme, avtomatika, zemljevid strani),
`docs/INTRANET.md` (poti, vloge, UX omejitve), `docs/DATABASE.md` (migracije), `docs/procesi/`.

---

## 2. Vsaka stran mora biti dokončana, ne minimalna

Uporabnik ne sme prositi za očitne funkcije. Za vsako stran preveri spodnji seznam; poceni
postavke naredi takoj, dražje naštej na koncu pod **»Predlagam še«**.

**Seznami in tabele**
- iskanje (brez šumnikov, `PimText.Fold`), filtri s štetjem in gumbom »Počisti filtre«;
- filtri in stran v URL-ju (povezavo se da deliti, nazaj v brskalniku deluje);
- razvrščanje po stolpcih; število zadetkov (»340 izdelkov«);
- strežniško listanje (`PimPager`) pri velikih naborih;
- potrditveno polje na vrstici + **»Označi vse«** (na strani in »vse, ki ustrezajo filtru«),
  vrstica z množičnimi dejanji: »Izbranih 12 · Izbriši · Izvozi · Nastavi …«;
- izvoz v Excel tistega, kar je na zaslonu (filtri upoštevani);
- klik na vrstico odpre podrobnosti; povezave v druge dele sistema (izdelek → SAOP zgodovina,
  validacija, cene, uvoz, iz katerega je prišel).

**Urejanje in brisanje**
- brisanje in množične spremembe: potrditev, ki pove **koliko in česa** (»Izbrisati 12 pravil?«),
  po možnosti razveljavitev;
- obrazec: preverjanje ob vnosu, jasna napaka ob polju, gumb »Shrani« onemogočen med shranjevanjem,
  opozorilo ob odhodu z neshranjenimi spremembami;
- podvajanje (»Kopiraj«) tam, kjer se zapisi ponavljajo (pravila, profili);
- po shranjevanju sporočilo, kaj se je zgodilo, in kaj bo sistem naredil naprej
  (»Shranjeno. Validacija ponovljena, 3 izdelki so zdaj pripravljeni za splet.«).

**Stanja** (`PimState`): nalaganje, prazno (s predlogom, kaj narediti), napaka (kaj in kako naprej),
brez pravic (»Samo za branje«).

**Dolga opravila:** napredek, možnost preklica, rezultat s povezavo (`HeavyWorkGate`, opravila v
ozadju). Nikoli zamrznjen gumb brez odziva.

---

## 3. Dizajn

- Pri vsaki novi strani ali prenovi naloži skill `frontend-design:frontend-design`, vendar ostani
  znotraj obstoječega vizualnega sistema intraneta. Ne izmišljuj nove palete za vsako stran.
- Barve, razmiki, radiji in pisava so žetoni v `PIM_Solution/src/PIM.Intranet/wwwroot/app.css`
  (`--pim-*`). Ne piši trdih barv; manjkajoči žeton dodaj v `:root`.
- Najprej uporabi skupne gradnike v `Components/Shared/`: `PimPage` (glava, drobtine, dejanja),
  `PimTable`, `PimPager`, `PimState`, `PimTabs`, `PimPicker` (izbira kategorije/atributa),
  `PimChip`, `PimStat`, `PimHubCard`, `PimBar`. Če se vzorec ponovi na drugi strani (npr. izbira
  vrstic in množična dejanja), ga izvleci v skupni gradnik, ne kopiraj.
- Brez Bootstrapa (`row`, `col`, `card`, `btn`, `form-control` …), ikone so CSS/SVG, ne Unicode.
- Hierarhija: eno glavno dejanje na stran (primarni gumb), sekundarna so tiha; nevarna dejanja rdeča
  in ločena. Goste, berljive tabele; številke desno poravnane; statusi kot čipi.
- Dostopnost je pogodba (UX testi jo preverjajo): `<caption>` na tabelah, `aria-label` na
  potrditvenih poljih, `role="alert"`/`"status"`, vidni `:focus-visible`, kontrast ≥ 4,5 : 1.
- Notranje povezave so base-relativne (`href="izdelki"`, ne `/izdelki`).
- Vsaka prikazana vrednost pride iz baze. Nobenih izmišljenih števcev, imen ali primerov.
- Vse UX omejitve: `docs/INTRANET.md` razdelek 6 in `PIM_Solution/UX/LESSONS.md`.

---

## 4. Rdeče črte

- **SAOP:** nikoli samodejnega pošiljanja v SAOP. Spremembe gredo v vrsto in čakajo odobritev.
  Dev in PRD obe kličeta **živi** SAOP; pazi, kaj zaženeš.
- **Manjkajoč podatek iz ERP** se popravi v zajemu/preslikavi in ponovno prebere, nikoli ročno v bazi.
- **Gesla:** obstoječih gesel v `sec.LocalUser` se ne dotikaj.
- **Baza:** preveri, na katero bazo kaže `PIM_Solution/src/PIM.Intranet/appsettings.Local.json`
  (`Server=`), preden karkoli pišeš. Nikoli testov proti produkciji.
- **Sočasne seje:** več sej Claude dela na repozitoriju hkrati. Pred urejanjem preveri `git status`;
  številke migracij se lahko podvojijo.

---

## 5. Baza

- Vsaka sprememba baze = nova oštevilčena datoteka v `PIM_Solution/sql/migrations` + razdelek v
  `docs/DATABASE.md` (spremenjeni objekti, ali je potreben ročni korak). Uporabljene migracije se ne
  spreminja.
- Začasne tabele (`#temp`) s tekstom: `COLLATE DATABASE_DEFAULT`.
- Pisalne procedure uporabljajo skupni transakcijski vzorec in pišejo zgodovino.

---

## 6. Preverjanje pred »končano«

- Build v **Release** (Visual Studio zaklene `bin\Debug`), intranet lokalno na portu 5093.
- Testi: `powershell -ExecutionPolicy Bypass -File scripts/run_tests.ps1 -Filter <F..>`
  (`dotnet test` sam ne zažene konzolnih testov). Ne zaganjaj DB dela `ProductWorkbookTests`
  (8 GB RAM zamrzne SQL).
- Stran preveri v brskalniku (preview) ali z upodabljanjem brez prijave; pokaži dokaz.
- Obstoječe napake, ki niso moje, poročaj ločeno.
- Če se je spremenil proces, v istem commitu posodobi `docs/procesi/…` in zaženi
  `scripts/Procesi.ps1 -Ukaz Graf`.

---

## 7. Oblika zaključnega povzetka

1. **Naredil sem** — kaj uporabnik zdaj vidi in lahko naredi (ne seznam datotek).
2. **Vpliv na sistem** — kaj se spremeni drugje (izvozi, SAOP, validacija, avtomatika).
3. **Preverjeno** — kako, z rezultatom.
4. **Predlagam še** — 2–5 konkretnih izboljšav, ki jih nisem naredil, po pomembnosti.
