#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ICON="$ROOT/assets/icon"
SET="$ROOT/build/CopyBridge.iconset"
mkdir -p "$SET" "$ROOT/build/icon-png"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$ICON/CopyBridge-master.png" --out "$SET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$ICON/CopyBridge-master.png" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$ICON/CopyBridge.icns"
cp "$SET/icon_256x256.png" "$ICON/CopyBridge-256.png"
for size in 16 24 32 48 64 128 256; do
  sips -z "$size" "$size" "$ICON/CopyBridge-master.png" --out "$ROOT/build/icon-png/$size.png" >/dev/null
done
python3 - "$ROOT" <<'PY'
from pathlib import Path
import struct,sys
root=Path(sys.argv[1]);sizes=[16,24,32,48,64,128,256]
entries=[];images=[];offset=6+16*len(sizes)
for size in sizes:
 data=(root/f'build/icon-png/{size}.png').read_bytes()
 assert data[:8]==b'\x89PNG\r\n\x1a\n'
 entries.append(struct.pack('<BBBBHHII',size%256,size%256,0,0,1,32,len(data),offset))
 images.append(data);offset+=len(data)
result=struct.pack('<HHH',0,1,len(sizes))+b''.join(entries)+b''.join(images)
assert len(result)==offset
(root/'assets/icon/CopyBridge.ico').write_bytes(result)
print('Created ICNS and multi-size ICO from the shared artwork')
PY
