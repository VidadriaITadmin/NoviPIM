using PIM.Intranet.Services;
using PIM.Operations;

const string password = "ne-sledi-se-v-produkciji";
var hash = PasswordHasher.Hash(password);
if (!PasswordHasher.Verify(password, hash)) throw new InvalidOperationException("Pravilno geslo mora biti sprejeto.");
if (PasswordHasher.Verify("napačno", hash)) throw new InvalidOperationException("Napačno geslo ne sme biti sprejeto.");
if (PasswordHasher.Verify(password, "neveljaven-zapis")) throw new InvalidOperationException("Poškodovan hash ne sme biti sprejet.");
Console.WriteLine("F4 preverjanje lokalnega gesla je uspešno.");

var sandbox = Path.Combine(Path.GetTempPath(), "pim-local-settings-" + Guid.NewGuid().ToString("N"));
try
{
  // Sidro je PIM.sln in ne PIM_Solution\PIM.sln: koren rešitve mora biti najden tudi, kadar je
  // PIM_Solution sam koren kloniranega repozitorija — tam nadmape s tem imenom ni.
  var solutionDir = Path.Combine(sandbox, "repo", "PIM_Solution");
  Directory.CreateDirectory(solutionDir);
  File.WriteAllText(Path.Combine(solutionDir, "PIM.sln"), "");
  var skupna = Path.Combine(solutionDir, LocalSettings.FileName);
  File.WriteAllText(skupna, """{"ConnectionStrings":{"Pim":"Server=skupna"},"Saop":{"BaseUrl":"skupna"}}""");

  var projectDir = Path.Combine(solutionDir, "src", "PIM.Intranet");
  Directory.CreateDirectory(projectDir);
  var publishDir = Path.Combine(projectDir, "bin", "Release", "net10.0", "publish");
  Directory.CreateDirectory(publishDir);

  // Neodvisno od globine: koren rešitve, mapa projekta in objavljena mapa najdejo isto datoteko.
  foreach (var izhodisce in new[] { solutionDir, projectDir, publishDir })
    if (LocalSettings.FindPath(izhodisce) != skupna)
      throw new InvalidOperationException($"Iskanje iz {izhodisce} mora najti skupno nastavitev rešitve.");

  var offRepo = Path.Combine(sandbox, "izven-resitve");
  Directory.CreateDirectory(offRepo);
  if (LocalSettings.FindPath(offRepo) is not null)
    throw new InvalidOperationException("Izven rešitve ni kaj najti — iskanje mora vrniti null, ne ugibati.");

  // Na strežniku korena rešitve ni; velja datoteka ob .exe, ki jo ohrani Publish-Intranet.ps1.
  var streznik = Path.Combine(sandbox, "iis");
  Directory.CreateDirectory(streznik);
  File.WriteAllText(Path.Combine(streznik, LocalSettings.FileName), """{"ConnectionStrings":{"Pim":"Server=iis"}}""");
  var viriNaStrezniku = LocalSettings.Sources(streznik);
  if (viriNaStrezniku.Count != 1 || Path.GetDirectoryName(viriNaStrezniku[0]) != streznik)
    throw new InvalidOperationException("Brez korena rešitve mora obveljati datoteka ob .exe.");

  // V razvoju obstajata obe; skupna je zadnja, ker zadnji vir prepiše prejšnje.
  File.WriteAllText(Path.Combine(publishDir, LocalSettings.FileName), """{"ConnectionStrings":{"Pim":"Server=pozabljena"}}""");
  var viriVRazvoju = LocalSettings.Sources(publishDir);
  if (viriVRazvoju.Count != 2 || viriVRazvoju[^1] != skupna)
    throw new InvalidOperationException("Skupna nastavitev rešitve mora prepisati pozabljeno datoteko v izhodni mapi.");

  Console.WriteLine("F4 iskanje lokalne konfiguracije je uspešno.");
}
finally
{
  if (Directory.Exists(sandbox)) Directory.Delete(sandbox, recursive: true);
}
