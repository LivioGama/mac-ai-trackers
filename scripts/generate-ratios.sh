#!/bin/bash
# Orchestrate the full 5h <-> 7d ratio analysis pipeline:
#   1. analyze-token-ratios.py  (extract monotonic ranges)
#   2. ratios-to-csv.py         (convert to CSV for Sheets)
#   3. ratios-to-png.py         (generate PNG charts)
#
# Usage:
#   ./scripts/generate-ratios.sh [options]
#
# Options:
#   --data-dir DIR          Path to usage-history root (default: ~/.cache/ai-usages-tracker/usage-history/2026/)
#   --out-dir DIR           Output directory (default: /tmp)
#   --accounts-config FILE  Path to accounts.json with display names/colors
#                           (auto-generated if missing, see accounts.example.json)
#   --tz-offset H           Timezone offset for hour-of-day (default: +2, CEST)
#   --min-delta-5h N        Min token delta for a range (default: 5)
#   --skip-png              Skip PNG generation (faster for data analysis)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${HOME}/.cache/ai-usages-tracker/usage-history/2026"
OUT_DIR="/tmp"
ACCOUNTS_CONFIG=""
TZ_OFFSET=2
MIN_DELTA_5H=5
SKIP_PNG=0

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --data-dir)
      DATA_DIR="$2"
      shift 2
      ;;
    --out-dir)
      OUT_DIR="$2"
      shift 2
      ;;
    --accounts-config)
      ACCOUNTS_CONFIG="$2"
      shift 2
      ;;
    --tz-offset)
      TZ_OFFSET="$2"
      shift 2
      ;;
    --min-delta-5h)
      MIN_DELTA_5H="$2"
      shift 2
      ;;
    --skip-png)
      SKIP_PNG=1
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# Validate data directory
if [[ ! -d "$DATA_DIR" ]]; then
  echo "❌ Data directory not found: $DATA_DIR" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

echo "📊 Token Ratio Analysis Pipeline"
echo "========================================"
echo "Data dir:      $DATA_DIR"
echo "Output dir:    $OUT_DIR"
echo "TZ offset:     +${TZ_OFFSET}"
echo "Min delta 5h:  ${MIN_DELTA_5H} tokens"
echo ""

# Step 1: Extract monotonic ranges
echo "📍 Step 1: Extracting monotonic ranges..."
RATIOS_JSONL="${OUT_DIR}/ratios.jsonl"
python3 "${SCRIPT_DIR}/analyze-token-ratios.py" "$DATA_DIR" \
  --min-delta-5h "$MIN_DELTA_5H" \
  --out "$RATIOS_JSONL"
echo "   ✓ Ranges written to $RATIOS_JSONL"
echo ""

# Step 2: Convert to CSV
echo "📍 Step 2: Converting to CSV..."
python3 "${SCRIPT_DIR}/ratios-to-csv.py" "$RATIOS_JSONL" \
  --prefix "${OUT_DIR}/ratios" \
  --tz-offset "$TZ_OFFSET"
echo "   ✓ CSVs written to ${OUT_DIR}/ratios-*.csv"
echo ""

# Step 3: Generate PNGs (optional)
if [[ $SKIP_PNG -eq 0 ]]; then
  echo "📍 Step 3: Generating PNG charts..."

  # Ensure matplotlib venv exists
  VENV_DIR="/tmp/venv-ratios"
  if [[ ! -d "$VENV_DIR" ]]; then
    echo "   → Creating venv for matplotlib..."
    uv venv "$VENV_DIR" >/dev/null 2>&1
    uv pip install --python "${VENV_DIR}/bin/python" matplotlib >/dev/null 2>&1
  fi

  # Prepare arguments for ratios-to-png.py
  PNG_ARGS=("${OUT_DIR}/ratios")
  if [[ -n "$ACCOUNTS_CONFIG" ]]; then
    if [[ ! -f "$ACCOUNTS_CONFIG" ]]; then
      echo "   ❌ Accounts config not found: $ACCOUNTS_CONFIG" >&2
      exit 1
    fi
    PNG_ARGS+=("--accounts-config" "$ACCOUNTS_CONFIG")
  fi

  "${VENV_DIR}/bin/python" "${SCRIPT_DIR}/ratios-to-png.py" "${PNG_ARGS[@]}"
  echo "   ✓ PNGs written to ${OUT_DIR}/ratios-*.png"
else
  echo "📍 Step 3: Skipped (--skip-png)"
fi

echo ""
echo "✅ Pipeline complete!"
echo ""
echo "📁 Output files:"
echo "   ${OUT_DIR}/ratios.jsonl"
echo "   ${OUT_DIR}/ratios-macro.csv"
echo "   ${OUT_DIR}/ratios-scatter.csv"
if [[ $SKIP_PNG -eq 0 ]]; then
  echo "   ${OUT_DIR}/ratios-macro.png"
  echo "   ${OUT_DIR}/ratios-scatter.png"
fi
echo ""

# Show next steps
if [[ -z "$ACCOUNTS_CONFIG" ]]; then
  echo "💡 To customize chart labels/colors:"
  echo "   1. Copy: cp scripts/accounts.example.json accounts.json"
  echo "   2. Edit: edit accounts.json with your display names"
  echo "   3. Regenerate: ./scripts/generate-ratios.sh --accounts-config accounts.json"
fi
