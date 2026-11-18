# A string where a boolean is wanted: the fix is the corrected line, not a list of typical mix-ups.
# expect: option-wrong-type
# expect-output: `programs.firefox.enable` expects boolean, but you gave it a string (`"yes"`).
# expect-output: On line 8: use `true` or `false`, without quotes. programs.firefox.enable = true;
# expect-output: What Nix said: A definition for option `programs.firefox.enable' is not of type `boolean'. Definition values: - In `hosts/case.nix': "yes"
{ ... }:
{
  programs.firefox.enable = "yes";
}
