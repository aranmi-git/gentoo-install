# gentoo-install.sh changelog

## 1.0 (2026-11-18)

First release, built on the same menus as
[arch-install](https://github.com/aranmi-git/arch-install) and
[artix-install](https://github.com/aranmi-git/artix-install).

### Gentoo-specific
- **Stage3** for OpenRC or systemd (desktop or not), signature checked
  against Gentoo's release key; the key comes from the Gentoo ISO, Web Key
  Directory or keys.gentoo.org and is accepted only with the pinned fingerprint.
- **Build settings**: CPU cores (MAKEOPTS), packages built at once (--jobs),
  -march (x86-64, x86-64-v3, native), prebuilt or compiled; detected CPU, threads
  and RAM shown with a recommendation (one job per thread, at most one per
  2 GiB of RAM).
- **Prebuilt packages** from Gentoo's binary host with signatures required;
  x86-64-v3 package set when chosen; `-bin` builds of Firefox, Thunderbird,
  LibreOffice and Telegram when prebuilt is chosen.
- **Profile** picked from the choices (23.0, desktop, plasma, gnome, systemd).
- **Unattended emerge**: autounmask writes and accepts needed USE, keyword and
  licence changes.
- **Distribution kernel** (prebuilt or compiled) with installkernel + dracut;
  GRUB, systemd-boot and UKI entries follow kernel updates automatically.
- **Secure Boot**: sbctl keys before the kernel is emerged, so the
  distribution kernel and its modules sign themselves; dracut signs UKIs.
- **OpenRC** (display-manager with DISPLAYMANAGER, elogind, sysklogd, cronie,
  chrony, zram-init) or **systemd** (units, zram-generator, PipeWire user
  units for everyone).
- **Window manager sessions** on OpenRC through `gentoo-session` (D-Bus +
  gentoo-pipewire-launcher).
- **Overlays**: GURU (toggle, or automatic for Ly, niri, river, LeftWM, some
  peripheral tools) and hyproverlay (Hyprland); ~amd64 accepted for them only.
- **update-system**: snapshot (snapper or ZFS), sync, update @world, depclean.
- **ZFS**: Gentoo's sys-fs/zfs + zfs-kmod; ZFSBootMenu built with dracut's crypt
  module; OpenRC zfs-import/zfs-mount or the systemd units.
- Steam from Flathub; Chrome instead of Chromium (Chromium left Gentoo's
  repository in October 2026).

### Not carried over
- Limine, rEFInd, EFISTUB and SYSLINUX; the multi-kernel boot order
  (installkernel keeps the installed kernel versions instead).
- AUR, yay and paru (GURU instead); OpenLogi; COSMIC and Budgie (not in
  Gentoo's repository).
- Carrying a live Wi-Fi network into the new system.

## What was tested, and what was not

### Automated, in this sandbox
- `shellcheck` clean with every optional check on.
- Every package name in the script checked against Gentoo's repository, GURU
  and hyproverlay as of 2026-11-18; every profile against profiles.desc.
- **Simulated install** (179 checks): OpenRC and systemd; GRUB (UEFI with an
  encrypted /boot, BIOS with a separate /boot), systemd-boot, UKI with Secure
  Boot, ZFS + ZFSBootMenu on LUKS2 and plain; make.conf, package.use, crypttab,
  dracut, services, overlays, sessions, update-system.
- **Unit tests** (58): build settings, profiles, layouts, and the stage3
  signature check with real gpg (good, tampered, other key, wrong fingerprint).
- **Presets** (167).

### Not tested
- **No real install yet.** Gentoo's mirrors were not reachable from the
  sandbox, so emerge, installkernel, dracut and the binary host never ran here.
- How often prebuilt packages match (USE differences cause local compiles),
  the autounmask choices emerge makes, Secure Boot on real firmware, ZFS on a
  real live system.
