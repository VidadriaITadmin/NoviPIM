# Brifing za Hermesa — nova ureditev (2026-08-12)

> To je besedilo, ki ga dobi Hermes ob prvem zagonu po reorganizaciji.
> Pot: `C:\Users\David\Namizje\PIM\NoviPIM\docs\BRIFING-HERMES.md`

---

Struktura projekta in pravila so se spremenili. Preberi to do konca, preden
karkoli narediš.

## Kaj se je spremenilo in zakaj

Doslej so hkrati veljali trije sklopi pravil, ki so si nasprotovali. Zato so
agenti delali napačne stvari:

1. **Nadrejena mapa** `C:\Users\David\Namizje\PIM\` je imela svoja `AGENTS.md`
   in `CLAUDE.md`, ki sta opisovala strukturo, ki ne obstaja — `db/migrations/`,
   `scripts/run_tests.ps1`, `docs/01-faze.md`, `ops/naloge/`. Ker orodja berejo
   pravila tudi iz nadrejenih map, sta se ta dokumenta mešala v vsako sejo.
   **Umaknjena sta v `..\_arhiv\stara-pravila\`.**
2. **Stara tvoja navodila** so kazala na `C:\ai\repo`, `C:\ai\naloge`,
   `C:\ai\logs`. **Mapa `C:\ai` sploh ne obstaja.** Nadomestil jih je
   `docs\HERMES.md`.
3. **Ta repozitorij** je imel ostanek Node predloge — `package.json`, `src\index.js`,
   `tests\index.test.js`. `npm test` je poganjal en izmišljen test (`2+3=5`) in
   vedno uspel. Agenti so to navajali kot dokaz, da .NET sistem deluje.
   **Lažno zeleno. Scaffold je umaknjen v `..\_arhiv\node-scaffold\`.**

## Kaj velja zdaj

- **`AGENTS.md` v korenu repozitorija je edini pravilnik.** Vse drugo je
  podrejeno. Če kje najdeš navodilo, ki mu nasprotuje, je zastarelo — ne
  upoštevaj ga in javi, kje si ga našel.
- **`docs\HERMES.md` so tvoja navodila** kot koordinatorja.
- Delovna mapa je **`C:\Users\David\Namizje\PIM\NoviPIM`**. Edina.
- Sistem je **.NET 9 + Blazor + MS SQL**. Ni Node, ni React.
- Edini dokaz, da nekaj dela:
  ```powershell
  dotnet build PIM_Solution\PIM.sln
  dotnet test PIM_Solution\PIM.sln --no-restore
  ```
  Izhodna koda 0. `npm test` ne obstaja več in ni dokaz ničesar.
- Če build pade z `MSB3027 ... file is locked` — to ni napaka v kodi, teče
  intranet. Ustavi proces `PIM.Intranet` in ponovi.

## Koliko svobode imaš

**Delaj sam do konca. Ne sprašuj za dovoljenje.**

Brez vprašanja smeš: brati karkoli v repozitoriju, pisati kodo, teste, SQL
migracije in dokumentacijo, poganjati build in teste, poganjati migrator proti
razvojni bazi `PIM`, ustvarjati veje, commitati, nameščati NuGet pakete.

**Vprašaj samo pri tem (zaprt seznam):**

1. brisanje česarkoli — datotek, map, tabel, stolpcev, podatkov, vej
2. prepis dela, ki ni tvoje — `git reset --hard`, `git checkout --`, `git clean`
3. karkoli izven `C:\Users\David\Namizje\PIM\NoviPIM`
4. produkcija ali prava baza
5. živi SAOP klic, prava e-pošta, webhook, deploy, `git push`
6. merge v `master`
7. sistemske nastavitve

Če se vprašaš »ali smem?« in ni na tem seznamu, je odgovor **da**.

## Kar ostaja nespremenjeno

- Ne commitaj v `master`; delaj na `feature/<faza>-<id>-<opis>`.
- Nikoli ne spremeni testa zato, da bi šel skozi.
- Migracije so samo dodajanje; obstoječih ne urejaj.
- Največ 2 vzporedni niti, največ 3 iteracije na nalogo.
- Česar ne moreš dokazati z izhodom ukaza, ne trdiš.
- Ne olepšuj poročil.
