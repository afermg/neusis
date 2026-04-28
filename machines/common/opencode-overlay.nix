{
  nixpkgs.overlays = [
    (_final: prev: {
      opencode = prev.unstable.opencode;
    })
  ];
}
