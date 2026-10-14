#!/usr/bin/env bash
#
# Stereo verification test for the ASUS ProArt PX13 internal speakers.
#
# Plays the GNOME speaker-test voice samples ("left" / "right") hard-panned
# to each speaker, alternating: left, right, left, right. If stereo is
# working (patched tas2783 module + UCM profile from this repo), each word
# comes ONLY from the corresponding speaker; with the mirror-mode bug the
# right speaker is silent and both words come from the left one.
#
# The freedesktop samples are mono - GNOME's own Settings > Sound test
# dialog pans them per channel itself - so this script decodes them with
# GStreamer, pans them to one channel, and plays them with pw-play.
#
# Usage: ./test-stereo.sh

set -euo pipefail

SAMPLE_DIR=/usr/share/sounds/freedesktop/stereo
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for side in left right; do
  src="$SAMPLE_DIR/audio-channel-front-$side.oga"
  if [ ! -f "$src" ]; then
    echo "ERROR: voice sample not found: $src" >&2
    echo "       (part of the freedesktop sound theme, shipped by default on GNOME/KDE)" >&2
    exit 1
  fi
  gst-launch-1.0 -q filesrc location="$src" ! decodebin ! audioconvert \
    ! "audio/x-raw,format=S16LE" ! wavenc ! filesink location="$TMP/$side.wav"
  python3 -I - "$TMP/$side.wav" "$side" <<'EOF'
import struct, sys, wave
path, side = sys.argv[1], sys.argv[2]
w = wave.open(path)
n, fr = w.getnframes(), w.getframerate()
frames = struct.unpack(f"<{n}h", w.readframes(n))
w.close()
out = wave.open(path, "wb")
out.setnchannels(2)
out.setsampwidth(2)
out.setframerate(fr)
out.writeframesraw(b"".join(
    struct.pack("<hh", s, 0) if side == "left" else struct.pack("<hh", 0, s)
    for s in frames))
out.close()
EOF
done

echo "Listening for: 'left' (LEFT speaker), 'right' (RIGHT speaker), twice."
echo "If both words come from the same speaker, stereo is not working."
pw-play "$TMP/left.wav"
pw-play "$TMP/right.wav"
pw-play "$TMP/left.wav"
pw-play "$TMP/right.wav"
