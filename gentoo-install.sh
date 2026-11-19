#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# =============================================================================
#  gentoo-install.sh - menu-driven (dialog) installer for Gentoo Linux
#  https://github.com/aranmi-git/gentoo-install
#
#  Copyright (C) 2026 aranmi-git
#
#  This program is free software; you can redistribute it and/or modify it
#  under the terms of the GNU General Public License, version 2, as published
#  by the Free Software Foundation.
#
#  This program is distributed in the hope that it will be useful, but WITHOUT
#  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
#  FITNESS FOR A PARTICULAR PURPOSE. See the LICENSE file for the full text.
# =============================================================================
#
#  Features
#    * OpenRC or systemd; a Gentoo stage3 (checked against Gentoo's release key)
#    * Prebuilt packages from Gentoo's binary host where they exist, or
#      everything compiled for your CPU; you choose the CPU cores to use
#    * UEFI (64-bit or 32-bit firmware) or legacy BIOS; GPT; whole-disk install
#    * Root filesystem: ext4, btrfs or ZFS (ZFSBootMenu)
#    * Encryption of the root partition: none, LUKS1 or LUKS2
#    * Boot loader: GRUB, systemd-boot, unified kernel images (UKI), EFISTUB
#      or ZFSBootMenu; kernels installed and updated by installkernel
#    * Secure Boot with your own keys (sbctl); the kernel is signed on updates
#    * Kernel: Gentoo's distribution kernel, prebuilt or compiled
#    * Snapshots (snapper on btrfs, ZFS snapshots) and an update-system command
#    * Desktops and window managers (incl. Hyprland), login screens, dotfiles,
#      GPU drivers, applications, gaming, peripherals; GURU overlay
#    * Several users, each with a sudo level; LARBS-style bootstrap; presets
#
#  Usage
#    Boot the Gentoo minimal installation ISO (or any x86_64 live Linux with
#    curl, gpg, tar and cryptsetup), get online (net-setup), then as root:
#        bash gentoo-install.sh
#
#  Partition layouts (GPT)
#    UEFI + GRUB, /boot inside root ..... ESP 512M (/boot/efi) | root
#    UEFI + GRUB, unencrypted /boot ..... ESP 1G   (/boot)     | root
#    UEFI + systemd-boot/UKI/EFISTUB .... ESP 1G   (/boot/efi) | root
#    UEFI + ZFSBootMenu ................. ESP 1G   (/boot/efi) | root (ZFS pool)
#    BIOS + GRUB, /boot inside root ..... BIOS boot 2M | root
#    BIOS + GRUB, unencrypted /boot ..... BIOS boot 2M | /boot 1G ext4 | root
#  "root" is the filesystem itself, or a LUKS container that holds it.
#
#  !!! THE SELECTED DISK IS ERASED COMPLETELY !!!   Log: /tmp/gentoo-install.log
#  Keep backups.
# =============================================================================

SCRIPT_VERSION="1.0"
BACKTITLE="Gentoo Linux installer ${SCRIPT_VERSION}"
LOG=/tmp/gentoo-install.log
WARN_FILE=/tmp/gentoo-install.warnings
TARGET=/mnt/gentoo
CRYPT_NAME=cryptroot

# Sizes in MiB
ESP_SIZE_MIB=512        # ESP when it only holds the GRUB EFI binary
BOOT_SIZE_MIB=1024      # ESP / boot partition that also holds kernels + initramfs
BIOSBOOT_SIZE_MIB=2     # GPT "BIOS boot" partition (GRUB core.img)
MIN_ROOT_GIB=30         # source builds need room

BTRFS_OPTS="noatime,compress=zstd:1"
BTRFS_SUBVOLS=("@:/" "@home:/home" "@snapshots:/.snapshots" "@var_log:/var/log" "@var_cache_distfiles:/var/cache/distfiles" "@var_cache_binpkgs:/var/cache/binpkgs")

GUID_ESP=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
GUID_BIOS=21686148-6449-6E6F-744E-656564454649
GUID_LINUX=0FC63DAF-8483-4772-8E79-3D69D8477DE4
GUID_LUKS=CA7D7CCB-63ED-4C53-861C-1742536059CC

# Gentoo's stage3 tarballs and the key that signs them (Release Engineering,
# automated weekly release key). The tarball is used only if its signature
# checks out against this fingerprint.
GENTOO_MIRROR_DEFAULT=https://distfiles.gentoo.org
GENTOO_RELEASE_KEY=13EBBDBEDE7A12775DFDB1BABB572E0E2D182910
PROFILE_BASE=default/linux/amd64/23.0

# ZFS: in Gentoo's own repository (sys-fs/zfs, sys-fs/zfs-kmod)
ZPOOL=zroot
ZFS_BE=zroot/ROOT/gentoo
ZBM_VERSION=3.1.0
ZBM_GIT=https://github.com/zbm-dev/zfsbootmenu
ZBM_COMMIT=7174e420590a270ece3c6426bdb1d5cdd9ef27b0

# ---- user choices (defaults) ------------------------------------------------
DISK=""
INIT=openrc             # openrc | systemd
BUILD=bin               # bin (prebuilt packages where they exist) | source (compile everything)
CPU_JOBS=auto           # auto | number of parallel compile jobs (make -j)
EMERGE_JOBS=auto        # auto | number of packages built at the same time
CPU_MARCH=generic       # generic (x86-64) | v3 (x86-64-v3) | native (this CPU; source builds)
KERNEL=bin              # bin (gentoo-kernel-bin, prebuilt) | dist (gentoo-kernel, compiled)
GURU=0                  # 1 = enable the GURU community overlay
MIRROR=auto             # auto (Gentoo's CDN) | rank (mirrorselect: fastest mirrors)
FS=ext4                 # ext4 | btrfs | zfs
ENC=luks2               # none | luks1 | luks2
BOOTLOADER=grub         # grub | systemd-boot | uki | efistub | zfsbootmenu
GRUB_BOOT=encrypted     # encrypted | separate   (only GRUB + encryption)
SECUREBOOT=0            # 1 = sign the boot chain with your own keys (sbctl)
SNAPPER=0               # 1 = snapshots of / (snapper on btrfs, ZFS snapshots on ZFS)
SWAP=zram               # none | zram | file
SWAP_SIZE=4             # GiB, for SWAP=file
HOST_NAME=gentoo
KEYMAP=us
LOCALE=en_US.UTF-8
TIMEZONE=UTC
ROOT_PASS=""
USER_NAME=""            # primary user (first in USERS): owns the dotfiles
USERS=()                # login names, in order
declare -A U_FULL=() U_PASS=() U_SUDO=()   # per user: full name, password, sudo level (sudo|nopasswd|none)
BS_PROGS=""             # LARBS-style programs list: local path or http(s) URL of a CSV
BS_DOTFILES=""          # git URL of a dotfiles repository, copied into the primary user's home
BS_BRANCH=""            # branch of the dotfiles repository (empty = default)
BS_SHELL=bash           # login shell of the primary user: bash | zsh | fish
BS_POWER=0              # 1 = wheel may run shutdown/reboot/mount/update without a password
STANDALONE=0            # 1 = --bootstrap on an installed system (TARGET=/)
LUKS_PASS=""
NET="nm"                # nm | dhcpcd (+ iwd for Wi-Fi) | networkd (systemd only) | none
DESKTOP=none            # none, or a list of desktop/WM ids from desktop_table
DM=auto                 # login screen: auto | lightdm | sddm | gdm | greetd | ly | none
DOTS=""                 # dotfile presets from dots_table
EXTRA_PKGS=""           # packages (category/name)
GPU=auto                # auto | none | list of: intel amd nouveau nvidia vm
APPS=""                 # list chosen in the Applications menu
GAMING=""               # list of: steam wine lutris gamemode winetricks
PERIPH=""               # peripheral support: see periph_table

# ---- detected / computed ----------------------------------------------------
FIRMWARE=bios           # uefi | bios
EFI_BITS=64
ESP_PART="" ESP_NUM="" ESP_MOUNT="" ESP_SIZE=0
BIOSBOOT_PART="" BIOSBOOT_NUM=""
BOOT_PART="" BOOT_NUM="" BOOT_FS=""
ROOT_PART="" ROOT_NUM=""
ALL_PARTS=()
INSTALL_STARTED=0

# =============================================================================
#  Small helpers
# =============================================================================
die() {
	clear 2>/dev/null
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

# Hide credentials embedded in URLs (https://user:token@host/...) on stdin.
mask_secrets() { sed -u -E 's#(://)[^/@[:space:]"'"'"']+@#\1***@#g'; }

# Record a non-fatal problem (shown at the end of the installation).
warn() {
	printf 'WARNING: %s\n' "$*" >&2
	printf '%s\n' "$*" | mask_secrets >>"$WARN_FILE"
}

trim() {
	local s=$*
	s=${s#"${s%%[![:space:]]*}"}
	s=${s%"${s##*[![:space:]]}"}
	printf '%s' "$s"
}

encrypted()        { [[ $ENC != none ]]; }
grub_unlocks()     { [[ $BOOTLOADER == grub && $ENC != none && $GRUB_BOOT == encrypted ]]; }
# Methods started from the EFI system partition, mounted at /efi.
efi_loader()       { [[ $BOOTLOADER == systemd-boot || $BOOTLOADER == uki ]]; }
# Methods that need 64-bit UEFI firmware.
uefi_only()        { efi_loader || [[ $BOOTLOADER == zfsbootmenu ]]; }
boot_is_separate() { [[ $BOOTLOADER == grub && $ENC != none && $GRUB_BOOT == separate ]]; }
efi_arch()         { if [[ $EFI_BITS == 32 ]]; then echo ia32; else echo x64; fi; }
# Boot methods that Secure Boot is offered for (the firmware checks each step).
sb_capable()       { [[ $BOOTLOADER == grub ]] || efi_loader; }
secureboot_on()    { [[ $SECUREBOOT == 1 && $FIRMWARE == uefi && $EFI_BITS == 64 ]] && sb_capable; }
snapper_on()       { [[ $SNAPPER == 1 && $FS == btrfs ]]; }
zfs_on()           { [[ $FS == zfs ]]; }
zfs_snap_on()      { [[ $SNAPPER == 1 && $FS == zfs ]]; }
# A key file in the initramfs unlocks root a second time: after GRUB (encrypted
# /boot) or ZFSBootMenu (pool on LUKS) already asked for the passphrase.
needs_keyfile()    { grub_unlocks || { zfs_on && encrypted; }; }
guru_on()          { [[ $GURU == 1 ]] || periph_guru || ly_on || has "$DESKTOP" niri || has "$DESKTOP" river || has "$DESKTOP" leftwm; }
hypr_on()          { has "$DESKTOP" hyprland; }
ly_on()            { [[ $DM == ly ]]; }
systemd_on()       { [[ $INIT == systemd ]]; }

grub_efi_target() {
	if [[ $EFI_BITS == 32 ]]; then echo i386-efi; else echo x86_64-efi; fi
}

root_device() {
	if encrypted; then echo "/dev/mapper/$CRYPT_NAME"; else echo "$ROOT_PART"; fi
}

# /dev/sda + 2 -> /dev/sda2 ; /dev/nvme0n1 + 2 -> /dev/nvme0n1p2
part_name() {
	if [[ $1 =~ [0-9]$ ]]; then echo "${1}p${2}"; else echo "${1}${2}"; fi
}

# has "<space separated list>" <word>
has() { [[ " $1 " == *" $2 "* ]]; }
without() { # without "<list>" word -> the list minus that word
	local w out=""
	for w in $1; do [[ $w == "$2" ]] || out+="${out:+ }$w"; done
	printf '%s\n' "$out"
}

multilib_on() { has "$GAMING" wine || has "$GAMING" lutris; }

cpu_vendor() {
	case $(awk -F': ' '/^vendor_id/ { print $2; exit }' /proc/cpuinfo 2>/dev/null) in
		GenuineIntel) echo intel ;;
		AuthenticAMD) echo amd ;;
		*) echo other ;;
	esac
}

# GPU vendors found on the PCI bus -> driver keywords
detect_gpus() {
	local id out=""
	while read -r id; do
		case ${id:1:4} in
			8086) out+=" intel" ;;
			1002) out+=" amd" ;;
			10de) out+=" nouveau" ;;
			80ee | 15ad | 1af4 | 1234 | 1b36) out+=" vm" ;;
		esac
	done < <(lspci -nn 2>/dev/null | grep -E '\[03(00|02|80)\]' | grep -oE '\[[0-9a-f]{4}:[0-9a-f]{4}\]' || true)
	tr ' ' '\n' <<<"$out" | awk 'NF && !seen[$0]++' | paste -sd ' ' -
}

vm_type() {
	local v
	v=$(cat /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name 2>/dev/null | tr '\n' ' ') || true
	case $v in
		*innotek* | *VirtualBox*) echo virtualbox ;;
		*VMware*) echo vmware ;;
		*QEMU* | *KVM* | *Bochs* | *"Red Hat"*) echo qemu ;;
		*) echo none ;;
	esac
}

# Effective GPU driver list ("auto" only installs drivers when they are useful)
gpu_list() {
	case $GPU in
		none) ;;
		auto) if desktop_on || multilib_on; then detect_gpus; fi ;;
		*) echo "$GPU" ;;
	esac
}

nvidia_driver() { # prints the proprietary NVIDIA choice (nvidia | nvidia-dkms), if any
	local g
	for g in $(gpu_list); do
		if [[ $g == nvidia* ]]; then echo "$g"; return 0; fi
	done
	return 0
}

get_uuid() {
	local u
	u=$(blkid -c /dev/null -s UUID -o value "$1" 2>/dev/null) || true
	if [[ -z $u ]]; then
		echo "Could not read the UUID of $1" >&2
		return 1
	fi
	printf '%s\n' "$u"
}

partuuid_of() { blkid -c /dev/null -s PARTUUID -o value "$1" 2>/dev/null || true; }

# --bootstrap on an installed system: dialog may still be missing.
ensure_dialog() {
	command -v dialog >/dev/null 2>&1 && return 0
	echo "Installing 'dialog' ..."
	emerge --noreplace --quiet dev-util/dialog || die "Could not install 'dialog'."
}

swapfile_path() {
	if [[ $FS == btrfs ]]; then echo /swap/swapfile; else echo /swapfile; fi
}

ram_gib() {
	awk '/^MemTotal:/ { printf "%d", ($2 + 1048575) / 1048576 }' /proc/meminfo
}

# ---- CPU and build settings ----------------------------------------------------
cpu_threads() { nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1; }
cpu_cores() { # physical cores (threads when unknown)
	local c
	c=$(lscpu -p=Core,Socket 2>/dev/null | grep -v '^#' | sort -u | wc -l) || c=0
	if [[ $c =~ ^[0-9]+$ ]] && ((c > 0)); then echo "$c"; else cpu_threads; fi
}
cpu_model() { awk -F': ' '/^model name/ { print $2; exit }' /proc/cpuinfo 2>/dev/null | tr -s ' '; }
# Compile jobs that fit: one per thread, at most one per 2 GiB of RAM (a C++
# compile job can take that much).
jobs_recommended() {
	local t r m
	t=$(cpu_threads) r=$(ram_gib)
	[[ $r =~ ^[0-9]+$ ]] || r=2
	m=$((r / 2))
	((m < 1)) && m=1
	((t < m)) && m=$t
	echo "$m"
}
make_jobs() { if [[ $CPU_JOBS == auto ]]; then jobs_recommended; else echo "$CPU_JOBS"; fi; }
# Packages emerged side by side: useful with many cores, mostly while
# unpacking prebuilt packages.
emerge_jobs() {
	local j
	if [[ $EMERGE_JOBS != auto ]]; then echo "$EMERGE_JOBS"; return 0; fi
	j=$(make_jobs)
	if ((j >= 16)); then echo 3; elif ((j >= 8)); then echo 2; else echo 1; fi
}
# Does this CPU run x86-64-v3 code (AVX2 etc.)? glibc's loader knows.
v3_supported() {
	local ld out
	for ld in /lib64/ld-linux-x86-64.so.2 /usr/lib/ld-linux-x86-64.so.2 /lib/ld-linux-x86-64.so.2; do
		[[ -x $ld ]] || continue
		out=$("$ld" --help 2>/dev/null) || out=""
		grep -q 'x86-64-v3 (supported' <<<"$out" && return 0
		return 1
	done
	grep -qw avx2 /proc/cpuinfo 2>/dev/null && grep -qw bmi2 /proc/cpuinfo 2>/dev/null && grep -qw fma /proc/cpuinfo 2>/dev/null
}
march_flag() {
	case $CPU_MARCH in
		v3) echo x86-64-v3 ;;
		native) echo native ;;
		*) echo x86-64 ;;
	esac
}

# Run a command inside the target system with a clean environment.
in_target() {
	chroot "$TARGET" /usr/bin/env -i HOME=/root TERM=dumb LANG=C \
		PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin "$@"
}

# emerge inside the new system, unattended: USE, keyword and licence changes a
# package needs are written to /etc/portage and accepted (autounmask), so the
# install does not stop at a question.
gemerge() {
	in_target env CONFIG_PROTECT_MASK=/etc/portage emerge --quiet-build=y --autounmask=y --autounmask-continue=y \
		--autounmask-license=y --autounmask-keep-masks=y "$@"
}

# Run a command inside the target as <user> (makepkg, AUR helpers, dotfiles).
as_user() { # as_user <user> <command...>
	local u=$1
	shift
	chroot "$TARGET" /usr/bin/env -i HOME="/home/$u" USER="$u" LOGNAME="$u" TERM=dumb LANG=C.UTF-8 \
		PATH=/usr/local/sbin:/usr/local/bin:/usr/bin /usr/bin/setpriv --reuid="$u" --regid="$u" --init-groups -- "$@"
}

# =============================================================================
#  dialog wrappers
# =============================================================================
# ui: run dialog, print the answer on stdout, keep dialog's exit status.
ui() {
	# shellcheck disable=SC2069  # answer (stderr) -> caller, screen (stdout) -> terminal
	dialog --backtitle "$BACKTITLE" --colors --cancel-label "Back" "$@" 2>&1 >/dev/tty
}

msg() { # msg "text" [title] [height] [width]
	dialog --backtitle "$BACKTITLE" --colors --title " ${2:-Notice} " \
		--msgbox "$1" "${3:-10}" "${4:-70}" >/dev/tty 2>&1 || true
}

yesno() { # yesno "text" [title] [defaultno: 1] [height] [width]
	local -a opt=()
	if [[ ${3:-0} == 1 ]]; then opt=(--defaultno); fi
	dialog --backtitle "$BACKTITLE" --colors --title " ${2:-Confirm} " "${opt[@]}" \
		--yesno "$1" "${4:-10}" "${5:-70}" >/dev/tty 2>&1
}

# Ask for a secret twice; prints it on stdout.
ask_password() { # ask_password "title" "what"
	local p1 p2
	while true; do
		p1=$(ui --title " $1 " --insecure --passwordbox "Enter $2:" 9 64) || return 1
		if [[ -z $p1 ]]; then
			msg "The password must not be empty." "$1"
			continue
		fi
		p2=$(ui --title " $1 " --insecure --passwordbox "Repeat $2:" 9 64) || return 1
		if [[ $p1 == "$p2" ]]; then
			printf '%s' "$p1"
			return 0
		fi
		msg "The two entries did not match. Please try again." "$1"
	done
}

# Interactive shell; Ctrl-C inside it must not terminate the installer.
run_shell() { # run_shell <command...>
	trap ':' INT
	"$@" </dev/tty >/dev/tty 2>&1 || true
	trap 'exit 130' INT TERM
}

# =============================================================================
#  Environment checks
# =============================================================================
detect_firmware() {
	if [[ -d /sys/firmware/efi ]]; then
		FIRMWARE=uefi
		EFI_BITS=$(cat /sys/firmware/efi/fw_platform_size 2>/dev/null || echo 64)
		[[ $EFI_BITS == 32 ]] || EFI_BITS=64
	else
		FIRMWARE=bios
	fi
}

preflight() {
	local t
	[[ $EUID -eq 0 ]] || die "Run this installer as root."
	[[ $(uname -m) == x86_64 ]] || die "This installer supports x86_64 only."
	for t in curl gpg tar xz sfdisk chroot; do
		command -v "$t" >/dev/null 2>&1 || die "'$t' was not found. Boot the Gentoo minimal installation ISO (or a live Linux that has it)."
	done
	command -v dialog >/dev/null 2>&1 || die "'dialog' was not found. Boot the Gentoo minimal installation ISO, which has it."
	[[ -t 0 && -t 1 ]] || die "Run the installer from an interactive terminal."
	: >"$LOG" || die "Cannot write $LOG"
	: >"$WARN_FILE"
	detect_firmware
	local r
	r=$(ram_gib)
	if [[ $r =~ ^[0-9]+$ ]] && ((r > 0)); then
		SWAP_SIZE=$((r < 2 ? 2 : (r > 8 ? 8 : r)))
	fi
	if v3_supported; then CPU_MARCH=v3; fi
}

net_ok() {
	timeout 30 curl -fsSI -o /dev/null "$GENTOO_MIRROR_DEFAULT/releases/" 2>/dev/null
}

# Before dialog is used: plain text. The Gentoo ISO has net-setup.
ensure_network_text() {
	local a
	while ! net_ok; do
		clear
		cat <<-'EOF'
			Gentoo's mirrors cannot be reached.
			The installer downloads everything, so it needs internet access.

			  Wired:  usually works by itself (dhcpcd on the ISO).
			  Wi-Fi:  net-setup  (asks for the network and its passphrase)
			  Phone:  USB tethering appears as a wired connection.

		EOF
		read -r -p "[n]et-setup, [r]etry, [s]hell ('exit' returns), [q]uit: " a </dev/tty || a=q
		case $a in
			n | N) if command -v net-setup >/dev/null 2>&1; then run_shell net-setup; else echo "net-setup is not on this live system."; sleep 2; fi ;;
			s | S) run_shell bash -i ;;
			q | Q) exit 1 ;;
			*) ;;
		esac
	done
}

# Wi-Fi from the menu: the ISO's own net-setup tool.
wifi_setup() {
	clear
	if command -v net-setup >/dev/null 2>&1; then
		run_shell net-setup
	else
		echo "net-setup is not available here; set up Wi-Fi in the shell (iwctl, wpa_supplicant ...), then type 'exit'."
		run_shell bash -i
	fi
}

ensure_network() {
	dialog --backtitle "$BACKTITLE" --title " Network " --infobox "Checking the connection to Gentoo's mirrors ..." 3 60 >/dev/tty 2>&1
	while ! net_ok; do
		local c
		c=$(ui --title " No network " --cancel-label "Quit" --menu \
			"Gentoo's mirrors cannot be reached.\nThe installer downloads everything, so it needs internet access." 15 72 4 \
			retry "Try again" \
			wifi "Connect to a Wi-Fi network (net-setup)" \
			shell "Open a shell to fix it manually ('exit' returns here)" \
			quit "Quit the installer") || c=quit
		case $c in
			retry) ;;
			wifi) wifi_setup ;;
			shell)
				clear
				echo "Set up the network (net-setup, ip, ...), then type 'exit'."
				run_shell bash -i
				;;
			*) clear; exit 1 ;;
		esac
		dialog --backtitle "$BACKTITLE" --title " Network " --infobox "Checking the connection ..." 3 50 >/dev/tty 2>&1
	done
}

# =============================================================================
#  Partition layout
# =============================================================================
compute_layout() {
	local n=1
	ESP_PART="" ESP_NUM="" ESP_MOUNT="" ESP_SIZE=0
	BIOSBOOT_PART="" BIOSBOOT_NUM=""
	BOOT_PART="" BOOT_NUM="" BOOT_FS=""
	ALL_PARTS=()

	if [[ $FIRMWARE == uefi ]]; then
		ESP_NUM=$n
		ESP_PART=$(part_name "$DISK" "$n")
		n=$((n + 1))
		if boot_is_separate; then
			ESP_MOUNT=/boot          # GRUB with an unencrypted /boot: the ESP is /boot
			ESP_SIZE=$BOOT_SIZE_MIB
		elif efi_loader; then
			ESP_MOUNT=/efi           # systemd-boot / UKI: kernels are copied to the ESP
			ESP_SIZE=$BOOT_SIZE_MIB
		elif zfs_on; then
			ESP_MOUNT=/boot/efi      # kernels stay in /boot (in the pool); ZFSBootMenu's image goes here
			ESP_SIZE=$BOOT_SIZE_MIB
		else
			ESP_MOUNT=/boot/efi
			ESP_SIZE=$ESP_SIZE_MIB
		fi
		ALL_PARTS+=("$ESP_PART")
	else
		BIOSBOOT_NUM=$n
		BIOSBOOT_PART=$(part_name "$DISK" "$n")
		n=$((n + 1))
		ALL_PARTS+=("$BIOSBOOT_PART")
		if boot_is_separate; then
			BOOT_NUM=$n
			BOOT_PART=$(part_name "$DISK" "$n")
			n=$((n + 1))
			BOOT_FS=ext4
			ALL_PARTS+=("$BOOT_PART")
		fi
	fi
	ROOT_NUM=$n
	ROOT_PART=$(part_name "$DISK" "$n")
	ALL_PARTS+=("$ROOT_PART")
}

sfdisk_script() {
	local root_type=$GUID_LINUX
	if encrypted; then root_type=$GUID_LUKS; fi
	echo "label: gpt"
	if [[ -n $ESP_PART ]]; then
		echo "size=${ESP_SIZE}MiB, type=$GUID_ESP, name=\"EFI system partition\""
	fi
	if [[ -n $BIOSBOOT_PART ]]; then
		echo "size=${BIOSBOOT_SIZE_MIB}MiB, type=$GUID_BIOS, name=\"BIOS boot\""
	fi
	if [[ -n $BOOT_PART ]]; then
		echo "size=${BOOT_SIZE_MIB}MiB, type=$GUID_LINUX, name=\"boot\""
	fi
	echo "type=$root_type, name=\"gentoo\""
}

required_mib() {
	local mib=$((MIN_ROOT_GIB * 1024 + 8 + ESP_SIZE))
	if [[ -n $BIOSBOOT_PART ]]; then mib=$((mib + BIOSBOOT_SIZE_MIB)); fi
	if [[ -n $BOOT_PART ]]; then mib=$((mib + BOOT_SIZE_MIB)); fi
	if [[ $SWAP == file ]] && ! zfs_on; then mib=$((mib + SWAP_SIZE * 1024)); fi
	echo "$mib"
}

enc_desc() {
	case $ENC in
		luks1) echo "LUKS1 (PBKDF2)" ;;
		luks2) if grub_unlocks; then echo "LUKS2 (PBKDF2)"; else echo "LUKS2 (Argon2id)"; fi ;;
		*) echo "none" ;;
	esac
}

layout_row() { printf '  %-18s %-9s %s\n' "$1" "$2" "$3"; }

layout_lines() {
	local rootdesc
	if [[ -n $ESP_PART ]]; then
		layout_row "$ESP_PART" "${ESP_SIZE} MiB" "FAT32 -> $ESP_MOUNT (EFI system partition)"
	fi
	if [[ -n $BIOSBOOT_PART ]]; then
		layout_row "$BIOSBOOT_PART" "${BIOSBOOT_SIZE_MIB} MiB" "BIOS boot (no filesystem)"
	fi
	if [[ -n $BOOT_PART ]]; then
		case $BOOT_FS in
			vfat) layout_row "$BOOT_PART" "${BOOT_SIZE_MIB} MiB" "FAT32 -> /boot" ;;
			ext2) layout_row "$BOOT_PART" "${BOOT_SIZE_MIB} MiB" "ext2 -> /boot (legacy BIOS bootable)" ;;
			*) layout_row "$BOOT_PART" "${BOOT_SIZE_MIB} MiB" "ext4 -> /boot" ;;
		esac
	fi
	if zfs_on; then
		if encrypted; then rootdesc="$(enc_desc) -> ZFS pool $ZPOOL -> /"; else rootdesc="ZFS pool $ZPOOL -> /"; fi
	elif encrypted; then rootdesc="$(enc_desc) -> $FS -> /"; else rootdesc="$FS -> /"; fi
	layout_row "$ROOT_PART" "rest" "$rootdesc"
}

# =============================================================================
#  Menu labels
# =============================================================================
lbl_disk() {
	if [[ -n $DISK ]]; then
		printf '%s  %s' "$DISK" "$(lsblk -dno SIZE "$DISK" 2>/dev/null | tr -d ' ')"
	else
		printf '\\Z1(not set)\\Zn'
	fi
}
lbl_enc() {
	case $ENC in
		none) printf 'none' ;;
		*) printf '%s' "${ENC^^}"; [[ -n $LUKS_PASS ]] || printf ' \\Z1(passphrase not set)\\Zn' ;;
	esac
}
lbl_boot() {
	case $BOOTLOADER in
		systemd-boot) printf 'systemd-boot' ;;
		uki) printf 'UKI (unified kernel images, systemd-boot)' ;;
		zfsbootmenu) printf 'ZFSBootMenu' ;;
		*)
			if ! encrypted; then
				printf 'GRUB'
			elif [[ $GRUB_BOOT == encrypted ]]; then
				printf 'GRUB (/boot encrypted)'
			else
				printf 'GRUB (unencrypted /boot)'
			fi
			;;
	esac
}
lbl_sb() {
	if [[ $SECUREBOOT != 1 ]]; then printf 'off'
	elif secureboot_on; then printf 'on (sbctl, your own keys)'
	else printf '\\Z1on, but not possible with this firmware or boot loader\\Zn'; fi
}
lbl_snapper() {
	if [[ $SNAPPER != 1 ]]; then printf 'off'
	elif zfs_on; then printf 'ZFS snapshots before updates, bootable from ZFSBootMenu'
	elif [[ $FS != btrfs ]]; then printf '\\Z1on, but needs btrfs or ZFS\\Zn'
	else printf 'snapper: before updates + hourly'; fi
}
lbl_swap() {
	case $SWAP in
		file) printf 'swap file, %s GiB' "$SWAP_SIZE" ;;
		zram) printf 'zram (%s)' "$(systemd_on && echo zram-generator || echo zram-init)" ;;
		*) printf 'none' ;;
	esac
}
lbl_set()    { if [[ -n $1 ]]; then printf 'set'; else printf '\\Z1(not set)\\Zn'; fi; }
sudo_word() { case ${U_SUDO[$1]:-} in sudo) printf 'sudo' ;; nopasswd) printf 'sudo, no password' ;; *) printf 'no sudo' ;; esac; }
lbl_user() {
	local u out=""
	if ((${#USERS[@]} == 0)); then printf '\\Z1(not set)\\Zn'; return 0; fi
	for u in "${USERS[@]}"; do out+="${out:+, }$u ($(sudo_word "$u"))"; done
	printf '%s' "$out"
}
lbl_bootstrap() {
	local out=""
	[[ -n $BS_PROGS ]] && out+="programs list"
	[[ -n $BS_DOTFILES ]] && out+="${out:+, }dotfiles"
	[[ $BS_SHELL != bash ]] && out+="${out:+, }$BS_SHELL"
	[[ $BS_POWER == 1 ]] && out+="${out:+, }power cmds"
	printf '%s' "${out:-(none)}"
}
lbl_locale() { printf '%s' "$LOCALE"; }

lbl_mirror() { if [[ $MIRROR == auto ]]; then printf "Gentoo's CDN (distfiles.gentoo.org)"; else printf 'fastest mirrors (mirrorselect)'; fi; }
lbl_init() { if systemd_on; then printf 'systemd'; else printf 'OpenRC'; fi; }
lbl_build() {
	local m
	if [[ $BUILD == bin ]]; then m="prebuilt packages where they exist"; else m="compile everything"; fi
	printf '%s; %s jobs, %s' "$m" "$(make_jobs)" "$(march_flag)"
}
lbl_kernel() { if [[ $KERNEL == bin ]]; then printf 'gentoo-kernel-bin (prebuilt)'; else printf 'gentoo-kernel (compiled here)'; fi; }
lbl_overlays() {
	local o=""
	guru_on && o+="GURU"
	hypr_on && o+="${o:+, }hyproverlay"
	printf '%s' "${o:-none}"
}
lbl_net() {
	case $NET in
		nm) printf 'NetworkManager' ;;
		dhcpcd) printf 'dhcpcd + iwd' ;;
		networkd) printf 'systemd-networkd + iwd' ;;
		*) printf 'none' ;;
	esac
}
lbl_gpu() {
	local l
	case $GPU in
		none) printf 'none' ;;
		auto)
			l=$(detect_gpus)
			if ! desktop_on && ! multilib_on; then printf 'auto (only with a desktop)'; else printf 'auto (%s)' "${l:-nothing detected}"; fi
			;;
		*) printf '%s' "$GPU" ;;
	esac
}
lbl_list() { if [[ -n $1 ]]; then printf '%s' "$1"; else printf '(none)'; fi; }

# =============================================================================
#  Menus (each returns 1 when the user goes back without a change)
# =============================================================================
live_media_disk() {
	local src pk
	src=$(findmnt -no SOURCE /mnt/cdrom 2>/dev/null) || true
	[[ -b $src ]] || return 0
	pk=$(lsblk -no PKNAME "$src" 2>/dev/null | head -n1 | tr -d ' ')
	if [[ -n $pk ]]; then echo "/dev/$pk"; else echo "$src"; fi
}

menu_disk() {
	local live d size model tran desc
	local -a items=()
	live=$(live_media_disk)
	while read -r d; do
		[[ $d =~ ^/dev/(loop|ram|zram|sr|fd) ]] && continue
		[[ $(lsblk -dno TYPE "$d" 2>/dev/null | tr -d ' ') == disk ]] || continue
		[[ $(lsblk -dno RO "$d" 2>/dev/null | tr -d ' ') == 0 ]] || continue
		size=$(lsblk -dno SIZE "$d" | tr -d ' ')
		model=$(trim "$(lsblk -dno MODEL "$d" 2>/dev/null)")
		tran=$(trim "$(lsblk -dno TRAN "$d" 2>/dev/null)")
		desc="$size  ${model:-unknown model}${tran:+  [$tran]}"
		[[ $d == "$live" ]] && desc+="  (live media)"
		items+=("$d" "$desc")
	done < <(lsblk -dnpo NAME)

	if ((${#items[@]} == 0)); then
		msg "No suitable disk was found." "Disk"
		return 1
	fi

	local sel
	sel=$(ui --title " Target disk " --default-item "${DISK:-${items[0]}}" --menu \
		"Select the disk to install Gentoo Linux on.\n\Z1\ZbThe whole disk will be erased.\Zn" 0 0 0 "${items[@]}") || return 1

	if [[ -n $live && $sel == "$live" ]]; then
		msg "$sel holds the live system you booted from. Choose another disk." "Disk"
		return 1
	fi
	local bytes
	bytes=$(blockdev --getsize64 "$sel" 2>/dev/null || echo 0)
	if ((bytes < (MIN_ROOT_GIB + 2) * 1024 * 1024 * 1024)); then
		msg "$sel is too small. At least $((MIN_ROOT_GIB + 2)) GiB are needed." "Disk"
		return 1
	fi

	local current
	current=$(lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$sel" 2>/dev/null | head -n 12)
	if dialog --backtitle "$BACKTITLE" --colors --cr-wrap --no-collapse --title " Confirm disk " --defaultno \
		--yesno "Current content of $sel:\n\n$current\n\n\Z1\ZbEverything on $sel will be erased when the installation starts.\Zn\nUse this disk?" \
		0 78 >/dev/tty 2>&1; then
		DISK=$sel
		return 0
	fi
	return 1
}

menu_fs() {
	local c
	local -a items=(ext4 "Classic journaling filesystem"
		btrfs "Subvolumes (@, @home, ...), zstd compression, snapshots")
	if [[ $FIRMWARE == uefi && $EFI_BITS == 64 ]]; then
		items+=(zfs "ZFS pool, booted by ZFSBootMenu; can sit on LUKS2")
	fi
	c=$(ui --title " Filesystem " --default-item "$FS" --menu "Root filesystem:" 12 78 3 "${items[@]}") || return 1
	if [[ $c == zfs ]]; then
		menu_zfs_info || return 1
	elif zfs_on && [[ $BOOTLOADER == zfsbootmenu ]]; then
		BOOTLOADER=grub
		msg "ZFSBootMenu only boots ZFS, so the boot loader is now GRUB. Change it in the Bootloader item." "Boot loader"
	fi
	FS=$c
	if [[ $FS == btrfs && $SNAPPER != 1 ]] &&
		yesno "Take automatic btrfs snapshots with snapper (before every update-system run, plus hourly)?\n\nYou can change this later in the Snapshots item." "Snapshots"; then
		SNAPPER=1
	fi
	return 0
}

# ZFS: what changes, and the choices that go with it.
menu_zfs_info() {
	yesno "ZFS is in Gentoo's own repository (sys-fs/zfs); its kernel module is built for your kernel and rebuilt on every kernel update (dist-kernel).\n\n- Boot loader: \ZbZFSBootMenu\Zn, built on the new system. It can boot any snapshot.\n- With encryption the pool sits on \ZbLUKS2\Zn: ZFSBootMenu asks for the passphrase once.\n- The live system needs ZFS tools (zpool): the Gentoo LiveGUI ISO has them; the minimal ISO may not.\n- No swap file (zram instead) and no Secure Boot with ZFS.\n\nUse ZFS?" "ZFS" 0 18 76 || return 1
	if ! command -v zpool >/dev/null 2>&1; then
		msg "This live system has no ZFS tools (zpool). Boot a live system with ZFS, such as Gentoo's LiveGUI ISO, to install on ZFS." "ZFS" 9 72
		return 1
	fi
	BOOTLOADER=zfsbootmenu
	if [[ $SWAP == file ]]; then SWAP=zram; fi
	SECUREBOOT=0
	if [[ $SNAPPER != 1 ]] && yesno "Take a ZFS snapshot of the system before every update-system run (the last 10 are kept)? ZFSBootMenu can boot any of them." "Snapshots"; then
		SNAPPER=1
	fi
	return 0
}

menu_grub_boot() {
	local c
	c=$(ui --title " GRUB and encryption " --default-item "$GRUB_BOOT" --menu \
		"Where should the kernel and initramfs live?\n\n\Zbencrypted\Zn: everything except the ESP is encrypted. GRUB asks for the passphrase (US keyboard layout, unlocking takes ~10-30 s); LUKS2 is created with PBKDF2.\n\n\Zbseparate\Zn: a 1 GiB unencrypted /boot holds kernel + initramfs; the initramfs asks for the passphrase and LUKS2 keeps Argon2id." \
		19 78 2 \
		encrypted "/boot inside the encrypted root (GRUB unlocks it)" \
		separate "Unencrypted /boot partition") || return 1
	GRUB_BOOT=$c
}

menu_enc() {
	local c
	c=$(ui --title " Encryption " --default-item "$ENC" --menu "Encrypt the root partition?" 12 78 3 \
		none "No encryption" \
		luks1 "LUKS1 - PBKDF2, widest GRUB compatibility" \
		luks2 "LUKS2 - Argon2id (PBKDF2 when GRUB must unlock it)") || return 1
	ENC=$c
	if encrypted; then
		if [[ -z $LUKS_PASS ]] || ! yesno "An encryption passphrase is already set.\n\nKeep it?" "Passphrase"; then
			ask_luks_pass || true
		fi
		if [[ $BOOTLOADER == grub ]]; then menu_grub_boot || true; fi
	fi
	return 0
}

ask_luks_pass() {
	local p
	p=$(ask_password "Encryption passphrase" "the disk encryption passphrase") || return 1
	if ((${#p} < 8)) && ! yesno "This passphrase is shorter than 8 characters.\n\nUse it anyway?" "Weak passphrase" 1; then
		return 1
	fi
	LUKS_PASS=$p
}

menu_bootloader() {
	local c note=""
	if zfs_on; then
		msg "With ZFS the boot loader is ZFSBootMenu. To use another boot loader, choose ext4 or btrfs in the Filesystem item." "Boot loader" 9 70
		return 1
	fi
	local -a items=(grub "GRUB 2 - BIOS or UEFI; can unlock an encrypted /boot")
	if [[ $FIRMWARE == uefi && $EFI_BITS == 64 ]]; then
		items+=(
			systemd-boot "systemd-boot - plain UEFI menu; kernels on the ESP (/efi)"
			uki "UKI - one signed EFI file per kernel, listed by systemd-boot")
	else
		note="\n\nsystemd-boot and UKI need 64-bit UEFI and are hidden."
	fi
	c=$(ui --title " Boot loader " --default-item "$BOOTLOADER" --menu \
		"Boot loader (firmware: ${FIRMWARE^^}$([[ $FIRMWARE == uefi ]] && echo ", ${EFI_BITS}-bit")). Gentoo's installkernel adds each new kernel to it.${note}" \
		0 78 0 "${items[@]}") || return 1
	BOOTLOADER=$c
	case $BOOTLOADER in
		grub)
			if encrypted; then menu_grub_boot || true; fi
			;;
		systemd-boot)
			msg "The EFI system partition (1 GiB) is mounted at /efi. On every kernel update kernel-install copies the kernel and its initramfs there and writes a systemd-boot entry.$(encrypted && printf '%s' '\n\nThe root filesystem stays encrypted; the initramfs asks for the passphrase.')" "systemd-boot" 11 72
			;;
		uki)
			msg "Each kernel, its initramfs and the command line become one EFI file in /efi/EFI/Linux, which systemd-boot lists. With Secure Boot this one file is what the firmware checks. The command line is in /etc/kernel/cmdline.$(encrypted && printf '%s' '\n\nThe UKIs are unencrypted; the root filesystem stays encrypted.')" "Unified kernel images" 12 74
			;;
	esac
	if [[ $SECUREBOOT == 1 ]] && ! secureboot_on; then
		msg "Secure Boot is not possible with $(lbl_boot) on this computer, so it will be left off. It works with GRUB, systemd-boot and UKI on 64-bit UEFI." "Secure Boot" 10 72
	fi
	return 0
}

menu_secureboot() {
	if zfs_on; then
		msg "Secure Boot is not offered with ZFS: ZFSBootMenu starts the kernel itself (kexec), which the firmware does not check." "Secure Boot" 9 70
		return 1
	fi
	if [[ $FIRMWARE != uefi || $EFI_BITS != 64 ]]; then
		msg "Secure Boot needs 64-bit UEFI firmware. This computer started with ${FIRMWARE^^}${EFI_BITS:+ ($EFI_BITS-bit)}." "Secure Boot"
		return 1
	fi
	if ! sb_capable; then
		msg "Secure Boot is offered for GRUB, systemd-boot and UKI.\n\nChoose one of those boot loaders first." "Secure Boot" 10 72
		return 1
	fi
	if yesno "Sign the boot loader and kernels with your own keys (sbctl)?\n\n- Before installing, put the firmware's Secure Boot in \ZbSetup Mode\Zn (delete or reset the keys in the firmware settings). Then the installer enrolls your keys, plus Microsoft's so graphics cards and other option ROMs still start.\n- If it is not in Setup Mode, the keys are still made and everything is signed; enroll them later with: sudo sbctl enroll-keys -m\n- Afterwards, turn Secure Boot on in the firmware. Every kernel update is signed with your keys (installkernel).$([[ $BOOTLOADER == grub ]] && printf '%s' '\n\nWith GRUB, the modules it needs are built into the signed GRUB image.')" "Secure Boot" 0 19 76; then
		SECUREBOOT=1
	else
		SECUREBOOT=0
	fi
	return 0
}

menu_snapper() {
	if zfs_on; then
		if yesno "Take a ZFS snapshot of the system ($ZFS_BE) before every update-system run? The last 10 are kept, and ZFSBootMenu can boot any of them (Ctrl-S in its menu). /home is a separate dataset and is not rolled back." "Snapshots" 0 12 74; then SNAPPER=1; else SNAPPER=0; fi
		return 0
	fi
	if [[ $FS != btrfs ]]; then
		msg "Snapshots need btrfs or ZFS. Choose one of them in the Filesystem item first." "Snapshots"
		return 1
	fi
	if yesno "Take automatic btrfs snapshots of / with snapper?\n\n- one before every update-system run (the installer's update command)\n- hourly snapshots, the last few kept (timeline)\n- /home is a separate subvolume and is not rolled back\n\nRestore one with snapper from the running system, or from a live ISO." "Snapshots" 0 16 76; then
		SNAPPER=1
	else
		SNAPPER=0
	fi
	return 0
}

menu_swap() {
	local c s
	if zfs_on; then
		c=$(ui --title " Swap " --default-item "$SWAP" --menu "Swap space (a swap file is not offered on ZFS):" 11 70 2 \
			none "No swap" zram "Compressed swap in RAM") || return 1
		SWAP=$c
		return 0
	fi
	c=$(ui --title " Swap " --default-item "$SWAP" --menu "Swap space:" 12 70 3 \
		none "No swap" \
		zram "Compressed swap in RAM" \
		file "Swap file on the root filesystem") || return 1
	if [[ $c == file ]]; then
		s=$(ui --title " Swap file " --inputbox "Swap file size in GiB (1-128):" 9 50 "$SWAP_SIZE") || return 1
		if ! [[ $s =~ ^[0-9]+$ ]] || ((s < 1 || s > 128)); then
			msg "Please enter a whole number between 1 and 128." "Swap file"
			return 1
		fi
		SWAP_SIZE=$s
	fi
	SWAP=$c
}

# ---- kernel: Gentoo's distribution kernel ---------------------------------------
menu_kernel() {
	local c
	c=$(ui --title " Kernel " --default-item "$KERNEL" --menu "Gentoo's distribution kernel (sys-kernel/gentoo-kernel). Both are updated with the system, and installkernel adds every new version to the boot loader." 13 78 2 \
		bin "gentoo-kernel-bin - prebuilt by Gentoo; ready in a minute" \
		dist "gentoo-kernel - the same kernel compiled here (30-90 minutes)") || return 1
	KERNEL=$c
	return 0
}

# ---- mirrors ---------------------------------------------------------------------
menu_mirror() {
	local c
	c=$(ui --title " Mirrors " --default-item "$MIRROR" --menu "Where packages and sources are downloaded from:" 11 76 2 \
		auto "Gentoo's CDN (distfiles.gentoo.org) - fast almost everywhere" \
		rank "Time the mirrors and use the fastest (mirrorselect)") || return 1
	MIRROR=$c
	return 0
}

# ---- init, build settings, overlays ------------------------------------------------
menu_init() {
	local c
	c=$(ui --title " Init system " --default-item "$INIT" --menu "Init system of the new system. Gentoo supports both fully; the profile and stage3 are picked to match." 12 78 2 \
		openrc "OpenRC - Gentoo's own init (elogind for desktops)" \
		systemd "systemd - systemd-boot and UKI fit it naturally") || return 1
	INIT=$c
	if [[ $NET == networkd ]] && ! systemd_on; then NET="nm"; fi
	return 0
}

menu_build() {
	local c t k r rec v3=" (this CPU cannot run it)"
	t=$(cpu_threads) k=$(cpu_cores) r=$(ram_gib) rec=$(jobs_recommended)
	if v3_supported; then v3=" (this CPU can)"; fi
	while true; do
		c=$(ui --title " Build settings " --cancel-label "Done" --default-item packages --menu \
			"This computer: \Zb$(cpu_model)\Zn\n$k cores, $t threads, ${r} GiB RAM. Recommended: \Zb$rec\Zn compile jobs (one per thread, at most one per 2 GiB of RAM)." 17 78 5 \
			packages "$([[ $BUILD == bin ]] && echo "Prebuilt packages where they exist (fast)" || echo "Compile everything from source (slow, tuned)")" \
			cores "CPU cores to use: $([[ $CPU_JOBS == auto ]] && echo "auto ($rec)" || echo "$CPU_JOBS")" \
			parallel "Packages built at once: $([[ $EMERGE_JOBS == auto ]] && echo "auto ($(emerge_jobs))" || echo "$EMERGE_JOBS")" \
			cpu "Optimize for: $(march_flag)" \
			explain "What do these mean?") || return 0
		case $c in
			packages)
				c=$(ui --title " Packages " --default-item "$BUILD" --menu "Gentoo's binary host has most packages prebuilt for generic x86-64 (and x86-64-v3) CPUs. A package whose settings differ is compiled anyway." 13 78 2 \
					bin "Prebuilt where they exist - a desktop in well under an hour" \
					source "Compile everything - hours for a desktop, tuned to this CPU") || continue
				BUILD=$c
				;;
			cores)
				c=$(ui --title " CPU cores " --inputbox "Compile jobs to run at once (make -j). This computer has $t threads and ${r} GiB of RAM; 'auto' uses $rec.\n\nFewer jobs keep the computer responsive; more need more RAM." 12 70 "$CPU_JOBS") || continue
				if [[ $c == auto || ($c =~ ^[1-9][0-9]{0,2}$ && $c -le 512) ]]; then
					CPU_JOBS=$c
					if [[ $c != auto ]] && ((c > t)); then msg "$c jobs on $t threads: allowed, but rarely faster." "CPU cores"; fi
				else
					msg "Enter 'auto' or a number from 1 to 512." "CPU cores"
				fi
				;;
			parallel)
				c=$(ui --title " Parallel packages " --inputbox "How many packages emerge builds side by side (--jobs). 'auto': $(EMERGE_JOBS=auto emerge_jobs) for this computer. Each one uses the compile jobs above, limited by the load average." 11 70 "$EMERGE_JOBS") || continue
				if [[ $c == auto || $c =~ ^[1-9][0-9]?$ ]]; then EMERGE_JOBS=$c; else msg "Enter 'auto' or a number from 1 to 99." "Parallel packages"; fi
				;;
			cpu)
				c=$(ui --title " CPU optimization " --default-item "$CPU_MARCH" --menu "Instruction set the packages are built for (-march):" 13 78 3 \
					generic "x86-64 - runs on every 64-bit PC; matches Gentoo's prebuilt packages" \
					v3 "x86-64-v3 - AVX2 era (2015+)${v3}; prebuilt set exists" \
					native "This exact CPU - source builds only; prebuilt packages stay generic") || continue
				if [[ $c == v3 ]] && ! v3_supported; then msg "This CPU does not support x86-64-v3; programs built for it would not start." "CPU"; continue; fi
				CPU_MARCH=$c
				;;
			explain)
				msg "\ZbPrebuilt packages\Zn come from Gentoo's binary host and install in seconds. Where your settings (USE flags) differ from how they were built, emerge compiles that package instead.\n\n\ZbCPU cores\Zn sets make -j: how many compiler processes run at once. Each can need up to 2 GiB of RAM; too many and the build swaps or fails.\n\n\ZbPackages built at once\Zn lets emerge work on several packages in parallel, which helps most when unpacking many prebuilt ones.\n\n\ZbOptimize for\Zn: x86-64-v3 or native can make compiled code a few percent faster. Prebuilt packages exist for generic and v3 only." "Build settings" 20 76
				;;
		esac
	done
}

menu_overlays() {
	local msgx=""
	if yesno "Enable \ZbGURU\Zn, Gentoo's community overlay (user-contributed packages, like an AUR that is reviewed less strictly)?\n\nThe installer turns it on by itself when a choice needs it (Ly, niri, river, LeftWM and some tools)." "Overlays" 1 12 74; then GURU=1; else GURU=0; fi
	if hypr_on; then msgx="\n\nHyprland comes from the hyproverlay repository, which is enabled because Hyprland is selected."; fi
	msg "Overlays: $(lbl_overlays).$msgx" "Overlays" 10 70
	return 0
}

menu_hostname() {
	local c
	c=$(ui --title " Hostname " --inputbox "Hostname of the new system:" 9 60 "$HOST_NAME") || return 1
	if ! [[ $c =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]; then
		msg "Use letters, digits and '-' only (1-63 characters, no leading/trailing '-')." "Hostname"
		return 1
	fi
	HOST_NAME=$c
}

menu_keymap() {
	local -a maps=()
	local c
	mapfile -t maps < <(localectl list-keymaps 2>/dev/null ||
		find /usr/share/kbd/keymaps -type f -name '*.map.gz' -printf '%f\n' 2>/dev/null | sed 's/\.map\.gz$//' | sort -u)
	if ((${#maps[@]})); then
		c=$(ui --title " Keyboard " --default-item "$KEYMAP" --no-items --menu "Console keymap:" 0 0 0 "${maps[@]}") || return 1
	else
		c=$(ui --title " Keyboard " --inputbox "Console keymap (e.g. us, de-latin1, fr, uk):" 9 60 "$KEYMAP") || return 1
	fi
	[[ $c =~ ^[A-Za-z0-9._-]+$ ]] || return 1
	KEYMAP=$c
	# Use it right away, so passphrases typed in this installer match the boot prompt.
	loadkeys "$KEYMAP" >/dev/null 2>&1 || true
}

menu_locale() {
	local -a items=()
	local c
	if [[ -r /usr/share/i18n/SUPPORTED ]]; then
		mapfile -t items < <(awk '$2 == "UTF-8" { print $1 }' /usr/share/i18n/SUPPORTED | sort -u)
	fi
	if ((${#items[@]})); then
		c=$(ui --title " Locale " --default-item "$LOCALE" --no-items --menu "System locale:" 0 0 0 "${items[@]}") || return 1
	else
		c=$(ui --title " Locale " --inputbox "System locale (e.g. en_US.UTF-8):" 9 60 "$LOCALE") || return 1
		[[ $c =~ ^[A-Za-z_]+\.UTF-8(@[A-Za-z]+)?$ ]] || { msg "Please enter a UTF-8 locale such as en_US.UTF-8." "Locale"; return 1; }
	fi
	LOCALE=$c
}

menu_timezone() {
	local -a regions=(UTC Africa America Antarctica Arctic Asia Atlantic Australia Europe Indian Pacific)
	local -a cities=()
	local r c
	r=$(ui --title " Timezone " --default-item "${TIMEZONE%%/*}" --no-items --menu "Region:" 0 0 0 "${regions[@]}") || return 1
	if [[ $r == UTC ]]; then
		TIMEZONE=UTC
		return 0
	fi
	mapfile -t cities < <(cd "/usr/share/zoneinfo/$r" 2>/dev/null && find . -type f | sed 's|^\./||' | sort)
	if ((${#cities[@]} == 0)); then
		msg "No time zones found for $r." "Timezone"
		return 1
	fi
	c=$(ui --title " Timezone: $r " --default-item "${TIMEZONE#*/}" --no-items --menu "City:" 0 0 0 "${cities[@]}") || return 1
	TIMEZONE="$r/$c"
}

menu_rootpass() {
	local p
	p=$(ask_password "Root password" "the root password") || return 1
	ROOT_PASS=$p
}

sync_primary() {
	if ((${#USERS[@]})); then
		USER_NAME=${USERS[0]}
	else
		USER_NAME=""
	fi
}

valid_login() { # valid_login <name> [allow existing on this system: 1]
	if ! [[ $1 =~ ^[a-z_][a-z0-9_-]{0,30}$ ]]; then
		msg "Invalid login name. Start with a lowercase letter or _, then lowercase letters, digits, - or _ (max 31)." "User"
		return 1
	fi
	if [[ ${2:-0} != 1 ]] && { [[ $1 == root ]] || grep -q "^${1}:" /etc/passwd 2>/dev/null; }; then
		msg "'$1' is a reserved system account name." "User"
		return 1
	fi
	return 0
}

menu_sudo_level() { # menu_sudo_level <user> -> prints sudo|nopasswd|none
	ui --title " sudo for $1 " --default-item "${U_SUDO[$1]:-sudo}" --menu "Administrator rights for $1:" 12 72 3 \
		sudo "Administrator: sudo asks for the password (wheel)" \
		nopasswd "Administrator: sudo never asks for a password" \
		none "Regular user, no sudo"
}

# Add (no argument) or edit a user.
user_dialog() {
	local u=${1:-} n p lvl
	if [[ -z $u ]]; then
		u=$(ui --title " New user " --inputbox "Login name (lowercase letters, digits, '-', '_'):" 9 64) || return 1
		valid_login "$u" || return 1
		if [[ -n ${U_SUDO[$u]+x} ]]; then
			msg "'$u' is already in the list." "User"
			return 1
		fi
	fi
	n=$(ui --title " User $u " --inputbox "Full name (optional):" 9 64 "${U_FULL[$u]:-}") || return 1
	if [[ $n == *:* ]]; then
		msg "The full name must not contain ':'." "User"
		return 1
	fi
	if [[ -n ${U_PASS[$u]:-} ]] && yesno "Keep the current password of $u?" "User $u"; then
		p=${U_PASS[$u]}
	else
		p=$(ask_password "Password for $u" "the password for $u") || return 1
	fi
	lvl=$(menu_sudo_level "$u") || return 1
	if [[ -z ${U_SUDO[$u]+x} ]]; then USERS+=("$u"); fi
	U_FULL[$u]=$n
	U_PASS[$u]=$p
	U_SUDO[$u]=$lvl
	sync_primary
}

remove_user() {
	local u=$1 x
	local -a keep=()
	for x in "${USERS[@]}"; do [[ $x == "$u" ]] || keep+=("$x"); done
	USERS=("${keep[@]}")
	unset 'U_FULL[$u]' 'U_PASS[$u]' 'U_SUDO[$u]'
	sync_primary
}

make_primary() {
	local u=$1 x
	local -a order=("$u")
	for x in "${USERS[@]}"; do [[ $x == "$u" ]] || order+=("$x"); done
	USERS=("${order[@]}")
	sync_primary
}

menu_user() {
	local c u a
	local -a items=()
	while true; do
		items=()
		for u in "${USERS[@]}"; do
			items+=("$u" "${U_FULL[$u]:+${U_FULL[$u]} - }$(sudo_word "$u")$([[ $u == "${USERS[0]}" ]] && echo ' - primary')")
		done
		items+=("+add" "Add a user")
		c=$(ui --title " Users " --cancel-label "Done" --menu \
			"Accounts on the new system. The primary user (first) also gets the AUR helper and the dotfiles. Select a user to edit it." \
			0 0 0 "${items[@]}") || break
		if [[ $c == "+add" ]]; then
			user_dialog || true
			continue
		fi
		a=$(ui --title " $c " --menu "What to do with $c?" 12 60 4 \
			edit "Change name, password or sudo level" \
			primary "Make $c the primary user" \
			delete "Remove $c from the list") || continue
		case $a in
			edit) user_dialog "$c" || true ;;
			primary) make_primary "$c" ;;
			delete) if yesno "Remove $c?" "Users" 1; then remove_user "$c"; fi ;;
		esac
	done
	((${#USERS[@]} > 0))
}

# ---- LARBS-style bootstrap settings ---------------------------------------------
menu_bootstrap() {
	local c v re_url='^(https?|git)://[^[:space:]]+$|^git@[^[:space:]]+$'
	while true; do
		c=$(ui --title " Bootstrap (LARBS-style) " --cancel-label "Done" --menu \
			"After the base install: install a list of programs, copy a dotfiles repository into the primary user's home, set a login shell. Everything here is optional." \
			18 78 6 \
			progs "Programs list: ${BS_PROGS:-(none)}" \
			presets "Dotfile presets: $(lbl_dots)" \
			dotfiles "Own dotfiles repo: ${BS_DOTFILES:-(none)}${BS_BRANCH:+ ($BS_BRANCH)}" \
			shell "Login shell: $BS_SHELL" \
			power "Passwordless power/mount/update commands for wheel: $([[ $BS_POWER == 1 ]] && echo yes || echo no)" \
			example "Show the programs list format") || break
		case $c in
			presets) menu_dotfiles || true ;;
			progs)
				v=$(ui --title " Programs list " --inputbox "Path or http(s) URL of a programs CSV (see 'example'). Leave empty for none." 10 78 "$BS_PROGS") || continue
				v=$(trim "$v")
				if [[ -n $v && ! $v =~ ^https?:// && ! -f $v ]]; then
					msg "File not found: $v" "Programs list"
					continue
				fi
				if [[ -n $v && -f $v ]]; then v=$(readlink -f "$v"); fi
				BS_PROGS=$v
				;;
			dotfiles)
				v=$(ui --title " Dotfiles " --inputbox "Git URL of a dotfiles repository (copied into the primary user's home, like LARBS). Leave empty for none." 10 78 "$BS_DOTFILES") || continue
				v=$(trim "$v")
				if [[ -n $v && ! $v =~ $re_url ]]; then
					msg "That does not look like a git URL." "Dotfiles"
					continue
				fi
				BS_DOTFILES=$v
				if [[ -n $v ]]; then
					v=$(ui --title " Dotfiles " --inputbox "Branch (leave empty for the repository's default):" 9 60 "$BS_BRANCH") || continue
					v=$(trim "$v")
					if [[ -n $v && ! $v =~ ^[A-Za-z0-9._/-]+$ ]]; then msg "Invalid branch name." "Dotfiles"; continue; fi
					BS_BRANCH=$v
				else
					BS_BRANCH=""
				fi
				;;
			shell)
				v=$(ui --title " Login shell " --default-item "$BS_SHELL" --menu "Login shell for the primary user:" 11 50 3 \
					bash "GNU Bash" zsh "Z shell" fish "fish") || continue
				BS_SHELL=$v
				;;
			power)
				if yesno "Let members of wheel run shutdown, reboot, poweroff, mount, umount and update-system without typing a password (like LARBS)?" "Power commands" 1; then BS_POWER=1; else BS_POWER=0; fi
				;;
			example)
				dialog --backtitle "$BACKTITLE" --title " Programs list format " --cr-wrap --no-collapse --msgbox \
"One program per line:  TAG,PROGRAM,DESCRIPTION
Lines starting with # are ignored. TAG:
  (empty)  Gentoo package: category/name, or a plain name
           that Gentoo has in exactly one category
  A        package from the GURU overlay (enabled for it)
  G        git repository, built with make && make install
  P        Python program, in its own venv (as the user)
  F        Flatpak app from Flathub

This is LARBS's format; LARBS's progs.csv mostly works
(names Gentoo calls differently are reported and skipped).
Example:
#TAG,NAME IN REPO (OR GIT URL),PURPOSE
,www-client/firefox,\"is the web browser.\"
,vlc,\"plays videos and music.\"
A,gui-apps/fuzzel,\"is a launcher from GURU.\"
G,https://git.suckless.org/st,\"is the terminal.\"
P,yt-dlp,\"downloads videos.\"
F,com.spotify.Client,\"plays music.\"" 23 74 >/dev/tty 2>&1 || true
				;;
		esac
	done
	return 0
}

menu_network() {
	local c
	local -a items=(nm "NetworkManager (recommended; Wi-Fi via nmtui or applet)"
		dhcpcd "dhcpcd + iwd - small, no desktop applet")
	if systemd_on; then items+=(networkd "systemd-networkd + iwd"); fi
	items+=(none "Configure networking yourself later")
	c=$(ui --title " Network " --default-item "$NET" --menu "Network management on the new system:" 0 76 0 "${items[@]}") || return 1
	NET=$c
}


# ---- packages: Gentoo atoms (category/name) ---------------------------------------
# Every package in the tables below exists in Gentoo's repository, in GURU, or
# (Hyprland) in hyproverlay. In the new system, a name is checked against the
# repositories that are actually enabled before it is handed to emerge.
repo_has() { # repo_has <category/name>  (inside the target)
	local d
	for d in "$TARGET"/var/db/repos/*/; do
		[[ -d $d$1 ]] && return 0
	done
	return 1
}
# A plain name (from a programs list) -> category/name, when exactly one
# category of the enabled repositories has it.
resolve_atom() { # resolve_atom <name or category/name>
	local -a hits=()
	if [[ $1 == */* ]]; then
		repo_has "$1" && echo "$1"
		return 0
	fi
	mapfile -t hits < <(cd "$TARGET/var/db/repos" 2>/dev/null && compgen -G "*/*/$1" | cut -d/ -f2- | grep -v '^acct-' | sort -u)
	if ((${#hits[@]} == 1)); then echo "${hits[0]}"; fi
	return 0
}

# ---- desktops and window managers --------------------------------------------
# id|kind|label|packages that must install|packages installed when available
# kind: de = desktop environment, x11 / wl = X11 / Wayland window manager
desktop_table() {
	cat <<'EOF'
xfce|de|Xfce|xfce-base/xfce4-meta media-sound/pavucontrol gnome-base/gvfs gnome-base/gnome-keyring|
plasma|de|KDE Plasma|kde-plasma/plasma-meta kde-apps/konsole kde-apps/dolphin|kde-apps/ark kde-apps/kate kde-plasma/spectacle kde-apps/gwenview kde-apps/okular
gnome|de|GNOME|gnome-base/gnome gnome-extra/gnome-tweaks|
mate|de|MATE|mate-base/mate media-sound/pavucontrol|
cinnamon|de|Cinnamon|gnome-extra/cinnamon x11-terms/gnome-terminal gnome-base/gnome-keyring|
lxqt|de|LXQt|lxqt-base/lxqt-meta kde-frameworks/breeze-icons media-sound/pavucontrol-qt|
enlightenment|de|Enlightenment|x11-wm/enlightenment x11-terms/terminology|
i3|x11|i3|x11-wm/i3 x11-misc/i3status x11-misc/i3lock|x11-misc/i3blocks x11-misc/autotiling
bspwm|x11|bspwm|x11-wm/bspwm x11-misc/sxhkd x11-misc/polybar|x11-misc/dmenu
dwm|x11|dwm|x11-wm/dwm x11-terms/st x11-misc/dmenu x11-misc/slock|x11-misc/slstatus
awesome|x11|awesome|x11-wm/awesome|
qtile|x11|Qtile|x11-wm/qtile|dev-python/psutil dev-python/dbus-fast
herbstluftwm|x11|herbstluftwm|x11-wm/herbstluftwm|x11-misc/polybar
openbox|x11|Openbox|x11-wm/openbox x11-misc/obconf x11-misc/tint2|lxde-base/lxappearance-obconf
fluxbox|x11|Fluxbox|x11-wm/fluxbox|
icewm|x11|IceWM|x11-wm/icewm|
spectrwm|x11|spectrwm|x11-wm/spectrwm|
leftwm|x11|LeftWM (GURU)|x11-wm/leftwm|x11-misc/polybar
sway|wl|Sway|gui-wm/sway gui-apps/swaylock gui-apps/swayidle gui-apps/swaybg gui-apps/waybar|gui-libs/xdg-desktop-portal-wlr x11-misc/autotiling
hyprland|wl|Hyprland (hyproverlay)|gui-wm/hyprland gui-apps/hyprlock gui-apps/hypridle gui-apps/hyprpaper gui-apps/waybar gui-libs/xdg-desktop-portal-hyprland|sys-auth/hyprpolkitagent dev-qt/qtwayland
niri|wl|niri (GURU)|gui-wm/niri gui-apps/xwayland-satellite gui-apps/swaybg gui-apps/swaylock gui-apps/swayidle gui-apps/waybar|sys-apps/xdg-desktop-portal-gnome
river|wl|river (GURU)|gui-wm/river gui-apps/swaybg gui-apps/swaylock gui-apps/swayidle gui-apps/waybar|gui-libs/xdg-desktop-portal-wlr
labwc|wl|labwc|gui-wm/labwc gui-apps/swaybg gui-apps/swaylock gui-apps/swayidle gui-apps/waybar|gui-libs/xdg-desktop-portal-wlr
wayfire|wl|Wayfire|gui-wm/wayfire gui-apps/swaybg gui-apps/swaylock|gui-apps/wcm gui-libs/xdg-desktop-portal-wlr
EOF
}

# The "rounded" set every X11 / Wayland window manager gets: terminal, launcher,
# notifications, compositor/wallpaper, file manager, polkit agent, lock,
# volume/brightness/media keys, screenshots, fonts and themes.
WM_X11_TOOLS="x11-terms/alacritty x11-misc/rofi x11-misc/dunst x11-misc/picom media-gfx/feh xfce-base/thunar xfce-base/thunar-volman gnome-base/gvfs xfce-base/tumbler gnome-extra/polkit-gnome x11-misc/xss-lock app-misc/brightnessctl media-sound/playerctl media-sound/pamixer media-sound/pavucontrol media-gfx/maim x11-misc/xclip x11-misc/xdotool media-gfx/flameshot lxde-base/lxappearance x11-misc/dex x11-apps/xsetroot x11-misc/numlockx x11-apps/setxkbmap x11-apps/xrandr x11-misc/arandr sys-fs/udiskie media-fonts/fontawesome media-fonts/nerdfonts x11-themes/papirus-icon-theme x11-themes/arc-theme gnome-extra/nm-applet"
WM_WL_TOOLS="gui-apps/foot x11-terms/alacritty gui-apps/fuzzel gui-apps/wofi gui-apps/mako gui-apps/grim gui-apps/slurp gui-apps/swappy gui-apps/wl-clipboard app-misc/cliphist app-misc/brightnessctl media-sound/playerctl media-sound/pamixer media-sound/pavucontrol xfce-base/thunar xfce-base/thunar-volman gnome-base/gvfs xfce-base/tumbler gnome-extra/polkit-gnome app-misc/nwg-look gui-apps/kanshi gui-apps/wlogout sys-apps/xdg-desktop-portal sys-apps/xdg-desktop-portal-gtk x11-base/xwayland sys-fs/udiskie media-fonts/fontawesome media-fonts/nerdfonts x11-themes/papirus-icon-theme x11-themes/arc-theme gnome-extra/nm-applet"

desktop_on() { [[ -n $DESKTOP && $DESKTOP != none ]]; }
desktop_field() { desktop_table | awk -F'|' -v i="$1" -v f="$2" '$1 == i { print $f; exit }'; }
desktop_kind() { desktop_field "$1" 2; }
has_kind() { # has_kind de|x11|wl: is any selected desktop of that kind?
	local d
	desktop_on || return 1
	for d in $DESKTOP; do
		if [[ $(desktop_kind "$d") == "$1" ]]; then return 0; fi
	done
	return 1
}

lbl_desktop() {
	local d out=""
	if ! desktop_on; then
		printf 'none (console only)'
		return 0
	fi
	for d in $DESKTOP; do out+="${out:+, }$(desktop_field "$d" 3)"; done
	printf '%s' "$out"
}

# Login screen: an explicit choice, or picked from the selected desktops.
desktop_dm() {
	desktop_on || return 0
	case $DM in
		none) return 0 ;;
		lightdm | sddm | gdm | greetd | ly) echo "$DM" ;;
		*)
			if has "$DESKTOP" plasma || has "$DESKTOP" lxqt; then echo sddm
			elif has "$DESKTOP" gnome; then echo gdm
			elif has "$DESKTOP" hyprland && ! has_kind x11 && ! has_kind de; then echo sddm
			elif has_kind wl && ! has_kind x11 && ! has_kind de; then echo greetd
			else echo lightdm; fi
			;;
	esac
}
lbl_dm() {
	if ! desktop_on; then printf 'n/a (no desktop)'; return 0; fi
	case $DM in
		auto) printf 'auto: %s' "$(desktop_dm)" ;;
		none) printf 'none (console + startx)' ;;
		*) printf '%s' "$DM" ;;
	esac
}

dm_packages() {
	case $(desktop_dm) in
		lightdm) printf '%s\n' x11-misc/lightdm x11-misc/lightdm-gtk-greeter ;;
		sddm) echo gui-apps/sddm ;;
		gdm) echo gnome-base/gdm ;;
		ly) echo x11-misc/ly ;;
		greetd)
			printf '%s\n' gui-libs/greetd gui-apps/tuigreet
			if has_kind x11 || has_kind de; then echo x11-apps/xinit; fi
			;;
		*) if has_kind x11 || has_kind de; then echo x11-apps/xinit; fi ;;
	esac
	if [[ -n $(desktop_dm) ]] && ! systemd_on && [[ $(desktop_dm) != ly ]]; then echo gui-libs/display-manager-init; fi
	return 0
}

dm_service() { # the login screen's service: OpenRC's display-manager, or the systemd unit
	local dm
	dm=$(desktop_dm)
	[[ -n $dm ]] || return 0
	if systemd_on; then
		case $dm in
			ly) echo ly@tty2 ;;
			*) echo "$dm" ;;
		esac
	else
		case $dm in
			ly) echo ly ;;
			*) echo display-manager ;;
		esac
	fi
}

desktop_packages() {
	local d
	desktop_on || return 0
	printf '%s\n' x11-base/xorg-server media-libs/mesa media-video/pipewire media-video/wireplumber \
		x11-misc/xdg-user-dirs x11-misc/xdg-utils media-fonts/noto media-fonts/noto-emoji media-fonts/dejavu
	for d in $DESKTOP; do
		desktop_field "$d" 4 | tr ' ' '\n'
	done
	dm_packages
}

# Installed with install_available: a missing one is skipped with a warning.
desktop_extra_packages() {
	local d
	desktop_on || return 0
	for d in $DESKTOP; do
		desktop_field "$d" 5 | tr ' ' '\n'
	done
	if has_kind x11; then tr ' ' '\n' <<<"$WM_X11_TOOLS"; fi
	if has_kind wl; then tr ' ' '\n' <<<"$WM_WL_TOOLS"; fi
	if [[ $NET == nm ]]; then
		if has "$DESKTOP" xfce || has "$DESKTOP" mate || has "$DESKTOP" cinnamon; then
			echo gnome-extra/nm-applet
		fi
		if has "$DESKTOP" lxqt; then echo gui-apps/nm-tray; fi
	fi
}

menu_desktop() {
	local c id kind label
	local -a items=()
	while IFS='|' read -r id kind label _; do
		case $kind in
			de) label="Desktop:     $label" ;;
			x11) label="WM, X11:     $label" ;;
			*) label="WM, Wayland: $label" ;;
		esac
		items+=("$id" "$label")
	done < <(desktop_table)
	c=$(checklist "Desktops and window managers" "Pick any number (space toggles); each one becomes a session on the login screen. Window managers come with a bar, launcher, terminal, notifications, file manager, lock and screenshot tools." "$DESKTOP" "${items[@]}") || return 1
	DESKTOP=${c:-none}
	prune_dots
	if [[ -n $PRUNED ]]; then
		msg "These dotfile presets were removed because their desktop is no longer selected:\n\n$PRUNED" "Dotfiles" 11 70
	fi
	if hypr_on; then
		msg "Hyprland is not in Gentoo's own repository any more; it comes from the community 'hyproverlay' repository, which the installer enables for it." "Hyprland" 9 70
	fi
	if desktop_on && [[ $NET != nm ]]; then
		if yesno "Desktops work best with NetworkManager.\n\nSwitch the network setting to NetworkManager?" "Network"; then
			NET="nm"
		fi
	fi
	return 0
}

menu_dm() {
	local c now
	local -a items
	if ! desktop_on; then
		msg "Choose a desktop or window manager first." "Login screen"
		return 1
	fi
	now=$(DM=auto desktop_dm)
	items=(auto "Choose for me (now: $now)"
		lightdm "LightDM + GTK greeter - X11 and Wayland sessions"
		sddm "SDDM - KDE's login screen, X11 and Wayland"
		gdm "GDM - GNOME's login screen"
		greetd "greetd + tuigreet - text login, best for Wayland WMs"
		ly "Ly - text login with a session list (GURU), on tty2")
	items+=(none "None - log in on the console, start it yourself")
	c=$(ui --title " Login screen " --default-item "$DM" --menu "Display manager for: $(lbl_desktop)" 0 78 0 "${items[@]}") || return 1
	DM=$c
}

# ---- dotfile presets ------------------------------------------------------------
# id|for (desktop ids or "any")|label|sources|packages|note
# source = <git url>#<branch>#<how>; how: skel = repo's etc/skel -> ~,
# dots = the repo's dot-files -> ~, config = repo's config/ -> ~/.config,
# build = clone to ~/.local/src and make install, fish / bash = shell configs.
dots_table() {
	local gh=https://github.com gl=https://gitlab.com/garuda-linux/themes-and-settings/settings
	local cx="$gh/CachyOS/cachyos-alacritty-config#master#skel" cp="$gh/CachyOS/cachyos-picom-config#develop#skel"
	local cdev="x11-libs/libX11 x11-libs/libXft x11-libs/libXinerama media-libs/freetype media-libs/fontconfig media-libs/harfbuzz"
	cat <<EOF
cachyos-i3|i3|CachyOS i3|$gh/CachyOS/cachyos-i3wm-settings#develop#skel $cx $cp|x11-misc/polybar x11-misc/rofi x11-misc/dunst x11-misc/picom media-gfx/feh media-sound/pamixer gnome-extra/polkit-gnome x11-misc/xob x11-misc/dex app-misc/jq x11-terms/alacritty x11-misc/redshift media-fonts/hack|
cachyos-hyprland|hyprland|CachyOS Hyprland|$gh/CachyOS/cachyos-hyprland-settings#master#skel $cx|gui-apps/waybar gui-apps/swaybg gui-apps/swaylock gui-apps/mako gui-apps/wofi gui-apps/wlogout gui-apps/wl-clipboard x11-themes/kvantum gui-apps/qt6ct app-misc/brightnessctl media-sound/pamixer kde-plasma/polkit-kde-agent media-fonts/fontawesome media-fonts/noto-emoji x11-terms/alacritty gui-apps/grim gui-apps/slurp|
cachyos-niri|niri|CachyOS niri|$gh/CachyOS/cachyos-niri-settings#master#skel $cx|gui-apps/waybar gui-apps/swaybg gui-apps/swaylock gui-apps/mako gui-apps/wofi gui-apps/wlogout gui-apps/wl-clipboard dev-libs/bemenu x11-themes/kvantum gui-apps/qt6ct app-misc/brightnessctl media-sound/pamixer gui-apps/wob kde-plasma/polkit-kde-agent gui-apps/xwayland-satellite media-fonts/fontawesome media-fonts/noto-emoji x11-terms/alacritty|
cachyos-qtile|qtile|CachyOS Qtile|$gh/CachyOS/cachyos-qtile-settings#master#skel|x11-misc/picom x11-misc/rofi xfce-base/thunar x11-terms/alacritty dev-python/psutil dev-python/pulsectl dev-python/dbus-fast gnome-extra/polkit-gnome gnome-base/gnome-keyring media-gfx/feh gui-apps/qt6ct media-gfx/flameshot media-sound/playerctl x11-misc/dunst media-fonts/fontawesome media-fonts/roboto media-fonts/ibm-plex|
cachyos-wayfire|wayfire|CachyOS Wayfire|$gh/CachyOS/cachyos-wayfire-settings#develop#skel $cx|dev-libs/bemenu x11-themes/kvantum gui-apps/qt6ct x11-terms/alacritty x11-base/xwayland|
cachyos-openbox|openbox|CachyOS Openbox|$gh/CachyOS/cachyos-openbox-settings#develop#skel $cx $cp|x11-misc/dunst x11-misc/nitrogen x11-misc/rofi x11-misc/tint2 x11-misc/picom app-misc/brightnessctl media-gfx/scrot x11-misc/xclip x11-misc/xsettingsd x11-misc/xss-lock xfce-base/thunar xfce-base/thunar-volman xfce-base/tumbler media-video/mpv media-sound/pavucontrol xfce-base/xfce4-power-manager gnome-extra/polkit-gnome x11-terms/alacritty|
cachyos-kde|plasma|CachyOS KDE Plasma look|$gh/CachyOS/cachyos-kde-settings#develop#skel $cx|x11-terms/alacritty media-fonts/hack|
cachyos-xfce|xfce|CachyOS Xfce look|$gh/CachyOS/cachyos-xfce-settings#develop#skel $cx|x11-terms/alacritty x11-themes/kvantum gui-apps/qt6ct xfce-extra/xfce4-whiskermenu-plugin|
cachyos-fish|any|CachyOS fish config (login shell: fish)|$gh/CachyOS/cachyos-fish-config#main#fish|app-shells/fish app-misc/fastfetch sys-apps/bat sys-apps/eza app-shells/fzf|
eos-i3|i3|EndeavourOS i3|$gh/endeavouros-team/endeavouros-i3wm-setup#main#skel|x11-misc/i3blocks x11-misc/rofi x11-misc/dunst x11-misc/picom x11-misc/dex x11-terms/xfce4-terminal xfce-base/thunar x11-misc/xss-lock x11-misc/numlockx x11-misc/nitrogen media-gfx/feh media-gfx/scrot x11-misc/autotiling media-sound/playerctl gui-apps/clipman gnome-extra/polkit-gnome app-misc/brightnessctl|
eos-sway|sway|EndeavourOS Sway (community)|$gh/EndeavourOS-Community-Editions/sway#main#dots|gui-apps/waybar gui-apps/wofi gui-apps/mako gui-apps/foot gui-apps/swaybg gui-apps/swaylock gui-apps/swayidle gui-apps/grim gui-apps/slurp gui-apps/wl-clipboard|
eos-bspwm|bspwm|EndeavourOS bspwm (community)|$gh/EndeavourOS-Community-Editions/bspwm#main#dots|x11-misc/sxhkd x11-misc/polybar x11-misc/rofi x11-misc/dunst x11-misc/picom x11-misc/nitrogen media-gfx/feh x11-terms/xfce4-terminal|
eos-openbox|openbox|EndeavourOS Openbox (community)|$gh/EndeavourOS-Community-Editions/openbox#main#dots|x11-misc/tint2 x11-misc/obconf x11-misc/picom|
eos-awesome|awesome|EndeavourOS awesome (community)|$gh/EndeavourOS-Community-Editions/awesome#master#dots|x11-terms/xfce4-terminal x11-misc/rofi x11-misc/picom|
garuda-sway|sway|Garuda Sway|$gl/garuda-sway-settings.git#master#skel|gui-apps/waybar gui-apps/wofi gui-apps/mako gui-apps/foot gui-apps/swaybg gui-apps/swaylock gui-apps/swayidle gui-apps/grim gui-apps/slurp gui-apps/wl-clipboard|
garuda-i3|i3|Garuda i3|$gl/garuda-i3-settings.git#master#skel|x11-misc/rofi x11-misc/dunst x11-terms/kitty gnome-extra/polkit-gnome x11-misc/numlockx xfce-base/xfce4-power-manager x11-misc/dex media-sound/playerctl app-misc/brightnessctl x11-misc/dmenu|
garuda-bspwm|bspwm|Garuda bspwm|$gl/garuda-bspwm-settings.git#master#skel|x11-misc/sxhkd x11-misc/polybar x11-misc/rofi x11-misc/dunst x11-misc/picom|
garuda-wayfire|wayfire|Garuda Wayfire|$gl/garuda-wayfire-settings.git#master#skel|x11-terms/alacritty|
larbs|dwm|LARBS (Luke Smith): voidrice, dwm, st, dmenu|$gh/LukeSmithxyz/voidrice#master#dots $gh/LukeSmithxyz/dwm#master#build $gh/LukeSmithxyz/st#master#build $gh/LukeSmithxyz/dmenu#master#build $gh/LukeSmithxyz/dwmblocks#master#build|app-shells/zsh app-misc/lf media-gfx/nsxiv media-video/mpv app-text/zathura app-text/zathura-pdf-mupdf x11-misc/dunst x11-misc/picom x11-misc/xwallpaper media-gfx/maim x11-misc/xclip x11-misc/xdotool x11-misc/unclutter-xfixes media-sound/pulsemixer app-editors/neovim media-video/ffmpeg app-shells/fzf media-fonts/fontawesome media-fonts/noto-emoji $cdev|dwm, st, dmenu and dwmblocks are built from source into /usr/local; the login shell becomes zsh.
gh0stzk-bspwm|bspwm|gh0stzk bspwm (themed rices)|$gh/gh0stzk/dotfiles#master#config|x11-misc/polybar x11-misc/sxhkd x11-misc/picom x11-misc/rofi x11-misc/dunst gui-apps/eww media-gfx/feh x11-terms/alacritty x11-terms/kitty app-misc/jq x11-misc/xdotool media-gfx/maim x11-misc/xclip app-misc/brightnessctl media-sound/playerctl media-sound/pamixer x11-misc/xsettingsd|
titus-bash|any|Chris Titus mybash (.bashrc + starship prompt)|$gh/ChrisTitusTech/mybash#main#bash|app-shells/starship app-shells/fzf app-shells/zoxide sys-apps/bat sys-apps/eza app-misc/fastfetch app-misc/trash-cli app-text/tree app-text/multitail app-editors/neovim|
EOF
}
dots_field() { dots_table | awk -F'|' -v i="$1" -v f="$2" '$1 == i { print $f; exit }'; }

# Drop presets whose desktop is no longer selected. Sets PRUNED to their labels.
PRUNED=""
prune_dots() {
	local id d kept=""
	PRUNED=""
	for id in $DOTS; do
		d=$(dots_field "$id" 2)
		if [[ $d == any ]] || has "$DESKTOP" "$d"; then
			kept+="${kept:+ }$id"
		else
			PRUNED+="${PRUNED:+, }$(dots_field "$id" 3)"
		fi
	done
	DOTS=$kept
}

lbl_dots() {
	local n
	n=$(wc -w <<<"$DOTS")
	if ((n == 0)); then printf '(none)'; elif ((n == 1)); then dots_field "$DOTS" 3; else printf '%s presets' "$n"; fi
}

menu_dotfiles() {
	local c id for label d show added="" out
	local -a items=()
	while IFS='|' read -r id for label _; do
		show=0
		if [[ $for == any ]] || ! desktop_on; then show=1; fi
		for d in $for; do
			if has "$DESKTOP" "$d"; then show=1; fi
		done
		if ((show)); then
			if [[ $for == any ]]; then items+=("$id" "$label"); else items+=("$id" "$label  [$(desktop_field "$for" 3)]"); fi
		fi
	done < <(dots_table)
	c=$(checklist "Dotfiles" "Popular configurations, copied into the primary user's home at the end of the install (an existing file is kept as name.~1~). The packages they use are installed (from the AUR too when an AUR helper is chosen).$(desktop_on && echo " Only presets for your desktops are shown.")" "$DOTS" "${items[@]}") || return 1
	# A preset needs its window manager.
	for id in $c; do
		for d in $(dots_field "$id" 2); do
			[[ $d == any ]] && continue
			if ! has "$DESKTOP" "$d"; then
				if desktop_on; then DESKTOP+=" $d"; else DESKTOP=$d; fi
				added+="${added:+, }$(desktop_field "$d" 3)"
			fi
		done
	done
	DOTS=$c
	out=""
	if [[ -n $added ]]; then out+="Added to Desktops: $added.\n\n"; fi
	if has "$DOTS" larbs && has "$DOTS" cachyos-fish; then
		out+="LARBS uses zsh and the CachyOS preset uses fish; the login shell is set to fish (change it under Bootstrap).\n\n"
		BS_SHELL=fish
	elif has "$DOTS" larbs && [[ $BS_SHELL == bash ]]; then
		BS_SHELL=zsh
		out+="LARBS's dotfiles expect zsh: the login shell is now zsh.\n\n"
	elif has "$DOTS" cachyos-fish && [[ $BS_SHELL != fish ]]; then
		BS_SHELL=fish
		out+="The CachyOS fish preset sets the login shell to fish.\n\n"
	fi
	if [[ -n $out ]]; then msg "${out%\\n\\n}" "Dotfiles" 11 70; fi
	return 0
}

# checklist helper: checklist "title" "text" "<current list>" tag desc tag desc ...
checklist() {
	local title=$1 text=$2 cur=$3 out
	shift 3
	local -a items=()
	while (($# >= 2)); do
		if has "$cur" "$1"; then items+=("$1" "$2" on); else items+=("$1" "$2" off); fi
		shift 2
	done
	out=$(ui --title " $title " --separate-output --checklist "$text" 0 0 0 "${items[@]}") || return 1
	printf '%s\n' "$out" | paste -sd ' ' -
}

menu_gpu() {
	local c sel det
	det=$(detect_gpus)
	c=$(ui --title " GPU drivers " --default-item "$([[ $GPU == auto || $GPU == none ]] && echo "$GPU" || echo choose)" --menu \
		"Detected: \Zb${det:-no known GPU}\Zn\n\nAuto picks open-source drivers (nouveau for NVIDIA). Choose the NVIDIA driver yourself for best NVIDIA performance." 15 78 3 \
		auto "Install drivers for the detected GPUs" \
		choose "Pick the drivers yourself" \
		none "No GPU packages") || return 1
	if [[ $c != choose ]]; then
		GPU=$c
		return 0
	fi
	sel=$(checklist "GPU drivers" "Space selects. The NVIDIA driver (x11-drivers/nvidia-drivers) uses its open kernel module on RTX 20xx / GTX 16xx and newer." \
		"$([[ $GPU == auto || $GPU == none ]] && echo "$det" || echo "$GPU")" \
		intel "Intel - Mesa, Vulkan, VA-API" \
		amd "AMD - Mesa, RADV Vulkan, VA-API" \
		nouveau "NVIDIA open source (nouveau)" \
		nvidia "NVIDIA proprietary driver (nvidia-drivers)" \
		vm "Virtual machine - Mesa + guest tools") || return 1
	GPU=${sel:-none}
}

menu_apps() {
	local sel
	sel=$(checklist "Applications" "Space selects. Firefox, LibreOffice and other big ones are prebuilt (-bin) when you chose prebuilt packages." "$APPS" \
		firefox "Firefox web browser" \
		chrome "Google Chrome (Chromium left Gentoo's repository)" \
		thunderbird "Thunderbird mail" \
		vlc "VLC media player" \
		mpv "mpv media player" \
		libreoffice "LibreOffice suite" \
		gimp "GIMP image editor" \
		obs "OBS Studio" \
		keepassxc "KeePassXC password manager" \
		telegram-desktop "Telegram" \
		discord "Discord" \
		flatpak "Flatpak + Flathub remote" \
		git "Git" \
		htop "htop" \
		neovim "Neovim" \
		openssh "OpenSSH server (sshd service)" \
		cups "Printing: CUPS (service)") || return 1
	APPS=$sel
}

menu_gaming() {
	local sel
	sel=$(checklist "Gaming" "Space selects. Steam comes from Flathub (Flatpak): Gentoo's own Steam lives in an extra overlay. Wine and Lutris turn on 32-bit libraries for the packages that need them." "$GAMING" \
		steam "Steam (Flatpak, from Flathub)" \
		wine "Wine (wine-vanilla, with 32-bit support)" \
		winetricks "Winetricks" \
		lutris "Lutris game launcher" \
		gamemode "Feral GameMode") || return 1
	GAMING=$sel
}

menu_aur() {
	menu_overlays
}

menu_extras() {
	local c
	c=$(ui --title " Extra packages " --inputbox \
		"Additional packages, separated by spaces (optional): category/name, or a plain name Gentoo has in only one category.\nExamples: app-editors/vim sys-process/btop media-sound/spotify" \
		10 78 "$EXTRA_PKGS") || return 1
	c=$(trim "$(printf '%s' "$c" | tr ',' ' ' | tr -s ' ')")
	if ! pkg_words_ok "$c"; then
		msg "Use category/name (letters, digits and . _ + -), e.g. app-editors/vim." "Extra packages"
		return 1
	fi
	EXTRA_PKGS=$c
}

# =============================================================================
#  Validation and confirmation
# =============================================================================
# Everything the install will hand to emerge.
all_wanted_packages() {
	{
		desktop_packages
		desktop_extra_packages
		gpu_packages
		app_packages
		gaming_packages
		periph_packages
		local id
		for id in $DOTS; do dots_field "$id" 5 | tr ' ' '\n'; done
		tr ' ' '\n' <<<"$EXTRA_PKGS"
	} | awk 'NF && !seen[$0]++'
}

validate() {
	local -a missing=()
	[[ -n $DISK && -b $DISK ]] || missing+=("target disk")
	[[ -n $ROOT_PASS ]] || missing+=("root password")
	((${#USERS[@]} > 0)) || missing+=("at least one user account")
	if encrypted && [[ -z $LUKS_PASS ]]; then missing+=("encryption passphrase (or choose 'none')"); fi
	if ((${#missing[@]})); then
		msg "Please set first:\n$(printf '  - %s\\n' "${missing[@]}")" "Incomplete" 12 70
		return 1
	fi

	local nv count=0 g
	for g in $(gpu_list); do [[ $g == nvidia* ]] && count=$((count + 1)); done
	nv=$(nvidia_driver)
	if ((count > 1)); then
		msg "Select only one NVIDIA driver." "GPU drivers"
		return 1
	fi
	if [[ -n $nv ]] && has "$(gpu_list)" nouveau; then
		msg "The NVIDIA driver and nouveau cannot be installed together. Pick one." "GPU drivers"
		return 1
	fi
	if [[ -n $GAMING || -n $nv ]] && ! desktop_on; then
		yesno "You selected GPU or gaming packages without a desktop. Continue anyway?" "No desktop" 1 || return 1
	fi
	if has "$PERIPH" openlinkhub && has "$PERIPH" ckb-next; then
		msg "Pick ckb-next OR OpenLinkHub in Peripherals: they drive the same Corsair devices." "Peripherals"
		return 1
	fi
	if periph_gui && ! desktop_on; then
		yesno "Some peripheral tools you picked are desktop apps, and no desktop is selected. Continue anyway?" "No desktop" 1 || return 1
	fi

	if uefi_only && [[ $FIRMWARE != uefi || $EFI_BITS != 64 ]]; then
		msg "$(lbl_boot) needs 64-bit UEFI firmware, but this computer was started with ${FIRMWARE^^}$([[ $FIRMWARE == uefi ]] && echo " (${EFI_BITS}-bit)"). Choose another boot loader." "Boot loader"
		return 1
	fi
	if [[ $FIRMWARE == uefi && ! -d /sys/firmware/efi/efivars ]]; then
		yesno "The EFI variables (/sys/firmware/efi/efivars) are not available, so no UEFI boot entry can be written; the boot loader is also put at the firmware's fallback path (EFI/BOOT), which most computers start.\n\nContinue?" "UEFI" 0 11 72 || return 1
	fi
	if [[ $NET == networkd ]] && ! systemd_on; then
		msg "systemd-networkd needs systemd. Choose NetworkManager or dhcpcd (Network item)." "Network"
		return 1
	fi
	if [[ $SECUREBOOT == 1 ]] && ! secureboot_on; then
		yesno "Secure Boot is not possible with $(lbl_boot) on this computer and will be left off.\n\nContinue without it?" "Secure Boot" 0 || return 1
	fi
	if [[ $SNAPPER == 1 && $FS != btrfs && $FS != zfs ]]; then
		yesno "Snapshots need btrfs or ZFS; with $FS they are skipped.\n\nContinue without snapshots?" "Snapshots" 0 || return 1
	fi
	if zfs_on && [[ $BOOTLOADER != zfsbootmenu ]]; then
		msg "ZFS is booted by ZFSBootMenu. Choose ZFS again in the Filesystem item to set it up." "ZFS"
		return 1
	fi
	if [[ $BOOTLOADER == zfsbootmenu ]] && ! zfs_on; then
		msg "ZFSBootMenu only boots ZFS. Choose another boot loader, or ZFS in the Filesystem item." "Boot loader"
		return 1
	fi
	if zfs_on && [[ $SWAP == file ]]; then
		msg "A swap file on ZFS can hang the system under memory pressure. Choose zram or no swap (Swap item)." "Swap"
		return 1
	fi

	if zfs_on && ! command -v zpool >/dev/null 2>&1; then
		msg "This live system has no ZFS tools (zpool). Boot a live system with ZFS, such as Gentoo's LiveGUI ISO." "ZFS"
		return 1
	fi
	local g=""
	guru_on && g+="\n- GURU (community overlay): $(ly_on && echo 'Ly ')$(has "$DESKTOP" niri && echo 'niri ')$(has "$DESKTOP" river && echo 'river ')$(has "$DESKTOP" leftwm && echo 'LeftWM ')$([[ $GURU == 1 ]] && echo '(you enabled it)')"
	hypr_on && g+="\n- hyproverlay (Hyprland)"
	if [[ -n $g ]]; then
		yesno "These community repositories will be enabled:$g\n\nTheir packages are user-maintained and reviewed less strictly than Gentoo's own. Continue?" "Overlays" 0 13 76 || return 1
	fi
	if [[ $BUILD == source ]] && desktop_on; then
		yesno "Compiling a desktop from source takes hours (often 4-12 on an ordinary PC, more for KDE or GNOME) with $(make_jobs) jobs.\n\nContinue?" "Compile everything" 0 11 72 || return 1
	fi

	compute_layout
	local bytes need
	bytes=$(blockdev --getsize64 "$DISK" 2>/dev/null || echo 0)
	need=$(required_mib)
	if ((bytes / 1048576 < need)); then
		msg "$DISK is too small for this configuration: $((need / 1024 + 1)) GiB are required." "Disk too small"
		return 1
	fi
	if desktop_on && ((bytes / 1073741824 < 60)); then
		yesno "A Gentoo desktop installation should have at least 60 GiB (sources, packages and build space).\n\nContinue anyway?" "Small disk" 1 || return 1
	fi
	if grub_unlocks && [[ $LUKS_PASS == *[![:ascii:]]* ]]; then
		yesno "The passphrase contains non-ASCII characters. GRUB reads the passphrase with a US keyboard layout and may not be able to unlock the disk.\n\nContinue anyway?" "Passphrase" 1 || return 1
	fi
	if grub_unlocks && [[ $KEYMAP != us ]]; then
		msg "Note: GRUB asks for the passphrase using the US keyboard layout, not '$KEYMAP'. Characters that differ between the layouts must be typed at their US positions." "Keyboard layout" 9 72
	fi
	return 0
}

build_summary() {
	local model
	model=$(trim "$(lsblk -dno MODEL "$DISK" 2>/dev/null)")
	cat <<EOF
Disk        $DISK  $(lsblk -dno SIZE "$DISK" | tr -d ' ')  ${model}
            \Z1\ZbEVERYTHING ON THIS DISK WILL BE ERASED\Zn
Firmware    ${FIRMWARE^^}$([[ $FIRMWARE == uefi ]] && echo " (${EFI_BITS}-bit)")
Init        $(lbl_init); profile $(gentoo_profile)
Build       $(lbl_build)
Partitions  GPT:
$(layout_lines)
Boot loader $(lbl_boot); Secure Boot: $(lbl_sb)
Snapshots   $(lbl_snapper)
Swap        $(lbl_swap)
Kernel      $(lbl_kernel)
Mirrors     $(lbl_mirror)
Host        $HOST_NAME, keymap $KEYMAP, locale $(lbl_locale), $TIMEZONE
Users       $(lbl_user)
Bootstrap   $(lbl_bootstrap)$([[ -n $DOTS ]] && printf '; dotfiles: %s' "$DOTS")
Desktop     $(lbl_desktop)
Login       $(lbl_dm); network: $(lbl_net)
GPU         $(lbl_gpu)
Software    $(lbl_list "$(trim "$APPS $EXTRA_PKGS")"); gaming: $(lbl_list "$GAMING")
Peripherals $(lbl_periph)
Overlays    $(lbl_overlays)
EOF
}

confirm_install() {
	local word
	dialog --backtitle "$BACKTITLE" --colors --cr-wrap --no-collapse --title " Summary " \
		--yes-label "Continue" --no-label "Back" --defaultno \
		--yesno "$(build_summary)" 0 0 >/dev/tty 2>&1 || return 1
	word=$(ui --title " Last chance " --inputbox \
		"\Z1\ZbAll data on $DISK will be destroyed.\Zn\n\nType the disk name (\Zb${DISK#/dev/}\Zn) to start the installation:" \
		11 70) || return 1
	if [[ $word != "${DISK#/dev/}" ]]; then
		msg "The confirmation did not match. Nothing was changed." "Cancelled"
		return 1
	fi
	return 0
}

step_prepare_live() {
	local t
	local -a missing=()
	for t in sfdisk wipefs mkfs.vfat mkfs.ext4; do command -v "$t" >/dev/null 2>&1 || missing+=("$t"); done
	if [[ $FS == btrfs ]] && ! command -v mkfs.btrfs >/dev/null 2>&1; then missing+=(mkfs.btrfs); fi
	if encrypted && ! command -v cryptsetup >/dev/null 2>&1; then missing+=(cryptsetup); fi
	if zfs_on && ! command -v zpool >/dev/null 2>&1; then missing+=(zpool); fi
	if ((${#missing[@]})); then
		echo "The live system lacks: ${missing[*]}. Use the Gentoo minimal ISO (or LiveGUI for ZFS)." >&2
		return 1
	fi
	if zfs_on; then modprobe zfs; fi
	if [[ $MIRROR == rank ]] && command -v mirrorselect >/dev/null 2>&1; then
		echo "Timing Gentoo's mirrors (mirrorselect) ..."
		mirrorselect -s3 -b10 -o -D 2>/dev/null | sed -n 's/^GENTOO_MIRRORS="\(.*\)"$/\1/p' | tr ' ' '\n' | awk NF >/tmp/gentoo-install.mirrors || true
		if [[ -s /tmp/gentoo-install.mirrors ]]; then echo "Fastest: $(paste -sd' ' /tmp/gentoo-install.mirrors)"; else echo "mirrorselect found nothing; using Gentoo's CDN."; fi
	fi
	echo "All tools needed by the installer are present."
}

release_disk() {
	local disk=$1 dev mp type sw
	zfs_release_disk "$disk"
	# Unmount everything on the disk (deepest devices first) and disable swap.
	while read -r dev; do
		while read -r mp; do
			[[ -n $mp ]] || continue
			while read -r sw; do
				if [[ -n $sw ]]; then swapoff "$sw" 2>/dev/null || true; fi
			done < <(awk -v m="${mp%/}/" 'NR > 1 && index($1, m) == 1 { print $1 }' /proc/swaps 2>/dev/null || true)
			echo "Unmounting $mp"
			umount -R "$mp" 2>/dev/null || umount -Rl "$mp" 2>/dev/null || true
		done < <(findmnt -rn -o TARGET -S "$dev" 2>/dev/null | sort -r || true)
		swapoff "$dev" 2>/dev/null || true
	done < <(lsblk -lnpo NAME "$disk" | tac)
	# Close LUKS / LVM mappings stacked on it.
	while read -r dev type; do
		case $type in
			crypt)
				echo "Closing $dev"
				cryptsetup close "$dev" 2>/dev/null || dmsetup remove "$dev" 2>/dev/null || true
				;;
			lvm)
				echo "Removing $dev"
				dmsetup remove "$dev" 2>/dev/null || true
				;;
		esac
	done < <(lsblk -lnpo NAME,TYPE "$disk" | tac)
}

wait_for_partitions() {
	local p _
	partprobe "$DISK" 2>/dev/null || partx -u "$DISK" 2>/dev/null || blockdev --rereadpt "$DISK" 2>/dev/null || true
	udevadm settle 2>/dev/null || true
	for p in "${ALL_PARTS[@]}"; do
		for _ in $(seq 1 30); do
			[[ -b $p ]] && break
			sleep 0.5
		done
		if [[ ! -b $p ]]; then
			echo "Partition $p did not appear." >&2
			return 1
		fi
	done
}

step_partition() {
	local p
	echo "Releasing $DISK ..."
	release_disk "$DISK"
	if mountpoint -q "$TARGET"; then
		umount -R "$TARGET" 2>/dev/null || umount -Rl "$TARGET"
	fi

	echo "Removing old signatures ..."
	while read -r p; do
		[[ $p == "$DISK" ]] && continue
		wipefs -af "$p" >/dev/null 2>&1 || true
	done < <(lsblk -lnpo NAME "$DISK")
	wipefs -af "$DISK"

	echo "Partition script:"
	sfdisk_script | sed 's/^/    /'
	sfdisk_script | sfdisk --wipe always --wipe-partitions always "$DISK"
	wait_for_partitions

	if [[ $FIRMWARE == bios ]] && command -v parted >/dev/null; then
		# Some old BIOSes only boot GPT disks whose protective MBR is "active".
		parted -s "$DISK" disk_set pmbr_boot on || true
	fi
	echo
	lsblk -o NAME,SIZE,TYPE,PARTTYPENAME,PARTLABEL "$DISK" || lsblk "$DISK"
}

step_encrypt() {
	local -a fmt=(--batch-mode --type "$ENC")
	if [[ $ENC == luks2 ]]; then
		if grub_unlocks; then fmt+=(--pbkdf pbkdf2); else fmt+=(--pbkdf argon2id); fi
	fi
	echo "Creating $(enc_desc) container on $ROOT_PART ..."
	printf '%s' "$LUKS_PASS" | cryptsetup luksFormat "${fmt[@]}" --key-file=- "$ROOT_PART"
	echo "Opening it as /dev/mapper/$CRYPT_NAME ..."
	printf '%s' "$LUKS_PASS" | cryptsetup open --key-file=- "$ROOT_PART" "$CRYPT_NAME"
	cryptsetup luksDump "$ROOT_PART" | grep -E '^(Version|Cipher|PBKDF|Hash)|^[[:space:]]+(PBKDF|Cipher):' || true
}

mount_target() {
	local rootdev e sv mp
	rootdev=$(root_device)
	mkdir -p "$TARGET"
	if zfs_on; then
		: # the pool's datasets are mounted under $TARGET by zfs_create_pool
	elif [[ $FS == btrfs ]]; then
		mount -o "$BTRFS_OPTS,subvol=@" "$rootdev" "$TARGET"
		for e in "${BTRFS_SUBVOLS[@]:1}"; do
			sv=${e%%:*}
			mp=${e#*:}
			mkdir -p "$TARGET$mp"
			mount -o "$BTRFS_OPTS,subvol=$sv" "$rootdev" "$TARGET$mp"
		done
		if [[ $SWAP == file ]]; then
			mkdir -p "$TARGET/swap"
			mount -o "noatime,subvol=@swap" "$rootdev" "$TARGET/swap"
		fi
	else
		mount -o noatime "$rootdev" "$TARGET"
	fi
	if [[ -n $BOOT_PART ]]; then
		mkdir -p "$TARGET/boot"
		if [[ $BOOT_FS == vfat ]]; then
			mount -o umask=0077 "$BOOT_PART" "$TARGET/boot"
		else
			mount -o noatime "$BOOT_PART" "$TARGET/boot"
		fi
	fi
	if [[ -n $ESP_PART ]]; then
		mkdir -p "$TARGET$ESP_MOUNT"
		mount -o umask=0077 "$ESP_PART" "$TARGET$ESP_MOUNT"
	fi
}

make_swapfile() {
	local f
	f="$TARGET$(swapfile_path)"
	echo "Creating a ${SWAP_SIZE} GiB swap file at $(swapfile_path) ..."
	if [[ $FS == btrfs ]]; then
		btrfs filesystem mkswapfile --size "${SWAP_SIZE}g" "$f"
	else
		dd if=/dev/zero of="$f" bs=1M count=$((SWAP_SIZE * 1024)) status=none
		chmod 600 "$f"
		mkswap "$f"
	fi
	chmod 600 "$f"
}

step_filesystems() {
	local rootdev e
	rootdev=$(root_device)
	case $FS in
		ext4)
			mkfs.ext4 -F -L arch "$rootdev"
			;;
		btrfs)
			mkfs.btrfs -f -L arch "$rootdev"
			mkdir -p "$TARGET"
			mount "$rootdev" "$TARGET"
			for e in "${BTRFS_SUBVOLS[@]}"; do
				btrfs subvolume create "$TARGET/${e%%:*}"
			done
			if [[ $SWAP == file ]]; then btrfs subvolume create "$TARGET/@swap"; fi
			umount "$TARGET"
			;;
		zfs) zfs_create_pool ;;
	esac
	if [[ -n $ESP_PART ]]; then mkfs.vfat -F 32 -n EFI "$ESP_PART"; fi
	if [[ -n $BOOT_PART ]]; then
		case $BOOT_FS in
			vfat) mkfs.vfat -F 32 -n BOOT "$BOOT_PART" ;;
			ext2) mkfs.ext2 -F -L boot "$BOOT_PART" ;;
			*) mkfs.ext4 -F -L boot "$BOOT_PART" ;;
		esac
	fi

	echo "Mounting the new filesystems under $TARGET ..."
	mount_target
	if [[ $SWAP == file ]] && ! zfs_on; then make_swapfile; fi
	findmnt -R "$TARGET" || true
}

mount_chroot_fs() {
	local d
	if [[ $FIRMWARE == uefi && -d /sys/firmware/efi/efivars ]] && ! mountpoint -q /sys/firmware/efi/efivars; then
		mount -t efivarfs efivarfs /sys/firmware/efi/efivars || true
	fi
	for d in dev proc sys; do
		mkdir -p "$TARGET/$d"
		if ! mountpoint -q "$TARGET/$d"; then
			mount --rbind "/$d" "$TARGET/$d"
			mount --make-rslave "$TARGET/$d"
		fi
	done
	# A private /run, so package scripts cannot touch the live system's services.
	mkdir -p "$TARGET/run"
	if ! mountpoint -q "$TARGET/run"; then
		mount -t tmpfs -o mode=0755,nosuid,nodev tmpfs "$TARGET/run"
		if [[ -d /run/udev ]]; then
			mkdir -p "$TARGET/run/udev"
			mount --bind /run/udev "$TARGET/run/udev"
		fi
	fi
}




# ---- stage3 ------------------------------------------------------------------------
gentoo_mirror() {
	local m
	if [[ $MIRROR == rank && -s /tmp/gentoo-install.mirrors ]]; then
		m=$(head -n1 /tmp/gentoo-install.mirrors)
		[[ -n $m ]] && { echo "${m%/}"; return 0; }
	fi
	echo "$GENTOO_MIRROR_DEFAULT"
}

stage3_flavour() { # the stage3 that matches the choices
	local f=""
	if desktop_on; then f="desktop-"; fi
	if systemd_on; then f+=systemd; else f+=openrc; fi
	echo "$f"
}

# Gentoo's release key: the copy on the Gentoo ISO, else Web Key Directory.
# Accepted only with the pinned fingerprint.
release_key_import() { # release_key_import <gnupg home>
	local g=$1 f
	for f in /usr/share/openpgp-keys/gentoo-release.asc /var/lib/gentoo/gkeys/keyrings/gentoo/release/pubring.gpg; do
		[[ -s $f ]] && gpg --homedir "$g" --batch --quiet --import "$f" 2>/dev/null
	done
	gpg --homedir "$g" --batch --quiet --auto-key-locate clear,nodefault,wkd --locate-keys releng@gentoo.org >/dev/null 2>&1 || true
	gpg --homedir "$g" --batch --quiet --keyserver hkps://keys.gentoo.org --recv-keys "$GENTOO_RELEASE_KEY" >/dev/null 2>&1 || true
	gpg --homedir "$g" --with-colons --list-keys "$GENTOO_RELEASE_KEY" 2>/dev/null | awk -F: '$1 == "fpr" { print $10 }' | grep -qx "$GENTOO_RELEASE_KEY"
}

# A detached signature by the release key (or one of its subkeys)?
signed_by_release_key() { # signed_by_release_key <gnupg home> <file> <signature>
	local st
	st=$(gpg --homedir "$1" --batch --status-fd 1 --verify "$3" "$2" 2>/dev/null) || true
	awk -v k="$GENTOO_RELEASE_KEY" '$2 == "VALIDSIG" && $NF == k { ok = 1 } END { exit !ok }' <<<"$st"
}

step_stage3() {
	local base latest path g d=/tmp/gentoo-install-stage3 f
	base="$(gentoo_mirror)/releases/amd64/autobuilds"
	mkdir -p "$d"
	echo "Looking up the newest stage3 ($(stage3_flavour)) on $base ..."
	latest=$(curl -fsSL --retry 3 "$base/latest-stage3-amd64-$(stage3_flavour).txt")
	path=$(awk '/^[0-9]+T[0-9]+Z\/stage3-.*\.tar\.xz/ { print $1; exit }' <<<"$latest")
	if [[ -z $path ]]; then
		echo "Could not find the stage3 in latest-stage3-amd64-$(stage3_flavour).txt" >&2
		return 1
	fi
	f="$d/${path##*/}"
	echo "Downloading $path ..."
	curl -fL --retry 3 -C - -o "$f" "$base/$path"
	curl -fsSL --retry 3 -o "$f.asc" "$base/$path.asc"
	g=$(mktemp -d)
	if ! release_key_import "$g"; then
		echo "Gentoo's release key ($GENTOO_RELEASE_KEY) could not be found to check the stage3." >&2
		return 1
	fi
	if ! signed_by_release_key "$g" "$f" "$f.asc"; then
		echo "The stage3 is NOT signed by Gentoo's release key; refusing to use it." >&2
		rm -rf "$g"
		return 1
	fi
	rm -rf "$g"
	echo "Signature checked: Gentoo Release Engineering ($GENTOO_RELEASE_KEY)."
	echo "Unpacking into $TARGET ..."
	tar xpf "$f" --xattrs-include='*.*' --numeric-owner -C "$TARGET"
	rm -f "$f" "$f.asc"
	[[ -x $TARGET/usr/bin/emerge ]] || { echo "The stage3 has no emerge." >&2; return 1; }
}

# ---- Portage: make.conf, profile, repositories ------------------------------------
gentoo_profile() {
	local p=$PROFILE_BASE
	if desktop_on; then
		if has "$DESKTOP" plasma; then p+=/desktop/plasma
		elif has "$DESKTOP" gnome; then p+=/desktop/gnome
		else p+=/desktop; fi
	fi
	if systemd_on; then p+=/systemd; fi
	echo "$p"
}

write_make_conf() {
	local j e f=$TARGET/etc/portage/make.conf feat="parallel-fetch"
	j=$(make_jobs) e=$(emerge_jobs)
	local opts="--jobs=$e --load-average=$j"
	if [[ $BUILD == bin ]]; then
		opts+=" --getbinpkg"
		feat+=" getbinpkg binpkg-request-signature"
	fi
	[[ -f $f ]] && cp "$f" "$f.stage3"
	cat >"$f" <<MK
# /etc/portage/make.conf - written by gentoo-install.sh
# The stage3's original is kept as make.conf.stage3. See: man make.conf

# Compiler: -march=$(march_flag) ($(case $CPU_MARCH in native) echo "this CPU" ;; v3) echo "x86-64-v3" ;; *) echo "any x86-64 PC" ;; esac))
COMMON_FLAGS="-O2 -pipe -march=$(march_flag)"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
FCFLAGS="\${COMMON_FLAGS}"
FFLAGS="\${COMMON_FLAGS}"
RUSTFLAGS="\${RUSTFLAGS} -C target-cpu=$(march_flag)"

# CPU: $(cpu_model); $(cpu_threads) threads, $(ram_gib) GiB RAM.
# make -j: compile jobs at once. --jobs: packages at once. Change them here.
MAKEOPTS="-j$j -l$j"
EMERGE_DEFAULT_OPTS="$opts"
FEATURES="$feat"

# Packages: $([[ $BUILD == bin ]] && echo "prebuilt from Gentoo's binary host where they match, compiled otherwise" || echo "everything compiled here")
ACCEPT_LICENSE="-* @FREE @BINARY-REDISTRIBUTABLE"
USE="dist-kernel$(desktop_on && echo ' pipewire wayland X')$([[ $NET == nm ]] && echo ' networkmanager')"
VIDEO_CARDS="$(video_cards)"
INPUT_DEVICES="libinput"
GRUB_PLATFORMS="$(if [[ $FIRMWARE == uefi ]]; then if [[ $EFI_BITS == 32 ]]; then echo efi-32; else echo efi-64; fi; else echo pc; fi)"
L10N="$(locale_l10n)"
$(if [[ $MIRROR == rank && -s /tmp/gentoo-install.mirrors ]]; then printf 'GENTOO_MIRRORS="%s"\n' "$(paste -sd' ' /tmp/gentoo-install.mirrors)"; fi)
$(if secureboot_on; then printf '\n# Secure Boot: kernels and modules are signed with the sbctl keys\nSECUREBOOT_SIGN_KEY="/var/lib/sbctl/keys/db/db.key"\nSECUREBOOT_SIGN_CERT="/var/lib/sbctl/keys/db/db.pem"\nMODULES_SIGN_KEY="/var/lib/sbctl/keys/db/db.key"\nMODULES_SIGN_CERT="/var/lib/sbctl/keys/db/db.pem"\n'; fi)
MK
	echo "make.conf: MAKEOPTS=-j$j, $e package(s) at once, -march=$(march_flag), $([[ $BUILD == bin ]] && echo 'prebuilt packages' || echo 'source builds')"
}

locale_l10n() { # en_US.UTF-8 -> "en-US en"
	local l=${LOCALE%%.*}
	l=${l%%@*}
	if [[ $l == *_* ]]; then echo "${l/_/-} ${l%%_*}"; else echo "$l"; fi
}

# USE flags for single packages, written once (autounmask adds its own files).
write_package_use() {
	local d=$TARGET/etc/portage/package.use iu="dracut"
	mkdir -p "$d" "$TARGET/etc/portage/package.accept_keywords" "$TARGET/etc/portage/package.license"
	case $BOOTLOADER in
		grub) iu+=" grub" ;;
		systemd-boot) iu+=" systemd systemd-boot" ;;
		uki) iu+=" systemd systemd-boot uki" ;;
	esac
	{
		echo "# gentoo-install.sh"
		echo "sys-kernel/installkernel $iu"
		if [[ $BOOTLOADER == systemd-boot || $BOOTLOADER == uki ]]; then
			if systemd_on; then echo "sys-apps/systemd boot kernel-install"; else echo "sys-apps/systemd-utils boot kernel-install"; fi
		fi
		if zfs_on; then
			# ZFSBootMenu's EFI image needs systemd's EFI stub.
			if systemd_on; then echo "sys-apps/systemd boot"; else echo "sys-apps/systemd-utils boot"; fi
		fi
		if secureboot_on; then echo "sys-kernel/gentoo-kernel secureboot"; echo "sys-kernel/gentoo-kernel-bin secureboot"; fi
		if desktop_on; then echo "media-video/pipewire sound-server"; fi
		if has "$GAMING" wine; then echo "app-emulation/wine-vanilla wow64"; fi
		if encrypted; then echo "sys-fs/cryptsetup -static-libs"; fi
	} >"$d/00-gentoo-install"
	# Firmware licences (linux-firmware is redistributable; microcode too).
	printf 'sys-kernel/linux-firmware linux-fw-redistributable\nsys-firmware/intel-microcode intel-ucode\n' >"$TARGET/etc/portage/package.license/00-gentoo-install"
}

enable_overlays() {
	local need=0
	guru_on && need=1
	hypr_on && need=1
	((need)) || return 0
	gemerge --noreplace app-eselect/eselect-repository dev-vcs/git
	if guru_on; then
		in_target eselect repository enable guru
		# GURU packages are marked ~amd64 (testing): accept that for GURU only.
		echo '*/*::guru ~amd64' >"$TARGET/etc/portage/package.accept_keywords/00-guru"
	fi
	if hypr_on; then
		in_target eselect repository enable hyproverlay
		echo '*/*::hyproverlay ~amd64' >"$TARGET/etc/portage/package.accept_keywords/00-hyproverlay"
	fi
	in_target emaint sync --auto
}

step_portage() {
	mkdir -p "$TARGET/etc/portage/repos.conf"
	cp "$TARGET/usr/share/portage/config/repos.conf" "$TARGET/etc/portage/repos.conf/gentoo.conf"
	rm -f "$TARGET/etc/resolv.conf"
	cp -L /etc/resolv.conf "$TARGET/etc/resolv.conf" || true
	mount_chroot_fs
	write_make_conf
	write_package_use
	if [[ $CPU_MARCH == v3 && -f $TARGET/etc/portage/binrepos.conf/gentoobinhost.conf ]]; then
		# Gentoo's x86-64-v3 package set, built for AVX2-era CPUs.
		sed -i 's#/x86-64/*$#/x86-64-v3/#' "$TARGET/etc/portage/binrepos.conf/gentoobinhost.conf"
	fi
	if [[ $BUILD == bin && ! -f $TARGET/etc/portage/binrepos.conf/gentoobinhost.conf ]]; then
		warn "The stage3 has no binary host configured; packages will be compiled."
	fi
	echo "Getting the Gentoo repository (emerge-webrsync, signature checked) ..."
	in_target emerge-webrsync
	in_target eselect profile set "$(gentoo_profile)"
	echo "Profile: $(gentoo_profile)"
	if [[ $BUILD == bin ]]; then in_target getuto; fi
	enable_overlays
	# CPU instruction flags for source builds.
	gemerge --oneshot app-portage/cpuid2cpuflags
	echo "*/* $(in_target cpuid2cpuflags)" >"$TARGET/etc/portage/package.use/00-cpu-flags"
	echo "Updating the system to the profile ($(gentoo_profile)) ..."
	gemerge --update --deep --newuse @world
	gemerge --noreplace app-admin/sudo app-shells/bash-completion sys-apps/mlocate sys-fs/dosfstools
	gemerge --depclean || true
}

# ---- kernel, initramfs ---------------------------------------------------------------
write_dracut_conf() {
	mkdir -p "$TARGET/etc/dracut.conf.d"
	{
		echo "# Written by gentoo-install.sh"
		echo 'hostonly="yes"'
		echo 'compress="zstd"'
		if encrypted; then echo 'add_dracutmodules+=" crypt "'; fi
		if zfs_on; then echo 'add_dracutmodules+=" zfs "'; fi
		if [[ $FS == btrfs ]]; then echo 'add_dracutmodules+=" btrfs "'; fi
		if needs_keyfile; then echo "install_items+=\" /etc/cryptsetup-keys.d/$CRYPT_NAME.key /etc/crypttab \""; fi
		if [[ -n $(nvidia_driver) ]]; then echo 'omit_drivers+=" nouveau "'; fi
	} >"$TARGET/etc/dracut.conf.d/10-gentoo-install.conf"
	mkdir -p "$TARGET/etc/kernel"
	boot_cmdline >"$TARGET/etc/kernel/cmdline"
}

# Firmware and boot tools, installed before the kernel.
boot_tool_packages() {
	printf '%s\n' sys-kernel/linux-firmware sys-kernel/installkernel sys-kernel/dracut
	if [[ $(cpu_vendor) == intel ]]; then echo sys-firmware/intel-microcode; fi
	if desktop_on; then echo sys-firmware/sof-firmware; fi
	if encrypted; then echo sys-fs/cryptsetup; fi
	if [[ $FS == btrfs ]]; then echo sys-fs/btrfs-progs; fi
	if [[ $FIRMWARE == uefi ]]; then echo sys-boot/efibootmgr; fi
	case $BOOTLOADER in
		grub) echo sys-boot/grub ;;
		systemd-boot | uki) if systemd_on; then echo sys-apps/systemd; else echo sys-apps/systemd-utils; fi ;;
	esac
	if zfs_on; then
		if systemd_on; then echo sys-apps/systemd; else echo sys-apps/systemd-utils; fi
	fi
}

kernel_packages() {
	if [[ $KERNEL == bin ]]; then echo sys-kernel/gentoo-kernel-bin; else echo sys-kernel/gentoo-kernel; fi
	if zfs_on; then printf '%s\n' sys-fs/zfs sys-fs/zfs-kmod; fi
}

step_kernel() {
	local -a pkgs
	write_dracut_conf
	mapfile -t pkgs < <(boot_tool_packages)
	install_required "firmware and boot tools" "${pkgs[@]}"
	sb_prepare
	if efi_loader; then install_systemd_boot; fi
	mapfile -t pkgs < <(kernel_packages)
	echo "Kernel: $(lbl_kernel)"
	install_required "kernel" "${pkgs[@]}"
	if zfs_on; then zfs_target_setup; fi
}


set_locale() {
	local f="$TARGET/etc/locale.gen"
	mkdir -p "$TARGET/etc"
	{
		echo "# Written by gentoo-install.sh"
		echo "en_US.UTF-8 UTF-8"
		if [[ $LOCALE != en_US.UTF-8 ]]; then echo "$LOCALE UTF-8"; fi
	} >"$f"
	in_target locale-gen
	if systemd_on; then
		printf 'LANG=%s\n' "$LOCALE" >"$TARGET/etc/locale.conf"
	else
		printf 'LANG="%s"\nLC_COLLATE="C.UTF-8"\n' "$LOCALE" >"$TARGET/etc/env.d/02locale"
	fi
	in_target env-update >/dev/null 2>&1 || true
}

write_fstab() {
	local fs_uuid boot_uuid="" esp_uuid="" e sv mp
	if ! zfs_on; then fs_uuid=$(get_uuid "$(root_device)"); fi
	if [[ -n $BOOT_PART ]]; then boot_uuid=$(get_uuid "$BOOT_PART"); fi
	if [[ -n $ESP_PART ]]; then esp_uuid=$(get_uuid "$ESP_PART"); fi
	{
		echo "# /etc/fstab - generated by gentoo-install.sh"
		echo "# <device>                                 <dir>             <type> <options>                         <dump> <pass>"
		if zfs_on; then
			echo "# / and the other datasets of pool $ZPOOL are mounted by ZFS (zfs-mount.service)."
		elif [[ $FS == btrfs ]]; then
			for e in "${BTRFS_SUBVOLS[@]}"; do
				sv=${e%%:*}
				mp=${e#*:}
				printf 'UUID=%s  %-22s  btrfs  %s,subvol=/%s  0 0\n' "$fs_uuid" "$mp" "$BTRFS_OPTS" "$sv"
			done
			if [[ $SWAP == file ]]; then
				printf 'UUID=%s  %-22s  btrfs  noatime,subvol=/@swap  0 0\n' "$fs_uuid" "/swap"
			fi
		else
			printf 'UUID=%s  %-22s  ext4   defaults,noatime  0 1\n' "$fs_uuid" "/"
		fi
		if [[ -n $BOOT_PART ]]; then
			case $BOOT_FS in
				vfat) printf 'UUID=%s  %-22s  vfat   defaults,noatime,umask=0077  0 2\n' "$boot_uuid" "/boot" ;;
				ext2) printf 'UUID=%s  %-22s  ext2   defaults,noatime  0 2\n' "$boot_uuid" "/boot" ;;
				*) printf 'UUID=%s  %-22s  ext4   defaults,noatime  0 2\n' "$boot_uuid" "/boot" ;;
			esac
		fi
		if [[ -n $ESP_PART ]]; then
			printf 'UUID=%s  %-22s  vfat   defaults,noatime,umask=0077  0 2\n' "$esp_uuid" "$ESP_MOUNT"
		fi
		if [[ $SWAP == file ]] && ! zfs_on; then
			printf '%s  none  swap  defaults  0 0\n' "$(swapfile_path)"
		fi
	} >"$TARGET/etc/fstab"
	echo "--- /etc/fstab ---"
	cat "$TARGET/etc/fstab"
}

setup_crypt_target() {
	local kf="/etc/cryptsetup-keys.d/$CRYPT_NAME.key"
	if needs_keyfile; then
		# GRUB (or ZFSBootMenu) already asked for the passphrase; a key file inside
		# the initramfs, which lies on the encrypted disk, unlocks root a second
		# time without asking again (listed in /etc/crypttab).
		echo "Adding a key file for the initramfs ..."
		mkdir -p "$TARGET/etc/cryptsetup-keys.d"
		chmod 700 "$TARGET/etc/cryptsetup-keys.d"
		(umask 077 && head -c 64 /dev/urandom >"$TARGET$kf")
		local -a kopts=(--batch-mode --pbkdf-force-iterations 1000)
		if [[ $ENC == luks2 ]]; then kopts+=(--pbkdf pbkdf2); fi
		printf '%s' "$LUKS_PASS" | cryptsetup luksAddKey "${kopts[@]}" --key-file=- "$ROOT_PART" "$TARGET$kf"
		chmod 400 "$TARGET$kf"
		# The initramfs holds the key: only root may read it.
		mkdir -p "$TARGET/etc/kernel/postinst.d"
		printf '#!/bin/sh\n# gentoo-install.sh: the initramfs contains the disk key file; keep it root-only.\nchmod 600 /boot/initramfs-* /efi/*/*/initrd* /efi/EFI/Linux/*.efi 2>/dev/null\nexit 0\n' \
			>"$TARGET/etc/kernel/postinst.d/99-initramfs-permissions"
		chmod 755 "$TARGET/etc/kernel/postinst.d/99-initramfs-permissions"
	fi
	# dracut's crypt module reads this (hostonly) to unlock root in the initramfs.
	local u
	u=$(get_uuid "$ROOT_PART")
	if needs_keyfile; then
		printf '# gentoo-install.sh\n%s UUID=%s %s luks,discard\n' "$CRYPT_NAME" "$u" "$kf" >"$TARGET/etc/crypttab"
	else
		printf '# gentoo-install.sh\n%s UUID=%s none luks,discard\n' "$CRYPT_NAME" "$u" >"$TARGET/etc/crypttab"
	fi
}







# Pools left imported by an earlier attempt that sit on this disk.
zfs_release_disk() {
	command -v zpool >/dev/null || return 0
	local pool st
	while read -r pool; do
		[[ -n $pool ]] || continue
		st=$(zpool status -P "$pool" 2>/dev/null) || continue
		if grep -q -e "$1" -e "/dev/mapper/$CRYPT_NAME" -e /dev/disk/by-partuuid <<<"$st"; then
			echo "Exporting ZFS pool $pool"
			zpool export -f "$pool" 2>/dev/null || true
		fi
	done < <(zpool list -H -o name 2>/dev/null || true)
}

zfs_vdev() {
	if encrypted; then
		echo "/dev/mapper/$CRYPT_NAME"
	else
		local u
		u=$(partuuid_of "$ROOT_PART")
		if [[ -n $u && -e /dev/disk/by-partuuid/$u ]]; then echo "/dev/disk/by-partuuid/$u"; else echo "$ROOT_PART"; fi
	fi
}

# Pool and datasets. The boot environment zroot/ROOT/arch holds / and /boot,
# so a snapshot of it holds the kernels too; /home and the logs are separate.
zfs_create_pool() {
	local dev
	dev=$(zfs_vdev)
	# The same host id on the live system and the new one: the pool imports cleanly.
	zgenhostid -f
	echo "Creating ZFS pool $ZPOOL on $dev ..."
	zpool create -f -o ashift=12 -o autotrim=on \
		-O compression=lz4 -O acltype=posixacl -O xattr=sa -O relatime=on -O dnodesize=auto \
		-O normalization=formD -O mountpoint=none -O canmount=off \
		-R "$TARGET" "$ZPOOL" "$dev"
	zfs create -o mountpoint=none "$ZPOOL/ROOT"
	zfs create -o mountpoint=/ -o canmount=noauto "$ZFS_BE"
	zfs mount "$ZFS_BE"
	zfs create -o mountpoint=/home "$ZPOOL/home"
	zfs create -o mountpoint=/var -o canmount=off "$ZPOOL/var"
	zfs create "$ZPOOL/var/log"
	zfs create -o canmount=off "$ZPOOL/var/cache"
	zfs create -o compression=off "$ZPOOL/var/cache/distfiles"
	zfs create -o compression=off "$ZPOOL/var/cache/binpkgs"
	zpool set bootfs="$ZFS_BE" "$ZPOOL"
	mkdir -p /etc/zfs
	zpool set cachefile=/etc/zfs/zpool.cache "$ZPOOL"
	zfs list -o name,mountpoint,canmount -r "$ZPOOL"
}

# The new system: host id, pool cache, and the services that import and mount
# the pool (sys-fs/zfs ships OpenRC scripts and systemd units).
zfs_target_setup() {
	cp "${LIVE_ROOT:-}/etc/hostid" "$TARGET/etc/hostid"
	mkdir -p "$TARGET/etc/zfs"
	cp "${LIVE_ROOT:-}/etc/zfs/zpool.cache" "$TARGET/etc/zfs/zpool.cache"
	if systemd_on; then
		in_target systemctl enable zfs-import-cache.service zfs-import.target zfs-mount.service zfs.target
	else
		in_target rc-update add zfs-import boot
		in_target rc-update add zfs-mount boot
	fi
}

# update-system: a snapshot of the system (snapper or ZFS), then the update.
write_update_tools() { # write_update_tools <root dir>
	local root=$1 snap=none
	if snapper_on; then snap=snapper; elif zfs_snap_on; then snap=zfs; fi
	mkdir -p "$root/usr/local/bin" "$root/usr/local/libexec/gentoo-install"
	cat >"$root/usr/local/libexec/gentoo-install/snapshot" <<EOF
#!/bin/sh
# gentoo-install.sh: snapshot the system before update-system changes it.
# ZFS: the running boot environment, the newest KEEP kept (ZFSBootMenu boots
# them: select the environment, Ctrl-S). snapper: a "number" snapshot.
KEEP=10
METHOD=$snap
EOF
	cat >>"$root/usr/local/libexec/gentoo-install/snapshot" <<'EOF'
case $METHOD in
	zfs)
		[ "$(findmnt -no FSTYPE /)" = zfs ] || exit 0
		be=$(findmnt -no SOURCE /) || exit 0
		zfs snapshot "$be@update-$(date +%Y%m%d-%H%M%S)" || exit 0
		zfs list -H -t snapshot -o name -s creation -d 1 "$be" 2>/dev/null | grep -F "$be@update-" |
			head -n -"$KEEP" | while read -r s; do zfs destroy "$s" || true; done
		echo "Snapshot taken of $be."
		;;
	snapper)
		snapper -c root create -c number -d "before update-system" && echo "snapper snapshot taken."
		;;
esac
exit 0
EOF
	chmod 755 "$root/usr/local/libexec/gentoo-install/snapshot"
	cat >"$root/usr/local/bin/update-system" <<'EOF'
#!/bin/sh
# update-system [-y]   (written by gentoo-install.sh)
# Takes a snapshot (if set up), syncs the repositories and updates everything,
# then removes what is no longer needed. -y: do not ask before emerging.
[ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
ask=--ask
[ "${1:-}" = -y ] && ask=
/usr/local/libexec/gentoo-install/snapshot
emerge --sync || exit 1
# shellcheck disable=SC2086
emerge $ask --verbose --update --deep --newuse @world || exit 1
# shellcheck disable=SC2086
emerge $ask --depclean
echo "Done. If a new kernel was installed, reboot to use it."
EOF
	chmod 755 "$root/usr/local/bin/update-system"
}

# Set a password. The password travels on stdin only: never in a command line,
# never in the log. chpasswd stores only the hash (/etc/shadow).
set_password() { # set_password <user> <password>
	printf '%s:%s\n' "$1" "$2" | in_target chpasswd
	if ! awk -F: -v u="$1" '$1 == u && $2 ~ /^\$[^$]+\$/ { ok = 1 } END { exit !ok }' "$TARGET/etc/shadow"; then
		echo "The password of '$1' was not stored in /etc/shadow." >&2
		return 1
	fi
	echo "Password set for '$1'."
}

setup_users() {
	local base="" g u groups shell=/bin/bash
	for g in audio video input storage users plugdev; do
		if grep -q "^${g}:" "$TARGET/etc/group"; then base+="${base:+,}$g"; fi
	done
	for u in "${USERS[@]}"; do
		groups=$base
		if [[ ${U_SUDO[$u]} != none ]]; then groups="wheel,$groups"; fi
		if grep -q "^${u}:" "$TARGET/etc/passwd"; then
			in_target usermod -a -G "$groups" "$u"
			if [[ -n ${U_FULL[$u]} ]]; then in_target usermod -c "${U_FULL[$u]}" "$u"; fi
		else
			in_target useradd -m -s "$shell" -G "$groups" -c "${U_FULL[$u]}" "$u"
		fi
		set_password "$u" "${U_PASS[$u]}"
		mkdir -p "$TARGET/etc/sudoers.d"
		if [[ ${U_SUDO[$u]} == nopasswd ]]; then
			printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$u" >"$TARGET/etc/sudoers.d/20-nopasswd-$u"
			chmod 440 "$TARGET/etc/sudoers.d/20-nopasswd-$u"
		else
			rm -f "$TARGET/etc/sudoers.d/20-nopasswd-$u"
		fi
		echo "User '$u': groups $groups, $(sudo_word "$u")."
	done
	if [[ -n $ROOT_PASS ]]; then
		set_password root "$ROOT_PASS"
	fi
	mkdir -p "$TARGET/etc/sudoers.d"
	if [[ ! -e $TARGET/etc/sudoers.d/10-wheel ]]; then
		printf '%%wheel ALL=(ALL:ALL) ALL\n' >"$TARGET/etc/sudoers.d/10-wheel"
		chmod 440 "$TARGET/etc/sudoers.d/10-wheel"
	fi
	if [[ $BS_POWER == 1 ]]; then
		cat >"$TARGET/etc/sudoers.d/30-wheel-power" <<'EOF'
# gentoo-install.sh (LARBS-style): wheel may run these without a password
%wheel ALL=(ALL:ALL) NOPASSWD: /usr/bin/shutdown,/usr/bin/reboot,/usr/bin/poweroff,/usr/bin/halt,/usr/bin/loginctl suspend,/usr/bin/mount,/usr/bin/umount,/usr/local/bin/update-system
EOF
		chmod 440 "$TARGET/etc/sudoers.d/30-wheel-power"
	fi
	in_target visudo -c
}

step_configure() {
	echo "Hostname, keymap, timezone ..."
	echo "$HOST_NAME" >"$TARGET/etc/hostname"
	cat >"$TARGET/etc/hosts" <<EOF
127.0.0.1	localhost
::1		localhost
127.0.1.1	$HOST_NAME
EOF
	ln -sfn "/usr/share/zoneinfo/$TIMEZONE" "$TARGET/etc/localtime"
	if systemd_on; then
		printf 'KEYMAP=%s\n' "$KEYMAP" >"$TARGET/etc/vconsole.conf"
		in_target systemd-machine-id-setup >/dev/null 2>&1 || true
	else
		mkdir -p "$TARGET/etc/conf.d"
		printf 'hostname="%s"\n' "$HOST_NAME" >"$TARGET/etc/conf.d/hostname"
		sed -i -E "s/^keymap=.*/keymap=\"$KEYMAP\"/" "$TARGET/etc/conf.d/keymaps" 2>/dev/null || printf 'keymap="%s"\n' "$KEYMAP" >"$TARGET/etc/conf.d/keymaps"
		echo "$TIMEZONE" >"$TARGET/etc/timezone"
	fi
	echo "Locale $LOCALE ..."
	set_locale
	write_fstab
	if encrypted; then setup_crypt_target; fi
	setup_users
}

target_packages() {
	if snapper_on; then echo app-backup/snapper; fi
	if [[ $NET == nm ]]; then echo net-misc/networkmanager; fi
	echo dev-vcs/git
	desktop_packages
}

link_in_target() { # link_in_target <existing file> <link path>   (paths inside the target)
	if [[ -e $TARGET$1 ]]; then
		ln -sfn "$1" "$TARGET$2"
	else
		warn "$1 not found in the new system; skipped."
	fi
}

# Console keymap -> X11 keyboard layout ("layout" or "layout variant")
xkb_layout_of() {
	local k=${1%.map.gz}
	case $k in
		us | us-acentos) echo us ;;
		uk | gb) echo gb ;;
		dvorak | dvorak-*) echo "us dvorak" ;;
		colemak) echo "us colemak" ;;
		de-latin1-nodeadkeys) echo "de nodeadkeys" ;;
		de | de-latin1 | de_CH-latin1) [[ $k == de_CH* ]] && echo ch || echo de ;;
		sg | sg-latin1 | ch-de) echo ch ;;
		fr_CH | fr_CH-latin1 | ch-fr) echo "ch fr" ;;
		fr | fr-latin1 | fr-latin9 | fr-pc) echo fr ;;
		be-latin1 | be) echo be ;;
		br-abnt2 | br-abnt) echo br ;;
		la-latin1) echo latam ;;
		es | es-cp850) echo es ;;
		pt-latin1 | pt-latin9 | pt) echo pt ;;
		it | it2 | it-ibm) echo it ;;
		se-lat6 | se-latin1 | sv-latin1) echo se ;;
		no | no-latin1) echo no ;;
		dk | dk-latin1) echo dk ;;
		'fi') echo 'fi' ;;
		pl | pl2) echo pl ;;
		cz | cz-qwertz | cz-lat2) echo cz ;;
		cz-us-qwertz) echo "cz qwerty" ;;
		sk-qwertz) echo sk ;;
		hu) echo hu ;;
		ru | ruwin_*) echo ru ;;
		ua | ua-utf) echo ua ;;
		jp106) echo jp ;;
		tr_q-latin5 | trq) echo tr ;;
		*) k=${k%%[-_]*}; echo "${k%%[0-9]*}" ;;
	esac
}

# Make graphical logins use the same keyboard layout as the console, so
# passwords type the same everywhere.
write_x_keyboard() {
	local lv layout variant=""
	[[ $KEYMAP == us ]] && return 0
	lv=$(xkb_layout_of "$KEYMAP")
	layout=${lv%% *}
	if [[ $lv == *" "* ]]; then variant=${lv#* }; fi
	if [[ -z $layout ]]; then
		warn "Could not map keymap '$KEYMAP' to an X11 layout; the graphical login uses a US layout."
		return 0
	fi
	if [[ ! -d $TARGET/usr/share/X11/xkb/symbols ]] || [[ ! -e $TARGET/usr/share/X11/xkb/symbols/$layout ]]; then
		warn "X11 has no keyboard layout '$layout' (from keymap '$KEYMAP'); the graphical login uses a US layout. Set it with: localectl set-x11-keymap <layout>"
		return 0
	fi
	mkdir -p "$TARGET/etc/X11/xorg.conf.d"
	{
		echo "# Written by gentoo-install.sh from the console keymap '$KEYMAP'"
		echo 'Section "InputClass"'
		echo '	Identifier "system-keyboard"'
		echo '	MatchIsKeyboard "on"'
		echo "	Option \"XkbLayout\" \"$layout\""
		if [[ -n $variant ]]; then echo "	Option \"XkbVariant\" \"$variant\""; fi
		echo 'EndSection'
	} >"$TARGET/etc/X11/xorg.conf.d/00-keyboard.conf"
	echo "X11 keyboard layout: $layout${variant:+ ($variant)} (from keymap $KEYMAP)"
}

# The keyboard layout for graphical logins (sessions and PipeWire: finish_desktop).
configure_desktop() {
	desktop_on || return 0
	write_x_keyboard
}

# ---- GPU, applications, gaming --------------------------------------------------
gpu_packages() {
	local g list
	list=$(gpu_list)
	[[ -n $list ]] || return 0
	printf '%s\n' media-libs/mesa media-libs/vulkan-loader
	for g in $list; do
		case $g in
			intel) echo media-libs/libva-intel-media-driver ;;
			nvidia) echo x11-drivers/nvidia-drivers ;;
			vm)
				case $(vm_type) in
					virtualbox) echo app-emulation/virtualbox-guest-additions ;;
					vmware) echo app-emulation/open-vm-tools ;;
					qemu) printf '%s\n' app-emulation/spice-vdagent app-emulation/qemu-guest-agent ;;
				esac
				;;
		esac
	done
}

# make.conf VIDEO_CARDS: which Mesa / X drivers Portage builds.
video_cards() {
	local g out=""
	for g in $(gpu_list); do
		case $g in
			intel) out+=" intel" ;;
			amd) out+=" amdgpu radeonsi" ;;
			nouveau) out+=" nouveau" ;;
			nvidia) out+=" nvidia" ;;
			vm)
				case $(vm_type) in
					qemu) out+=" virgl" ;;
					*) out+=" vmware" ;;
				esac
				;;
		esac
	done
	trim "$out"
}

app_packages() {
	local a
	for a in $APPS; do
		case $a in
			# Big ones as Mozilla's / The Document Foundation's builds when prebuilt is chosen.
			firefox) if [[ $BUILD == bin ]]; then echo www-client/firefox-bin; else echo www-client/firefox; fi ;;
			thunderbird) if [[ $BUILD == bin ]]; then echo mail-client/thunderbird-bin; else echo mail-client/thunderbird; fi ;;
			libreoffice) if [[ $BUILD == bin ]]; then echo app-office/libreoffice-bin; else echo app-office/libreoffice; fi ;;
			telegram-desktop) if [[ $BUILD == bin ]]; then echo net-im/telegram-desktop-bin; else echo net-im/telegram-desktop; fi ;;
			chrome) echo www-client/google-chrome ;;
			vlc) echo media-video/vlc ;;
			mpv) echo media-video/mpv ;;
			gimp) echo media-gfx/gimp ;;
			obs) echo media-video/obs-studio ;;
			keepassxc) echo app-admin/keepassxc ;;
			discord) echo net-im/discord ;;
			flatpak) echo sys-apps/flatpak ;;
			git) echo dev-vcs/git ;;
			htop) echo sys-process/htop ;;
			neovim) echo app-editors/neovim ;;
			openssh) echo net-misc/openssh ;;
			cups) echo net-print/cups ;;
		esac
	done
}

gaming_packages() {
	local g
	for g in $GAMING; do
		case $g in
			steam) echo sys-apps/flatpak ;;   # Steam itself from Flathub (install_software)
			wine) echo app-emulation/wine-vanilla ;;
			winetricks) echo app-emulation/winetricks ;;
			lutris) echo games-util/lutris ;;
			gamemode) echo games-util/gamemode ;;
		esac
	done
}

# ---- peripherals --------------------------------------------------------------
# id|menu text (max 39 characters)|packages ("-": its own function)|needs a desktop
periph_table() {
	cat <<'PT'
bluetooth|Bluetooth: bluez, Blueman (service)|net-wireless/bluez|0
solaar|Logitech: Solaar - pairing, battery|app-misc/solaar|1
logiops|Logitech: logiops, MX mice (service)|app-misc/logiops|0
g810-led|Logitech: G keyboard lighting|app-misc/g810-led|0
piper|Gaming mice: Piper (service)|app-misc/piper|1
openlinkhub|Corsair: OpenLinkHub (service)|-|0
ckb-next|Corsair: ckb-next (service)|app-misc/ckb|1
openrazer|Razer: OpenRazer, Polychromatic|sys-apps/openrazer sys-apps/polychromatic|1
openrgb|RGB lighting, many brands: OpenRGB|app-misc/openrgb sys-apps/i2c-tools|1
coolercontrol|Fans, pumps: CoolerControl (GURU)|sys-apps/coolercontrold sys-apps/coolercontrol|1
controllers|PlayStation/Switch/Steam/8BitDo pads|games-util/game-device-udev-rules|0
xone|Xbox dongle, USB pads: xone (GURU)|games-util/xone|0
xpadneo|Xbox pads, Bluetooth: xpadneo (driver)|games-util/xpadneo net-wireless/bluez|0
sc-controller|Gamepad mapper: SC Controller|games-util/sc-controller|1
antimicrox|Gamepad to keys/mouse: AntiMicroX|games-util/antimicrox|1
oversteer|Steering wheels: Oversteer (GURU)|games-util/oversteer|1
wacom|Drawing tablets: Wacom|x11-drivers/xf86-input-wacom dev-libs/libwacom|0
input-remapper|Key/button remapper (GURU)|games-util/input-remapper|1
keyd|Key remapping daemon (GURU)|app-misc/keyd|0
kanata|Key remapper: kanata (GURU)|app-misc/kanata|0
PT
}
periph_field() { periph_table | awk -F'|' -v id="$1" -v f="$2" '$1 == id { print $f }'; }
periph_ids() { periph_table | cut -d'|' -f1; }
periph_gui() { local p; for p in $PERIPH; do [[ $(periph_field "$p" 4) == 1 ]] && return 0; done; return 1; }
periph_guru() { local p; for p in $PERIPH; do [[ $(periph_field "$p" 2) == *GURU* ]] && return 0; done; return 1; }

# IDs that match what is plugged in (USB vendor:product) or built in (Bluetooth).
detect_periph() {
	local d v p ids="" usb=" "
	for d in /sys/bus/usb/devices/*; do
		[[ -r $d/idVendor && -r $d/idProduct ]] || continue
		v=$(<"$d/idVendor") p=$(<"$d/idProduct")
		usb+="$v:$p $v "
	done
	[[ $usb == *" 046d "* ]] && ids+=" solaar"
	[[ $usb == *" 1b1c "* ]] && ids+=" openlinkhub"
	[[ $usb == *" 1532 "* ]] && ids+=" openrazer"
	[[ $usb =~ \ (054c|057e|28de|2dc8)\  ]] && ids+=" controllers"
	[[ $usb =~ \ 045e:(02e6|02fe|02f9|091e|02ea|02dd|02e3|0b00|0b12|0b13)\  ]] && ids+=" xone"
	[[ $usb == *" 056a "* ]] && ids+=" wacom"
	compgen -G '/sys/class/bluetooth/hci*' >/dev/null && ids+=" bluetooth"
	trim "$ids"
}

PERIPH_ASKED=0
CORSAIR_HELP="Both drive the same Corsair USB devices, so only one can be installed.

\ZbOpenLinkHub\Zn (recommended): newer and actively developed. Covers the iCUE LINK hub with its fans and coolers, Commander Core / Core XT / Pro, most Corsair AIO coolers, many keyboards, mice and headsets, and DDR4/DDR5 memory lighting. Runs as a background service; you set it up in a web browser at http://127.0.0.1:27003. Built here from a fixed, checked release (0.9.4) with Gentoo's Go.

\Zbckb-next\Zn: keyboards and mice only (lighting, macros, remapping); no AIO coolers, fan hubs or iCUE LINK. A desktop app with a tray icon."

menu_periph() {
	local sel det cur c p
	local -a items=()
	det=$(detect_periph)
	cur=$PERIPH
	if ((PERIPH_ASKED == 0)) && [[ -z $cur ]]; then cur=$det; fi
	while IFS='|' read -r p c _ _; do items+=("$p" "$c"); done < <(periph_table)
	sel=$(checklist "Peripherals" "Detected now: \Zb${det:-nothing known}\Zn (ticked the first time). Items marked GURU turn on the GURU overlay. Pick ckb-next OR OpenLinkHub for Corsair." "$cur" "${items[@]}") || return 1
	PERIPH_ASKED=1
	if has "$sel" openlinkhub && has "$sel" ckb-next; then
		c=$(ui --title " Corsair: pick one " --default-item openlinkhub --menu "$CORSAIR_HELP" 22 78 2 \
			openlinkhub "AIOs, hubs, iCUE LINK, more (recommended)" \
			ckb-next "keyboards and mice") || return 1
		if [[ $c == openlinkhub ]]; then sel=$(without "$sel" ckb-next); else sel=$(without "$sel" openlinkhub); fi
	fi
	c=0
	for p in solaar logiops; do has "$sel" "$p" && c=$((c + 1)); done
	if ((c > 1)); then
		yesno "Solaar and logiops each take over a Logitech device; only one can control a given mouse or receiver at a time. Keep all of them anyway?" "Logitech" 1 || return 1
	fi
	PERIPH=$sel
}

lbl_periph() { lbl_list "$PERIPH"; }

periph_packages() {
	local p f
	for p in $PERIPH; do
		f=$(periph_field "$p" 3)
		[[ $f == - ]] && continue
		tr ' ' '\n' <<<"$f"
		if [[ $p == bluetooth ]] && desktop_on; then echo net-wireless/blueman; fi
	done
}

# Services of the peripheral tools: "<OpenRC name>|<systemd name>".
periph_services() {
	local p
	for p in $PERIPH; do
		case $p in
			bluetooth | xpadneo) echo "bluetooth|bluetooth" ;;
			logiops) echo "logid|logid" ;;
			piper) echo "ratbagd|ratbagd" ;;
			openlinkhub) echo "openlinkhub|openlinkhub" ;;
			ckb-next) echo "ckb-next-daemon|ckb-next-daemon" ;;
			coolercontrol) echo "coolercontrold|coolercontrold" ;;
			input-remapper) echo "input-remapper|input-remapper" ;;
			keyd) echo "keyd|keyd" ;;
		esac
	done
}

# ---- installing packages ------------------------------------------------------
# Packages are checked against the enabled repositories first; one that is not
# there (an overlay that is off, a renamed package) is reported, not fatal.
install_available() { # install_available "label" atom...
	local label=$1 p a
	shift
	local -a want=() ok=() missing=()
	mapfile -t want < <(printf '%s\n' "$@" | awk 'NF && !seen[$0]++')
	((${#want[@]})) || return 0
	for p in "${want[@]}"; do
		a=$(resolve_atom "$p")
		if [[ -n $a ]]; then ok+=("$a"); else missing+=("$p"); fi
	done
	if ((${#missing[@]})); then warn "$label - not in the enabled repositories, skipped: ${missing[*]}"; fi
	((${#ok[@]})) || return 0
	echo "Installing $label: ${ok[*]}"
	if ! gemerge --noreplace "${ok[@]}"; then
		warn "$label - installing them together failed; trying one by one."
		for p in "${ok[@]}"; do
			gemerge --noreplace "$p" || warn "$label - could not install $p (see the log)"
		done
	fi
	return 0
}

# Packages that must install: a failure stops the step.
install_required() { # install_required "label" atom...
	local label=$1
	shift
	local -a want=()
	mapfile -t want < <(printf '%s\n' "$@" | awk 'NF && !seen[$0]++')
	((${#want[@]})) || return 0
	echo "Installing $label: ${want[*]}"
	gemerge --noreplace "${want[@]}"
}

# ---- OpenLinkHub: built from a fixed release ----------------------------------------
OPENLINKHUB_VERSION=0.9.4
OPENLINKHUB_GIT=https://github.com/jurkovic-nikola/OpenLinkHub
OPENLINKHUB_COMMIT=a08204cf88fd373a0bbdbe1f4382e8c64024adca

# Built with Gentoo's Go (go.sum pins every module), run as its own user by an
# OpenRC script or a systemd unit (the project's own). Called in "if".
install_openlinkhub() {
	local o=/opt/OpenLinkHub head
	echo "OpenLinkHub $OPENLINKHUB_VERSION: building from source ..."
	gemerge --noreplace --oneshot dev-lang/go dev-vcs/git || return 1
	rm -rf "$TARGET$o"
	in_target git -c advice.detachedHead=false clone -q --depth 1 -b "$OPENLINKHUB_VERSION" "$OPENLINKHUB_GIT" "$o" || return 1
	head=$(in_target git -C "$o" rev-parse HEAD) || return 1
	if [[ $head != "$OPENLINKHUB_COMMIT" ]]; then
		echo "OpenLinkHub: tag $OPENLINKHUB_VERSION points to $head, expected $OPENLINKHUB_COMMIT" >&2
		return 1
	fi
	in_target /bin/sh -c "cd $o && GOTOOLCHAIN=local GOFLAGS=-mod=readonly GOPATH=/tmp/gentoo-go GOCACHE=/tmp/gentoo-go/cache CGO_ENABLED=1 go build -trimpath -o OpenLinkHub ." || return 1
	rm -rf "$TARGET/tmp/gentoo-go" "$TARGET$o/.git"
	[[ -x $TARGET$o/OpenLinkHub ]] || return 1
	if ! grep -q '^openlinkhub:' "$TARGET/etc/passwd"; then
		in_target useradd -r -M -d "$o" -s /sbin/nologin openlinkhub || return 1
	fi
	in_target chown -R openlinkhub:openlinkhub "$o" || return 1
	mkdir -p "$TARGET/etc/udev/rules.d"
	cp "$TARGET$o/99-openlinkhub.rules" "$TARGET/etc/udev/rules.d/99-openlinkhub.rules" || return 1
	if systemd_on; then
		mkdir -p "$TARGET/etc/systemd/system"
		cat >"$TARGET/etc/systemd/system/openlinkhub.service" <<-UNIT
			# OpenLinkHub $OPENLINKHUB_VERSION, built by gentoo-install.sh (the project's own unit)
			[Unit]
			Description=Open source interface for iCUE LINK System Hub, Corsair AIOs and Hubs
			After=sleep.target systemd-udevd.service

			[Service]
			User=openlinkhub
			Group=openlinkhub
			WorkingDirectory=$o
			ExecStartPre=+/usr/bin/udevadm control --reload-rules
			ExecStartPre=+/usr/bin/udevadm trigger --subsystem-match=usb --attr-match=idVendor=1b1c
			ExecStartPre=+/usr/bin/udevadm settle --timeout=30
			ExecStart=$o/OpenLinkHub
			Restart=always
			RestartSec=5

			[Install]
			WantedBy=multi-user.target
		UNIT
	else
		mkdir -p "$TARGET/etc/init.d"
		cat >"$TARGET/etc/init.d/openlinkhub" <<-INITD
			#!/sbin/openrc-run
			# OpenLinkHub $OPENLINKHUB_VERSION, written by gentoo-install.sh
			description="OpenLinkHub (Corsair devices; web UI on port 27003)"
			supervisor=supervise-daemon
			command="$o/OpenLinkHub"
			command_user="openlinkhub:openlinkhub"
			directory="$o"

			depend() {
				need localmount udev
			}

			start_pre() {
				udevadm control --reload-rules
				udevadm trigger --subsystem-match=usb --attr-match=idVendor=1b1c
				udevadm settle --timeout=30
			}
		INITD
		chmod 755 "$TARGET/etc/init.d/openlinkhub"
	fi
	echo "OpenLinkHub installed: service 'openlinkhub', web UI at http://127.0.0.1:27003"
}

# After the peripheral packages: tools built here, configs, groups.
periph_finish() {
	local p u
	[[ -n $PERIPH ]] || return 0
	if has "$PERIPH" openlinkhub && ! install_openlinkhub; then
		warn "OpenLinkHub could not be installed (details in the log); the rest of the install continues."
		PERIPH=$(without "$PERIPH" openlinkhub)
	fi
	if has "$PERIPH" logiops && [[ ! -e $TARGET/etc/logid.cfg ]]; then
		printf '%s\n' '// logiops (gentoo-install.sh): add your devices, see https://github.com/PixlOne/logiops/wiki/Configuration' \
			'// then restart the logid service' 'devices: ();' >"$TARGET/etc/logid.cfg"
	fi
	if has "$PERIPH" openrgb; then
		mkdir -p "$TARGET/etc/modules-load.d"
		echo i2c-dev >"$TARGET/etc/modules-load.d/openrgb.conf"
	fi
	for u in "${USERS[@]}"; do
		for p in plugdev keyd input; do
			case $p in
				plugdev) has "$PERIPH" openrazer || continue ;;
				keyd) has "$PERIPH" keyd || continue ;;
				input) has "$PERIPH" input-remapper || has "$PERIPH" kanata || continue ;;
			esac
			if grep -q "^$p:" "$TARGET/etc/group"; then in_target usermod -a -G "$p" "$u"; fi
		done
	done
	return 0
}

install_software() {
	local -a list=()
	mapfile -t list < <(desktop_extra_packages)
	install_available "desktop and window manager tools" "${list[@]}"
	mapfile -t list < <(gpu_packages)
	install_available "GPU drivers" "${list[@]}"
	mapfile -t list < <(app_packages)
	install_available "applications" "${list[@]}"
	mapfile -t list < <(gaming_packages)
	install_available "gaming packages" "${list[@]}"
	mapfile -t list < <(periph_packages)
	install_available "peripheral support" "${list[@]}"
	read -ra list <<<"$EXTRA_PKGS"
	install_available "extra packages" "${list[@]}"
	if has "$APPS" flatpak || has "$GAMING" steam; then
		in_target flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo ||
			warn "Could not add the Flathub remote; run: flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo"
	fi
	if has "$GAMING" steam; then
		echo "Steam: from Flathub (com.valvesoftware.Steam) ..."
		in_target flatpak install -y --noninteractive flathub com.valvesoftware.Steam ||
			warn "Steam could not be installed from Flathub now; run: flatpak install flathub com.valvesoftware.Steam"
	fi
}

# ---- services: OpenRC or systemd --------------------------------------------------
svc_enable() { # svc_enable <name> [runlevel]  (OpenRC: default runlevel unless given)
	if systemd_on; then
		in_target systemctl enable "$1" >/dev/null 2>&1
	else
		[[ -e $TARGET/etc/init.d/$1 ]] || return 1
		in_target rc-update add "$1" "${2:-default}" >/dev/null
	fi
}

enable_service() { # enable_service <openrc name> <systemd name> [openrc runlevel]
	local n=$1
	if systemd_on; then n=$2; fi
	[[ -n $n ]] || return 0
	if svc_enable "$n" "${3:-default}"; then
		echo "Enabled service: $n"
	else
		warn "Service '$n' could not be enabled (not installed?)."
	fi
}

configure_network() {
	case $NET in
		networkd)
			mkdir -p "$TARGET/etc/systemd/network"
			printf '[Match]\nType=ether\n\n[Network]\nDHCP=yes\n' >"$TARGET/etc/systemd/network/20-wired.network"
			printf '[Match]\nType=wlan\n\n[Network]\nDHCP=yes\nIgnoreCarrierLoss=3s\n' >"$TARGET/etc/systemd/network/25-wireless.network"
			ln -sfn /run/systemd/resolve/stub-resolv.conf "$TARGET/etc/resolv.conf"
			;;
		dhcpcd)
			mkdir -p "$TARGET/etc/iwd"
			[[ -e $TARGET/etc/iwd/main.conf ]] || printf '[General]\nEnableNetworkConfiguration=false\n' >"$TARGET/etc/iwd/main.conf"
			;;
	esac
	if compgen -G '/sys/class/net/*/wireless' >/dev/null && [[ $NET != none ]]; then
		case $NET in
			nm) echo "Wi-Fi: connect after the first boot with nmtui (or the desktop's network applet)." ;;
			*) echo "Wi-Fi: connect after the first boot with: iwctl station wlan0 connect <network>" ;;
		esac
	fi
}

configure_zram() {
	[[ $SWAP == zram ]] || return 0
	if systemd_on; then
		mkdir -p "$TARGET/etc/systemd"
		printf '# gentoo-install.sh: compressed swap in RAM (zram-generator)\n[zram0]\nzram-size = min(ram / 2, 8192)\ncompression-algorithm = zstd\n' \
			>"$TARGET/etc/systemd/zram-generator.conf"
	else
		mkdir -p "$TARGET/etc/conf.d"
		cat >"$TARGET/etc/conf.d/zram-init" <<'ZR'
# gentoo-install.sh: one compressed swap device in RAM (half the RAM, at most 8 GiB)
load_on_start=yes
unload_on_stop=yes
num_devices=1
type0=swap
flag0=
size0="$(( $(awk '/MemTotal/ { print $2 }' /proc/meminfo) / 2048 > 8192 ? 8192 : $(awk '/MemTotal/ { print $2 }' /proc/meminfo) / 2048 ))"
algo0=zstd
ZR
	fi
	mkdir -p "$TARGET/etc/sysctl.d"
	printf 'vm.swappiness = 180\nvm.watermark_boost_factor = 0\nvm.watermark_scale_factor = 125\nvm.page-cluster = 0\n' \
		>"$TARGET/etc/sysctl.d/99-zram.conf"
}

# The daemons every install gets, plus the chosen network and swap.
base_service_packages() {
	if ! systemd_on; then printf '%s\n' app-admin/sysklogd sys-process/cronie net-misc/chrony; fi
	if systemd_on; then echo net-misc/chrony; fi
	case $NET in
		nm) echo net-misc/networkmanager ;;
		dhcpcd) printf '%s\n' net-misc/dhcpcd net-wireless/iwd ;;
		networkd) echo net-wireless/iwd ;;
	esac
	if [[ $SWAP == zram ]]; then
		if systemd_on; then echo sys-apps/zram-generator; else echo sys-block/zram-init; fi
	fi
}

enable_services() {
	local s o d
	if systemd_on; then
		enable_service "" chronyd
		enable_service "" fstrim.timer
	else
		enable_service sysklogd ""
		enable_service cronie ""
		enable_service chronyd ""
		if desktop_on; then
			enable_service dbus "" default
			enable_service elogind "" boot
		fi
		if [[ $SWAP == zram ]]; then enable_service zram-init "" boot; fi
		# SSD trim once a week (cron).
		mkdir -p "$TARGET/etc/cron.weekly"
		printf '#!/bin/sh\n# gentoo-install.sh: trim free space on SSDs once a week\nexec fstrim -a\n' >"$TARGET/etc/cron.weekly/fstrim"
		chmod 755 "$TARGET/etc/cron.weekly/fstrim"
	fi
	case $NET in
		nm) enable_service NetworkManager NetworkManager ;;
		dhcpcd)
			enable_service dhcpcd dhcpcd
			enable_service iwd iwd
			;;
		networkd)
			enable_service "" systemd-networkd
			enable_service "" systemd-resolved
			enable_service "" iwd
			;;
	esac
	s=$(dm_service)
	if [[ -n $s ]]; then
		if systemd_on; then
			enable_service "" "$s"
		else
			if [[ $s == display-manager ]]; then
				d=$(desktop_dm)
				mkdir -p "$TARGET/etc/conf.d"
				sed -i -E "s/^DISPLAYMANAGER=.*/DISPLAYMANAGER=\"$d\"/" "$TARGET/etc/conf.d/display-manager" 2>/dev/null || true
				grep -q '^DISPLAYMANAGER=' "$TARGET/etc/conf.d/display-manager" 2>/dev/null ||
					printf 'DISPLAYMANAGER="%s"\n' "$d" >>"$TARGET/etc/conf.d/display-manager"
			fi
			enable_service "$s" ""
		fi
	fi
	while IFS='|' read -r o s; do
		[[ -n $o ]] && enable_service "$o" "$s"
	done < <(periph_services | awk 'NF && !seen[$0]++')
	if has "$APPS" openssh; then enable_service sshd sshd; fi
	if has "$APPS" cups; then enable_service cupsd cups; fi
	if has "$(gpu_list)" vm; then
		case $(vm_type) in
			virtualbox) enable_service virtualbox-guest-additions vboxservice ;;
			vmware) enable_service vmware vmtoolsd ;;
			qemu) enable_service qemu-guest-agent qemu-guest-agent ;;
		esac
	fi
	return 0
}

# ---- desktops: install side ---------------------------------------------------
session_exec() { # desktop id -> command a login-screen session starts
	case $1 in
		qtile) echo "qtile start" ;;
		herbstluftwm) echo "herbstluftwm --locked" ;;
		openbox) echo openbox-session ;;
		fluxbox) echo startfluxbox ;;
		icewm) echo icewm-session ;;
		dwm) echo /usr/local/bin/dwm-session ;;
		niri) echo niri-session ;;
		hyprland) echo Hyprland ;;
		*) echo "$1" ;;
	esac
}

# With systemd, logind gives every session D-Bus and PipeWire starts from its
# user units (enabled for all users below). With OpenRC nobody starts a session
# bus or PipeWire for a bare window manager: /usr/local/bin/gentoo-session does
# both (with Gentoo's gentoo-pipewire-launcher), then runs the window manager.
# Desktop environments get PipeWire from the autostart entry Gentoo installs.
write_session_tools() {
	mkdir -p "$TARGET/usr/local/bin"
	cat >"$TARGET/usr/local/bin/gentoo-session" <<'GS'
#!/bin/sh
# gentoo-session <window manager command...>        (written by gentoo-install.sh)
# Starts a bare window manager inside a D-Bus session and with PipeWire
# running. Used by the "(Gentoo session)" login entries; from the console:
# gentoo-session sway
if [ $# -eq 0 ]; then
	echo "usage: gentoo-session <command> [arguments]" >&2
	exit 2
fi
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && command -v dbus-run-session >/dev/null 2>&1; then
	exec dbus-run-session -- "$0" "$@"
fi
# Started by startx or greetd instead of a display manager: load the same
# profile files a display manager would.
if [ -n "${GENTOO_XPROFILE:-}" ]; then
	unset GENTOO_XPROFILE
	for f in /etc/profile "$HOME/.profile" /etc/xprofile "$HOME/.xprofile"; do
		if [ -f "$f" ]; then . "$f"; fi
	done
fi
if command -v gentoo-pipewire-launcher >/dev/null 2>&1 && [ -n "${XDG_RUNTIME_DIR:-}" ]; then
	gentoo-pipewire-launcher restart >/dev/null 2>&1 &
fi
"$@"
rc=$?
pkill -u "$(id -u)" -x wireplumber 2>/dev/null
pkill -u "$(id -u)" -x pipewire 2>/dev/null
exit "$rc"
GS
	chmod 755 "$TARGET/usr/local/bin/gentoo-session"
}

session_file() { # desktop id -> path of the installer's login entry for it
	if [[ $(desktop_kind "$1") == x11 ]]; then
		echo "/usr/share/xsessions/gentoo-install-$1.desktop"
	else
		echo "/usr/share/wayland-sessions/gentoo-install-$1.desktop"
	fi
}

# Every selected window manager gets a login entry. OpenRC: "<name> (Gentoo
# session)" through gentoo-session; systemd: only when its package has none.
ensure_sessions() {
	local d kind cmd bin dir f
	if ! systemd_on; then write_session_tools; fi
	if has "$DESKTOP" dwm; then
		mkdir -p "$TARGET/usr/local/bin"
		cat >"$TARGET/usr/local/bin/dwm-session" <<'DS'
#!/bin/sh
# dwm session (gentoo-install.sh): status bar, then dwm.
if command -v dwmblocks >/dev/null 2>&1; then dwmblocks &
elif command -v slstatus >/dev/null 2>&1; then slstatus &
fi
exec dwm
DS
		chmod 755 "$TARGET/usr/local/bin/dwm-session"
	fi
	for d in $DESKTOP; do
		kind=$(desktop_kind "$d")
		[[ $kind == x11 || $kind == wl ]] || continue
		cmd=$(session_exec "$d")
		bin=${cmd%% *}
		bin=${bin##*/}
		if [[ $d == dwm ]]; then bin=dwm; fi
		if [[ ! -x $TARGET/usr/bin/$bin && ! -x $TARGET/usr/local/bin/$bin ]]; then
			warn "$(desktop_field "$d" 3): '$bin' is not installed; no login session for it."
			continue
		fi
		f="$TARGET$(session_file "$d")"
		mkdir -p "${f%/*}"
		if systemd_on; then
			if [[ $kind == x11 ]]; then dir=/usr/share/xsessions; else dir=/usr/share/wayland-sessions; fi
			if grep -lqsE "^Exec=(.*/)?($bin|${cmd%% *})( |$)" "$TARGET$dir"/*.desktop; then
				echo "Login session for $(desktop_field "$d" 3): shipped by its package"
				continue
			fi
			printf '[Desktop Entry]\nName=%s\nComment=%s - written by gentoo-install.sh\nExec=%s\nType=Application\nDesktopNames=%s\n' \
				"$(desktop_field "$d" 3)" "$bin" "$cmd" "$d" >"$f"
		else
			printf '[Desktop Entry]\nName=%s (Gentoo session)\nComment=%s with a D-Bus session and PipeWire sound - written by gentoo-install.sh\nExec=/usr/local/bin/gentoo-session %s\nType=Application\nDesktopNames=%s\n' \
				"$(desktop_field "$d" 3)" "$bin" "$cmd" "$d" >"$f"
		fi
		echo "Login session: ${f#"$TARGET"}"
	done
	if systemd_on; then
		in_target systemctl --global enable pipewire.socket pipewire-pulse.socket wireplumber.service >/dev/null 2>&1 ||
			warn "Could not enable PipeWire's user units; run: systemctl --global enable pipewire.socket pipewire-pulse.socket wireplumber.service"
	fi
}

de_start_cmd() { # desktop environment id -> command that starts it from startx
	case $1 in
		xfce) echo startxfce4 ;;
		plasma) echo startplasma-x11 ;;
		gnome) echo gnome-session ;;
		mate) echo mate-session ;;
		cinnamon) echo cinnamon-session ;;
		lxqt) echo startlxqt ;;
		budgie) echo budgie-desktop ;;
		enlightenment) echo enlightenment_start ;;
	esac
}

# Per-user defaults: the session LightDM preselects, and with no login screen
# an ~/.xinitrc so that "startx" starts the first X11 choice.
session_defaults() {
	local u home d first="" firstx="" line="" dm wrap=""
	dm=$(desktop_dm)
	if ! systemd_on; then wrap="/usr/local/bin/gentoo-session "; fi
	for d in $DESKTOP; do
		if [[ -z $first ]]; then first=$d; fi
		if [[ -z $firstx && $(desktop_kind "$d") != wl ]]; then firstx=$d; fi
	done
	if [[ -n $firstx ]]; then
		if [[ $(desktop_kind "$firstx") == x11 ]]; then
			line="exec $wrap$(session_exec "$firstx")"
		elif systemd_on; then
			line="exec $(de_start_cmd "$firstx")"
		else
			line="exec dbus-run-session $(de_start_cmd "$firstx")"
		fi
	fi
	for u in "${USERS[@]}"; do
		home="$TARGET/home/$u"
		[[ -d $home ]] || continue
		if [[ $dm == lightdm && $(desktop_kind "$first") != de && -e $TARGET$(session_file "$first") && ! -e $home/.dmrc ]]; then
			printf '[Desktop]\nSession=gentoo-install-%s\n' "$first" >"$home/.dmrc"
			in_target chown "$u:" "/home/$u/.dmrc"
		fi
		if [[ -z $dm && -n $line && ! -e $home/.xinitrc ]]; then
			printf '#!/bin/sh\n# Written by gentoo-install.sh: "startx" starts this session.\nexport GENTOO_XPROFILE=1\n%s\n' "$line" >"$home/.xinitrc"
			in_target chown "$u:" "/home/$u/.xinitrc"
			echo "No login screen: 'startx' starts ${line#exec } for $u"
		fi
	done
	if [[ -z $dm ]] && has_kind wl; then
		echo "No login screen: start a Wayland window manager from the console, e.g. '${wrap}sway'."
	fi
}

# bspwm and river start with an empty screen without a config: give each user
# the package's example (dotfile presets may replace it later).
wm_default_configs() {
	local u home src d
	for u in "${USERS[@]}"; do
		home="$TARGET/home/$u"
		[[ -d $home ]] || continue
		if has "$DESKTOP" bspwm && [[ ! -e $home/.config/bspwm/bspwmrc ]]; then
			src=""
			for d in "$TARGET/usr/share/doc/bspwm/examples" "$TARGET/usr/share/doc/bspwm"; do
				if [[ -f $d/bspwmrc ]]; then
					src=$d/bspwmrc
					break
				fi
			done
			if [[ -n $src ]]; then
				mkdir -p "$home/.config/bspwm" "$home/.config/sxhkd"
				install -m 755 "$src" "$home/.config/bspwm/bspwmrc"
				if [[ -f ${src%/*}/sxhkdrc ]]; then sed 's/\burxvt\b/alacritty/' "${src%/*}/sxhkdrc" >"$home/.config/sxhkd/sxhkdrc"; fi
				in_target chown -R "$u:" "/home/$u/.config"
				echo "bspwm: example config for $u"
			else
				warn "bspwm: no example bspwmrc found; create ~/.config/bspwm/bspwmrc."
			fi
		fi
		if has "$DESKTOP" river && [[ ! -e $home/.config/river/init ]]; then
			src=""
			for d in "$TARGET/usr/share/doc/river/examples" "$TARGET/usr/share/doc/river" "$TARGET/usr/share/river"; do
				if [[ -f $d/init ]]; then
					src=$d/init
					break
				fi
			done
			if [[ -n $src ]]; then
				mkdir -p "$home/.config/river"
				install -m 755 "$src" "$home/.config/river/init"
				in_target chown -R "$u:" "/home/$u/.config"
				echo "river: example init for $u"
			fi
		fi
	done
}

write_greetd_config() {
	local x="" cmd="" first=${DESKTOP%% *}
	local wrap="" vt=1
	if ! systemd_on; then wrap="/usr/local/bin/gentoo-session " vt=7; fi
	if has_kind x11 || has_kind de; then x=" --xsessions /usr/share/xsessions --xsession-wrapper 'startx /usr/bin/env GENTOO_XPROFILE=1'"; fi
	# Until a session was chosen once (F2), Enter starts the first Wayland choice.
	if [[ $(desktop_kind "$first") == wl ]]; then cmd=" --cmd '$wrap$(session_exec "$first")'"; fi
	mkdir -p "$TARGET/etc/greetd"
	cat >"$TARGET/etc/greetd/config.toml" <<EOF
# greetd + tuigreet (gentoo-install.sh). F2 in tuigreet picks the session.
[terminal]
vt = $vt

[default_session]
command = "tuigreet --time --remember --remember-session --asterisks --sessions /usr/share/wayland-sessions${x}${cmd}"
user = "greeter"
EOF
	echo "greetd: tuigreet on tty$vt"
}

# After all desktop packages are in: sessions, starter configs, login screen.
finish_desktop() {
	desktop_on || return 0
	ensure_sessions
	wm_default_configs
	session_defaults
	if [[ $(desktop_dm) == greetd ]]; then write_greetd_config; fi
	if [[ $(desktop_dm) == ly ]]; then
		if systemd_on; then
			in_target systemctl disable getty@tty2.service >/dev/null 2>&1 || true
		else
			# OpenRC: no login prompt on tty2, where Ly runs.
			sed -i -E 's/^(c2:.*agetty.*tty2.*)$/#\1/' "$TARGET/etc/inittab" 2>/dev/null || true
			in_target rc-update del agetty.tty2 default >/dev/null 2>&1 || true
		fi
		echo "Ly: login screen on tty2"
	fi
}

# ---- dotfile presets: install side ------------------------------------------
write_dots_helper() {
	cat >"$TARGET/tmp/gentoo-dots.sh" <<'EOF'
#!/bin/sh
# gentoo-dots.sh <git url> <branch> <how> - run as the user (gentoo-install.sh)
set -eu
url=$1 branch=$2 how=$3
tmp=$(mktemp -d /tmp/gentoo-dots.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
git clone -q --depth 1 -b "$branch" "$url" "$tmp/r"
r=$tmp/r
cpb() { cp -a --backup=numbered "$@"; }
case $how in
	skel)
		[ -d "$r/etc/skel" ] || { echo "no etc/skel in $url" >&2; exit 1; }
		cpb "$r/etc/skel/." "$HOME/"
		;;
	dots)
		for f in "$r"/.[!.]* "$r"/..?*; do
			[ -e "$f" ] || continue
			case ${f##*/} in
				.git | .github | .gitignore | .gitmodules | .gitattributes | .editorconfig) continue ;;
			esac
			cpb "$f" "$HOME/"
		done
		;;
	config)
		[ -d "$r/config" ] || { echo "no config/ in $url" >&2; exit 1; }
		mkdir -p "$HOME/.config"
		cpb "$r/config/." "$HOME/.config/"
		;;
	build)
		name=${url##*/}
		name=${name%.git}
		mkdir -p "$HOME/.local/src"
		rm -rf "${HOME:?}/.local/src/$name"
		cp -a "$r" "$HOME/.local/src/$name"
		cd "$HOME/.local/src/$name"
		make
		;;
	fish)
		mkdir -p "$HOME/.config/fish"
		sed '/^source \/usr\/share\/cachyos-fish-config/d' "$r/cachyos-config.fish" >"$HOME/.config/fish/cachyos-config.fish"
		grep -qs cachyos-config.fish "$HOME/.config/fish/config.fish" ||
			echo 'source ~/.config/fish/cachyos-config.fish' >>"$HOME/.config/fish/config.fish"
		;;
	bash)
		cpb "$r/.bashrc" "$HOME/.bashrc"
		mkdir -p "$HOME/.config"
		cpb "$r/starship.toml" "$HOME/.config/starship.toml"
		;;
	*) echo "unknown method $how" >&2; exit 1 ;;
esac
EOF
	chmod 755 "$TARGET/tmp/gentoo-dots.sh"
}

bs_presets() {
	local id d line label sources pkgs note src url branch how name re_url='^https://[A-Za-z0-9./_-]+$' re_br='^[A-Za-z0-9._/-]+$'
	local -a plist=() wm=()
	gemerge --noreplace dev-vcs/git || warn "Dotfiles: could not install git."
	write_dots_helper
	for id in $DOTS; do
		label="" sources="" pkgs="" note=""
		line=$(dots_table | awk -F'|' -v i="$id" '$1 == i')
		if [[ -n $line ]]; then IFS='|' read -r _ _ label sources pkgs note <<<"$line"; fi
		if [[ -z $label ]]; then
			warn "Dotfiles: unknown preset '$id' skipped."
			continue
		fi
		echo "==> Dotfiles: $label"
		if [[ -n $note ]]; then echo "    Note: $note"; fi
		read -ra plist <<<"$pkgs"
		if [[ $STANDALONE == 1 ]]; then
			# On an installed system the window manager itself may be missing.
			for d in $(dots_field "$id" 2); do
				if [[ $d != any ]]; then read -ra wm <<<"$(desktop_field "$d" 4) $(desktop_field "$d" 5)"; plist=("${wm[@]}" "${plist[@]}"); fi
			done
		fi
		install_available "packages for $label" "${plist[@]}"
		if [[ $STANDALONE == 1 ]]; then
			for d in $(dots_field "$id" 2); do
				if [[ $d != any ]]; then DESKTOP=$d ensure_sessions; fi
			done
		fi
		for src in $sources; do
			IFS='#' read -r url branch how <<<"$src"
			if ! [[ $url =~ $re_url && $branch =~ $re_br && $how =~ ^[a-z]+$ ]]; then
				warn "Dotfiles: bad source '$src' skipped."
				continue
			fi
			echo "    $url ($branch, $how)"
			if ! as_user "$USER_NAME" sh /tmp/gentoo-dots.sh "$url" "$branch" "$how"; then
				warn "Dotfiles: $label - $url failed."
				continue
			fi
			if [[ $how == build ]]; then
				name=${url##*/}
				name=${name%.git}
				in_target /bin/sh -c "cd '/home/$USER_NAME/.local/src/$name' && make install" ||
					warn "Dotfiles: $label - 'make install' of $name failed."
			fi
		done
		if [[ $id == larbs ]]; then
			# LARBS sets PATH (status bar scripts) and its environment in
			# ~/.config/shell/profile, read by zsh on a console login. Login screens
			# read ~/.profile instead, so point that at the same file.
			as_user "$USER_NAME" /bin/sh -c '[ -e ~/.profile ] || [ ! -f ~/.config/shell/profile ] || ln -s .config/shell/profile ~/.profile' ||
				warn "Dotfiles: LARBS - could not link ~/.profile."
		fi
	done
	rm -f "$TARGET/tmp/gentoo-dots.sh"
}

step_packages() {
	local -a pkgs=()
	mapfile -t pkgs < <({ target_packages; base_service_packages; } | awk 'NF && !seen[$0]++')
	install_required "system packages" "${pkgs[@]}"
	configure_desktop
	install_software
	finish_desktop
	periph_finish
	configure_network
	configure_zram
	enable_services
}

# ---- LARBS-style bootstrap ---------------------------------------------------------
bs_install_progs() {
	local csv="$TARGET/tmp/gentoo-install-progs.csv" tag prog comment n=0 total name need_dev=0 need_flatpak=0
	local re_pkg='^[A-Za-z0-9][A-Za-z0-9._+-]*(/[A-Za-z0-9][A-Za-z0-9._+-]*)?$' re_url='^(https?|git)://[^[:space:]"`$;|&<>]+$'
	if [[ $BS_PROGS =~ ^https?:// ]]; then
		echo "Downloading the programs list: $BS_PROGS"
		if ! curl -fsSL --max-time 120 -o "$csv" "$BS_PROGS"; then
			warn "Bootstrap: could not download $BS_PROGS; programs list skipped."
			return 0
		fi
	else
		cp "$BS_PROGS" "$csv"
	fi
	sed -i 's/\r$//' "$csv"
	total=$(grep -cvE '^[[:space:]]*(#|$)' "$csv" || true)
	grep -qE '^G,' "$csv" && need_dev=1
	grep -qE '^F,' "$csv" && need_flatpak=1
	if ((need_dev)); then gemerge --noreplace dev-vcs/git || warn "Bootstrap: could not install git."; fi
	if ((need_flatpak)); then
		gemerge --noreplace sys-apps/flatpak || warn "Bootstrap: could not install flatpak."
		in_target flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo || true
	fi
	if grep -qE '^A,' "$csv" && [[ $GURU != 1 ]]; then
		echo "The programs list has A entries: enabling the GURU overlay for them ..."
		GURU=1
		enable_overlays || warn "Bootstrap: GURU could not be enabled; A entries are skipped."
	fi
	echo "Installing $total programs from the list ..."
	while IFS=, read -r -u 9 tag prog comment || [[ -n $tag$prog ]]; do
		tag=$(trim "$tag")
		prog=$(trim "$prog")
		[[ -z $tag && -z $prog ]] && continue
		[[ $tag == \#* ]] && continue
		comment=$(trim "$comment")
		comment=${comment#\"}
		comment=${comment%\"}
		n=$((n + 1))
		case $tag in
			"" | X)
				echo "==> [$n/$total] $prog $comment"
				if ! [[ $prog =~ $re_pkg ]]; then warn "Bootstrap: invalid package name '$prog' skipped."; continue; fi
				install_available "programs list" "$prog"
				;;
			A)
				echo "==> [$n/$total] $prog (GURU) $comment"
				if ! [[ $prog =~ $re_pkg ]]; then warn "Bootstrap: invalid package name '$prog' skipped."; continue; fi
				install_available "programs list (GURU)" "$prog"
				;;
			G)
				name=${prog##*/}
				name=${name%.git}
				echo "==> [$n/$total] $name (git + make) $comment"
				if ! [[ $prog =~ $re_url && $name =~ $re_pkg ]]; then warn "Bootstrap: invalid git URL '$prog' skipped."; continue; fi
				as_user "$USER_NAME" mkdir -p "/home/$USER_NAME/.local/src" || true
				if [[ -d $TARGET/home/$USER_NAME/.local/src/$name/.git ]]; then
					as_user "$USER_NAME" git -C "/home/$USER_NAME/.local/src/$name" pull -q --ff-only || true
				elif ! as_user "$USER_NAME" git clone -q --depth 1 "$prog" "/home/$USER_NAME/.local/src/$name"; then
					warn "Bootstrap: cloning $prog failed."
					continue
				fi
				if ! { as_user "$USER_NAME" make -C "/home/$USER_NAME/.local/src/$name" &&
					in_target make -C "/home/$USER_NAME/.local/src/$name" install; }; then
					warn "Bootstrap: building $name failed."
				fi
				;;
			P)
				echo "==> [$n/$total] $prog (Python, own venv) $comment"
				if ! [[ $prog =~ $re_pkg && $prog != */* ]]; then warn "Bootstrap: invalid Python package '$prog' skipped."; continue; fi
				# Gentoo has no pipx: the same idea by hand, one venv per program.
				as_user "$USER_NAME" /bin/sh -c "python3 -m venv ~/.local/venvs/$prog && ~/.local/venvs/$prog/bin/pip install -q $prog && mkdir -p ~/.local/bin && for b in ~/.local/venvs/$prog/bin/*; do case \${b##*/} in python*|pip*|activate*|Activate*) ;; *) ln -sf \"\$b\" ~/.local/bin/ ;; esac; done" ||
					warn "Bootstrap: installing $prog with pip failed."
				;;
			F)
				echo "==> [$n/$total] $prog (Flatpak) $comment"
				if ! [[ $prog =~ $re_pkg ]]; then warn "Bootstrap: invalid Flatpak id '$prog' skipped."; continue; fi
				in_target flatpak install -y --noninteractive flathub "$prog" || warn "Bootstrap: Flatpak $prog failed."
				;;
			*)
				warn "Bootstrap: unknown tag '$tag' for $prog skipped."
				;;
		esac
	done 9<"$csv"
	rm -f "$csv"
}

bs_dotfiles() {
	local tmp=/tmp/gentoo-install-dotfiles
	local -a br=()
	if [[ -n $BS_BRANCH ]]; then br=(-b "$BS_BRANCH"); fi
	echo "Copying dotfiles from $BS_DOTFILES into ~$USER_NAME ..."
	gemerge --noreplace dev-vcs/git || true
	rm -rf "$TARGET$tmp"
	if as_user "$USER_NAME" git clone -q --depth 1 "${br[@]}" "$BS_DOTFILES" "$tmp" &&
		as_user "$USER_NAME" /bin/sh -c "tar -C $tmp --exclude=./.git --exclude=./README.md --exclude=./LICENSE --exclude=./FUNDING.yml -cf - . | tar -C ~ -xf -"; then
		echo "Dotfiles installed."
	else
		warn "Bootstrap: installing the dotfiles from $BS_DOTFILES failed."
	fi
	rm -rf "$TARGET$tmp"
}

bs_shell() {
	local path
	local atom
	case $BS_SHELL in
		zsh) path=/bin/zsh atom=app-shells/zsh ;;
		fish) path=/usr/bin/fish atom=app-shells/fish ;;
		*) return 0 ;;
	esac
	echo "Setting the login shell of $USER_NAME to $BS_SHELL ..."
	if gemerge --noreplace "$atom"; then
		in_target usermod -s "$path" "$USER_NAME" || warn "Bootstrap: could not set the login shell."
	else
		warn "Bootstrap: could not install $BS_SHELL."
	fi
}

bootstrap_wanted() { [[ -n $BS_PROGS || -n $DOTS || -n $BS_DOTFILES || $BS_SHELL != bash ]]; }

step_bootstrap_user() {
	if [[ -n $BS_PROGS ]]; then bs_install_progs; fi
	if [[ -n $DOTS ]]; then bs_presets; fi
	if [[ -n $BS_DOTFILES ]]; then bs_dotfiles; fi
	bs_shell
}

# ---- boot loader ------------------------------------------------------------
# Kernel command line for dracut: rd.luks.uuid unlocks the LUKS volume (with
# the key file listed in /etc/crypttab when there is one); root= by the
# filesystem's UUID. The keymap is in the initramfs (from the system's config).
boot_cmdline() {
	local c=""
	if encrypted; then c="rd.luks.uuid=$(get_uuid "$ROOT_PART") "; fi
	if ! zfs_on; then
		# ZFSBootMenu adds root=zfs:<boot environment> itself.
		c+="root=UUID=$(get_uuid "$(root_device)") "
		if [[ $FS == btrfs ]]; then c+="rootflags=subvol=@ "; fi
	fi
	c+="rw loglevel=3"
	if [[ -n $(nvidia_driver) ]]; then c+=" nvidia_drm.modeset=1"; fi
	printf '%s\n' "$c"
}

# GRUB with Secure Boot loads no modules from disk: build in what it needs.
GRUB_SB_MODULES="all_video boot btrfs cat chain configfile echo efifwsetup efinet ext2 fat font gettext gfxmenu gfxterm gfxterm_background gzio halt help iso9660 jpeg keystatus loadenv loopback linux ls lsefi lsefimmap lsefisystab memdisk minicmd normal part_gpt part_msdos password_pbkdf2 png probe reboot regexp search search_fs_uuid search_fs_file search_label serial sleep smbios test tpm true video cryptodisk luks luks2 gcry_rijndael gcry_sha256 gcry_sha512 pbkdf2 zstd"

grub_settings() {
	local cfg="$TARGET/etc/default/grub" extra=""
	[[ -f $cfg ]] || printf 'GRUB_DISTRIBUTOR="Gentoo"\nGRUB_TIMEOUT=5\nGRUB_CMDLINE_LINUX=""\nGRUB_CMDLINE_LINUX_DEFAULT=""\n' >"$cfg"
	if encrypted; then extra="rd.luks.uuid=$(get_uuid "$ROOT_PART")"; fi
	if [[ -n $(nvidia_driver) ]]; then extra+="${extra:+ }nvidia_drm.modeset=1"; fi
	if grep -q '^GRUB_CMDLINE_LINUX=' "$cfg"; then
		sed -i -E "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"$extra\"|" "$cfg"
	else
		echo "GRUB_CMDLINE_LINUX=\"$extra\"" >>"$cfg"
	fi
	if grub_unlocks; then
		sed -i '/^#\?GRUB_ENABLE_CRYPTODISK=/d' "$cfg"
		echo 'GRUB_ENABLE_CRYPTODISK=y' >>"$cfg"
	fi
	grep -E '^GRUB_(CMDLINE_LINUX|ENABLE_CRYPTODISK)=' "$cfg" || true
}

install_grub() {
	local t
	local -a sb=()
	grub_settings
	if [[ $FIRMWARE == uefi ]]; then
		t=x86_64-efi
		[[ $EFI_BITS == 32 ]] && t=i386-efi
		if secureboot_on; then sb=(--modules="$GRUB_SB_MODULES" --disable-shim-lock); fi
		if ! in_target grub-install --target="$t" --efi-directory="$ESP_MOUNT" --bootloader-id=Gentoo "${sb[@]}"; then
			warn "grub-install could not register a UEFI boot entry; the firmware's fallback path is used."
			in_target grub-install --target="$t" --efi-directory="$ESP_MOUNT" --bootloader-id=Gentoo --no-nvram "${sb[@]}"
		fi
		in_target grub-install --target="$t" --efi-directory="$ESP_MOUNT" --removable "${sb[@]}"
	else
		in_target grub-install --target=i386-pc "$DISK"
	fi
}

# systemd-boot (and UKIs): installed before the kernel, so that kernel-install
# writes the kernel in systemd-boot's layout.
install_systemd_boot() {
	in_target bootctl install --esp-path="$ESP_MOUNT" ||
		in_target bootctl install --esp-path="$ESP_MOUNT" --no-variables
	mkdir -p "$TARGET$ESP_MOUNT/loader"
	printf 'timeout 5\nconsole-mode auto\neditor no\n' >"$TARGET$ESP_MOUNT/loader/loader.conf"
	[[ -f $TARGET$ESP_MOUNT/EFI/systemd/systemd-bootx64.efi ]] || { echo "bootctl did not install systemd-boot" >&2; return 1; }
}

# Runs installkernel again for the installed kernel: initramfs from the final
# configuration, boot loader entry, signatures.
kernel_reinstall() {
	local k=sys-kernel/gentoo-kernel-bin
	[[ $KERNEL == bin ]] || k=sys-kernel/gentoo-kernel
	echo "Installing the kernel into the boot loader (emerge --config $k) ..."
	in_target emerge --config "$k"
}

# ---- Secure Boot (sbctl) --------------------------------------------------------
SB_ENROLLED=0
sb_setup_mode() { # (output captured first: "cmd | grep -q" can fail under pipefail)
	local out
	out=$(in_target sbctl status --json 2>/dev/null) || true
	grep -Eq '"setup_mode": *true' <<<"$out"
}

# Keys before the kernel is emerged: the distribution kernel signs itself (and
# its modules) with them (USE=secureboot, SECUREBOOT_SIGN_KEY in make.conf).
sb_prepare() {
	secureboot_on || return 0
	echo "Secure Boot: creating your own keys (sbctl) ..."
	gemerge --noreplace app-crypt/sbctl
	in_target sbctl create-keys
	if [[ $BOOTLOADER == uki ]]; then
		{
			echo 'uefi_secureboot_cert="/var/lib/sbctl/keys/db/db.pem"'
			echo 'uefi_secureboot_key="/var/lib/sbctl/keys/db/db.key"'
		} >>"$TARGET/etc/dracut.conf.d/10-gentoo-install.conf"
	fi
	# Boot loaders updated later are signed again by installkernel's hook.
	mkdir -p "$TARGET/etc/kernel/postinst.d"
	printf '#!/bin/sh\n# gentoo-install.sh: sign the boot loader and kernels with the sbctl keys\nsbctl sign-all >/dev/null 2>&1\nexit 0\n' >"$TARGET/etc/kernel/postinst.d/95-sbctl-sign"
	chmod 755 "$TARGET/etc/kernel/postinst.d/95-sbctl-sign"
}

sb_sign_all() {
	local e="$ESP_MOUNT" f
	local -a files=()
	secureboot_on || return 0
	case $BOOTLOADER in
		grub) files+=("$e/EFI/Gentoo/grubx64.efi" "$e/EFI/BOOT/BOOTX64.EFI") ;;
		systemd-boot | uki) files+=("$e/EFI/systemd/systemd-bootx64.efi" "$e/EFI/BOOT/BOOTX64.EFI") ;;
	esac
	while IFS= read -r f; do files+=("${f#"$TARGET"}"); done < <(compgen -G "$TARGET/boot/vmlinuz-*" || true; compgen -G "$TARGET$e/EFI/Linux/*.efi" || true)
	for f in "${files[@]}"; do
		if [[ -e $TARGET$f ]]; then
			in_target sbctl sign -s "$f" || warn "Secure Boot: could not sign $f"
		fi
	done
	if sb_setup_mode; then
		echo "Secure Boot: the firmware is in Setup Mode; enrolling your keys (with Microsoft's, for option ROMs) ..."
		if in_target sbctl enroll-keys -m; then
			SB_ENROLLED=1
		else
			warn "Secure Boot: enrolling the keys failed. After booting, run: sudo sbctl enroll-keys -m"
		fi
	else
		warn "Secure Boot: the firmware is not in Setup Mode, so your keys were made and everything is signed, but not enrolled. Put Secure Boot in Setup Mode in the firmware settings, boot the new system, run: sudo sbctl enroll-keys -m   then turn Secure Boot on."
	fi
	in_target sbctl verify || true
	if [[ $SB_ENROLLED == 1 ]]; then
		echo "Secure Boot: keys enrolled. Turn Secure Boot on in the firmware settings after the first boot."
	fi
}

# ---- snapper ---------------------------------------------------------------------
# snapper's create-config makes its own /.snapshots subvolume inside @; use the
# @snapshots subvolume instead (mounted at /.snapshots by fstab), so rolling
# back @ keeps the snapshots. Timeline: systemd timers, or cron with OpenRC.
write_snapper_cron() { # write_snapper_cron <root dir>
	local root=$1
	if compgen -G "$root/etc/cron.hourly/*snapper*" >/dev/null; then
		echo "snapper: its own cron jobs are installed."
		return 0
	fi
	mkdir -p "$root/etc/cron.hourly" "$root/etc/cron.daily"
	printf '#!/bin/sh\n# gentoo-install.sh: hourly snapper timeline snapshot\nexec snapper --no-dbus -c root create -c timeline -d timeline\n' \
		>"$root/etc/cron.hourly/gentoo-snapper-timeline"
	# shellcheck disable=SC2016  # $a is for the cron script
	printf '#!/bin/sh\n# gentoo-install.sh: daily snapper cleanup\nfor a in number timeline empty-pre-post; do snapper --no-dbus -c root cleanup "$a"; done\n' \
		>"$root/etc/cron.daily/gentoo-snapper-cleanup"
	chmod 755 "$root/etc/cron.hourly/gentoo-snapper-timeline" "$root/etc/cron.daily/gentoo-snapper-cleanup"
}

setup_snapper() {
	local rootdev cfg="$TARGET/etc/snapper/configs/root"
	snapper_on || return 0
	rootdev=$(root_device)
	echo "Setting up snapper for / ..."
	umount "$TARGET/.snapshots"
	rmdir "$TARGET/.snapshots"
	in_target snapper --no-dbus -c root create-config /
	btrfs subvolume delete "$TARGET/.snapshots"
	mkdir "$TARGET/.snapshots"
	mount -o "$BTRFS_OPTS,subvol=@snapshots" "$rootdev" "$TARGET/.snapshots"
	chmod 750 "$TARGET/.snapshots"
	sed -i -E \
		-e 's/^ALLOW_GROUPS=.*/ALLOW_GROUPS="wheel"/' \
		-e 's/^NUMBER_LIMIT=.*/NUMBER_LIMIT="10"/' \
		-e 's/^NUMBER_LIMIT_IMPORTANT=.*/NUMBER_LIMIT_IMPORTANT="5"/' \
		-e 's/^TIMELINE_LIMIT_HOURLY=.*/TIMELINE_LIMIT_HOURLY="5"/' \
		-e 's/^TIMELINE_LIMIT_DAILY=.*/TIMELINE_LIMIT_DAILY="7"/' \
		-e 's/^TIMELINE_LIMIT_WEEKLY=.*/TIMELINE_LIMIT_WEEKLY="0"/' \
		-e 's/^TIMELINE_LIMIT_MONTHLY=.*/TIMELINE_LIMIT_MONTHLY="0"/' \
		-e 's/^TIMELINE_LIMIT_YEARLY=.*/TIMELINE_LIMIT_YEARLY="0"/' "$cfg"
	if systemd_on; then
		in_target systemctl enable snapper-timeline.timer snapper-cleanup.timer
	else
		write_snapper_cron "$TARGET"
	fi
	echo "snapper: a snapshot before every update-system run, hourly timeline."
}

# ---- ZFSBootMenu -----------------------------------------------------------------
# Its release images cannot unlock LUKS, so it is built on the new system from
# the pinned release, with dracut's crypt module: it asks for the passphrase,
# imports the pool, lists the boot environments and snapshots, and starts the
# chosen kernel (kexec). The system's initramfs unlocks the disk again with the
# key file (it lies inside the encrypted pool, unlike ZFSBootMenu's image on
# the EFI system partition, which holds no key).
zbm_cmdline() {
	local c="quiet loglevel=0"
	if encrypted; then c="rd.luks.uuid=$(get_uuid "$ROOT_PART") $c"; fi
	printf '%s\n' "$c"
}

write_zbm_config() { # write_zbm_config <root dir>
	local root=$1
	mkdir -p "$root/etc/zfsbootmenu/dracut.conf.d"
	cat >"$root/etc/zfsbootmenu/config.yaml" <<ZC
# Written by gentoo-install.sh. After editing, run: generate-zbm
Global:
  ManageImages: true
  BootMountPoint: $ESP_MOUNT
  DracutConfDir: /etc/zfsbootmenu/dracut.conf.d
  PostHooksDir: /etc/zfsbootmenu/generate-zbm.post.d
Components:
  Enabled: false
EFI:
  ImageDir: $ESP_MOUNT/EFI/zbm
  Versions: false
  Enabled: true
Kernel:
  Prefix: zfsbootmenu
  CommandLine: $(zbm_cmdline)
ZC
	# ZFSBootMenu's own dracut settings (not the system's: no key file here).
	{
		echo "# Written by gentoo-install.sh: ZFSBootMenu's initramfs holds no key."
		if encrypted; then echo 'add_dracutmodules+=" crypt "'; fi
		echo 'omit_dracutmodules+=" systemd "'
	} >"$root/etc/zfsbootmenu/dracut.conf.d/10-gentoo-install.conf"
	mkdir -p "$root/etc/zfsbootmenu/generate-zbm.post.d"
	cat >"$root/etc/zfsbootmenu/generate-zbm.post.d/10-efi-fallback" <<ZF
#!/bin/sh
# gentoo-install.sh: keep the firmware's fallback boot file up to date.
mkdir -p $ESP_MOUNT/EFI/BOOT
cp -f $ESP_MOUNT/EFI/zbm/zfsbootmenu.EFI $ESP_MOUNT/EFI/BOOT/BOOTX64.EFI
ZF
	chmod 755 "$root/etc/zfsbootmenu/generate-zbm.post.d/10-efi-fallback"
	# Rebuilt after every kernel installation (installkernel hook).
	mkdir -p "$root/etc/kernel/postinst.d"
	printf '#!/bin/sh\n# gentoo-install.sh: rebuild ZFSBootMenu after a kernel update\ngenerate-zbm >/dev/null 2>&1 || echo "generate-zbm failed" >&2\nexit 0\n' \
		>"$root/etc/kernel/postinst.d/96-zfsbootmenu"
	chmod 755 "$root/etc/kernel/postinst.d/96-zfsbootmenu"
}

install_zfsbootmenu() {
	local src=/var/tmp/zfsbootmenu-src head first
	echo "Building ZFSBootMenu $ZBM_VERSION ..."
	gemerge --noreplace app-shells/fzf dev-perl/boolean dev-perl/Config-IniFiles dev-perl/Sort-Versions dev-perl/YAML-PP \
		sys-apps/kexec-tools sys-block/mbuffer sys-kernel/dracut dev-vcs/git
	rm -rf "$TARGET$src"
	in_target git clone -q --depth 1 --branch "v$ZBM_VERSION" "$ZBM_GIT" "$src"
	head=$(in_target git -C "$src" rev-parse HEAD)
	if [[ $head != "$ZBM_COMMIT" ]]; then
		echo "ZFSBootMenu v$ZBM_VERSION is commit $head, expected $ZBM_COMMIT; not installing it." >&2
		return 1
	fi
	in_target make -C "$src" install
	rm -rf "$TARGET$src"
	write_zbm_config "$TARGET"
	first=$(cd "$TARGET/boot" && compgen -G 'vmlinuz-*' | sort -V | tail -n1) || first=""
	# What ZFSBootMenu passes to the system's kernel; it adds root=zfs:<dataset>.
	# Set on zroot/ROOT, so every boot environment and snapshot clone inherits it.
	zfs set org.zfsbootmenu:commandline="$(boot_cmdline)" "$ZPOOL/ROOT"
	in_target generate-zbm
	efi_entry "ZFSBootMenu" '\EFI\zbm\zfsbootmenu.EFI' '\EFI\BOOT\BOOTX64.EFI'
	echo "ZFSBootMenu: boots $ZFS_BE (${first:-newest kernel}); other kernels and snapshots from its menu."
}

# register_efi "<label>" '\EFI\dir\file.efi' - (re)create one UEFI boot entry.
register_efi() {
	in_target /bin/bash -s -- "$DISK" "$ESP_NUM" "$1" "$2" <<'EOS'
disk=$1 part=$2 label=$3 loader=$4
efibootmgr 2>/dev/null | while IFS= read -r line; do
	if [[ $line =~ ^Boot([0-9A-Fa-f]{4})\*?[[:space:]](.*)$ ]]; then
		num=${BASH_REMATCH[1]} name=${BASH_REMATCH[2]%%$'\t'*}
		if [[ $name == "$label" ]]; then efibootmgr -q -b "$num" -B || true; fi
	fi
done
efibootmgr -q -c -d "$disk" -p "$part" -L "$label" -l "$loader"
EOS
}

efi_entry() { # efi_entry "<label>" '<loader>' '<fallback path>'
	if register_efi "$1" "$2"; then
		echo "UEFI boot entry '$1' created."
	else
		warn "Could not create the UEFI boot entry '$1'; the firmware fallback $3 will be used."
	fi
}

step_bootloader() {
	case $BOOTLOADER in
		grub) install_grub ;;
		systemd-boot | uki) [[ -f $TARGET$ESP_MOUNT/EFI/systemd/systemd-bootx64.efi ]] || install_systemd_boot ;;
	esac
	kernel_reinstall
	if [[ $BOOTLOADER == grub ]]; then in_target grub-mkconfig -o /boot/grub/grub.cfg; fi
	if [[ $BOOTLOADER == zfsbootmenu ]]; then install_zfsbootmenu; fi
	sb_sign_all
}

# ---- checks ----------------------------------------------------------------------
verify_zfsbootmenu() {
	local e="$TARGET$ESP_MOUNT" img=$ESP_MOUNT/EFI/zbm/zfsbootmenu.EFI listing
	if [[ ! -s $TARGET$img ]]; then
		echo "ZFSBootMenu: $img was not built" >&2
		return 1
	fi
	if [[ ! -s $e/EFI/BOOT/BOOTX64.EFI ]]; then
		echo "ZFSBootMenu: the fallback EFI/BOOT/BOOTX64.EFI is missing" >&2
		return 1
	fi
	if [[ $(zpool get -H -o value bootfs "$ZPOOL") != "$ZFS_BE" ]]; then
		echo "ZFS: bootfs of $ZPOOL is not $ZFS_BE" >&2
		return 1
	fi
	if [[ ! -s $TARGET/etc/hostid ]]; then
		echo "ZFS: /etc/hostid is missing" >&2
		return 1
	fi
	if encrypted; then
		# The image on the unencrypted EFI partition must not hold the key file.
		rm -f "$TARGET/var/tmp/zbm-initrd"
		if in_target objcopy -O binary --only-section=.initrd "$img" /var/tmp/zbm-initrd 2>/dev/null &&
			listing=$(in_target lsinitrd /var/tmp/zbm-initrd 2>/dev/null); then
			rm -f "$TARGET/var/tmp/zbm-initrd"
			if grep -q 'cryptsetup-keys.d' <<<"$listing"; then
				rm -f "$TARGET$img" "$e/EFI/BOOT/BOOTX64.EFI"
				echo "ZFSBootMenu: its image contains the disk key file; removed it" >&2
				return 1
			fi
			if ! grep -q 'cryptsetup' <<<"$listing"; then
				echo "ZFSBootMenu: its image has no cryptsetup (dracut crypt module)" >&2
				return 1
			fi
			echo "OK: ZFSBootMenu unlocks LUKS and holds no key file"
		else
			rm -f "$TARGET/var/tmp/zbm-initrd"
			warn "Could not look inside the ZFSBootMenu image."
		fi
	fi
	echo "OK: ZFSBootMenu ($img), boot environment $ZFS_BE"
}

verify_install() {
	local img listing k
	if [[ $BOOTLOADER == uki ]]; then
		if ! compgen -G "$TARGET$ESP_MOUNT/EFI/Linux/*.efi" >/dev/null; then
			echo "UKI: no unified kernel image in $ESP_MOUNT/EFI/Linux" >&2
			return 1
		fi
		echo "OK: unified kernel image(s): $(cd "$TARGET$ESP_MOUNT/EFI/Linux" && echo *.efi)"
	else
		k=$(cd "$TARGET/boot" 2>/dev/null && compgen -G 'vmlinuz-*' | sort -V | tail -n1) || k=""
		img=""
		if [[ -n $k ]]; then img=/boot/initramfs-${k#vmlinuz-}.img; fi
		if [[ $BOOTLOADER == systemd-boot ]]; then
			img=$(cd "$TARGET" && compgen -G "${ESP_MOUNT#/}/*/*/initrd*" | sort -V | tail -n1) || img=""
			[[ -n $img ]] && img=/$img
		fi
		if [[ -z $img || ! -s $TARGET$img ]]; then
			echo "No kernel / initramfs was installed (looked for ${img:-an initramfs})" >&2
			return 1
		fi
		if encrypted; then
			listing=$(in_target lsinitrd "$img" 2>/dev/null) || listing=""
			if ! grep -q 'cryptsetup' <<<"$listing"; then
				echo "$img does not contain cryptsetup (dracut crypt module)" >&2
				return 1
			fi
			if needs_keyfile && ! grep -q "etc/cryptsetup-keys.d/$CRYPT_NAME.key" <<<"$listing"; then
				echo "$img does not contain the LUKS key file" >&2
				return 1
			fi
		fi
		echo "OK: kernel and initramfs (${img##*/})"
	fi
	case $BOOTLOADER in
		grub)
			if ! grep -q 'linux' "$TARGET/boot/grub/grub.cfg" 2>/dev/null; then
				echo "grub.cfg contains no kernel entries" >&2
				return 1
			fi
			if grub_unlocks && ! grep -q 'cryptomount' "$TARGET/boot/grub/grub.cfg"; then
				echo "grub.cfg does not unlock the encrypted disk (cryptomount missing)" >&2
				return 1
			fi
			echo "OK: /boot/grub/grub.cfg"
			;;
		systemd-boot)
			if ! compgen -G "$TARGET$ESP_MOUNT/loader/entries/*.conf" >/dev/null; then
				echo "systemd-boot: no loader entries were written" >&2
				return 1
			fi
			echo "OK: systemd-boot entries"
			;;
		zfsbootmenu) verify_zfsbootmenu ;;
	esac
}

step_finalize() {
	setup_snapper
	write_update_tools "$TARGET"
	verify_install
	if snapper_on; then
		in_target snapper --no-dbus -c root create -d "after gentoo-install.sh" || true
	fi
	if zfs_on; then
		# The freshly installed system, bootable from ZFSBootMenu's snapshot list.
		zfs snapshot "$ZFS_BE@install" || warn "Could not snapshot $ZFS_BE."
	fi
	cp "$LOG" "$TARGET/var/log/gentoo-install.log" 2>/dev/null || true
	# The settings of this install as a preset, to install the same system again.
	if [[ -d $TARGET/root ]]; then
		preset_write "$TARGET/root/gentoo-install.preset" "${PRESET_LABEL:-$(printf '%s' "${HOST_NAME,,}" | tr -c 'a-z0-9._-' '-')}" 2>/dev/null || true
	fi
	chmod 600 "$TARGET/var/log/gentoo-install.log" 2>/dev/null || true
	sync
}
# =============================================================================
#  Installation driver
# =============================================================================
cleanup_target() {
	sync
	if mountpoint -q "$TARGET" 2>/dev/null; then
		umount -R "$TARGET" 2>/dev/null || umount -Rl "$TARGET" 2>/dev/null || true
	fi
	if zfs_on && command -v zpool >/dev/null && zpool list "$ZPOOL" >/dev/null 2>&1; then
		zpool export "$ZPOOL" 2>/dev/null || zpool export -f "$ZPOOL" 2>/dev/null || true
	fi
	if [[ -e /dev/mapper/$CRYPT_NAME ]]; then
		local i
		for i in 1 2 3 4 5; do
			cryptsetup close "$CRYPT_NAME" 2>/dev/null && break
			sleep 1
		done
	fi
	INSTALL_STARTED=0
}

# Run one installation step in a subshell with strict error handling, showing
# its output live in a dialog progress box and appending it to $LOG.
# Must be called as a plain command (never inside if/while/&&/||), or bash
# disables "set -e" inside the step.
run_step() { # run_step "title" function
	local title=$1 fn=$2 rows=24 cols=80 size
	size=$(stty size </dev/tty 2>/dev/null) || size=""
	if [[ $size =~ ^([0-9]+)\ ([0-9]+)$ ]]; then
		rows=${BASH_REMATCH[1]}
		cols=${BASH_REMATCH[2]}
	fi
	((rows >= 12)) || rows=24
	((cols >= 50)) || cols=80
	printf '\n===== %s =====\n' "$title" >>"$LOG"
	(
		set -Eeuo pipefail
		shopt -s inherit_errexit
		trap 'echo "ERROR: \"$BASH_COMMAND\" failed with exit status $? (line $LINENO)" >&2' ERR
		"$fn"
	) </dev/null 2>&1 | mask_secrets | tee -a "$LOG" |
		{
			dialog --backtitle "$BACKTITLE" --title " $title " --progressbox $((rows - 4)) $((cols - 4)) >/dev/tty 2>&1
			cat >/dev/null
		}
	return "${PIPESTATUS[0]}"
}

log_settings() {
	{
		echo "gentoo-install.sh $SCRIPT_VERSION - $(date)"
		echo "firmware=$FIRMWARE efi_bits=$EFI_BITS disk=$DISK fs=$FS enc=$ENC bootloader=$BOOTLOADER grub_boot=$GRUB_BOOT secureboot=$SECUREBOOT snapper=$SNAPPER"
		echo "init=$INIT profile=$(gentoo_profile) build=$BUILD jobs=$(make_jobs) emerge_jobs=$(emerge_jobs) march=$(march_flag) kernel=$KERNEL guru=$GURU"
		echo "swap=$SWAP swap_size=$SWAP_SIZE mirror=$MIRROR overlays=$(lbl_overlays)"
		echo "hostname=$HOST_NAME keymap=$KEYMAP locale=$LOCALE timezone=$TIMEZONE user=$USER_NAME"
		echo "net=$NET desktop=$DESKTOP dm=$(desktop_dm) dotfiles=$DOTS extras=$EXTRA_PKGS"
		echo "gpu=$GPU (effective: $(gpu_list)) apps=$APPS gaming=$GAMING peripherals=$PERIPH"
		local u
		for u in "${USERS[@]}"; do echo "user=$u sudo=${U_SUDO[$u]}"; done
		echo "bootstrap: progs=$BS_PROGS dotfiles=$BS_DOTFILES branch=$BS_BRANCH shell=$BS_SHELL power=$BS_POWER"
		echo "partitions: ${ALL_PARTS[*]} (esp=$ESP_PART#$ESP_NUM biosboot=$BIOSBOOT_PART#$BIOSBOOT_NUM boot=$BOOT_PART#$BOOT_NUM root=$ROOT_PART#$ROOT_NUM)"
	} | mask_secrets >>"$LOG"
}

install_failed() {
	local title=$1 tailf c
	tailf=$(mktemp)
	tail -n 80 "$LOG" >"$tailf"
	dialog --backtitle "$BACKTITLE" --title " Failed: $title " --exit-label "Continue" \
		--textbox "$tailf" 0 0 >/dev/tty 2>&1 || true
	rm -f "$tailf"
	while true; do
		c=$(ui --title " Installation failed " --cancel-label "Exit" --menu \
			"The installation stopped during:\n  $title\n\nFull log: $LOG" 15 74 3 \
			shell "Open a shell to investigate ('exit' comes back)" \
			menu "Unmount, back to the main menu (settings are kept)" \
			exit "Unmount everything and exit") || c="exit"
		case $c in
			shell)
				clear
				echo "The new system is mounted at $TARGET. Log: $LOG. Type 'exit' when done."
				run_shell bash -i
				;;
			menu)
				cleanup_target
				return 0
				;;
			*)
				cleanup_target
				clear
				echo "Installation failed during: $title"
				echo "See $LOG for details."
				exit 1
				;;
		esac
	done
}

install_done() {
	local c warnings=""
	if [[ -s $WARN_FILE ]]; then
		warnings="\n\n\Z3Warnings:\Zn\n$(sed 's/$/\\n/' "$WARN_FILE" | tr -d '\n')"
	fi
	while true; do
		c=$(ui --title " Installation complete " --cancel-label "Exit" --menu \
			"Gentoo Linux is installed on $DISK. Update it later with: sudo update-system\nRemove the installation medium before booting the new system.${warnings}" 0 0 4 \
			reboot "Unmount and reboot" \
			poweroff "Unmount and power off" \
			chroot "Open a shell inside the new system" \
			exit "Unmount and return to the live system") || c="exit"
		case $c in
			chroot)
				clear
				echo "You are inside the new system. Type 'exit' to return to the installer."
				run_shell chroot "$TARGET" /usr/bin/env -i HOME=/root TERM="${TERM:-linux}" \
					PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin /bin/bash -l
				;;
			reboot) cleanup_target; clear; reboot; exit 0 ;;
			poweroff) cleanup_target; clear; poweroff; exit 0 ;;
			*)
				cleanup_target
				clear
				echo "Done. The installation log was saved to /var/log/gentoo-install.log on the new system,"
				echo "and these settings as a preset to /root/gentoo-install.preset (load it with --preset)."
				exit 0
				;;
		esac
	done
}

do_install() {
	local -a titles=() funcs=()
	local i n rc

	titles+=("Preparing the live system") funcs+=(step_prepare_live)
	titles+=("Partitioning $DISK") funcs+=(step_partition)
	if encrypted; then titles+=("Setting up $(enc_desc) encryption") funcs+=(step_encrypt); fi
	titles+=("Creating filesystems") funcs+=(step_filesystems)
	titles+=("Downloading and checking the stage3") funcs+=(step_stage3)
	titles+=("Portage: repository, profile, @world ($([[ $BUILD == bin ]] && echo 'prebuilt' || echo 'compiling'), $(make_jobs) jobs)") funcs+=(step_portage)
	titles+=("Configuring the system") funcs+=(step_configure)
	titles+=("Kernel ($(lbl_kernel)), firmware, initramfs") funcs+=(step_kernel)
	titles+=("Installing packages (this can take long)") funcs+=(step_packages)
	if bootstrap_wanted; then titles+=("Bootstrap: programs, dotfiles, shell") funcs+=(step_bootstrap_user); fi
	titles+=("Installing the boot loader ($BOOTLOADER)$(secureboot_on && echo ', Secure Boot')") funcs+=(step_bootloader)
	titles+=("Finishing$({ snapper_on || zfs_on; } && echo ': snapshots,') update-system, checks") funcs+=(step_finalize)

	: >"$WARN_FILE"
	log_settings
	INSTALL_STARTED=1
	n=${#funcs[@]}
	for ((i = 0; i < n; i++)); do
		# Do NOT call run_step inside "if"/"||": bash would then silently disable
		# "set -e" inside the step and a failing command would go unnoticed.
		run_step "[$((i + 1))/$n] ${titles[i]}" "${funcs[i]}"
		rc=$?
		if ((rc != 0)); then
			install_failed "${titles[i]}"
			return 1
		fi
	done
	install_done
}

# =============================================================================
#  Presets: every setting except the disk, passwords and users
# =============================================================================
# A preset is a text file:
#     # gentoo-install preset v1
#     # name: my-desktop
#     FS=btrfs
#     DESKTOP=xfce sway
# It is never run or sourced. Only the keys in PRESET_KEYS are accepted, each
# value must pass preset_check, and anything else rejects the whole file.
# Its ID is <name>@<first 16 hex digits of the SHA-256 of its settings>; loading
# "<file, link or name>@<ID digits>" refuses a preset whose settings differ.
PRESET_KEYS=(INIT BUILD CPU_JOBS EMERGE_JOBS CPU_MARCH KERNEL GURU FS ENC GRUB_BOOT BOOTLOADER SECUREBOOT SNAPPER SWAP SWAP_SIZE MIRROR
	HOST_NAME KEYMAP LOCALE TIMEZONE NET DESKTOP DM DOTS GPU APPS GAMING PERIPH EXTRA_PKGS
	BS_PROGS BS_DOTFILES BS_BRANCH BS_SHELL BS_POWER)
PRESET_REPO=${GENTOO_INSTALL_PRESETS:-https://raw.githubusercontent.com/aranmi-git/gentoo-install/main/presets}
PRESET_MAX_BYTES=65536
PRESET_ID=""      # ID of the loaded preset (shown in the main menu)
PRESET_LABEL=""   # its name
PRESET_ERR=""     # why the last load failed
PRESET_SKIPPED="" # keys left out by preset_write
MENU_JUMP=""      # main menu item to highlight next
declare -A PRESET_NEW=() PRESET_OLD=()

one_of() { # one_of <value> <option>...
	local v=$1 o
	shift
	for o in "$@"; do [[ $v == "$o" ]] && return 0; done
	return 1
}

all_of() { # all_of "<words>" <option>... : every word is an option, none twice
	local w seen=" "
	[[ $1 =~ ^[A-Za-z0-9._+\ -]*$ ]] || return 1 # no glob characters before splitting
	for w in $1; do
		one_of "$w" "${@:2}" || return 1
		[[ $seen != *" $w "* ]] || return 1
		seen+="$w "
	done
}

pkg_words_ok() { # packages: [category/]name, each part starting with a letter or digit (no options)
	local w
	[[ $1 =~ ^[A-Za-z0-9._+/\ -]*$ ]] || return 1
	for w in $1; do [[ $w =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*(/[A-Za-z0-9][A-Za-z0-9._+-]*)?$ ]] || return 1; done
}

# Is <value> allowed for <key> in a preset?
preset_check() { # preset_check <key> <value>
	local k=$1 v=$2 w seen=" "
	local re_host='[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?'
	local re_path='(/[A-Za-z0-9._~%+=-]*)*'
	case $k in
		FS) one_of "$v" ext4 btrfs zfs ;;
		ENC) one_of "$v" none luks1 luks2 ;;
		GRUB_BOOT) one_of "$v" encrypted separate ;;
		INIT) one_of "$v" openrc systemd ;;
		BUILD) one_of "$v" bin source ;;
		CPU_JOBS) [[ $v == auto || ($v =~ ^[1-9][0-9]{0,2}$ && $v -le 512) ]] ;;
		EMERGE_JOBS) [[ $v == auto || $v =~ ^[1-9][0-9]?$ ]] ;;
		CPU_MARCH) one_of "$v" generic v3 native ;;
		KERNEL) one_of "$v" bin dist ;;
		GURU) one_of "$v" 0 1 ;;
		BOOTLOADER) one_of "$v" grub systemd-boot uki zfsbootmenu ;;
		SWAP) one_of "$v" none zram file ;;
		SWAP_SIZE) [[ $v =~ ^[1-9][0-9]{0,2}$ ]] && ((v <= 128)) ;;
		SECUREBOOT | SNAPPER) one_of "$v" 0 1 ;;
		MIRROR) one_of "$v" auto rank ;;
		HOST_NAME) [[ $v =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] ;;
		KEYMAP) [[ $v =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$ ]] ;;
		LOCALE) [[ $v =~ ^[A-Za-z_]+\.UTF-8(@[A-Za-z]+)?$ ]] ;;
		TIMEZONE)
			[[ $v == UTC ]] && return 0
			[[ $v =~ ^[A-Z][A-Za-z_]+(/[A-Za-z0-9_+-]+){1,2}$ ]] || return 1
			[[ ! -d /usr/share/zoneinfo || -f /usr/share/zoneinfo/$v ]]
			;;
		NET) one_of "$v" nm dhcpcd networkd none ;;
		DESKTOP)
			[[ $v == none ]] && return 0
			[[ -n $v ]] || return 1
			# shellcheck disable=SC2046  # ids are single words
			all_of "$v" $(desktop_table | cut -d'|' -f1)
			;;
		DM) one_of "$v" auto lightdm sddm gdm greetd ly none ;;
		DOTS)
			# shellcheck disable=SC2046
			all_of "$v" $(dots_table | cut -d'|' -f1)
			;;
		GPU)
			one_of "$v" auto none && return 0
			[[ -n $v ]] && all_of "$v" intel amd nouveau nvidia vm
			;;
		APPS)
			all_of "$v" firefox chrome thunderbird vlc mpv libreoffice gimp obs keepassxc \
				telegram-desktop discord flatpak git htop neovim openssh cups
			;;
		GAMING) all_of "$v" steam wine winetricks lutris gamemode ;;
		PERIPH)
			# shellcheck disable=SC2046  # ids are single words
			all_of "$v" $(periph_ids) && ! { has "$v" openlinkhub && has "$v" ckb-next; }
			;;
		EXTRA_PKGS) pkg_words_ok "$v" ;;
		BS_POWER) one_of "$v" 0 1 ;;
		BS_PROGS) [[ -z $v || $v =~ ^https://${re_host}${re_path}$ ]] ;;
		BS_DOTFILES)
			[[ -z $v || $v =~ ^https://${re_host}${re_path}$ ||
				$v =~ ^git@[A-Za-z0-9.-]+:[A-Za-z0-9._~-]+(/[A-Za-z0-9._~-]+)*$ ]]
			;;
		BS_BRANCH) [[ -z $v || $v =~ ^[A-Za-z0-9._][A-Za-z0-9._/-]{0,99}$ ]] ;;
		BS_SHELL) one_of "$v" bash zsh fish ;;
		*) return 1 ;;
	esac
}

preset_norm() { # one value with runs of blanks collapsed
	local -a w=()
	read -r -a w <<<"$1" || true
	printf '%s' "${w[*]}"
}

# The settings in a fixed order; the ID is computed from exactly this text.
preset_canon() {
	local k
	for k in "${PRESET_KEYS[@]}"; do
		if [[ -n ${PRESET_NEW[$k]+x} ]]; then printf '%s=%s\n' "$k" "${PRESET_NEW[$k]}"; fi
	done
}

preset_hash() { preset_canon | sha256sum | cut -c1-16; }
preset_hash_full() { preset_canon | sha256sum | cut -d' ' -f1; }

valid_preset_name() { [[ $1 =~ ^[a-z0-9][a-z0-9._-]{0,39}$ ]]; }

# Read a preset file into PRESET_NEW. Nothing is applied. 1 + PRESET_ERR on error.
preset_parse() { # preset_parse <file>
	local f=$1 line t k v n=0 bytes
	PRESET_NEW=() PRESET_ERR="" PRESET_LABEL=""
	bytes=$(wc -c <"$f" 2>/dev/null) || bytes=-1
	if ((bytes < 0 || bytes > PRESET_MAX_BYTES)); then
		PRESET_ERR="The file is missing or larger than $((PRESET_MAX_BYTES / 1024)) KiB."
		return 1
	fi
	if LC_ALL=C grep -q $'[\x01-\x08\x0b\x0e-\x1f\x7f]' "$f" || [[ $(tr -d '\000' <"$f" | wc -c) != "$bytes" ]]; then
		PRESET_ERR="The file contains control characters; it is not a preset."
		return 1
	fi
	# A preset never holds secrets. Refuse a file that looks like it does (in a
	# setting or a comment), so a password is not shared by accident.
	t=$(grep -niE '(^|[^a-z])(pass(word|wd|phrase)?|pw|secret|token|api[_-]?key|private[_-]?key|luks[_-]?key)[a-z_]*[[:space:]]*[=:]' "$f" | head -n 1 | cut -d: -f1)
	if [[ -n $t ]]; then
		PRESET_ERR="Line $t looks like a password or other secret. A preset never holds passwords (root, users, encryption) or keys; remove that line."
		return 1
	fi
	while IFS= read -r line || [[ -n $line ]]; do
		n=$((n + 1))
		line=${line%$'\r'}
		if ((n == 1)); then
			if [[ ! $line =~ ^#\ gentoo-install\ preset\ v1[[:space:]]*$ ]]; then
				PRESET_ERR="The first line must be: # gentoo-install preset v1"
				return 1
			fi
			continue
		fi
		t=$(trim "$line")
		[[ -z $t ]] && continue
		if [[ $t == \#* ]]; then
			if [[ $t =~ ^#\ *name:\ *([a-z0-9][a-z0-9._-]{0,39})$ ]]; then PRESET_LABEL=${BASH_REMATCH[1]}; fi
			continue
		fi
		if [[ ! $t =~ ^([A-Z_]+)=(.*)$ ]]; then
			PRESET_ERR="Line $n is not KEY=value."
			return 1
		fi
		k=${BASH_REMATCH[1]}
		v=$(preset_norm "${BASH_REMATCH[2]}")
		if ! one_of "$k" "${PRESET_KEYS[@]}"; then
			case $k in
				DISK | ROOT_PASS | LUKS_PASS | USER_NAME | USERS | U_*) PRESET_ERR="Line $n: $k must not be in a preset; the installer always asks for it." ;;
				*) PRESET_ERR="Line $n: unknown setting $k." ;;
			esac
			return 1
		fi
		if [[ -n ${PRESET_NEW[$k]+x} ]]; then
			PRESET_ERR="Line $n: $k is set twice."
			return 1
		fi
		if ! preset_check "$k" "$v"; then
			v=${v//\\/}
			PRESET_ERR="Line $n: invalid value for $k: ${v:0:60}"
			return 1
		fi
		PRESET_NEW[$k]=$v
	done <"$f"
	if ((n == 0)); then
		PRESET_ERR="The file is empty."
		return 1
	fi
	if ((${#PRESET_NEW[@]} == 0)); then
		PRESET_ERR="The file holds no settings."
		return 1
	fi
	return 0
}

# Get a preset to <dest>: a local file, an https:// link, or a name from PRESET_REPO.
preset_fetch() { # preset_fetch <spec> <dest>; sets PRESET_SRC
	local spec=$1 dest=$2 url
	PRESET_SRC=""
	if [[ $spec == https://* ]]; then
		url=$spec
	elif [[ $spec =~ ^[a-z][a-z0-9+.-]*:// ]]; then
		PRESET_ERR="Only https:// links are accepted for presets."
		return 1
	elif [[ -e $spec || $spec == */* ]]; then
		if [[ ! -f $spec || ! -r $spec ]]; then
			PRESET_ERR="File not found: $spec"
			return 1
		fi
		cp -- "$spec" "$dest" || { PRESET_ERR="Cannot read $spec"; return 1; }
		PRESET_SRC=$(readlink -f -- "$spec")
		return 0
	elif valid_preset_name "$spec"; then
		if [[ $PRESET_REPO != https://* ]]; then
			PRESET_ERR="VOID_INSTALL_PRESETS must be an https:// address."
			return 1
		fi
		url="${PRESET_REPO%/}/$spec.preset"
	else
		PRESET_ERR="Not a file, an https:// link or a preset name: $spec"
		return 1
	fi
	if [[ $url =~ ^https://[^/]*@ || $url =~ [[:space:]] ]]; then
		PRESET_ERR="Links with a user name, token or spaces are not accepted."
		return 1
	fi
	PRESET_SRC=$url
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL --proto '=https' --proto-redir '=https' --max-time 60 \
			--max-filesize "$PRESET_MAX_BYTES" -o "$dest" -- "$url" >/dev/null 2>&1 ||
			{ PRESET_ERR="Could not download $url"; return 1; }
	else
		PRESET_ERR="curl is not available to download $url"
		return 1
	fi
	return 0
}

preset_backup() {
	local k
	PRESET_OLD=()
	for k in "${PRESET_KEYS[@]}"; do PRESET_OLD[$k]=${!k}; done
}

preset_restore() {
	local k
	for k in "${PRESET_KEYS[@]}"; do printf -v "$k" '%s' "${PRESET_OLD[$k]}"; done
}

# Apply PRESET_NEW; settings it does not name are reset to the defaults.
preset_apply() {
	local k
	FS=ext4 ENC=luks2 BOOTLOADER=grub GRUB_BOOT=encrypted SECUREBOOT=0 SNAPPER=0 SWAP=zram SWAP_SIZE=4
	INIT=openrc BUILD=bin CPU_JOBS=auto EMERGE_JOBS=auto CPU_MARCH=generic KERNEL=bin GURU=0 MIRROR=auto HOST_NAME=gentoo KEYMAP=us
	LOCALE=en_US.UTF-8 TIMEZONE=UTC NET=nm DESKTOP=none DM=auto DOTS="" GPU=auto APPS=""
	GAMING="" PERIPH="" EXTRA_PKGS="" BS_PROGS="" BS_DOTFILES="" BS_BRANCH=""
	BS_SHELL=bash BS_POWER=0
	for k in "${PRESET_KEYS[@]}"; do
		if [[ -n ${PRESET_NEW[$k]+x} ]]; then printf -v "$k" '%s' "${PRESET_NEW[$k]}"; fi
	done
	prune_dots
}

# Problems of the applied preset on this computer (empty: none).
preset_notes() {
	if uefi_only && [[ $FIRMWARE != uefi || $EFI_BITS != 64 ]]; then
		printf '\\Z1%s needs 64-bit UEFI; this computer started with %s. Choose another boot loader.\\Zn\\n' "$(lbl_boot)" "${FIRMWARE^^}"
	fi
	if [[ $FS == zfs && $BOOTLOADER != zfsbootmenu ]] || [[ $FS != zfs && $BOOTLOADER == zfsbootmenu ]]; then
		printf '\\Z1ZFS and ZFSBootMenu go together; this preset has FS=%s with %s.\\Zn\\n' "$FS" "$(lbl_boot)"
	fi
	if [[ -n $PRUNED ]]; then
		printf 'Dotfile presets dropped (their desktop is not in the preset): %s\\n' "$PRUNED"
	fi
}

preset_summary() { # preset_summary <id> <verified: 0/1/2> -> dialog text
	local id=$1 ver=$2 ext=""
	case $ver in
		1) printf 'Preset   \\Zb%s\\Zn  \\Z2(fingerprint verified)\\Zn\\n' "$id" ;;
		*) printf 'Preset   \\Zb%s\\Zn\\n         \\Z3Not verified: load it as %s to check it next time.\\Zn\\n' "$id" "$id" ;;
	esac
	printf 'From     %s\n\n' "$(printf '%s' "$PRESET_SRC" | mask_secrets)"
	printf 'System   %s, %s\n' "$(lbl_init)" "$(gentoo_profile)"
	printf 'Build    %s\n' "$(lbl_build)"
	printf 'Disk     %s, encryption: %s\n' "$FS" "$(enc_desc)"
	printf 'Boot     %s; swap: %s\n' "$(lbl_boot)" "$(lbl_swap)"
	printf 'Kernel   %s\n' "$(lbl_kernel)"
	printf 'Boot+    Secure Boot: %s; snapshots: %s\n' "$(lbl_sb)" "$(lbl_snapper)"
	printf 'Mirrors  %s\n' "$(lbl_mirror)"
	printf 'Host     %s, keymap %s, %s, %s\n' "$HOST_NAME" "$KEYMAP" "$(lbl_locale)" "$TIMEZONE"
	printf 'Network  %s\n' "$(lbl_net)"
	printf 'Desktop  %s; login: %s\n' "$(lbl_desktop)" "$(lbl_dm)"
	printf 'Dotfiles %s\n' "$(lbl_dots)"
	printf 'GPU      %s\n' "$(lbl_gpu)"
	printf 'Apps     %s\n' "$(lbl_list "$APPS")"
	printf 'Gaming   %s\n' "$(lbl_list "$GAMING")"
	printf 'Devices  %s\n' "$(lbl_periph)"
	printf 'Packages %s\n' "${EXTRA_PKGS:-(none)}"
	printf 'Overlays %s\n' "$(lbl_overlays)"
	if [[ -n $BS_PROGS ]]; then ext+="  programs list: $BS_PROGS\\n"; fi
	if has "$PERIPH" openlinkhub; then ext+="  OpenLinkHub (Corsair): github.com/jurkovic-nikola/OpenLinkHub, pinned release\\n"; fi
	if guru_on; then ext+="  the GURU community overlay\\n"; fi
	if hypr_on; then ext+="  the hyproverlay community repository (Hyprland)\\n"; fi

	if [[ -n $BS_DOTFILES ]]; then ext+="  dotfiles: $BS_DOTFILES${BS_BRANCH:+ ($BS_BRANCH)}\\n"; fi
	if [[ -n $ext ]]; then
		printf '\n\\Z3\\ZbThis preset installs programs and files from outside the Gentoo repository:\\Zn\n%s\\Z3Load it only if you trust these sources.\\Zn\n' "$ext"
	fi
	printf '\nNot in a preset (asked next): disk, root password, users%s.\n' "$(encrypted && printf ', encryption passphrase')"
}

# Fetch, check, show and (if confirmed) apply a preset. 0 = applied.
preset_load() { # preset_load <file | https link | name>[@ID]
	local spec expect="" tmp full id ver=0 notes
	spec=$(trim "$1")
	if [[ $spec =~ ^(.+)@([0-9A-Fa-f]{16,64})$ ]]; then
		spec=${BASH_REMATCH[1]}
		expect=${BASH_REMATCH[2],,}
	fi
	tmp=$(mktemp /tmp/arch-preset.XXXXXX) || return 1
	if ! preset_fetch "$spec" "$tmp" || ! preset_parse "$tmp"; then
		rm -f -- "$tmp"
		msg "This preset was not loaded:\n\n$(printf '%s' "$PRESET_ERR" | mask_secrets)\n\nNo setting was changed." "Preset" 12 74
		return 1
	fi
	rm -f -- "$tmp"
	full=$(preset_hash_full)
	if [[ -n $expect ]]; then
		if [[ ${full:0:${#expect}} != "$expect" ]]; then
			msg "\Z1\ZbThe preset does not match its ID.\Zn\n\nExpected: $expect\nFound:    ${full:0:${#expect}}\n\nIt was changed after the ID was made, or it is a different preset. It was not loaded and no setting was changed." "Preset: wrong fingerprint" 13 74
			return 1
		fi
		ver=1
	fi
	if [[ -z $PRESET_LABEL ]]; then
		PRESET_LABEL=$(basename -- "$spec" .preset)
		valid_preset_name "$PRESET_LABEL" || PRESET_LABEL=preset
	fi
	id="$PRESET_LABEL@${full:0:16}"
	preset_backup
	preset_apply
	notes=$(preset_notes)
	if ! dialog --backtitle "$BACKTITLE" --colors --cr-wrap --no-collapse --title " Load this preset? " --scrollbar \
		--yes-label "Load" --no-label "Cancel" --yesno "$(preset_summary "$id" "$ver")${notes:+\n\n$notes}" 0 0 >/dev/tty 2>&1; then
		preset_restore
		prune_dots
		return 1
	fi
	PRESET_ID=$id
	printf 'Loaded preset %s from %s (verified: %s)\n' "$id" "$PRESET_SRC" "$ver" | mask_secrets >>"$LOG" 2>/dev/null || true
	if [[ -n $notes && $notes == *Z1* ]]; then MENU_JUMP=Bootloader; else MENU_JUMP=Install; fi
	return 0
}

# Write the current settings as a preset. Values a preset cannot hold
# (a local programs list, a link with credentials) are left out: PRESET_SKIPPED.
preset_write() { # preset_write <file> <name>
	local f=$1 name=$2 k v
	PRESET_NEW=() PRESET_SKIPPED=""
	for k in "${PRESET_KEYS[@]}"; do
		v=$(preset_norm "${!k}")
		if preset_check "$k" "$v"; then PRESET_NEW[$k]=$v; else PRESET_SKIPPED+="${PRESET_SKIPPED:+ }$k"; fi
	done
	(
		umask 022
		{
			echo "# gentoo-install preset v1"
			echo "# name: $name"
			echo "# id: $name@$(preset_hash)"
			echo "# Made by gentoo-install.sh $SCRIPT_VERSION on $(date +%F)."
			echo "# Load it with:  bash gentoo-install.sh --preset <this file, an https link or a name>"
			echo "# Disk, passwords and users are never stored here; the installer asks for them."
			preset_canon
		} >"$f"
	)
}

# Ask for what a preset never contains, then show the main menu.
preset_quick() {
	msg "Preset loaded: \Zb$PRESET_ID\Zn\n\nNow the parts a preset never contains: the disk, the root password, the users$(encrypted && printf ' and the encryption passphrase').\n\nAfterwards the main menu opens with \ZbInstall\Zn selected. Every setting can still be changed there." "Preset" 13 70
	menu_disk || true
	if [[ -z $ROOT_PASS ]]; then menu_rootpass || true; fi
	if ((${#USERS[@]} == 0)); then user_dialog || true; fi
	if encrypted && [[ -z $LUKS_PASS ]]; then ask_luks_pass || true; fi
	return 0
}

lbl_preset() {
	if [[ -n $PRESET_ID ]]; then printf '%s' "$PRESET_ID"; else printf '(none) - load or save all settings'; fi
}

menu_preset() {
	local c v name f def
	c=$(ui --title " Preset " --menu \
		"A preset holds every setting except the disk, the passwords and the users, so the same system can be installed again with a few answers. Its ID ends in a fingerprint of the settings." \
		13 78 3 \
		load "Load a preset: file, https:// link or name" \
		save "Save the current settings as a preset" \
		id "Show the ID of the current settings") || return 1
	case $c in
		load)
			v=$(ui --title " Load a preset " --inputbox \
				"Enter one of:\n  a file:   /mnt/usb/desktop.preset\n  a link:   https://example.org/desktop.preset\n  a name:   xfce-desktop  (from the presets folder of the repository)\n\nAdd @ and the ID's digits to verify it:  xfce-desktop@1a2b3c4d5e6f7a8b" \
				15 78) || return 1
			[[ -n $(trim "$v") ]] || return 1
			preset_load "$v" || return 1
			preset_quick
			;;
		save)
			def=${PRESET_LABEL:-$(printf '%s' "${HOST_NAME,,}" | tr -c 'a-z0-9._-' '-')}
			valid_preset_name "$def" || def=my-preset
			name=$(ui --title " Save a preset " --inputbox "Name (lowercase letters, digits, '.', '_', '-'):" 9 64 "$def") || return 1
			if ! valid_preset_name "$name"; then
				msg "Use 1-40 lowercase letters, digits, '.', '_' or '-', starting with a letter or digit." "Preset"
				return 1
			fi
			f=$(ui --title " Save a preset " --inputbox "Save to (a USB stick keeps it; /root is lost when the live system shuts down):" 9 78 "/root/$name.preset") || return 1
			f=$(trim "$f")
			if [[ -z $f || -d $f ]]; then msg "Enter a file name, not a folder." "Preset"; return 1; fi
			if [[ -e $f ]] && ! yesno "$f exists.\n\nReplace it?" "Preset" 1; then return 1; fi
			if ! preset_write "$f" "$name" 2>/dev/null; then
				msg "Cannot write $f" "Preset"
				return 1
			fi
			PRESET_LABEL=$name PRESET_ID="$name@$(preset_hash)"
			msg "Saved: $f\n\nID: \Zb$PRESET_ID\Zn\n\nInstall the same system elsewhere with:\n  bash gentoo-install.sh --preset $f@${PRESET_ID#*@}\n\nOr add the file to the presets/ folder of the repository as $name.preset and use:\n  bash gentoo-install.sh --preset $PRESET_ID${PRESET_SKIPPED:+\n\n\Z3Left out (a preset cannot hold them): $PRESET_SKIPPED\Zn}" "Preset saved" 19 78
			;;
		id)
			preset_write /dev/null "${PRESET_LABEL:-preset}"
			msg "ID of the current settings:\n\n  \Zb${PRESET_LABEL:-preset}@$(preset_hash)\Zn\n\nIt changes whenever a setting changes. The disk, passwords and users are not part of it.${PRESET_SKIPPED:+\n\n\Z3Not part of a preset: $PRESET_SKIPPED\Zn}" "Preset ID" 13 74
			;;
	esac
	return 0
}

# =============================================================================
#  Main menu
# =============================================================================
MENU_ORDER=(Preset Disk Init Build Filesystem Encryption Bootloader Secure-Boot Snapshots Swap Kernel Mirrors Hostname
	Keyboard Locale Timezone Root-password Users Network Desktop Login Dotfiles GPU Apps Gaming Peripherals Packages Overlays Bootstrap Install)

next_item() {
	local i
	for i in "${!MENU_ORDER[@]}"; do
		if [[ ${MENU_ORDER[i]} == "$1" ]]; then
			echo "${MENU_ORDER[i + 1]:-Install}"
			return 0
		fi
	done
	echo Install
}

main_menu() {
	local choice next=${1:-Disk} fw ok
	fw=${FIRMWARE^^}
	[[ $FIRMWARE == uefi ]] && fw+=" ${EFI_BITS}-bit"
	while true; do
		choice=$(ui --title " Gentoo Linux installation " --default-item "$next" --cancel-label "Exit" \
			--menu "Set the options, then choose \ZbInstall\Zn. Firmware: \Zb$fw\Zn" 0 0 0 \
			Preset "$(lbl_preset)" \
			Disk "$(lbl_disk)" \
			Init "$(lbl_init)" \
			Build "$(lbl_build)" \
			Filesystem "$FS" \
			Encryption "$(lbl_enc)" \
			Bootloader "$(lbl_boot)" \
			Secure-Boot "$(lbl_sb)" \
			Snapshots "$(lbl_snapper)" \
			Swap "$(lbl_swap)" \
			Kernel "$(lbl_kernel)" \
			Mirrors "$(lbl_mirror)" \
			Hostname "$HOST_NAME" \
			Keyboard "$KEYMAP" \
			Locale "$(lbl_locale)" \
			Timezone "$TIMEZONE" \
			Root-password "$(lbl_set "$ROOT_PASS")" \
			Users "$(lbl_user)" \
			Network "$(lbl_net)" \
			Desktop "$(lbl_desktop)" \
			Login "$(lbl_dm)" \
			Dotfiles "$(lbl_dots)" \
			GPU "$(lbl_gpu)" \
			Apps "$(lbl_list "$APPS")" \
			Gaming "$(lbl_list "$GAMING")" \
			Peripherals "$(lbl_periph)" \
			Packages "${EXTRA_PKGS:-(none)}" \
			Overlays "$(lbl_overlays)" \
			Bootstrap "$(lbl_bootstrap)" \
			Install "\Zb>>> Start the installation\Zn")
		ok=$?
		if ((ok != 0)); then
			if yesno "Exit the installer? Nothing has been written to disk." "Exit" 1; then
				clear
				exit 0
			fi
			continue
		fi
		ok=0
		case $choice in
			Preset) menu_preset || ok=1 ;;
			Disk) menu_disk || ok=1 ;;
			Init) menu_init || ok=1 ;;
			Build) menu_build || ok=1 ;;
			Filesystem) menu_fs || ok=1 ;;
			Encryption) menu_enc || ok=1 ;;
			Bootloader) menu_bootloader || ok=1 ;;
			Secure-Boot) menu_secureboot || ok=1 ;;
			Snapshots) menu_snapper || ok=1 ;;
			Swap) menu_swap || ok=1 ;;
			Kernel) menu_kernel || ok=1 ;;
			Mirrors) menu_mirror || ok=1 ;;
			Hostname) menu_hostname || ok=1 ;;
			Keyboard) menu_keymap || ok=1 ;;
			Locale) menu_locale || ok=1 ;;
			Timezone) menu_timezone || ok=1 ;;
			Root-password) menu_rootpass || ok=1 ;;
			Users) menu_user || ok=1 ;;
			Network) menu_network || ok=1 ;;
			Desktop) menu_desktop || ok=1 ;;
			Login) menu_dm || ok=1 ;;
			Dotfiles) menu_dotfiles || ok=1 ;;
			GPU) menu_gpu || ok=1 ;;
			Apps) menu_apps || ok=1 ;;
			Gaming) menu_gaming || ok=1 ;;
			Peripherals) menu_periph || ok=1 ;;
			Packages) menu_extras || ok=1 ;;
			Overlays) menu_overlays || ok=1 ;;
			Bootstrap) menu_bootstrap || ok=1 ;;
			Install)
				if validate && confirm_install; then
					do_install
				fi
				ok=1
				;;
		esac
		if ((ok == 0)); then next=$(next_item "$choice"); else next=$choice; fi
		if [[ -n $MENU_JUMP ]]; then
			next=$MENU_JUMP
			MENU_JUMP=""
		fi
	done
}

usage() {
	cat <<EOF
gentoo-install.sh $SCRIPT_VERSION - menu-driven Gentoo Linux installer

Run as root from the Gentoo minimal installation ISO (x86_64) with internet access:
    bash gentoo-install.sh

Install from a preset (asks only for the disk, passwords and users):
    bash gentoo-install.sh --preset kde-openrc
    bash gentoo-install.sh --preset /mnt/usb/my.preset@1a2b3c4d5e6f7a8b

LARBS-style post-install on an ALREADY INSTALLED Gentoo system (no disk changes):
    bash gentoo-install.sh --bootstrap

Options:
    -p, --preset P   load a preset: a file, an https:// link, or a name from
                     $PRESET_REPO
                     Add @ID (16+ hex digits) to refuse a changed preset.
    -b, --bootstrap  only create/update a user and run the bootstrap
    -h, --help       show this help
    -V, --version    show the version
EOF
}

# ---- --bootstrap: LARBS-like flow on a running system --------------------------------
bootstrap_main() {
	local u n p lvl c rc
	[[ $EUID -eq 0 ]] || die "Run this as root."
	command -v emerge >/dev/null 2>&1 || die "This mode needs Gentoo Linux (emerge not found)."
	[[ -t 0 && -t 1 ]] || die "Run this from an interactive terminal."
	if [[ -d /mnt/cdrom || -d /run/initramfs/live ]] && [[ ! -d /var/db/repos/gentoo ]]; then
		die "This looks like the live ISO. --bootstrap is for an installed system; run the installer without options instead."
	fi
	: >"$LOG" || die "Cannot write $LOG"
	: >"$WARN_FILE"
	STANDALONE=1
	TARGET=/
	BACKTITLE="Gentoo Linux bootstrap ${SCRIPT_VERSION}"
	ensure_dialog
	ensure_network
	if [[ -d /var/db/repos/guru ]]; then GURU=1; fi
	if [[ -d /run/systemd/system ]]; then INIT=systemd; fi

	msg "Welcome!\n\nThis sets up a user and installs your programs list and dotfiles, LARBS-style, on this Gentoo system. The disk is not changed.\n\nLog: $LOG" "Welcome" 14 70
	while true; do
		u=$(ui --title " User " --inputbox "Login name of the user to create or update:" 9 64 "${USERS[0]:-}") || { clear; exit 0; }
		valid_login "$u" 1 && break
	done
	if id "$u" >/dev/null 2>&1; then
		yesno "The user '$u' already exists. Its files stay; its password will be changed, it is added to the groups below, and the dotfiles may overwrite files in its home.\n\nContinue?" "Existing user" 1 || { clear; exit 0; }
	fi
	n=$(ui --title " User $u " --inputbox "Full name (optional):" 9 64) || { clear; exit 0; }
	[[ $n != *:* ]] || die "The full name must not contain ':'."
	p=$(ask_password "Password for $u" "the password for $u") || { clear; exit 0; }
	U_SUDO[$u]=sudo
	lvl=$(menu_sudo_level "$u") || { clear; exit 0; }
	USERS=("$u")
	U_FULL[$u]=$n U_PASS[$u]=$p U_SUDO[$u]=$lvl
	sync_primary
	menu_bootstrap

	c="User:       $u ($(sudo_word "$u"))\nPrograms:   ${BS_PROGS:-(none)}\nPresets:    ${DOTS:-(none)}\nDotfiles:   ${BS_DOTFILES:-(none)}${BS_BRANCH:+ ($BS_BRANCH)}\nShell:      $BS_SHELL\nPower cmds: $([[ $BS_POWER == 1 ]] && echo 'without password' || echo 'normal')"
	yesno "$c\n\nStart?" "Let's go" 0 15 70 || { clear; exit 0; }

	run_step "[1/2] Setting up user $u" setup_users
	rc=$?
	if ((rc == 0)); then
		run_step "[2/2] Bootstrap: programs, dotfiles, shell" step_bootstrap_user
		rc=$?
	fi
	if ((rc != 0)); then
		dialog --backtitle "$BACKTITLE" --title " Failed " --textbox "$LOG" 0 0 >/dev/tty 2>&1 || true
		clear
		echo "The bootstrap stopped with an error. See $LOG"
		exit 1
	fi
	c="All done. Log out and log in as $u."
	if [[ -s $WARN_FILE ]]; then c+="\n\n\Z3Warnings:\Zn\n$(sed 's/$/\\n/' "$WARN_FILE" | tr -d '\n')"; fi
	msg "$c" "All done!" 18 74
	clear
	exit 0
}

main() {
	local preset="" start=Disk
	case ${1:-} in
		-h | --help) usage; exit 0 ;;
		-V | --version) echo "$SCRIPT_VERSION"; exit 0 ;;
		-b | --bootstrap) bootstrap_main ;;
		-p | --preset)
			[[ -n ${2:-} && $# -eq 2 ]] || { usage >&2; exit 2; }
			preset=$2
			;;
		--preset=?*)
			[[ $# -eq 1 ]] || { usage >&2; exit 2; }
			preset=${1#--preset=}
			;;
		"") ;;
		*) usage >&2; exit 2 ;;
	esac
	preflight
	trap '[[ $INSTALL_STARTED == 1 ]] && cleanup_target' EXIT
	trap 'exit 130' INT TERM
	ensure_network_text
	ensure_network
	msg "This installer puts Gentoo Linux on a whole disk.\n\n  * OpenRC or systemd; a checked Gentoo stage3\n  * prebuilt packages or everything compiled; you pick\n    the CPU cores it uses (Build item)\n  * UEFI or BIOS; ext4, btrfs (snapper) or ZFS\n  * no encryption, LUKS1 or LUKS2; Secure Boot (sbctl)\n  * GRUB, systemd-boot, UKI or ZFSBootMenu\n  * desktops and window managers (pick several,\n    Hyprland too) with dotfile presets\n  * GPU drivers, apps, gaming, peripherals, GURU\n  * several users with sudo levels, LARBS-style bootstrap\n\nDetected: $(cpu_threads) CPU threads, $(ram_gib) GiB RAM.\nNothing is written until you confirm the summary and type the disk name.\nLog file: $LOG" \
		"Welcome" 21 74
	if [[ -n $preset ]] && preset_load "$preset"; then
		preset_quick
		start=$MENU_JUMP
		MENU_JUMP=""
	fi
	main_menu "$start"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
	main "$@"
fi
