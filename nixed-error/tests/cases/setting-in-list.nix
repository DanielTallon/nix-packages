{ pkgs, ... }:
{
  programs.nix-ld = {
    enable = true;
    libraries = with pkgs; [
      vulkan-loader
      vulkan-validation-layers
        BraveWalletDisabled       = true;
    ];
  };

  programs.chromium = {
    enable = true;
    extraOpts = {
      BraveNewsDisabled = true;
      BraveTalkDisabled = true;
    };
  };
}
