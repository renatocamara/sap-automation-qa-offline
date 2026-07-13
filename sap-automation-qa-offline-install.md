# SAP Testing Automation Framework — Offline Installation Guide

**Purpose:** Install and run the [Azure/sap-automation-qa](https://github.com/Azure/sap-automation-qa)
configuration checks on a management (jump) server **without internet access**.

**Why this guide exists:** The repo ships no prebuilt offline package. Its standard
`scripts/setup.sh` downloads everything live — Azure CLI from Microsoft, Python packages
from PyPI, Ansible collections from Ansible Galaxy. On an air-gapped server it fails at
the first download. The solution is to stage every dependency on an internet-connected
machine, transfer one bundle, and install manually.

---

## Before you start: one important limitation

The configuration checks validate **Azure infrastructure** (VM SKU, Load Balancer
settings, disk types, ANF/AFS) by calling Azure management APIs with a managed identity
(`az login --identity`).

**Why this matters:** even a fully offline install still requires the management server
to reach Azure ARM endpoints (`management.azure.com`). Private endpoints, Azure service
tags, or an internal proxy all work — general internet is *not* required. But if the
server cannot reach ARM at all, the Azure infrastructure checks will fail and only the
OS/SAP-level checks will produce results. Confirm ARM reachability with your network
team before starting.

The SAP VMs themselves never need internet — the framework only connects to them over
SSH (Linux) or WinRM (Windows) from the management server.

---

## Prerequisites

| Requirement | Why |
|---|---|
| Staging machine **with internet**, same OS distro/version and CPU architecture as the offline server (e.g., both RHEL 8.10 x86_64) | Python wheels and OS packages are compiled per-platform. A bundle built on Ubuntu won't install on RHEL; one built on RHEL 9 may not install on RHEL 8. |
| Python **3.10+** (3.11 recommended) on **both** machines, same minor version | The framework requires ≥3.10, and pip downloads wheels tagged for the specific Python version that runs the download. A 3.11 bundle won't install into a 3.9 venv. |
| Managed identity with **Reader** role on the SAP resource groups, assigned to the management server VM | The Azure infrastructure checks read resource configurations via this identity. See repo `docs/SETUP.MD` §4. |
| Network path (SSH/WinRM) from management server to all SAP VMs | Ansible executes the OS/SAP-level checks over these connections. |

---

## Part 0 — Prepare the staging machine (first-time setup)

These steps happen on the **internet-connected staging machine** only. If git and
Python are already installed, skip to Part 1.

### Step 0.1 — Install git

Git is the tool used to download ("clone") the framework's source code from GitHub.

```bash
# RHEL / CentOS
sudo yum install -y git

# Ubuntu / Debian
sudo apt-get update && sudo apt-get install -y git

# SLES
sudo zypper install -y git
```

Verify it worked:

```bash
git --version        # should print something like: git version 2.39.x
```

### Step 0.2 — Install Python 3.10+ (3.11 recommended)

```bash
# RHEL 8/9
sudo dnf install -y python3.11 python3.11-pip

# Ubuntu 22.04 (python3 is already 3.10 — just add pip and venv)
sudo apt-get install -y python3-pip python3-venv

# SLES 15
sudo zypper install -y python311 python311-pip
```

Verify:

```bash
python3.11 --version    # or: python3 --version
```

**Why the version matters:** the framework requires Python ≥ 3.10, and the offline
bundle you build in Part 1 only works with the same Python version on both machines.

### Step 0.3 — Clone the repository (download the source code)

```bash
mkdir -p ~/sapqa-offline        # create a working folder
cd ~/sapqa-offline              # move into it
git clone https://github.com/Azure/sap-automation-qa.git
```

**What this command does:** `git clone <URL>` downloads a full copy of the repository
into a new folder named `sap-automation-qa` in your current directory. After it
finishes you can confirm with:

```bash
ls sap-automation-qa            # you should see scripts/, docs/, requirements.in, ...
```

**No git available / policy forbids it?** You can download the same content as a ZIP
instead: open `https://github.com/Azure/sap-automation-qa` in a browser, click the
green **Code** button → **Download ZIP**, then `unzip sap-automation-qa-main.zip` and
rename the folder to `sap-automation-qa`.

---

## Part 1 — Build the bundle (on the internet-connected staging machine)

### Step 1.1 — Pack the repository for transfer

```bash
cd ~/sapqa-offline
tar czf sap-automation-qa.tar.gz sap-automation-qa
```

**Why:** the offline server can't `git clone`, so the repo travels as a tarball. Record
the commit hash (`git -C sap-automation-qa rev-parse HEAD`) in your change docs — the
offline copy can't be updated in place, so you need to know exactly what version is
deployed.

### Step 1.2 — Download all Python packages as wheels

```bash
python3.11 -m pip download -r sap-automation-qa/requirements.in -d wheels/
```

**Why:** `pip download` resolves the full dependency tree (~100+ packages: ansible-core,
Azure SDKs, pywinrm, etc.) and saves the installable wheel files locally instead of
installing them. On the offline server, pip will install from this folder instead of
PyPI. This is why the Python version and OS must match — pip downloads wheels built for
*this* platform.

### Step 1.3 — Download the Ansible collections

```bash
python3.11 -m pip install ansible-core    # provides ansible-galaxy on the staging box
ansible-galaxy collection download -r sap-automation-qa/collections/requirements.yml -p collections_offline/
```

**Why:** the framework's playbooks depend on seven pinned collections
(`ansible.windows`, `ansible.posix`, `community.general`, …) normally pulled from
Ansible Galaxy at setup time. `collection download` saves them as tarballs **and**
generates a `requirements.yml` inside `collections_offline/` that points at those local
tarballs — that generated file is what you'll install from in Part 2.

### Step 1.4 — Download the Azure CLI as OS packages

RHEL example:

```bash
sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
sudo dnf install -y https://packages.microsoft.com/config/rhel/8/packages-microsoft-prod.rpm
sudo dnf download --resolve --destdir=azcli_rpms/ azure-cli
```

Ubuntu: `apt-get download azure-cli` (plus dependencies) · SLES: `zypper --download-only install azure-cli`

**Why:** `setup.sh` installs the Azure CLI by curling an installer script from
`aka.ms`, which is impossible offline. The distro package achieves the same result, and
`--resolve` pulls its dependency RPMs too, so the offline install won't stop on a
missing library. The CLI is required for `az login --identity`.

### Step 1.5 — Download the required OS packages

```bash
sudo dnf download --resolve --destdir=os_rpms/ python3.11 python3.11-pip sshpass git
```

**Why:** these are the system packages `setup.sh` would have installed:
`python3-pip`/`python3-venv` to build the virtual environment, `sshpass` for
password-based SSH used by Ansible, `git` optionally for version tracking. Skip any
already present on the target server — check first with `rpm -q <package>`.

### Step 1.6 — Pack everything into one archive

```bash
tar czf sapqa-offline-bundle.tar.gz sap-automation-qa.tar.gz wheels/ collections_offline/ azcli_rpms/ os_rpms/
```

**Why:** a single file is easier to move through approved transfer channels and to
checksum. Generate one: `sha256sum sapqa-offline-bundle.tar.gz` — verify it after
transfer to rule out corruption.

Transfer the bundle to the management server via your approved method (internal scp,
secure file transfer, removable media per policy).

---

## Part 2 — Install on the offline management server

> **Do not run `scripts/setup.sh`.** It curls the Azure CLI installer and contacts
> PyPI/Galaxy — all of which fail offline. The steps below replicate exactly what it
> does, using the bundle instead of the internet.

### Step 2.1 — Verify and unpack

```bash
sha256sum sapqa-offline-bundle.tar.gz          # compare against staging value
tar xzf sapqa-offline-bundle.tar.gz && cd sapqa-offline
```

### Step 2.2 — Install OS packages and Azure CLI

```bash
sudo rpm -ivh os_rpms/*.rpm          # dpkg -i / zypper in on Ubuntu/SLES
sudo rpm -ivh azcli_rpms/*.rpm
az version                            # confirm the CLI works
```

**Why first:** everything after this needs Python and the venv module; the test
execution later needs the CLI.

### Step 2.3 — Unpack the framework

```bash
tar xzf sap-automation-qa.tar.gz && cd sap-automation-qa
```

### Step 2.4 — Create the virtual environment and install Python packages offline

```bash
python3.11 -m venv .venv
source .venv/bin/activate
pip install --no-index --find-links=../wheels --upgrade pip
pip install --no-index --find-links=../wheels -r requirements.in
```

**Why these flags:** `--no-index` forbids pip from contacting PyPI (it would hang or
error against a blocked network); `--find-links=../wheels` tells it to resolve
everything from the transferred wheel folder. If this step reports a missing package,
the staging machine's OS/Python didn't match — rebuild the bundle on a matching system.

### Step 2.5 — Install the Ansible collections offline

```bash
mkdir -p .ansible/collections
ansible-galaxy collection install -r ../collections_offline/requirements.yml -p .ansible/collections
export ANSIBLE_COLLECTIONS_PATH="$PWD/.ansible/collections"
```

**Why:** the `requirements.yml` used here is the one *generated in Step 1.3* — it
references the local tarballs, so no Galaxy access is attempted. The export makes the
playbooks find the collections; add it to the shell profile of whoever runs the checks.

### Step 2.6 — Set the environment variables setup.sh would have set

```bash
export ANSIBLE_HOST_KEY_CHECKING=False
export ANSIBLE_PYTHON_INTERPRETER=$(which python3)
```

**Why:** without the first, Ansible prompts interactively on first SSH to each SAP host
and the run stalls; the second pins Ansible to the venv's Python so module dependencies
resolve.

---

## Part 3 — Configure and run

These steps are identical to the standard online procedure (repo `docs/SETUP.MD` §2 and
`docs/CONFIGURATION_CHECKS.md`); summarized here for completeness.

### Step 3.1 — Set the test type

In `vars.yaml`: `TEST_TYPE: "ConfigurationChecks"` and set `SYSTEM_CONFIG_NAME` to your
workspace folder name.

### Step 3.2 — Create the system workspace

Under `WORKSPACES/SYSTEM/<ENV-REGION-VNET-SID>/` create `hosts.yaml` (Ansible inventory
with each SAP host's IP, user, connection type), `sap-parameters.yaml` (SID, instance
numbers, platform, HA setup), and the credential file (`ssh_key.ppk` or `password`,
`chmod 600`). **Why:** this workspace is how the framework knows which hosts to check
and how to reach them — nothing is auto-discovered.

### Step 3.3 — Log in to Azure and run

```bash
az login --identity                       # uses the VM's managed identity — needs ARM reachability
az account set --subscription <sub-id>
./scripts/sap_automation_qa.sh            # all checks
# or scoped:
./scripts/sap_automation_qa.sh --extra-vars='{"configuration_test_type":"Database"}'
```

### Step 3.4 — Collect the report

```text
WORKSPACES/SYSTEM/<NAME>/quality_assurance/CONFIG_<SID>_<DB>_<INVOCATION_ID>.html
```

**Why:** this HTML report is the deliverable — share it with Microsoft for review and
recommendations.

---

## Alternative: Docker image transfer

If you prefer containers: on the staging machine run `./scripts/setup.sh container start`,
then `docker save sap-automation-qa -o sapqa-image.tar`; transfer and
`docker load -i sapqa-image.tar` on the management server. **Why consider it:** the
image bundles Python and all dependencies, eliminating the OS/Python matching concerns —
but it requires Docker on the offline server, and the ARM reachability limitation is
unchanged.

## Updating the framework

The offline server can't `git pull`. To update, repeat Part 1 on the staging machine
and transfer a fresh bundle. Pin and record a tested commit/tag per bundle so deployed
versions are traceable.
