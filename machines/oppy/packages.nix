{
  pkgs,
  ...
}:
{
  # Oppy-specific packages (base packages in common/system.nix)
  environment.systemPackages = [
    pkgs.ipmitool
  ];
}
