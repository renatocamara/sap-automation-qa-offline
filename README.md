# sap-automation-qa-offline

Tooling to run the [SAP Testing Automation Framework (Azure/sap-automation-qa)](https://github.com/Azure/sap-automation-qa)
configuration checks in environments where the management (jump) server has **no
internet access** — common in secure and regulated SAP landscapes.

## Contents

| File | Description |
|---|---|
| [sap-automation-qa-offline-install.md](./sap-automation-qa-offline-install.md) | **Step-by-step offline installation guide.** Explains every step and why it's needed: preparing a staging machine (installing git/Python, cloning the repo), building the offline dependency bundle, transferring it, installing on the air-gapped server, and running the checks. Start here. |
| [provision-jumpserver.sh](./provision-jumpserver.sh) | **Interactive Azure CLI script** that provisions the management (jump) server. Prompts for subscription, deployment target (hub VNet / DMZ VNet / new VNet), suggests an unused CIDR block and validates it against existing VNets, lets you pick a VM SKU (validated for the region), and creates the VM with a system-assigned managed identity. |

## Quick start

```bash
# On any machine with Azure CLI + python3, to provision the jump server:
chmod +x provision-jumpserver.sh
./provision-jumpserver.sh
```

Then follow the [offline installation guide](./sap-automation-qa-offline-install.md)
to install and run the framework on that server.

## Key facts

- There is **no prebuilt offline package** in the upstream repo — the guide shows how to build one.
- The SAP VMs never need internet; the jump server only needs SSH/WinRM to them.
- The Azure infrastructure checks require the jump server to reach Azure management
  APIs (`management.azure.com`) — private endpoint, service tags, or proxy is
  sufficient. Fully air-gapped servers get OS/SAP-level checks only.
