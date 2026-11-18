# An enum value in the wrong case (like kernelProvider = "LTS" in the user's config): not the wrong kind of
# value, just not in the list. Suggest the value that differs only in case, and keep the full list.
# The value comes before the declaration: the report points at the first line naming the option.
# expect: option-wrong-type
# expect-output: ✗ "LTS" isn't an allowed value for this option
# expect-output: `kernelProvider` only accepts "xddxdd", "chaotic", "latest", "lts", "zen", "xanmod", and `"LTS"` is not one of them.
# expect-output: On line 10: did you mean "lts"? (allowed: "xddxdd", "chaotic", "latest", "lts", "zen", "xanmod") config.kernelProvider = "lts";
{ config, lib, ... }:
{
  config.kernelProvider = "LTS";
  options.kernelProvider = lib.mkOption { type = lib.types.enum [ "xddxdd" "chaotic" "latest" "lts" "zen" "xanmod" ]; };
  config.environment.etc.case.text = config.kernelProvider;
}
