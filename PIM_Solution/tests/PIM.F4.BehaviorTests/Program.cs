using PIM.Intranet.Services;

const string password = "ne-sledi-se-v-produkciji";
var hash = PasswordHasher.Hash(password);
if (!PasswordHasher.Verify(password, hash)) throw new InvalidOperationException("Pravilno geslo mora biti sprejeto.");
if (PasswordHasher.Verify("napačno", hash)) throw new InvalidOperationException("Napačno geslo ne sme biti sprejeto.");
if (PasswordHasher.Verify(password, "neveljaven-zapis")) throw new InvalidOperationException("Poškodovan hash ne sme biti sprejet.");
Console.WriteLine("F4 preverjanje lokalnega gesla je uspešno.");

var sandbox = Path.Combine(Path.GetTempPath(), "pim-local-settings-locator-" + Guid.NewGuid().ToString("N"));
try
{
  var repoRoot = Path.Combine(sandbox, "repo");
  var solutionDir = Path.Combine(repoRoot, "PIM_Solution");
  Directory.CreateDirectory(solutionDir);
  File.WriteAllText(Path.Combine(solutionDir, "PIM.sln"), "");

  var projectDir = Path.Combine(solutionDir, "src", "PIM.Intranet");
  Directory.CreateDirectory(projectDir);
  var expectedFromRoot = Path.Combine(repoRoot, LocalSettingsLocator.FileName);

  if (LocalSettingsLocator.FindRepositoryRootLocalSettingsPath(repoRoot) != expectedFromRoot)
    throw new InvalidOperationException("Iskanje mora najti korensko nastavitev, ko se zažene iz korena repozitorija.");
  if (LocalSettingsLocator.FindRepositoryRootLocalSettingsPath(projectDir) != expectedFromRoot)
    throw new InvalidOperationException("Iskanje mora najti korensko nastavitev, ko se zažene iz projektne mape.");

  var publishDir = Path.Combine(projectDir, "bin", "Release", "net10.0", "publish");
  Directory.CreateDirectory(publishDir);
  if (LocalSettingsLocator.FindRepositoryRootLocalSettingsPath(publishDir) != expectedFromRoot)
    throw new InvalidOperationException("Iskanje mora najti korensko nastavitev tudi iz objavljene (publish) mape poljubne globine.");

  var offRepo = Path.Combine(sandbox, "izven-repozitorija");
  Directory.CreateDirectory(offRepo);
  if (LocalSettingsLocator.FindRepositoryRootLocalSettingsPath(offRepo) is not null)
    throw new InvalidOperationException("Iskanje izven repozitorija ne sme vrniti poti — ni kaj najti.");

  Console.WriteLine("F4 iskanje lokalne konfiguracije je uspešno.");
}
finally
{
  if (Directory.Exists(sandbox)) Directory.Delete(sandbox, recursive: true);
}
