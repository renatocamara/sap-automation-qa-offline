# sap-automation-qa-offline

Tooling to run the [SAP Testing Automation Framework (Azure/sap-automation-qa)](https://github.com/Azure/sap-automation-qa)
configuration checks in environments where the management (jump) server has **no
internet access** — common in secure and regulated SAP landscapes.

## Architecture (current scenario: on-premises jump server, fully offline)

![Customer scenario architecture](./architecture-onprem.svg)

The environment: an **on-premises jump server (RHEL 9, no internet, no Azure
portal)** connected to Azure via ExpressRoute; SAP servers on Azure (RHEL 8.10, no
internet). The flow: (1) the operator laptop (internet) downloads the framework and
all dependencies as one bundle; (2) the bundle is copied to the jump server via scp;
(3) the jump server runs read-only SSH checks against the SAP servers over
ExpressRoute; (4) the report is generated on the jump server; (5) copied back to
the laptop and shared with Microsoft. Full procedure:
[QUICKSTART.md](./QUICKSTART.md).

## Contents

| File | Description |
|---|---|
| [QUICKSTART.md](./QUICKSTART.md) | **Start here.** Background, the "does anything get installed on SAP?" answer, the environment ([diagram](./architecture-onprem.svg)), the Azure-endpoints decision test, and the 9-step offline procedure: laptop downloads bundle → scp to jump server → offline install + validated fixes → checks → report back to laptop. |
| [sap-automation-qa-offline-install.md](./sap-automation-qa-offline-install.md) | **Deep-dive reference** for the offline installation. Explains the *why* behind each step: preparing the internet-connected download machine (the operator laptop, in this environment), building the offline dependency bundle, transferring it, installing on the air-gapped jump server, and running the checks. |
| [provision-jumpserver.sh](./provision-jumpserver.sh) | **Interactive Azure CLI script** that provisions the management (jump) server. Prompts for subscription, deployment target (hub VNet / DMZ VNet / new VNet), suggests an unused CIDR block and validates it against existing VNets, lets you pick a VM SKU (validated for the region), and creates the VM with a system-assigned managed identity. |
| [deploy-sap-sim-lab.sh](./deploy-sap-sim-lab.sh) | **Lab builder** for validating the whole process in a hub/spoke ALZ environment: creates subnets with NSGs (policy-compliant), a jump server, and two simulated SAP VMs; auto-detects an available VM SKU; generates the framework workspace files. |

## Quick start

Go straight to **[QUICKSTART.md](./QUICKSTART.md)** — the 9-step offline procedure
for the on-premises jump server: download on the laptop, transfer, install offline,
run the checks, collect the report.

## Key facts

- There is **no prebuilt offline package** in the upstream repo — the guide shows how to build one.
- The SAP VMs never need internet; the jump server only needs SSH/WinRM to them.
- The Azure infrastructure checks require the jump server to reach Azure management
  APIs (`management.azure.com`) — private endpoint, service tags, or proxy is
  sufficient. Fully air-gapped servers get OS/SAP-level checks only.
