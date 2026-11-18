# expect: missing-closer
{ ... }:
{
  programs.chromium = {
    enable = true;
    extraOpts = {
      BraveWalletDisabled = true;
      BraveNewsDisabled = true;
    };
  ;

  programs.fish.enable = true;
}
