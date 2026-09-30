/*
  323 — Zgodovina sprememb zapiše tudi spremembo samo velike/male črke (atributi in besedila) — naloga #115.

  Najdeno pri #49 (2026-09-30, razvojna baza): sprožilca canon.TR_ProductAttribute_FieldHistory in
  canon.TR_ProductText_FieldHistory (034) primerjata staro in novo vrednost z
    WHERE EXISTS(SELECT CONVERT(nvarchar(400),d.Value) EXCEPT SELECT CONVERT(nvarchar(400),i.Value))
  v kolaciji baze (SQL_Latin1_General_CP1_CI_AS = NE loči velikih in malih črk). Sprememba »kgs« -> »Kgs«
  ali »bela« -> »Bela« se je zato zapisala v bazo, v pim.ProductFieldHistory pa ne (pri 314 je od 27.490
  sprememb v zgodovino šlo 17.502, ostale so samo v pim.AttributeValueNormalizationLog).

  Kaj naredi 323 (ena transakcija; če katerakoli kontrola pade, se nič ne spremeni):
    1. V ŽIVI definiciji obeh sprožilcev zamenja samo pogoj primerjave: obe strani EXCEPT dobita
       COLLATE Latin1_General_BIN2 (loči velike/male črke in naglase; presledki na koncu se še vedno ne
       štejejo kot sprememba — tako kot prej). Vse ostalo (paket, vir, kdo, zapisane vrednosti) ostane.
       Sidro mora biti v vsakem sprožilcu natanko enkrat; če ga ni, 323 ustavi (drift) — razen če je
       popravek že narejen (ponovni zagon ne naredi nič).
    2. Samopreizkus v shranjeni točki (SAVE TRANSACTION ... ROLLBACK): na enem obstoječem atributu z malo
       črko nastavi isto vrednost z VELIKIMI črkami in preveri, da je sprožilec zapisal natanko eno vrstico
       zgodovine; nato vse vrne (podatki in zgodovina ostanejo, kot so bili).

  Kaj NE naredi: stare zgodovine ne dopolnjuje (manjkajoče spremembe iz 314 so v
  pim.AttributeValueNormalizationLog). Sprožilci za canon.Product, canon.ProductCommercial in
  canon.ProductMedia imajo enak vzorec, a jih 323 ne spreminja (Product/Commercial so polja iz SAOP in jih
  bere pogled zadržanih sprememb za SAOP, 311) — ločena naloga.

  Vpliv: pri množičnih spremembah, ki menjajo samo veliko/malo črko (poenotenje vrednosti, uvoz), bo
  zgodovina imela več vrstic. Nič ne gre v SAOP, katalog.csv se ne spremeni.
  Objekti: canon.TR_ProductAttribute_FieldHistory, canon.TR_ProductText_FieldHistory (ALTER na živi
  definiciji). Ročni korak: ne. Migrator ne pozna GO.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;

IF UNICODE(N'č') <> 269
  THROW 53230, N'323: datoteka ni prebrana kot UTF-8 (sqlcmd -f 65001 ali Invoke-PendingMigrations.ps1).', 1;
IF OBJECT_ID(N'canon.TR_ProductAttribute_FieldHistory', N'TR') IS NULL OR OBJECT_ID(N'canon.TR_ProductText_FieldHistory', N'TR') IS NULL
   OR OBJECT_ID(N'pim.ProductFieldHistory', N'U') IS NULL OR OBJECT_ID(N'pim.ProductChangeBatch', N'U') IS NULL
  THROW 53231, N'323 potrebuje sprožilca zgodovine iz 034.', 1;

DECLARE @Old nvarchar(400) = N'WHERE EXISTS(SELECT CONVERT(nvarchar(400),d.Value) EXCEPT SELECT CONVERT(nvarchar(400),i.Value));';
DECLARE @New nvarchar(400) = N'WHERE EXISTS(SELECT CONVERT(nvarchar(400),d.Value) COLLATE Latin1_General_BIN2 EXCEPT SELECT CONVERT(nvarchar(400),i.Value) COLLATE Latin1_General_BIN2) /* 323: tudi velika/mala crka */;';
DECLARE @Marker nvarchar(100) = N'/* 323: tudi velika/mala crka */';

BEGIN TRANSACTION;

DECLARE @Name sysname, @Def nvarchar(max), @Count int, @Pos int;
DECLARE triggers CURSOR LOCAL FAST_FORWARD FOR
  SELECT name FROM (VALUES (N'canon.TR_ProductAttribute_FieldHistory'), (N'canon.TR_ProductText_FieldHistory')) AS t(name);
OPEN triggers;
FETCH NEXT FROM triggers INTO @Name;
WHILE @@FETCH_STATUS = 0
BEGIN
  SET @Def = OBJECT_DEFINITION(OBJECT_ID(@Name));
  IF CHARINDEX(@Marker, @Def) = 0
  BEGIN
    SET @Count = (LEN(@Def) - LEN(REPLACE(@Def, @Old, N''))) / LEN(@Old);
    IF @Count <> 1
    BEGIN
      DECLARE @Msg nvarchar(400) = CONCAT(N'323: v ', @Name, N' pogoj primerjave ni natanko enkrat (najdeno ', @Count, N'x) — živa definicija se razlikuje od 034.');
      THROW 53232, @Msg, 1;
    END;
    SET @Def = REPLACE(@Def, @Old, @New);
    SET @Pos = CHARINDEX(N'CREATE', @Def);
    IF @Pos = 0 OR CHARINDEX(N'TRIGGER', @Def) < @Pos THROW 53233, N'323: definicija sprožilca se ne začne s CREATE.', 1;
    SET @Def = STUFF(@Def, @Pos, 6, N'ALTER');
    EXEC (@Def);
    IF CHARINDEX(@Marker, OBJECT_DEFINITION(OBJECT_ID(@Name))) = 0 OR CHARINDEX(N'Latin1_General_BIN2', OBJECT_DEFINITION(OBJECT_ID(@Name))) = 0
      THROW 53234, N'323: sprožilec po spremembi nima primerjave BIN2.', 1;
  END;
  FETCH NEXT FROM triggers INTO @Name;
END;
CLOSE triggers;
DEALLOCATE triggers;

/* Samopreizkus: sprememba samo velikosti črk mora dati eno vrstico zgodovine, enaka vrednost nobene. */
DECLARE @TestId bigint, @TestValue nvarchar(400);
SELECT TOP (1) @TestId = pa.ProductAttributeId, @TestValue = CONVERT(nvarchar(400), pa.Value)
FROM canon.ProductAttribute AS pa
WHERE pa.Value IS NOT NULL AND LEN(pa.Value) BETWEEN 1 AND 100
  AND CONVERT(nvarchar(400), pa.Value) COLLATE Latin1_General_BIN2 <> UPPER(CONVERT(nvarchar(400), pa.Value)) COLLATE Latin1_General_BIN2;

IF @TestId IS NOT NULL
BEGIN
  DECLARE @TestBatch uniqueidentifier = NEWID(), @SameBatch uniqueidentifier = NEWID(), @Rows int, @SameRows int;
  SAVE TRANSACTION Preizkus323;
  EXEC sys.sp_set_session_context @key = N'ChangeSource', @value = N'MIGRACIJA';
  EXEC sys.sp_set_session_context @key = N'ChangedBy', @value = N'migracija 323 (preizkus)';
  EXEC sys.sp_set_session_context @key = N'BatchId', @value = @TestBatch;
  UPDATE canon.ProductAttribute SET Value = UPPER(Value) WHERE ProductAttributeId = @TestId;
  SELECT @Rows = COUNT(*) FROM pim.ProductFieldHistory AS h
    INNER JOIN pim.ProductChangeBatch AS b ON b.ChangeBatchId = h.ChangeBatchId
    WHERE b.BatchId = @TestBatch AND h.FieldKey = N'ProductAttribute.Value';
  EXEC sys.sp_set_session_context @key = N'BatchId', @value = @SameBatch;
  UPDATE canon.ProductAttribute SET Value = Value WHERE ProductAttributeId = @TestId;
  SELECT @SameRows = COUNT(*) FROM pim.ProductFieldHistory AS h
    INNER JOIN pim.ProductChangeBatch AS b ON b.ChangeBatchId = h.ChangeBatchId
    WHERE b.BatchId = @SameBatch;
  ROLLBACK TRANSACTION Preizkus323;
  EXEC sys.sp_set_session_context @key = N'BatchId', @value = NULL;
  EXEC sys.sp_set_session_context @key = N'ChangeSource', @value = NULL;
  EXEC sys.sp_set_session_context @key = N'ChangedBy', @value = NULL;
  IF @Rows <> 1 THROW 53235, N'323: sprememba samo velikosti črk ni dala natanko ene vrstice zgodovine.', 1;
  IF @SameRows <> 0 THROW 53236, N'323: zapis enake vrednosti je dal vrstico zgodovine.', 1;
  IF NOT EXISTS (SELECT 1 FROM canon.ProductAttribute WHERE ProductAttributeId = @TestId
                 AND CONVERT(nvarchar(400), Value) COLLATE Latin1_General_BIN2 = @TestValue COLLATE Latin1_General_BIN2)
    THROW 53237, N'323: preizkusna vrednost ni bila vrnjena.', 1;
END;

COMMIT TRANSACTION;
PRINT N'323: sprožilca zgodovine atributov in besedil ločita velike/male črke.';
