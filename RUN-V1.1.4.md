# Running release v1.1.4 (offline)

> **Status: current.** STAF **v1.1.4** was released by the engineering team on 2026-09-04
> (available on `main` and as the tagged release). This is the procedure for the next execution.
>
> **Why v1.1.4 matters for this engagement** (per the STAF engineering team):
>
> - **DB-Db2-0002 (Linux installation & system language)** now obtains the Db2 instance user's
>   locale reliably and reports `LANG_NOT_SET` explicitly — this is the check that returned
>   "ERROR: Command failed" in the previous run.
> - **Azure Shared Disk (ASD) fencing** is now supported in check applicability — checks
>   previously skipped for ASD-based deployments can now run.

This is a delta on top of the standard procedure: everything about the environment
(air-gapped jump, offline install, workspace) stays the same as
[QUICKSTART.md](./QUICKSTART.md). What changes is the framework version.

**Verified against the v1.1.4 source (2026-09-04):**

| Item | Result |
|---|---|
| `requirements.in` | **Identical to v1.1.3** (`ansible-core==2.16.19`) — the existing `wheels/` folder works as-is, no rebuild |
| `collections/requirements.yml` | **Same seven collections, same versions** — the existing `collections_offline/` works as-is |
| Offline tolerances | **Still required** — v1.1.4 does not change the `az login` or per-disk `az disk show` paths; `apply-framework-fixes.sh` still applies cleanly |
| HA check gating | Unchanged — SCS/ERS HA checks still require `scs_high_availability: true`; DB-tier HA config checks remain HANA-only |

---

## Part 1 — Operator laptop (browser + terminal, has internet)

1. Download the **v1.1.4 release ZIP** — either from the repo's **Releases** page
   (<https://github.com/Azure/sap-automation-qa/releases>) or directly:

   <https://github.com/Azure/sap-automation-qa/archive/refs/tags/1.1.4.zip>

   You'll get `sap-automation-qa-1.1.4.zip`.
2. Copy it to the jump server:

```bash
scp sap-automation-qa-1.1.4.zip <user>@<jump-server>:~/
```

> The bundle pieces already on the jump (`wheels/`, `collections_offline/`, `jump_rpms/`,
> `tools/`) are reused — do not delete them.

---

## Part 2 — Jump server (offline)

```bash
cd ~
unzip sap-automation-qa-1.1.4.zip
cd sap-automation-qa-1.1.4

# CHECKPOINT 1 - the bundle pieces must be reachable from here. Extract the ZIP
# NEXT TO the existing wheels/ and collections_offline/ folders (same parent
# directory, same OS user as the previous working setup). If this ls fails or
# pip later prints "Location '../wheels' is ignored", the path is wrong - stop
# and fix it (or use absolute paths in --find-links):
ls ../wheels | grep -i ansible_core     # must show ansible_core-2.16.19

# Reuse the supported runtime (Python 3.11 / ansible-core 2.16.19). v1.1.4's
# requirements.in is identical to v1.1.3, so the existing wheels folder works
# as-is (no new downloads needed).
# Remove any pre-existing .venv first: creating a venv on top of an existing one
# does NOT convert it to a new interpreter, and the bundle's compiled wheels are
# cp311 - they will NOT install on a Python 3.12 venv ("No matching distribution
# found" on the first compiled package, e.g. black):
rm -rf .venv
python3.11 -m venv .venv && source .venv/bin/activate
python -V        # CHECKPOINT 2: must print Python 3.11.x - if it shows 3.12, stop
pip install --no-index --find-links=../wheels --upgrade pip
pip install --no-index --find-links=../wheels -r requirements.in
mkdir -p .ansible/collections
COLL_DIR="$PWD/.ansible/collections"
( cd ../collections_offline && ansible-galaxy collection install -r requirements.yml -p "$COLL_DIR" )
ansible --version    # must show ansible-core 2.16.19 / Python 3.11

# Apply the offline fixes and WATCH the output lines:
#   [ok]   = patch applied (expected for the Azure-login and disk-collection tolerances)
#   [skip] = already fixed upstream (expected for the IMDS fix, which landed in 1.1.3)
#   [warn] = the code changed and the patch didn't apply. STOP here and share the
#            output before running.
bash ../tools/apply-framework-fixes.sh .

# Reuse the existing, already-correct workspace (do NOT rebuild it):
OLD=<path-to-your-previous-clone>/sap-automation-qa    # the clone used in the last working run
cp -r "$OLD/WORKSPACES/SYSTEM/<workspace>" WORKSPACES/SYSTEM/
cp "$OLD/vars.yaml" ./vars.yaml
```

### Before running — HA coverage question

Is the **ASCS/ERS of this SID a pacemaker (HA) cluster**? If **yes**, enable the HA
configuration checks in the workspace so this run also collects the **corosync token /
quorum / fencing** values (they were **not** collected in previous runs because this flag
was unset). In `WORKSPACES/SYSTEM/<workspace>/sap-parameters.yaml` set:

```yaml
scs_high_availability: true
scs_cluster_type: "AFA"     # or "ISCSI" / "ASD", per the actual fencing setup
                             # (ASD is newly supported in v1.1.4 check applicability)
```

If the ASCS/ERS is **not** clustered, leave the parameters as they are.

> Note: the database-tier HA configuration checks are currently HANA-only in the framework;
> for a DB2 system (HADR) they do not run regardless of these flags.

### Run and verify

```bash
./scripts/sap_automation_qa.sh -vv 2>&1 | tee run-v114.log

# Verify the report populated:
ls -lh WORKSPACES/SYSTEM/<workspace>/quality_assurance/CONFIG_*.html
```

Open the newest `CONFIG_*.html` — it should show a populated report (Total Checks > 0).
Keep `run-v114.log` and the HTML to share back with the STAF engineering team.

---

## How to tell this run actually worked

- `ansible --version` showed **ansible-core 2.16.19 / Python 3.11** before the run.
- The wrapper log ends with **`return code: 0`** and `failed=0` for every SAP host.
- The HTML report shows **Total Checks > 0** with real statuses (not an empty summary).
- **DB-Db2-0002 (Linux installation & system language)** now shows a real value (or
  `LANG_NOT_SET`) instead of "ERROR: Command failed".
- If `scs_high_availability: true` was set, the report includes the **SCS/ERS HA
  Configuration** section (corosync/quorum/fencing values).
