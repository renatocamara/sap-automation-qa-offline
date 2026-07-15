#!/usr/bin/env bash
#
# setup-and-run.sh — One-shot offline runner for the SAP configuration checks, executed
# ON THE JUMP SERVER. It asks for the customer-specific inputs up front, then does the
# rest automatically: offline install (Step 4), workspace generation (Step 6),
# configuration (Step 7a), connectivity check, the run (Step 8), and a report summary
# (Step 9). Nothing is installed on the SAP servers — the checks are read-only.
#
# Two ways to run:
#   Interactive (default):   ./setup-and-run.sh
#   Non-interactive:         ./setup-and-run.sh --answers answers.env   (or: ANSWERS=answers.env)
#                            (great for a security review of the inputs, and for repeats)
#
# See answers.env.example for the non-interactive format.
#
set -euo pipefail

# ---- defaults (env / answers-file overridable) ------------------------------
# Find the bundle wherever the operator put it: an explicit BUNDLE wins; otherwise look
# in the current directory, then next to this script, then $HOME. Everything (extract +
# install) then happens in that same directory — not a hardcoded $HOME.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${BUNDLE:-}" ]]; then
  for _cand in "$PWD/sapqa-offline-bundle.tar.gz" "$SCRIPT_DIR/sapqa-offline-bundle.tar.gz" "$HOME/sapqa-offline-bundle.tar.gz"; do
    [[ -f "$_cand" ]] && { BUNDLE="$_cand"; break; }
  done
  BUNDLE="${BUNDLE:-$PWD/sapqa-offline-bundle.tar.gz}"
fi
WORK_DIR="${WORK_DIR:-$(cd "$(dirname "$BUNDLE")" 2>/dev/null && pwd || echo "$PWD")}"
FRAMEWORK_DIR="${FRAMEWORK_DIR:-$WORK_DIR/sap-automation-qa}"
REINSTALL="${REINSTALL:-0}"          # 1 = force re-extract + re-install even if present
ASSUME_YES="${ASSUME_YES:-0}"        # 1 = don't pause for confirmation
ANSWERS="${ANSWERS:-}"

# customer inputs (may come from answers file / env; otherwise prompted)
SID="${SID:-}"
SYSTEM_CONFIG_NAME="${SYSTEM_CONFIG_NAME:-}"
SSH_USER="${SSH_USER:-}"
AUTH_MODE="${AUTH_MODE:-}"           # keyfile | agent
SSH_KEY_PATH="${SSH_KEY_PATH:-}"     # required if AUTH_MODE=keyfile
AZURE_ACCESS="${AZURE_ACCESS:-no}"   # yes | no  (no => offline, skip Azure auth)
# SAP parameters (sensible defaults matching QUICKSTART 6.3)
DB_SID="${DB_SID:-HDB}"
PLATFORM="${PLATFORM:-HANA}"
SCS_HA="${SCS_HA:-false}"
DB_HA="${DB_HA:-false}"
SCS_INSTANCE="${SCS_INSTANCE:-00}"
ERS_INSTANCE="${ERS_INSTANCE:-01}"
DB_INSTANCE="${DB_INSTANCE:-00}"
NFS_PROVIDER="${NFS_PROVIDER:-AFS}"
# HOSTS format (non-interactive): space-separated "tier:hostname:ip" items, e.g.
#   HOSTS="db:vm-sapdb01:10.20.1.36 scs:vm-sapascs01:10.20.1.37"
HOSTS="${HOSTS:-}"

# ---- helpers ----------------------------------------------------------------
log()  { printf '\n\033[1;34m[run]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[run:warn]\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31m[run:ERROR]\033[0m %s\n' "$*" >&2; exit 1; }
ask()  { # ask "Prompt" "default" -> echoes answer
  local p="$1" d="${2:-}" a
  if [[ -n "$d" ]]; then read -r -p "$p [$d]: " a; echo "${a:-$d}"
  else read -r -p "$p: " a; echo "$a"; fi
}
confirm() {
  [[ "$ASSUME_YES" == "1" ]] && return 0
  local a; read -r -p "$1 [y/N]: " a; [[ "$a" =~ ^[Yy]$ ]]
}

# parse flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --answers) ANSWERS="$2"; shift 2;;
    --reinstall) REINSTALL=1; shift;;
    --yes|-y) ASSUME_YES=1; shift;;
    -h|--help) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) die "unknown argument: $1";;
  esac
done
if [[ -n "$ANSWERS" ]]; then
  [[ -f "$ANSWERS" ]] || die "answers file not found: $ANSWERS"
  log "Loading answers from $ANSWERS"
  # shellcheck disable=SC1090
  source "$ANSWERS"
  ASSUME_YES=1   # answers file implies unattended
fi

declare -A TIER_HOSTS   # tier -> newline list of "hostname ip"

# =============================================================================
# 1) OFFLINE INSTALL  (QUICKSTART Step 4)
# =============================================================================
install_offline() {
  if [[ -d "$FRAMEWORK_DIR/.venv" && "$REINSTALL" != "1" ]]; then
    log "Framework already installed at $FRAMEWORK_DIR (use --reinstall to rebuild). Skipping install."
    return 0
  fi
  [[ -f "$BUNDLE" ]] || die "bundle not found: $BUNDLE (copy it here or set BUNDLE=/path)."

  log "Verifying and unpacking the bundle"
  if [[ -f "$BUNDLE.sha256" ]]; then
    ( cd "$(dirname "$BUNDLE")" && sha256sum -c "$(basename "$BUNDLE").sha256" ) \
      || die "bundle checksum mismatch — re-transfer it."
  else
    warn "no .sha256 next to the bundle — skipping integrity check."
  fi

  cd "$WORK_DIR"
  tar xzf "$BUNDLE"
  # python3.11 from carried RPMs, only if the jump lacks it.
  # Use dnf with all repos disabled: it installs the local RPM set OFFLINE, resolves
  # dependencies among them, and SKIPS any package already present — unlike `rpm -Uvh`,
  # which is atomic and aborts the whole transaction if one RPM is already installed.
  if ! command -v python3.11 >/dev/null 2>&1; then
    if compgen -G "jump_rpms/*.rpm" >/dev/null; then
      log "Installing python3.11 from carried RPMs (offline)"
      sudo dnf install -y --disablerepo='*' jump_rpms/*.rpm \
        || sudo rpm -Uvh --replacepkgs jump_rpms/*.rpm \
        || warn "RPM install reported errors — verifying below"
      command -v python3.11 >/dev/null 2>&1 \
        || die "python3.11 still not found after installing jump_rpms. Try manually: sudo dnf install -y --disablerepo='*' jump_rpms/*.rpm"
    else
      die "python3.11 not present and no jump_rpms/*.rpm in the bundle. See QUICKSTART Step 1/2."
    fi
  fi

  tar xzf sap-automation-qa.tar.gz
  tar xzf tools.tar.gz
  cd "$FRAMEWORK_DIR"

  log "Creating framework venv and installing dependencies offline (--no-index)"
  python3.11 -m venv .venv
  # shellcheck disable=SC1091
  source .venv/bin/activate
  pip install --no-index --find-links=../wheels --upgrade pip
  pip install --no-index --find-links=../wheels -r requirements.in

  log "Installing Ansible collections (from collections_offline/)"
  mkdir -p .ansible/collections
  local coll_dir="$PWD/.ansible/collections"
  ( cd ../collections_offline && ansible-galaxy collection install -r requirements.yml -p "$coll_dir" )

  log "Applying validated framework fixes"
  bash ../tools/apply-framework-fixes.sh .

  log "Offline install complete."
}

# =============================================================================
# 2) GATHER INPUTS
# =============================================================================
gather_inputs() {
  log "Collecting the details for this SAP system"
  [[ -n "$SID" ]] || SID="$(ask 'SAP SID (e.g. X00)')"
  SID="${SID^^}"
  [[ "$SID" =~ ^[A-Z][A-Z0-9]{2}$ ]] || warn "SID '$SID' is unusual (expected 3 chars like X00) — continuing."

  if [[ -z "$SYSTEM_CONFIG_NAME" ]]; then
    local suggest="PRD-EUS2-SAP01-$SID"
    SYSTEM_CONFIG_NAME="$(ask 'Workspace name (ENV-REGION-VNET-SID)' "$suggest")"
  fi

  [[ -n "$SSH_USER" ]] || SSH_USER="$(ask 'SSH user for the SAP servers' 'azureadm')"

  # hosts
  if [[ -n "$HOSTS" ]]; then
    local item t h ip
    for item in $HOSTS; do
      IFS=':' read -r t h ip <<<"$item"
      [[ -n "$t" && -n "$h" && -n "$ip" ]] || die "bad HOSTS item '$item' (expected tier:hostname:ip)."
      TIER_HOSTS["$t"]+="$h $ip"$'\n'
    done
  else
    echo "  Enter each SAP server. Tier is one of: db, scs, app, pas, ers, web."
    while true; do
      local t h ip
      t="$(ask '  Tier (blank to finish)')"; [[ -z "$t" ]] && break
      h="$(ask '  Hostname (e.g. vm-sapdb01)')"
      ip="$(ask '  IP address')"
      [[ -n "$h" && -n "$ip" ]] || { warn "hostname/ip required — skipping"; continue; }
      TIER_HOSTS["$t"]+="$h $ip"$'\n'
    done
  fi
  [[ ${#TIER_HOSTS[@]} -gt 0 ]] || die "no SAP servers provided."

  # credentials
  if [[ -z "$AUTH_MODE" ]]; then
    echo "  How should the jump authenticate to the SAP servers?"
    echo "    1) key file  (copied into the workspace as ssh_key.ppk, chmod 600)"
    echo "    2) ssh-agent (no key file on disk — recommended by many security teams)"
    case "$(ask '  Choose 1 or 2' '2')" in
      1) AUTH_MODE="keyfile";;
      *) AUTH_MODE="agent";;
    esac
  fi
  if [[ "$AUTH_MODE" == "keyfile" && -z "$SSH_KEY_PATH" ]]; then
    SSH_KEY_PATH="$(ask '  Path to the private key file')"
  fi
  [[ "$AUTH_MODE" == "keyfile" && ! -f "$SSH_KEY_PATH" ]] && die "key file not found: $SSH_KEY_PATH"

  if [[ -z "${AZURE_ACCESS_SET:-}" && "$ASSUME_YES" != "1" ]]; then
    if confirm "  Does this jump server have a route to Azure (management.azure.com)?"; then
      AZURE_ACCESS="yes"
    else
      AZURE_ACCESS="no"
    fi
  fi
}

# =============================================================================
# 3) GENERATE WORKSPACE  (QUICKSTART Step 6)
# =============================================================================
generate_workspace() {
  WS="$FRAMEWORK_DIR/WORKSPACES/SYSTEM/$SYSTEM_CONFIG_NAME"
  log "Generating workspace: $WS"
  mkdir -p "$WS/logs"

  # 6.2 hosts.yaml (grouped by tier); node_tier per tier
  {
    local tier group ntier line h ip
    for tier in "${!TIER_HOSTS[@]}"; do
      case "$tier" in
        db)  group="${SID}_DB";  ntier="$( [[ "${PLATFORM^^}" == "HANA" ]] && echo hana || echo db )";;
        scs) group="${SID}_SCS"; ntier="scs";;
        ers) group="${SID}_ERS"; ntier="ers";;
        app) group="${SID}_APP"; ntier="app";;
        pas) group="${SID}_PAS"; ntier="pas";;
        web) group="${SID}_WEB"; ntier="web";;
        *)   group="${SID}_${tier^^}"; ntier="$tier";;
      esac
      echo "${group}:"
      echo "  hosts:"
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        h="${line%% *}"; ip="${line##* }"
        echo "    ${h}:"
        echo "      ansible_host: \"${ip}\""
        echo "      ansible_user: \"${SSH_USER}\""
        echo "      ansible_connection: \"ssh\""
        echo "      connection_type: \"key\""
        echo "      virtual_host: \"${h}\""
        echo "      become_user: \"root\""
        echo "      os_type: \"linux\""
        echo "      ansible_python_interpreter: \"/usr/bin/python3\""
        echo "      vm_name: \"${h}\""
      done <<<"${TIER_HOSTS[$tier]}"
      echo "  vars:"
      echo "    node_tier: \"${ntier}\""
    done
  } > "$WS/hosts.yaml"

  # 6.3 sap-parameters.yaml
  cat > "$WS/sap-parameters.yaml" <<EOF
sap_sid: "${SID}"
db_sid: "${DB_SID}"
platform: "${PLATFORM}"
scs_high_availability: ${SCS_HA}
database_high_availability: ${DB_HA}
database_scale_out: false
scs_instance_number: "${SCS_INSTANCE}"
ers_instance_number: "${ERS_INSTANCE}"
db_instance_number: "${DB_INSTANCE}"
NFS_provider: "${NFS_PROVIDER}"
user_assigned_identity_client_id: ""
EOF

  # 6.4 credentials
  if [[ "$AUTH_MODE" == "keyfile" ]]; then
    cp "$SSH_KEY_PATH" "$WS/ssh_key.ppk"
    chmod 600 "$WS/ssh_key.ppk"
    log "Key file placed at $WS/ssh_key.ppk (chmod 600). Consider 'shred -u' after the run."
  else
    log "ssh-agent mode: no key file written to the workspace."
  fi
}

# =============================================================================
# 4) CONFIGURE vars.yaml  (QUICKSTART Step 7a)
# =============================================================================
configure_vars() {
  log "Setting vars.yaml (TEST_TYPE + SYSTEM_CONFIG_NAME)"
  cd "$FRAMEWORK_DIR"
  sed -i \
    -e 's/^TEST_TYPE:.*/TEST_TYPE: "ConfigurationChecks"/' \
    -e "s/^SYSTEM_CONFIG_NAME:.*/SYSTEM_CONFIG_NAME: \"$SYSTEM_CONFIG_NAME\"/" \
    vars.yaml
  grep -E '^(TEST_TYPE|SYSTEM_CONFIG_NAME)' vars.yaml
}

# =============================================================================
# 5) CONNECTIVITY CHECK
# =============================================================================
connectivity_check() {
  log "Testing SSH connectivity to each SAP server"
  local tier line h ip sshopts=(-o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no)
  [[ "$AUTH_MODE" == "keyfile" ]] && sshopts+=(-i "$WS/ssh_key.ppk")
  local fail=0
  for tier in "${!TIER_HOSTS[@]}"; do
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      h="${line%% *}"; ip="${line##* }"
      if ssh -n "${sshopts[@]}" "${SSH_USER}@${ip}" 'echo ok' >/dev/null 2>&1; then
        printf '   \033[1;32mOK\033[0m   %s (%s)\n' "$h" "$ip"
      else
        printf '   \033[1;31mFAIL\033[0m %s (%s)\n' "$h" "$ip"; fail=1
      fi
    done <<<"${TIER_HOSTS[$tier]}"
  done
  if [[ $fail -eq 1 ]]; then
    warn "One or more servers were unreachable over SSH."
    confirm "Continue anyway?" || die "Aborted at connectivity check."
  fi
}

# =============================================================================
# 6) RUN  (QUICKSTART Step 8)
# =============================================================================
run_checks() {
  cd "$FRAMEWORK_DIR"
  # shellcheck disable=SC1091
  source .venv/bin/activate
  if [[ "$AUTH_MODE" == "keyfile" ]]; then
    log "Running the checks via the wrapper (key file)"
    ./scripts/sap_automation_qa.sh
  else
    log "Running the playbook directly (ssh-agent mode)"
    [[ -n "$(ssh-add -l 2>/dev/null)" ]] || die "no key loaded in ssh-agent. Run: eval \"\$(ssh-agent -s)\"; ssh-add <key>"
    export ANSIBLE_COLLECTIONS_PATH="$PWD/.ansible/collections:/opt/ansible/collections"
    export ANSIBLE_CONFIG="$PWD/src/ansible.cfg"
    export ANSIBLE_MODULE_UTILS="$PWD/src/module_utils"
    export ANSIBLE_HOST_KEY_CHECKING=False
    local logstamp; logstamp="$(date +%Y%m%d_%H%M%S)"
    export ANSIBLE_LOG_PATH="$WS/logs/execution_${logstamp}.log"
    ansible-playbook src/playbook_00_configuration_checks.yml \
      -i "$WS/hosts.yaml" \
      -e @vars.yaml -e @"$WS/sap-parameters.yaml" \
      -e "_workspace_directory=$WS"
  fi
}

# =============================================================================
# 7) SUMMARY  (QUICKSTART Step 9)
# =============================================================================
summarize() {
  local report
  report="$(ls -t "$WS/quality_assurance/"CONFIG_*.html 2>/dev/null | head -1 || true)"
  if [[ -z "$report" ]]; then
    warn "No report file found in $WS/quality_assurance/ — check the run output above."
    return 0
  fi
  log "Report generated:"
  echo "   $report"
  # count check statuses with the venv python
  python3 - "$report" <<'PY' || true
import re,sys,html
from collections import Counter
src=open(sys.argv[1],encoding="utf-8").read()
rows=re.findall(r'<tr[^>]*>(.*?)</tr>', src, re.S)
c=Counter()
for r in rows:
    cs=re.findall(r'<td[^>]*>(.*?)</td>', r, re.S)
    cs=[re.sub(r'\s+',' ',html.unescape(re.sub(r'<[^>]+>',' ',x))).strip() for x in cs]
    if len(cs)==5 and re.match(r'^[A-Z].*-\d', cs[0] or ''):
        c[cs[4]]+=1
print("   Check results:", dict(c))
PY
  cat <<'EOF'

   Offline scope note (for the deliverable / cover email):
   ---------------------------------------------------------------------------
   The OS and SAP configuration checks are complete and reflect the actual state
   of the servers. The Azure infrastructure checks (VM SKU, disk performance
   tier/IOPS/MBPS, accelerated networking, HA placement) could not run on an
   offline jump and appear as N/A / INFO / FAILED — this is a scope limitation,
   not a configuration defect. Those items are validated separately by someone
   with Azure portal access, or by enabling Azure access on the jump server.
   ---------------------------------------------------------------------------

   Copy the report to your laptop with:
EOF
  echo "     scp ${SSH_USER}@<jump-server>:\"$report\" ."
}

# =============================================================================
# main
# =============================================================================
main() {
  log "SAP configuration checks — offline one-shot runner"
  install_offline
  gather_inputs

  echo
  log "About to generate the workspace and run read-only checks with these settings:"
  echo "   SID                : $SID"
  echo "   Workspace          : $SYSTEM_CONFIG_NAME"
  echo "   SSH user           : $SSH_USER"
  echo "   Auth mode          : $AUTH_MODE${SSH_KEY_PATH:+ ($SSH_KEY_PATH)}"
  echo "   Azure access       : $AZURE_ACCESS (offline run skips Azure auth)"
  local tier
  for tier in "${!TIER_HOSTS[@]}"; do
    echo "   Tier $tier:"; printf '                        %s\n' ${TIER_HOSTS[$tier]//$'\n'/ }
  done
  echo
  confirm "Proceed?" || die "Aborted by user."

  generate_workspace
  configure_vars
  connectivity_check
  run_checks
  summarize
  log "All done."
}
main "$@"
