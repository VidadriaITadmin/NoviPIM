SET XACT_ABORT ON;
EXEC(N'
CREATE OR ALTER PROCEDURE val.Promote
  @OrganizationId int = NULL,
  @ValidationProfileCode nvarchar(100) = N''ERP_L1''
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;
  BEGIN TRY
    BEGIN TRANSACTION;
    ;WITH Eligible AS
    (
      SELECT product.ProductId, product.OrganizationId, product.ItemID, product.EAN, product.Manufacturer,
             (SELECT TOP (1) textValue.Value FROM canon.ProductText textValue WHERE textValue.ProductId = product.ProductId AND textValue.TextType = N''WEB_TITLE'' AND textValue.Lang = N''sl'') AS Name
      FROM canon.Product product
      INNER JOIN val.ProductValidationState validationState ON validationState.ProductId = product.ProductId
      INNER JOIN val.ValidationProfile profile ON profile.ValidationProfileId = validationState.ValidationProfileId
      WHERE profile.ProfileCode = @ValidationProfileCode AND validationState.Status = N''VALID''
        AND product.IsActive = 1 AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
    )
    MERGE pim.Product AS target
    USING Eligible AS source ON target.OrganizationId = source.OrganizationId AND target.ItemID = source.ItemID
    WHEN MATCHED THEN UPDATE SET EAN = source.EAN, Name = source.Name, Manufacturer = source.Manufacturer, PromotedUtc = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT (OrganizationId, ItemID, EAN, Name, Manufacturer) VALUES (source.OrganizationId, source.ItemID, source.EAN, source.Name, source.Manufacturer);
    COMMIT TRANSACTION;
  END TRY
  BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
  END CATCH;
END;
');
