# ASUS ProArt PX13 (HN7306) — Linux Internal Speaker Fix

Make the **internal speakers** work on the **ASUS ProArt PX13 (HN7306, "Strix
Halo" / Ryzen AI Max)** under Linux, and keep them working across **reboot**
and **suspend/resume**.

Developed on Ubuntu 26.04 (kernel 7.0.x), but the analysis applies to any
recent distro with this laptop. HDMI audio works out of the box — this is
specifically about the silent internal speakers (PipeWire only shows a "Dummy
Output" sink).

> **Note:** the per-laptop TAS2783 calibration firmware is proprietary and is
> **not included** in this repo. You extract it once from ASUS's free Windows
> driver — see [`firmware/EXTRACT-FIRMWARE.md`](firmware/EXTRACT-FIRMWARE.md).

## Symptoms this fixes

- Internal speakers silent; PipeWire shows only **"Dummy Output"** (or only
  Headphones/Headset Mic from the rt721 jack codec).
- `dmesg` shows TAS2783 errors such as:
  - `Direct firmware load for 1714-1-8.bin failed with error -2`
  - `error playback without fw download`
  - `FW download failed: -110` (intermittent at boot)
- Speakers that work after a manual fix **break again after every
  suspend/resume** (and originally after every reboot) — on resume the whole
  `amd-soundwire` ALSA card disappears.
- Once audible, **stereo is broken**: the right speaker is silent and the
  left renders both channels (sounds "center"). Both mono amps mirror the
  left channel.

## Root causes (four separate problems)

1. **Missing TAS2783 calibration firmware.** The speaker amps are TI TAS2783
   SoundWire smart amps needing per-laptop calibration blobs
   (`1714-1-8.bin` / `1714-1-B.bin`). `linux-firmware` only ships TAS2783
   blobs for some HP/Dell machines — there are no ASUS `1714` blobs upstream,
   so the amp never initializes and playback fails.

2. **No ALSA UCM "Speaker" profile for the TAS2783.** Upstream
   `alsa-ucm-conf` has no `tas2783` codec profile, so PipeWire never exposes
   the internal speaker. Additionally, `rt721.conf` references a
   `Headphone Switch` control this codec/driver doesn't expose, which makes
   `alsaucm set _verb HiFi` fail and drops PipeWire to a generic
   "stereo-fallback" profile (silent even after the firmware loads).

3. **The AMD ACP/SoundWire controller doesn't survive boot/suspend cleanly.**
   - Cold boot: TAS2783 firmware download intermittently fails with an SDW bus
     timeout (`FW download failed: -110`).
   - **s2idle resume: the entire `amd-soundwire` ALSA card disappears** — the
     ACP/SoundWire controller fails to re-initialize — dropping PipeWire back
     to "Dummy Output".

4. **The in-tree TAS2783 driver mirrors one channel onto both amps.** On a
   stereo stream `snd_sdw_params_to_config()` (`include/sound/sdw.h`) gives
   every amp `ch_mask = GENMASK(ch_count-1,0)` = `0x3`, which the SoundWire
   core treats as *mirror mode*: both amps get the same payload block offset
   (`sdw_compute_slave_ports()` advances by the mask's popcount), so both
   render the left channel and the right speaker stays silent. Fixed by an
   out-of-tree build of the codec module carrying the upstream-pending
   [stereo-split + resume-fix series](https://lore.kernel.org/lkml/20260809101541.4969-1-wiza@saarinenkoti.fi/)
   (see [`driver/`](driver/)); it adds a per-amp `RX Single Channel Switch`
   which the UCM profile turns on for both amps.

## What this repo installs

`fix-px13-audio.sh` installs all of the following (safe to re-run):

| Component | Installed to | Purpose |
|---|---|---|
| Calibration firmware | `/lib/firmware/1714-1-{8,B}.bin` (+ `ti/audio/tas2783/`) | Lets the TAS2783 amps initialize |
| Patched codec module (DKMS) | `/usr/src/tas2783-stereo-1.0/` → `/lib/modules/<k>/updates/dkms/` | Stereo split across the two amps + resume fixes; rebuilds automatically for new kernels |
| UCM use case (self-contained) | `/usr/share/alsa/ucm2/px13-soundwire/` + card override in `conf.d/amd-soundwire/` | Exposes the internal Speaker (enabling the per-amp `RX Single Channel Switch` for the stereo split), Headphones and Mics; bundles its own copies of the codec device files, so `alsa-ucm-conf` upgrades cannot break it |
| `px13-audio-fix.sh` | `/usr/local/sbin/` | Resets the ACP controller (PCI unbind/bind of `0000:c4:00.5`) and refreshes PipeWire |
| `px13-audio-rebind.service` | `/etc/systemd/system/` | Runs the reset at **boot** (`After=sound.target`) |
| `px13-audio-resume.service` | `/etc/systemd/system/` | Runs the reset after **resume** (ordered on the sleep targets, after thaw) |

### The key insight for suspend/resume

On resume the whole controller dies, so poking the individual SoundWire amp
slaves doesn't help — and worse, **unbinding anything from inside the
`systemd-sleep` hook hangs for ~90 s**, because that hook runs while
`user.slice` is frozen and the bus is in its broken just-resumed state. The
fix is:

1. Reset the **parent ACP PCI device** (`snd_pci_ps` on `0000:c4:00.5`)
   instead of the individual slaves. This re-probes the whole stack (both
   SoundWire managers, both amps with a fresh firmware download, the rt721
   codec) and recreates the card cleanly — like a cold boot.
2. Do it from a **post-resume systemd service** (`px13-audio-resume.service`,
   ordered `After=`/`WantedBy=` the sleep targets) that runs *after* the
   system has fully resumed and thawed (in `system.slice`, which is never
   frozen). There the reset completes in ~2 s instead of hanging.

## Usage

```bash
git clone https://github.com/<owner>/<repo>.git
cd <repo>

# 1. Extract the proprietary TAS2783 firmware into firmware/ first:
#    see firmware/EXTRACT-FIRMWARE.md  (1714-1-8.bin and 1714-1-B.bin)

# 2. Install everything:
./fix-px13-audio.sh
```

Verify:

```bash
journalctl -k -b 0 | grep -i tas2783      # no "firmware load ... failed"
wpctl status                              # shows "Audio Coprocessor Speaker"
./test-stereo.sh                          # "left"/"right" voice, each from its own speaker
```

`test-stereo.sh` plays GNOME's speaker-test voice samples hard-panned to
each speaker (left, right, left, right). If both words come from the same
speaker, the stereo split (root cause 4) is not active.

A reboot and a suspend/resume cycle should both keep the speakers working with
no manual intervention.

## Tested versions

| Component | Tested with |
|---|---|
| OS | Ubuntu 26.04 "resolute" |
| Kernel | `7.0.0-34-generic`, `7.0.0-38-generic` |
| alsa-ucm-conf | `1.2.15.3-1ubuntu1.5`, `1.2.15.3-1ubuntu1.7` |
| PipeWire / WirePlumber | `1.6.2-1ubuntu1.2` / `0.5.13-1ubuntu1` |

How the fix holds up across updates:

- **Kernel updates** are handled by DKMS: the patched codec module
  rebuilds and installs itself for every new kernel. Its source is the
  7.0.0 `tas2783-sdw.c` snapshot plus the upstream-pending series. If a
  future kernel changes the codec's internal APIs the DKMS *build* fails —
  loudly but harmlessly: the in-tree module stays in use and the speakers
  keep working in mirror mono. Refresh `driver/` from the new kernel
  source when that happens (or drop it once the series is merged).
- **alsa-ucm-conf updates** can no longer break the use case: the verb is
  fully self-contained and no distro-owned UCM file is patched anymore.
  (Earlier revisions patched `sof-soundwire/rt721.conf` and were broken
  twice by package upgrades — a `Headphone Switch` cset regression and a
  guard-variable rename.)
- **PipeWire/WirePlumber**: nothing version-specific; any recent release
  with standard UCM support works.

## Hardware details

ASUS ProArt PX13 HN7306 · card long-name
`ASUSTeKCOMPUTERINC.-ProArtPX13HN7306EAC-1.0-HN7306EAC` · rt721-sdca jack
codec + 2× TAS2783 SoundWire smart amps on SoundWire link 1 (slaves `01:8`,
`01:b`) · AMD ACP PCI device `0000:c4:00.5` (driver `snd_pci_ps`) · PCI
subsystem id `0x1714`.

## Upstreaming (so this fix becomes unnecessary)

- Request the ASUS `1714-1-8` / `1714-1-B` TAS2783 blobs in
  [`linux-firmware`](https://gitlab.com/kernel-firmware/linux-firmware).
- Request a `tas2783.conf` SoundWire codec profile (modeled on `rt1308.conf`)
  in [`alsa-ucm-conf`](https://github.com/alsa-project/alsa-ucm-conf), plus a
  `cfg-amp:N` → implicit speaker fallback.
- The AMD ACP/SoundWire s2idle resume failure (whole card disappears) is a
  kernel bug worth reporting to the ALSA/SOF maintainers.
- The stereo-split fix is already posted upstream
  ([lore](https://lore.kernel.org/lkml/20260809101541.4969-1-wiza@saarinenkoti.fi/))
  but not yet merged (as of kernel 7.0.0-38). Once it lands in Ubuntu's
  kernel, drop the DKMS block from `fix-px13-audio.sh` and the `driver/`
  directory; the UCM `If.ControlExists` guards make the profile harmless
  either way.

## Licensing note

The fix scripts and config in this repo are free to use/modify. The TAS2783
**calibration firmware is proprietary to ASUS/TI** and is deliberately **not**
distributed here — you extract it from ASUS's own driver for your own machine.
