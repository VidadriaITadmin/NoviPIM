SET XACT_ABORT ON;

/* Equal current and historical NewValue is valid; only a difference is a conflict. */
DECLARE @definition nvarchar(max)=OBJECT_DEFINITION(OBJECT_ID(N'pim.UndoProductField'));
IF @definition IS NULL THROW 51237, 'Manjka procedura pim.UndoProductField.', 1;
IF @definition NOT LIKE N'%IF NOT EXISTS(SELECT @NewValue EXCEPT SELECT @CurrentValue)%'
  THROW 51238, 'Pričakovani pogoj konflikta razveljavitve ni najden.', 1;
SET @definition=REPLACE(@definition,N'IF NOT EXISTS(SELECT @NewValue EXCEPT SELECT @CurrentValue)',N'IF EXISTS(SELECT @NewValue EXCEPT SELECT @CurrentValue)');
SET @definition=STUFF(@definition,CHARINDEX(N'PROCEDURE',@definition),9,N'OR ALTER PROCEDURE');
EXEC sys.sp_executesql @definition;
