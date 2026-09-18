# Koliko osnovnega grafa je narejenega

Datum pregleda: 2026-09-08  
Obseg: SAOP/ERP, dobaviteljski XML in FTP/HTTP viri, uvoz v PIM, CSV za splet ter povratna sinhronizacija v SAOP.

## Kratek odgovor

Osnovni graf je v kodi pokrit skoraj po vsej dolžini, ni pa še v celoti operativno zaprt.
Najbolj poštena ocena je:

| Veja grafa | Koda | Avtomatski lokalni dokaz | Živa zunanja povezava | Ocena |
|---|---:|---:|---:|---|
| SAOP → viri podatkov | da | da, fixture/replay | zgodovinsko uporabljena, danes ni preverjena | delno operativno |
| XML dobaviteljev → viri podatkov | da | da, NW in BT fixture | lokalne datoteke delajo | operativno za datoteko |
| FTP/HTTP → prevzem datoteke | da, `PIM.SourceFetchWorker` | potrebni so ciljni testi | brez pravih povezav in poverilnic ni dokazano | pripravljeno, ne potrjeno |
| Viri → RAW → preslikava → kanonični PIM | da | F3/F5/F6/F7 integracijski testi | odvisno od posameznega vira | najbolj dokončan del |
| PIM → CSV za splet | da | F5/F7 in test izvoza na zahtevo | dostava na Magento/FTP/HTTP manjka | datoteka da, dostava ne |
| PIM → vrsta → SAOP | da | F8 z lokalnim HTTP strežnikom | pravi SAOP write-back ni preverjen | lokalno dokazano, živo ne |
| Urnik, nadzor in opozorila | delno/da | F9 | produkcijski razpored in prave dostave niso dokazani | delno operativno |

Če osnovni graf štejemo kot šest velikih členov, so štirje tehnično zgrajeni, dva pa sta
zaključena samo do zunanje meje. To ni isto kot »vse deluje v produkciji«.

## Kaj dejansko obstaja

### 1. SAOP (ERP) kot vhod

- `PIM.KatalogWorker` podpira `Disabled`, `Fixture` in `Live` način.
- SAOP odgovor shrani v `raw.Inbox`, nato konfiguracijske preslikave polnijo kanonični model.
- Obstajajo delta zajem, watermark, ponovna preslikava in evidenca tekov.
- F3 testi pokrivajo pogodbo, vedenje, SAOP odjemalca in integracijo.

Manjka sedanji dokaz z živim SAOP-om. Tak preizkus je zunanji klic in se izvaja šele z
ustrezno povezavo, poverilnicami ter odobritvijo.

### 2. Dobaviteljski XML

- `PIM.XmlFileWorker` je generičen: obliko vira določajo `map.SourceConnector`,
  `map.EntityMapping` in `map.FieldMapping`.
- Podprta sta vsaj Nowodvorski (`NW_XML`) in Braytron (`BT_XML`).
- F5 testi pokrivajo atribute, kategorije, medije, odkrivanje novih atributov,
  transformacije vrednosti, karanteno in integracijo.
- XML iz lokalne landing mape je prava zapisovalna pot v razvojno bazo.

Poslovna vrzel ostajajo Braytronove kategorije, dokler ni določeno ciljno drevo.

### 3. FTP/HTTP in datotečni viri

- `PIM.SourceFetchWorker` vsebuje HTTP(S), FTP in mapni prevzem v landing mapo.
- `PIM.StockFileWorker` zna NW CSV in BT XML zalogo zapisati v `stock.*`.
- To dokazuje, da datotečni del ni več samo narisan, vendar prava mesta prevzema,
  uporabniška imena in gesla niso del repozitorija in niso bila preizkušena v tem pregledu.

### 4. Osrednji PIM

- Obstajajo ločene RAW, mapping, canonical, PIM, validation, stock, B2B, outbound in ops poti.
- Sistem hrani organizacijo in izvor ter ne obravnava podatka samo kot eno CSV vrstico.
- Intranet ima preglede izdelkov, kakovosti, karantene, tekov, zalog, izvozov in odhodne poti.
- To je najbolj zrel del grafa, vendar je kakovost posameznega artikla odvisna od popolnosti
  vhodnih podatkov in poslovnih preslikav.

### 5. CSV izvozi za splet

- `PIM.B2bWorker` bere register `out.ExportProfile`/`out.ExportColumn` in ustvarja CSV.
- Obstajata tudi predogled in izvoz na zahtevo iz intraneta.
- Testi preverjajo glave, vrstni red, obvezna polja, escaping in vsebino.
- Končna dostava datoteke v Magento prek FTP/HTTP ni zaprta. Sistem danes zanesljivo dokazuje
  nastanek lokalne datoteke, ne njenega prevzema na spletni strani.

### 6. Povratna sinhronizacija v SAOP

- PIM zna sestaviti SAOP dokument, ga dati v `out.OutboxMessage`, odobriti, zahtevati ponovno
  pošiljanje, beležiti poskuse in obravnavati odgovor.
- `PIM.OutboxDispatcher` zahteva izrecni `--send` in SAOP nastavitve.
- F8 testi uporabljajo samo `127.0.0.1` in preverjajo retry, dead, sent, verified, drift,
  deduplikacijo ter lease recovery.
- Živ zapis v SAOP ni del tega pregleda. HTTP 200 sam po sebi ni PASS; preveriti je treba tudi
  SAOP rezultat v telesu in echo po ponovnem branju.

## Današnji preverjeni rezultat

Zadnji shranjeni polni zagon (`run_tests_last.log`, 2026-09-08 07:29) kaže:

- build PASS;
- 51 uspešnih, 0 preskočenih in 3 padle projekte;
- padli so `PIM.F2.Integration` (SQL 52202), `PIM.F5.Integration` (SQL timeout) in
  `PIM.F8.Integration` (SQL timeout);
- končni rezultat `REZULTAT: NEUSPESNO`.

Med tem pregledom je bil znova zagnan ukaz iz korena repozitorija:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\run_tests.ps1
```

Zagon je prišel do `=== Build ===`, končnega zelenega rezultata ni vrnil.

Dodatno:

```powershell
dotnet build PIM_Solution\PIM.sln --nologo -v:minimal
```

Rezultat: izhod 1, `Build FAILED`, vendar povzetek kaže `0 Warning(s)` in `0 Error(s)`.
To je treba diagnosticirati; dokler merodajni skript ne vrne 0, današnji status celote ni PASS.
Starejša zelena poročila dokazujejo prejšnje stanje, ne današnjega.

## Kaj manjka do zaprtega grafa

1. Odpraviti oziroma razložiti trenutni build izhod 1 in dobiti zelen `scripts\run_tests.ps1`.
2. Za vsak pravi vir potrditi povezavo, poverilnice, urnik, svežino podatkov in alarm ob napaki.
3. Izvesti varen živi SAOP GET ter primerjati en znan artikel od odgovora do PIM kartice.
4. Določiti in preizkusiti dostavo spletnega CSV-ja ter potrdilo prevzema.
5. Z odobrenim testnim artiklom in neprodukcijskim endpointom izvesti SAOP write-back in echo.
6. Zapreti odprte poslovne preslikave; teh ni mogoče pravilno uganiti v kodi.

Podrobni testi so v [TESTNI_NACRT_VSE_VEJE.md](TESTNI_NACRT_VSE_VEJE.md), preizkus enega
artikla pa v [E2E_EN_ARTIKEL.md](E2E_EN_ARTIKEL.md).
