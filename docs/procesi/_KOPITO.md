---
id: ime-procesa
naslov: Ime procesa
podrocje: 03-izdelki
stanje: deluje            # deluje | delno | ne-deluje
bere: [pim.izdelek, saop.cene]          # oznake iz _PODATKI.md
pise: [pim.odprodaja, pim.saop-vrsta]   # oznake iz _PODATKI.md
strani: [/izdelki/odprodaja]
posli: []                 # ključi poslov v urniku, npr. MAGENTO_CSV
koda: [PIM_Solution/src/PIM.Intranet/Components/Pages/Clearance*.razor, PIM_Solution/src/PIM.Intranet/Services/Clearance*.cs]
migracije: [275]
---

# [Ime procesa]

> **Področje:** [mapa, npr. Poslovanje] · **Lastnik:** [vloga ali oseba] · **Stanje:** ✅ deluje / ⚠️ delno / ❌ ne deluje · **Preverjeno:** [LLLL-MM-DD, iz kode / z uporabnikom]

<!--
KOPITO ZA VSE PROCESE PIM
- Vsak proces je ena datoteka v mapi svojega področja (docs/procesi/NN-podrocje/ime-procesa.md).
- Glava med --- je STROJNO BRANA: iz nje se sestavi glavni graf (00-GLAVNI-PROCES.md) in opozorila o vplivu sprememb.
  Vsak ključ v eni vrstici, seznami v [ ] ločeni z vejico. bere/pise samo z oznakami iz _PODATKI.md.
  koda: poti od korena repozitorija, dovoljen * ; to so datoteke, katerih sprememba pomeni spremembo tega procesa.
- Razdelkov ne izpuščaj in ne preimenuj. Če razdelek nima vsebine, napiši »Ni.«
- Piši za uporabnika (komerciala, urednik kataloga), ne za programerja. Tehnika gre samo v razdelek 9.
- Strani intraneta piši kot pot v poševnih narekovajih: `/izdelki/odprodaja`.
- Kar v kodi ni tako, kot bi uporabnik pričakoval, ali česar ni mogoče preveriti, označi z ⚠️ in zapiši v razdelek 10.
-->

## 1. Namen

En do dva stavka: čemu proces služi in kaj je rezultat.

## 2. Kdo sodeluje

| Vloga | Kaj naredi v procesu |
|---|---|
| Komerciala | … |
| Urednik kataloga | … |
| Skrbnik | … |
| Avtomatika (PIM) | … |

## 3. Kdaj se sproži

- **Ročno:** kdo in ob kakšni priložnosti.
- **Po urniku:** ime posla in pogostost (npr. `SUPPLIER_CATALOG_IMPORT`, vsakih 6 ur).
- **Ob dogodku:** kaj ga sproži.

## 4. Vhod in izhod

| | Kaj | Od kod / kam |
|---|---|---|
| **Vhod** | … | SAOP / dobavitelj / Excel / uporabnik |
| **Izhod** | … | PIM / SAOP / katalog.csv / Magento |

## 5. Diagram

Vedno pasovni diagram z istimi štirimi pasovi (pas, ki ga proces ne uporablja, izpusti).
Oblike: `([ ])` začetek/konec · `[ ]` korak uporabnika · `[[ ]]` samodejni korak · `{ }` odločitev · `[( )]` podatki · `>` čaka potrditev.
Barve so vedno enake (classDef spodaj kopiraj nespremenjene).

```mermaid
flowchart LR
  subgraph U["👤 Uporabnik"]
    A([Začetek]) --> B[Korak uporabnika]
  end
  subgraph P["🗂️ PIM"]
    C[[Samodejni korak]] --> D{Odločitev?}
    D -- da --> E>Čaka potrditev]
    D -- ne --> F([Konec])
  end
  subgraph S["🏢 SAOP"]
    G[(ERP podatek)]
  end
  subgraph W["🌐 Splet"]
    H[(katalog.csv)]
  end
  B --> C
  E --> G
  E --> H

  classDef user fill:#e8f1ff,stroke:#2f6fd6,color:#0b2a5b;
  classDef auto fill:#eef7ee,stroke:#3a8a3a,color:#123812;
  classDef wait fill:#fff4e0,stroke:#d08a00,color:#4a3000;
  classDef data fill:#f3f0fa,stroke:#6b54b0,color:#2a1f4d;
  classDef endp fill:#f2f2f2,stroke:#777,color:#222;
  class A,F endp; class B user; class C,D auto; class E wait; class G,H data;
```

## 6. Koraki

| # | Kdo | Kje (stran) | Kaj narediš | Kaj se zgodi v sistemu | Kako preveriš, da je uspelo |
|---|---|---|---|---|---|
| 1 | Komerciala | `/…` | … | … | … |
| 2 | Avtomatika | — | — | … | … |

## 7. Pravila in varovalke

- Kaj sistem ne dovoli ali zadrži in zakaj (npr. »v SAOP nič samodejno — vedno po odobritvi«).
- Kdo lahko kaj (vloge in dovoljenja).

## 8. Ko gre kaj narobe

| Znak (kaj vidiš) | Verjeten vzrok | Kaj narediš |
|---|---|---|
| … | … | … |

## 9. Tehnično ozadje

<details>
<summary>Za skrbnika in razvoj</summary>

- **Strani:** `PIM.Intranet/Components/Pages/….razor`
- **Storitve / delavci:** …
- **Tabele in pogledi:** `schema.Tabela`
- **Migracije:** `NNN_Ime.sql`
- **Urniki:** ime posla, pogostost

</details>

## 10. Odprta vprašanja in razlike

- ⚠️ Kar v kodi ni jasno, ni dokončano ali se verjetno razlikuje od dejanskega dela.

## Povezani procesi

- [Ime](../NN-podrocje/proces.md): kako sta povezana.
