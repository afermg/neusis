{
  nixpkgs.overlays = [
    (_final: prev: {
      ollama = prev.unstable.ollama;
      ollama-cuda = prev.unstable.ollama-cuda;
    })
  ];
}
