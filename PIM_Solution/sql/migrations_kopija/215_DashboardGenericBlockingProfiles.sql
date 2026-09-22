/*
  215 — nadzorna plosca: "ERP veljavni" in "Z napakami" naj bereta trenutne blokirajoce profile,
  ne se vedno ukinjena ERP_L1 in nescinkoviti WEB_B2C.

  Uporabnik je ERP_L1 in WEB_B2C umaknil iz validacije (ERP_L1: IsActive = 0; WEB_B2C: BlocksErp = 0,
  BlocksWeb = 0 - se vedno aktiven in se vedno pise v val.ProductValidationState/val.ProductIssue, a
  ne vpliva vec na canon.Product.ValidationStatus). Njuno mesto so prevzeli ERP_L1_EU/ERP_L1_SLO/
  ERP_L1_THIRD/SHARED_CORE (BlocksErp = 1) in WEB_svetila_si/WEB_videlektro/SHARED_CORE (BlocksWeb = 1).
  intranet.GetDashboard (010, popravljeno v 214 na COUNT(DISTINCT ...)) je se vedno filtriral trdo
  kodirano po ProfileCode = ''ERP_L1''/''WEB_B2C'' - "ERP veljavni" je zato po umiku ERP_L1 vedno
  kazal 0, "Z napakami" pa je stel napake profila, ki jih nihce vec ne blokira, namesto dejanskih
  ERP/spletnih zapor.

  Popravek: obe stevilki se zdaj racunata neposredno iz canon.Product prek EXISTS/NOT EXISTS proti
  val.ProductIssue, filtrirano po profileValue.BlocksErp/BlocksWeb (ne po imenu profila) in
  requirementValue.Severity = ''ERROR'' - ista logika, kot jo canon.Product.ValidationStatus ze
  uporablja v val.RunValidation (182/211), samo locena na ERP/splet namesto zdruzena. Za splet je
  dodan isti pogoj kot tam: profil s Scope=''WEB'' velja samo, ce ima izdelek kljukico za to drevo
  (pim.ProductWebShop). Ker obe stevilki stejeta PODMNOZICO istih vrstic canon.Product, ki jih steje
  CanonProductCount, "ERP veljavni"/"Z napakami" po konstrukciji ne moreta vec preseci "Skupaj
  izdelkov" - ne glede na katerikoli prihodnji profil ali morebitne podvojene vrstice v
  val.ProductValidationState (glej tudi 214).

  ERP_L1 in WEB_B2C namerno NISTA izbrisana ali dodatno deaktivirana s to migracijo: WEB_B2C se
  aktivno uporablja v PIM.F5.Integration testu (val.Promote/out.ExportProductsCsv @ProfileCode=
  ''WEB_B2C''/-''_PRODUCTS'') in ce bi ga izklopili brez prilagoditve testa, bi ta padel. Zastarela
  preverba v PIM.Migrator (VerifyF1Async) in tests/sql/Verify-F1.sql, ki je zahtevala natanko ti dve
  imeni kot aktivni, je popravljena locena od te migracije (C#/T-SQL datoteki nista migraciji).

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
    (SELECT COUNT(*) FROM canon.Product productValue
     WHERE productValue.OrganizationId = @OrganizationId
       AND NOT EXISTS
       (
         SELECT 1 FROM val.ProductIssue issueValue
         INNER JOIN val.FieldRequirement requirementValue ON requirementValue.FieldRequirementId = issueValue.FieldRequirementId
         INNER JOIN val.ValidationProfile profileValue ON profileValue.ValidationProfileId = issueValue.ValidationProfileId
         WHERE issueValue.ProductId = productValue.ProductId AND issueValue.IsActive = 1
           AND requirementValue.Severity = N''ERROR'' AND profileValue.BlocksErp = 1
       )) AS ErpValidCount,
    (SELECT COUNT(*) FROM canon.Product productValue
     WHERE productValue.OrganizationId = @OrganizationId
       AND EXISTS
       (
         SELECT 1 FROM val.ProductIssue issueValue
         INNER JOIN val.FieldRequirement requirementValue ON requirementValue.FieldRequirementId = issueValue.FieldRequirementId
         INNER JOIN val.ValidationProfile profileValue ON profileValue.ValidationProfileId = issueValue.ValidationProfileId
         WHERE issueValue.ProductId = productValue.ProductId AND issueValue.IsActive = 1
           AND requirementValue.Severity = N''ERROR'' AND profileValue.BlocksWeb = 1
           AND (profileValue.Scope <> N''WEB'' OR EXISTS
             (SELECT 1 FROM pim.ProductWebShop shopValue
              WHERE shopValue.ProductId = productValue.ProductId
                AND shopValue.WebShopCode = profileValue.CategoryTreeCode
                AND shopValue.IsPublished = 1))
       )) AS WebInvalidCount,
    (SELECT COUNT(*) FROM raw.Inbox WHERE OrganizationId = @OrganizationId AND Status = N''Quarantined'') AS QuarantineCount;
END;

');
