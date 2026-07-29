SET NOCOUNT ON;

DECLARE @ExpectedSchemas int = 9;
DECLARE @ActualSchemas int = (
  SELECT COUNT(*)
  FROM sys.schemas
  WHERE name IN (N'raw', N'map', N'canon', N'val', N'pim', N'out', N'ops', N'dbo', N'sec')
);

IF @ActualSchemas <> @ExpectedSchemas
  THROW 52001, 'F0 preverjanje: manjkajo sheme.', 1;

IF (SELECT COUNT(*) FROM dbo.OrganizationConfig) <> 4
  THROW 52002, 'F0 preverjanje: OrganizationConfig ne vsebuje štirih organizacij.', 1;

IF NOT EXISTS (SELECT 1 FROM sys.procedures WHERE object_id = OBJECT_ID(N'ops.LogError'))
  THROW 52003, 'F0 preverjanje: manjka ops.LogError.', 1;
IF NOT EXISTS (SELECT 1 FROM sys.procedures WHERE object_id = OBJECT_ID(N'ops.EnqueueDeadLetter'))
  THROW 52004, 'F0 preverjanje: manjka ops.EnqueueDeadLetter.', 1;
IF NOT EXISTS (SELECT 1 FROM sys.procedures WHERE object_id = OBJECT_ID(N'ops.RecordPipelineStep'))
  THROW 52005, 'F0 preverjanje: manjka ops.RecordPipelineStep.', 1;

PRINT 'F0 preverjanje MSSQL je uspešno.';
