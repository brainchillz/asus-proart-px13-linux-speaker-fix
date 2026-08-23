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

## Root causes (three separate problems)

1. **Missing TAS2783 calibration firmware.** The speaker amps are TI TAS2783
   SoundWire smart amps needing per-laptop calibration blobs
   (`1714-1-8.bin` / `1714-1-B.bin`). `linux-firmware` only ships TAS2783
   blobs for some HP/Dell machines — there are no ASUS `1714` blobs upstream,
   so the amp never initializes and playback fails.

2. **No ALSA UCM "Speaker" profile for the TAS2783.** Upstream
   `alsa-ucm-conf` has no `tas2783` codec profile. The kernel's
   `snd_acp_sdw_legacy_mach` machine driver also emits no ` spk:<codec>`
   token in `alsa.components` (this card reports
   `cfg-amp:2 mic:acp-dmic cfg-mics:1 hs:rt721`), so the generic
   `sof-soundwire` profile resolves `SpeakerCodec1` to `""`, never adds a
   Speaker device, and PipeWire falls back to a "Dummy Output" sink.

3. **The AMD ACP/SoundWire controller doesn't survive boot/suspend cleanly.**
   - Cold boot: TAS2783 firmware download intermittently fails with an SDW bus
     timeout (`FW download failed: -110`).
   - **s2idle resume: the entire `amd-soundwire` ALSA card disappears** — the
     ACP/SoundWire controller fails to re-initialize — dropping PipeWire back
     to "Dummy Output".

## What this repo installs

`fix-px13-audio.sh` installs all of the following (safe to re-run):

| Component | Installed to | Purpose |
|---|---|---|
| Calibration firmware | `/lib/firmware/1714-1-{8,B}.bin` (+ `ti/audio/tas2783/`) | Lets the TAS2783 amps initialize |
| UCM Speaker profile | `/usr/share/alsa/ucm2/sof-soundwire/tas2783.conf` | Adds a Speaker device on PCM 2 and unmutes both amps |
| Card override | `/usr/share/alsa/ucm2/conf.d/amd-soundwire/<card-long-name>.conf` | Force-selects the tas2783 profile. **Generated** from the installed `sof-soundwire.conf`, not shipped — see below |
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
speaker-test -D pipewire -c 2 -t sine -f 440
```

A reboot and a suspend/resume cycle should both keep the speakers working with
no manual intervention.

### Why the card override is generated, not shipped

Two things about the UCM layer are easy to get wrong, and both produce a
silent failure with no error pointing at the cause:

**The `Syntax` ceiling is enforced by alsa-lib, not alsa-ucm-conf.** Recent
`sof-soundwire.conf` declares `Syntax 7`. alsa-lib 1.2.11 — what Ubuntu 24.04
and Zorin 18 ship — refuses anything above `Syntax 6`:

```
ALSA lib parser.c:270:(parse_syntax_field) Incompatible syntax 7 in <card>.conf
```

Upgrading `alsa-ucm-conf` does **not** fix this and makes it worse: the newer
tree's own `sof-soundwire.conf` is `Syntax 7`, so overlaying it renders the
card unreadable. Ubuntu's `alsa-ucm-conf 1.2.10-1ubuntu5.14` is also not
vanilla 1.2.10 — it is heavily backported (`Syntax 6`, `MultiCodecInit`,
`rt1320`, and `acp-dmic.conf`, which upstream 1.2.15.2 does not ship at all
and the internal mic needs).

**The two alsa-ucm-conf generations gate the speaker include on different
variables:**

| Tree | `HiFi.conf` tests |
|---|---|
| upstream 1.2.15.x | `${var:SpeakerCodec1}` |
| Ubuntu 24.04 backport | `${var:SpeakerCodecFile}` |

Setting only `SpeakerCodec1` silently yields no Speaker device on
Ubuntu/Zorin. The override therefore sets **both**; the unused one is a
harmless no-op on either tree.

Generating the override from the installed `sof-soundwire.conf` sidesteps
both problems: it is always syntax-correct for the tree it came from, and its
`Include` paths always resolve.

## Hardware details

ASUS ProArt PX13 HN7306 · card long-name
`ASUSTeKCOMPUTERINC.-ProArtPX13HN7306EA{,C}-1.0-HN7306EA{,C}` (varies by
SKU; detected at runtime) · rt721-sdca jack
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

## Licensing note

The fix scripts and config in this repo are free to use/modify. The TAS2783
**calibration firmware is proprietary to ASUS/TI** and is deliberately **not**
distributed here — you extract it from ASUS's own driver for your own machine.
