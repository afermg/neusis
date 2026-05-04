{ pkgs, ... }:
{
  home = {
    username = "jfredinh";
    homeDirectory = "/home/jfredinh";

    packages = with pkgs; [
      duckdb
      jq
      pkgs.unstable.opencode
    ];
  };
}
