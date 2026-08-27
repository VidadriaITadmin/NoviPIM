# Specifikacije starega PIM-a — in kaj od njih velja za NoviPIM

Ta mapa je nastala iz dokumentacije **starega sistema** (`..\PIM_test`). Njegove sheme, poti,
workerji in izmerjene številke za NoviPIM ne veljajo, poslovna vizija in oblikovna načela pa.

## Kaj je kje

| Datoteka | Kaj je |
|---|---|
| `Nacrt_PIM_Sistem_Vizija.md` | **v2.0 — prepisano za NoviPIM**: vizija, izmerjeno stanje, vrzeli, prioritete |
| `Nacrt_Intranet_Aplikacija.md` | **v2.0 — prepisano za NoviPIM**: izgled, navigacija, sklopi, pravila strani |
| `izvirniki_stari_PIM/` | **nespremenjena izvirnika v1.0** (stari sistem) — samo za primerjavo |
| `Sestva_PIMa/Prompt_Codex_Delovna_Okolja_Reorganizacija.md` | **ZASTARELO — ne izvajaj.** Prompt za star sistem (`src/`, sheme `stg`/`pim`, poti `/products`, `/quality/issues`). Nadomešča ga [`docs/agent-prompts/CODEX_INTRANET_KARTICA_VALIDACIJA_PREVERBE.md`](../agent-prompts/CODEX_INTRANET_KARTICA_VALIDACIJA_PREVERBE.md) |

Izvirnika sta ohranjena zato, ker sta edini zapis, kako je bilo nekaj rešeno prej. Po
`AGENTS.md` §1 velja: iz `PIM_test` se ničesar ne kopira kot pravilo.

## Kaj je pri prepisu zamenjano

Zapis: `STG` → `raw.Inbox`/`canon.*`; `pim.OutputChannel`/`OutputColumn` →
`out.ExportProfile`/`out.ExportColumn`; `pim.vw_StockUnified` → `stock.*`; shema `media.*` →
`canon.ProductMedia`/`ProductDocument`; trije kanali → sedem validacijskih profilov;
6 workerjev → 10; angleške poti (`/products`, `/stg/products`) → slovenske
(`izdelki`, `zajem`, `kakovost`, `izvozi`, …); makete `UX_pictures/` → `PIM_Solution\UX\` in
`docs/NACRT_INTRANET_PRENOVA.md` §13.

Podroben seznam je v obeh dokumentih (`Nacrt_PIM_Sistem_Vizija.md` §0,
`Nacrt_Intranet_Aplikacija.md` uvodna opomba).

## Kje je merodajno stanje

Ta dokumenta sta **namen in ciljna slika**, ne stanje. Za stanje velja:

- `STATUS.md` — kje je sistem
- `docs/INTRANET.md` — dejansko stanje intranet kode
- `docs/PRODUKTNI_MODEL_PIM.md` — trajni zemljevid faz, virov in pogodb
- `PIM_Solution\NAVIGACIJSKI_SISTEM_IN_FUNKCIJE_STRANI.txt` — funkcija za funkcijo, TRENUTNO/DODATI
