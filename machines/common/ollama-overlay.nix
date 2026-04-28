{
  nixpkgs.overlays = [
    (_final: prev: {
      ollama = prev.unstable.ollama;
    })
  ];
}
