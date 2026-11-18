# A snippet `environment.systemPackages = [ … ];` pasted into the existing systemPackages list
# (seen in ~/.dotfiles/modules/packages.nix): drop the wrapper, keep the contents.
# expect: setting-in-list
# expect-output: Line 13 sets `environment.systemPackages` again, inside the `environment.systemPackages` list that line 9 already opened.
# expect-output: Delete line 13 (`environment.systemPackages = [`) and line 17 (`];`), keeping the lines in between.
# expect-output: Where: hosts/case.nix, line 13
{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    # --- Browsers ---
    brave

      environment.systemPackages = [
  (pkgs.hello.overrideAttrs (old: {
    postInstall = "echo hi";
  }))
];

    git
  ];
}
