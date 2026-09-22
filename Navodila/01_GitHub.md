# 01 — Koda na GitHub in nazaj

Repozitorij: **https://github.com/VidadriaITadmin/NoviPIM** · glavna veja: `main`.
Koren repozitorija je mapa `NoviPIM` (v njej je `PIM_Solution`).

Vse ukaze poganjaš v PowerShellu v mapi repozitorija:

```powershell
cd C:\Users\david\Desktop\PIM\NoviPIM
```

## 1. Poglej, kaj je spremenjeno

```powershell
git status
git diff --stat
```

Preveri, da na seznamu **ni** `appsettings.Local.json`, `*.bak`, izvozov (`izvoz\`) ali dnevnikov
(`logs\`). Te izloča `.gitignore`; če se kljub temu pojavijo, jih ne dodajaj.

## 2. Nova veja (priporočeno za večje spremembe)

```powershell
git switch main
git pull
git switch -c feature/kratek-opis
```

Že obstoječa veja: `git switch ime-veje`. Na kateri veji si: `git branch --show-current`.

## 3. Shrani (commit)

```powershell
git add -A
git commit -m "Kratek opis, kaj in zakaj"
```

Samo izbrane datoteke: `git add pot\do\datoteke` namesto `git add -A`.
Pomota v zadnjem sporočilu (še ni poslano): `git commit --amend -m "novo sporočilo"`.

## 4. Pošlji na GitHub (push)

```powershell
git push -u origin feature/kratek-opis
```

`-u` samo prvič za novo vejo; kasneje zadošča `git push`.

## 5. Združi v `main`

**Prek spletne strani (priporočeno):** GitHub pokaže rumeni pas *Compare & pull request* →
*Create pull request* → preglej spremembe → *Merge pull request*.

**Ali iz ukazne vrstice** (če je nameščen `gh`):

```powershell
gh pr create --base main --fill
gh pr merge --merge
```

**Ali neposredno, brez pull requesta:**

```powershell
git switch main
git pull
git merge feature/kratek-opis
git push
```

## 6. Kodo na drug računalnik / strežnik

### Prvič — kloniraj (priporočeno)

```powershell
cd C:\PIM
git clone https://github.com/VidadriaITadmin/NoviPIM.git
```

### Vsakič naslednjič

```powershell
cd C:\PIM\NoviPIM
git switch main
git pull
git log -1 --format="%h %s"     # preveri, da je zadnji commit pravi
```

### Če prenašaš ZIP z GitHuba (Code → Download ZIP)

- ZIP **razpakiraj v NOVO, prazno mapo**. Razpakiranje čez staro mapo pusti datoteke, ki so bile v
  repozitoriju izbrisane — build nato pade (npr. `CS0104` zaradi dveh enakih razredov).
- Windows označi razpakirane datoteke kot »z interneta« in PowerShell zavrne `.ps1` skripte
  (`is not digitally signed`). Enkrat odblokiraj:
  ```powershell
  Get-ChildItem C:\pot\do\NoviPIM -Recurse -File | Unblock-File
  ```
- `appsettings.Local.json` ni v ZIP-u — prekopiraj ga iz stare mape.

## 7. Uporabno

| Kaj | Ukaz |
|---|---|
| zgodovina na kratko | `git log --oneline -15` |
| kaj se je spremenilo v datoteki | `git log --oneline -- pot\datoteka` |
| zavrzi nepotrjeno spremembo ENE datoteke | `git restore pot\datoteka` |
| začasno pospravi spremembe | `git stash` · nazaj: `git stash pop` |
| katere veje obstajajo | `git branch -a` |
| razlika med vejo in main | `git diff main...HEAD --stat` |

`git reset --hard` in `git push --force` brišeta delo — uporabi jih samo, če točno veš, kaj izgubiš.
