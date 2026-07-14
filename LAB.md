# Lab — reproduce the offline environment for testing

This is **optional** and **not part of the customer procedure**. A real customer
already has an offline jump server and simply follows
[QUICKSTART.md](./QUICKSTART.md).

Use this only if you want to **reproduce the whole scenario from scratch** in Azure —
to validate the procedure, rehearse it, or demo it — without a real SAP landscape.

## What the lab builds

`deploy-sap-sim-lab.sh` creates, in an existing hub/spoke topology:

| Component | Purpose |
|---|---|
| **Jump server** — RHEL 9, **no internet** | Simulates the customer's on-premises jump server. Runs the framework. |
| **2 simulated SAP servers** — RHEL 8.10, Python 3.6, **no internet** | Give the framework real hosts to SSH into and real Azure resources to read. They run no SAP software, so SAP-level checks report "not found" — expected. |

The lab reproduces the two things that make the customer scenario hard:

- **Everything is offline.** Both the jump server and the SAP servers are blocked from
  the internet (a deny-outbound NSG rule). Anything that must be installed has to be
  **copied in** — exactly the constraint the customer lives with. The only exception
  the script automates: it temporarily attaches a NAT gateway to install `python3.11`
  and `git` on the jump, then removes it (because in a real customer that tooling
  arrives inside the offline bundle instead).
- **Real OS/Python versions.** RHEL 9 jump + RHEL 8.10 / Python 3.6 SAP servers, so
  the validation exercises the same version constraints the customer has.

## Prerequisites

- Azure CLI logged in, with rights to create resources.
- An existing hub VNet and a spoke VNet (ExpressRoute/VPN/peering between them). The
  script finds them across subscriptions (ALZ-friendly) and creates one subnet in each.
- `python3` and `ssh-keygen` on the machine running the script.

## Run it

```bash
AUTO=1 ./deploy-sap-sim-lab.sh          # accepts sensible defaults non-interactively
# or just: ./deploy-sap-sim-lab.sh      # to review each prompt
```

It prints the jump server IP, the SAP server IPs, the SSH key path, and a generated
framework workspace under `lab-workspace/`. From there you follow the customer
[QUICKSTART.md](./QUICKSTART.md) starting at Step 2 (build the bundle on your laptop,
copy it in, install offline, run) — the jump server is the "existing offline jump
server" the quickstart assumes.

### Parallel environments

To run a second, isolated lab that doesn't collide with the first (e.g. one for you
to walk through by hand while another is used for automated checks):

```bash
LAB_SUFFIX=2 AUTO=1 ./deploy-sap-sim-lab.sh   # names become vm-sapqa-jump01-2, etc.
```

## Tear it down

```bash
az group delete -n <base>-mgmt --subscription <hub-sub>  --yes --no-wait
az group delete -n <base>-sap  --subscription <spoke-sub> --yes --no-wait
```

(The script prints the exact resource-group names and delete commands at the end.)

## What this lab has validated

See [LAB-FINDINGS.md](./LAB-FINDINGS.md) for the issues found and fixed while running
this lab end to end — including the headline result: with `ansible-core 2.16` the
checks run against the SAP servers' Python 3.6 **without installing anything on the
SAP servers**.
