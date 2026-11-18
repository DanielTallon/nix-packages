# mode: captured
# Real output from the user's config (2026-10-24): after an update, mcp-nixos in systemPackages needs fastmcp,
# which needs fastmcp-slim, which nixpkgs marks broken once mcp is version 2. Newer nixpkgs words this as
# "has problems: - broken:". The trace only names man-db's options; the derivation frames give the chain.
# expect-output: Where: configuration.nix, line 3
# expect-output: Its package marks it broken when `lib.versionAtLeast mcp.version "2"`
# expect-output: Nothing in your files names it: `mcp-nixos` (configuration.nix, line 3) needs `python3Packages.fastmcp`, which needs `python3Packages.fastmcp-slim`.
# expect-output: Remove `mcp-nixos` from line 3 of configuration.nix for now.
# expect-output: inputs.nixpkgs-pinned.legacyPackages.${pkgs.stdenv.hostPlatform.system}.mcp-nixos
# expect-output: nixpkgs.config.problems.handlers.fastmcp-slim.broken = "warn";
{ pkgs, ... }:
{
  environment.systemPackages = [ pkgs.mcp-nixos ];
}
