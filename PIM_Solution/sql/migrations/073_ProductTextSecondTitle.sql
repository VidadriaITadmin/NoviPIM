/*
  073 — druga vrstica ERP naziva dobi svoje mesto.

  Najdeno takoj po 072: nazivi po jezikih so se izlusili (92.735 vrednosti), MERGE v
  canon.ProductText pa je padel na CK_CanonProductText_Type. Dovoljene vrste besedila so bile
  DESCRIPTION, WEB_TITLE in TITLE_ERP; SAOP pa naziv artikla poslje v dveh vrsticah
  (ItemTitle1 in ItemTitle2) in preglednica jih ima za dva dela istega naziva.

  Kar ta migracija naredi: doda TITLE_ERP2 med dovoljene vrste. Druge vrstice ne zdruzujemo s
  prvo — zdruzevanje je stvar izpisa, ne shrambe; kdor hoce cel naziv, zdruzi TITLE_ERP in
  TITLE_ERP2 in ve, kaj je od kod. Prav to zdruzevanje je v stari preglednici zapisano kot
  izpeljano polje.

  Strani, ki so zaradi te napake koncale v karanteni, se preslikajo znova; nic ni izgubljeno,
  ker je vsebina se vedno v raw.Inbox.
*/

SET XACT_ABORT ON;

IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_CanonProductText_Type')
  ALTER TABLE canon.ProductText DROP CONSTRAINT CK_CanonProductText_Type;

ALTER TABLE canon.ProductText WITH CHECK
  ADD CONSTRAINT CK_CanonProductText_Type
  CHECK (TextType IN (N'DESCRIPTION', N'WEB_TITLE', N'TITLE_ERP', N'TITLE_ERP2'));

IF NOT EXISTS
(
  SELECT 1 FROM sys.check_constraints
  WHERE name = N'CK_CanonProductText_Type' AND definition LIKE N'%TITLE\_ERP2%' ESCAPE N'\'
)
  THROW 52731, 'Druga vrstica ERP naziva ni dovoljena.', 1;
