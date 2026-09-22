# Navodila PIM — kazalo

Praktična navodila za vsakdanje delo s PIM: od spremembe kode do delujoče aplikacije na strežniku.
Vsaka datoteka je samostojna; če nisi prepričan, začni pri **Hitrem vrstnem redu** spodaj.

| Datoteka | Kdaj jo odpreš |
|---|---|
| [01_GitHub.md](01_GitHub.md) | Shraniti spremembe in jih poslati na GitHub; prenesti kodo na drug računalnik |
| [02_Migracije.md](02_Migracije.md) | Posodobiti bazo (nove `.sql` migracije) lokalno ali na strežniku |
| [03_Publish.md](03_Publish.md) | Pripraviti objavljeno aplikacijo (intranet + workerji + skripte) v eno mapo |
| [04_Prenos_na_streznik.md](04_Prenos_na_streznik.md) | Prenesti objavo na IIS strežnik, prvič in vsakič naslednjič |
| [05_AutomationHost.md](05_AutomationHost.md) | Gostitelj avtomatike: konzola lokalno, Windows storitev na strežniku |
| [06_Bliznice_in_ukazi.md](06_Bliznice_in_ukazi.md) | Kratki ukazi, SQL poizvedbe, naslovi strani, Windows bližnjice |
| [07_Tezave.md](07_Tezave.md) | Ko kaj ne dela — znane napake in rešitve |

## Hitri vrstni red ob novi različici

```
Razvojni računalnik                              Strežnik
───────────────────                              ────────
1. commit + push na GitHub      (01)
2. migracije lokalno            (02)
3. publish v eno mapo           (03)   ──────►   4. backup baze             (04)
                                                 5. migracije               (02)
                                                 6. ustavi AutomationHost   (05)
                                                 7. prekopiraj objavo       (04)
                                                 8. zaženi AutomationHost   (05)
                                                 9. preveri /health, /sistem
```

**Pravilo:** baza vedno **pred** aplikacijo. Nova koda na stari bazi pade (manjkajoči stolpci in
procedure), stara koda na novi bazi praviloma dela.

## Stalna pravila

- `appsettings.Local.json` (povezava do baze, SAOP geslo) **nikoli** ne gre na GitHub ali v objavo.
  Na vsakem računalniku/strežniku ostane svoj.
- Nikoli ne ciljaj baze `PIM_test` z migracijami za `PIM` in obratno — vedno preveri `Database=` v povezavi.
- Na isti bazi sme teči **samo en** AutomationHost (lokalna konzola ALI storitev na strežniku).
- Pred migracijami na strežniku vedno backup.

## Naprej (obstoječa podrobnejša dokumentacija)

- `docs/PUBLISH.md` — publish intraneta, podrobno
- `PIM_Solution/deploy/PORTABLE_RELEASE.md` — prenosljiv paket (intranet + migrator v eni mapi)
- `PIM_Solution/deploy/README-Windows.md` — IIS, računi, pravice
- `PIM_Solution/sql/migrations/Invoke-PendingMigrations.ps1` — glava datoteke opisuje vse možnosti
