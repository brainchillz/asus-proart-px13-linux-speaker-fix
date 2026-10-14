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
# 3. A fully SELF-CONTAINED UCM use case: ./ucm/px13-soundwire/ bundles
#    its own copies of the codec device files (rt721 headset, acp-dmic,
#    tas2783 speaker) instead of including the distro sof-soundwire/
#    ones, and the card override ./ucm/<card-longname>.conf points UCM
#    at it. Two reasons:
#      - the distro HiFi.conf auto-detects codecs from "spk:<codec>"
#        tokens this machine's legacy AMD machine driver never publishes,
#        so it exposes no Speaker device at all;
#      - the distro rt721.conf references a "Headphone Switch" cset this
#        codec doesn't support (verb activation fails outright, dropping
#        PipeWire to a silent fallback profile), and alsa-ucm-conf
#        updates have repeatedly broken that file's variable guards
#        (MultiMicShadow -> MicCodec1 rename in 1.2.15.3-1ubuntu1.7).
#    Bundling our own copies makes the speakers immune to alsa-ucm-conf
#    package upgrades - earlier revisions patched the distro file and
#    were broken by every update.
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
# 5. A DKMS package (./driver) rebuilding the TAS2783 SoundWire codec
#    module with the upstream-pending "stereo split and resume fixes"
#    series. Without it both mono amps mirror the left channel (right
#    speaker silent); the patched module adds a per-amp "RX Single
#    Channel Switch" control which the UCM profile above turns on for
#    both amps. Being DKMS, it rebuilds automatically for every new
#    kernel and installs to /lib/modules/<k>/updates/dkms/, which
#    depmod prefers over the in-tree module.
#
# Run this after a fresh OS install. Safe to re-run.
#
# See the README for full background/history.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CARD_LONGNAME="ASUSTeKCOMPUTERINC.-ProArtPX13HN7306EAC-1.0-HN7306EAC"

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

echo "==> Installing patched tas2783 codec module (stereo split) via DKMS..."
DKMS_PKG="tas2783-stereo"
DKMS_VER="1.0"
command -v dkms >/dev/null 2>&1 || sudo apt-get install -y dkms
sudo dkms remove "${DKMS_PKG}/${DKMS_VER}" --all >/dev/null 2>&1 || true
sudo rm -rf "/usr/src/${DKMS_PKG}-${DKMS_VER}"
sudo install -d -m 755 "/usr/src/${DKMS_PKG}-${DKMS_VER}"
sudo install -m 644 "$SCRIPT_DIR/driver/dkms.conf" "$SCRIPT_DIR/driver/Makefile" \
  "$SCRIPT_DIR/driver/tas2783-sdw.c" "$SCRIPT_DIR/driver/tas2783.h" \
  "/usr/src/${DKMS_PKG}-${DKMS_VER}/"
sudo dkms add "${DKMS_PKG}/${DKMS_VER}"
sudo dkms build "${DKMS_PKG}/${DKMS_VER}"
sudo dkms install "${DKMS_PKG}/${DKMS_VER}"
echo "    module now resolves to: $(modinfo -n snd-soc-tas2783-sdw)"

echo "==> Installing self-contained ALSA UCM use case (immune to alsa-ucm-conf upgrades)..."
sudo install -d -m 755 /usr/share/alsa/ucm2/px13-soundwire
sudo install -m 644 "$SCRIPT_DIR/ucm/px13-soundwire/"*.conf /usr/share/alsa/ucm2/px13-soundwire/
sudo install -d -m 755 /usr/share/alsa/ucm2/conf.d/amd-soundwire
sudo install -m 644 "$SCRIPT_DIR/ucm/${CARD_LONGNAME}.conf" "/usr/share/alsa/ucm2/conf.d/amd-soundwire/${CARD_LONGNAME}.conf"

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
echo "    ./test-stereo.sh                      (voice test: 'left'/'right' from each speaker)"
echo
echo "A reboot (and a suspend/resume cycle) is recommended to confirm"
echo "everything persists cleanly - px13-audio-rebind.service runs at boot"
echo "(after sound.target) and px13-audio-resume.service runs after every"
echo "resume, both resetting the ACP controller and refreshing PipeWire."
