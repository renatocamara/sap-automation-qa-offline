#!/bin/bash
# =============================================================================
# provision-jumpserver.sh
#
# Interactively provisions a management (jump) server for the SAP Testing
# Automation Framework (Azure/sap-automation-qa) using the Azure CLI.
#
# What it does:
#   1. Prompts for the Azure subscription ID.
#   2. Asks whether to deploy into a hub VNet, a DMZ VNet, or a new VNet.
#   3. Existing VNet: lets you pick the resource group, VNet, and subnet.
#   4. New VNet: suggests an unused CIDR block and validates that the chosen
#      CIDR does not overlap with any existing VNet in the subscription.
#   5. Creates the resources and provisions the jump server VM with a
#      system-assigned managed identity (required by the framework).
#
# Requirements: az (Azure CLI), python3 (for CIDR math), an account with
#               rights to create resources in the subscription.
# =============================================================================
set -euo pipefail

# ----------------------------- helpers ---------------------------------------
log()  { echo -e "\e[1;34m[INFO]\e[0m  $*"; }
warn() { echo -e "\e[1;33m[WARN]\e[0m  $*"; }
err()  { echo -e "\e[1;31m[ERROR]\e[0m $*" >&2; }
die()  { err "$*"; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed."; }

# Prompt with optional default: ask VAR "Question" "default"
ask() {
    local __var="$1" __q="$2" __def="${3:-}" __ans
    if [[ -n "$__def" ]]; then
        read -r -p "$__q [$__def]: " __ans
        __ans="${__ans:-$__def}"
    else
        while true; do
            read -r -p "$__q: " __ans
            [[ -n "$__ans" ]] && break
            echo "  A value is required."
        done
    fi
    printf -v "$__var" '%s' "$__ans"
}

valid_cidr() {
    python3 - "$1" <<'EOF'
import ipaddress, sys
try:
    ipaddress.ip_network(sys.argv[1], strict=True)
except ValueError:
    sys.exit(1)
EOF
}

# overlaps CIDR "space1 space2 ..." -> exit 0 if overlap found
overlaps() {
    python3 - "$@" <<'EOF'
import ipaddress, sys
cand = ipaddress.ip_network(sys.argv[1])
for s in sys.argv[2:]:
    if cand.overlaps(ipaddress.ip_network(s)):
        print(s)
        sys.exit(0)
sys.exit(1)
EOF
}

# suggest_cidr "space1 space2 ..." -> prints first free 10.x.0.0/24
suggest_cidr() {
    python3 - "$@" <<'EOF'
import ipaddress, sys
existing = [ipaddress.ip_network(s) for s in sys.argv[1:]]
for i in range(100, 255):
    cand = ipaddress.ip_network(f"10.{i}.0.0/24")
    if not any(cand.overlaps(e) for e in existing):
        print(cand); sys.exit(0)
for i in range(0, 100):
    cand = ipaddress.ip_network(f"10.{i}.0.0/24")
    if not any(cand.overlaps(e) for e in existing):
        print(cand); sys.exit(0)
sys.exit(1)
EOF
}

# ----------------------------- preflight -------------------------------------
need_cmd az
need_cmd python3

log "Checking Azure CLI login..."
if ! az account show >/dev/null 2>&1; then
    log "Not logged in. Launching 'az login'..."
    az login --only-show-errors >/dev/null
fi

# ----------------------------- 1. subscription -------------------------------
echo
echo "Available subscriptions:"
az account list --query "[].{Name:name, SubscriptionId:id}" -o table
echo
ask SUBSCRIPTION_ID "Enter the Azure subscription ID to use"
az account set --subscription "$SUBSCRIPTION_ID" || die "Could not select subscription '$SUBSCRIPTION_ID'."
log "Using subscription: $(az account show --query name -o tsv)"

# Collect every address space already in use (used for validation/suggestion)
log "Collecting existing VNet address spaces in the subscription..."
mapfile -t EXISTING_SPACES < <(az network vnet list \
    --query "[].addressSpace.addressPrefixes[]" -o tsv)
if ((${#EXISTING_SPACES[@]})); then
    log "Found ${#EXISTING_SPACES[@]} address space(s) in use: ${EXISTING_SPACES[*]}"
else
    log "No existing VNets found in this subscription."
fi

# ----------------------------- 2. network choice -----------------------------
echo
echo "Where should the jump server be deployed?"
echo "  1) Existing hub VNet"
echo "  2) Existing DMZ VNet"
echo "  3) New VNet"
ask NET_CHOICE "Choose 1, 2 or 3" "3"

CREATE_VNET=false
case "$NET_CHOICE" in
    1|2)
        # ------------------- existing VNet path ------------------------------
        [[ "$NET_CHOICE" == "1" ]] && log "Deploying into an existing HUB VNet." \
                                   || log "Deploying into an existing DMZ VNet."
        echo
        echo "Existing VNets in this subscription:"
        az network vnet list \
            --query "[].{Name:name, ResourceGroup:resourceGroup, AddressSpace:join(', ', addressSpace.addressPrefixes), Location:location}" \
            -o table
        echo
        ask RESOURCE_GROUP "Resource group of the target VNet"
        ask VNET_NAME      "VNet name"
        az network vnet show -g "$RESOURCE_GROUP" -n "$VNET_NAME" >/dev/null \
            || die "VNet '$VNET_NAME' not found in resource group '$RESOURCE_GROUP'."
        LOCATION=$(az network vnet show -g "$RESOURCE_GROUP" -n "$VNET_NAME" --query location -o tsv)

        echo
        echo "Subnets in $VNET_NAME:"
        az network vnet subnet list -g "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" \
            --query "[].{Name:name, Prefix:addressPrefix}" -o table
        echo
        ask SUBNET_NAME "Subnet to use (existing name, or a new name to create one)"
        if ! az network vnet subnet show -g "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" \
                -n "$SUBNET_NAME" >/dev/null 2>&1; then
            log "Subnet '$SUBNET_NAME' does not exist — it will be created."
            mapfile -t SUBNET_SPACES < <(az network vnet subnet list \
                -g "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" \
                --query "[].addressPrefix" -o tsv)
            while true; do
                ask SUBNET_PREFIX "Address prefix for the new subnet (must be inside the VNet space)"
                valid_cidr "$SUBNET_PREFIX" || { err "Invalid CIDR."; continue; }
                if ((${#SUBNET_SPACES[@]})) && HIT=$(overlaps "$SUBNET_PREFIX" "${SUBNET_SPACES[@]}"); then
                    err "Overlaps existing subnet prefix: $HIT"; continue
                fi
                break
            done
            az network vnet subnet create -g "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" \
                -n "$SUBNET_NAME" --address-prefixes "$SUBNET_PREFIX" >/dev/null
            log "Subnet '$SUBNET_NAME' ($SUBNET_PREFIX) created."
        fi
        ;;
    3)
        # ------------------- new VNet path ------------------------------------
        CREATE_VNET=true
        log "A new VNet will be created."
        ask RESOURCE_GROUP "Resource group for the new VNet/VM (created if missing)" "rg-sapqa-mgmt"
        ask LOCATION       "Azure region" "westeurope"

        SUGGESTED=""
        if ((${#EXISTING_SPACES[@]})); then
            SUGGESTED=$(suggest_cidr "${EXISTING_SPACES[@]}") || true
        else
            SUGGESTED="10.100.0.0/24"
        fi
        [[ -n "$SUGGESTED" ]] && log "Suggested unused CIDR block: $SUGGESTED"

        while true; do
            ask VNET_CIDR "CIDR block for the new VNet" "${SUGGESTED:-10.100.0.0/24}"
            valid_cidr "$VNET_CIDR" || { err "'$VNET_CIDR' is not a valid CIDR."; continue; }
            if ((${#EXISTING_SPACES[@]})) && HIT=$(overlaps "$VNET_CIDR" "${EXISTING_SPACES[@]}"); then
                err "'$VNET_CIDR' overlaps existing VNet address space: $HIT — choose another."
                continue
            fi
            break
        done
        log "CIDR $VNET_CIDR validated: no overlap with existing VNets."

        VNET_NAME="vnet-sapqa-mgmt"
        SUBNET_NAME="snet-jumpserver"
        ask VNET_NAME   "New VNet name"   "$VNET_NAME"
        ask SUBNET_NAME "New subnet name" "$SUBNET_NAME"
        ;;
    *) die "Invalid choice: $NET_CHOICE" ;;
esac

# ----------------------------- 3. VM parameters ------------------------------
echo
ask VM_NAME    "Jump server VM name" "vm-sapqa-jump01"
ask VM_SIZE    "VM size"             "Standard_D4s_v5"
ask ADMIN_USER "Admin username"      "azureadm"

echo
echo "Operating system (must be a supported management-server distro):"
echo "  1) Ubuntu 22.04 LTS"
echo "  2) RHEL 9"
echo "  3) SLES 15 SP5"
ask OS_CHOICE "Choose 1, 2 or 3" "1"
case "$OS_CHOICE" in
    1) IMAGE="Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:latest" ;;
    2) IMAGE="RedHat:RHEL:9-lvm-gen2:latest" ;;
    3) IMAGE="SUSE:sles-15-sp5:gen2:latest" ;;
    *) die "Invalid choice: $OS_CHOICE" ;;
esac

ask PUBLIC_IP "Attach a public IP? (usually 'no' for a jump server reached via internal network/Bastion)" "no"
ask SSH_SOURCE "Source CIDR allowed to SSH to the jump server (NSG rule)" "10.0.0.0/8"

# ----------------------------- 4. summary + confirm --------------------------
echo
echo "================= Deployment summary ================="
echo "  Subscription : $SUBSCRIPTION_ID"
echo "  Resource grp : $RESOURCE_GROUP"
echo "  Location     : ${LOCATION:-<from VNet>}"
if $CREATE_VNET; then
echo "  VNet (new)   : $VNET_NAME ($VNET_CIDR)"
echo "  Subnet (new) : $SUBNET_NAME"
else
echo "  VNet         : $VNET_NAME (existing)"
echo "  Subnet       : $SUBNET_NAME"
fi
echo "  VM           : $VM_NAME ($VM_SIZE, $IMAGE)"
echo "  Admin user   : $ADMIN_USER (SSH key auto-generated)"
echo "  Public IP    : $PUBLIC_IP"
echo "  SSH allowed  : from $SSH_SOURCE"
echo "======================================================"
ask CONFIRM "Proceed with deployment? (yes/no)" "yes"
[[ "$CONFIRM" == "yes" ]] || die "Aborted by user."

# ----------------------------- 5. create resources ---------------------------
if ! az group show -n "$RESOURCE_GROUP" >/dev/null 2>&1; then
    log "Creating resource group $RESOURCE_GROUP in $LOCATION..."
    az group create -n "$RESOURCE_GROUP" -l "$LOCATION" >/dev/null
fi

if $CREATE_VNET; then
    log "Creating VNet $VNET_NAME ($VNET_CIDR) with subnet $SUBNET_NAME..."
    az network vnet create -g "$RESOURCE_GROUP" -n "$VNET_NAME" -l "$LOCATION" \
        --address-prefixes "$VNET_CIDR" \
        --subnet-name "$SUBNET_NAME" --subnet-prefixes "$VNET_CIDR" >/dev/null
fi

NSG_NAME="nsg-${VM_NAME}"
log "Creating network security group $NSG_NAME (SSH from $SSH_SOURCE only)..."
az network nsg create -g "$RESOURCE_GROUP" -n "$NSG_NAME" -l "${LOCATION}" >/dev/null
az network nsg rule create -g "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" \
    -n Allow-SSH --priority 1000 --direction Inbound --access Allow \
    --protocol Tcp --destination-port-ranges 22 \
    --source-address-prefixes "$SSH_SOURCE" >/dev/null

PIP_ARGS=(--public-ip-address "")
[[ "$PUBLIC_IP" == "yes" ]] && PIP_ARGS=(--public-ip-sku Standard)

log "Provisioning VM $VM_NAME (this can take a few minutes)..."
az vm create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_NAME" \
    --location "$LOCATION" \
    --image "$IMAGE" \
    --size "$VM_SIZE" \
    --vnet-name "$VNET_NAME" \
    --subnet "$SUBNET_NAME" \
    --nsg "$NSG_NAME" \
    --admin-username "$ADMIN_USER" \
    --generate-ssh-keys \
    --assign-identity \
    "${PIP_ARGS[@]}" \
    --output table

PRIVATE_IP=$(az vm show -g "$RESOURCE_GROUP" -n "$VM_NAME" -d --query privateIps -o tsv)
IDENTITY_ID=$(az vm show -g "$RESOURCE_GROUP" -n "$VM_NAME" --query identity.principalId -o tsv)

echo
log "Jump server provisioned successfully."
echo "  Private IP                    : $PRIVATE_IP"
echo "  System-assigned identity (ID): $IDENTITY_ID"
echo
echo "Next steps for the SAP Testing Automation Framework:"
echo "  1. Grant the identity above the 'Reader' role on every resource group"
echo "     containing SAP components, e.g.:"
echo "       az role assignment create --assignee $IDENTITY_ID \\"
echo "         --role Reader --scope /subscriptions/$SUBSCRIPTION_ID/resourceGroups/<SAP-RG>"
if $CREATE_VNET; then
echo "  2. Peer $VNET_NAME with the SAP workload VNet(s):"
echo "       az network vnet peering create -g $RESOURCE_GROUP -n to-sap \\"
echo "         --vnet-name $VNET_NAME --remote-vnet <SAP-VNET-ID> --allow-vnet-access"
echo "  3. Install the framework (online: scripts/setup.sh — offline: see the"
echo "     offline installation guide in this repo)."
else
echo "  2. Verify network reachability (SSH) from $PRIVATE_IP to the SAP VMs."
echo "  3. Install the framework (online: scripts/setup.sh — offline: see the"
echo "     offline installation guide in this repo)."
fi
