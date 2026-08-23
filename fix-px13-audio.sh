#!/usr/bin/env bash
#
# Fix internal speaker/amp audio on the ASUS ProArt PX13 (HN7306, "Strix
# Halo" / Ryzen AI Max) under Linux.
#
# This script installs everything needed for the internal speakers to work:
#
# 1. TAS2783 SoundWire smart-amp calibration firmware
#    (1714-1-8.bin / 1714-1-B.bin, bundled in ./firmware next to this
#    script). Without these, every playback attempt fails with:
#
#      slave-tas2783 ...: Direct firmware load for 1714-1-8.bin failed with error -2
#      slave-tas2783 ...: error playback without fw download
#      ASoC error (-22): at snd_soc_dai_hw_params() on tas2783-codec
#
#    and the internal speakers produce no sound (HDMI audio is unaffected).
#
# 2. A local ALSA UCM "Speaker" profile for the TAS2783 amp (bundled in
#    ./ucm). Upstream alsa-ucm-conf has no tas2783 codec profile, so without
#    this PipeWire only ever sees "Headphones"/"Headset Microphone" (from
#    the rt721 jack codec) and falls back to a "Dummy Output" sink even
#    after the firmware above loads correctly.
#
# 3. A per-card UCM override, GENERATED at install time from whichever
#    sof-soundwire.conf is actually installed, that force-selects the
#    tas2783 profile from (2). It is generated rather than shipped because
#    a shipped copy is coupled to one alsa-ucm-conf generation and fails on
#    others - see the long comment at the generation step below. The card
#    long name is detected from /proc/asound/cards rather than hardcoded,
#    since it differs per SKU (HN7306EA vs HN7306EAC vs ...).
#
# 4. A systemd oneshot service (./systemd/px13-audio-rebind.service +
#    px13-audio-fix.sh) plus a systemd-sleep hook
#    (./systemd/px13-audio-resume.sh) that RESET the AMD ACP/SoundWire
#    controller (unbind/bind the parent ACP PCI device 0000:c4:00.5 on
#    driver snd_pci_ps) and refresh PipeWire/WirePlumber - both at boot
#    and after resume from suspend/hibernate.
#
#    On s2idle resume the whole ACP/SoundWire controller fails to come
#    back: the entire "amd-soundwire" ALSA card DISAPPEARS and PipeWire
#    drops to "Dummy Output". The PCI re-bind re-probes the whole stack
#    from scratch (both SoundWire managers, both tas2783 amps -
#    re-downloading their calibration firmware - and the rt721 codec),
#    recreating the card cleanly like a cold boot. This also covers the
#    intermittent tas2783 "FW download failed: -110" SDW bus timeout that
#    can hit slave 01:b at boot.
#
#    (An earlier version poked individual tas2783 SoundWire slaves
#    instead. That HUNG for ~90s on resume - unbinding a slave on the
#    dead post-resume bus blocks - and never recovered the card. The
#    PCI-level reset avoids that hang.)
#
#    NOTE: the boot reset MUST happen after PipeWire/WirePlumber are up
#    (After=sound.target); running it earlier in boot hits a "Permission
#    denied" on the sysfs writes (kernel still settling). The resume hook
#    runs while user.slice is FROZEN, so px13-audio-fix.sh skips the
#    PipeWire restart for frozen sessions and lets WirePlumber's udev
#    monitor re-enumerate the recreated card on thaw.
#
# Run this after a fresh OS install. Safe to re-run.
#
# See the README for full background/history.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UCM=/usr/share/alsa/ucm2

# Detect the card instead of hardcoding it. The UCM long name embeds the
# exact SKU and differs between machines (HN7306EA vs HN7306EAC vs ...).
# A hardcoded name installs an override that simply never matches - the
# speakers stay dead and nothing anywhere reports an error.
CARD_NUM="$(awk -F'[][]' '/\]: amd-soundwire/ {gsub(/ /,"",$1); print $1; exit}' /proc/asound/cards)"
if [ -z "$CARD_NUM" ]; then
	echo "ERROR: no amd-soundwire card found in /proc/asound/cards." >&2
	exit 1
fi
CARD_LONGNAME="$(awk -v n="$CARD_NUM" \
	'{if ($1==n && /\]:/) {getline; gsub(/^[ \t]+|[ \t]+$/,""); print; exit}}' \
	/proc/asound/cards)"
echo "==> Detected card $CARD_NUM: $CARD_LONGNAME"

# The TAS2783 calibration firmware is proprietary and is NOT shipped in this
# public repo - you must extract it from ASUS's Windows driver first. See
# firmware/EXTRACT-FIRMWARE.md.
if [ ! -f "$SCRIPT_DIR/firmware/1714-1-8.bin" ] || [ ! -f "$SCRIPT_DIR/firmware/1714-1-B.bin" ]; then
  echo "ERROR: missing calibration firmware in $SCRIPT_DIR/firmware/" >&2
  echo "       Need: 1714-1-8.bin and 1714-1-B.bin" >&2
  echo "       These proprietary ASUS/TI blobs are not included in this repo." >&2
  echo "       Extract them first - see firmware/EXTRACT-FIRMWARE.md" >&2
  exit 1
fi

echo "==> Installing TAS2783 calibration firmware..."
sudo install -m 644 "$SCRIPT_DIR/firmware/1714-1-8.bin" /lib/firmware/1714-1-8.bin
sudo install -m 644 "$SCRIPT_DIR/firmware/1714-1-B.bin" /lib/firmware/1714-1-B.bin
sudo install -d -m 755 /lib/firmware/ti/audio/tas2783
sudo install -m 644 "$SCRIPT_DIR/firmware/1714-1-8.bin" /lib/firmware/ti/audio/tas2783/1714-1-8.bin
sudo install -m 644 "$SCRIPT_DIR/firmware/1714-1-B.bin" /lib/firmware/ti/audio/tas2783/1714-1-B.bin

echo "==> Checking the TAS2783 amp controls this profile drives..."
for ctl in 'Left Spk Switch' 'Right Spk Switch' 'Left Spk2 Switch' 'Right Spk2 Switch'; do
	if ! amixer -c "$CARD_NUM" cget "name=$ctl" >/dev/null 2>&1; then
		echo "    WARNING: control '$ctl' not found on card $CARD_NUM."
		echo "             ucm/tas2783.conf assumes two TAS2783 amps; a board"
		echo "             with a different amp count needs its EnableSequence"
		echo "             adjusted or verb activation will fail."
	fi
done

echo "==> Installing local ALSA UCM speaker profile for tas2783..."
sudo install -m 644 "$SCRIPT_DIR/ucm/tas2783.conf" "$UCM/sof-soundwire/tas2783.conf"

# Generate the card override from whatever sof-soundwire.conf is actually
# installed, rather than shipping a copy of one.
#
# A shipped copy is version-coupled to the alsa-ucm-conf it was taken from,
# and breaks in two separate ways on older trees:
#
#   * Syntax. Newer sof-soundwire.conf declares "Syntax 7", but the syntax
#     ceiling is enforced by ALSA-LIB, not by alsa-ucm-conf. alsa-lib 1.2.11
#     (Ubuntu 24.04 / Zorin 18) rejects anything above Syntax 6 outright:
#     "parser.c:270 Incompatible syntax 7 ... -22". Upgrading alsa-ucm-conf
#     does not help and actively makes things worse.
#
#   * Moved includes. Paths like /common/pcm/hdmi.conf do not exist in older
#     trees, so the override fails to parse even once the syntax is accepted.
#
# Deriving the override from the installed file sidesteps both: it is always
# syntax-correct and its includes always resolve for the tree it came from.
echo "==> Generating card override for ${CARD_LONGNAME}..."
OVERRIDE="$UCM/conf.d/amd-soundwire/${CARD_LONGNAME}.conf"
if [ ! -f "$UCM/sof-soundwire/sof-soundwire.conf" ]; then
	echo "ERROR: $UCM/sof-soundwire/sof-soundwire.conf missing." >&2
	echo "       Is alsa-ucm-conf installed?" >&2
	exit 1
fi
if [ -f "$OVERRIDE" ] && [ ! -f "$OVERRIDE.orig" ]; then
	sudo cp -a "$OVERRIDE" "$OVERRIDE.orig"
	echo "    backed up existing override to $(basename "$OVERRIDE").orig"
fi

TMP_OVERRIDE="$(mktemp)"
trap 'rm -f "$TMP_OVERRIDE"' EXIT
cat "$UCM/sof-soundwire/sof-soundwire.conf" > "$TMP_OVERRIDE"
cat >> "$TMP_OVERRIDE" <<'UCMEOF'

# --- Local addition: force the TAS2783 speaker device ---
# alsa.components for this card is "cfg-amp:2 mic:acp-dmic cfg-mics:1
# hs:rt721" - there is no " spk:<codec>" token, because the kernel's
# snd_acp_sdw_legacy_mach machine driver does not emit one for tas2783.
# SpeakerCodec1 therefore resolves to "" and the generic sof-soundwire
# HiFi profile never adds a Speaker device, so PipeWire falls back to a
# Dummy Output sink. Force-select the local tas2783.conf instead.
#
# BOTH variables must be set, because the two alsa-ucm-conf generations
# gate the speaker include differently:
#
#   upstream 1.2.15.x   ->  If.spkdev tests ${var:SpeakerCodec1}
#   Ubuntu 24.04 tree   ->  If.spk    tests ${var:SpeakerCodecFile}
#
# Setting only SpeakerCodec1 silently produces no Speaker device on
# Ubuntu/Zorin. The unused one is a harmless no-op on either tree.
#
# Appended after the multi-codec If blocks above so that rt721 headset and
# acp-dmic microphone handling is left completely untouched.
Define {
	SpeakerCodec1 "tas2783"
	SpeakerCodecFile "tas2783"
}
UCMEOF
sudo install -m 644 "$TMP_OVERRIDE" "$OVERRIDE"

# Older revisions of this script shipped a patched rt721.conf that emptied
# the 'Headphone Switch' cset. That patch was wrong on two counts: the
# control does exist (numid=13 'Headphone Switch'), and the shipped file
# referenced ${var:MultiMicShadow} / ${var:MultiSpeakerShadow}, which are
# undefined on trees that use MicCodecFile / SpeakerCodecFile - breaking
# the rt721 Mic and Speaker sections outright. Restore the stock file.
if dpkg -V alsa-ucm-conf 2>/dev/null | grep -q 'sof-soundwire/rt721.conf'; then
	echo "==> Restoring stock rt721.conf (previous versions patched it)..."
	sudo apt-get install --reinstall -o Dpkg::Options::=--force-confmiss \
		-y alsa-ucm-conf >/dev/null 2>&1 || \
		echo "    could not reinstall alsa-ucm-conf; do it manually"
fi

echo "==> Installing ACP/SoundWire reset + PipeWire-refresh script..."
sudo install -m 755 "$SCRIPT_DIR/systemd/px13-audio-fix.sh" /usr/local/sbin/px13-audio-fix.sh
sudo rm -f /usr/local/sbin/px13-audio-rebind.sh

echo "==> Installing boot-time service (resets the ACP controller after"
echo "    sound.target; covers the -110 FW download timeout at cold boot)..."
sudo install -m 644 "$SCRIPT_DIR/systemd/px13-audio-rebind.service" /etc/systemd/system/px13-audio-rebind.service

echo "==> Installing post-resume service (the whole amd-soundwire card"
echo "    disappears after s2idle resume; this resets it once the system"
echo "    has fully resumed + thawed)..."
sudo install -m 644 "$SCRIPT_DIR/systemd/px13-audio-resume.service" /etc/systemd/system/px13-audio-resume.service

echo "==> Removing the old systemd-sleep hook if present (it ran while"
echo "    user.slice was frozen and HUNG the resume - replaced by the"
echo "    post-resume service above)..."
sudo rm -f /usr/lib/systemd/system-sleep/px13-audio-resume.sh

sudo systemctl daemon-reload
sudo systemctl enable px13-audio-rebind.service
sudo systemctl enable px13-audio-resume.service

echo "==> Resetting the ACP controller and refreshing PipeWire now..."
sudo /usr/local/sbin/px13-audio-fix.sh || true

echo
echo "==> Done. Verify with:"
echo "    journalctl -k -b 0 | grep -i tas2783   (should show no firmware load errors)"
echo "    wpctl status                          (should show 'Audio Coprocessor Speaker')"
echo "    speaker-test -D pipewire -c 2 -t sine -f 440"
echo
echo "A reboot (and a suspend/resume cycle) is recommended to confirm"
echo "everything persists cleanly - px13-audio-rebind.service runs at boot"
echo "(after sound.target) and px13-audio-resume.service runs after every"
echo "resume, both resetting the ACP controller and refreshing PipeWire."
