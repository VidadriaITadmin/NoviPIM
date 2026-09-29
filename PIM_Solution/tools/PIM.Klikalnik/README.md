# Klikalnik

Samodejni pregled vseh strani intraneta v pravem brskalniku. Uporablja se na razvojnem računalniku,
preden rečemo, da je stran »končana«.

1. Zaženi intranet s testnim skrbnikom (brez prijave, samo razvojna baza `DAVID\MSSQL19`):

       dotnet build -c Release
       dotnet bin/Release/net10.0/PIM.Klikalnik.dll

   Posluša na `http://localhost:5000/` (drugače: `KLIKALNIK_PORT=5071`, da teče več hkrati). Program se
   ustavi, če povezava ne kaže na razvojni strežnik (`KLIKALNIK_STREZNIK`, privzeto `DAVID\MSSQL19`).
   Poročilo gre v `porocilo/` ali v mapo `KLIKALNIK_IZHOD` (tako ga vrata naloge shranijo k preverjanju).

2. V drugem oknu zaženi pregled (vse strani ali samo tiste, ki vsebujejo niz):

       node klikalnik.mjs http://localhost:5000/
       node klikalnik.mjs http://localhost:5000/ izdelki

   V Git Bashu piši pot brez začetne poševnice (`izdelki`, ne `/izdelki`).

Rezultat: `porocilo/klikalnik.md` (seznam najdb po resnosti in časi nalaganja), `porocilo/klikalnik.json`
in posnetki zaslona v `porocilo/posnetki/`.

Kaj preveri: ali stran postane interaktivna in se umiri, napake na strani in v konzoli, ali spustni
seznami in iskalna polja spremenijo rezultat, razvrščanje po stolpcih, odziv varnih gumbov, klik na
vrstico, mrtve in absolutne povezave, `<caption>` na tabelah.

Česa ne naredi: nikoli ne klikne gumbov, ki pišejo ali pošiljajo (Shrani, Izbriši, Pošlji, Zaženi,
Uvozi, Potrdi, Odobri ...), in ne spreminja polj v urejevalnih obrazcih. Shranjevanje in pravice po
vlogah je zato treba preveriti posebej.
