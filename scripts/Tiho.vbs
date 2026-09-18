' Tiho.vbs - pozene ukaz brez konzolnega okna in vrne njegovo izhodno kodo.
'
' Zakaj obstaja. Nacrtovano opravilo z LogonType InteractiveToken pozene proces v tvoji
' namizni seji. Konzolo mu Windows alocira, preden PowerShell prebere -WindowStyle Hidden,
' zato okno ob vsakem zagonu utripne in pobere fokus sredi tipkanja. Pri Store aliasu
' pwsh.exe (dvobajtni skrbnik v WindowsApps) je se slabse: gre skozi AppX aktivacijo, ki si
' konzolo vzame vedno in za -WindowStyle Hidden ne ve.
'
' wscript.exe je program graficne podsistemske vrste in konzole nima. Otroka pozene s skritim
' oknom ze ob nastanku (drugi argument Run = 0), zato okna ni niti za trenutek. Tretji
' argument True pomeni, da pocakamo: razporejevalnik tako vidi pravo trajanje naloge,
' MultipleInstances IgnoreNew se drzi, izhodna koda pa ostane merilo (WScript.Quit spodaj).
'
' Uporaba:  wscript //B //Nologo Tiho.vbs <program> [argument ...]

Option Explicit

Dim lupina, datoteke, ukaz, i, izvajalec, izhod

If WScript.Arguments.Count < 1 Then
  WScript.Quit 87                       ' ERROR_INVALID_PARAMETER
End If

Set datoteke = CreateObject("Scripting.FileSystemObject")
izvajalec = WScript.Arguments(0)

' Store posodobitev PowerShella zamenja mapo, ker ima verzijo v imenu, in shranjena pot odpade.
' Takrat je bolje pasti nazaj na pwsh.exe iz PATH kot pustiti nalogo, da neha teci.
If Not datoteke.FileExists(izvajalec) Then izvajalec = "pwsh.exe"

ukaz = Navednice(izvajalec)
For i = 1 To WScript.Arguments.Count - 1
  ukaz = ukaz & " " & Navednice(WScript.Arguments(i))
Next

Set lupina = CreateObject("WScript.Shell")
izhod = lupina.Run(ukaz, 0, True)
WScript.Quit izhod

' WScript.Arguments navednice odstrani, zato jih pred sestavljanjem ukazne vrstice vrnemo
' nazaj - sicer bi se pot s presledkom razlomila na dva argumenta.
Function Navednice(vrednost)
  If Len(vrednost) = 0 Then
    Navednice = """"""
  ElseIf InStr(vrednost, " ") > 0 Then
    Navednice = """" & vrednost & """"
  Else
    Navednice = vrednost
  End If
End Function
