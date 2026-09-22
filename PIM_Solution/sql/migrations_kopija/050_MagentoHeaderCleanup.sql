/*
  050 — glave Magento predloge postanejo enolicne in brez skritih presledkov.

  Zakaj zdaj: uvoz v Magento bere stolpce **po imenu glave**, ne po zaporedju
  (odlocitev uporabnika, 2026-08-21). Ime glave je torej kljuc, s katerim se stolpec
  poveze z Magentovim atributom. Kljuc, ki se ponovi ali ima na koncu presledek,
  ni kljuc — Magento ne more vedeti, katerega od dveh enakih misliva, presledek na
  koncu pa je razlika, ki se je ne vidi in se je zato ne da odpraviti z gledanjem.

  Tri stvari, vse v registru, nobena v kodi izvoza:

  1. Podvojena glava 'Frekvenca' (stolpca 58 in 122). Ostane 122, ker ima ob sebi
     par 'Enota frekvence' (123) in ker so stolpci 113-215 urejeni po abecedi
     angleskih imen atributov — 58 je ostanek iz casa, ko je bila frekvenca
     zapisana posebej, preden je izvoz zacel brati vse atribute enotno.
     Stolpec 58 gre na IsActive = 0, ostali se strnejo; predloga ima 214 stolpcev.

  2. Se dve podvojeni glavi, ki ju je odkril isti pregled:
       13  'Enota bruto teze'  (ob 'Bruto teza',     stolpec 12, iz SAOP)
       125 'Enota bruto teze'  (ob 'Bruto teza (2)', stolpec 124)
       15  'Enota neto teze'   (ob 'Neto teza',      stolpec 14, iz SAOP)
       164 'Enota neto teze'   (ob 'Neto teza (2)',  stolpec 163)
     Vrednostna stolpca se ze locita s pripono '(2)', enotna pa ne. Zato dobita
     125 in 164 isto pripono. Nic se ne odstrani, samo ime postane enolicno.

  3. Devetnajst glav ima na koncu presledek ('Enota dolzine ', 'Nastavitev visine ').
     Migracija 045 jih je namerno prepisala znak za znak, ker je bila takrat
     predloga zunanja pogodba in je bil vsak znak dokaz. Odkar se povezava dela po
     imenu, je koncni presledek past: v Magentu bi ga bilo treba vtipkati, sicer se
     ime ne ujame, napake pa se ne vidi. Zato se odrezejo — tudi v kanonicni kodi,
     da 'Attr.Enota dolzine ' ne postane koda, ki jo je treba pisati s presledkom.

  Vse tri spremembe so varne prav zato, ker Magento bere po imenu: zaporedje se
  sme premakniti, ker ga nihce ne steje.

  Idempotentno: vsak UPDATE ima pogoj, ki po prvem zagonu ne velja vec.
*/

SET XACT_ABORT ON;

DECLARE @ProductProfileId int =
  (SELECT ExportProfileId FROM out.ExportProfile WHERE ProfileCode = N'MAGENTO_PRODUCTS');

IF @ProductProfileId IS NULL
  THROW 52360, 'Profil MAGENTO_PRODUCTS ne obstaja; najprej mora tece migracija 045.', 1;

/* --- 1) 'Frekvenca' ostane ena -------------------------------------------- */

IF EXISTS
(
  SELECT 1 FROM out.ExportColumn
  WHERE ExportProfileId = @ProductProfileId AND ColumnCode = N'COL058' AND IsActive = 1
)
BEGIN
  /* Zaporedje je enolicno tudi za ugasnjene vrstice (UQ_ExportColumn_ProfileOrder),
     zato gre ugasnjeni stolpec najprej na prosto mesto zunaj obsega, sele nato se
     ostali strnejo, na koncu pa se ugasnjeni pripne za zadnjega. */
  UPDATE out.ExportColumn SET IsActive = 0, SortOrder = 9058
  WHERE ExportProfileId = @ProductProfileId AND ColumnCode = N'COL058';

  /* Zaporedje aktivnih ostane zvezno 1..214. ColumnCode se ne spreminja — ta je
     oznaka vrstice v registru, ne mesto v datoteki. */
  UPDATE out.ExportColumn SET SortOrder = SortOrder - 1
  WHERE ExportProfileId = @ProductProfileId AND IsActive = 1 AND SortOrder > 58;

  UPDATE out.ExportColumn SET SortOrder = 215
  WHERE ExportProfileId = @ProductProfileId AND ColumnCode = N'COL058';
END;

/* --- 2) enotna stolpca dobita isto pripono kot njuna vrednostna ----------- */

UPDATE out.ExportColumn
SET OutputColumnName = N'Enota bruto teže (2)',
    CanonicalFieldCode = N'Attr.Enota bruto teže (2)'
WHERE ExportProfileId = @ProductProfileId AND ColumnCode = N'COL125'
  AND OutputColumnName = N'Enota bruto teže';

UPDATE out.ExportColumn
SET OutputColumnName = N'Enota neto teže (2)',
    CanonicalFieldCode = N'Attr.Enota neto teže (2)'
WHERE ExportProfileId = @ProductProfileId AND ColumnCode = N'COL164'
  AND OutputColumnName = N'Enota neto teže';

/* --- 3) brez presledka na koncu ------------------------------------------- */

UPDATE out.ExportColumn
SET OutputColumnName = RTRIM(OutputColumnName),
    CanonicalFieldCode = RTRIM(CanonicalFieldCode)
WHERE ExportProfileId = @ProductProfileId
  AND (OutputColumnName <> RTRIM(OutputColumnName) OR CanonicalFieldCode <> RTRIM(CanonicalFieldCode));

/* --- 4) preverba, da je stanje res tako, kot pravi opis ------------------- */

IF EXISTS
(
  SELECT OutputColumnName FROM out.ExportColumn
  WHERE ExportProfileId = @ProductProfileId AND IsActive = 1
  GROUP BY OutputColumnName HAVING COUNT(*) > 1
)
  THROW 52361, 'Med aktivnimi stolpci Magento predloge je se vedno podvojena glava.', 1;

IF EXISTS
(
  SELECT 1 FROM out.ExportColumn
  WHERE ExportProfileId = @ProductProfileId AND IsActive = 1
    AND (OutputColumnName <> LTRIM(RTRIM(OutputColumnName)) OR OutputColumnName = N'')
)
  THROW 52362, 'Glava Magento predloge ima presledek na robu ali je prazna.', 1;
