# A snippet pasted in without indenting it, repeating settings the file already has (the user's AirPods case).
# expect-output: `services.pulseaudio.enable` is set twice
# expect-output: Line 15 is indented less than the code around it
# expect-output: Both set it to `false`. Delete line 15: services.pulseaudio.enable = false;
# expect-output: lines 11–14: `services.pipewire = { … };` (all repeats)
# expect-output: "All repeats": every setting in that block
{ ... }:
{
  hardware.bluetooth.enable = true;

services.pipewire = {
  enable = true;
  pulse.enable = true;
};
services.pulseaudio.enable = false;

  # --- Audio ---
  services.pulseaudio.enable = false;
  services.pipewire = {
    enable = true;
    pulse.enable = true;
    alsa.enable = true;
  };
}
