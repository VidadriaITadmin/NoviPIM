# E-poštna opozorila prek Resend — stanje in navodila za nadaljevanje

_Zapisano 2026-09-14. Za kontekst glej tudi `deploy/README-Windows.md` in `workers/PIM.AlertDispatcher/`._

## Zakaj Resend, ne Office365 SMTP

`PIM.AlertDispatcher` je od nekdaj znal pošiljati e-pošto prek SMTP (`EmailAlertSender.cs`), a je bilo to
neuporabno, ker ima Microsoft 365 najemnik pri tem podjetju **onemogočen Authenticated SMTP** — ne za
posamezen predal (`david@vidadria.com`), ampak na ravni cele organizacije (samopostrežni preklopi v
Exchange admin centru in OWA nastavitvah so posiveli/onemogočeni). Popravek zahteva pravega Microsoft 365
Global/Exchange admina, ki bi to ročno odklenil (glej spodaj "Alternativa: vseeno Office365").

Resend (resend.com) je preprost REST API za pošiljanje transakcijske e-pošte — prijava z API ključem, brez
SMTP, brez tenant politik, ki bi to blokirale. Zato smo se odločili za to pot.

## Kaj je že narejeno v kodi

`workers/PIM.AlertDispatcher/EmailAlertSender.cs` zdaj podpira dva načina pošiljanja, izbrana z okoljsko
spremenljivko:

- `PIM_ALERT_EMAIL_PROVIDER=Smtp` (privzeto, nespremenjeno vedenje) — stari SMTP način.
- `PIM_ALERT_EMAIL_PROVIDER=Resend` — nov REST klic na `https://api.resend.com/emails`, prijava z
  `PIM_RESEND_API_KEY`. Isti vzorec kot obstoječi `WebhookAlertSender.cs` (gol `HttpClient`, brez novega
  NuGet paketa).

**Preverjeno**: surov testni klic na Resend API (z resničnim API ključem, `from=onboarding@resend.dev`,
`to=jaka.steblaj@gmail.com`) je uspel in e-pošta je prispela. To dokazuje, da ključ in klic delujeta;
koda v `EmailAlertSender.cs` je zvest prepis istega klica.

## Kje smo obtičali — ODLOČITEV POTREBNA

V Resend nadzorni plošči (Domains → Add Domain → `vidadria.com`) se je pokazalo opozorilo:

> **vidadria.com is in use by another Resend team.** Verifying ownership will transfer the domain to
> your team and revoke their access.

To pomeni: **nekdo (drug razvijalec/ekipa) je to domeno pri Resend že prej registriral.** Preden kdorkoli
klikne "I've added the records" (kar prenese lastništvo domene in **prekliče dostop tistemu prejšnjemu
računu**), je treba to razjasniti — če ta drug Resend račun že kaj dejansko pošilja (spletna stran, računi,
potrditve naročil ...), bi nepremišljen prevzem to pretrgal brez opozorila.

**Odločeno 2026-09-14**: to razčisti drug razvijalec, ki bo prevzel to nalogo. Preden se domena prevzame:
1. Ugotovi, kdo/kaj je ta drug Resend račun in ali trenutno karkoli pošilja prek `vidadria.com`.
2. Če je varno (star/pozabljen račun, nič aktivnega), prevzemi domeno (klik "I've added the records" po
   tem, ko so DNS zapisi za `vidadria.com` dodani — glej naslednji korak).
3. Če ni varno, se dogovori s tistim, ki ima ta drug račun, o skupni rabi ali usklajeni migraciji.

## Naslednji koraki, ko je domena razčiščena

1. V Resend: **Domains → Add Domain → vidadria.com**, dodaj prikazane DNS zapise (TXT za SPF, CNAME za
   DKIM) pri tistem, ki upravlja DNS za `vidadria.com` (verjetno isti kontakt kot za Microsoft 365).
   Klikni **Verify** po razširjanju DNS (lahko traja od minut do ur).
2. V `appsettings.Local.json` (koren rešitve, ni v Gitu) ali kot okoljske spremenljivke nastavi:
   ```
   PIM_ALERT_DELIVERY_ENABLED=true
   PIM_ALERT_EMAIL_ENABLED=true
   PIM_ALERT_EMAIL_PROVIDER=Resend
   PIM_RESEND_API_KEY=re_...          (API ključ iz Resend nadzorne plošče)
   PIM_SMTP_FROM=PIM Alarmi <alarmi@vidadria.com>   (ali podoben naslov na potrjeni domeni)
   ```
   Opomba: `PIM_SMTP_FROM` je poimenovan po prejšnjem (SMTP) mehanizmu, a se uporablja za "from" naslov
   pri obeh ponudnikih — ni ga treba preimenovati, samo vedi, da velja tudi za Resend.
3. Poženi `PIM.AlertDispatcher` (ročno ali prek Scheduled Task) in preveri v `ops.AlertDelivery`, da
   vrstice preidejo iz `Pending` v `Succeeded`. Trenutno čaka 6 pravih alarmov (od 3.-4. septembra) na
   `david@vidadria.com`, ki bodo prvi pravi test.
4. Ko deluje, dodaj iste okoljske spremenljivke tudi na namenski strežnik (glej
   `deploy/Configure-WorkerScheduledTasks.ps1` in `deploy/README-Windows.md` — skrivnosti gredo tja ročno,
   nikoli prek skripte ali Gita).

## Kaj vse lahko Resend še pokrije (za kasneje, ni nujno zdaj)

`ops.AlertDelivery` s kanalom `Email` je trenutno edina pot, ki jo `EmailAlertSender` pošilja, in edini
vir obvestil je stopnjevanje neopdrjenih napak pri odhodni pošti v SAOP (`ops.EscalateOutboundEvents`,
migracija 090). Ko je Resend enkrat priklopljen, je isti mehanizem (isti `EmailAlertSender`, drugačna
vsebina) mogoče brez večjega dela razširiti na:

- **Nočni samotest** (`/sistem/samotest`) — obvestilo, če pade.
- **Zastali/tihi postopki** (`ops.RunWatchdog`, `StaleHeartbeat` alarmi) — trenutno gredo v isto vrsto
  (`ops.Alert` → `ops.AlertDelivery`), torej to že deluje takoj, ko je Resend priklopljen — ni dodatnega
  dela.
- **Neuspeli B2B/Magento izvozi** (`out.ExportRun`, `B2B_EXPORT` alarmi, `ExportRejected`) — enako, že v
  isti vrsti.
- **Nove funkcije, ki jih danes ni**: tedenski povzetek stanja kataloga, opozorilo ob manjkajočih
  prevodih/kategorijah, obvestilo uporabniku intranета ob pozabljenem geslu (`sec.LocalUser`) — to bi
  zahtevalo nov klic `EmailAlertSender`/podoben razred zunaj `ops.Alert` vrste, ni pripravljeno danes.

Ker `ops.RunWatchdog`/`ops.EscalateOutboundEvents` že polnita `ops.AlertDelivery` za vse zgornje obstoječe
primere, je **glavno delo za razširitev na "vse" že narejeno** — ko Resend enkrat pošlje eno vrsto
alarma, pošlje vse, ki gredo skozi isto vrsto. Novih funkcij (tedenski povzetek ipd.) pa ni treba graditi,
dokler jih kdo dejansko ne potrebuje.
