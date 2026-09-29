# Ekipa agentov — navodila za lastnika

Na PIM lahko hkrati dela več agentov Claude, kot ekipa razvijalcev. Ti vpišeš, kaj želiš; ekipa
analizira, razvije, preizkusi, pogleda strani kot človek in delo združi. Vse vidiš na nadzorni plošči.

## 1. Odpri nadzorno ploščo

Dvoklik na `scripts\Tabla.cmd`. Odpre se http://localhost:5099/ in se osvežuje sama (zelena pika
»v živo« zgoraj levo). Stran lahko pustiš odprto ves dan.

## 2. Vpiši nalogo

Gumb **Nova naloga** zgoraj desno:

- **Kaj naj ekipa naredi** — en stavek, npr. »Filtri na /izdelki se ne ohranijo po kliku nazaj«.
- **Podrobno** — kje, kaj vidiš, kaj pričakuješ, kako veš, da je narejeno. Več kot napišeš, manj
  vprašanj dobiš nazaj.
- **Strani** — če veš, na kateri strani je (npr. `izdelki`, `cene/ceniki`).
- **Prednost** — Visoka gre prva.
- »Takoj pripravljena za ekipo« — če je ne obkljukaš, ostane med predlogi, dokler je ne sprostiš.

Nalogo lahko napišeš tudi kar v Claude: »dodaj nalogo: …«.

## 3. Zaženi ekipo

V Claude (zavihek Code, ta projekt) napiši:

> delaj naloge

ali samo izbrane: »delaj naloge 12, 14«. Seja, v kateri to napišeš, je **dispečer**: prebere tablo,
izbere naloge, ki se ne prekrivajo, in zažene ekipo. Vsaka naloga dobi svoje agente:

| Vloga | Kaj naredi |
|---|---|
| **Analitik vpliva** (vijolična) | Kdo še bere podatek, kaj gre v SAOP, katalog.csv, validacijo; katere datoteke bo naloga zaklenila. |
| **Razvijalec** (modra) | Naredi spremembo v svoji kopiji kode (veja `naloga/N`). Številke migracij dobi s table, zato se ne podvojijo. |
| **Vrata** (rumena) | Samodejni preizkus: build, testi, procesi, klikalnik po straneh s posnetki. |
| **Preverjalec** (turkizna) | Drug agent odpre strani v brskalniku, klika, meri hitrost, preveri bazo. Če najde napako, gre nazaj k razvijalcu (največ dvakrat). |
| **Integrator** (zelena) | Vejo posodobi z vsem, kar so medtem naredili drugi, ponovno zgradi in šele nato združi. Naenkrat eno. |
| **Nadzornik** | Na koncu preveri, da je tabla urejena in nič ne visi, in napiše povzetek. |

## 4. Kaj vidiš na plošči

- **Številke zgoraj** — koliko agentov dela, koliko nalog je v delu, koliko čaka tebe (utripa rdeče),
  koliko jih čaka v vrsti, katerim so padla vrata, koliko je danes združenih.
- **Tekoči trak** — vsaka naloga (`#12`) potuje od predlogov do »Združeno«. Pika na številki pomeni,
  da agent na njej dela zdaj.
- **Ekipa zdaj** — kartica za vsakega agenta: vloga, naloga, kaj dela v tem trenutku, koliko časa.
  »tiho« = se nekaj minut ni oglasil (normalno pri dolgem buildu); **»ZASTAL«** (rdeče) = več kot pol
  ure brez glasu — povej dispečerju.
- **Čaka tebe** — vprašanja ekipe. Odgovoriš kar tam, s svojimi besedami. Spodaj so tudi sprejete
  naloge, ki jih lahko združiš z enim klikom (če samodejno združevanje ni vklopljeno).
- **Mesta za vrata** — največ trije preizkusi hkrati, da računalnik in SQL ne zamrzneta. Ostali čakajo
  v vrsti; to ni napaka.
- **Kdo čaka koga** — puščice: katera naloga čaka tebe, drugo nalogo, vrsto ali je blokirana.
- **Časovnica** — kaj se je v zadnjih 12 urah zgodilo po nalogah (pike: modra razvoj, rumena vrata,
  zelena uspeh, rdeča napaka, roza vprašanje zate).
- **Tabla nalog** — klik na nalogo odpre podrobnosti: opis, zaklenjene datoteke, izid vrat s posnetki
  strani, dnevnik vsega, kar se je z nalogo zgodilo, in dejanja (prednost, združi, opusti).

## 5. Kaj ekipa nikoli ne naredi sama

- **Ne pošilja v SAOP.** Spremembe gredo v vrsto in čakajo tvojo odobritev v intranetu.
- **Ne objavlja na produkcijski strežnik.** Ko je delo združeno, objavo narediš ti (glej `Navodila/03_Publish.md`).
- **Ne ugiba poslovnih pravil.** Če ni jasno (npr. »ali tranzit dobi S-popust?«), vpraša tebe in počaka.
- **Ne dela na produkcijski bazi.** Vse preizkuse dela na razvojni bazi tega računalnika.

## 6. Ko nekaj ne gre

| Vidiš | Pomeni | Naredi |
|---|---|---|
| Naloga v »Blokirane« | Konflikt z delom druge naloge ali build po posodobitvi ne gre skozi. | Reci dispečerju »poglej nalogo N«. |
| Agent »ZASTAL« | Agent se več kot 30 min ni oglasil. | Reci dispečerju; nadzornik ga ob koncu pospravi. |
| Vrata NAPAKA | Preizkus je našel napako. | Nič — razvijalec jo popravlja sam. Če ostane, je v povzetku. |
| Zgoraj »brez povezave« | Strežnik plošče ne teče. | Ponovno dvoklik na `scripts\Tabla.cmd`. |

## 7. Tehnično (za razvijalce)

Tabla: `scripts/Koordinacija.ps1` (stanje v `.git/pim-koordinacija`, skupno vsem delovnim kopijam).
Tok: `.claude/workflows/pim-naloge.js`. Vloge: `.claude/agents/`. Plošča: `scripts/tabla/`.
Nastavitve računalnika (razvojni SQL strežnik, integracijska veja, `vrataHkrati`,
`samodejnoZdruzi`): `.git/pim-koordinacija/nastavitve.json`. Pravila za seje: `CLAUDE.md` §0.
