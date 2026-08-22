{
  config,
  pkgs,
  ...
}:

let
  oppyOrigin = "100.79.40.39:18080";
in
{
  age.secrets.cloudflared-overleaf = {
    file = ../../secrets/karkinos/cloudflared-overleaf.age;
    owner = "cloudflared";
    group = "cloudflared";
    mode = "0400";
  };

  users.users.cloudflared = {
    isSystemUser = true;
    group = "cloudflared";
    description = "Cloudflare Tunnel connector";
  };
  users.groups.cloudflared = { };

  # Preserve the Cloudflare dashboard's existing localhost:18080 ingress while
  # moving the connector to Karkinos. This local socket crosses Tailscale to the
  # private, address-scoped origin on Oppy.
  systemd.sockets.overleaf-oppy-origin = {
    description = "Local Overleaf ingress socket backed by Oppy";
    wantedBy = [ "sockets.target" ];
    listenStreams = [ "127.0.0.1:18080" ];
  };

  systemd.services.overleaf-oppy-origin = {
    description = "Proxy Overleaf ingress to Oppy over Tailscale";
    after = [ "tailscaled.service" ];
    wants = [ "tailscaled.service" ];
    serviceConfig = {
      ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd ${oppyOrigin}";
      DynamicUser = true;
      NoNewPrivileges = true;
      PrivateDevices = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_UNIX"
      ];
    };
  };

  # This is the same remotely managed tunnel used on Moby. The persistent
  # cutover sentinel deliberately prevents a Karkinos rebuild from starting it
  # before Moby is quiesced; simultaneous connectors would split requests
  # between two databases. Create the sentinel only during the documented
  # cutover, then start this unit explicitly.
  systemd.services.cloudflared-overleaf = {
    description = "Cloudflare Tunnel — overleaf.quasimorphic.com";
    unitConfig.ConditionPathExists = "/var/lib/overleaf-ingress/enabled";
    after = [
      "network-online.target"
      "overleaf-oppy-origin.socket"
    ];
    wants = [
      "network-online.target"
      "overleaf-oppy-origin.socket"
    ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "notify";
      User = "cloudflared";
      Group = "cloudflared";
      EnvironmentFile = config.age.secrets.cloudflared-overleaf.path;
      ExecStart = "${pkgs.cloudflared}/bin/cloudflared --no-autoupdate tunnel --protocol http2 --edge-ip-version 4 run";
      Restart = "on-failure";
      RestartSec = "5s";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
      ];
      MemoryDenyWriteExecute = true;
      LockPersonality = true;
    };
  };
}
