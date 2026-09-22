/*
  214 — nadzorna plosca: "ERP veljavni" in "Z napakami" ne smeta presegati "Skupaj izdelkov".

  Uporabnik je na /nadzorna-plosca opazil nemogoce stanje: "ERP veljavni" (297.677) je bil vecji od
  "Skupaj izdelkov" (196.559) - 151 % vseh izdelkov. Po shemi (005_CreateOutputContract,
  006_CreateCanonicalValidationAndPim) to ne sme biti mozno: val.ProductValidationState ima
  UQ_ProductValidationState_ProductProfile UNIQUE (ProductId, ValidationProfileId), val.ValidationProfile
  ima UQ_ValidationProfile_ProfileCode UNIQUE (ProfileCode) - en izdelek sme imeti kvecjemu eno VALID
  vrstico za profil 'ERP_L1'. Ce baza vseeno vrne vec vrstic na izdelek (podvojeni zapisi, npr. iz
  obdobja pred to omejitvijo ali rocnega posega mimo migracij), jih je intranet.GetDashboard (010) do
  zdaj sesteval s COUNT(*) - napaka v podatkih se je neposredno prevedla v nemogoco stevilko na plosci
  namesto da bi bila blokirana.

  intranet.GetDashboard se popravi na COUNT(DISTINCT stateValue.ProductId) za ErpValidCount in
  WebInvalidCount: obe stevilki sta s tem po definiciji navzgor omejeni s CanonProductCount za isto
  podjetje, ne glede na morebitne podvojene vrstice v val.ProductValidationState. To NE odpravi vzroka
  morebitnih podvojenih vrstic (ce obstajajo, jih je treba se poiskati in pocistiti neposredno v bazi -
  glej diagnosticni poizvedbi v docs/DATABASE.md), ampak prepreci, da bi taksna podvojitev kdajkoli spet
  pokazala nemogoco stevilko na plosci.

  Migrator ne pozna GO (061), zato CREATE OR ALTER v EXEC(N'...').
*/

SET XACT_ABORT ON;

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetDashboard @OrganizationId int
AS
BEGIN
  SET NOCOUNT ON;
  SELECT
    (SELECT COUNT(*) FROM canon.Product WHERE OrganizationId = @OrganizationId) AS CanonProductCount,
    (SELECT COUNT(*) FROM pim.Product WHERE OrganizationId = @OrganizationId) AS PimProductCount,
    (SELECT COUNT(DISTINCT stateValue.ProductId) FROM val.ProductValidationState stateValue INNER JOIN val.ValidationProfile profileValue ON profileValue.ValidationProfileId = stateValue.ValidationProfileId INNER JOIN canon.Product productValue ON productValue.ProductId = stateValue.ProductId WHERE productValue.OrganizationId = @OrganizationId AND profileValue.ProfileCode = N''ERP_L1'' AND stateValue.Status = N''VALID'') AS ErpValidCount,
    (SELECT COUNT(DISTINCT stateValue.ProductId) FROM val.ProductValidationState stateValue INNER JOIN val.ValidationProfile profileValue ON profileValue.ValidationProfileId = stateValue.ValidationProfileId INNER JOIN canon.Product productValue ON productValue.ProductId = stateValue.ProductId WHERE productValue.OrganizationId = @OrganizationId AND profileValue.ProfileCode = N''WEB_B2C'' AND stateValue.Status = N''INVALID'') AS WebInvalidCount,
    (SELECT COUNT(*) FROM raw.Inbox WHERE OrganizationId = @OrganizationId AND Status = N''Quarantined'') AS QuarantineCount;
END;

');
