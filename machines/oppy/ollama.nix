{ ... }:
{
  # Ollama service for local LLM inference
  services.ollama = {
    enable = true;
    # package defaults to pkgs.ollama; bumped to unstable via
    # ../common/ollama-overlay.nix
    acceleration = "cuda";
  };

  # Optional: Open firewall port if you want to access ollama from other machines
  # networking.firewall.allowedTCPPorts = [ 11434 ];
}