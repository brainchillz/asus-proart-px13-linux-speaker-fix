# Extracting the TAS2783 calibration firmware

The internal speaker amps on the ASUS ProArt PX13 (HN7306) are TI **TAS2783**
SoundWire smart amps. They need per-laptop **calibration firmware**:

```
1714-1-8.bin
1714-1-B.bin
```

These are **proprietary ASUS/TI blobs** and are **not shipped** in
`linux-firmware` (only some HP/Dell TAS2783 blobs are upstream). They are also
**not included in this public repository** for licensing reasons — you must
extract them yourself from ASUS's official Windows driver, which is free to
download from ASUS support.

Once extracted, drop them in this `firmware/` directory (named exactly
`1714-1-8.bin` and `1714-1-B.bin`) and run `../fix-px13-audio.sh`.

## Where the names come from

The kernel TAS2783 driver builds the firmware filename from
`<pci-subsystem-id>-<soundwire-link>-<slave-address>.bin`. For this laptop the
subsystem id is `0x1714`, the amps are on SoundWire link `1` at slave
addresses `0x8` and `0xB`, giving `1714-1-8.bin` and `1714-1-B.bin`. If a
future kernel reports different names, check:

```
dmesg | grep -i "Direct firmware load"
```

and rename the extracted blobs to match.

## Step 1 — Download the ASUS "TI SmartAMP" driver

From the ASUS ProArt PX13 (HN7306) support page → Driver & Tools → Audio, grab
the **TI SmartAMP** package. The version used here was:

```
SmartAMP_TI_DCH_TexasInstruments_Z_V6.3.1.15_47519.exe
```

Direct URL (may change/expire — prefer the official support page):

```
https://dlcdnets.asus.com/pub/ASUS/nb/Image/Driver/Audio/47519/SmartAMP_TI_DCH_TexasInstruments_Z_V6.3.1.15_47519.exe?model=HN7306EAC
```

## Step 2 — Unpack the installer and pull out the .bin files

The installer is an **InstallAware self-extracting EXE** (NOT Inno Setup, so
`innoextract` does not work on it). Two ways to get the firmware out:

### Option A — try archive extractors first (no Wine)

Some InstallAware EXEs can be opened directly. Try, in order:

```bash
# 7-Zip (p7zip-full)
7z x SmartAMP_TI_*.exe -oextracted

# or cabextract
cabextract -d extracted SmartAMP_TI_*.exe
```

Then look for the firmware:

```bash
find extracted -iname '1714-1-0x8.bin' -o -iname '1714-1-0xB.bin' \
                -o -iname '1714-1-*.bin'
```

If you find `Firmwares/1714-1-0x8.bin` and `Firmwares/1714-1-0xB.bin`, skip to
Step 3.

### Option B — run the installer under Wine and snapshot its temp dir

This is the method that worked here when the archive extractors couldn't crack
the InstallAware container. The installer self-extracts to a temp directory at
runtime; we grab the firmware from there.

```bash
sudo apt-get install -y wine64           # or your distro's wine package

# Run the installer silently under Wine. It self-extracts to a temp dir
# under the Wine prefix before installing.
wine64 SmartAMP_TI_*.exe /S &

# While it runs, find the extracted firmware in the Wine temp tree:
find ~/.wine/drive_c/users/*/Temp ~/.wine/drive_c/windows/temp \
     -iname '1714-1-0x8.bin' -o -iname '1714-1-0xB.bin' 2>/dev/null
```

If it self-extracts and exits too fast, run it without `/S`, leave the
installer window open on the first screen (it has already unpacked to temp at
that point), run the `find` above, copy the two files out, then cancel the
installer. You can `sudo apt-get remove --purge wine64` afterward.

## Step 3 — Install into this repo

Copy the two blobs here, **dropping the `0x`** from the names:

```bash
cp /path/to/1714-1-0x8.bin  firmware/1714-1-8.bin
cp /path/to/1714-1-0xB.bin  firmware/1714-1-B.bin
```

### Verify (optional)

The exact blobs from the `V6.3.1.15_47519` package are 40746 bytes each with
these SHA-256 sums:

```
9a105de50978fc3250062d66bea6b77f3aaabaf85280739be28ff1ed3ae535ca  1714-1-8.bin
a975dc7e2340cb5c97259d5e8c3d7e447b5a0af1a91528c058c9fda0adeb74c1  1714-1-B.bin
```

A different ASUS package version may ship different (but still valid)
calibration data, so a checksum mismatch is not necessarily wrong — what
matters is that `journalctl -k -b 0 | grep -i tas2783` shows no
"Direct firmware load ... failed" after running the fix.

## Step 4 — Run the fix

```bash
cd ..
./fix-px13-audio.sh
```
