using System.Security.Cryptography;

namespace PIM.Operations;

/// <summary>
/// Zgoscevanje gesel lokalnih racunov.
///
/// Zakaj tu in ne v intranetu: prvega skrbnika na novem racunalniku ni komu ustvariti, ker je
/// prijava v intranet pogoj za dostop do strani, ki uporabnike ureja. Migrator zato zna ustvariti
/// zacetni racun (--ustvari-admina), oba pa morata gesla zapisati v isti obliki. Dva izvoda te
/// formule bi pomenila racun, s katerim se ni mogoce prijaviti.
///
/// PBKDF2 je iz osnovne knjiznice, zato tu ni nobene zunanje odvisnosti.
/// </summary>
public static class PasswordHash
{
  const int SaltLength = 16;
  const int KeyLength = 32;
  const int Iterations = 210_000;

  public static string Create(string password)
  {
    ArgumentException.ThrowIfNullOrWhiteSpace(password);
    var salt = RandomNumberGenerator.GetBytes(SaltLength);
    var key = Rfc2898DeriveBytes.Pbkdf2(password, salt, Iterations, HashAlgorithmName.SHA256, KeyLength);
    return $"v1.{Iterations}.{Convert.ToBase64String(salt)}.{Convert.ToBase64String(key)}";
  }

  public static bool Verify(string password, string storedHash)
  {
    if (string.IsNullOrEmpty(password) || string.IsNullOrEmpty(storedHash)) return false;
    var parts = storedHash.Split('.', StringSplitOptions.None);
    if (parts.Length != 4 || parts[0] != "v1" || !int.TryParse(parts[1], out var iterations) || iterations < 100_000) return false;
    try
    {
      var salt = Convert.FromBase64String(parts[2]);
      var expected = Convert.FromBase64String(parts[3]);
      var actual = Rfc2898DeriveBytes.Pbkdf2(password, salt, iterations, HashAlgorithmName.SHA256, expected.Length);
      return CryptographicOperations.FixedTimeEquals(actual, expected);
    }
    catch (FormatException)
    {
      return false;
    }
  }
}
