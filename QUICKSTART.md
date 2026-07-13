# Quickstart — running the SAP configuration checks

## Background — why this documentation exists

Your SAP landscape runs on Azure inside a protected network. Before relying on it in
production, Microsoft provides a free validation tool — the
[SAP Testing Automation Framework](https://github.com/Azure/sap-automation-qa) — that
inspects the deployment (VM configuration, storage, network, SAP/HANA parameters,
cluster settings) and produces an HTML assessment report you can review with Microsoft
to receive recommendations.

The framework was designed assuming open internet access, which secure SAP
environments don't have. This repository closes that gap: it documents exactly how to
install and run the checks from a **jump (management) server** inside your network,
covers both connectivity situations you may be in, and includes fixes for issues we
found and resolved while validating the entire procedure end to end in a lab replica
of this topology (hub/spoke, Azure Landing Zone policies, SLES SAP nodes) on
2026-07-13 — culminating in a successfully generated report.

Two principles worth stating up front:

- **Nothing is ever installed on the SAP servers.** The framework connects to them
  over SSH in read-only fashion. All software lives on the jump server.
- The jump server needs to reach Azure management APIs (`management.azure.com`) via
  its managed identity for the infrastructure checks — private connectivity or proxy
  is sufficient.

## Which scenario are you in?

Run this on the jump server:

```bash
curl -sI --max-time 10 https://pypi.org >/dev/null && echo "SCENARIO 2 (online)" || echo "SCENARIO 1 (offline)"
```

| | **Scenario 2 — jump server with internet/proxy** | Scenario 1 — fully air-gapped |
|---|---|---|
| Jump server reaches PyPI/GitHub | Yes (directly or via allowlisted proxy) | No |
| Extra "staging" machine needed | No | **Yes** |
| Effort | ~10 commands, 1 machine | ~25 commands, 2 machines |

**Scenario 2 is the primary path of this guide** (it matches this environment).
Scenario 1 is retained as the fallback at the end, in case connectivity is ever
restricted further.

---

# Scenario 2 — existing jump server with internet access

**The scenario:** you already have a jump server VM inside the Azure network, with a
route to the SAP VMs and outbound internet access (direct or through an allowlisted
proxy). Everything happens on this one machine: it downloads the framework and its
dependencies, connects to the SAP servers over SSH to read their configuration,
queries Azure resource settings through its managed identity, and generates the
report. No staging machine, no offline bundle.

![Scenario 2 architecture](./architecture-online.svg)

The numbered flow: (1) the jump server installs the framework and dependencies
directly from public sources; (2) it inspects the SAP VMs via SSH — read-only;
(3) it validates Azure resource configuration through ARM using its managed identity;
(4) it generates the HTML assessment report; (5) the report is shared with Microsoft.

If a proxy is in the path, it must allow: `github.com`, `pypi.org`,
`files.pythonhosted.org`, `galaxy.ansible.com`, `aka.ms`, `packages.microsoft.com`,
`management.azure.com`.

## Step-by-step

### Step 1 — One-time prerequisites (run from any machine with Azure CLI)

Enable a managed identity on the jump server VM and grant it **Reader** on every
resource group containing SAP components (VMs, disks, load balancers, network,
shared storage):

```bash
az vm identity assign -g <JUMP_RG> -n <JUMP_VM>
az role assignment create --assignee <PRINCIPAL_ID> --role Reader \
  --scope /subscriptions/<SUB_ID>/resourceGroups/<SAP_RG>
```

Also confirm SSH (Linux) or WinRM (Windows) works from the jump server to every SAP VM.

### Step 2 — On the jump server: install the framework

```bash
# if behind a proxy, first: export http_proxy=... https_proxy=...
sudo apt-get install -y git     # yum/zypper per distro
git clone https://github.com/Azure/sap-automation-qa.git
cd sap-automation-qa
./scripts/setup.sh              # installs Azure CLI, Python venv, Ansible collections (~5-10 min)
source .venv/bin/activate
```

### Step 3 — Apply the validated fixes (required — see LAB-FINDINGS.md)

Without these, every Linux run fails with an error hidden behind `no_log`:

```bash
# from a clone of this repo (or download the script raw from GitHub):
./apply-framework-fixes.sh ~/sap-automation-qa
```

### Step 4 — Check Python on the SAP servers

The framework requires Python ≥ 3.7 **on the SAP VMs**. SLES 15 / RHEL 8 default to
3.6. First, just check — recent Azure images often already include a newer
interpreter side by side (our lab's SLES 15 SP5 image shipped `python3.11` out of
the box):

```bash
ssh <user>@<sap-vm> 'ls /usr/bin/python3*'
```

If a 3.7+ interpreter is listed, nothing to install — you'll simply reference it in
`hosts.yaml` (Step 5). If not, install one. Note that the SAP VMs having "no
internet" does **not** block this: SLES/RHEL pay-as-you-go VMs on Azure receive
packages from the distro's Azure-internal update infrastructure (SUSE Public Cloud
Update Infrastructure / RHUI) — the same private channel that delivers their security
patches:

```bash
ssh <user>@<sap-vm> 'sudo zypper install -y python311'    # SLES
ssh <user>@<sap-vm> 'sudo dnf install -y python3.11'      # RHEL
```

The install is harmless to SAP: it adds a parallel interpreter and changes no system
default. Only if even the update infrastructure is blocked (rare), transfer the RPMs
through the jump server and install with `rpm -ivh` — same offline pattern as
Scenario 1.

### Step 5 — Describe the SAP system (workspace)

```bash
mkdir -p WORKSPACES/SYSTEM/<ENV-REGION-VNET-SID>
```

Create three files in that folder (full templates in the
[offline guide, Part 3](./sap-automation-qa-offline-install.md)):

- `hosts.yaml` — inventory: each SAP host's IP, SSH user, role (`hana`/`scs`/`app`),
  and `ansible_python_interpreter: "/usr/bin/python3.11"` per host (see Step 4)
- `sap-parameters.yaml` — SID, instance numbers, platform (HANA/Db2), HA topology
- `ssh_key.ppk` — private key the SAP VMs accept (`chmod 600`)

### Step 6 — Configure and authenticate

```bash
# vars.yaml: TEST_TYPE: "ConfigurationChecks", SYSTEM_CONFIG_NAME: "<your workspace name>"
az login --identity && az account set --subscription <SAP_SUB_ID>
sudo az login --identity && sudo az account set --subscription <SAP_SUB_ID>
```

Both logins are needed: the framework's Azure collectors run as root, and Azure CLI
sessions are per-user (validated finding — see LAB-FINDINGS.md issue 4).

### Step 7 — Run

```bash
./scripts/sap_automation_qa.sh
# scoped alternatives:
#   --extra-vars='{"configuration_test_type":"Database"}'
#   --extra-vars='{"configuration_test_type":"CentralServiceInstances"}'
```

### Step 8 — Collect the deliverable

```text
WORKSPACES/SYSTEM/<NAME>/quality_assurance/CONFIG_<SID>_<DB>_<INVOCATION_ID>.html
```

Open in a browser; share with Microsoft for review and recommendations.

---

# Scenario 1 — air-gapped jump server (fallback)

**The scenario:** the jump server cannot reach any public endpoint. A disposable
internet-connected Linux machine ("staging") — which must match the jump server's OS
distribution/version and Python version — builds a dependency bundle that is
transferred once.

![Scenario 1 architecture](./architecture.svg)

Condensed procedure (full detail with per-step explanations in the
[offline installation guide](./sap-automation-qa-offline-install.md)):

### On the STAGING machine (internet)

```bash
mkdir -p ~/sapqa-offline && cd ~/sapqa-offline
git clone https://github.com/Azure/sap-automation-qa.git
tar czf sap-automation-qa.tar.gz sap-automation-qa
python3 -m pip download -r sap-automation-qa/requirements.in -d wheels/
python3 -m pip install ansible-core
ansible-galaxy collection download -r sap-automation-qa/collections/requirements.yml -p collections_offline/
sudo dnf download --resolve --destdir=azcli_rpms/ azure-cli        # apt/zypper per distro
sudo dnf download --resolve --destdir=os_rpms/ python3-pip sshpass
tar czf sapqa-offline-bundle.tar.gz sap-automation-qa.tar.gz wheels/ collections_offline/ azcli_rpms/ os_rpms/
sha256sum sapqa-offline-bundle.tar.gz
scp sapqa-offline-bundle.tar.gz <user>@<jump-server-ip>:~/
```

### On the JUMP SERVER (offline install — do NOT run setup.sh)

```bash
sha256sum sapqa-offline-bundle.tar.gz            # compare with staging value
tar xzf sapqa-offline-bundle.tar.gz
sudo rpm -ivh os_rpms/*.rpm azcli_rpms/*.rpm     # dpkg -i / zypper in per distro
tar xzf sap-automation-qa.tar.gz && cd sap-automation-qa
python3 -m venv .venv && source .venv/bin/activate
pip install --no-index --find-links=../wheels --upgrade pip
pip install --no-index --find-links=../wheels -r requirements.in
mkdir -p .ansible/collections
ansible-galaxy collection install -r ../collections_offline/requirements.yml -p .ansible/collections
export ANSIBLE_COLLECTIONS_PATH="$PWD/.ansible/collections"
export ANSIBLE_HOST_KEY_CHECKING=False
export ANSIBLE_PYTHON_INTERPRETER=$(which python3)
```

Then continue from **Scenario 2, Step 3** (fixes, workspace, run, report) — those
steps are identical in both scenarios.
