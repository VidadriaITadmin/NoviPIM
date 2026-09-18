SET XACT_ABORT ON;

/* SET NOCOUNT ON resets @@ROWCOUNT; the guard must run before it. */
DECLARE @ProductTriggerDefinition nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'canon.TR_Product_FieldHistory'));
DECLARE @CommercialTriggerDefinition nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'canon.TR_ProductCommercial_FieldHistory'));

IF @ProductTriggerDefinition IS NULL OR @CommercialTriggerDefinition IS NULL
  THROW 51220, 'Manjka trigger sledljivosti sprememb iz migracije 028.', 1;

/* The existing guard stays in place. This inserts an earlier guard before SET NOCOUNT ON. */
SET @ProductTriggerDefinition = REPLACE(
  @ProductTriggerDefinition,
  N'SET NOCOUNT ON;',
  N'IF ROWCOUNT_BIG() = 0 RETURN; SET NOCOUNT ON;');
SET @CommercialTriggerDefinition = REPLACE(
  @CommercialTriggerDefinition,
  N'SET NOCOUNT ON;',
  N'IF ROWCOUNT_BIG() = 0 RETURN; SET NOCOUNT ON;');

SET @ProductTriggerDefinition = REPLACE(@ProductTriggerDefinition, N'CREATE   TRIGGER', N'CREATE OR ALTER TRIGGER');
SET @ProductTriggerDefinition = REPLACE(@ProductTriggerDefinition, N'CREATE TRIGGER', N'CREATE OR ALTER TRIGGER');
SET @CommercialTriggerDefinition = REPLACE(@CommercialTriggerDefinition, N'CREATE   TRIGGER', N'CREATE OR ALTER TRIGGER');
SET @CommercialTriggerDefinition = REPLACE(@CommercialTriggerDefinition, N'CREATE TRIGGER', N'CREATE OR ALTER TRIGGER');

IF @ProductTriggerDefinition NOT LIKE N'%IF ROWCOUNT_BIG() = 0 RETURN; SET NOCOUNT ON;%'
  THROW 51221, 'Popravek triggerja izdelka ni bil pripravljen.', 1;
IF @CommercialTriggerDefinition NOT LIKE N'%IF ROWCOUNT_BIG() = 0 RETURN; SET NOCOUNT ON;%'
  THROW 51222, 'Popravek triggerja komerciale ni bil pripravljen.', 1;

EXEC sys.sp_executesql @ProductTriggerDefinition;
EXEC sys.sp_executesql @CommercialTriggerDefinition;
