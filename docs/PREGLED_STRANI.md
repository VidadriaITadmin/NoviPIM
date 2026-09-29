# Pregled strani intraneta — skupni seznam napak

Začeto 2026-09-29. To je **en seznam** vsega, kar na straneh ne deluje. Vsaka seja ga bere na začetku,
popravlja od vrha navzdol in odkljuka, kar je popravljeno in preverjeno s klikalnikom
(`PIM_Solution/tools/PIM.Klikalnik`). Novo napako dopiši na konec ustreznega razdelka (zadošča ena vrstica).

Viri: statični pregled kode vseh 85 strani (razor → servis → SQL) in klikalnik (brskalnik, vgrajen
skrbnik, razvojna baza). Rezultat klikalnika: `PIM_Solution/tools/PIM.Klikalnik/porocilo/klikalnik.md`.

Oznake: **[V]** visoka (napačen rezultat, izgubljeni podatki, »ne dela«), **[S]** srednja (zmede,
zahteva obvod), **[N]** nizka (manjka udobje).

---

## A. Skupni vzroki (en popravek odpravi napako na več straneh)

Te popraviti najprej: vsak odpravi veliko pritožb naenkrat.

- [ ] **A1 [V] Gumb se ne odzove na prvi klik.** Polje se pošlje strežniku šele, ko zapustiš polje;
  gumb je do takrat siv in brskalnik klik zavrže. Zadane: /izdelki/odprodaja (Shrani, Dodaj),
  /stranke/{id} (Zapiši zaznamek, Dodaj pravilo embalaže), /kakovost/artikli (Zadrži), /preverbe (Shrani prag),
  /izvozi/mnozicno, /administracija (Najdi v AD), /saop/artikli (Preveri in dodaj), /pravila/slovar,
  /pravila/preslikave, /nastavitve/nabori-atributov (Uvozi seznam).
  Popravek: `@bind:event="oninput"` na poljih, od katerih je odvisen `disabled`.
- [ ] **A2 [V] Ob napaki dejanja izgine cela tabela.** Napaka shranjevanja gre v isto polje kot napaka
  nalaganja, `PimState` pa takrat skrije vsebino. Zadane: /nastavitve/kategorije, /nastavitve/atributi,
  /nastavitve/nabori-atributov, /nastavitve/rezervacija-zaloge, /kakovost/kategorije, /preverbe, /saop,
  /saop/zgodovina, /saop/odkloni, /zajem/atributi. Popravek: ločen `ActionError` nad tabelo.
- [ ] **A3 [V] Vloga COMMERCIAL vidi urejevalnike, shranjevanje pa pade.** Strani odpre komercialist,
  servis pa zahteva `CatalogWrite`/`SaopWrite` (samo ADMIN in CATALOG_EDITOR). Stanja »Samo za branje« ni,
  napaka je splošna ali pogoltnjena. Zadane: kartica izdelka (nobeno polje), /cene (gumbi skriti brez razlage),
  /nastavitve/kategorije, /nastavitve/atributi, /nastavitve/nabori-atributov, /nastavitve/rezervacija-zaloge,
  /izvozi/mnozicno, /izvozi/obvestila (Potrdi). **Odločitev uporabnika:** kaj sme komercialist urejati?
- [ ] **A4 [V] /outbound: odobritev se zapiše, stran pa javi napako.** `ApproveItemAsync`/`CancelItemAsync`
  nimata preverjanja pravic v servisu; pravica pade šele pri pošiljanju. Varnostna vrzel in lažna napaka hkrati.
- [ ] **A5 [S] Sporočilo »Shranjeno« takoj izgine.** Po shranjevanju se stran ponovno naloži in pobriše sporočilo:
  kartica izdelka (oznake, odprodaja, zaključi), /administracija/vloge (vsa dejanja). Uporabnik misli, da ni delovalo.
- [ ] **A6 [S] Shranjevanje ene vrstice/sklopa zavrže neshranjene spremembe drugih.** /izdelki/odprodaja,
  /stranke/{id}, /varovalke, /splet/umaknjeni, /administracija, /administracija/vloge.
- [ ] **A7 [S] Filter se uveljavi šele z gumbom »Uporabi filtre«**, drugje takoj: /izdelki, /kakovost/napake,
  /kakovost/karantena. Poenotiti: izbira velja takoj, iskanje ob Enter.
- [ ] **A8 [S] Iskanje ne ignorira šumnikov** (»zarnica« ne najde »žarnica«) skoraj povsod; `PimText.Fold` uporablja
  samo /splet. Popravek: skupna funkcija iskanja (C#: `PimText.Matches`, SQL: `COLLATE …_CI_AI`).
- [ ] **A9 [S] Filtri niso v naslovu strani** (osvežitev in »nazaj« jih izgubita, povezave ni mogoče deliti):
  /cene, /stranke, /mediji, /outbound, /saop/zgodovina, /zajem, /sistem/teki, /uvozi, /pravila-popustov in ~14 nastavitvenih strani.
- [ ] **A10 [S] Filter s tehničnimi kodami namesto imen**: status na /outbound in /saop/zgodovina (PendingApproval …),
  nivoji na /kakovost/napake (ERP_SLO), vrste preverb, skupina/ABC/rabat na /izdelki, vloge na /mediji.
- [ ] **A11 [S] PimPicker pobriše vpisano besedilo**, če ne klikneš možnosti (filtri na /izdelki, kategorije, atributi).
- [ ] **A12 [N] Tabele nimajo razvrščanja po stolpcih** (`PimTable`), nimajo »Označi vse« in množičnih dejanj.
  Predlog: skupni gradnik za izbiro vrstic + vrstico dejanj.
- [ ] **A13 [S] Predupodabljanje:** stran je vidna, a prvih nekaj sekund kliki ne delujejo in podatki se naložijo
  dvakrat (vse interaktivne strani). Potrditi s klikalnikom; popravek `prerender: false` na težkih straneh.

## B. Po straneh — najresnejše

### Izdelki
- [ ] [V] /izdelki — iskanje ne išče po nazivu, samo po šifri in EAN (`intranet.GetProductList`, preverjeno na bazi).
- [ ] [S] /izdelki — ob menjavi podjetja v filtru ostanejo proizvajalci/dobavitelji starega obsega; izbira vrne 0.
- [ ] [S] /izdelki — »Nazadnje spremenjeni« razvršča po drugem datumu, kot ga kaže stolpec.
- [ ] [N] /izdelki — »Napaka: Brez slike« in »Slika: Brez slike« sta isti filter; brez »Označi vse«; pager samo naprej/nazaj.
- [ ] [V] /izdelki/{id} — prazna številska polja kažejo »—« in se štejejo za izpolnjena; »—« lahko gre v SAOP.
- [ ] [V] /izdelki/{id} in /izdelki/{šifra}/kategorije — izbrana kategorija se ne shrani brez vmesnega »Dodaj na seznam«.
- [ ] [S] /izdelki/{id} — vsako shranjevanje izprazni in znova izriše celo kartico (izgubiš mesto).
- [ ] [S] /izdelki/{id} — dobavitelj/proizvajalec sta prosto besedilo; napačen vpis gre v vrsto za SAOP.
- [ ] [V] /izdelki/odprodaja — »Vir« se po izbiri datoteke lahko spremeni, uvoz pa gre pod starim virom.
- [ ] [V] /izdelki/uvoz — izbira podjetja po izbiri datoteke nima učinka; napaka po zapisu povabi k dvojnemu uvozu.
- [ ] [S] /izdelki/uvoz — povezava »Kategorije« v oknu Manjkajoče vodi na neobstoječo stran (`kategorije`).
- [ ] [S] /izdelki/novi-artikli — klik na kartico števca spremeni naslov, filter pa ostane star; filtra Stanje in SAOP se prepisujeta.

### Cene, zaloge, stranke
- [ ] [S] /cene — iskanje velja samo ob Enter, čip in izvoz pa že kažeta novo iskanje; ni iskanja po nazivu.
- [ ] [S] /cene — »Cenik = X« + »Vsaj N cenikov« vedno vrne 0.
- [ ] [S] /cene — napake nalaganja so prikazane kot »Ni cenikov« / »Izdelek nima cen«.
- [ ] [S] /cene/tisk — samo B2C/B2B (podjetja brez B2C dobijo prazne cene); kategorijo je treba natipkati točno; ob menjavi izbire ostanejo stare vrstice pod novo glavo.
- [ ] [V] /stranke/{id} — tipa ali vrste stranke ni mogoče vrniti na »Ni določen« (napaka baze, prazen niz namesto NULL).
- [ ] [S] /stranke/{id} — v izbiri »Iz šifranta strank« le prvih 500 strank; manjkajo polja iz 279 (referent, e-pošte, P2).
- [ ] [S] /stranke — filtri, zavihek in stran niso v naslovu; »Nazaj« iz stranke vse izgubi.
- [ ] [S] /pravila-popustov — posebnih izjem ni mogoče urediti ali odstraniti; izjema zahteva interni ID stranke; poštnina, pragovi in preslikava veljajo za vsa podjetja, stran pa kaže izbrano podjetje.
- [ ] [S] /stranke/uvoz, /cene/uvoz — izbira podjetja po nalaganju datoteke nima učinka.

### Kakovost
- [ ] [V] /kakovost/napake — ob izbranem nivoju se filtra Profil in Blokira ignorirata (seznam, števec in izvoz).
- [ ] [V] /kakovost/napake — povezava na izdelek vedno odpre Pregled, ne manjkajočega polja (napačni razdelki).
- [ ] [S] /kakovost/napake — »Samo napake« skrije del napak; klik na pravilo včasih vrne prazen seznam; KPI povezave zamenjajo podjetje; izbirnik Polje ima samo 15 polj.
- [ ] [V] /preverbe — števec kaže tisoče, vidnih je le 50 cen + 50 zalog, brez listanja.
- [ ] [S] /preverbe — artikel brez povezave odpre izdelek 0; cenovna preverba odpre napačen razdelek; »Cenik ali skladišče« zahteva točno kodo.
- [ ] [S] /kakovost/artikli — klik na KPI preračuna vse ostale KPI (pokažejo 0) in ponastavi podjetje.
- [ ] [S] /kakovost/karantena, /kakovost/prevodi — vse ali samo 300 vrstic, brez strežniškega listanja.

### Nastavitve in pravila
- [ ] [V] /nastavitve/kategorije — po »Shrani prevode« se polja izpraznijo (videti, kot da ni shranjeno).
- [ ] [V] /nastavitve/atributi — »Odpri vrednosti« pri večini atributov pokaže »Vrednosti niso na voljo« (koda proti imenu v SQL).
- [ ] [V] /nastavitve/atributi — kljukice in »N izbranih« nimajo nobenega dejanja.
- [ ] [V] /pravila/validacija — vsak klik (Napaka, Opozorilo, Umakni …) sproži validacijo vseh podjetij in zamrzne stran za minute.
- [ ] [V] /pravila/nazivi — novo pravilo z obstoječo kodo tiho povozi staro; »Shrani in zapiši nazive« zapiše tudi podkategorijam z lastnim pravilom.
- [ ] [V] /splet/katalog — iskanje po šifri praviloma ne najde nič (privzeti filter čakalne vrste), brez praznega stanja.
- [ ] [S] /nastavitve/kategorije — »+ Dodaj podkategorijo« po zaprtju panela ne dela več; »Uredi nabor« se odpre izven pogleda.

### Splet, izvozi, SAOP
- [ ] [V] /splet/izvoz — 3 od 4 spletišč v seznamu vrnejo prazen predogled (seznam ni usklajen z 214).
- [ ] [S] /splet/umaknjeni — povezava »Artikli z blokirajočimi napakami« odpre nefiltriran seznam.
- [ ] [S] /outbound — ob vsakem kliku naloži celotno zgodovino; skupinska dejanja brez `finally` (gumbi ostanejo sivi).
- [ ] [S] /saop/artikli — pasica zadržanih sprememb pokaže in potrdi spremembe **vseh** podjetij.
- [ ] [S] /saop/zgodovina — »Pripravi popravek« vzame tudi izbrane vrstice, ki jih filter skriva.
- [ ] [S] /saop/odkloni — stolpec »Kaj je ERP vrnil« je vedno »—«; po »Pošlji znova« se seznam ne osveži.
- [ ] [S] SAOP strani — podjetje se izbira na dva načina; sosednji zavihki lahko kažejo različni podjetji.

### Zajem, sistem, administracija
- [ ] [V] /zajem — ko filter nima zadetkov, izginejo tudi filtri (nazaj samo z osvežitvijo).
- [ ] [V] /sistem/teki — filter »Postopek« filtrira samo trenutno stran in trdi, da je to vse.
- [ ] [S] /zajem — filter »Še brez teka« nikoli ne najde ničesar (`CASE … WHEN NULL`).
- [ ] [S] /zajem/cakalna-vrsta — izbrane entitete ni mogoče vrniti na »vse«.
- [ ] [S] /zajem/tezave/…, /sistem/teki/{id} — seznam kaže vsa podjetja, podrobnost pa »ne obstaja« za drugo podjetje.
- [ ] [S] /sistem/posel/{posel} — neveljaven vnos v urniku se tiho prezre.
- [ ] [S] /administracija — napaka pri nalaganju sesuje stran; »Dodaj račun« doda vpisano, ne najdeno ime.

## C. Klikalnik (brskalnik) — tek 2026-09-29

82 strani, brskalnik, vgrajen skrbnik, razvojna baza. Spodaj so samo najdbe, ki sem jih pregledal
ročno. Lažne alarme sem izločil: statične strani (/, /nastavitve, /pravila, /nadzorna-plosca) niso
»neinteraktivne«, na /stranke pa je bil klikalnik prehiter in razvrščanje deluje.

**Pozor pri časih:** med tekom je druga seja poganjala `val.RunValidation`, klikalnik pa je pomotoma
zagnal izvoz 179.220 vrstic z /izdelki (preklican). Časi so zato previsoki; pred popravljanjem jih
izmeri na mirni bazi.

- [ ] [V] **Hitrost** — nalaganje nad 20 s: /zajem 73 s, /kakovost/napake 65 s, /izdelki/novi-artikli
  in /zajem/novi-artikli 62 s, /cene 49 s, /nastavitve/atributi 34 s, /zajem/neujemanja 32 s,
  /preverbe 30 s, /izdelki 29 s, /splet/umaknjeni 27 s, /nastavitve/kategorije 27 s, /pravila/validacija 26 s,
  /kakovost/artikli 20 s.
- [ ] [S] /mediji — ob spremembi filtrov se prejšnje poizvedbe ne prekličejo; v bazi je hkrati teklo 5 enakih poizvedb.
- [ ] [S] /splet/katalog — iskanje obstoječega aktivnega artikla (OL.PETAR.ANTRACITE) vrne prazno tabelo
  brez razlage; Enter v iskanju ne deluje, dela samo »Prikaži« (potrjeno v brskalniku).
- [ ] [S] /kakovost/karantena, /zajem/neujemanja, /saop/odkloni, /saop/polja, /pravila/preslikave,
  /analitika/artikli — izbira drugega podjetja v spustnem seznamu ne spremeni prikaza (preveri: ali je
  podjetje prazno ali filter čaka na gumb).
- [ ] [S] /analitika — izbira dobavitelja ne spremeni prikaza.
- [ ] [S] /kakovost/prevodi — izbira jezika ne spremeni prikaza.
- [ ] [S] /saop/zgodovina — izbira entitete »Product« ne spremeni prikaza.
- [ ] [S] /administracija — filter »Stanje računa« ne spremeni prikaza.
- [ ] [S] /splet/izvoz — izbira profila ali spletnega mesta ne spremeni prikaza, dokler ne klikneš »Prikaži« (glej B: 3 od 4 spletišč prazna).
- [ ] [S] /cene/tisk — jezik in spletno mesto nimata učinka do »Pripravi cenik« (glej B: stare vrstice pod novo glavo).
- [ ] [N] /administracija/mape, /splet, /outbound, /splet/katalog — »Osveži« ne pove, ali je osvežil (ni sporočila ali časa).
- [ ] [N] /sistem/sled, /nastavitve/povezave-izdelkov — iskanje nima učinka do klika na gumb (Enter ne dela).
- [ ] [N] /izvozi/profili/{id}, /nastavitve/atributi/{koda}, /zajem/teki/{id} — nobena stran ne vodi sem
  (ali povezave manjkajo ali pa so samo v podrobnostih).
- [ ] [N] Veliko filtrov ni v naslovu strani (glej A9) — klikalnik jih je našel na 20+ straneh.

### Opombe za naslednji tek klikalnika
- Klikalnik je kliknil »Poženi« na /sistem in oddal zahtevo za zagon posla `WEB_CATALOG_EXPORT`
  (`ops.JobDefinition.RequestedBy = 'klikalnik'`, razvojna baza). Na razvojnem računalniku to ne gre v SAOP;
  zahtevo lahko prekličeš na /sistem ali pustiš. Besede pozen/zahtev/izvoz/prenesi so zdaj izključene.
- Klikalnik ne klika Shrani in ne preverja vlog. Shranjevanje in vlogo COMMERCIAL je treba preveriti posebej
  (glej A3).
