# Quickstart — two scenarios

This assumes a jump (management) server **already exists** with network access to the
SAP VMs. Pick your scenario with one test, run on the jump server:

```bash
curl -sI --max-time 10 https://pypi.org >/dev/null && echo "SCENARIO 2 (online)" || echo "SCENARIO 1 (offline)"
```

| | Scenario 1 — air-gapped | Scenario 2 — internet/proxy available |
|---|---|---|
| Jump server can reach PyPI/GitHub | No | Yes (directly or via proxy) |
| Staging machine needed | **Yes** | No |
| Effort | ~25 commands, 2 machines | ~10 commands, 1 machine |
| Reference | This page + [full offline guide](./sap-automation-qa-offline-install.md) | This page |

Both scenarios share the same prerequisites and the same execution/report steps —
only the **installation** differs.

---

## Common prerequisites (both scenarios)

1. Managed identity on the jump server VM, with **Reader** on every resource group
   containing SAP components:

   ```bash
   az vm identity assign -g <JUMP_RG> -n <JUMP_VM>
   az role assignment create --assignee <PRINCIPAL_ID> --role Reader \
     --scope /subscriptions/<SUB_ID>/resourceGroups/<SAP_RG>
   ```

2. SSH (Linux) or WinRM (Windows) from the jump server to all SAP VMs.
3. Jump server must reach `management.azure.com` (Azure ARM). Private endpoint,
   service tags, or proxy all qualify — general internet is not required for this.

---

## Scenario 1 — air-gapped jump server (staging machine required)

The jump server cannot download anything, so a disposable internet-connected Linux
machine ("staging") builds a bundle first. **The staging machine must match the jump
server's OS distribution/version and Python minor version.**

### 1a. On the STAGING machine (internet)

```bash
mkdir -p ~/sapqa-offline && cd ~/sapqa-offline
git clone https://github.com/Azure/sap-automation-qa.git
tar czf sap-automation-qa.tar.gz sap-automation-qa
python3 -m pip download -r sap-automation-qa/requirements.in -d wheels/
python3 -m pip install ansible-core
ansible-galaxy collection download -r sap-automation-qa/collections/requirements.yml -p collections_offline/
sudo dnf download --resolve --destdir=azcli_rpms/ azure-cli        # apt-get download / zypper --download-only per distro
sudo dnf download --resolve --destdir=os_rpms/ python3-pip sshpass # only what's missing on the jump server
tar czf sapqa-offline-bundle.tar.gz sap-automation-qa.tar.gz wheels/ collections_offline/ azcli_rpms/ os_rpms/
sha256sum sapqa-offline-bundle.tar.gz
scp sapqa-offline-bundle.tar.gz <user>@<jump-server-ip>:~/
```

### 1b. On the JUMP SERVER (offline install — do NOT run setup.sh)

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

Continue at **Execution** below.

---

## Scenario 2 — jump server with internet or allowlisted proxy

No staging machine, no bundle. Everything happens on the jump server:

```bash
# if behind a proxy, first: export http_proxy=... https_proxy=...
sudo dnf install -y git        # apt-get / zypper per distro
git clone https://github.com/Azure/sap-automation-qa.git
cd sap-automation-qa
./scripts/setup.sh             # installs Azure CLI, Python venv, Ansible collections
source .venv/bin/activate
```

Endpoints the proxy must allow: `github.com`, `pypi.org`, `files.pythonhosted.org`,
`galaxy.ansible.com`, `aka.ms`, `packages.microsoft.com`, `management.azure.com`.

Continue at **Execution** below.

---

## Execution (identical for both scenarios)

```bash
# 1. vars.yaml: set TEST_TYPE: "ConfigurationChecks" and SYSTEM_CONFIG_NAME
# 2. Create the system workspace:
mkdir -p WORKSPACES/SYSTEM/<ENV-REGION-VNET-SID>
#    Add: hosts.yaml (inventory), sap-parameters.yaml (SID/platform/HA),
#         ssh_key.ppk or password file (chmod 600)
# 3. Run:
az login --identity
az account set --subscription <SUB_ID>
./scripts/sap_automation_qa.sh
```

**Deliverable:** `WORKSPACES/SYSTEM/<NAME>/quality_assurance/CONFIG_<SID>_<DB>_<ID>.html`
— open in a browser, share with Microsoft for review and recommendations.

---

## Known issues — apply BEFORE the first run

Lab-validated fixes for framework v1.1.2 (details in [LAB-FINDINGS.md](./LAB-FINDINGS.md)):

```bash
# after cloning sap-automation-qa, from this repo:
./apply-framework-fixes.sh /path/to/sap-automation-qa
```

And if the SAP VMs run SLES 15 / RHEL 8 (default Python 3.6), add to every host in
`hosts.yaml`:

```yaml
ansible_python_interpreter: "/usr/bin/python3.11"
```

Without these, every Linux run fails at "Prepare system context information" with an
error hidden behind `no_log`.
