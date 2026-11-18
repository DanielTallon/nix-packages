{ pkgs, ... }:
{
  environment.systemPackages = with pkgs;
    # --- Browsers ---
    brave

    # --- General ---
    baobab
    fish
  ];
}
