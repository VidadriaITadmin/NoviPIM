SET XACT_ABORT ON;

/* 032 used NOT EXISTS around EXCEPT, which rejected an equal current value. */
DECLARE @definition nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'pim.UndoProductField'));
IF @definition IS NULL THROW 51232, 'Manjka procedura pim.UndoProductField iz migracije 032.', 1;

SET @definition = REPLACE(
  @definition,
  N'IF NOT EXISTS(SELECT @NewValue EXCEPT SELECT @CurrentValue)' + CHAR(10) + N'    THROW 51225',
  N'IF EXISTS(SELECT @NewValue EXCEPT SELECT @CurrentValue)' + CHAR(10) + N'    THROW 51225');

IF @definition LIKE N'%IF NOT EXISTS(SELECT @NewValue EXCEPT SELECT @CurrentValue)%'
  THROW 51233, 'Pogoj konflikta razveljavitve ni bil popravljen.', 1;

SET @definition = STUFF(@definition, CHARINDEX(N'PROCEDURE', @definition), 9, N'OR ALTER PROCEDURE');
EXEC sys.sp_executesql @definition;
