# Trije domenski agenti za NoviPIM

## Pravilna ureditev

To niso trije zaporedni agenti po vlogah. To so trije samostojni domenski agenti, preneseni iz `PIM_osnovna`:

| Agent | Lastno področje | Ciljna koda v NoviPIM | Kaj dokonča |
|---|---|---|---|
| Agent A — ZAJEM | prejem in normalizacija podatkov iz SAOP/XML/CSV | `workers\PIM.KatalogWorker\`, `workers\PIM.XmlFileWorker\`, `src\PIM.XmlMapping\` | varno `raw.Inbox → map → canon` obdelavo z fixture/replay dokazom |
| Agent B — IZVOZ | CSV in B2B/stock izvozi | `src\PIM.B2b\`, `src\PIM.StockMapping\`, izvozne procedure `out.Export*` | preverjen lokalni CSV kontrakt in F6/F7 dokaz, brez zunanje dostave |
| Agent C — ODHODNA POT | outbox in povratna SAOP sinhronizacija | `src\PIM.Outbound\`, `workers\PIM.OutboxDispatcher\` | varna outbox pot in F8 dokaz proti loopback fixture, brez živega SAOP |

Vsak od teh treh agentov dela svojo nalogo do konca v svojem področju. Agent A ne dela izvoza, Agent B ne spreminja zajema, Agent C ne spreminja CSV izvoza.

Hermes jih orkestrira: razdeli delo, prepreči trke, spremlja dokaze in sproži Claude/Codex cikel za posamezno domeno. Hermes ne piše produkcijske kode.

## Kako vsak agent opravi nalogo

Za **vsak** domenski agent velja isti zaključeni cikel:

1. Hermes mu ustvari eno konkretno nalogo v `.hermes\naloge\`.
2. Claude Code implementira samo njegovo dovoljeno področje.
3. Codex ločeno pregleda diff, zažene zahtevane dokaze in izda `PASS` ali `FAIL`.
4. Ob `FAIL` se isti domenski agent vrne v popravek; po treh neuspešnih krogih je naloga `BLOKIRANO`.
5. Ob `PASS` in preverjenih izhodnih kodah 0 je naloga končana in agent prejme naslednjo nalogo svojega področja.

Torej: Claude in Codex nista nadomestek treh agentov. Claude je implementator, Codex je neodvisni QA mehanizem, ki ga Hermes uporabi za nalogo agenta A, B ali C.

## Vzporedno delo

Agenti A, B in C so lahko aktivni istočasno samo, kadar se ne dotikajo istih datotek oziroma iste migracije.

Dovoljeno vzporedno:

- A: worker oziroma mapping koda brez SQL migracije;
- B: B2B/stock CSV generator ali izvozna pogodba brez SQL migracije;
- C: outbox koda in F8 fixture testi brez SQL migracije.

Zaporedno, ne vzporedno:

- vsak poseg v `PIM_Solution\sql\migrations\`;
- spremembe `PIM.Migrator`;
- spremembe skupne konfiguracije, `TASKBOARD.md` ali `STATUS.md`;
- karkoli, kar spremeni skupno kanonično shemo `raw`, `map`, `canon`, `out` ali `ops`.

V danem trenutku ima vsak agent največ eno nalogo. Hermes ne odpre nove naloge za isti agent, dokler trenutna ni `KONČANO` ali `BLOKIRANO`.

## Meje treh agentov

### Agent A — ZAJEM

Dovoljene poti:

```text
PIM_Solution\workers\PIM.KatalogWorker\
PIM_Solution\workers\PIM.XmlFileWorker\
PIM_Solution\src\PIM.XmlMapping\
PIM_Solution\tests\PIM.F3.*
PIM_Solution\tests\PIM.F5.*
PIM_Solution\tests\PIM.F6.*
```

Dokaz: ustrezni F3/F5/F6 fixture, contract oziroma integration testi; noben živi SAOP/XML/FTP klic.

### Agent B — IZVOZ

Dovoljene poti:

```text
PIM_Solution\src\PIM.B2b\
PIM_Solution\src\PIM.StockMapping\
PIM_Solution\tests\PIM.F6.*
PIM_Solution\tests\PIM.F7.*
```

Dokaz: CSV pogodba, robni primeri kodiranja/ločil/vodilnih ničel in F6/F7 testi. Datoteka je lahko ustvarjena le lokalno ali v testni začasni mapi; dostava na Magento/FTP/HTTP ni del agenta B.

### Agent C — ODHODNA POT

Dovoljene poti:

```text
PIM_Solution\src\PIM.Outbound\
PIM_Solution\workers\PIM.OutboxDispatcher\
PIM_Solution\tests\PIM.F8.*
```

Dokaz: F8 contract/behavior/dispatcher/echo/integration testi in izključno loopback `127.0.0.1` HTTP fixture. Živi SAOP, profil v produkciji, resni tokeni in zunanja dostava niso del agenta C.

## Skupna pravila

1. Nadrejeni pravilnik je `..\AGENTS.md`; ta dokument ga ne more preglasiti.
2. Razvojna baza je samo lokalna `PIM`; `PIM_test` je samo za branje.
3. Vsaka sprememba sheme je nova oštevilčena migracija. Obstoječih migracij se ne ureja.
4. Poslovnih pravil agent ne ugiba. Nejasno pravilo pomeni `BLOKIRANO` z jasnim vprašanjem za Davida.
5. Koda se ne šteje za končano brez ciljnega dokaza, `dotnet build PIM_Solution\PIM.sln` in, kadar naloga ni blokirana, `scripts\run_tests.ps1` z izhodom 0.
6. UI sprememba zahteva dejanski lokalni prikaz/screenshot ter F10 test; izvorna koda in build sama nista dokaz videza.
7. Noben agent ne izvaja živega SAOP/Magento/FTP klica, IIS objave, Scheduled Taska, `git push` ali merga v `master`.

## Predloga za eno domeno nalogo

```markdown
# <A|B|C>-<oznaka>: <kratek naslov>

Agent: <A — ZAJEM | B — IZVOZ | C — ODHODNA POT>
Stanje: V_DELU
Ozemlje: <WORKERJI | DOMENA/IZVOZ | BAZA>

## Cilj
<ena merljiva poved>

## Dovoljene poti
- <točne poti; samo področje tega agenta>

## Prepovedano
- <skupne datoteke, druga dva agenta in zunanji sistemi>

## Definition of Done
- [ ] <ciljni F3/F5/F6/F7/F8 ali drugi konkreten dokaz>
- [ ] `dotnet build PIM_Solution\PIM.sln` vrne 0
- [ ] `scripts\run_tests.ps1` vrne 0 oziroma naloga jasno navede dokazano blokado

## Claude — izvedeni dokazi
<dejanski ukazi, izhodne kode, spremenjene datoteke in omejitve>

## Codex QA
<preverba vsake DoD točke; zadnja vrstica: VERDICT: PASS ali VERDICT: FAIL>
```

## Kako jih Hermes potem sproži

Hermes za vsak aktivni domeni agent pripravi ločen nalog in ga preda Claudu. Primer poziva za agenta A:

```powershell
Set-Location 'C:\Users\david\Desktop\PIM\NoviPIM'
claude -p '<celotna vsebina naloga A>' --permission-mode acceptEdits --allowedTools 'Read,Write,Edit,Bash(git *),Bash(dotnet *),Bash(powershell *)' --max-turns 40 --output-format json
```

Po Claudeovem zaključku Hermes za isto oznako ločeno sproži Codex:

```powershell
codex exec --model gpt-5.6-terra '<Preglej nalog A, git diff, izvedi zahtevane dokaze in v .hermes\naloge\ napiši A-<oznaka>-qa.md. Ne spreminjaj kode. Zadnja vrstica mora biti VERDICT: PASS ali VERDICT: FAIL.>'
```

Enak vzorec Hermes uporabi za B in C, vendar vsak prejme samo svoj nalog in svoje dovoljene poti. Če A/B/C potrebuje SQL migracijo, Hermes najprej zapre ali blokira ostale migracijske naloge in jo izvede zaporedno.

## Pripravljeni prompti za zagon

V treh ločenih Hermes sejah uporabi celotno vsebino ustrezne datoteke:

- `docs\agent-prompts\AGENT_A_ZAJEM.md`
- `docs\agent-prompts\AGENT_B_IZVOZ.md`
- `docs\agent-prompts\AGENT_C_ODHODNA_POT.md`
