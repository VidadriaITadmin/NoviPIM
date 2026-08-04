# Navodila za AI agente (Codex)

## Projekt
Kratek opis aplikacije in tehnologij.

## Kako delati
- Delaj majhne, zaključene spremembe; vsaka naj bo svoj commit
- Sporočila commitov: kratek opis v slovenščini
- Pred zaključkom naloge poženi: `npm test` in `npm run lint`
- Če test pade, ga popravi, preden nadaljuješ
- Po zaključku dopiši vrstico v PROGRESS.md

## Struktura
- src/ — izvorna koda
- tests/ — testi (za vsako novo funkcijo dodaj test)

## Standardi
- Zamik: 2 presledka
- Brez novih odvisnosti brez potrebe; če jo dodaš, jo utemelji v commit sporočilu

## Prepovedano
- Brisanje ali prepisovanje .env in konfiguracij brez izrecne zahteve
- Force push
- Spreminjanje CI konfiguracije (.github/) brez izrecne zahteve

---

# Usmerjanje dela (koordinator + podagenti)

## Model
Uporabnik govori z **enim agentom = vodjo (koordinatorjem)**. Uporabnik pove
**cilj** v naravnem jeziku; vodja sam razbere, katero ozemlje je prizadeto, in
razdeli delo. Uporabniku ni treba reči, ali je nekaj "baza" ali "intranet".

Vodja NE dela dveh nepovezanih stvari sam zaporedno, če se ne dotikata istih
datotek — takrat požene **več podagentov vzporedno** in na koncu združi rezultate.

## Ozemlja (po tem vodja usmerja)
- **BAZA** — `PIM_Solution/sql/` (migracije, sheme, raw tabele), `PIM.Migrator`
- **INTRANET** — `PIM_Solution/src/PIM.Intranet/` (Blazor strani, servisi, UI)
- **WORKERJI** — `PIM_Solution/workers/*` (Katalog, NwXml, XmlFile, SaopStock,
  StockFile, B2b, Foundation, AlertDispatcher, OutboxDispatcher, Watchdog)
- **DOMENSKI PROJEKTI** — `PIM_Solution/src/PIM.B2b`, `PIM.Operations`,
  `PIM.Outbound`, `PIM.StockMapping`, `PIM.XmlMapping`

## Pravila usmerjanja
1. **Različne / nepovezane naloge** (dotikajo se ločenih ozemelj) → vzporedno,
   vsak podagent samo svoje ozemlje. Nič prekrivanja datotek.
2. **Povezane naloge** (ena je odvisna od druge, npr. najprej DB polje, potem
   prikaz) → zaporedno: najprej odvisnost (npr. migracija + commit), nato odjemalec.
3. **Ena sama stvar** → en podagent na pravem ozemlju.
4. Če dva podagenta rabita isto datoteko → NE vzporedno; nadaljuj zaporedno.

## Skupni spomin (OBVEZNO za vsakega agenta/podagenta)
- **Pred nalogo:** preberi `TASKBOARD.md` in naredi `git pull`.
- **Po nalogi:** dopiši rezultat v `TASKBOARD.md` (status + kdo + kaj) in commitaj.
- Ozemlja se ne prepletajo v enem commitu — vsako ozemlje svoj commit.
- `TASKBOARD.md` je edini vir resnice o tem, kdo kaj dela in kaj je narejeno.
