/*
  148 — popravek 147: enolicnost zahteve brez obsega je bila indeks, ne omejitev.

  Migracija 147 je iskala UQ_FieldRequirement_ProfileField med sys.key_constraints in ga ni
  nasla, ker je bil ustvarjen kot enolicen indeks (sys.indexes). Ostal je in prvi vnos v nabor
  kategorije je padel z 2601 nad (profil, polje). Tu se indeks odstrani; enolicnost z obsegom
  iz 147 (UQ_FieldRequirement_ProfileFieldScope) ostane edina.
*/

SET XACT_ABORT ON;

IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UQ_FieldRequirement_ProfileField' AND object_id = OBJECT_ID(N'val.FieldRequirement'))
  DROP INDEX UQ_FieldRequirement_ProfileField ON val.FieldRequirement;
IF EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = N'UQ_FieldRequirement_ProfileField' AND parent_object_id = OBJECT_ID(N'val.FieldRequirement'))
  ALTER TABLE val.FieldRequirement DROP CONSTRAINT UQ_FieldRequirement_ProfileField;

IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UQ_FieldRequirement_ProfileField' AND object_id = OBJECT_ID(N'val.FieldRequirement'))
  THROW 51482, N'148: stari enolicni indeks zahteve je ostal.', 1;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UQ_FieldRequirement_ProfileFieldScope' AND object_id = OBJECT_ID(N'val.FieldRequirement') AND is_unique = 1)
  THROW 51483, N'148: enolicnost zahteve z obsegom manjka.', 1;
