# Procesi PIM

**Odpri `PIM-procesi.html`** (dvoklik; Edge ali Chrome). V njem so celoten tok PIM, vsa področja in vsi procesi s koraki, diagrami, odvisnostmi in vplivom sprememb. Za diagrame je potreben internet.

## Kaj je v mapi

| Datoteka | Kaj je |
|---|---|
| `PIM-procesi.html` | Pregledovalnik z vgrajenimi podatki. Ročno ga ne urejaj, sestavi se sam. |
| `01-nadzor/` … `09-administracija/` | Posamezni procesi (en proces = ena datoteka `.md`). To je vir vsega. |
| `_KOPITO.md` | Predloga za nov proces. |
| `_PODATKI.md` | Slovar podatkov, prek katerih so procesi povezani (`bere` / `pise`). |
| `_pregledovalnik.html` | Predloga pregledovalnika (videz in delovanje). |
| `Osveži pregled.cmd` | Ponovno sestavi `PIM-procesi.html` iz procesov in ga odpre. |

## Kako se uporablja

- **Branje:** odpri `PIM-procesi.html`. Klikni področje, proces ali podatek. Hitro iskanje odpreš s `Ctrl+K`.
- **Urejanje v živo:** v pregledovalniku klikni **📂 Poveži z mapo** in izberi to mapo. Nato:
  - vsak proces ima gumb **✎ Uredi**, področje pa gumb **＋ Nov proces**;
  - pred shranjevanjem se pokaže **vpliv spremembe**: kaj bi PODRLO (nekdo bere podatek, ki ga nihče več ne piše), kaj zahteva POZOR in kaj OBOGATI;
  - spremembe drugih uporabnikov se prikažejo same v nekaj sekundah.
- **Deljenje:** mapo `docs\procesi` postavi na skupni disk ali v OneDrive/SharePoint. Vsak odpre isti `PIM-procesi.html` in se poveže z mapo. Če isti proces hkrati shranita dva, obvelja zadnji shranjeni.

## Kako so procesi povezani

Vsak proces ima na vrhu strojno glavo: kaj **bere**, kaj **piše**, katere strani, posle in kodo uporablja. Proces A vpliva na proces B, kadar B bere podatek, ki ga A piše. Iz teh povezav nastanejo glavni graf, odvisnosti in opozorila.

## Za razvoj (v repozitoriju)

```bash
powershell -ExecutionPolicy Bypass -File scripts/Procesi.ps1 -Ukaz Graf
```

```bash
powershell -ExecutionPolicy Bypass -File scripts/Procesi.ps1 -Ukaz Vpliv -Od origin/main
```

```bash
powershell -ExecutionPolicy Bypass -File scripts/Procesi.ps1 -Ukaz Preveri
```

- **`Graf`** sestavi `PIM-procesi.html`.
- **`Vpliv`** iz git sprememb kode pove, katere procese sprememba zadane in na katere vpliva naprej. Spremenjeno kodo, ki je ne opisuje noben proces, označi kot NEPOKRITO.
- **`Preveri`** najde strani intraneta brez procesa, zastarele poti kode in neznane oznake podatkov.

**Pravilo:** vsaka sprememba kode ali migracija, ki spremeni proces, v istem commitu popravi tudi opis procesa (glavo, korake, diagram, datum »Preverjeno«). Nato zaženi `-Ukaz Graf`.
