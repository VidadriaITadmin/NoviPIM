# Ciljno stanje in preslikava referenc

| Referenca v `../PIM_test/UX_pictures` | Ciljna stran oziroma sklop | Implementacijska zahteva |
|---|---|---|
| `Nadzorna_plosca.png` | `/nadzorna-plosca` | Polna mreža kartic, opravil, kakovosti po profilih, procesov, opozoril, aktivnosti in hitrih dostopov iz podatkov baze. |
| `Izdelki.png` | `/izdelki` | Zavihki, iskanje, filtri, statusni čipi, tabela, paginacija; vsi podatki iz baze. |
| `Osebna_izkaznica_izdelka.png` | `/izdelki/{id}` | Glava izdelka, profili, popolnost, zavihki, obrazec in napake; samo polja, ki jih podpira baza oziroma nov read model. |
| `Mediji.png` | Mediji | Pred implementacijo se potrdi obstoječ podatkovni model za medije; brez modela ne ustvarjamo izmišljenih kartic. |
| `Stranke.png` | `/stranke` | Zavihki, filtri, KPI oznake, tabela in paginacija iz `GetCustomers`. |
| `partnerji.png` | Partnerji | Pred implementacijo se potrdi vir partnerjev/dobaviteljev. |
| `zaloga.png` | `/zaloge` | KPI kartice, filtri, tabela zalog in podatkovno podprta opozorila. |
| `cene_in_ceniki.png` | Cene in ceniki | Pred implementacijo se potrdi cenovni read model; trenutna B2B pravila niso enaka ceniku izdelkov. |
| `Kakovost.png` | `/napake-validacije` in `/karantena` | KPI, kakovost po profilih, najpogostejše napake, filter tabela in karantena iz baze. |
| `uvozi.png` | `/teki-obdelave` | Kartice virov in zgodovina uvozov iz procesnih tekov. |
| `uvozi_izvozi.png` | `/teki-obdelave` in `/outbound` | Uvozi/izvozi se prikažejo z resničnimi statusi, vrsticami in uporabniki, kadar jih baza vsebuje. |
| `nastavitve_kataloga.png` | Nastavitve kataloga | Pred implementacijo se potrdi model atributov, kategorij, preslikav, kanalov in prevodov. |

## Izrecne prepovedi

- Ne kopiramo števil, datumov, osebnih imen, katalogov, izdelkov ali odstotkov iz UX slik v C# ali Razor kodo.
- Ne prikazujemo kontrol, ki navidezno shranjujejo podatke, če ustrezna baza/procedura ne obstaja.
- Ne ustvarjamo nove UX reference brez potrditve uporabnika.
