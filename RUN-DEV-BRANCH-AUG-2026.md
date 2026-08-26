# Running the `development-august-2026` branch (offline) — temporary procedure

> **Status: temporary.** This procedure exists because the STAF engineering team asked us to
> validate the latest development branch (`development-august-2026`) ahead of the next tagged
> release. Once that release is published, use [QUICKSTART.md](./QUICKSTART.md) with the
> released version and retire this document.
>
> **Scope note:** the configuration checks are read-only against the SAP servers. Run against
> non-production first when possible, and only run a development branch with the STAF team's
> go-ahead.

This is a delta on top of the standard procedure: everything about the environment
(air-gapped jump, offline install, workspace) stays the same as
[QUICKSTART.md](./QUICKSTART.md). What changes is **where the framework code comes from**
(a branch ZIP instead of the release) — and, good news, this branch's `requirements.in`
is **identical to v1.1.3**, so the existing offline bundle (wheels/collections/RPMs)
works as-is. No rebuild needed.

---

## Part 1 — Operator laptop (browser + terminal, has internet)

1. Open the framework repo: <https://github.com/Azure/sap-automation-qa>
2. On the top-left, click the **branch selector** (it shows `main` by default) and switch to
   the branch **`development-august-2026`**.
3. Click the green **Code** button and choose **Download ZIP**. You'll get
   `sap-automation-qa-development-august-2026.zip`.
4. Copy it to the jump server:

```bash
scp sap-automation-qa-development-august-2026.zip <user>@<jump-server>:~/
```

> The bundle pieces already on the jump (`wheels/`, `collections_offline/`, `jump_rpms/`,
> `tools/`) are reused — do not delete them.

---

## Part 2 — Jump server (offline)

```bash
cd ~
unzip sap-automation-qa-development-august-2026.zip
cd sap-automation-qa-development-august-2026

# Reuse the supported runtime already in place (Python 3.11 / ansible-core 2.16.19).
# This branch's requirements.in is identical to v1.1.3, so the existing wheels
# folder works as-is (no new downloads needed):
python3.11 -m venv .venv && source .venv/bin/activate
pip install --no-index --find-links=../wheels --upgrade pip
pip install --no-index --find-links=../wheels -r requirements.in
mkdir -p .ansible/collections
COLL_DIR="$PWD/.ansible/collections"
( cd ../collections_offline && ansible-galaxy collection install -r requirements.yml -p "$COLL_DIR" )
ansible --version    # must show ansible-core 2.16.19 / Python 3.11

# Apply the offline fixes and WATCH the output lines:
#   [ok]   = patch applied
#   [skip] = already fixed in this branch (good news, nothing to do)
#   [warn] = the code changed in this dev branch and the patch didn't apply.
#            STOP here and share the output before running.
bash ../tools/apply-framework-fixes.sh .

# Reuse the existing, already-correct workspace (do NOT rebuild it):
OLD=~/roopesh/sap-config-check/sap-automation-qa    # adjust to the last working clone path
cp -r "$OLD/WORKSPACES/SYSTEM/PRD-WUS3-SAP-RMJ" WORKSPACES/SYSTEM/
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
```

If the ASCS/ERS is **not** clustered, leave the parameters as they are.

> Note: the database-tier HA configuration checks are currently HANA-only in the framework;
> for a DB2 system (HADR) they do not run regardless of these flags.

### Run and verify

```bash
./scripts/sap_automation_qa.sh -vv 2>&1 | tee run-dev-aug2026.log

# Verify the report populated:
ls -lh WORKSPACES/SYSTEM/<workspace>/quality_assurance/CONFIG_*.html
```

Open the newest `CONFIG_*.html` — it should show a populated report (Total Checks > 0).
Keep `run-dev-aug2026.log` and the HTML to share back with the STAF engineering team.

---

## How to tell this run actually worked

- `ansible --version` showed **ansible-core 2.16.19 / Python 3.11** before the run.
- The wrapper log ends with **`return code: 0`** and `failed=0` for every SAP host.
- The HTML report shows **Total Checks > 0** with real statuses (not an empty summary).
- If `scs_high_availability: true` was set, the report includes the **SCS/ERS HA
  Configuration** section (corosync/quorum/fencing values).
