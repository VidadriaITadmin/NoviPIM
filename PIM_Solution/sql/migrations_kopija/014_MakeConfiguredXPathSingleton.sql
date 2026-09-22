SET XACT_ABORT ON;

-- XPath value() zahteva enolično zaporedje; konfiguracijske poti so zato eksplicitno omejene na prvi element.
UPDATE map.FieldMapping
SET SourceElement=CONCAT(SourceElement,N'[1]')
WHERE IsActive=1
  AND SourceElement NOT LIKE N'%[[]1[]]%';
