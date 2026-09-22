/*
  070 — razpored za dobaviteljev XML pri vseh stirih podjetjih.

  Migracija 069 je konektorja NW_XML in BT_XML registrirala pri vseh stirih podjetjih, zajem pa
  je vseeno padel z 'Razpored ni omogocen': ops.BeginRun zahteva vrstico v ops.ScheduleProfile
  za (podjetje, pipeline), in GENERIC_XML jo je imelo samo podjetje 2.

  To je ista varovalka, ki je 2026-08-20 ustavila SAOP zajem pri treh podjetjih (napaka 51100).
  Ne obidemo je — dopolnimo register, kot je bilo takrat storjeno z migracijo 043.

  Intervali so prepisani z vrstice podjetja 2, da se obnasanje ne razlikuje po podjetjih.
*/

SET XACT_ABORT ON;

DECLARE @Interval int, @Stale int, @Lock int;
SELECT TOP(1) @Interval = IntervalSeconds, @Stale = StaleAfterSeconds, @Lock = LockTimeoutMilliseconds
FROM ops.ScheduleProfile WHERE Pipeline = N'GENERIC_XML' AND OrganizationId = 2;

IF @Interval IS NULL
BEGIN
  SET @Interval = 300; SET @Stale = 900; SET @Lock = 5000;
END;

MERGE ops.ScheduleProfile AS target
USING (VALUES (1), (3), (4)) AS source(OrganizationId)
  ON target.OrganizationId = source.OrganizationId AND target.Pipeline = N'GENERIC_XML'
WHEN NOT MATCHED THEN INSERT (OrganizationId, Provider, Pipeline, IsEnabled, IntervalSeconds, StaleAfterSeconds, LockTimeoutMilliseconds, UpdatedBy)
  VALUES (source.OrganizationId, N'XML', N'GENERIC_XML', 1, @Interval, @Stale, @Lock, N'migracija 070');

/* --- preverba --------------------------------------------------------------- */

IF (SELECT COUNT(*) FROM ops.ScheduleProfile WHERE Pipeline = N'GENERIC_XML' AND IsEnabled = 1) < 4
  THROW 52701, 'Razpored za dobaviteljev XML ni omogocen pri vseh stirih podjetjih.', 1;
