#!/bin/bash
# =============================================================================
# apply-framework-fixes.sh
#
# Applies the fixes documented in LAB-FINDINGS.md to a fresh clone of
# Azure/sap-automation-qa (validated against v1.1.2).
#
# Usage: ./apply-framework-fixes.sh [path-to-sap-automation-qa]   (default: .)
# Run AFTER cloning the framework, BEFORE running the checks.
#
# Note: Issue 1 (target Python >= 3.7) is fixed in YOUR workspace hosts.yaml
# (ansible_python_interpreter), not here — see LAB-FINDINGS.md.
# =============================================================================
set -euo pipefail

REPO="${1:-.}"
FILE="$REPO/src/roles/configuration_checks/tasks/main.yml"
[[ -f "$FILE" ]] || { echo "ERROR: $FILE not found. Pass the sap-automation-qa path."; exit 1; }

# --- Fix: skipped Windows IMDS task clobbers Linux compute_metadata register --
if grep -q "compute_metadata_win" "$FILE"; then
    echo "[skip] Windows register already renamed."
else
    python3 - "$FILE" <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read()
head, sep, tail = s.partition('ansible.windows.win_uri:')
if not sep:
    print("[warn] win_uri task not found — framework layout changed?"); sys.exit(0)
tail = tail.replace('compute_metadata', 'compute_metadata_win', 2)
open(p, 'w').write(head + sep + tail)
print("[ok] Windows IMDS register renamed to compute_metadata_win.")
EOF
fi

# --- Fix: add return_content to the Linux IMDS uri task (defensive) ----------
if awk '/ansible.builtin.uri:/,/register:/' "$FILE" | grep -q "return_content"; then
    echo "[skip] return_content already present on Linux IMDS task."
else
    sed -i '/ansible.builtin.uri:/a\    return_content:                 true' "$FILE"
    echo "[ok] return_content: true added to Linux IMDS task."
fi

echo "Done. Reminder: add ansible_python_interpreter to hosts.yaml if targets run Python < 3.7 (SLES 15 / RHEL 8 defaults)."
