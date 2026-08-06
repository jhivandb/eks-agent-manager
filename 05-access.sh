#!/usr/bin/env bash
# Toggle public exposure of the platform's internet-facing endpoints.
#
#   ./05-access.sh vpn      restrict to WSO2 VPN egress CIDRs (vpn.env) + NAT EIP(s)
#   ./05-access.sh public   restore unrestricted access
#
# Covers the three plane gateways (gateway-default), plus two more PUBLIC load
# balancers found on inspection: the Thunder extension gateway (:8443) and the
# observability Prometheus — both as internet-facing as the gateways, so vpn
# mode without them would be a fence with two open gates. The registry LB is
# internal and untouched. vpn mode also restricts the EKS API endpoint.
#
# Mechanism: spec.loadBalancerSourceRanges patched directly onto the Services;
# the AWS cloud controller maintains the LB security-group rules from it. Five
# of these Services are created by kgateway from Gateway resources, so a direct
# patch looked doomed to be reverted — tested on kgateway v2.2.1 and it is not:
# the field survived a passive wait, a forced Gateway reconcile, and a full
# kgateway controller restart. The deployer applies with server-side apply and
# never claims spec.loadBalancerSourceRanges, so its applies leave the field
# alone. GatewayParameters was the fallback and offers no such field anyway
# (only extraAnnotations), so the direct patch is both the durable and the
# simple path. The patch IS lost if a Service is deleted and recreated (Gateway
# or chart reinstall) — re-run this script afterwards.
#
# THE HAIRPIN TRAP: in-cluster components call the platform's PUBLIC hostnames
# (Thunder token/JWKS calls, observer, agent trace export), looping out through
# the VPC's NAT gateway and back in via the public LBs. vpn mode therefore
# always appends the NAT gateway's Elastic IP(s) to the allowlist — without
# them the platform silently breaks itself while every pod looks healthy.
#
# The EKS API allowlist additionally includes this machine's current public IP,
# so a mistake in vpn.env cannot lock the operator out of kubectl.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

kubeconfig_points_at_cluster

MODE="${1:-}"
case "${MODE}" in
  public|vpn) ;;
  *) die "usage: $0 {public|vpn}" ;;
esac

TARGETS=(
  "${CONTROL_PLANE_NS}/gateway-default"
  "${DATA_PLANE_NS}/gateway-default"
  "${OBSERVABILITY_NS}/gateway-default"
  "${CONTROL_PLANE_NS}/amp-thunder-extension-https-gateway"
  "${OBSERVABILITY_NS}/openchoreo-observability-prometheus"
)

CIDR_RE='^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$'

nat_gateway_eips() {
  local vpc_id eips
  vpc_id="$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
    --query 'cluster.resourcesVpcConfig.vpcId' --output text)"
  eips="$(aws ec2 describe-nat-gateways --region "${AWS_REGION}" \
    --filter "Name=vpc-id,Values=${vpc_id}" "Name=state,Values=available" \
    --query 'NatGateways[].NatGatewayAddresses[].PublicIp' --output text | tr '\t' '\n' | sort -u)"
  [[ -n "${eips}" ]] || die "no available NAT gateway in ${vpc_id} — cannot allowlist in-cluster hairpin traffic"
  echo "${eips}"
}

my_public_ip() {
  local ip
  ip="$(curl -fsS --max-time 10 https://checkip.amazonaws.com | tr -d '[:space:]')"
  [[ "${ip}/32" =~ ${CIDR_RE} ]] || die "could not determine this machine's public IP (got '${ip}')"
  echo "${ip}"
}

patch_services() {
  local patch="$1"
  for t in "${TARGETS[@]}"; do
    kubectl patch svc "${t#*/}" -n "${t%%/*}" --type=merge -p "${patch}" >/dev/null
    echo "  ${t}"
  done
}

# Idempotent: compares before calling update-cluster-config, because EKS
# rejects a no-op update with InvalidParameterException.
set_eks_public_cidrs() {
  local desired_sorted current update_id status
  desired_sorted="$(printf '%s\n' "$@" | sort -u)"
  current="$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
    --query 'cluster.resourcesVpcConfig.publicAccessCidrs' --output text | tr '\t' '\n' | sort -u)"
  if [[ "${current}" == "${desired_sorted}" ]]; then
    echo "  EKS API endpoint already set — skipping"
    return 0
  fi

  warn "================================================================"
  warn "About to change the EKS API endpoint allowlist for ${CLUSTER_NAME}:"
  warn "$(echo "${desired_sorted}" | paste -sd' ' -)"
  warn "kubectl access from anywhere else will stop working."
  warn "Ctrl-C within 5 seconds to abort."
  warn "================================================================"
  sleep 5

  update_id="$(aws eks update-cluster-config --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
    --resources-vpc-config "publicAccessCidrs=$(echo "${desired_sorted}" | paste -sd, -)" \
    --query 'update.id' --output text)"
  echo "  cluster update ${update_id} in progress..."
  for _ in $(seq 1 80); do
    status="$(aws eks describe-update --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
      --update-id "${update_id}" --query 'update.status' --output text)"
    case "${status}" in
      Successful) echo "  cluster update finished"; return 0 ;;
      Failed|Cancelled) die "EKS cluster update ${update_id} ended ${status}" ;;
    esac
    sleep 15
  done
  die "EKS cluster update ${update_id} still ${status} after 20 minutes"
}

join_or_open() {
  if [[ -z "$1" ]]; then echo "(open)"; else echo "$1" | paste -sd, -; fi
}

# Reads back spec.loadBalancerSourceRanges AND the inbound TCP CIDRs on the
# LB's actual security group. expected="" means unrestricted (empty spec, SG
# showing 0.0.0.0/0). SG propagation by the cloud controller can lag a minute,
# so mismatches are polled before being reported.
verify_access() {
  local expected="$1" want_sg="$1"
  if [[ -z "${want_sg}" ]]; then want_sg="0.0.0.0/0"; fi

  local attempt all_ok spec sg host lb_name sg_ids status rows
  for attempt in $(seq 1 7); do
    all_ok=1
    rows=""
    for t in "${TARGETS[@]}"; do
      spec="$(kubectl get svc "${t#*/}" -n "${t%%/*}" -o json \
        | jq -r '.spec.loadBalancerSourceRanges[]?' | sort -u)"
      host="$(kubectl get svc "${t#*/}" -n "${t%%/*}" \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
      lb_name="${host%%-*}"
      sg="(lookup failed)"
      if sg_ids="$(aws elb describe-load-balancers --region "${AWS_REGION}" \
          --load-balancer-names "${lb_name}" \
          --query 'LoadBalancerDescriptions[0].SecurityGroups' --output text 2>/dev/null)"; then
        # shellcheck disable=SC2086  # sg_ids is a space-separated id list
        sg="$(aws ec2 describe-security-groups --region "${AWS_REGION}" --group-ids ${sg_ids} \
          --output json | jq -r '.SecurityGroups[].IpPermissions[]
            | select(.IpProtocol=="tcp") | .IpRanges[].CidrIp' | sort -u)"
      fi
      status="OK"
      if [[ "${spec}" != "${expected}" || "${sg}" != "${want_sg}" ]]; then
        status="MISMATCH"
        all_ok=0
      fi
      rows+="$(printf '  %-62s %-9s spec=%s sg=%s' "${t}" "${status}" \
        "$(join_or_open "${spec}")" "$(join_or_open "${sg}")")"$'\n'
    done
    if (( all_ok )); then break; fi
    if (( attempt < 7 )); then sleep 15; fi
  done

  printf '%s' "${rows}"
  echo "  EKS API publicAccessCidrs: $(aws eks describe-cluster --name "${CLUSTER_NAME}" \
    --region "${AWS_REGION}" --query 'cluster.resourcesVpcConfig.publicAccessCidrs' \
    --output text | tr '\t' ',')"
  if (( ! all_ok )); then
    warn "Service spec and LB security group disagree after ~90s of polling — the cloud controller may be wedged; check its logs and re-run"
  fi
  return 0
}

if [[ "${MODE}" == "vpn" ]]; then
  if [[ ! -f "${SCRIPT_DIR}/vpn.env" ]]; then
    die "vpn.env not found. Get the VPN's public egress ranges from WSO2 IT and create ${SCRIPT_DIR}/vpn.env containing:
  export VPN_CIDRS=\"x.x.x.x/32 y.y.y.y/24\""
  fi
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/vpn.env"
  [[ -n "${VPN_CIDRS:-}" ]] || die "vpn.env does not set VPN_CIDRS"
  for c in ${VPN_CIDRS}; do
    [[ "${c}" =~ ${CIDR_RE} ]] || die "malformed CIDR in vpn.env: '${c}'"
  done

  log "Discovering NAT gateway EIPs (in-cluster hairpin traffic egresses through these)"
  NAT_EIPS="$(nat_gateway_eips)"
  echo "  $(echo "${NAT_EIPS}" | paste -sd' ' -)"

  mapfile -t LB_RANGES < <({ printf '%s\n' ${VPN_CIDRS}; echo "${NAT_EIPS}" | sed 's|$|/32|'; } | sort -u)

  log "Restricting ${#TARGETS[@]} load balancers to: ${LB_RANGES[*]}"
  patch_services "$(jq -cn '{spec:{loadBalancerSourceRanges:$ARGS.positional}}' --args "${LB_RANGES[@]}")"

  log "Restricting the EKS API endpoint"
  MY_IP="$(my_public_ip)"
  echo "  including this machine's ${MY_IP}/32 as a lockout guard"
  EKS_CIDRS=(${VPN_CIDRS} "${MY_IP}/32")
  # Nodes only need this if they reach the API over the public endpoint.
  if [[ "$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
      --query 'cluster.resourcesVpcConfig.endpointPrivateAccess' --output text)" != "True" ]]; then
    warn "endpointPrivateAccess is off — adding NAT EIPs so the nodes keep API access"
    mapfile -t -O "${#EKS_CIDRS[@]}" EKS_CIDRS < <(echo "${NAT_EIPS}" | sed 's|$|/32|')
  fi
  set_eks_public_cidrs "${EKS_CIDRS[@]}"

  log "Verifying"
  verify_access "$(printf '%s\n' "${LB_RANGES[@]}")"
  log "Platform locked to the VPN. Run './05-access.sh public' to undo."
else
  log "Removing source-range restrictions from ${#TARGETS[@]} load balancers"
  patch_services '{"spec":{"loadBalancerSourceRanges":null}}'

  log "Opening the EKS API endpoint"
  set_eks_public_cidrs "0.0.0.0/0"

  log "Verifying"
  verify_access ""
  log "Platform is publicly reachable."
fi
