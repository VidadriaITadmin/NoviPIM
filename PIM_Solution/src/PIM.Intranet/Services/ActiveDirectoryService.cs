using System.DirectoryServices.AccountManagement;
using System.Runtime.Versioning;

namespace PIM.Intranet.Services;

public sealed record ActiveDirectoryUser(string DomainIdentity, string DisplayName);
public sealed record ActiveDirectoryLookupResult(ActiveDirectoryUser? User, string? Error)
{
  public bool Success => User is not null;
}

public sealed class ActiveDirectoryService(IConfiguration configuration)
{
  string Domain => configuration["ActiveDirectory:Domain"]?.Trim() ?? "AD";

  public ActiveDirectoryLookupResult Lookup(string identity)
  {
    if (!OperatingSystem.IsWindows()) return new(null, "AD iskanje je na voljo samo na Windows strežniku.");
    var normalized = NormalizeIdentity(identity, Domain);
    if (normalized is null) return new(null, $"Vnesi uporabnika v obliki {Domain}\\uporabnik.");

    try
    {
      return LookupWindows(normalized);
    }
    catch
    {
      return new(null, $"Domenskega uporabnika ni mogoče najti v domeni {Domain}.");
    }
  }

  public bool Validate(string domainIdentity, string password)
  {
    if (!OperatingSystem.IsWindows() || string.IsNullOrEmpty(password)) return false;
    var normalized = NormalizeIdentity(domainIdentity, Domain);
    if (normalized is null) return false;

    try
    {
      return ValidateWindows(normalized, password);
    }
    catch
    {
      return false;
    }
  }

  public static string? NormalizeIdentity(string? identity, string domain)
  {
    if (string.IsNullOrWhiteSpace(identity) || string.IsNullOrWhiteSpace(domain)) return null;
    var value = identity.Trim();
    var separator = value.IndexOf('\\');
    if (separator <= 0 || separator == value.Length - 1) return null;
    var suppliedDomain = value[..separator].Trim();
    var samAccountName = value[(separator + 1)..].Trim();
    return suppliedDomain.Equals(domain, StringComparison.OrdinalIgnoreCase) && samAccountName.Length > 0
      ? $"{domain}\\{samAccountName}"
      : null;
  }

  [SupportedOSPlatform("windows")]
  ActiveDirectoryLookupResult LookupWindows(string identity)
  {
    var samAccountName = identity[(identity.IndexOf('\\') + 1)..];
    using var context = new PrincipalContext(ContextType.Domain, Domain);
    using var user = UserPrincipal.FindByIdentity(context, IdentityType.SamAccountName, samAccountName);
    return user is null
      ? new(null, $"Domenski uporabnik {identity} ne obstaja.")
      : new(new(identity, user.DisplayName?.Trim() is { Length: > 0 } displayName ? displayName : identity), null);
  }

  [SupportedOSPlatform("windows")]
  bool ValidateWindows(string identity, string password)
  {
    var samAccountName = identity[(identity.IndexOf('\\') + 1)..];
    using var context = new PrincipalContext(ContextType.Domain, Domain);
    return context.ValidateCredentials(samAccountName, password, ContextOptions.Negotiate);
  }
}
