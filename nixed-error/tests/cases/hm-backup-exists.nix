# mode: captured
# Real output from ~/.dotfiles (backupFileExtension = "backup"): ~/.config/fastfetch/config.jsonc
# was replaced by a regular file, and a config.jsonc.backup from June was still there. Captured with
#   { echo "error: unit home-manager-fredrick.service failed"; journalctl -u home-manager-fredrick.service -n 40 -o cat; }
# The file in the way is config.jsonc, not the backup; and `nh os switch` won't rerun an unchanged unit.
# expect-output: A normal file is in the way of `~/.config/fastfetch/config.jsonc`
# expect-output: rename it to `~/.config/fastfetch/config.jsonc.backup`, but a backup by that name is already there
# expect-output: rm ~/.config/fastfetch/config.jsonc.backup
# expect-output: sudo systemctl restart home-manager-fredrick.service
# expect-output: home-manager.overwriteBackup = true;
# expect-output: `nh os switch` alone won't retry it
