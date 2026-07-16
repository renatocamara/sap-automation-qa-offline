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
| [QUICKSTART.md](./QUICKSTART.md) | **Start here — the customer procedure.** Assumes an existing offline jump server. Background, the "does anything get installed on SAP?" answer, the environment ([diagram](./architecture-onprem.svg)), and the step-by-step: laptop downloads bundle → scp to jump server → offline install + validated fixes → checks → report back to laptop. |
| [SCRIPTS.md](./SCRIPTS.md) + [build-bundle.sh](./build-bundle.sh) + [setup-and-run.sh](./setup-and-run.sh) | **One-shot automation of the whole procedure.** `build-bundle.sh` builds the offline bundle on the laptop; `setup-and-run.sh` runs everything on the jump server (offline install, workspace, run, report) with the inputs prompted up front. All four end-to-end paths lab-validated on a clean RHEL 9 jump. |
| [SPEECH.md](./SPEECH.md) | Presenter/teleprompter script for walking a customer through the procedure live — one spoken segment per QUICKSTART block and sub-step. |
| [LAB-FINDINGS.md](./LAB-FINDINGS.md) | The real issues found and fixed while validating the procedure end to end, each with root cause and fix. |
| [sap-automation-qa-offline-install.md](./sap-automation-qa-offline-install.md) | **Deep-dive reference** for the offline installation — the *why* behind each step. |
| [LAB.md](./LAB.md) + [deploy-sap-sim-lab.sh](./deploy-sap-sim-lab.sh) | **Optional — for testing only, not part of the customer procedure.** A helper that builds a throwaway Azure lab (offline RHEL 9 jump + two RHEL 8.10/Python 3.6 SAP sims) to reproduce and rehearse the whole scenario from scratch. |
| [provision-jumpserver.sh](./provision-jumpserver.sh) | Optional Azure CLI script to provision a jump server VM (for anyone who needs to create one). Not needed when a jump server already exists. |

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
