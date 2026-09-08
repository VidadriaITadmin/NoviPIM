# Delovni list izdelkov — en izvoz, en uvoz

Zahteva uporabnika 2026-09-08: *»naredi enoten izvoz in pa uvoz, da bo lahko uporabnik pisal
podatke in jih uvozil notri, ko jih spremeni in dopolni«* ter stolpec, ki pove, na katero
spletno stran gre artikel, z vrednostmi, ločenimi z `|`.

## Kaj je bilo prej narobe

Stran `/izdelki` je ponujala dva izvoza in noben uvoz.

| Datoteka | Vsebina | Se da vrniti? |
|---|---|---|
| `predloga=pregled` | ERP, komerciala, splet | **ne** — naslovi kot »Naziv ERP (sl)« se pri uvozu ne ujamejo z nobeno kodo |
| `predloga=saop` | samo ERP polja iz registra | da, a le na `/saop/artikli` in samo za ERP |

Spletnih nazivov, opisov, kategorij, atributov in podatka o spletni strani ni bilo mogoče
uvoziti nikjer. Kdor je hotel dopolniti splet za tisoč izdelkov, je moral odpreti tisoč kartic.

## Kaj je zdaj

Ena datoteka: `/izvoz/izdelki.xlsx?predloga=delovni`, gumb **Delovni list** na `/izdelki`.
Vrne se na `/izdelki/uvoz`.

Stolpce obeh smeri določa **en sam seznam** — `PIM.Operations.ProductWorkbookContract`. Zato
stolpec ne more zdrsniti samo na eni strani: kar izvoz izpiše, uvoz prebere.

### Skupine stolpcev

| Skupina | Kaj je v njej | Kam gre pri uvozu |
|---|---|---|
| Ključ | Podjetje, Šifra artikla, Naziv | nikamor; brez prvih dveh uvoz vrstice ne najde |
| ERP — gre v vrsto za SAOP | vsa polja z `IsWritable` iz registra `out.SaopXmlField` (tudi »Objava na spletu«) | `out.EnqueueSaopItemChanges` → skupina čaka odobritev |
| Splet — zapiše se takoj | Spletne strani, Kategorije po straneh, spletni nazivi in opisi po jezikih | `pim.SetProductCategories`, `pim.SaveProductTexts` |
| Spletni atributi | vrednosti atributov iz `canon.ProductAttribute` in tisti, ki jih zahteva validacija | `pim.SaveProductAttributes` |
| Stanje — samo za branje | ERP, Splet, Popolnost, Odprte težave, Zadnja sprememba | nikamor |

Naslov stolpca ni edini sprejeti zapis. Uvoz prepozna tudi kanonično kodo (`ProductText.WEB_TITLE.sl`)
in ime elementa SAOP (`ItemNetWeight`), zato si sme uporabnik narediti tudi svojo datoteko.

## Tri pravila, ki veljajo povsod v listu

1. **Prazna celica pomeni »tega polja se ne dotakni«**, ne »izprazni ga«. List ima stotine
   stolpcev in večina celic je praznih; drugačno pravilo bi ob prvem uvozu izpraznilo katalog.
2. **Seznam v celici je ločen z `|`.** Velja za spletne strani, kategorije in slike.
3. **Uvozi se samo tisto, kar se razlikuje od zapisanega.** Nespremenjena datoteka ne naredi
   ničesar. Brez tega bi vsak uvoz uvrstil v odhodno vrsto desettisoče sporočil, ki ne
   spremenijo nič, in predogled ne bi povedal, kaj je uporabnik pravzaprav popravil.

## Stolpec »Spletne strani«

Vrednosti so imena iz registra `canon.WebSite`, ločena z `|`, na primer:

```
Svetila.si | Videlektro
```

Sprejeti sta ime in koda (`svetila_si`, `B2C`). Register ima danes štiri strani: Svetila.si,
Svetila.si (ANG), Videlektro, Videlektro (ANG).

Stolpec ni nova zastavica. Ostaja pravilo migracije 146: **izdelek je na strani natanko takrat,
kadar ima na njej kategorijo.** Stolpec je zato ukaz nad kategorijami:

- stran, ki je v celici **ni**, izgubi kategorije (`pim.SetProductCategories` s praznim seznamom);
- stran, ki je v celici **je**, mora kategorijo imeti — iz svojega stolpca »Kategorije — …« ali
  že od prej. Če je nima, uvoz to pove kot napako vrstice in strani ne doda.

Vzporedna tabela »na kateri strani je artikel« bi bila drugi vir resnice za isto vprašanje in
prvi dan, ko bi se razšla s kategorijami, bi se artikel na spletu pojavil ali izginil brez sledi.

## Objava na spletu

Register `out.SaopXmlField` pozna `Product.WebPublish` kot element `WebPublish`, torej podatek
potuje v SAOP. Zato je stolpec »Objava na spletu« med ERP polji in gre skozi odhodno vrsto, ne
neposredno v katalog — enako kot enota mere ali skupina artikla. V `canon.Product` se vrednost
pojavi ob naslednjem zajemu iz SAOP.

Migracija 171 je ustvarila tudi proceduro `pim.SetProductWebPublish` za neposredni zapis. Ko se
je pokazalo, da je polje last odhodne vrste, je ostala neuporabljena. Ni odstranjena, ker je
brisanje po `AGENTS.md` §4.1 odločitev človeka; je pa zapisano tu, da ni videti kot pozabljena.

## Meje

| Kaj | Meja | Kje je zapisana |
|---|---|---|
| Vrstic v izvozu | 20.000 | `ProductWorkbookService.MaxRows`; večji nabor je zapisan v opombo v datoteki |
| Stolpcev atributov | 200 | `ProductWorkbookService.MaxAttributeColumns`; najprej zahtevani |
| Velikost naložene datoteke | 16 MB | `ProductImport.razor` |
| Vrstic pri branju zvezka | 50.000 | `WorkbookTable.MaxRows` |

## Kaj se je pri tem moralo popraviti drugje

- **`WorkbookTable.Read` zdaj sprejme namige za naslovno vrstico.** List s skupinami stolpcev
  ima dve naslovni vrstici; brez namiga bi bralnik vzel prvo (imena skupin) in uvoz bi videl
  stolpce, ki jih ni.
- **`WorkbookWriter` ohrani prelome vrstic.** Doslej je `\n` postal presledek in večvrstičen
  opis se je iz zvezka vrnil sploščen — pri listu, ki gre ven in se vrne, je to izguba podatka.
- **`WorkbookHeader`** je zdaj edino mesto s pravilom, kdaj sta dva naslova isti stolpec.
- **`.warn-message`** je pristal v `app.css`. Prej je bil definiran samo v `SaopItems.razor.css`;
  ker je Blazor CSS obsegov, je bil na drugih straneh razred brez učinka.
- **`ExportHref` na `/izdelki` je iz `bool` prešel na kodo predloge**, ker predloge niso več dve,
  ampak tri. `PIM.F10.ProductsUxTests` je natanko ta podpis pripenjal z vzorcem
  `string ExportHref\(bool saopTemplate\)`; vzorec je sproščen na poljuben seznam parametrov,
  trditev, ki jo varuje — naslov izvoza mora nastati iz `Href(page: 1)`, torej iz istih filtrov
  kot seznam — pa ostaja enaka in enako stroga. To je edina sprememba obstoječega testa.

## Dokaz

```
scripts\run_tests.ps1 -Filter ProductWorkbook
```

Test `tests/PIM.F10.ProductWorkbookTests` preveri, da se vse izvožene glave prepoznajo nazaj, da
nespremenjena datoteka ne prinese nobene spremembe in da ena spremenjena celica da natanko eno
spremembo. Prvi del testa je čista logika in teče brez baze.
