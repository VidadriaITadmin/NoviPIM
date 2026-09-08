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

Ena datoteka: `/izvoz/izdelki.xlsx?predloga=delovni`, gumb **Izvozi Excel** na `/izdelki`.
Vrne se z gumbom **Uvozi Excel** na `/izdelki/uvoz`.

Orodna vrstica na `/izdelki` ima od 2026-09-08 natanko ti dve dejanji. Uporabnik: »zakaj imava
petsto gumbov, naredi samo izvoz in uvoz in to je to, ostalo ne rabiva.« Šest gumbov v vrsti je
bilo šest vprašanj namesto enega odgovora.

Nobena pot ni izginila, le gumba nima več:

| Kaj | Kje je zdaj |
|---|---|
| Predloga SAOP | `/izvoz/izdelki.xlsx?predloga=saop` — ista pot izvoza, druga predloga |
| Izvoz »pregled« (enosmeren) | `/izvoz/izdelki.xlsx` brez parametra |
| Excel → čakalna lista SAOP | `/saop/artikli`, zavihek **Artikli** v razdelku SAOP |
| Množično urejanje izbranih | `/izvozi/mnozicno`, povezano s `/kakovost` in s strani uvoza |

Izbira v tabeli ostane: določa obseg izvoza (izbrani ali cel pogled). Ker delovni list nosi
stolpec Podjetje, izbire ni več treba omejevati na eno podjetje, kot je bilo treba pri
množičnem urejanju.

Stolpce obeh smeri določa **en sam seznam** — `PIM.Operations.ProductWorkbookContract`. Zato
stolpec ne more zdrsniti samo na eni strani: kar izvoz izpiše, uvoz prebere.

### Skupine stolpcev

| Skupina | Kaj je v njej | Kam gre pri uvozu |
|---|---|---|
| Ključ | Podjetje, Šifra artikla, Naziv | nikamor; brez prvih dveh uvoz vrstice ne najde |
| ERP — gre v vrsto za SAOP | vsa polja z `IsWritable` iz registra `out.SaopXmlField` (tudi »Objava na spletu«) | `out.EnqueueSaopItemChanges` → skupina čaka odobritev |
| Splet — zapiše se takoj | Spletne strani, Kategorije po straneh, spletni nazivi in opisi po jezikih | `pim.SetProductCategories`, `pim.SaveProductTexts` |
| Atributi kategorije — nabor | kar kategorija predpisuje (`canon.CategoryAttributeSet`, z dedovanjem po drevesu) | `pim.SaveProductAttributes` |
| Atributi izven nabora | kar izdelek nosi mimo nabora; na splet ne gre, a vrednost obstaja | `pim.SaveProductAttributes` |
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

## Izvoz po kategoriji

Filter **Kategorija** na `/izdelki` (od migracije 175) zoži dvoje hkrati:

1. **vrstice** — izdelki te kategorije in vseh njenih potomcev. Kdor izbere »Notranja svetila«,
   dobi tudi »Notranja svetila > Downlights > Vgradne svetilke«, ker se nabor atributov po
   drevesu deduje navzdol in se mora filter obnašati enako;
2. **stolpce atributov** — delovni list dobi nabor te kategorije, ne vseh 148 atributov kataloga.

V spustnem seznamu ob vsaki kategoriji stojita število izdelkov pod njo in velikost njenega
nabora, sicer bi bila izbira ugibanje.

Zakaj to sploh šteje. Do 175 je list dobil stolpce atributov iz dveh virov: kar izdelki že imajo
zapisano, in kar zahteva validacija. Nabor kategorije v tem ni sodeloval, zato **atributa, ki ga
kategorija predpisuje, izdelek pa ga še nima, v listu ni bilo** — ravno tistega, ki ga je treba
vpisati. List je pokazal, kar že obstaja, in zamolčal, kar manjka. Izmerjeno na kategoriji
»Zunanja svetila > Prenosna svetila« (26 izdelkov, 27 atributov v naboru): devet atributov nabora
je pri vseh izvoženih izdelkih praznih. Prej ti stolpci ne bi obstajali.

Ključ atributa se pri tem ne spremeni. V naboru je stabilna koda (`IP_STOPNJA_ZASCITE`), v
`canon.ProductAttribute` pa slovensko ime (`IP stopnja zaščite`). Preslikavo dela
`canon.AttributeTranslation` v jeziku `sl`, enako kot na kartici izdelka in v validaciji.

Nabor se nastavlja na `/nastavitve/nabori-atributov`. Dedovanje po prednikih je zapisano v
funkciji `canon.CategoryAttributeEffective` (migracija 147) in se v izvozu ne podvaja.

Meja stolpcev (200) velja **samo za atribute izven nabora**. Nabor kategorije gre v list cel.

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
| Stolpcev atributov izven nabora | 200 | `ProductWorkbookService.MaxAttributeColumns`; nabor kategorije ni omejen |
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
