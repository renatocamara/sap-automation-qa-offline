# Quickstart — SAP configuration checks in the offline environment

## Background — why this documentation exists

Your SAP landscape runs on Azure inside a protected network. Microsoft provides a
free validation tool — the
[SAP Testing Automation Framework](https://github.com/Azure/sap-automation-qa) — that
inspects the deployment (VM configuration, storage, network, SAP/HANA parameters,
cluster settings) and produces an HTML assessment report you review with Microsoft
to receive recommendations.

The framework was designed assuming open internet access, which this environment
doesn't have. This guide adapts it to the real topology: an **on-premises jump
server with no internet access**, connected to the SAP servers on Azure through
ExpressRoute. The procedure was validated end to end in a lab replica, including
fixes for real framework issues found during validation
([LAB-FINDINGS.md](./LAB-FINDINGS.md)).

> **This guide assumes you already have an offline jump server** — that is the
> customer's situation. You do **not** create any VMs here. (Only if you want to
> *reproduce* the whole scenario from scratch in Azure for testing/rehearsal, there
> is a helper script — see [LAB.md](./LAB.md). It is not part of this procedure.)

## ❓ Does anything get installed on the SAP servers?

Answering this first because it's the most important question for any SAP owner:

- **No agent, no service, no framework component is installed on the SAP servers.**
  The framework runs entirely on the jump server and connects to each SAP server
  over SSH. During a check, Ansible (the engine underneath) temporarily copies small
  Python scripts to a temp directory on the server, executes them **read-only**,
  and removes them — standard agentless behavior, nothing persists.
- **The Python version, handled without touching the SAP servers (✅ lab-validated):**
  the SAP servers run Python 3.6 (RHEL 8.10 default), and the newest framework engine
  requires Python ≥ 3.7 on the machines it inspects. The fix lives **entirely on the
  jump server**: pin the engine to `ansible-core 2.16` (part of the bundle), which
  still supports Python 3.6 targets. In our lab replica (RHEL 8.10 + Python 3.6), the
  full checks ran with zero failures and generated the report — **nothing installed
  on the SAP servers.** This is the default this guide follows (Step 2 pins it).
  - *Fallback only if a future framework version drops 2.16 support:* install
    `python3.11` on each SAP server (additive RPM, no default change, no service
    restart, `sudo` required, DEV/QAS first). Not needed today.
- **Permissions for the checks themselves:** an SSH user on each SAP server able to
  `sudo` to root without password (used to read configurations only).

## The environment

![Environment architecture](./architecture-onprem.svg)

| Component | Details |
|---|---|
| Jump server | **On-premises**, RHEL 9 — no internet, no Azure portal access. Installs and runs the framework. |
| Operator laptop | Has internet access; SSH client to the jump server. **Downloads the bundle** and transfers it. |
| Connectivity | On-premises ↔ Azure via **ExpressRoute** (private peering) |
| SAP servers | Azure VMs, RHEL 8.10, Python 3.6, no internet |

The flow: (1) the laptop downloads the framework and all dependencies (the
"bundle"); (2) the bundle is copied to the jump server via `scp`; (3) the jump
server runs the read-only checks against the SAP servers over ExpressRoute; (4) the
report is generated on the jump server; (5) copied back to the laptop and shared
with Microsoft.

> ⚠️ **To confirm with the customer:** this guide assumes the **operator laptop** is
> the internet-connected machine that downloads the bundle. If a different machine
> or file-transfer process is mandated (e.g. a controlled transfer area), only
> Steps 2–3 change — the origin of the files must then be documented here.

## ⚠️ One decision before starting: can the Azure checks run?

Part of the framework's value is validating **Azure resource configuration** (VM
SKUs, disks, load balancers). That requires the jump server to reach two public
endpoints. Test it:

> ☁️ **Run on: JUMP SERVER**

```bash
curl -sI --max-time 10 https://login.microsoftonline.com >/dev/null && echo AUTH-OK || echo AUTH-BLOCKED
curl -sI --max-time 10 https://management.azure.com >/dev/null && echo ARM-OK || echo ARM-BLOCKED
```

- **Blocked (expected here):** the run proceeds with **OS/SAP-level checks only**;
  Azure infrastructure checks appear as errors in the report. Step 4's fix script
  prepares the framework for this. If full coverage is wanted later, the network
  team can evaluate allowlisting those two endpoints via proxy.
- **Both OK:** you'll authenticate with a **service principal** in Step 7b and get
  the full report (a managed identity is not possible — the jump server is not an
  Azure VM).

## Where each step runs

Only three places exist in this procedure: 💻 the **operator laptop** (internet),
☁️ the **jump server** (no internet), and — via SSH from the jump server — the SAP
servers. Every step is tagged.

---

## Step 1 — Prerequisites on the jump server

> ☁️ **Run on: JUMP SERVER.**

The framework needs **Python 3.11, git, pip and sshpass** on the jump server (RHEL 9's
default is Python 3.9, too old to run the framework's engine; git is not installed by
default either — ✅ both confirmed in the lab). First check whether the jump server can
reach the Red Hat channel:

```bash
sudo dnf install -y python3.11 python3.11-pip git sshpass && python3.11 --version
```

- **If it succeeds** (3.11.x prints): done, go to Step 2.
- **If it times out / fails:** expected and common. ⚠️ **Lab-validated finding** — an
  on-premises jump server (and an Azure Landing Zone hub subnet) frequently has **no
  route to Red Hat's update servers (RHUI)**, so `dnf` cannot fetch anything. In that
  case the `python3.11` RPMs are **downloaded on the laptop and carried in the
  bundle** (Step 2 includes them) and installed offline in Step 4. Nothing more to do
  here — continue to Step 2.

Also confirm the jump server can SSH into every SAP server (it already can, per the
environment description).

## Step 2 — Download the bundle

> 💻 **Run on: OPERATOR LAPTOP** (the machine with internet). Commands assume a
> Linux/macOS shell; on Windows, use WSL (a Linux environment inside Windows) — same
> commands. If you don't have WSL yet, do the one-time setup just below first.

### First time on a Windows laptop? Install WSL (one-time)

The commands in this step need a **Linux** environment. On Windows, the simplest way to
get one is **WSL** (Windows Subsystem for Linux). You only do this once.

1. Click **Start**, type **PowerShell**, right-click **Windows PowerShell** and choose
   **Run as administrator**.
2. In the blue window, type this one command and press Enter:

   ```powershell
   wsl --install
   ```

   This installs WSL and **Ubuntu** (a Linux distribution) automatically.
3. **Restart the computer** when it asks.
4. After the restart, an **Ubuntu** window opens by itself and asks you to create a
   **username and password** — pick any; this is your Linux login (the password is
   invisible as you type, that's normal).
5. From now on, open **Ubuntu** from the Start menu whenever this guide says
   "operator laptop". The first time, install the two helpers the bundle build needs:

   ```bash
   sudo apt-get update && sudo apt-get install -y python3-venv git
   ```

   (It will ask for the Ubuntu password you just created.)

> **If `wsl --install` fails or is blocked:** WSL needs administrator rights, an internet
> connection, and Windows 10 (version 2004+) or Windows 11. In locked-down corporate
> laptops it is sometimes disabled by policy — if the command errors out, ask your IT
> team to enable WSL, or use any Linux machine/VM you already have instead. You do **not**
> need WSL on the jump server — only on this internet-connected laptop, and only to build
> the bundle.

**Reference:** Microsoft's official WSL install guide —
[How to install Linux on Windows with WSL](https://learn.microsoft.com/en-us/windows/wsl/install).

Once you have a Linux shell (WSL/Ubuntu, macOS, or Linux), run:

```bash
mkdir -p ~/sapqa-offline && cd ~/sapqa-offline

# 0. A local virtual environment for the download tooling. REQUIRED on modern
#    Ubuntu/Debian (Python 3.11+), where `pip install` into the system Python is
#    blocked with "externally-managed-environment" (PEP 668). The venv sidesteps
#    that cleanly (✅ found during a laptop dry-run). Needs python3-venv:
#      sudo apt-get install -y python3-venv     # Debian/Ubuntu, one time
python3 -m venv .buildenv
source .buildenv/bin/activate
pip install --upgrade pip

# 1. The framework + this documentation/fixes repo
git clone https://github.com/Azure/sap-automation-qa.git
git clone https://github.com/renatocamara/sap-automation-qa-offline.git tools
tar czf sap-automation-qa.tar.gz sap-automation-qa
tar czf tools.tar.gz tools

# 2. Python dependencies (~100 packages), targeting the jump server's platform:
#    Linux x86_64 + Python 3.11 — regardless of what the laptop runs.
#    The ansible-core<2.17 constraint is what lets the checks run against the SAP
#    servers' Python 3.6 WITHOUT installing anything on them (✅ lab-validated).
echo 'ansible-core<2.17' > constraints.txt
pip download -r sap-automation-qa/requirements.in -c constraints.txt -d wheels/ \
  --platform manylinux2014_x86_64 --python-version 3.11 --only-binary=:all:

# 3. Ansible collections (ansible-core goes into the .buildenv, not the system)
pip install ansible-core
ansible-galaxy collection download -r sap-automation-qa/collections/requirements.yml -p collections_offline/

# 4. python3.11 + git RPMs for the JUMP SERVER (only needed if Step 1's dnf failed —
#    i.e. the jump server can't reach Red Hat's RHUI; ✅ common in ALZ/on-prem).
#    Skip if Step 1 succeeded. Must be RHEL/EL 9 RPMs (matching the jump server),
#    downloaded on a RHEL 9 machine with a Red Hat subscription:
#      mkdir -p jump_rpms && dnf download --resolve --destdir=jump_rpms/ python3.11 python3.11-pip git sshpass
#    (If the laptop isn't RHEL 9, get them from the Red Hat customer portal or a
#    RHEL 9 VM; keep them in ./jump_rpms/ so they ride along in the bundle.)

# 5. Pack everything into ONE file and fingerprint it
tar czf sapqa-offline-bundle.tar.gz sap-automation-qa.tar.gz tools.tar.gz wheels/ collections_offline/ jump_rpms/ 2>/dev/null || \
tar czf sapqa-offline-bundle.tar.gz sap-automation-qa.tar.gz tools.tar.gz wheels/ collections_offline/
sha256sum sapqa-offline-bundle.tar.gz
```

Note the `sha256sum` value — you'll compare it after the transfer.

> If step 2's `pip download` fails on a specific package with "no matching
> distribution", run that same command inside WSL/Linux without the three
> `--platform/--python-version/--only-binary` flags.

## Step 3 — Transfer the bundle to the jump server

> 💻 **Run on: OPERATOR LAPTOP** (it sends the file **to** the jump server).

```bash
scp sapqa-offline-bundle.tar.gz <user>@<jump-server>:~/
```

## Step 4 — Install the framework on the jump server (offline)

> ☁️ **Run on: JUMP SERVER.**

Verify the transfer, unpack, and install — **do NOT run the framework's `setup.sh`**
(it requires internet); these commands replicate it offline:

```bash
sha256sum ~/sapqa-offline-bundle.tar.gz     # must match Step 2's value
cd ~ && tar xzf sapqa-offline-bundle.tar.gz

# If Step 1's dnf failed (jump can't reach RHUI), install python3.11 from the
# RPMs carried in the bundle — otherwise the next line (python3.11 -m venv) fails:
sudo rpm -Uvh jump_rpms/*.rpm 2>/dev/null || echo "no jump_rpms (python3.11 already present from Step 1)"

tar xzf sap-automation-qa.tar.gz && tar xzf tools.tar.gz
cd sap-automation-qa

python3.11 -m venv .venv && source .venv/bin/activate
pip install --no-index --find-links=../wheels --upgrade pip
pip install --no-index --find-links=../wheels -r requirements.in

mkdir -p .ansible/collections
# ansible-galaxy resolves the downloaded tarballs relative to the CURRENT directory,
# so install FROM the collections_offline folder (✅ offline dry-run finding —
# running it from here with a relative path fails with "Could not find *.tar.gz"):
COLL_DIR="$PWD/.ansible/collections"
( cd ../collections_offline && ansible-galaxy collection install -r requirements.yml -p "$COLL_DIR" )
export ANSIBLE_COLLECTIONS_PATH="$PWD/.ansible/collections"
export ANSIBLE_HOST_KEY_CHECKING=False
export ANSIBLE_PYTHON_INTERPRETER=$(which python3)
```

`--no-index` forbids pip from trying the internet; `--find-links` points it at the
transferred packages instead.

Then apply the validated framework fixes (required — without them every Linux run
fails, and offline runs abort at the Azure login; details in
[LAB-FINDINGS.md](./LAB-FINDINGS.md)):

```bash
# `bash` prefix avoids a "Permission denied" if the exec bit wasn't preserved
# through the download/transfer (✅ offline dry-run finding):
bash ../tools/apply-framework-fixes.sh .
```

## Step 5 — Python on the SAP servers — ⏭️ NORMALLY SKIP THIS

> ✅ **If you built the bundle with the `ansible-core<2.17` constraint (Step 2, the
> default), SKIP this step entirely and go to Step 6.** Lab-validated: with
> ansible-core 2.16 the checks run against the SAP servers' Python 3.6 as-is —
> **nothing is installed on the SAP servers.** This is the recommended path.

This step is the **fallback only**, needed if a future framework version drops
ansible-core 2.16 support (then Python ≥ 3.7 is required on the SAP servers).

<details><summary>Fallback: install python3.11 on each SAP server</summary>

> ☁️ **Run on: JUMP SERVER** — the `ssh` commands reach *into* each SAP server.

```bash
ssh <user>@<sap-server> 'ls /usr/bin/python3*'          # check what's there first
ssh <user>@<sap-server> 'sudo dnf install -y python3.11' # install if absent
```

Then change the `ansible_python_interpreter` value to `"/usr/bin/python3.11"` on each
host in `hosts.yaml` (Step 6 — the template already carries the line, default
`/usr/bin/python3`). "No internet" does not block the install: the SAP servers
get packages from Red Hat's private channel (RHUI on Azure, or Satellite). If even
that is blocked, carry the RHEL 8 `python3.11` RPMs in the bundle and `sudo rpm
-ivh` them via the jump server. The install is additive — no default Python change,
no service restart, no SAP impact; DEV/QAS first.

</details>

## Step 6 — Describe the SAP system (workspace)

> ☁️ **Run on: JUMP SERVER**, inside the `sap-automation-qa` folder.

The framework does not discover anything by itself. You describe your SAP system in a
small "workspace" folder that holds two YAML files plus the SSH credential.

### 6.1 Create the workspace folder

The folder name is just a label you choose — the framework uses it to locate these
files (you point `vars.yaml` at it in Step 7). A common convention is
`ENV-REGION-VNET-SID` (environment, Azure region, VNet, SAP SID), for example
`PRD-EUS2-SAP01-AMS`. Any name works; pick one and create it:

```bash
mkdir -p WORKSPACES/SYSTEM/PRD-EUS2-SAP01-AMS
cd WORKSPACES/SYSTEM/PRD-EUS2-SAP01-AMS
```

Whatever name you choose here, use the same one for `SYSTEM_CONFIG_NAME` in Step 7.

> ⚠️ **Do not run against the sample workspace that ships with the framework.** The
> upstream clone includes an example folder — `WORKSPACES/SYSTEM/DEV-WEEU-SAP01-X00` —
> populated with placeholder values. Running against it is a common mistake and causes
> confusing failures (see the Key Vault note in 6.3). **Create your own folder as above**
> and leave the sample one untouched.

> **What is a SID?** The SID (System ID) is the unique 3-letter uppercase code that
> identifies an SAP system (e.g. `PRD`, `QAS`); the database has its own DB SID (for
> HANA, often `HDB`). Find the real values from your SAP Basis team, or read them off
> a SAP server:
>
> ```bash
> ssh <user>@<sap-server> 'ls /usr/sap/ | grep -vE "SYS|tmp|hostctrl|hostexec"'
> ```
>
> The examples below use `AMS`/`HDB` — replace with yours.

### 6.2 Create `hosts.yaml` — the SAP servers to check

This file tells the jump server which SAP servers to connect to and how. Servers are
grouped by role: `<SID>_DB` (database), `<SID>_SCS` (central services), `<SID>_APP`
(application servers). One block per server — add or remove blocks to match your
landscape.

Replace the placeholders with your values: the group prefixes (`AMS_` → your SID),
the hostnames, the private IPs, the SSH user, and the Azure VM names. Then paste the
whole block:

```bash
cat > hosts.yaml <<'EOF'
AMS_DB:
  hosts:
    SAPDBHOSTNAME:
      ansible_host: "10.0.0.10"
      ansible_user: "azureadm"
      ansible_connection: "ssh"
      connection_type: "key"
      virtual_host: "SAPDBHOSTNAME"
      become_user: "root"
      os_type: "linux"
      ansible_python_interpreter: "/usr/bin/python3"
      vm_name: "AZURE-VM-NAME"
  vars:
    node_tier: "hana"
AMS_SCS:
  hosts:
    SAPSCSHOSTNAME:
      ansible_host: "10.0.0.11"
      ansible_user: "azureadm"
      ansible_connection: "ssh"
      connection_type: "key"
      virtual_host: "SAPSCSHOSTNAME"
      become_user: "root"
      os_type: "linux"
      ansible_python_interpreter: "/usr/bin/python3"
      vm_name: "AZURE-VM-NAME"
  vars:
    node_tier: "scs"
AMS_APP:
  hosts:
    SAPAPPHOSTNAME:
      ansible_host: "10.0.0.12"
      ansible_user: "azureadm"
      ansible_connection: "ssh"
      connection_type: "key"
      virtual_host: "SAPAPPHOSTNAME"
      become_user: "root"
      os_type: "linux"
      ansible_python_interpreter: "/usr/bin/python3"
      vm_name: "AZURE-VM-NAME"
  vars:
    node_tier: "app"
EOF
```

What each field means:

- `ansible_host` — the server's private IP (reachable from the jump server).
- `ansible_user` — the SSH user; it must be able to `sudo` to root without a password
  (the checks only read configuration).
- `vm_name` — the Azure VM name exactly as shown in the portal (used by the Azure
  checks, when they run).
- Group names must be `<SID>_DB` / `<SID>_SCS` / `<SID>_APP` in uppercase — rename the
  `AMS_` prefixes if your SID differs.

**About `ansible_python_interpreter: "/usr/bin/python3"` (already in the template):**
keep this line. It tells Ansible to use each SAP server's **own** system Python
(`/usr/bin/python3` — Python 3.6 on RHEL 8.10), which is already installed, so
**nothing is installed on the SAP servers** (this is option B). It is also required:
because the framework runs from a virtual environment on the jump server, without this
line Ansible tries to reuse the jump server's venv Python path on the SAP servers —
which does not exist there — and every host fails at "Gathering Facts" with
`/…/.venv/bin/python3: No such file or directory` (see LAB-FINDINGS Issue 9).

Only if you took the Step 5 fallback and installed `python3.11` on the SAP servers,
change the value to `"/usr/bin/python3.11"` under each host.

### 6.3 Create `sap-parameters.yaml` — what the SAP system looks like

```bash
cat > sap-parameters.yaml <<'EOF'
sap_sid: "AMS"                        # your SAP SID
db_sid: "HDB"                         # your database SID
platform: "HANA"                      # HANA / Db2 / ORACLE / SQLSERVER
scs_high_availability: false          # true if ASCS/ERS is clustered
database_high_availability: false     # true if DB uses replication + cluster
database_scale_out: false
scs_instance_number: "00"
ers_instance_number: "01"
db_instance_number: "00"
NFS_provider: "AFS"                   # AFS (Azure Files) or ANF (Azure NetApp Files)
user_assigned_identity_client_id: ""
EOF
```

If HA is `true`, also add `scs_cluster_type`/`database_cluster_type` (`AFA`, `ISCSI`
or `ASD`) — see the upstream
[SETUP guide, section 2.2](https://github.com/Azure/sap-automation-qa/blob/main/docs/SETUP.MD#22-system-configuration-workspaces).

> ⚠️ **Make sure there is no `key_vault_id` / `secret_id` in this file.** The upstream
> sample `sap-parameters.yaml` ships with Key Vault lines pre-filled with *placeholders*
> like `<key-vault-name>` and `<subscription-id>`. The wrapper only checks whether those
> variables are **non-empty** — it does not validate them — so even the untouched
> placeholder text makes it take the Key Vault path: it runs `az login --identity` and
> fails on an offline jump with **`az: command not found`**. The template above simply
> omits them, which is what you want. If you started from the upstream sample instead,
> clear them explicitly:
>
> ```yaml
> key_vault_id: ""
> secret_id: ""
> user_assigned_identity_client_id: ""
> ```
>
> Offline, the SSH key comes from the local file in this workspace (6.4) — never from
> Key Vault.

### 6.4 Credentials — how the jump server authenticates to the SAP servers

The framework connects to each SAP server over SSH, so it needs a credential. **Where
it goes:** into *this* workspace folder — the one you are in
(`WORKSPACES/SYSTEM/<your-name>/`) — as a file named exactly `ssh_key.ppk` (SSH key)
or `password` (password). The framework looks for it there, nowhere else.

```bash
# from inside the workspace folder:
cp /path/to/the/private-key ssh_key.ppk
chmod 600 ssh_key.ppk
```

> If you are using the lab workspace (`LAB-...`), the key is already inside it — you
> have nothing to do in this step.

#### Getting this approved by security

A private key sitting in a folder is a fair thing to push back on. Here is how to make
this acceptable — and what to tell your security team:

- **The trust path already exists.** The jump server is, by definition, the host
  operators already use to SSH into the SAP servers. Whatever key does that already
  lives within the jump server's boundary. The framework reuses that existing path;
  it opens no new network route and the key never leaves the jump.
- **Use a dedicated, least-privilege account and key — not a personal or admin one.**
  Create an SSH key pair used *only* for these checks, tied to a dedicated service
  account on the SAP servers. It can be revoked or rotated on its own without touching
  anyone's real credentials, and its blast radius is limited to read-only inspection.
- **Prefer ssh-agent so no key file rests on disk** — see the exact recipe below.
  The private key stays in memory only and is gone when the agent is cleared. This is
  usually the easiest option to approve.
- **If a key file is used, treat it as ephemeral:** `chmod 600`, keep the workspace on
  a restricted/encrypted path, and delete the file after the run
  (`shred -u ssh_key.ppk`).

> **Note — Azure Key Vault is *not* an option here.** For an internet-connected jump
> server the framework can pull the credential from Key Vault, but the offline
> on-premises jump can reach neither `vault.azure.net` nor an Azure managed identity,
> so that path does not apply to this scenario.

#### ssh-agent recipe (no key file on disk)

The convenience wrapper `scripts/sap_automation_qa.sh` **requires a key file** when
`AUTHENTICATION_TYPE: SSHKEY` — it has no ssh-agent mode. To use an agent instead, you
run the playbook **directly** (same parameters the wrapper builds, minus
`--private-key`), so Ansible falls back to the agent. **No YAML change is needed** —
just don't place `ssh_key.ppk` in the workspace.

Trade-off: you skip the wrapper's niceties (version check, friendly logging). The HTML
report is still generated by the playbook's final play.

**Preferred — agent forwarding (the key never touches the jump server). ✅ Lab-validated.**
Load the key into an agent on the **operator laptop** and connect with `ssh -A`, so the
jump borrows the laptop's agent over the SSH session. Nothing is copied to the jump.

```bash
# 💻 on the OPERATOR LAPTOP:
eval "$(ssh-agent -s)"                 # start an agent (if not already running)
ssh-add /path/to/sap-checks-key        # load the private key into the LAPTOP agent
ssh-add -l                             # confirm it's loaded
ssh -A <user>@<jump-server>            # -A forwards the agent to the jump

# ☁️ now on the JUMP SERVER:
ssh-add -l                             # should list the forwarded key
#   -> then just run the checks (Step 8). With the one-shot setup-and-run.sh, pick
#      option 2 (ssh-agent); it detects the forwarded key and runs the playbook directly.
```

> Do **not** run `eval "$(ssh-agent -s)"` again on the jump when using `-A` — that would
> start a new, empty agent and break the forwarding. Just verify with `ssh-add -l`.

**Alternative — load the key into an agent on the jump** (use only if forwarding isn't
allowed; the key file is then present on the jump until you remove it):

```bash
# ☁️ on the JUMP SERVER, in ~/sap-automation-qa, venv active:
source .venv/bin/activate

# 1. load the dedicated key into an agent (stays in memory only)
eval "$(ssh-agent -s)"
ssh-add /path/to/sap-checks-key      # the private key; prompts once
ssh-add -l                            # confirm it's loaded

# 2. the environment the wrapper would set
export ANSIBLE_COLLECTIONS_PATH="$PWD/.ansible/collections:/opt/ansible/collections"
export ANSIBLE_CONFIG="$PWD/src/ansible.cfg"
export ANSIBLE_MODULE_UTILS="$PWD/src/module_utils"
export ANSIBLE_HOST_KEY_CHECKING=False

# 3. run the playbook directly — NO --private-key -> Ansible uses the agent
#    (replace <name> with your workspace folder; set TEST_TYPE/SYSTEM_CONFIG_NAME
#     in vars.yaml per Step 7 first)
WS="$PWD/WORKSPACES/SYSTEM/<name>"
mkdir -p "$WS/logs"
export ANSIBLE_LOG_PATH="$WS/logs/execution_$(date +%Y%m%d_%H%M%S).log"
ansible-playbook src/playbook_00_configuration_checks.yml \
  -i "$WS/hosts.yaml" \
  -e @vars.yaml -e @"$WS/sap-parameters.yaml" \
  -e "_workspace_directory=$WS"

# 4. when finished, clear the key from memory
ssh-add -D && ssh-agent -k
```

If your security team is fine with a short-lived key **file** instead, keep the simple
`ssh_key.ppk` in the workspace (top of this section) and use the normal Step 8 wrapper
run — just `shred -u` the file afterwards.

Return to the framework root:

```bash
cd ../../..
```

## Step 7 — Configure (and authenticate, if applicable)

> ☁️ **Run on: JUMP SERVER**, inside the `sap-automation-qa` folder.

### 7a. Edit `vars.yaml` — 2 lines

`vars.yaml` already exists in the **root of the `sap-automation-qa` folder** (not in
the workspace) — the framework ships it. Make sure you are there first:

```bash
cd ~/sap-automation-qa      # vars.yaml lives in this directory
ls vars.yaml                # should exist
```

Then change exactly **two lines** and leave the rest:

| Line | Set it to | Why |
|---|---|---|
| `TEST_TYPE:` | `"ConfigurationChecks"` | fixed value — selects the configuration checks |
| `SYSTEM_CONFIG_NAME:` | `"PRD-EUS2-SAP01-AMS"` ⚠️ **REPLACE** with your Step 6 folder name | which workspace to use |

```bash
sed -i 's/^TEST_TYPE:.*/TEST_TYPE: "ConfigurationChecks"/; s/^SYSTEM_CONFIG_NAME:.*/SYSTEM_CONFIG_NAME: "PRD-EUS2-SAP01-AMS"/' vars.yaml
grep -E '^(TEST_TYPE|SYSTEM_CONFIG_NAME)' vars.yaml   # verify — must print your two lines
```

(Prefer an editor? `nano vars.yaml`, change the same two lines, Ctrl+O + Enter,
Ctrl+X.)

> ⚠️ **Do not skip the `TEST_TYPE` line.** The framework ships with
> `TEST_TYPE: "SAPFunctionalTests"` as its factory default, which selects
> `playbook_00_ha_db_functional_tests` — the **high-availability functional tests**.
> Those perform **real failover scenarios** (node takeover, network isolation) and are
> **disruptive**, unlike the configuration checks, which are strictly read-only. Always
> confirm the run header says:
>
> ```
> [INFO] TEST_TYPE: ConfigurationChecks
> [INFO] Using playbook: playbook_00_configuration_checks
> ```
>
> If it says `SAPFunctionalTests` / `playbook_00_ha_db_functional_tests`, stop — the two
> lines above were not applied.

### 7b. Azure authentication — only if the jump server can reach Azure

**Why this step exists.** The framework runs **two kinds of checks**:

- **OS / SAP checks** — the jump server logs into the SAP servers over SSH and reads
  operating-system and SAP configuration. These need only SSH. **No Azure involved.**
- **Azure infrastructure checks** — validate things only Azure knows: the VM SKU, the
  disks, the load balancer. To read those, the framework calls the **Azure management
  APIs (ARM)**, and that call has to be **authenticated to Azure**. This step is what
  provides that authentication.

So 7b exists **only to enable the Azure-infrastructure part** of the report, and it
only makes sense if the jump server can actually reach Azure. Use the decision test
from earlier in this guide to decide which branch applies:

**If the endpoints were BLOCKED (expected in the offline scenario): nothing to do.**
Skip this step. The fix script from Step 4 already makes the framework tolerate the
missing Azure login: **all OS/SAP checks still run**, and the Azure infrastructure
checks simply show up as errors in the report — which is expected and fine.

**If both endpoints were OK (jump has a route to Azure):** someone with Azure access creates a read-only
service principal, then the jump server logs in with it (twice — the framework's
Azure collectors run as root):

```bash
# on a machine with Azure access:
az ad sp create-for-rbac --name sap-qa-checks --role Reader \
  --scopes /subscriptions/<SUB_ID>/resourceGroups/<SAP_RG>
# note appId, password, tenant from the output — then on the jump server:
az login --service-principal -u <APP_ID> -p <PASSWORD> --tenant <TENANT_ID>
az account set --subscription <SUB_ID>
sudo az login --service-principal -u <APP_ID> -p <PASSWORD> --tenant <TENANT_ID>
sudo az account set --subscription <SUB_ID>
```

(This branch also requires the `azure-cli` RPM — downloadable on the laptop from
`packages.microsoft.com/yumrepos/azure-cli/` and transferred with the bundle.)

> ⚠️ **The `az` binary alone does NOT enable the Azure checks.** Adding the `azure-cli`
> RPM to the bundle is necessary but not sufficient. Those checks read disk/VM
> properties from the Azure management API, so `az` must be able to **reach Azure over
> the network** (`management.azure.com` + `login.microsoftonline.com`) **and
> authenticate** (the service principal above). On a jump with no route to Azure,
> installing `az` only changes the error from `az: command not found` to a login/connect
> failure — the checks are still `N/A`. In other words, this needs all three together:
> **(1) a network path to Azure, (2) a service principal, (3) the `az` binary.** If the
> jump must stay fully air-gapped, `az` cannot help — instead, have someone with Azure
> portal/Cloud Shell access collect the disk data separately (see the note in Step 9).

## Step 8 — Run

> ☁️ **Run on: JUMP SERVER.**

Run these three commands. Runs **all** check families against every server in
`hosts.yaml`. Takes several minutes; read-only, nothing on SAP changes:

```bash
cd ~/sap-automation-qa            # the framework folder
source .venv/bin/activate         # activate the venv — prompt must show (.venv)
./scripts/sap_automation_qa.sh    # run all checks
```

**Optional — `--extra-vars`:** the script normally reads its settings from
`vars.yaml`; `--extra-vars` passes one extra setting for a single run without
editing any file. Useful to restrict the run to one check family:

```bash
./scripts/sap_automation_qa.sh --extra-vars='{"configuration_test_type":"Database"}'
./scripts/sap_automation_qa.sh --extra-vars='{"configuration_test_type":"CentralServiceInstances"}'
./scripts/sap_automation_qa.sh --extra-vars='{"configuration_test_type":"ApplicationInstances"}'
```

Accepted values: `all` (default), `Database`, `CentralServiceInstances`,
`ApplicationInstances`, `WebDispatcherInstances`. For the report you share with
Microsoft, run without parameters (= `all`).

Note: in the fully offline case, a telemetry task at the very end may report a
failure — that happens after the report is already written; ignore it.

## Step 9 — Collect the report

> 💻 **Run on: OPERATOR LAPTOP.**

```bash
scp <user>@<jump-server>:"~/sap-automation-qa/WORKSPACES/SYSTEM/<NAME>/quality_assurance/CONFIG_*.html" .
```

Open the HTML in a browser; share with Microsoft for review and recommendations.

### ⚠️ Reading the report in the offline scenario — this is expected, not a bug

Because the jump server is **offline and cannot reach Azure** (Step 7b was skipped),
the report is split in two, and **this is normal**:

- ✅ **OS / SAP checks — real results.** Everything read over SSH from the SAP servers
  (operating-system settings, SAP configuration, HA/cluster, filesystems, kernel
  parameters) ran normally and shows **actual pass/fail results**. This is the bulk of
  the assessment and it is complete.
- ⚠️ **Azure infrastructure checks — shown as errors/blank.** Everything that needs the
  Azure management APIs (VM SKU, disk layout, load balancer, accelerated networking)
  could not run, because there is no Azure login in an offline jump. These rows appear
  as errors or empty. **This does not mean the report failed** — it means those specific
  checks were out of scope for an offline run. In the report these show up either as
  `INFO — "Azure CLI not available"` or as `FAILED` with `az: command not found`.

  **Important — some HANA storage checks are in this Azure group.** The HANA
  disk-performance and storage-layout checks (stripe size, disk IOPS/MBPS, disk type,
  performance tier, supported storage type — `DB-HANA-00xx`) are Azure-collector checks:
  they read disk metadata from Azure, so **offline they come back `N/A` / `FAILED` too.**
  These are genuinely useful for a HANA sizing review, so if the customer needs them
  they must be run with Azure access (Step 7b: service principal + `management.azure.com`)
  or validated separately by someone with Azure portal access. Their absence here is the
  offline limitation, not a storage defect on the server.

**Tell the customer this up front** so no one reads the Azure-check errors as a broken
report. If Azure-infrastructure coverage is actually required, it needs the network
path + service principal from Step 7b (or the checks can be validated separately by
someone with Azure portal access) — it is not a defect in the run.

### Where the value is — and the scope note to hand over with the report

**The offline report is the OS/SAP half of a two-part assessment, and that half is
complete.** Its value: it validates everything that most commonly causes SAP-on-Azure
support issues — kernel and OS parameters, SAP-recommended tuning (saptune/tuned),
package versions, filesystem/mount layout, OS-level networking, and HA/cluster
configuration — all read directly from the servers. This is the core of a configuration
review and stands on its own.

**What it does not cover, because the jump is fully offline:** the Azure-infrastructure
items — VM SKU, disk performance tier / IOPS / MBPS, accelerated networking, and HA
placement (availability set / PPG / zones). These require Azure access. Most of them can
be confirmed in minutes from the Azure portal, so the offline report plus a short portal
cross-check equals a full picture.

**So the second half of the assessment must be done one of two ways:**

1. **By someone with Azure access** — read the VM SKU, disk SKUs/tiers, accelerated
   networking and zone placement from the Azure portal or Cloud Shell, and validate them
   against the SAP-on-Azure guidance; **or**
2. **By enabling Azure access on the jump server** — the Step 7b path: a network route to
   `management.azure.com` + `login.microsoftonline.com`, a read-only service principal,
   and the `az` binary in the bundle. Then re-run and the Azure checks populate for real.

**Scope note to paste into the deliverable / cover email:**

> This assessment was run from a fully offline (air-gapped) jump server. The **OS and SAP
> configuration checks are complete and reflect the actual state of the servers.** The
> **Azure infrastructure checks** (VM SKU, disk performance tier/IOPS/MBPS, accelerated
> networking, HA placement) **could not run offline** and appear as `N/A` / `INFO` /
> `FAILED` in the report — this is a scope limitation, **not** a configuration defect.
> These items will be validated separately by someone with Azure portal access, or by
> enabling Azure access on the jump server (network route + read-only service principal)
> and re-running.

## Troubleshooting — errors seen in the field

All of these come from real runs. Each one is caused by skipping a step or by starting
from the framework's upstream sample files instead of the templates in this guide.

### ⚠️ First: how to tell a run actually worked

A run can finish with `return code: 0` **and produce an HTML report that is completely
empty.** Before trusting any report, check all three:

1. The `PLAY RECAP` lists **your SAP hosts**, not just `localhost`.
2. The log does **not** say `skipping: no hosts matched`.
3. The report header shows **`Total Checks:` greater than 0** and a populated `Hostnames:`.

### `no hosts matched` → empty report (`Total Checks: 0`)

```
[WARNING]: Could not match supplied host pattern, ignoring: YRMJ_DB
[WARNING]: Could not match supplied host pattern, ignoring: YRMJ_SCS
PLAY [Host tasks] ****  skipping: no hosts matched
"Configuration checks completed. Check types executed: []"
PLAY RECAP: localhost : ok=17 ...
```

**Cause:** the group names in `hosts.yaml` do not match what the playbook derives from
`sap_sid` in `sap-parameters.yaml`. The playbook looks for `<sap_sid>_DB`,
`<sap_sid>_SCS`, `<sap_sid>_APP`, etc. If `sap_sid: "YRMJ"` but the inventory groups are
named anything else (different SID, lowercase, or hosts listed without groups), **nothing
matches and zero checks run** — yet the playbook still exits 0 and writes a report.

**Fix:** make the group names in `hosts.yaml` exactly `<sap_sid>_DB` / `<sap_sid>_SCS` /
`<sap_sid>_APP` …, **uppercase**, using the *same* SID as `sap_sid` in
`sap-parameters.yaml` (Step 6.2 / 6.3). Then re-run and confirm the three checks above.

### `az: command not found`

```
[INFO] Key Vault ID and Secret ID are set. Retrieving SSH key from Key Vault.
[INFO] Authenticating using MSI...
./scripts/sap_automation_qa.sh: line 429: az: command not found
```

**Cause:** `sap-parameters.yaml` contains `key_vault_id` / `secret_id`. The upstream sample
ships them pre-filled with *placeholders* (`<key-vault-name>`, `<subscription-id>`). The
wrapper only checks that they are **non-empty** — it does not validate them — so the
placeholder text sends it down the Key Vault path, which needs `az` + a managed identity.
Neither exists on an offline jump.

**Fix:** clear them (Step 6.3) and use the local key file in the workspace (Step 6.4).

### The run uses `playbook_00_ha_db_functional_tests` (⚠️ disruptive)

```
[INFO] TEST_TYPE: SAPFunctionalTests
[INFO] Using playbook: playbook_00_ha_db_functional_tests
```

**Cause:** `vars.yaml` is still at the framework's factory default. That playbook performs
**real HA failover scenarios** — it is not the read-only configuration check.

**Fix:** Step 7a. Confirm the header prints `TEST_TYPE: ConfigurationChecks` and
`Using playbook: playbook_00_configuration_checks` before letting it run. Passing
`--extra-vars '{"configuration_test_type":"Database"}'` does **not** change the test type.

### `sudo: a password is required` on `localhost`

```
TASK [Init: Install Required Python Azure Packages]
fatal: [localhost]: FAILED! => {"module_stderr": "sudo: a password is required\nSorry.\n"}
```

**Cause:** this task runs on the **jump server itself** (`localhost`), escalating to root to
pip-install Azure SDK packages. It fails if the operator account has no passwordless sudo —
common where privilege elevation is centrally controlled (BoKS, CyberArk, Centrify). Offline
it could not succeed anyway: there is no path to PyPI and no Azure to talk to.

**Fix:** apply the validated fixes from **Step 4** (`apply-framework-fixes.sh`), which make
these localhost init tasks non-fatal so the run continues into the actual checks. Granting
passwordless sudo on the jump is *not* required.

### `found a duplicate dict key (become_user)`

```
[WARNING]: While constructing a mapping from .../hosts.yaml, line 23, column 7,
found a duplicate dict key (become_user). Using last defined value only.
```

**Cause:** the same key appears twice under a host in `hosts.yaml`, usually after hand-editing.
YAML keeps only the last one, which may not be the value you intended.

**Fix:** open `hosts.yaml` at the reported line and remove the duplicate.

### Privilege escalation in PAM-controlled environments (BoKS / CyberArk / Centrify)

Where `sudo` to root is brokered by a PAM product, Ansible's default `sudo` escalation may be
blocked. Ansible has no plugin for these products, but the escalation executable can be
overridden per host in `hosts.yaml` — for example, for BoKS `suexec`:

```yaml
      ansible_become: true
      ansible_become_method: su
      ansible_become_user: root
      ansible_become_exe: "suexec su"
```

Validate on a single host before running the full checks:

```bash
ansible <GROUP> -i WORKSPACES/SYSTEM/<name>/hosts.yaml -m command -a 'id' -b
```

`uid=0(root)` means escalation works. See
[Ansible — privilege escalation](https://docs.ansible.com/projects/ansible/latest/playbook_guide/playbooks_privilege_escalation.html).
