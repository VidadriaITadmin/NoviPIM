# UX evidenca PIM Intranet

Ta mapa je operativna evidenca prenove PIM Intraneta. Referenčne slike so izključno v `../PIM_test/UX_pictures/`; nobena vrednost s slike ni dovoljen vir poslovnih podatkov za aplikacijo.

## Pravila izvedbe

1. Vsaka vidna poslovna vrednost se prebere iz PIM baze prek obstoječe ali nove read-model storitve. Statični primeri, števci, odstotki, imena uporabnikov in datumi niso dovoljeni.
2. Referenčna slika določa vizualni sistem: tipografijo, mrežo, presledke, hierarhijo, barve, ikone, filtre, tabele, oznake statusa in prazna/nalagalna stanja.
3. Codex implementira omejen sklop strani z dokazljivimi testi/buildom. Claude nato neodvisno primerja implementacijo z referenco in preveri, da podatki niso izmišljeni.
4. Po vsakem sklopu se posodobita `PROGRESS.md` in `LESSONS.md` z dokazi, ne z domnevami.
5. Nova referenca se lahko doda šele po uporabnikovi potrditvi. Ime mora začeti z `NOV_UX_` in vsebovati `PREDLOG`.

## Osnovni vizualni sistem

- Namizni shell: temna leva navigacija približno 200 px, svetla glavna površina in bela zgornja vrstica.
- Primarna barva: modra za dejanja/povezave; oranžna samo kot aktivni poudarek oziroma opozorilni status; zelena za uspeh; rdeča za napako.
- Kartice: bela podlaga, tanek svetlo-siv rob, blag radius in minimalna senca.
- Tabele: goste, berljive vrstice z jasnim zaglavjem, statusnimi oznakami in enotnim dnom s paginacijo.
- Tipografija, velikosti, razmiki in razmerja se prevzemajo neposredno iz potrjenih slik, ne iz generiranih predlogov.

Podrobno stanje je v `CURRENT_STATE.md`, ciljno preslikavo v `TARGET_STATE.md`, napredek pa v `PROGRESS.md`.
