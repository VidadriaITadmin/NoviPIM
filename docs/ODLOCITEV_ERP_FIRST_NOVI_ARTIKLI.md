# Odločitev: ERP-first za nove artikle

Ta dokument nadomešča PIM-first predlog v `TOK_NOVIH_ARTIKLOV.md`.

## Eno pravilo

**Pravi artikel se ustvari samo v SAOP.** PIM pred tem nima artikla, ampak vodi predlog novega artikla. Zato v katalogu PIM ni začasnih artiklov, dvojnih šifer ali nejasnosti, ali artikel v ERP obstaja.

## Tok 1 — Artikel, ustvarjen v SAOP/DEMU

1. Uporabnik ustvari artikel neposredno v SAOP/DEMU.
2. Posel `SAOP_PRODUCT_IMPORT` ga ob naslednjem ali ročno zahtevanem zajemu samodejno ustvari v PIM-u.
3. PIM nato ureja spletne podatke, atribute, slike, dokumente in dovoljena ERP polja.

To je edina samodejna pot nastanka PIM artikla. Koda jo že podpira prek SAOP konektorja, ki sme ustvarjati artikle; v DEMU jo preverimo z E2E testom.

## Tok 2 — Nov artikel v dobaviteljevem XML-ju

1. XML ne ustvari `canon.Product`. Ustvari zapis na strani **Novi artikli** s posnetkom vseh XML podatkov.
2. Uporabnik pregleda naziv, EAN, dobaviteljevo šifro, slike, dokumente, atribute in primerja možna ujemanja.
3. Če manjkajo obvezni ERP podatki, jih uporabnik dopolni na predlogu — še vedno ne v PIM katalogu.
4. Gumb **Odpri v SAOP** sestavi in odobri POST za nov artikel v SAOP. To je ena nadzorovana pot; uporabnik ne ustvarja istega artikla še ročno v SAOP.
5. Po uspešnem odgovoru SAOP kandidat dobi uradno šifro in stanje »ustvarjen v ERP, čaka zajem PIM«.
6. `SAOP_PRODUCT_IMPORT` prebere uradni artikel in ga ustvari v PIM-u. Nato se na ta artikel pripnejo dovoljeni podatki iz istega XML kandidata.

## Tok 3 — Ročni nov artikel

Ročni obrazec **Nov predlog** ustvari isti predlog kot XML, z virom `ROČNI`. Minimalni podatki so podjetje, naziv ter EAN ali začasna interna oznaka. Nadaljuje se povsem enako kot tok 2: predlog → SAOP → zajem SAOP → PIM. Ni gumba »Ustvari artikel v PIM«.

## Kar ostane samo urejanje

| Pot | Sme ustvariti artikel? | Vloga |
| --- | --- | --- |
| Delovni list izdelkov | Ne | Uredi obstoječ PIM artikel; neznano šifro zavrne. |
| Kartica / množično urejanje | Ne | Uredi obstoječ PIM artikel. |
| XML dobavitelja | Ne | Pripravi ali osveži predlog. |
| Zaloga, cene, odprodaja | Ne | Ujemanje in dopolnjevanje obstoječih artiklov. |
| Magento | Ne | Samo izvoz. |
| SAOP zajem | Da | Ustvari ali posodobi uradni artikel v PIM-u. |

## Stanja na strani Novi artikli

`PREJET_XML` / `ROČNI_PREDLOG` → `DOPOLNITI_ERP` → `PRIPRAVLJEN_ZA_SAOP` → `V_VRSTI_SAOP` → `USTVARJEN_V_ERP` → `V_PIM`.

Izjemi sta `ZAVRNJEN`, `NEJASNO_UJEMANJE` in `SAOP_NAPAKA`. Predlog ostane viden tudi po uspehu, z EAN-om, uradno SAOP šifro, `ProductId`, virom in celotno sledjo. Tako je vedno jasno, kateri novi artikli so le v XML-ju, kateri čakajo SAOP in kateri so že v PIM-u.

## Varovalke

- `CanCreateProducts=1` velja samo za SAOP konektorje; XML, Excel, zaloga in cene imajo vedno `0`.
- Ujemanje je po podjetju + dobaviteljevi šifri ali enoličnem EAN-u. Več zadetkov je `NEJASNO_UJEMANJE`, nikoli avtomatska izbira.
- Po kreiranju v SAOP se PIM artikel ustvari samo z normalnim SAOP zajemom; odgovor SAOP se ne sme neposredno pretvoriti v PIM artikel mimo zajema.
- XML vrednosti se po SAOP zajemu prenesejo samo za polja, katerih lastnik je dobavitelj; ne smejo povoziti SAOP ali PIM-lastniških polj.
