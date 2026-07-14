#!/bin/bash
# =============================================================================
# deploy-sap-sim-lab.sh
#
# Builds a LAB that replicates the customer environment:
#
#   HUB   vnet  -> "jump server" VM: RHEL 9, NO INTERNET (simulates on-prem),
#                  reachable via private connectivity (VPN/peering)
#   SPOKE vnet  -> 2 simulated "SAP" VMs: RHEL 8.10 + Python 3.6 (customer
#                  versions), NO INTERNET
#
# Matches the customer scenario: offline jump server runs the framework; SAP
# servers are only touched via read-only SSH. Purpose: validate the offline
# procedure end to end, including the offline-auth fix (LAB-FINDINGS issue 5)
# and the "zero changes on SAP servers" option (ansible-core 2.16 with
# Python 3.6 targets).
#
# Order of operations matters: the jump server is prepared (python3.11 etc.)
# WHILE it still has outbound access; only then are the deny-internet NSG
# rules applied to freeze the offline state.
#
# Non-interactive mode: AUTO=1 ./deploy-sap-sim-lab.sh
#
# Parallel isolated environments: set LAB_SUFFIX to spin a second lab that does
# not collide with the first, e.g.  LAB_SUFFIX=2 AUTO=1 ./deploy-sap-sim-lab.sh
# gives vm-sapqa-jump01-2, vm-sapdb01-2, subnets snet-sapqa-mgmt-2, etc.
#
# Requirements: az (logged in), python3, ssh-keygen.
# =============================================================================
set -euo pipefail

SFX="${LAB_SUFFIX:+-${LAB_SUFFIX}}"   # "" by default, "-2" if LAB_SUFFIX=2
JUMP_VM="vm-sapqa-jump01${SFX}"
DB_VM="vm-sapdb01${SFX}"
SCS_VM="vm-sapascs01${SFX}"
MGMT_SUBNET="snet-sapqa-mgmt${SFX}"
SIM_SUBNET="snet-sap-sim${SFX}"

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
# subscription first, then every other subscription you can access.
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

ask HUB_VNET   "Hub VNet name (hosts the simulated on-prem jump server)" "vnet-alz-hub-eastus2"
find_vnet "$HUB_VNET" || die "Hub VNet '$HUB_VNET' not found in any accessible subscription."
HUB_SUB="$FOUND_SUB"; HUB_RG="$FOUND_RG"
log "Hub VNet found: RG=$HUB_RG, subscription=$(az account show --subscription "$HUB_SUB" --query name -o tsv)"

ask SPOKE_VNET "Spoke VNet name (hosts the simulated SAP servers)" "vnet-migrate-spoke-eastus2"
find_vnet "$SPOKE_VNET" || die "Spoke VNet '$SPOKE_VNET' not found in any accessible subscription."
SPOKE_SUB="$FOUND_SUB"; SPOKE_RG="$FOUND_RG"
log "Spoke VNet found: RG=$SPOKE_RG, subscription=$(az account show --subscription "$SPOKE_SUB" --query name -o tsv)"

LOCATION=$(az network vnet show -g "$HUB_RG" -n "$HUB_VNET" --subscription "$HUB_SUB" --query location -o tsv)
# Azure requires VM/NIC to live in the SAME subscription as their VNet.
ask LAB_RG     "Base name for the lab resource groups" "rg-sapqa-lab${SFX}"
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
# Creates an NSG and a subnet with the NSG attached (landing zone policy).
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

create_subnet "$HUB_RG"   "$HUB_VNET"   "$MGMT_SUBNET" "$HUB_SUB"
create_subnet "$SPOKE_RG" "$SPOKE_VNET" "$SIM_SUBNET"  "$SPOKE_SUB"

# ----------------------------- ssh key ---------------------------------------
KEY=~/.ssh/sapqa_lab_key
if [[ ! -f "$KEY" ]]; then
    ssh-keygen -t rsa -b 4096 -N "" -f "$KEY" -C "sapqa-lab" >/dev/null
    log "Generated lab SSH keypair: $KEY"
fi

# ----------------------------- VM size auto-detection ------------------------
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

# ----------------------------- images (match the customer) -------------------
JUMP_IMAGE="RedHat:RHEL:9-lvm-gen2:latest"          # customer jump server: RHEL 9
SAP_IMAGE="RedHat:RHEL:810-gen2:latest"             # customer SAP servers: RHEL 8.10 (Python 3.6)
if ! az vm image show --urn "$SAP_IMAGE" -l "$LOCATION" >/dev/null 2>&1; then
    warn "Image $SAP_IMAGE not found — falling back to RedHat:RHEL:8-lvm-gen2:latest"
    SAP_IMAGE="RedHat:RHEL:8-lvm-gen2:latest"
fi
log "Jump image: $JUMP_IMAGE | SAP image: $SAP_IMAGE"

# ----------------------------- resource groups + VMs -------------------------
az group show -n "$MGMT_RG" --subscription "$HUB_SUB" >/dev/null 2>&1 || \
    az group create -n "$MGMT_RG" -l "$LOCATION" --subscription "$HUB_SUB" >/dev/null
az group show -n "$SAP_RG" --subscription "$SPOKE_SUB" >/dev/null 2>&1 || \
    az group create -n "$SAP_RG" -l "$LOCATION" --subscription "$SPOKE_SUB" >/dev/null

HUB_SUBNET_ID=$(az network vnet subnet show -g "$HUB_RG" --vnet-name "$HUB_VNET" -n "$MGMT_SUBNET" --subscription "$HUB_SUB" --query id -o tsv)
SIM_SUBNET_ID=$(az network vnet subnet show -g "$SPOKE_RG" --vnet-name "$SPOKE_VNET" -n "$SIM_SUBNET" --subscription "$SPOKE_SUB" --query id -o tsv)

# --nsg "" prevents az from auto-creating a NIC-level NSG (blocked by ALZ policy).
log "Creating jump server $JUMP_VM (RHEL 9, $VM_SIZE, no public IP) in $MGMT_RG..."
az vm create -g "$MGMT_RG" -n "$JUMP_VM" -l "$LOCATION" --subscription "$HUB_SUB" \
    --image "$JUMP_IMAGE" \
    --size "$VM_SIZE" --subnet "$HUB_SUBNET_ID" --public-ip-address "" \
    --nsg "" --admin-username "$ADMIN_USER" --ssh-key-values "$KEY.pub" \
    --output none

for VM in "$DB_VM" "$SCS_VM"; do
    log "Creating simulated SAP VM $VM (RHEL 8.10 / Python 3.6, $VM_SIZE, no public IP) in $SAP_RG..."
    az vm create -g "$SAP_RG" -n "$VM" -l "$LOCATION" --subscription "$SPOKE_SUB" \
        --image "$SAP_IMAGE" \
        --size "$VM_SIZE" --subnet "$SIM_SUBNET_ID" --public-ip-address "" \
        --nsg "" --admin-username "$ADMIN_USER" --ssh-key-values "$KEY.pub" --output none
done

# ----------------------------- jump server prep (LAB FINDING) ----------------
# FINDING (validated 2026-07-13): in an Azure Landing Zone, the hub subnet has
# NO outbound internet by default (default-outbound-access retirement + no NAT),
# so the jump server CANNOT reach Red Hat's RHUI to `dnf install python3.11`.
# The customer will hit the same wall — which is why python3.11 RPMs must travel
# INSIDE the offline bundle (see QUICKSTART / LAB-FINDINGS).
# For the LAB only, we attach a temporary NAT gateway to give the jump egress,
# install python3.11, then DETACH it to restore the offline state.
PIP_NAT="pip-nat${SFX}"; NAT_GW="nat-lab${SFX}"
log "Attaching a temporary NAT gateway so the jump can install python3.11..."
az network public-ip create -g "$MGMT_RG" -n "$PIP_NAT" -l "$LOCATION" --subscription "$HUB_SUB" \
    --sku Standard --allocation-method Static -o none
az network nat gateway create -g "$MGMT_RG" -n "$NAT_GW" -l "$LOCATION" --subscription "$HUB_SUB" \
    --public-ip-addresses "$PIP_NAT" --idle-timeout 10 -o none
NATID=$(az network nat gateway show -g "$MGMT_RG" -n "$NAT_GW" --subscription "$HUB_SUB" --query id -o tsv)
az network vnet subnet update -g "$HUB_RG" --vnet-name "$HUB_VNET" -n "$MGMT_SUBNET" \
    --subscription "$HUB_SUB" --nat-gateway "$NATID" -o none
sleep 30
log "Installing python3.11 + sshpass on the jump server..."
az vm run-command invoke -g "$MGMT_RG" -n "$JUMP_VM" --subscription "$HUB_SUB" \
    --command-id RunShellScript \
    --scripts "dnf install -y python3.11 python3.11-pip sshpass >/tmp/prep.log 2>&1; python3.11 --version; echo EXIT=\$?" \
    --query "value[0].message" -o tsv | tail -3

# ----------------------------- freeze the offline state ----------------------
# Detach the NAT gateway (jump loses egress again) and deny-internet on both
# subnets — the lab is now truly offline, mirroring the customer.
log "Detaching NAT and applying deny-internet-outbound (making the lab offline)..."
az network vnet subnet update -g "$HUB_RG" --vnet-name "$HUB_VNET" -n "$MGMT_SUBNET" \
    --subscription "$HUB_SUB" --remove natGateway -o none 2>/dev/null || true
az network nat gateway delete -g "$MGMT_RG" -n "$NAT_GW" --subscription "$HUB_SUB" 2>/dev/null || true
az network public-ip delete -g "$MGMT_RG" -n "$PIP_NAT" --subscription "$HUB_SUB" 2>/dev/null || true
az network nsg rule create -g "$HUB_RG" --nsg-name "nsg-${MGMT_SUBNET}" --subscription "$HUB_SUB" \
    -n Deny-Internet-Outbound --priority 4000 --direction Outbound --access Deny \
    --protocol '*' --destination-address-prefixes Internet --destination-port-ranges '*' \
    --output none 2>/dev/null || warn "Deny rule on mgmt NSG may already exist."
az network nsg rule create -g "$SPOKE_RG" --nsg-name "nsg-${SIM_SUBNET}" --subscription "$SPOKE_SUB" \
    -n Deny-Internet-Outbound --priority 4000 --direction Outbound --access Deny \
    --protocol '*' --destination-address-prefixes Internet --destination-port-ranges '*' \
    --output none 2>/dev/null || warn "Deny rule on sim NSG may already exist."

# ----------------------------- workspace files -------------------------------
JUMP_IP=$(az vm show -g "$MGMT_RG" -n "$JUMP_VM" -d --subscription "$HUB_SUB" --query privateIps -o tsv)
DB_IP=$(az vm show -g "$SAP_RG" -n "$DB_VM" -d --subscription "$SPOKE_SUB" --query privateIps -o tsv)
SCS_IP=$(az vm show -g "$SAP_RG" -n "$SCS_VM" -d --subscription "$SPOKE_SUB" --query privateIps -o tsv)

WS="lab-workspace/LAB-EUS2-SAP01-X00${SFX}"
mkdir -p "$WS"
# NOTE: no ansible_python_interpreter here on purpose — the SAP sims keep the
# customer's Python 3.6, to validate the "ansible-core 2.16, zero changes on
# SAP servers" option. If that test fails, uncomment the interpreter lines and
# install python3.11 on the SAP sims (LAB-FINDINGS issue 1 / option A).
cat > "$WS/hosts.yaml" <<EOF
X00_DB:
  hosts:
    ${DB_VM}:
      ansible_host: "$DB_IP"
      ansible_user: "$ADMIN_USER"
      ansible_connection: "ssh"
      connection_type: "key"
      virtual_host: "${DB_VM}"
      become_user: "root"
      os_type: "linux"
      # ansible_python_interpreter: "/usr/bin/python3.11"   # option A only
      vm_name: "${DB_VM}"
  vars:
    node_tier: "hana"
X00_SCS:
  hosts:
    ${SCS_VM}:
      ansible_host: "$SCS_IP"
      ansible_user: "$ADMIN_USER"
      ansible_connection: "ssh"
      connection_type: "key"
      virtual_host: "${SCS_VM}"
      become_user: "root"
      os_type: "linux"
      # ansible_python_interpreter: "/usr/bin/python3.11"   # option A only
      vm_name: "${SCS_VM}"
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
echo "==================== OFFLINE LAB READY ===================="
echo "  Jump server : $JUMP_VM  $JUMP_IP  RHEL 9, NO internet (simulated on-prem)"
echo "  SAP DB sim  : $DB_VM     $DB_IP   RHEL 8.10 / Python 3.6, NO internet"
echo "  SAP SCS sim : $SCS_VM   $SCS_IP  RHEL 8.10 / Python 3.6, NO internet"
echo "  SSH key     : $KEY"
echo "  Workspace   : $WS"
echo "==========================================================="
echo
echo "Next steps (mirrors the customer QUICKSTART):"
echo "  1. From your laptop (via VPN): ssh -i $KEY $ADMIN_USER@$JUMP_IP"
echo "  2. Build the bundle on your laptop/WSL (QUICKSTART Step 2). Include the"
echo "     ansible-core 2.16 constraint to test the zero-SAP-changes option:"
echo "       echo 'ansible-core<2.17' > constraints.txt"
echo "       python3 -m pip download -r sap-automation-qa/requirements.in -c constraints.txt \\"
echo "         -d wheels/ --platform manylinux2014_x86_64 --python-version 3.11 --only-binary=:all:"
echo "  3. scp the bundle to the jump server, install offline (QUICKSTART Step 4),"
echo "     apply fixes, copy this workspace:"
echo "       scp -i $KEY -r $WS $ADMIN_USER@$JUMP_IP:~/sap-automation-qa/WORKSPACES/SYSTEM/"
echo "  4. Run WITHOUT any az login — this validates LAB-FINDINGS issue 5."
echo "  5. Expect: OS/SAP checks run, Azure checks error, report generated."
echo
echo "Delete this lab when done:"
echo "  az group delete -n $MGMT_RG --subscription $HUB_SUB --yes --no-wait"
echo "  az group delete -n $SAP_RG --subscription $SPOKE_SUB --yes --no-wait"
