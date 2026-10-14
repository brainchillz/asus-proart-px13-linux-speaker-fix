#!/usr/bin/env bash
#
# Recover the ASUS ProArt PX13 internal-speaker audio by resetting the AMD
# ACP / SoundWire controller, then refreshing PipeWire/WirePlumber.
#
# Used by:
#  - px13-audio-rebind.service (runs once at boot, after sound.target)
#  - /usr/lib/systemd/system-sleep/px13-audio-resume.sh (runs after resume
#    from suspend/hibernate)
#
# Why a full PCI reset (and not just a slave rebind):
#
#   On s2idle resume the whole AMD ACP/SoundWire controller fails to come
#   back - the entire "amd-soundwire" ALSA card (card 1) DISAPPEARS, not
#   just the tas2783 amps. Trying to unbind an individual tas2783 SoundWire
#   slave at that point BLOCKS for ~90s (the bus controller is dead), which
#   is exactly what used to hang the resume hook and leave audio on "Dummy
#   Output".
#
#   Unbinding/re-binding the parent ACP PCI device (0000:c4:00.5, driver
#   snd_pci_ps) tears the whole stack down and re-probes it from scratch -
#   the two SoundWire managers, both tas2783 smart amps (re-downloading
#   their 1714-1-8/1714-1-B calibration firmware) and the rt721 jack codec -
#   recreating card 1 cleanly, the same way a cold boot does. This also
#   covers the intermittent tas2783 "FW download failed: -110" SDW bus
#   timeout that can hit slave 01:b at boot.
#
# See the project README for full background.

set -uo pipefail

PCI_DEV="0000:c4:00.5"
PCI_DRV="/sys/bus/pci/drivers/snd_pci_ps"
CARD_MATCH="amd-soundwire"

log() { echo "px13-audio-fix: $*"; }

# --- Reset the ACP PCI device ------------------------------------------------
# The sysfs writes are wrapped in `timeout` because the unbind can block
# indefinitely if attempted while the ACP/SoundWire bus is in its broken
# just-resumed state (this must run AFTER resume+thaw - see
# px13-audio-resume.service - not from inside the systemd-sleep hook).
pci_write() { timeout 30 sh -c "echo '$1' > '$2'" 2>/dev/null; }

if [ ! -d "$PCI_DRV" ]; then
  log "snd_pci_ps driver not present, cannot reset - skipping"
elif [ ! -e "$PCI_DRV/$PCI_DEV" ]; then
  log "PCI $PCI_DEV not currently bound to snd_pci_ps - attempting bind only"
  pci_write "$PCI_DEV" "$PCI_DRV/bind" || log "bind failed/timed out"
else
  log "unbinding PCI $PCI_DEV"
  pci_write "$PCI_DEV" "$PCI_DRV/unbind" || log "unbind failed/timed out"
  sleep 2
  log "binding PCI $PCI_DEV"
  pci_write "$PCI_DEV" "$PCI_DRV/bind" || log "bind failed/timed out"
fi

# --- Wait for the amd-soundwire card to reappear -----------------------------
# Firmware download for the tas2783 amps is asynchronous after the bind.
for _ in $(seq 1 40); do
  if grep -q "$CARD_MATCH" /proc/asound/cards 2>/dev/null; then
    log "amd-soundwire card is present"
    break
  fi
  sleep 0.25
done
grep -q "$CARD_MATCH" /proc/asound/cards 2>/dev/null \
  || log "WARNING: amd-soundwire card did not reappear"

# Let the tas2783 firmware download / amp init settle before touching PipeWire.
sleep 2

# --- Verify both tas2783 amps actually got their firmware --------------------
# The amps download their calibration firmware asynchronously when they
# attach to the SoundWire bus, and at boot one of them (usually the right
# channel, sdw ...:01:8) intermittently misses the attach - the driver then
# fails every playback hw_params with "error playback without fw download"
# and that speaker stays silent even though the card exists.
#
# Detect it by forcing a hw_params on the SmartAmp PCM with a whisper of
# silence: if either amp lacks firmware the open fails with EINVAL. (If the
# device is busy, PipeWire already has it open and streaming - amps OK.)
# On failure, re-bind the SoundWire slaves so the driver re-runs its
# attach/firmware-download path, and re-check.
SDW_DRV="/sys/bus/soundwire/drivers/slave-tas2783"

amps_ok() {
  local out
  out=$(head -c 9600 /dev/zero | timeout 5 aplay -D hw:1,2 -q \
        -f S16_LE -c 2 -r 48000 -t raw - 2>&1) && return 0
  echo "$out" | grep -qi busy && return 0
  return 1
}

sdw_rebind_slaves() {
  local dev
  for dev in /sys/bus/soundwire/devices/sdw:0:1:0102:0000:01:*; do
    timeout 30 sh -c "echo '$(basename "$dev")' > '$SDW_DRV/unbind'" 2>/dev/null
  done
  sleep 1
  for dev in /sys/bus/soundwire/devices/sdw:0:1:0102:0000:01:*; do
    timeout 30 sh -c "echo '$(basename "$dev")' > '$SDW_DRV/bind'" 2>/dev/null
  done
  sleep 3
}

if [ -d "$SDW_DRV" ]; then
  for attempt in 1 2 3; do
    if amps_ok; then
      log "both tas2783 amps report firmware loaded"
      break
    fi
    if [ "$attempt" = 3 ]; then
      log "WARNING: tas2783 firmware still missing after $attempt attempts"
      break
    fi
    log "tas2783 firmware check failed (attempt $attempt) - re-binding SoundWire amps"
    sdw_rebind_slaves
  done
fi

# --- Refresh PipeWire/WirePlumber for each logged-in user --------------------
# Restart it so it cleanly re-enumerates the recreated card.
#
# IMPORTANT: on resume this script runs inside the systemd-sleep "post" hook,
# while user.slice is still FROZEN. A `systemctl --user` call against a frozen
# session would block until the session thaws (hanging the whole resume). So
# we skip the restart for any frozen session - WirePlumber's udev monitor
# delivers the card remove/add events on its own once the session thaws, and
# re-creates the "Speaker" sink without any restart.
for uid in $(loginctl list-users --no-legend | awk '{print $1}'); do
  runtime_dir="/run/user/$uid"
  user_name="$(id -nu "$uid" 2>/dev/null)" || continue
  [ -d "$runtime_dir" ] || continue

  events="/sys/fs/cgroup/user.slice/user-${uid}.slice/cgroup.events"
  if [ -r "$events" ] && grep -q "^frozen 1$" "$events" 2>/dev/null; then
    log "uid $uid ($user_name) session frozen - skipping pipewire restart" \
        "(udev will re-enumerate on thaw)"
    continue
  fi

  log "restarting pipewire for uid $uid ($user_name)"
  sudo -u "$user_name" XDG_RUNTIME_DIR="$runtime_dir" \
    systemctl --user restart wireplumber pipewire pipewire-pulse 2>/dev/null \
    || log "pipewire restart for uid $uid failed"
done
