#!/bin/bash
# =============================================================================
# deploy-sap-sim-lab.sh
#
# Builds a LAB environment to validate the offline SAP configuration checks
# process end to end, using an existing hub/spoke topology:
#
#   HUB   vnet  -> new subnet + jump server VM (management)
#   SPOKE vnet  -> new subnet + 2 simulated "SAP" VMs (SLES):
#                    vm-sapdb01   (plays the HANA DB node)
#                    vm-sapascs01 (plays the ASCS node)
#
# The SAP VMs run no real SAP software. Purpose: give the framework real hosts
# to SSH into and real Azure resources to validate, so the full pipeline
# (inventory -> SSH -> ARM -> HTML report) can be proven. Expect many SAP-level
# checks to report "fail/not found" — that is the expected lab outcome.
#
# Also generates the framework workspace files (hosts.yaml, sap-parameters.yaml)
# and prints the commands to copy everything to the jump server.
#
# Non-interactive mode: AUTO=1 ./deploy-sap-sim-lab.sh  (accepts all defaults)
#
# Requirements: az (logged in), python3, ssh-keygen.
# =============================================================================
set -euo pipefail

log()  { echo -e "\e[1;34m[INFO]\e[0m  $*"; }
warn() { echo -e "\e[1;33m[WARN]\e[0m  $*"; }
err()  { echo -e "\e[1;31m[ERROR]\e[0m $*" >&2; }
die()  { err "$*"; exit 1; }
ask() {
    local __var="$1" __q="$2" __def="${3:-}" __ans
    if [[ "${AUTO:-0}" == "1" && -n "$__def" ]]; then
        echo "$__q [$__def]: (auto)"
        printf -v "$__var" '%s' "$__def"
        return
    fi
    if [[ -n "$__def" ]]; then read -r -p "$__q [$__def]: " __ans; __ans="${__ans:-$__def}";
    else while true; do read -r -p "$__q: " __ans; [[ -n "$__ans" ]] && break; echo "  A value is required."; done; fi
    printf -v "$__var" '%s' "$__ans"
}

# suggest_subnet <vnet-space> <existing-subnet-prefixes...> -> first free /27
suggest_subnet() {
    python3 - "$@" <<'EOF'
import ipaddress, sys
space = ipaddress.ip_network(sys.argv[1])
used  = [ipaddress.ip_network(s) for s in sys.argv[2:]]
for cand in space.subnets(new_prefix=27):
    if not any(cand.overlaps(u) for u in used):
        print(cand); sys.exit(0)
sys.exit(1)
EOF
}

command -v az >/dev/null || die "Azure CLI not found."
command -v python3 >/dev/null || die "python3 not found."
az account show >/dev/null 2>&1 || az login --only-show-errors >/dev/null

# ----------------------------- parameters ------------------------------------
ask SUBSCRIPTION_ID "Subscription ID" "475ee8b6-bb28-4115-b780-a27db1aaf6fe"
az account set --subscription "$SUBSCRIPTION_ID"
log "Using subscription: $(az account show --query name -o tsv)"

# find_vnet <name> -> sets FOUND_SUB / FOUND_RG. Searches the selected
# subscription first, then every other subscription you can access (in an
# Azure Landing Zone the hub VNet usually lives in a Connectivity subscription).
# Uses 'az resource list' because newer Azure CLI requires -g on 'az network vnet list'.
find_vnet() {
    local vnet="$1" rg sub
    rg=$(az resource list --resource-type Microsoft.Network/virtualNetworks --query "[?name=='$vnet'].resourceGroup" -o tsv 2>/dev/null | head -1)
    if [[ -n "$rg" ]]; then FOUND_SUB="$SUBSCRIPTION_ID"; FOUND_RG="$rg"; return 0; fi
    log "VNet '$vnet' not in the selected subscription — searching all accessible subscriptions..."
    while read -r sub; do
        [[ "$sub" == "$SUBSCRIPTION_ID" ]] && continue
        rg=$(az resource list --resource-type Microsoft.Network/virtualNetworks --subscription "$sub" --query "[?name=='$vnet'].resourceGroup" -o tsv 2>/dev/null | head -1)
        if [[ -n "$rg" ]]; then FOUND_SUB="$sub"; FOUND_RG="$rg"; return 0; fi
    done < <(az account list --query "[].id" -o tsv)
    return 1
}

ask HUB_VNET   "Hub VNet name"   "vnet-alz-hub-eastus2"
find_vnet "$HUB_VNET" || die "Hub VNet '$HUB_VNET' not found in any accessible subscription."
HUB_SUB="$FOUND_SUB"; HUB_RG="$FOUND_RG"
log "Hub VNet found: RG=$HUB_RG, subscription=$(az account show --subscription "$HUB_SUB" --query name -o tsv)"

ask SPOKE_VNET "Spoke VNet name" "vnet-migrate-spoke-eastus2"
find_vnet "$SPOKE_VNET" || die "Spoke VNet '$SPOKE_VNET' not found in any accessible subscription."
SPOKE_SUB="$FOUND_SUB"; SPOKE_RG="$FOUND_RG"
log "Spoke VNet found: RG=$SPOKE_RG, subscription=$(az account show --subscription "$SPOKE_SUB" --query name -o tsv)"

LOCATION=$(az network vnet show -g "$HUB_RG" -n "$HUB_VNET" --subscription "$HUB_SUB" --query location -o tsv)
# Azure requires VM/NIC to live in the SAME subscription as their VNet, so the
# lab uses one RG per side: <base>-mgmt next to the hub, <base>-sap next to the spoke.
ask LAB_RG     "Base name for the lab resource groups" "rg-sapqa-lab"
MGMT_RG="${LAB_RG}-mgmt"   # created in the hub's subscription
SAP_RG="${LAB_RG}-sap"     # created in the spoke's subscription
ask ADMIN_USER "Admin username for all VMs" "azureadm"

# Verify hub <-> spoke peering
if az network vnet peering list -g "$HUB_RG" --vnet-name "$HUB_VNET" --subscription "$HUB_SUB" -o tsv \
     --query "[].remoteVirtualNetwork.id" | grep -qi "/$SPOKE_VNET$"; then
    log "Peering hub -> spoke confirmed."
else
    warn "No peering from $HUB_VNET to $SPOKE_VNET detected. The jump server will NOT reach the SAP VMs until peering exists."
fi

# ----------------------------- subnets ---------------------------------------
# Creates an NSG and a subnet with the NSG attached (many landing zone policies
# require "Subnets must have a Network Security Group"). If the subnet already
# exists without an NSG, one is attached retroactively.
create_subnet() { # rg vnet subnet_name subscription
    local rg="$1" vnet="$2" sn="$3" sub="$4" space used suggested prefix vloc nsg nsgid
    nsg="nsg-$sn"
    vloc=$(az network vnet show -g "$rg" -n "$vnet" --subscription "$sub" --query location -o tsv)

    if ! az network nsg show -g "$rg" -n "$nsg" --subscription "$sub" >/dev/null 2>&1; then
        log "Creating NSG $nsg in $rg..."
        az network nsg create -g "$rg" -n "$nsg" -l "$vloc" --subscription "$sub" --output none
    fi
    nsgid=$(az network nsg show -g "$rg" -n "$nsg" --subscription "$sub" --query id -o tsv)

    if az network vnet subnet show -g "$rg" --vnet-name "$vnet" -n "$sn" --subscription "$sub" >/dev/null 2>&1; then
        local current
        current=$(az network vnet subnet show -g "$rg" --vnet-name "$vnet" -n "$sn" --subscription "$sub" --query "networkSecurityGroup.id" -o tsv)
        if [[ -z "$current" ]]; then
            log "Subnet $sn exists without NSG — attaching $nsg..."
            az network vnet subnet update -g "$rg" --vnet-name "$vnet" -n "$sn" --subscription "$sub" --network-security-group "$nsgid" --output none
        else
            log "Subnet $sn already exists in $vnet with an NSG — reusing."
        fi
        return
    fi

    space=$(az network vnet show -g "$rg" -n "$vnet" --subscription "$sub" --query "addressSpace.addressPrefixes[0]" -o tsv)
    mapfile -t used < <(az network vnet subnet list -g "$rg" --vnet-name "$vnet" --subscription "$sub" --query "[].addressPrefix" -o tsv)
    suggested=$(suggest_subnet "$space" "${used[@]:-}") || die "No free /27 left in $vnet ($space)."
    ask prefix "Address prefix for new subnet '$sn' in $vnet" "$suggested"
    az network vnet subnet create -g "$rg" --vnet-name "$vnet" -n "$sn" --subscription "$sub" \
        --address-prefixes "$prefix" --network-security-group "$nsgid" >/dev/null
    log "Subnet $sn ($prefix) created in $vnet with NSG $nsg."
}

create_subnet "$HUB_RG"   "$HUB_VNET"   "snet-sapqa-mgmt" "$HUB_SUB"
create_subnet "$SPOKE_RG" "$SPOKE_VNET" "snet-sap-sim"    "$SPOKE_SUB"

# ----------------------------- ssh key ---------------------------------------
KEY=~/.ssh/sapqa_lab_key
if [[ ! -f "$KEY" ]]; then
    ssh-keygen -t rsa -b 4096 -N "" -f "$KEY" -C "sapqa-lab" >/dev/null
    log "Generated lab SSH keypair: $KEY"
fi

# ----------------------------- VM size auto-detection ------------------------
# Capacity restrictions vary per subscription/region. Test candidates in order
# (newest generations first) and use the first SKU deployable in BOTH the hub
# and spoke subscriptions.
log "Detecting a VM size available in $LOCATION for BOTH the hub and spoke subscriptions..."
VM_SIZE=""
for cand in Standard_D2als_v7 Standard_D2ls_v7 Standard_D2as_v7 Standard_D2s_v7 \
            Standard_DS1_v2 Standard_B2s Standard_B2ms Standard_D2s_v5 Standard_D2s_v4 \
            Standard_D2as_v5 Standard_D2as_v4 Standard_D2_v5 Standard_D2_v4 Standard_E2s_v5; do
    ok_hub=$(az vm list-skus -l "$LOCATION" --size "$cand" --resource-type virtualMachines --subscription "$HUB_SUB" \
            --query "[?name=='$cand' && length(restrictions)==\`0\`].name" -o tsv 2>/dev/null)
    ok_spk=$(az vm list-skus -l "$LOCATION" --size "$cand" --resource-type virtualMachines --subscription "$SPOKE_SUB" \
            --query "[?name=='$cand' && length(restrictions)==\`0\`].name" -o tsv 2>/dev/null)
    if [[ -n "$ok_hub" && -n "$ok_spk" ]]; then
        VM_SIZE="$cand"; break
    fi
done
[[ -n "$VM_SIZE" ]] || die "None of the candidate SKUs are available in $LOCATION. Run: az vm list-skus -l $LOCATION --resource-type virtualMachines --query \"[?length(restrictions)==\\\`0\\\`].name\" -o tsv | sort"
ask VM_SIZE "VM size for all lab VMs" "$VM_SIZE"
log "Using VM size: $VM_SIZE"

# ----------------------------- resource groups + VMs -------------------------
# Each RG is created in the SAME subscription as the VNet its VMs join.
az group show -n "$MGMT_RG" --subscription "$HUB_SUB" >/dev/null 2>&1 || \
    az group create -n "$MGMT_RG" -l "$LOCATION" --subscription "$HUB_SUB" >/dev/null
az group show -n "$SAP_RG" --subscription "$SPOKE_SUB" >/dev/null 2>&1 || \
    az group create -n "$SAP_RG" -l "$LOCATION" --subscription "$SPOKE_SUB" >/dev/null

HUB_SUBNET_ID=$(az network vnet subnet show -g "$HUB_RG" --vnet-name "$HUB_VNET" -n snet-sapqa-mgmt --subscription "$HUB_SUB" --query id -o tsv)
SIM_SUBNET_ID=$(az network vnet subnet show -g "$SPOKE_RG" --vnet-name "$SPOKE_VNET" -n snet-sap-sim --subscription "$SPOKE_SUB" --query id -o tsv)

# --nsg "" prevents az from auto-creating a NIC-level NSG with an SSH-from-
# Internet rule, which ALZ policy "Deny-MgmtPorts-From-Internet" blocks.
# The subnet NSGs created above govern traffic instead.
log "Creating jump server vm-sapqa-jump01 (Ubuntu 22.04, $VM_SIZE, no public IP) in $MGMT_RG..."
az vm create -g "$MGMT_RG" -n vm-sapqa-jump01 -l "$LOCATION" --subscription "$HUB_SUB" \
    --image Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:latest \
    --size "$VM_SIZE" --subnet "$HUB_SUBNET_ID" --public-ip-address "" \
    --nsg "" --admin-username "$ADMIN_USER" --ssh-key-values "$KEY.pub" \
    --assign-identity --output none

for VM in vm-sapdb01 vm-sapascs01; do
    log "Creating simulated SAP VM $VM (SLES 15 SP5, $VM_SIZE, no public IP) in $SAP_RG..."
    az vm create -g "$SAP_RG" -n "$VM" -l "$LOCATION" --subscription "$SPOKE_SUB" \
        --image SUSE:sles-15-sp5:gen2:latest \
        --size "$VM_SIZE" --subnet "$SIM_SUBNET_ID" --public-ip-address "" \
        --nsg "" --admin-username "$ADMIN_USER" --ssh-key-values "$KEY.pub" --output none
done

# ----------------------------- RBAC ------------------------------------------
IDENTITY=$(az vm show -g "$MGMT_RG" -n vm-sapqa-jump01 --subscription "$HUB_SUB" --query identity.principalId -o tsv)
log "Granting Reader to jump server identity ($IDENTITY)..."
az role assignment create --assignee "$IDENTITY" --role Reader \
    --scope "/subscriptions/$SPOKE_SUB/resourceGroups/$SAP_RG" >/dev/null || warn "Reader on $SAP_RG failed (may already exist)."
az role assignment create --assignee "$IDENTITY" --role Reader \
    --scope "/subscriptions/$SPOKE_SUB/resourceGroups/$SPOKE_RG" >/dev/null || warn "Reader on $SPOKE_RG failed (optional)."
az role assignment create --assignee "$IDENTITY" --role Reader \
    --scope "/subscriptions/$HUB_SUB/resourceGroups/$MGMT_RG" >/dev/null || warn "Reader on $MGMT_RG failed (optional)."

# ----------------------------- workspace files -------------------------------
JUMP_IP=$(az vm show -g "$MGMT_RG" -n vm-sapqa-jump01 -d --subscription "$HUB_SUB" --query privateIps -o tsv)
DB_IP=$(az vm show -g "$SAP_RG" -n vm-sapdb01 -d --subscription "$SPOKE_SUB" --query privateIps -o tsv)
SCS_IP=$(az vm show -g "$SAP_RG" -n vm-sapascs01 -d --subscription "$SPOKE_SUB" --query privateIps -o tsv)

WS="lab-workspace/LAB-EUS2-SAP01-X00"
mkdir -p "$WS"
# ansible_python_interpreter: SLES 15 default python3 is 3.6, too old for the
# framework's ansible-core (needs >= 3.7). Install python311 on the SAP VMs.
cat > "$WS/hosts.yaml" <<EOF
X00_DB:
  hosts:
    vm-sapdb01:
      ansible_host: "$DB_IP"
      ansible_user: "$ADMIN_USER"
      ansible_connection: "ssh"
      connection_type: "key"
      virtual_host: "vm-sapdb01"
      become_user: "root"
      os_type: "linux"
      ansible_python_interpreter: "/usr/bin/python3.11"
      vm_name: "vm-sapdb01"
  vars:
    node_tier: "hana"
X00_SCS:
  hosts:
    vm-sapascs01:
      ansible_host: "$SCS_IP"
      ansible_user: "$ADMIN_USER"
      ansible_connection: "ssh"
      connection_type: "key"
      virtual_host: "vm-sapascs01"
      become_user: "root"
      os_type: "linux"
      ansible_python_interpreter: "/usr/bin/python3.11"
      vm_name: "vm-sapascs01"
  vars:
    node_tier: "scs"
EOF

cat > "$WS/sap-parameters.yaml" <<EOF
sap_sid: "X00"
db_sid: "HDB"
scs_high_availability: false
database_high_availability: false
database_scale_out: false
scs_instance_number: "00"
ers_instance_number: "01"
db_instance_number: "00"
platform: "HANA"
NFS_provider: "AFS"
user_assigned_identity_client_id: ""
EOF
cp "$KEY" "$WS/ssh_key.ppk" && chmod 600 "$WS/ssh_key.ppk"
log "Workspace generated at: $WS"

# ----------------------------- summary ---------------------------------------
echo
echo "==================== LAB READY ===================="
echo "  Jump server : vm-sapqa-jump01  $JUMP_IP  (hub/snet-sapqa-mgmt, RG $MGMT_RG)"
echo "  SAP DB sim  : vm-sapdb01       $DB_IP   (spoke/snet-sap-sim, RG $SAP_RG)"
echo "  SAP SCS sim : vm-sapascs01     $SCS_IP  (spoke/snet-sap-sim, RG $SAP_RG)"
echo "  SSH key     : $KEY"
echo "==================================================="
echo
echo "Next steps:"
echo "  1. Connect to the jump server:"
echo "       ssh -i $KEY $ADMIN_USER@$JUMP_IP"
echo "  2. Install python311 on the SAP VMs (SLES default python3 is too old):"
echo "       ssh -i $KEY $ADMIN_USER@$DB_IP 'sudo zypper install -y python311'"
echo "       ssh -i $KEY $ADMIN_USER@$SCS_IP 'sudo zypper install -y python311'"
echo "  3. On the jump server: install the framework (online: scripts/setup.sh —"
echo "     offline: see the offline installation guide), then apply the framework"
echo "     fixes: ./apply-framework-fixes.sh ~/sap-automation-qa  (see LAB-FINDINGS.md)"
echo "  4. Copy the workspace:"
echo "       scp -i $KEY -r $WS $ADMIN_USER@$JUMP_IP:~/sap-automation-qa/WORKSPACES/SYSTEM/"
echo "  5. On the jump server: set TEST_TYPE=ConfigurationChecks and"
echo "     SYSTEM_CONFIG_NAME=LAB-EUS2-SAP01-X00 in vars.yaml, then:"
echo "       az login --identity && az account set --subscription <spoke-sub>"
echo "       sudo az login --identity   # Azure-based checks run as root (become)"
echo "       ./scripts/sap_automation_qa.sh"
echo "  6. Report: WORKSPACES/SYSTEM/LAB-EUS2-SAP01-X00/quality_assurance/CONFIG_X00_HANA_*.html"
