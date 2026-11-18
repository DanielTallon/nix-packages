# An enum value with a typo (two letters swapped): suggest the close match.
# Nothing reads consoleMode unless systemd-boot is on, so the case reads it in an /etc file.
# expect: option-wrong-type
# expect-output: ✗ "atuo" isn't an allowed value for this option
# expect-output: did you mean "auto"? (allowed:
# expect-output: boot.loader.systemd-boot.consoleMode = "auto";
{ config, ... }:
{
  boot.loader.systemd-boot.consoleMode = "atuo";
  environment.etc.case.text = config.boot.loader.systemd-boot.consoleMode;
}
