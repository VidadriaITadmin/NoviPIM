SET XACT_ABORT ON;

/* 030 added the guard before SET NOCOUNT ON. Remove the obsolete second guard after it. */
DECLARE @ProductTriggerDefinition nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'canon.TR_Product_FieldHistory'));
DECLARE @CommercialTriggerDefinition nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'canon.TR_ProductCommercial_FieldHistory'));

IF @ProductTriggerDefinition IS NULL OR @CommercialTriggerDefinition IS NULL
  THROW 51230, 'Manjka trigger sledljivosti sprememb.', 1;

SET @ProductTriggerDefinition = REPLACE(@ProductTriggerDefinition, N'IF ROWCOUNT_BIG() = 0 RETURN; SET NOCOUNT ON;' + CHAR(10) + N'  IF ROWCOUNT_BIG() = 0 RETURN;', N'IF ROWCOUNT_BIG() = 0 RETURN; SET NOCOUNT ON;');
SET @CommercialTriggerDefinition = REPLACE(@CommercialTriggerDefinition, N'IF ROWCOUNT_BIG() = 0 RETURN; SET NOCOUNT ON;' + CHAR(10) + N'  IF ROWCOUNT_BIG() = 0 RETURN;', N'IF ROWCOUNT_BIG() = 0 RETURN; SET NOCOUNT ON;');
SET @ProductTriggerDefinition = REPLACE(@ProductTriggerDefinition, N'CREATE   TRIGGER', N'CREATE OR ALTER TRIGGER');
SET @ProductTriggerDefinition = REPLACE(@ProductTriggerDefinition, N'CREATE TRIGGER', N'CREATE OR ALTER TRIGGER');
SET @CommercialTriggerDefinition = REPLACE(@CommercialTriggerDefinition, N'CREATE   TRIGGER', N'CREATE OR ALTER TRIGGER');
SET @CommercialTriggerDefinition = REPLACE(@CommercialTriggerDefinition, N'CREATE TRIGGER', N'CREATE OR ALTER TRIGGER');

IF @ProductTriggerDefinition LIKE N'%SET NOCOUNT ON;' + CHAR(10) + N'  IF ROWCOUNT_BIG() = 0 RETURN;%'
  THROW 51231, 'Trigger izdelka ima zastareli row-count guard.', 1;
IF @CommercialTriggerDefinition LIKE N'%SET NOCOUNT ON;' + CHAR(10) + N'  IF ROWCOUNT_BIG() = 0 RETURN;%'
  THROW 51232, 'Trigger komerciale ima zastareli row-count guard.', 1;

EXEC sys.sp_executesql @ProductTriggerDefinition;
EXEC sys.sp_executesql @CommercialTriggerDefinition;
