{ pkgs, ... }:
{
  home = {
    username = "jfredinh";
    homeDirectory = "/home/jfredinh";

    packages = with pkgs; [
      pkgs.inputs.claude-code-nix.default
      duckdb
      jq
      pkgs.unstable.opencode
    ];
  };
}
