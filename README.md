# sap-automation-qa-offline

Tooling to run the [SAP Testing Automation Framework (Azure/sap-automation-qa)](https://github.com/Azure/sap-automation-qa)
configuration checks in environments where the management (jump) server has **no
internet access** — common in secure and regulated SAP landscapes.

## Architecture

![Offline execution architecture](./architecture.svg)

The numbered flow: (1) an internet-connected staging machine downloads the framework
and dependencies and builds the offline bundle; (2) the bundle is transferred to the
jump server over an approved channel; (3) the jump server inspects the SAP VMs via
SSH — read-only, nothing is installed on them; (4) it validates Azure resource
configuration through the ARM APIs using its managed identity (private access);
(5) it generates the HTML assessment report; (6) the report is shared with Microsoft
for review. See the [installation guide](./sap-automation-qa-offline-install.md) for
the full step-by-step procedure.

## Contents

| File | Description |
|---|---|
| [QUICKSTART.md](./QUICKSTART.md) | **Start here.** Background on why this documentation exists, then the primary path — Scenario 2: existing jump server WITH internet (scenario explanation + [dedicated architecture diagram](./architecture-online.svg) + 8-step command sequence, including the validated fixes). Scenario 1 (air-gapped, staging machine + offline bundle) kept as fallback. |
| [sap-automation-qa-offline-install.md](./sap-automation-qa-offline-install.md) | **Step-by-step offline installation guide** (deep reference for Scenario 1). Explains every step and why it's needed: preparing a staging machine (installing git/Python, cloning the repo), building the offline dependency bundle, transferring it, installing on the air-gapped server, and running the checks. |
| [provision-jumpserver.sh](./provision-jumpserver.sh) | **Interactive Azure CLI script** that provisions the management (jump) server. Prompts for subscription, deployment target (hub VNet / DMZ VNet / new VNet), suggests an unused CIDR block and validates it against existing VNets, lets you pick a VM SKU (validated for the region), and creates the VM with a system-assigned managed identity. |
| [deploy-sap-sim-lab.sh](./deploy-sap-sim-lab.sh) | **Lab builder** for validating the whole process in a hub/spoke ALZ environment: creates subnets with NSGs (policy-compliant), a jump server, and two simulated SAP VMs; auto-detects an available VM SKU; generates the framework workspace files. |

## Quick start

Already have a jump server? Go straight to **[QUICKSTART.md](./QUICKSTART.md)** —
Scenario 2 (jump server with internet) is the primary 8-step path; Scenario 1
(air-gapped) is the documented fallback.

Need to create a jump server first?

```bash
# On any machine with Azure CLI + python3:
chmod +x provision-jumpserver.sh
./provision-jumpserver.sh
```

## Key facts

- There is **no prebuilt offline package** in the upstream repo — the guide shows how to build one.
- The SAP VMs never need internet; the jump server only needs SSH/WinRM to them.
- The Azure infrastructure checks require the jump server to reach Azure management
  APIs (`management.azure.com`) — private endpoint, service tags, or proxy is
  sufficient. Fully air-gapped servers get OS/SAP-level checks only.
