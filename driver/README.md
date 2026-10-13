# Patched `snd-soc-tas2783-sdw` kernel module (stereo split fix)

Out-of-tree build of `sound/soc/codecs/tas2783-sdw.c` carrying the
upstream-pending patch series
["ASoC: tas2783: fix stereo split and resume on a two-amp pair"](https://lore.kernel.org/lkml/20260809101541.4969-1-wiza@saarinenkoti.fi/)
(Ville Saarinen, 2026-08-09, not yet merged as of kernel 7.0.0-38).
Install via `../fix-px13-audio.sh`; it is a DKMS package, so it rebuilds
automatically for every new kernel.

## Why

The PX13 has two mono TAS2783 amps on one SoundWire link. The in-tree
driver hands both amps `ch_mask 0x3` on a stereo stream, which the
SoundWire core treats as *mirror mode*: both amps get the same payload
block offset, so both render the left channel and the right speaker is
silent. (Verified against the 7.0.0-34 source:
`snd_sdw_params_to_config()` in `include/sound/sdw.h` sets
`GENMASK(ch_count-1,0)`, and `sdw_compute_slave_ports()` in
`drivers/soundwire/generic_bandwidth_allocation.c` advances the offset by
the *popcount* of `ch_mask`.)

The series adds a per-amp boolean control, **`RX Single Channel Switch`**
(off by default), that makes the amp claim a single channel so the core
assigns the pair consecutive offsets (left amp = left channel, right amp
= right channel; the side follows the machine driver's codec order, not
the control). The UCM profile in `../ucm/` turns the switch on for both
amps. The series also fixes two resume-related bugs (deferred SDCA
writes failing with `-ENODATA`, and resume-time `regcache_sync()`
overwriting firmware-owned registers).

## Layout

- `tas2783-sdw.c`, `tas2783.h` — verbatim from `linux-source-7.0.0`
  `7.0.0-34.34` (`sound/soc/codecs/`), with `patches/` applied
  (`patch -p4`, all hunks at offset ≤ 10 lines).
- `patches/` — the three upstream patches, quoted-printable-decoded.
- `dkms.conf`, `Makefile` — DKMS package; installs to
  `/lib/modules/<k>/updates/dkms/`, which `depmod` prefers over the
  in-tree `kernel/sound/soc/codecs/` copy of the same name.
- `regenerate.sh` — re-apply `patches/` onto a different kernel version's
  source (see below).

## Regenerating for a new kernel

DKMS rebuilds the snapshot above against new headers automatically, but
if a kernel update changes the codec's internals the build will fail
(the in-tree module then stays in place - degraded to mirror mono, not
broken). Regenerate from that kernel's source:

```sh
apt-get download linux-source-<ver>=<abinv>       # e.g. linux-source-7.0.0=7.0.0-38.38
tar -xjf linux-source-*.tar.bz2 -C /tmp/x         # extract linux-source deb's data.tar
./regenerate.sh /tmp/x/usr/src/linux-source-*/linux-source-*
```

Then bump `PACKAGE_VERSION` in `dkms.conf`, re-run `fix-px13-audio.sh`,
and reload (see the script's output / main README).

Once the series lands in Ubuntu's kernel, delete this directory and the
DKMS block in `fix-px13-audio.sh`; the UCM `If.ControlExists` guards make
the profile harmless either way.
