# Lab validation findings — SAP configuration checks

**Date:** 2026-07-13 · **Framework:** Azure/sap-automation-qa v1.1.2 · **Result:** ✅ end-to-end success

Full pipeline validated in a hub/spoke ALZ lab (jump server in hub, 2 simulated SAP VMs
in spoke): inventory → SSH → IMDS → ARM checks → HTML report
(`CONFIG_X00_HANA_*.html`, return code 0, all 6 check families executed).

Three framework/environment issues were found and fixed along the way. **Any Linux
deployment will hit issues 2 (always) and 1 (on SLES/older RHEL)** — apply the fixes
below after cloning the framework, or run [apply-framework-fixes.sh](./apply-framework-fixes.sh).

---

## Issue 1 — Target VMs with Python 3.6 (SLES 15 default)

**Symptom:** modules misbehave on target hosts; IMDS `uri` result registered without
a `json` attribute; confusing downstream failures.

**Root cause:** the framework installs latest `ansible-core` (≥2.17), which requires
Python ≥3.7 **on target machines**. SLES 15 (and RHEL 8) default `python3` is 3.6.

**Fix (option A):** point Ansible at a newer Python — add to every host in
`hosts.yaml`:

```yaml
ansible_python_interpreter: "/usr/bin/python3.11"
```

(Install first if absent: `sudo zypper install -y python311` / `sudo dnf install -y python3.11`.)

**Production-safety note:** the install is additive (parallel interpreter, no
default change, no library replaced, no service restart, rollback =
`dnf remove python3.11`). Still: change window + non-prod SAP system first.

**Fix (option B — zero changes on SAP servers) ✅ VALIDATED 2026-07-13:** pin the
bundle to `ansible-core<2.17`. Version 2.16 still supports Python 3.6 targets, so
**nothing needs to be installed on the SAP servers**. Constraint at bundle build time:

```bash
echo 'ansible-core<2.17' > constraints.txt
python3 -m pip download -r sap-automation-qa/requirements.in -c constraints.txt -d wheels/ ...
```

**Lab evidence:** ansible-core **2.16.19** on the jump ran the full checks against two
**RHEL 8.10 / Python 3.6** SAP sims (no `ansible_python_interpreter` set) with
`failed=0` on every host, and generated the HTML report. This is the recommended
approach for the customer: it avoids touching the production SAP servers entirely.
Option A (install python3.11 on the SAP servers) remains the fallback if a future
framework version drops ansible-core 2.16 compatibility.

## Issue 2 — Skipped Windows IMDS task clobbers the Linux result (upstream bug)

**Symptom:** every Linux run fails at `"VM Information - Prepare system context
information"` with `'dict object' has no attribute 'json'` (hidden behind `no_log`).

**Root cause:** in `src/roles/configuration_checks/tasks/main.yml`, the Windows IMDS
task (`ansible.windows.win_uri`, `when: ansible_os_family == "Windows"`) registers into
the **same variable** (`compute_metadata`) as the Linux task before it. In Ansible, a
skipped task still overwrites its registered variable — so on Linux hosts the valid
IMDS response is replaced by a skip record (`['changed', 'skipped', 'skip_reason',
'false_condition']`).

**Fix:** rename the Windows task's `register:` (and its `until:`) to
`compute_metadata_win`. See the patch script.

**Status:** should be reported upstream to
[Azure/sap-automation-qa](https://github.com/Azure/sap-automation-qa/issues).

## Issue 3 — Linux IMDS task missing `return_content` (defensive)

The Linux IMDS `uri` task doesn't set `return_content: true` (the Windows variant
does). On newer ansible-core this can leave the response body unparsed. The patch adds
it — harmless on older versions, protective on newer ones.

## Issue 4 — Azure-based checks fail with "Please run 'az login'"

**Symptom:** the HTML report shows every Azure collector check as
`ERROR: Please run 'az login' to setup account`, even though `az login --identity`
succeeded on the jump server.

**Root cause:** the framework runs Azure collectors with `become: true` (as **root**),
and Azure CLI sessions are per-user (`~/.azure`). Logging in as the regular user does
not authenticate root.

**Fix:** log in as root too, before running the checks:

```bash
sudo az login --identity && sudo az account set --subscription <sub>
```

## Issue 5 — On-premises jump server: run aborts at Azure login (scenario adaptation)

**Context:** the customer's jump server is **on-premises** (RHEL 9, no internet, no
Azure endpoints), connected to the SAP VNet via ExpressRoute private peering.

**Symptom (anticipated):** the playbook's first localhost tasks run
`az login --identity` — which requires an Azure VM with a managed identity — and a
pip bootstrap that contacts PyPI. Offline/on-prem, both fail and abort the run
before any SAP check executes.

**Fix:** `apply-framework-fixes.sh` now makes both tasks non-fatal
(`ignore_errors`). Result: all OS/SAP-level checks run and the report is generated;
Azure infrastructure checks appear as errors (equivalent to what we observed in the
lab report before the root `az login` — the pipeline is proven to complete in that
state). If Azure coverage is required, the network team must allow
`login.microsoftonline.com` + `management.azure.com` and a **service principal**
(not managed identity) is used — see QUICKSTART Step 6b.

**Status:** ✅ VALIDATED 2026-07-13. A jump server **without any managed identity**
ran the full playbook: the `az login` task failed and was made non-fatal by the fix
(`localhost: rescued=1 ignored=1`), all OS/SAP checks ran (`failed=0`), and the HTML
report was generated — with no Azure authentication at all.

## Issue 7 — `pip install` blocked on the download laptop (PEP 668)

**Symptom (laptop dry-run):** on a modern Ubuntu/Debian laptop (Python 3.11+),
`pip install --user ansible-core` fails with `externally-managed-environment`, and
`ansible-galaxy` is then "command not found".

**Root cause:** PEP 668 — recent Debian/Ubuntu mark the system Python as externally
managed and block `pip install` into it.

**Fix:** build the bundle inside a local virtual environment on the laptop
(`python3 -m venv .buildenv && source .buildenv/bin/activate`), then `pip install
ansible-core` there. QUICKSTART Step 2 now starts with this venv. (`pip download` for
the wheels is unaffected — it only downloads, doesn't install.)

## Issue 6 — `git` missing on the jump server (RHEL 9)

**Symptom:** the offline install / framework clone fails with `git: command not
found`. RHEL 9 does not ship git by default.

**Fix:** include `git` in the jump-server prerequisites (QUICKSTART Step 1). If the
jump can't reach the Red Hat channel, add the `git` RPMs to the bundle alongside
`python3.11` (Step 2).

---

## Debugging technique worth remembering

The framework hides most errors behind `no_log: true`. To see a real error, flip the
specific task temporarily and **revert afterwards** (contexts may contain sensitive data):

```bash
sed -i '/<task name fragment>/,/ansible.builtin.set_fact/ s/no_log:.*true/no_log: false/' <file>
```

A `debug` task probing each Jinja expression of a failing `set_fact` pinpoints the
guilty variable in one run.

## Lab cost control

```bash
for vm in "rg-sapqa-lab-mgmt vm-sapqa-jump01 Connectivity" "rg-sapqa-lab-sap vm-sapdb01 Migrate" "rg-sapqa-lab-sap vm-sapascs01 Migrate"; do
  set -- $vm; az vm deallocate -g $1 -n $2 --subscription $3 --no-wait
done
```
