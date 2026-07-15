#!/usr/bin/env bash
#
# build-bundle.sh — Build the offline bundle on an internet-connected Linux operator
# machine. Automates Step 2 of QUICKSTART.md end to end.
#
# Output: sapqa-offline-bundle.tar.gz (+ .sha256) — carry it to the offline jump server,
# then run setup-and-run.sh there.
#
# Assumptions: Linux, python3 + python3-venv + git present, internet access.
# Nothing customer-specific is needed here — this bundle is generic.
#
# Override any default with an environment variable, e.g.:
#   WORKDIR=/tmp/sapqa ./build-bundle.sh
#
set -euo pipefail

# ---- configuration (env-overridable) ---------------------------------------
WORKDIR="${WORKDIR:-$HOME/sapqa-offline}"
FRAMEWORK_REPO="${FRAMEWORK_REPO:-https://github.com/Azure/sap-automation-qa.git}"
TOOLS_REPO="${TOOLS_REPO:-https://github.com/renatocamara/sap-automation-qa-offline.git}"
ANSIBLE_CORE_CONSTRAINT="${ANSIBLE_CORE_CONSTRAINT:-ansible-core<2.17}"  # option B: no change on SAP servers
TARGET_PYVER="${TARGET_PYVER:-3.11}"                 # the jump server's Python
TARGET_PLATFORM="${TARGET_PLATFORM:-manylinux2014_x86_64}"

# ---- helpers ----------------------------------------------------------------
log()  { printf '\n\033[1;34m[build]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[build:warn]\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31m[build:ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

# ---- preflight --------------------------------------------------------------
log "Preflight checks"
command -v python3 >/dev/null || die "python3 not found."
command -v git     >/dev/null || die "git not found (sudo apt-get install -y git)."
python3 -m venv --help >/dev/null 2>&1 || die "python3-venv missing (sudo apt-get install -y python3-venv)."
python3 -c 'import ensurepip' 2>/dev/null || die "python3 venv/pip support missing (install python3-venv)."

log "Working directory: $WORKDIR"
mkdir -p "$WORKDIR" && cd "$WORKDIR"

# ---- 0. build venv (PEP 668-safe) -------------------------------------------
log "Creating build virtual environment (.buildenv)"
python3 -m venv .buildenv
# shellcheck disable=SC1091
source .buildenv/bin/activate
pip install --quiet --upgrade pip

# ---- 1. framework + tools ---------------------------------------------------
log "Cloning framework and tools repos"
rm -rf sap-automation-qa tools
git clone --depth 1 "$FRAMEWORK_REPO" sap-automation-qa
git clone --depth 1 "$TOOLS_REPO" tools
tar czf sap-automation-qa.tar.gz sap-automation-qa
tar czf tools.tar.gz tools

# ---- 2. Python dependencies (for the jump server platform) ------------------
log "Downloading Python wheels (Linux/$TARGET_PLATFORM, py$TARGET_PYVER, '$ANSIBLE_CORE_CONSTRAINT')"
echo "$ANSIBLE_CORE_CONSTRAINT" > constraints.txt
rm -rf wheels && mkdir -p wheels
pip download -r sap-automation-qa/requirements.in -c constraints.txt -d wheels/ \
  --platform "$TARGET_PLATFORM" --python-version "$TARGET_PYVER" --only-binary=:all: \
  || die "pip download failed. If one package has no matching wheel, see QUICKSTART Step 2 note."

# ---- 3. Ansible collections -------------------------------------------------
log "Downloading Ansible collections"
pip install --quiet ansible-core
rm -rf collections_offline && mkdir -p collections_offline
ansible-galaxy collection download \
  -r sap-automation-qa/collections/requirements.yml -p collections_offline/

# ---- 4. jump-server RPMs (python3.11 for the offline RHEL 9 jump) -----------
# A fresh RHEL 9 jump ships only python3.9; ansible-core 2.16 needs a >=3.10 control
# interpreter, so the jump needs python3.11. Offline it can't dnf-install it, so we
# carry the RPMs in the bundle. We fetch them WITHOUT a Red Hat subscription using a
# UBI9 container (python3.11 is in the free UBI repos) — works on any laptop OS that
# has podman or docker. On a RHEL host we fall back to host dnf.
RPMS="python3.11 python3.11-pip git"
mkdir -p jump_rpms
fetch_rpms_container() {   # $1 = podman|docker
  "$1" run --rm -v "$PWD/jump_rpms:/rpms" registry.access.redhat.com/ubi9/ubi:latest \
    bash -c "dnf install -y --downloadonly --downloaddir=/rpms $RPMS"
}
if command -v podman >/dev/null 2>&1; then
  log "Fetching jump python3.11 RPMs via podman (UBI9, no subscription needed)"
  fetch_rpms_container podman && log "RPMs in jump_rpms/" || warn "podman RPM fetch failed — see note below."
elif command -v docker >/dev/null 2>&1; then
  log "Fetching jump python3.11 RPMs via docker (UBI9, no subscription needed)"
  fetch_rpms_container docker && log "RPMs in jump_rpms/" || warn "docker RPM fetch failed — see note below."
elif command -v dnf >/dev/null 2>&1; then
  log "RHEL host — downloading python3.11 RPMs via host dnf"
  dnf install -y --downloadonly --downloaddir=jump_rpms/ $RPMS 2>/dev/null \
    || dnf download --resolve --destdir=jump_rpms/ $RPMS 2>/dev/null \
    || warn "host dnf RPM fetch failed — see note below."
else
  warn "No podman/docker/dnf found — cannot fetch python3.11 RPMs."
fi
if ! compgen -G "jump_rpms/*.rpm" >/dev/null; then
  warn "jump_rpms/ is EMPTY. A fresh RHEL 9 jump has no python3.11 and setup-and-run.sh"
  warn "will stop there. Fix: install podman/docker on this machine (e.g. 'sudo apt-get"
  warn "install -y podman') and re-run, OR drop RHEL 9 python3.11 RPMs into $WORKDIR/jump_rpms/."
fi

# ---- 5. pack + fingerprint --------------------------------------------------
log "Packing the bundle"
tar czf sapqa-offline-bundle.tar.gz \
  sap-automation-qa.tar.gz tools.tar.gz wheels/ collections_offline/ jump_rpms/
SUM=$(sha256sum sapqa-offline-bundle.tar.gz | awk '{print $1}')
echo "$SUM  sapqa-offline-bundle.tar.gz" > sapqa-offline-bundle.tar.gz.sha256

# Drop the jump-server runner (and answers template) NEXT TO the bundle, so the operator
# can start it without first digging it out of tools.tar.gz inside the bundle.
for f in setup-and-run.sh answers.env.example; do
  if [[ -f "tools/$f" ]]; then
    cp "tools/$f" "./$f"
    [[ "$f" == *.sh ]] && chmod +x "./$f"
  fi
done

deactivate || true

# ---- done -------------------------------------------------------------------
log "DONE."
cat <<EOF

  Bundle : $WORKDIR/sapqa-offline-bundle.tar.gz
  SHA256 : $SUM
           (also saved to sapqa-offline-bundle.tar.gz.sha256)
  Runner : $WORKDIR/setup-and-run.sh          (copied out for convenience)
           $WORKDIR/answers.env.example

Next steps:
  1) Copy the bundle AND the runner to the jump server, e.g.:
       scp "$WORKDIR/sapqa-offline-bundle.tar.gz" \\
           "$WORKDIR/setup-and-run.sh" <user>@<jump-server>:~/
  2) On the jump server, run it (it extracts and installs the bundle itself):
       bash ~/setup-and-run.sh
EOF
