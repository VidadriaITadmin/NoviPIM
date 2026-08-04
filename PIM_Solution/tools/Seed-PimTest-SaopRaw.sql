/*
  Enkratni, sledljiv seed za lokalni razvoj.
  Vir: samo PIM_test.raw.IQLighting_* in PIM_test.raw.NW_XML_attributes_current.
  Cilj: samo trenutna baza PIM.
  Ne kliče val.RunValidation ali val.Promote, ker sta globalna za organizacijo 2.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF DB_NAME() <> N'PIM'
  THROW 52900, 'Skripta se sme zagnati samo v bazi PIM.', 1;

IF DB_ID(N'PIM_test') IS NULL
  THROW 52901, 'Izvorna baza PIM_test ni dosegljiva.', 1;

DECLARE @ExistingRunId uniqueidentifier =
(
  SELECT TOP (1) RunId
  FROM ops.PipelineRun
  WHERE Pipeline = N'SIMULATED_PIM_TEST_SAOP_RAW_V1'
    AND OrganizationId = 2
    AND SourceCode = N'SAOP_IQLIGHTING'
  ORDER BY StartedUtc DESC
);

IF @ExistingRunId IS NOT NULL
BEGIN
  IF EXISTS
  (
    SELECT 1
    FROM raw.Inbox
    WHERE RunId = @ExistingRunId
      AND Status <> N'Pending'
  )
  BEGIN
    PRINT N'Uspešen ali delno obdelan seed že obstaja; brez sprememb.';
    RETURN;
  END;

  -- Varnostno čiščenje samo nedokončanega prejšnjega poskusa istega simuliranega seeda.
  DELETE FROM raw.Inbox WHERE RunId = @ExistingRunId;
  DELETE FROM ops.PipelineRun WHERE RunId = @ExistingRunId;
END;

DECLARE @OriginalItemId nvarchar(100) =
(
  SELECT TOP (1) ItemID
  FROM PIM_test.raw.IQLighting_data_current
  ORDER BY __RowId
);
DECLARE @OriginalTitle nvarchar(500) =
(
  SELECT TOP (1) ItemTitle1
  FROM PIM_test.raw.IQLighting_data_current
  ORDER BY __RowId
);
DECLARE @OriginalUom nvarchar(100) =
(
  SELECT TOP (1) ItemUnitOfMeas
  FROM PIM_test.raw.IQLighting_data_current
  ORDER BY __RowId
);
DECLARE @OriginalAccountingGroup nvarchar(256) =
(
  SELECT TOP (1) AccountingBookGroupID
  FROM PIM_test.raw.IQLighting_data_current
  ORDER BY __RowId
);
DECLARE @Description nvarchar(max) =
(
  SELECT TOP (1) ItemDescription
  FROM PIM_test.raw.IQLighting_ItemDescriptions_current
  ORDER BY __RowId
);
DECLARE @Price decimal(19,4) =
(
  SELECT TOP (1) Price
  FROM PIM_test.raw.IQLighting_Prices_current
  ORDER BY __RowId
);
DECLARE @VatRate decimal(5,2) =
(
  SELECT TOP (1) VATRate
  FROM PIM_test.raw.IQLighting_Prices_current
  ORDER BY __RowId
);
DECLARE @PriceList nvarchar(100) =
(
  SELECT TOP (1) PriceListId
  FROM PIM_test.raw.IQLighting_Prices_current
  ORDER BY __RowId
);
DECLARE @ValidFrom datetime2(3) =
(
  SELECT TOP (1) PriceValidityFrom
  FROM PIM_test.raw.IQLighting_Prices_current
  ORDER BY __RowId
);
DECLARE @NwEan nvarchar(100) =
(
  SELECT TOP (1) EAN
  FROM PIM_test.raw.NW_XML_attributes_current
  WHERE NULLIF(EAN, N'') IS NOT NULL
  ORDER BY RawID
);
DECLARE @NwProductName nvarchar(500) =
(
  SELECT TOP (1) ProductName
  FROM PIM_test.raw.NW_XML_attributes_current
  WHERE NULLIF(EAN, N'') IS NOT NULL
  ORDER BY RawID
);

IF NULLIF(@OriginalItemId, N'') IS NULL OR @Price IS NULL OR @VatRate IS NULL
  OR NULLIF(@PriceList, N'') IS NULL OR NULLIF(@NwEan, N'') IS NULL
  THROW 52902, 'PIM_test nima vseh potrebnih reprezentativnih produktnih podatkov.', 1;

DECLARE @BridgeItemId nvarchar(100) = N'SIM-PIMTEST-NW-' + @NwEan;
DECLARE @SimOriginalItemId nvarchar(100) = N'SIM-PIMTEST-SAOP-' + @OriginalItemId;
DECLARE @RunId uniqueidentifier = NEWID();
DECLARE @OriginalItemPayload nvarchar(max) = CONVERT(nvarchar(max),
(
  SELECT
    @SimOriginalItemId AS [ItemID],
    COALESCE(NULLIF(@OriginalTitle, N''), N'PIM_test SAOP izdelek') AS [ItemTitle1],
    (
      SELECT
        COALESCE(NULLIF(@OriginalUom, N''), N'EA') AS [ItemUnitOfMeas],
        COALESCE(NULLIF(@OriginalAccountingGroup, N''), N'SIM_PIM_TEST') AS [AccountingBookGroupID]
      FOR XML PATH(N'GeneralData'), TYPE
    ),
    (SELECT N'SIM_PIM_TEST' AS [SupplierID], N'SIM_PIM_TEST' AS [ManufacturerID]
      FOR XML PATH(N'StockData'), TYPE),
    (SELECT N'SIM_PIM_TEST' AS [DiscountGroup1ID]
      FOR XML PATH(N'SalesData'), TYPE)
  FOR XML PATH(N'ItemGeneralData'), ROOT(N'ItemsGeneralData'), TYPE
));
DECLARE @BridgeItemPayload nvarchar(max) = CONVERT(nvarchar(max),
(
  SELECT
    @BridgeItemId AS [ItemID],
    COALESCE(NULLIF(@NwProductName, N''), N'PIM_test NW XML izdelek') AS [ItemTitle1],
    (
      SELECT N'EA' AS [ItemUnitOfMeas], N'SIM_PIM_TEST' AS [AccountingBookGroupID]
      FOR XML PATH(N'GeneralData'), TYPE
    ),
    (SELECT N'SIM_PIM_TEST' AS [SupplierID], N'SIM_PIM_TEST' AS [ManufacturerID]
      FOR XML PATH(N'StockData'), TYPE),
    (SELECT N'SIM_PIM_TEST' AS [DiscountGroup1ID]
      FOR XML PATH(N'SalesData'), TYPE)
  FOR XML PATH(N'ItemGeneralData'), ROOT(N'ItemsGeneralData'), TYPE
));
DECLARE @BridgePricePayload nvarchar(max) = CONVERT(nvarchar(max),
(
  SELECT
    @BridgeItemId AS [ItemCode],
    @NwEan AS [ItemEAN],
    @PriceList AS [PriceListId],
    @Price AS [Price],
    @VatRate AS [VATRate],
    @ValidFrom AS [PriceValidityFrom]
  FOR XML PATH(N'Price'), ROOT(N'ArrayOfPrice'), TYPE
));
DECLARE @DescriptionPayload nvarchar(max) = CONVERT(nvarchar(max),
(
  SELECT
    @BridgeItemId AS [ItemID],
    (
      SELECT COALESCE(NULLIF(@Description, N''), @NwProductName) AS [ItemDescription]
      FOR XML PATH(N'Description'), ROOT(N'Descriptions'), TYPE
    )
  FOR XML PATH(N'itemDescriptions'), ROOT(N'ItemsDescriptions'), TYPE
));

BEGIN TRANSACTION;
BEGIN TRY
  -- Generic mapping samo obogati že obstoječ kanonični produkt, zato ustvarimo dva izolirana
  -- nosilca s SIM prefiksom. Z njimi ne more priti do trka z realnimi produkti.
  MERGE canon.Product AS target
  USING
  (
    VALUES
      (2, @SimOriginalItemId, CONVERT(nvarchar(100), NULL)),
      (2, @BridgeItemId, @NwEan)
  ) AS source(OrganizationId, ItemID, EAN)
  ON target.OrganizationId = source.OrganizationId AND target.ItemID = source.ItemID
  WHEN NOT MATCHED THEN
    INSERT(OrganizationId, ItemID, EAN, BusinessHash)
    VALUES
    (
      source.OrganizationId,
      source.ItemID,
      source.EAN,
      CONVERT(char(64), HASHBYTES(N'SHA2_256', CONCAT(source.ItemID, N'|', COALESCE(source.EAN, N''))), 2)
    );

  INSERT ops.PipelineRun(RunId, Pipeline, OrganizationId, SourceCode, Status)
  VALUES(@RunId, N'SIMULATED_PIM_TEST_SAOP_RAW_V1', 2, N'SAOP_IQLIGHTING', N'Running');

  INSERT raw.Inbox(RunId, OrganizationId, SourceCode, EntityType, PageNumber, PayloadXml, PayloadHash, Status)
  VALUES
    (@RunId, 2, N'SAOP_IQLIGHTING', N'ItemGeneralData', 10001, @OriginalItemPayload,
      CONVERT(char(64), HASHBYTES(N'SHA2_256', CONVERT(varbinary(max), @OriginalItemPayload)), 2), N'Pending'),
    (@RunId, 2, N'SAOP_IQLIGHTING', N'ItemGeneralData', 10002, @BridgeItemPayload,
      CONVERT(char(64), HASHBYTES(N'SHA2_256', CONVERT(varbinary(max), @BridgeItemPayload)), 2), N'Pending'),
    (@RunId, 2, N'SAOP_IQLIGHTING', N'Prices', 10003, @BridgePricePayload,
      CONVERT(char(64), HASHBYTES(N'SHA2_256', CONVERT(varbinary(max), @BridgePricePayload)), 2), N'Pending'),
    (@RunId, 2, N'SAOP_IQLIGHTING', N'Descriptions', 10004, @DescriptionPayload,
      CONVERT(char(64), HASHBYTES(N'SHA2_256', CONVERT(varbinary(max), @DescriptionPayload)), 2), N'Pending');

  EXEC map.ProcessRawInbox @RunId = @RunId, @OrganizationId = 2, @SourceCode = N'SAOP_IQLIGHTING';

  UPDATE ops.PipelineRun
  SET Status = N'Succeeded',
      EndedUtc = SYSUTCDATETIME(),
      RowsRead = (SELECT COUNT(*) FROM raw.Inbox WHERE RunId = @RunId),
      RowsSucceeded = (SELECT COUNT(*) FROM raw.Inbox WHERE RunId = @RunId AND Status = N'Processed'),
      RowsFailed = (SELECT COUNT(*) FROM raw.Inbox WHERE RunId = @RunId AND Status = N'Quarantined')
  WHERE RunId = @RunId;

  COMMIT TRANSACTION;

  SELECT
    RunId,
    Pipeline,
    SourceCode,
    Status,
    RowsRead,
    RowsSucceeded,
    RowsFailed
  FROM ops.PipelineRun
  WHERE RunId = @RunId;
END TRY
BEGIN CATCH
  IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
  THROW;
END CATCH;
