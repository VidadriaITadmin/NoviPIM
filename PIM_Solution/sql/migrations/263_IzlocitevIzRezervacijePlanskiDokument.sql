/*
  263 — kljukica »izloči iz rezervacije zaloge« gre v SAOP na svojo končno točko.

  Polje Planning.ExcludeQtyReservation je bilo v pogodbi izdelka (out.SaopXmlField) pod ovojem
  PropertiesData, zato je odšlo v PATCH api/Item/UpdateItemsGeneralData. SAOP tam tega elementa ne
  pozna (swagger: ItemExcludeQtyReservation je samo v PlanningData) in je 22.9.2026 za ACB.C3986100N
  odgovoril 500 »Internal server error«.

  Stari PIM je kljukico pošiljal posebej: PATCH api/Item/UpdateItemsPlanningData z dokumentom
    <ItemsPlanningData><ItemPlanningData><ItemID/><PlanningData><ItemExcludeQtyReservation>true|false
  (PIM_test: src/Services/SaopPlanningXmlBuilder.cs, scripts/Send_ItemsPlanningData_Exclude.ps1).

  Tu se polje samo preseli v ovoj PlanningData. Pošiljatelj (PIM.Outbound.SaopPlanningDocument)
  polja tega ovoja izloči iz splošnega dokumenta in jih pošlje kot dokument planskih podatkov —
  samo spremenjena polja, za splošnim dokumentom istega prevzema. Sporočila v vrsti ostanejo
  SAOP_PRODUCT, odobritev in zgodovina se ne spremenita.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;

IF NOT EXISTS (SELECT 1 FROM out.SaopXmlField
               WHERE TargetKind = N'SAOP_PRODUCT' AND FieldKey = N'Planning.ExcludeQtyReservation')
  THROW 52630, N'263: v pogodbi izdelka ni polja Planning.ExcludeQtyReservation.', 1;

UPDATE out.SaopXmlField
SET Section = N'PlanningData', UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = N'migracija 263'
WHERE TargetKind = N'SAOP_PRODUCT' AND FieldKey = N'Planning.ExcludeQtyReservation'
  AND Section <> N'PlanningData';

IF EXISTS (SELECT 1 FROM out.SaopXmlField
           WHERE TargetKind = N'SAOP_PRODUCT' AND FieldKey = N'Planning.ExcludeQtyReservation'
             AND (Section <> N'PlanningData' OR ElementName <> N'ItemExcludeQtyReservation'
                  OR ValueFormat <> N'bool' OR TrueValue <> N'true' OR FalseValue <> N'false'))
  THROW 52631, N'263: polje Planning.ExcludeQtyReservation nima oblike, ki jo pricakuje UpdateItemsPlanningData.', 1;
