# 03 — Publish (priprava objave)

Publish naredi iz izvorne kode mapo, ki jo samo prekopiraš na strežnik. Na strežniku **ni treba**
imeti .NET SDK-ja ne izvorne kode — objava je *self-contained* (nosi svoj .NET runtime).

## Kaj nastane

```
C:\PIM_publish\PIM_app\
  PIM.Intranet.exe, *.dll, wwwroot\ ...     intranet (IIS)
  Workerji\
    PIM.AutomationHost\PIM.AutomationHost.exe   gostitelj avtomatike (05)
    PIM.SaopStockWorker\...                      workerji, ki jih gostitelj poganja
    ...
  scripts\*.ps1, *.vbs                      pomožne skripte (nadzor, opravila)
```

`appsettings.Local.json` namenoma **ni** v objavi — na strežniku ostane tisti, ki je že tam.

## Ukaz (na razvojnem računalniku)

Zapri Visual Studio ali ustavi razhroščevanje (drži datoteke v `bin\` zaklenjene), nato:

```powershell
cd C:\Users\david\Desktop\PIM\NoviPIM

# predogled - nič ne naredi
powershell -ExecutionPolicy Bypass -File .\PIM_Solution\deploy\Publish-All.ps1 -Destination C:\PIM_publish\PIM_app -DryRun

# dejanska objava
powershell -ExecutionPolicy Bypass -File .\PIM_Solution\deploy\Publish-All.ps1 -Destination C:\PIM_publish\PIM_app
```

Traja nekaj minut. Na koncu izpiše število workerjev in skript ter kratka navodila za strežnik.

**Pred publishem v prazno mapo** pobriši staro vsebino `C:\PIM_publish\PIM_app` — tako v objavi ni
ostankov prejšnje različice.

### Različice

| Potreba | Ukaz |
|---|---|
| samo popravek intraneta (hitreje, workerji ostanejo) | dodaj `-BrezWorkerjev` |
| ekvivalent brez skripte | `dotnet publish PIM_Solution\src\PIM.Intranet\PIM.Intranet.csproj -c Release -r win-x64 --self-contained true -o C:\PIM_publish\PIM_app` |
| paket z migratorjem (strežnik brez sqlcmd) | `pwsh -File .\PIM_Solution\deploy\New-PortableRelease.ps1 -OutputDirectory D:\PIM-Release\PIM-LLLL-MM-DD` |

## Preden prenašaš

- [ ] Koda je commitana in poslana na GitHub (01) — da veš, katera različica je na strežniku.
- [ ] Vse nove migracije so uveljavljene lokalno in aplikacija lokalno dela (02).
- [ ] V `C:\PIM_publish\PIM_app` ni `appsettings.Local.json` (skripta ga pobriše sama).
- [ ] Obstaja `Workerji\PIM.AutomationHost\PIM.AutomationHost.exe`.

Nadaljuj z [04_Prenos_na_streznik.md](04_Prenos_na_streznik.md).
