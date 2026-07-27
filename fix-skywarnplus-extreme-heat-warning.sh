#!/usr/bin/env bash
#
# fix-skywarnplus-extreme-heat-warning.sh
#
# Adds compatibility for the newer NWS alert name:
#   "Extreme Heat Warning"
# by mapping it to SkywarnPlus's existing:
#   "Excessive Heat Warning"
#
# This patches both the live-alert and tail-message audio lookups.
#
# Usage:
#   sudo bash fix-skywarnplus-extreme-heat-warning.sh
#
# Optional:
#   sudo bash fix-skywarnplus-extreme-heat-warning.sh --reset-state
#
# --reset-state removes SkywarnPlus's cached alert state and wx-tail.wav
# so the current alerts are rebuilt immediately on the next run.
#

set -Eeuo pipefail

SKYWARN_DIR="/usr/local/bin/SkywarnPlus"
SKYWARN_SCRIPT="${SKYWARN_DIR}/SkywarnPlus.py"
STATE_DIR="/tmp/SkywarnPlus"
RESET_STATE="no"

log() {
    printf '[SkywarnPlus Fix] %s\n' "$*"
}

fail() {
    printf '[SkywarnPlus Fix] ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage:
  sudo bash fix-skywarnplus-extreme-heat-warning.sh [--reset-state]

Options:
  --reset-state   Remove cached SkywarnPlus alert state and wx-tail.wav
                  after patching, forcing a fresh rebuild.
  -h, --help      Show this help.
EOF
}

for arg in "$@"; do
    case "$arg" in
        --reset-state)
            RESET_STATE="yes"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "Unknown option: $arg"
            ;;
    esac
done

if [[ "${EUID}" -ne 0 ]]; then
    fail "Run this script as root, for example: sudo bash $0"
fi

if [[ ! -f "${SKYWARN_SCRIPT}" ]]; then
    fail "SkywarnPlus.py was not found at ${SKYWARN_SCRIPT}"
fi

command -v python3 >/dev/null 2>&1 || fail "python3 is not installed."

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="${SKYWARN_SCRIPT}.backup-extreme-heat-${TIMESTAMP}"

log "Creating backup:"
log "  ${BACKUP}"
cp -a "${SKYWARN_SCRIPT}" "${BACKUP}"

rollback() {
    local exit_code=$?
    if [[ ${exit_code} -ne 0 ]]; then
        printf '[SkywarnPlus Fix] Patch failed. Restoring backup.\n' >&2
        cp -a "${BACKUP}" "${SKYWARN_SCRIPT}" || true
    fi
    exit "${exit_code}"
}
trap rollback EXIT

PATCH_RESULT="$(
python3 - "${SKYWARN_SCRIPT}" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

alias_line_pattern = re.compile(
    r'^[ \t]*alert_audio_name\s*=\s*"Excessive Heat Warning"\s+'
    r'if\s+alert\s*==\s*"Extreme Heat Warning"\s+else\s+alert\s*$',
    re.MULTILINE,
)

direct_lookup_pattern = re.compile(
    r'^(?P<indent>[ \t]*)index\s*=\s*ALERT_STRINGS\.index\(alert\)\s*$',
    re.MULTILINE,
)

if alias_line_pattern.search(text):
    print("already_patched")
    sys.exit(0)

def replacement(match: re.Match[str]) -> str:
    indent = match.group("indent")
    return (
        f'{indent}alert_audio_name = "Excessive Heat Warning" '
        f'if alert == "Extreme Heat Warning" else alert\n'
        f'{indent}index = ALERT_STRINGS.index(alert_audio_name)'
    )

patched_text, count = direct_lookup_pattern.subn(replacement, text)

if count == 0:
    print("no_match")
    sys.exit(2)

path.write_text(patched_text, encoding="utf-8")
print(f"patched:{count}")
PY
)" || {
    status=$?
    if [[ ${status} -eq 2 ]]; then
        fail "The expected SkywarnPlus alert lookup code was not found. The installed version may use different code."
    fi
    fail "The patch operation failed."
}

case "${PATCH_RESULT}" in
    already_patched)
        log "The compatibility fix is already installed. No code changes were needed."
        ;;
    patched:*)
        PATCH_COUNT="${PATCH_RESULT#patched:}"
        log "Patched ${PATCH_COUNT} alert-audio lookup occurrence(s)."
        ;;
    *)
        fail "Unexpected patch result: ${PATCH_RESULT}"
        ;;
esac

log "Checking Python syntax..."
if ! python3 -m py_compile "${SKYWARN_SCRIPT}"; then
    fail "Python syntax validation failed."
fi

chmod +x "${SKYWARN_SCRIPT}"

if [[ "${RESET_STATE}" == "yes" ]]; then
    log "Backing up and clearing cached SkywarnPlus state..."

    if [[ -f "${STATE_DIR}/data.json" ]]; then
        cp -a "${STATE_DIR}/data.json" \
            "${STATE_DIR}/data.json.backup-extreme-heat-${TIMESTAMP}"
    fi

    rm -f "${STATE_DIR}/data.json"
    rm -f "${STATE_DIR}/wx-tail.wav"

    log "Cached data.json and wx-tail.wav were removed."
fi

trap - EXIT

log "Fix installed successfully."
log "Backup retained at:"
log "  ${BACKUP}"

if [[ "${RESET_STATE}" == "yes" ]]; then
    log "Run SkywarnPlus now with:"
    log "  sudo -u asterisk ${SKYWARN_SCRIPT}"
else
    log "SkywarnPlus will use the fix on its next scheduled run."
    log "To force a fresh rebuild, rerun this script with --reset-state."
fi
