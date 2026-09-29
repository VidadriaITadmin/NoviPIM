# Ekipa agentov — navodila za lastnika

Na PIM lahko hkrati dela več agentov Claude, kot ekipa razvijalcev. Ti vpišeš, kaj želiš; ekipa
analizira, razvije, preizkusi, pogleda strani kot človek in delo združi. Vse vidiš na nadzorni plošči.

## 1. Odpri nadzorno ploščo

Dvoklik na `scripts\Tabla.cmd`. Odpre se http://localhost:5099/ in se osvežuje sama (zelena pika
»v živo« zgoraj levo). Stran lahko pustiš odprto ves dan.

## 2. Vpiši nalogo

Na zavihku **Domov**, okvir **1 Vpiši nalogo**: en stavek, kaj naj ekipa naredi, in po želji podrobnosti
(kje, kaj vidiš, kaj pričakuješ). Gumb **Dodaj nalogo**. Za nujnost, stran in vrsto klikni **Več možnosti**
ali zgoraj desno **Nova naloga**.

Nalogo lahko napišeš tudi kar v Claude: »dodaj nalogo: …«.

## 3. Zaženi ekipo

Okvir **2 Zaženi ekipo**: v Claude (zavihek Code, ta projekt) napiši

> delaj naloge

ali samo izbrane: »delaj naloge 12, 14«. Seja, v kateri to napišeš, je **dispečer**: izbere naloge, ki se
ne prekrivajo, in zažene ekipo. Vsaka naloga dobi svoje agente:

| Član ekipe | Barva | Kaj naredi |
|---|---|---|
| **Analitik** | vijolična | Kdo še bere podatek, kaj gre v SAOP, katalog.csv, validacijo; katere datoteke bo naloga zaklenila. |
| **Razvijalec** | modra | Naredi spremembo v svoji kopiji kode, da ne moti drugih. |
| **Samodejni preizkus** | rumena | Sestavi program, zažene teste in odpre strani (posnetki). Največ trije hkrati. |
| **Preverjalec** | turkizna | Odpre strani v brskalniku kot človek, klika, meri hitrost. Napake vrne razvijalcu. |
| **Integrator** | zelena | Delo združi v skupno kodo, ko je vse preizkušeno. Naenkrat eno. |
| **Nadzornik** | oranžna | Na koncu preveri, da nič ne visi, in napiše povzetek. |

## 4. Kaj vidiš na plošči

Plošča ima pet zavihkov. Za vsakdanjo rabo zadošča **Domov**.

- **Domov** — na vrhu **en stavek**, ki pove, ali moraš ti kaj narediti:
  rožnato »Ekipa te potrebuje« (odgovori spodaj), rdeče »ustavljeno«, modro »Ekipa dela — ni ti treba
  nič«, rumeno »naloge čakajo na začetek« (napiši »delaj naloge«), zeleno »Vse je narejeno«.
  Pod njim trije koraki in kartice nalog v teku.
- **Kartica naloge** — pot v petih korakih: *Analiza → Razvoj → Preizkus → Združevanje → Narejeno*.
  Zeleno = opravljeno, modro utripa = dela se zdaj, rožnato = čaka tvoj odgovor, rdeče = ustavljeno.
  Klik odpre podrobnosti: kaj je treba narediti, posnetke strani iz preizkusa in »Kaj se je zgodilo«.
- **Naloge** — vse naloge s filtri (Čaka na začetek, Ekipa dela, Čaka tebe, Ustavljene, Narejeno) in iskanjem.
- **Ekipa v živo** — kdo dela zdaj in kaj točno, preizkusna mesta in »Kdo čaka koga«.
- **Zgodovina** — časovnica zadnjih 12 ur in dogodki po domače.
- **Za tehnike** — veje, kopije kode, migracije, seje Claude. Ni ti treba gledati.

## 5. Kaj ekipa nikoli ne naredi sama

- **Ne pošilja v SAOP.** Spremembe gredo v vrsto in čakajo tvojo odobritev v intranetu.
- **Ne objavlja na produkcijski strežnik.** Ko je delo združeno, objavo narediš ti (glej `Navodila/03_Publish.md`).
- **Ne ugiba poslovnih pravil.** Če ni jasno (npr. »ali tranzit dobi S-popust?«), vpraša tebe in počaka.
- **Ne dela na produkcijski bazi.** Vse preizkuse dela na razvojni bazi tega računalnika.

## 6. Ko nekaj ne gre

| Vidiš | Pomeni | Naredi |
|---|---|---|
| Naloga v »Blokirane« | Konflikt z delom druge naloge ali build po posodobitvi ne gre skozi. | Reci dispečerju »poglej nalogo N«. |
| Član ekipe »ne odziva se« | Agent se več kot 30 min ni oglasil. | Reci dispečerju; nadzornik ga ob koncu pospravi. |
| Vrata NAPAKA | Preizkus je našel napako. | Nič — razvijalec jo popravlja sam. Če ostane, je v povzetku. |
| Zgoraj »brez povezave« | Strežnik plošče ne teče. | Ponovno dvoklik na `scripts\Tabla.cmd`. |

## 7. Tehnično (za razvijalce)

Tabla: `scripts/Koordinacija.ps1` (stanje v `.git/pim-koordinacija`, skupno vsem delovnim kopijam).
Tok: `.claude/workflows/pim-naloge.js`. Vloge: `.claude/agents/`. Plošča: `scripts/tabla/`.
Nastavitve računalnika (razvojni SQL strežnik, integracijska veja, `vrataHkrati`,
`samodejnoZdruzi`): `.git/pim-koordinacija/nastavitve.json`. Pravila za seje: `CLAUDE.md` §0.
