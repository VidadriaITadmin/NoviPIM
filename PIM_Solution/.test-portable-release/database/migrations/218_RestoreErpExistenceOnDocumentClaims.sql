/*
  218 - prevzem dokumenta mora izbiro POST/PATCH vezati na ErpExistence.

  Migracija 195 je pravilno dodala ponovni prevzem zapadlih pošiljanj, vendar je pri
  prepisu out.ClaimItemDocument in out.ClaimItemDocumentByKey vrnila staro merilo
  "artikel je v canon.Product". Nov artikel je v PIM-u pred prvim zapisom v SAOP,
  zato mora ostati Add/POST, dokler SAOP njegovega obstoja ne potrdi.
*/
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;

DECLARE @OldExistsExpression nvarchar(max) =
  N'(SELECT 1 FROM canon.Product WHERE OrganizationId = @OrganizationId AND ItemID = @EntityKey) THEN 1 ELSE 0 END)';
DECLARE @NewExistsExpression nvarchar(max) =
  N'(SELECT 1 FROM canon.Product WHERE OrganizationId = @OrganizationId AND ItemID = @EntityKey'
  + N' AND ErpExistence = N''CONFIRMED_IN_ERP'') THEN 1 ELSE 0 END)';

DECLARE @Procedures TABLE (ObjectName nvarchar(256) NOT NULL PRIMARY KEY);
INSERT @Procedures(ObjectName)
VALUES (N'out.ClaimItemDocument'), (N'out.ClaimItemDocumentByKey');

DECLARE @ObjectName nvarchar(256), @Definition nvarchar(max), @ProcedurePosition int;
DECLARE claims CURSOR LOCAL FAST_FORWARD FOR SELECT ObjectName FROM @Procedures;
OPEN claims;
FETCH NEXT FROM claims INTO @ObjectName;
WHILE @@FETCH_STATUS = 0
BEGIN
  SET @Definition = OBJECT_DEFINITION(OBJECT_ID(@ObjectName));
  IF @Definition IS NULL
    THROW 53230, N'218: manjka postopek prevzema dokumenta.', 1;

  SET @Definition = REPLACE(@Definition, @OldExistsExpression, @NewExistsExpression);
  IF @Definition NOT LIKE N'%ErpExistence%'
    THROW 53231, N'218: merila obstoja SAOP ni bilo mogoče zamenjati.', 1;

  SET @ProcedurePosition = PATINDEX(N'%PROCEDURE%', UPPER(@Definition));
  IF @ProcedurePosition = 0
    THROW 53232, N'218: glava postopka prevzema dokumenta ni veljavna.', 1;
  SET @Definition = STUFF(@Definition, 1, @ProcedurePosition - 1, N'ALTER ');
  EXEC sys.sp_executesql @Definition;

  FETCH NEXT FROM claims INTO @ObjectName;
END;
CLOSE claims;
DEALLOCATE claims;

IF EXISTS
(
  SELECT 1
  FROM @Procedures AS expected
  CROSS APPLY (SELECT OBJECT_DEFINITION(OBJECT_ID(expected.ObjectName)) AS Definition) AS moduleValue
  WHERE moduleValue.Definition NOT LIKE N'%ErpExistence%'
)
  THROW 53233, N'218: postopek prevzema dokumenta ne bere ErpExistence.', 1;
