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
# Requirements: az (logged in), python3, ssh-keygen.
# =============================================================================
set -euo pipefail

log()  { echo -e "\e[1;34m[INFO]\e[0m  $*"; }
warn() { echo -e "\e[1;33m[WARN]\e[0m  $*"; }
err()  { echo -e "\e[1;31m[ERROR]\e[0m $*" >&2; }
die()  { err "$*"; exit 1; }
ask() {
    local __var="$1" __q="$2" __def="${3:-}" __ans
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

ask HUB_VNET   "Hub VNet name"   "vnet-alz-hub-eastus2"
HUB_RG=$(az network vnet list --query "[?name=='$HUB_VNET'].resourceGroup" -o tsv)
[[ -n "$HUB_RG" ]] || die "Hub VNet '$HUB_VNET' not found in this subscription."
log "Hub VNet found in resource group: $HUB_RG"

ask SPOKE_VNET "Spoke VNet name" "vnet-migrate-spoke-eastus2"
SPOKE_RG=$(az network vnet list --query "[?name=='$SPOKE_VNET'].resourceGroup" -o tsv)
[[ -n "$SPOKE_RG" ]] || die "Spoke VNet '$SPOKE_VNET' not found in this subscription."
log "Spoke VNet found in resource group: $SPOKE_RG"

LOCATION=$(az network vnet show -g "$HUB_RG" -n "$HUB_VNET" --query location -o tsv)
ask LAB_RG     "Resource group for the lab VMs (created if missing)" "rg-sapqa-lab"
ask ADMIN_USER "Admin username for all VMs" "azureadm"

# Verify hub <-> spoke peering
if az network vnet peering list -g "$HUB_RG" --vnet-name "$HUB_VNET" -o tsv \
     --query "[].remoteVirtualNetwork.id" | grep -qi "/$SPOKE_VNET$"; then
    log "Peering hub -> spoke confirmed."
else
    warn "No peering from $HUB_VNET to $SPOKE_VNET detected. The jump server will NOT reach the SAP VMs until peering exists."
fi

# ----------------------------- subnets ---------------------------------------
create_subnet() { # rg vnet subnet_name
    local rg="$1" vnet="$2" sn="$3" space used suggested prefix
    if az network vnet subnet show -g "$rg" --vnet-name "$vnet" -n "$sn" >/dev/null 2>&1; then
        log "Subnet $sn already exists in $vnet — reusing."
        return
    fi
    space=$(az network vnet show -g "$rg" -n "$vnet" --query "addressSpace.addressPrefixes[0]" -o tsv)
    mapfile -t used < <(az network vnet subnet list -g "$rg" --vnet-name "$vnet" --query "[].addressPrefix" -o tsv)
    suggested=$(suggest_subnet "$space" "${used[@]:-}") || die "No free /27 left in $vnet ($space)."
    ask prefix "Address prefix for new subnet '$sn' in $vnet" "$suggested"
    az network vnet subnet create -g "$rg" --vnet-name "$vnet" -n "$sn" --address-prefixes "$prefix" >/dev/null
    log "Subnet $sn ($prefix) created in $vnet."
}

create_subnet "$HUB_RG"   "$HUB_VNET"   "snet-sapqa-mgmt"
create_subnet "$SPOKE_RG" "$SPOKE_VNET" "snet-sap-sim"

# ----------------------------- ssh key ---------------------------------------
KEY=~/.ssh/sapqa_lab_key
if [[ ! -f "$KEY" ]]; then
    ssh-keygen -t rsa -b 4096 -N "" -f "$KEY" -C "sapqa-lab" >/dev/null
    log "Generated lab SSH keypair: $KEY"
fi

# ----------------------------- resource group + VMs --------------------------
az group show -n "$LAB_RG" >/dev/null 2>&1 || az group create -n "$LAB_RG" -l "$LOCATION" >/dev/null

HUB_SUBNET_ID=$(az network vnet subnet show -g "$HUB_RG" --vnet-name "$HUB_VNET" -n snet-sapqa-mgmt --query id -o tsv)
SIM_SUBNET_ID=$(az network vnet subnet show -g "$SPOKE_RG" --vnet-name "$SPOKE_VNET" -n snet-sap-sim --query id -o tsv)

log "Creating jump server vm-sapqa-jump01 (Ubuntu 22.04, D2s_v5, no public IP)..."
az vm create -g "$LAB_RG" -n vm-sapqa-jump01 -l "$LOCATION" \
    --image Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:latest \
    --size Standard_D2s_v5 --subnet "$HUB_SUBNET_ID" --public-ip-address "" \
    --admin-username "$ADMIN_USER" --ssh-key-values "$KEY.pub" \
    --assign-identity --output none

for VM in vm-sapdb01 vm-sapascs01; do
    log "Creating simulated SAP VM $VM (SLES 15 SP5, D2s_v5, no public IP)..."
    az vm create -g "$LAB_RG" -n "$VM" -l "$LOCATION" \
        --image SUSE:sles-15-sp5:gen2:latest \
        --size Standard_D2s_v5 --subnet "$SIM_SUBNET_ID" --public-ip-address "" \
        --admin-username "$ADMIN_USER" --ssh-key-values "$KEY.pub" --output none
done

# ----------------------------- RBAC ------------------------------------------
IDENTITY=$(az vm show -g "$LAB_RG" -n vm-sapqa-jump01 --query identity.principalId -o tsv)
log "Granting Reader to jump server identity ($IDENTITY)..."
az role assignment create --assignee "$IDENTITY" --role Reader \
    --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$LAB_RG" >/dev/null || warn "Reader on $LAB_RG failed (may already exist)."
az role assignment create --assignee "$IDENTITY" --role Reader \
    --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$SPOKE_RG" >/dev/null || warn "Reader on $SPOKE_RG failed (optional)."

# ----------------------------- workspace files -------------------------------
JUMP_IP=$(az vm show -g "$LAB_RG" -n vm-sapqa-jump01 -d --query privateIps -o tsv)
DB_IP=$(az vm show -g "$LAB_RG" -n vm-sapdb01 -d --query privateIps -o tsv)
SCS_IP=$(az vm show -g "$LAB_RG" -n vm-sapascs01 -d --query privateIps -o tsv)

WS="lab-workspace/LAB-EUS2-SAP01-X00"
mkdir -p "$WS"
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
echo "  Jump server : vm-sapqa-jump01  $JUMP_IP  (hub/snet-sapqa-mgmt)"
echo "  SAP DB sim  : vm-sapdb01       $DB_IP   (spoke/snet-sap-sim)"
echo "  SAP SCS sim : vm-sapascs01     $SCS_IP  (spoke/snet-sap-sim)"
echo "  SSH key     : $KEY"
echo "==================================================="
echo
echo "Next steps:"
echo "  1. Copy the SSH key and connect to the jump server:"
echo "       ssh -i $KEY $ADMIN_USER@$JUMP_IP"
echo "  2. Transfer the offline bundle (or, since this LAB jump server has"
echo "     outbound Azure access, you may run scripts/setup.sh online to save time)."
echo "  3. Copy the workspace to the framework on the jump server:"
echo "       scp -i $KEY -r $WS $ADMIN_USER@$JUMP_IP:~/sap-automation-qa/WORKSPACES/SYSTEM/"
echo "  4. On the jump server: set TEST_TYPE=ConfigurationChecks and"
echo "     SYSTEM_CONFIG_NAME=LAB-EUS2-SAP01-X00 in vars.yaml, then:"
echo "       az login --identity && ./scripts/sap_automation_qa.sh"
echo "  5. Expect SAP-level checks to fail (no real SAP installed) — the goal is"
echo "     a generated CONFIG_X00_HANA_*.html report proving the pipeline works."
