#!/usr/bin/env bash
# Render the single combined launch video (demo/sources/launch.tape →
# demo/assets/launch.mp4). Wraps `vhs` with the same isolation/validation
# story as demo/render-all.sh, but only for the launch tape.
#
# Usage:  demo/launch-render.sh
#
# Output: demo/assets/launch.mp4 (1280x720, ~60s, MP4 H.264 from VHS).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
TAPE="$SCRIPT_DIR/sources/launch.tape"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

for cmd in vhs nvim task; do
  if ! command -v "$cmd" &>/dev/null; then
    echo -e "${RED}ERROR${NC}: $cmd not found on PATH"
    exit 1
  fi
done

# Use the existing tape validator — same isolation rules as the rest.
echo "=== Validate launch tape ==="
bash "$SCRIPT_DIR/validate-tapes.sh" "$TAPE"

cd "$REPO_DIR"

echo
echo "=== Render launch.mp4 (this may take 60–90s) ==="
# Longer timeout than render-all.sh since this tape is intentionally longer.
if timeout 300 vhs "$TAPE"; then
  echo -e "${GREEN}Render complete.${NC}"
else
  echo -e "${RED}Render failed.${NC}"
  exit 1
fi

OUT="$REPO_DIR/demo/assets/launch.mp4"
if [ ! -f "$OUT" ]; then
  echo -e "${RED}Expected output $OUT not found.${NC}"
  exit 1
fi

size_kb=$(( $(stat -c%s "$OUT" 2>/dev/null || stat -f%z "$OUT" 2>/dev/null) / 1024 ))
echo
echo "  $OUT"
echo "  size: ${size_kb}KB"

# Reddit's video upload cap is 60MB. Warn early so we don't realize on upload.
if [ "$size_kb" -gt 60000 ]; then
  echo -e "  ${YELLOW}WARN${NC} ${size_kb}KB exceeds Reddit's 60MB upload cap — re-encode before uploading."
elif [ "$size_kb" -gt 25000 ]; then
  echo -e "  ${YELLOW}NOTE${NC} ${size_kb}KB is large for r/neovim auto-preview; consider an ffmpeg -crf 28 pass."
else
  echo -e "  ${GREEN}OK${NC}   under Reddit's upload cap."
fi

# Probe duration if ffprobe is available — useful for checking the tape paced
# correctly without hand-watching every render.
if command -v ffprobe &>/dev/null; then
  duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$OUT" 2>/dev/null || echo "?")
  echo "  duration: ${duration}s"
fi
