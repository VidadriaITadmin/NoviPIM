/*
  094 — ponovna preslikava mora vrniti tudi vrednosti, ne le stanje strani.

  --- Kaj se je pokazalo ------------------------------------------------------------------

  Migracija 093 je vpisala 213 manjkajocih prevodov. Po ponovni preslikavi obeh dobaviteljevih
  zagonov (--znova-preslikaj, vsa stiri podjetja) v katalogu ni bilo nobene spremembe:
  "Prevladujoca barva SLO" je imela se vedno 2.425-krat "White" in nic "bela".

  Vzrok je varovalka v map.ApplyValueTransforms:

      AND value.RawValue IS NULL

  Postopek pred prvo pretvorbo shrani izvirnik v RawValue in vrednost s tem oznaci kot ze
  obdelano. To je pravilno — brez tega bi se pretvorbe ob ponovnem zagonu izvedle dvakrat
  (PREFIX bi predpono dodal dvakrat, STRIPPREFIX bi odrezal dva). Posledica pa je, da nov
  prevod doseze samo strani, ki so zajete na novo; nad ze izluscenimi vrednostmi je slovar
  brez ucinka.

  Ravno to je primer, za katerega --znova-preslikaj obstaja. Njegov komentar v obeh workerjih
  pravi: "Rabi se, ko se preslikave dopolnijo nad ze obdelanim zajemom." Doslej je stikalo
  vrnilo samo stanje strani na Pending, vrednosti pa pustilo pretvorjene — torej svoje naloge
  ni opravilo do konca.

  --- Kaj ta migracija naredi -------------------------------------------------------------

  map.ReopenRunForMapping naredi oboje v enem koraku: strani vrne na Pending IN izluscene
  vrednosti tega zagona vrne v surovo obliko (Value = RawValue, RawValue = NULL). Pretvorbe se
  s tem izvedejo znova nad izvirnikom, kar je deterministicno in ponovljivo: izvirnik je
  shranjen prav zato.

  Nicesar ne brise. Vrednost brez RawValue (se ni sla skozi pretvorbe) ostane nedotaknjena.

  Postopek je v bazi in ne v workerju, ker sta workerja dva — PIM.XmlFileWorker in
  PIM.KatalogWorker — in sta doslej imela isti stavek prepisan vsak zase.
*/

SET XACT_ABORT ON;

EXEC(N'
CREATE OR ALTER PROCEDURE map.ReopenRunForMapping
  @RunId uniqueidentifier,
  @Pages int = NULL OUTPUT
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  BEGIN TRANSACTION;

  /* Izvirnik nazaj v Value. Brez tega map.ApplyValueTransforms te vrstice preskoci
     (varovalka RawValue IS NULL) in dopolnjen slovar nima ucinka. */
  UPDATE value
    SET Value = value.RawValue,
        RawValue = NULL
  FROM map.ExtractedValue value
  INNER JOIN raw.Inbox inbox ON inbox.InboxId = value.InboxId
  WHERE inbox.RunId = @RunId
    AND value.RawValue IS NOT NULL;

  /* Samo stanje strani, brez brisanja: ze zapisani podatki ostanejo, preslikava jih ob
     ponovnem zagonu zdruzi (MERGE oziroma "vstavi, ce se ni"). */
  UPDATE raw.Inbox
    SET Status = N''Pending'', ProcessedUtc = NULL
  WHERE RunId = @RunId AND Status IN (N''Processed'', N''Quarantined'');

  SET @Pages = @@ROWCOUNT;

  COMMIT;
END;
');
