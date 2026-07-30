# Running the checks with read-only Azure access (the flexible option)

[QUICKSTART.md](./QUICKSTART.md) covers the **fully air-gapped** scenario, where the jump
server has no path to Azure at all. That path works, but it has a hard limit: the
**Azure-infrastructure checks** (VM SKU support, managed-disk performance tier / IOPS /
MBps, storage type, and HA / load-balancer configuration) come back **N/A**, because that
data only exists in the Azure control plane.

This document describes the **flexible option**: keep the jump server locked down for
everything *except* a **narrow, read-only, allow-listed** path to the Azure management
APIs. With that in place the framework runs **exactly as designed** — you get the complete
report, including the infrastructure checks, **with no modification to the framework**.

> **TL;DR** — Allow the jump to reach two Azure endpoints over HTTPS, give it a
> **read-only (Reader)** identity, sign in with `az login` before the run. Nothing on the
> SAP servers changes. Everything the framework does against Azure is **read-only**.

---

## 1. Why this is the shortest path to a complete report

The framework is Azure-native. On every run it reads live facts from the Azure control
plane to evaluate whether the deployment matches Microsoft's SAP-on-Azure reference
configuration. Offline, those calls have nothing to talk to, so the corresponding checks
are skipped. The moment the jump can reach the Azure management API with a read-only
identity, those same checks populate — no forks, no patches, no maintenance burden.

**What you gain by opening the path** (these are the checks that are N/A when fully
offline):

| Area | Examples of what gets evaluated |
|---|---|
| Compute | VM SKU is supported for the role + database; vCPU/memory expectations |
| Managed disks | Performance tier, provisioned IOPS / MBps, disk SKU vs. the SAP requirement |
| Storage | ANF service level / throughput, Azure Files (AFS) tier, storage type support |
| High availability | Load-balancer configuration, HA placement / zones |

Everything the framework already collects offline (OS, kernel, packages, SAP, and DB2
parameters) keeps working the same way.

---

## 2. What the framework actually calls (scope of access)

You are **not** opening the jump to the internet. You are allow-listing **two endpoints**,
both HTTPS (443), both **read-only** in how the framework uses them:

| Purpose | Endpoint | Azure service tag | Used for |
|---|---|---|---|
| Sign-in (Azure AD) | `login.microsoftonline.com` | `AzureActiveDirectory` | `az login` token |
| Management (ARM) | `management.azure.com` | `AzureResourceManager` | `az disk show`, `az netappfiles …`, `az storage account show`, `az storage share-rm list` |

Two things that **do not** need any egress:

- **Instance metadata (IMDS)** — `169.254.169.254`. This is a link-local address served
  *on each SAP VM itself*; it works whether or not the VM has internet. The framework reads
  VM name / size / resource group / subscription from it.
- **Azure Key Vault** (`*.vault.azure.net`) — only relevant if you choose to store the SSH
  key in Key Vault. It is **not required**; a local SSH key file works and keeps the path
  smaller. Allow-list `AzureKeyVault` only if you decide to use it.

> Every ARM call the framework makes is a **read / list / show** operation. The Reader role
> below cannot change, create, or delete anything in your environment.

---

## 3. The three things to arrange (and where each one is done)

| # | What | Where it's done | Who |
|---|---|---|---|
| 1 | **Network egress** from the jump to ARM + Azure AD (443) | Firewall / ExpressRoute / proxy | Network team |
| 2 | **A read-only identity** (Reader) scoped to the SAP subscription | Azure AD + subscription IAM | Subscription Owner |
| 3 | **Azure CLI on the jump** + `az login` before the run | The jump server | Operator |

### 3.1 Network egress

Allow **outbound HTTPS (443)** from the jump to the two endpoints in section 2. Pick
whatever fits your network model — you only need one of these:

- **ExpressRoute + firewall allow-list** to `management.azure.com` and
  `login.microsoftonline.com` (or the `AzureResourceManager` and `AzureActiveDirectory`
  **service tags**, which is the cleaner, self-maintaining option on Azure Firewall).
- **Outbound HTTPS proxy.** If the jump reaches Azure through a proxy, export the proxy on
  the jump before running (the Azure CLI honours these):

  ```bash
  export HTTPS_PROXY=http://<proxy-host>:<port>
  export HTTP_PROXY=http://<proxy-host>:<port>
  export NO_PROXY=169.254.169.254,localhost,127.0.0.1
  ```

  Keeping `169.254.169.254` in `NO_PROXY` ensures IMDS is never sent to the proxy.

Nothing has to be opened *to* the jump, and no inbound rules change. This is egress-only,
to two well-known Microsoft endpoints.

### 3.2 A read-only identity (Reader)

The jump authenticates to Azure as an identity that has **Reader** on the SAP
subscription (or, if you prefer tighter scope, Reader on the resource groups that hold the
SAP VMs, their managed disks, and the ANF / storage accounts).

- **On-premises jump (this customer's case): use a service principal.** Managed identity
  only exists for VMs running *in* Azure, so an on-prem jump can't use it.

  ```bash
  # Run by a subscription Owner, once:
  az ad sp create-for-rbac \
    --name "sp-sap-config-checks-ro" \
    --role "Reader" \
    --scopes "/subscriptions/<SAP_SUBSCRIPTION_ID>"
  # Returns appId (client id), password (secret), and tenant.
  ```

  Prefer a **certificate** or a **short-lived secret**, and remove the assignment after the
  assessment. Reader is read-only by definition.

- **If the jump were an Azure VM instead:** assign a **user-assigned managed identity** with
  Reader, and the framework's native `az login --identity` path works with no secret at all.

### 3.3 Azure CLI on the jump + sign in

1. Install the Azure CLI on the jump (offline installs are possible via the RPM package or
   the bundled installer if the jump can't reach `aka.ms`).
2. Sign in **before** running the framework, so the collectors inherit a valid session:

   ```bash
   az login --service-principal \
     -u <APP_ID> \
     -p <SECRET_OR_CERT_PATH> \
     --tenant <TENANT_ID>

   az account set --subscription <SAP_SUBSCRIPTION_ID>
   az account show          # confirm the right subscription is active
   ```

The framework's data collectors (`az disk show`, `az netappfiles …`, `az storage …`) reuse
this active `az` session automatically.

---

## 4. Framework configuration (what changes, and where)

Almost nothing changes versus the offline run. The subscription and resource group are read
per-host from IMDS, so you do **not** hard-code them.

In your workspace parameters file
(`WORKSPACES/SYSTEM/<your-workspace>/sap-parameters.yaml`):

| Setting | Value | Note |
|---|---|---|
| `sap_sid`, `db_sid`, `platform` | your values (e.g. `YRMJ`, `RMJYDB`, `DB2`) | same as the offline run |
| `NFS_provider` | `ANF` or `AFS` (as applicable) | enables the storage collector |
| `ANF_account_rg`, `ANF_account_name` | your ANF account details | required for the ANF checks to run |
| `key_vault_id`, `secret_id` | **leave empty** | use a local SSH key file; Key Vault is optional (section 2) |
| `user_assigned_identity_client_id` | empty / `00000000-…-0000` | leave unset when using a pre-established `az login` (service principal) |

Keep the validated framework patches from
[`apply-framework-fixes.sh`](./apply-framework-fixes.sh). They stay compatible and useful:
the init task still attempts `az login --identity` (managed identity), which does not exist
on an on-prem jump — the patch makes that attempt **non-fatal** so your pre-established
service-principal session is the one actually used. With real Azure access, the disk-metadata
steps simply succeed instead of being skipped.

The **Azure Python packages** the init step installs (`azure-mgmt-*`) come from the offline
bundle (or from PyPI if the jump is allowed to reach it) — the check collectors themselves
use the Azure CLI, not the Python SDK.

---

## 5. Run and verify

Run exactly as in QUICKSTART Step 8:

```bash
./scripts/sap_automation_qa.sh -vv 2>&1 | tee run.log
```

How to tell the Azure path is actually working (versus silently falling back to N/A):

- Before the run, `az account show` returns the **correct subscription**.
- In the log, the **`Collect detailed azure disks data`** / `az disk show` steps complete
  **without** `az: command not found` or `az login` errors.
- In the report, the disk-performance, storage, and SKU-support checks show **real values**
  (tier / IOPS / MBps / service level) rather than N/A.
- `Total Checks` is greater than zero and the infrastructure categories are populated.

---

## 6. Security summary (for the review conversation)

- **Read-only.** The identity has **Reader**; the framework only issues `show` / `list`
  calls. It cannot modify, create, or delete anything in Azure or on the SAP servers.
- **Minimal surface.** Egress is HTTPS (443) to **two** Microsoft endpoints
  (`AzureResourceManager`, `AzureActiveDirectory`). No inbound changes; the internet is not
  opened.
- **Scoped and temporary.** Scope the Reader assignment to the SAP subscription (or just the
  relevant resource groups), and remove it when the assessment is done.
- **No standing secrets on the jump.** Sign in with a certificate or a short-lived secret;
  don't store credentials in the repo or in config files. Rotate/expire after use.
- **SAP servers untouched.** As in the offline run, the checks against the SAP hosts are
  read-only over SSH; nothing is installed or changed there.

---

## 7. Offline vs. read-only Azure — which to choose

| | Fully offline ([QUICKSTART.md](./QUICKSTART.md)) | Read-only Azure access (this doc) |
|---|---|---|
| OS / SAP / DB2 checks | ✅ Yes | ✅ Yes |
| Azure-infra checks (disk perf, SKU, storage, HA) | ❌ N/A | ✅ Yes |
| Framework modified | Minor non-fatal patches | Same minor patches, nothing more |
| Network exposure | None | Egress-only, 443, two endpoints |
| Result | OS/SAP/DB2 report; pull infra from the portal separately | **Complete report in one run, framework as designed** |

If a narrow read-only path to Azure is acceptable to your security team, it is the
lowest-effort route to a complete assessment and avoids maintaining any divergence from the
upstream framework.
