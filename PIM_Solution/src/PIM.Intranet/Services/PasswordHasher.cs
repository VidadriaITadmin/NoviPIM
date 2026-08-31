namespace PIM.Intranet.Services;

/// <summary>
/// Zgoscevanje gesel. Formula zivi v <see cref="PIM.Operations.PasswordHash"/>, ker jo poleg
/// intraneta potrebuje tudi migrator, ki na novem racunalniku ustvari prvega skrbnika. Dva izvoda
/// bi pomenila racun, s katerim se ni mogoce prijaviti.
/// </summary>
public static class PasswordHasher
{
  public static string Hash(string password) => PIM.Operations.PasswordHash.Create(password);

  public static bool Verify(string password, string storedHash) => PIM.Operations.PasswordHash.Verify(password, storedHash);
}
