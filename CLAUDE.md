# NoviPIM

**Vsa pravila so v [`AGENTS.md`](AGENTS.md). Preberi jih pred prvo spremembo.**
Ta datoteka je samo kazalo — pravil ne podvaja, da si ne moreta nasprotovati.

## Na hitro

- Delovni repozitorij: `C:\Users\David\Namizje\PIM\NoviPIM` — edini. Koda je v `PIM_Solution\`.
- Stack: .NET 9, Blazor Server, MS SQL. **Ni Node, ni React.**
- Edini dokaz, da nekaj dela:

```powershell
dotnet build PIM_Solution\PIM.sln
dotnet test PIM_Solution\PIM.sln --no-restore
```

  `npm test` ni dokaz ničesar — glej `AGENTS.md` §3.

## Kje je kaj

| Datoteka | Za kaj |
|---|---|
| `AGENTS.md` | pravila, ozemlja, kaj smeš brez vprašanja |
| `TASKBOARD.md` | kdo kaj dela zdaj in kaj je narejeno |
| `STATUS.md` | kje je sistem trenutno |
| `docs\HERMES.md` | navodila za koordinatorja |
| `docs\` | baza, workerji, intranet, izvozi, namestitev, E2E |

## Svoboda

Delaj sam do konca. Vprašaj samo pri brisanju, prepisu tujega dela, produkciji,
zunanjih klicih, `git push` in merge v `master` — zaprt seznam je v `AGENTS.md` §4.
