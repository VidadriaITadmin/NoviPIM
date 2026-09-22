/*
  114 — najmanjsi razmik med dvema prevzemoma istega vira.

  Cikel zaloge tece na 5 minut, dobavitelji pa svojih datotek ne osvezujejo tako pogosto:

    NW_STOCK   Nowodvorski osvezuje zalogo na 2 uri (potrdil narocnik 2026-08-27)
    BT_STOCK   Braytron dovoli en prenos na 3 ure in okno pove v svojem odgovoru

  Brez tega podatka bi vsak petminutni cikel odprl FTP sejo oziroma HTTPS zahtevo - 288 klicev
  na dan na vir za podatek, ki se spremeni 12-krat oziroma 8-krat. To ni samo nesmiselno, ampak
  je pri viru z izrecno omejitvijo tudi razlog za blokado.

  Razmik sodi v register in ne v urnik: urnik pove, kako pogosto gledamo, razmik pa, kako pogosto
  dobavitelj sploh ima kaj novega. Prvo je nasa odlocitev, drugo dobaviteljeva lastnost.

  Braytronova vrednost je varovalka: njegov odgovor jo povozi, kadar okno sam sporoci.
  MAPA (NW_XML) razmika nima - lokalno datoteko polozi clovek in ni koga varovati.

  Zakaj dinamicni SQL. Migrator izvede datoteko kot en paket in ne pozna locila GO. Stavek, ki
  se sklicuje na stolpec, dodan v istem paketu, zato pade na razclenitvi (napaka 102), se preden
  se ALTER izvede. sp_executesql razclenitev odlozi na cas izvedbe, ko stolpec ze obstaja.
*/

SET XACT_ABORT ON;

IF COL_LENGTH(N'map.SourceFetchLocation', N'MinIntervalMinutes') IS NULL
  ALTER TABLE map.SourceFetchLocation ADD MinIntervalMinutes int NULL;

EXEC sp_executesql N'
  UPDATE map.SourceFetchLocation SET MinIntervalMinutes = 120, UpdatedUtc = SYSUTCDATETIME()
  WHERE SourceCode = N''NW_STOCK'';

  UPDATE map.SourceFetchLocation SET MinIntervalMinutes = 180, UpdatedUtc = SYSUTCDATETIME()
  WHERE SourceCode = N''BT_STOCK'';';

/* --- preverba --------------------------------------------------------------- */

EXEC sp_executesql N'
  IF EXISTS (SELECT 1 FROM map.SourceFetchLocation
             WHERE SourceCode IN (N''NW_STOCK'', N''BT_STOCK'') AND MinIntervalMinutes IS NULL)
    THROW 52809, ''Oba zalogovna vira morata imeti zapisan najmanjsi razmik med prevzemoma.'', 1;

  IF EXISTS (SELECT 1 FROM map.SourceFetchLocation WHERE MinIntervalMinutes <= 0)
    THROW 52810, ''Razmik med prevzemoma mora biti pozitiven.'', 1;';
