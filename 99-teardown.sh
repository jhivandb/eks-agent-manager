#!/usr/bin/env bash
# Destroys everything 01-04 created, in dependency order.
#
# Order matters for two reasons AWS will not warn you about: LoadBalancer
# Services must be gone before the VPC can be deleted, and the RDS security
# group must be gone before eksctl can delete the VPC that holds it.
#
# Usage: ./99-teardown.sh [--keep-db] [--snapshot] [--yes]

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

KEEP_DB=false
FINAL_SNAPSHOT=false
ASSUME_YES=false
for arg in "$@"; do
  case "$arg" in
    --keep-db)  KEEP_DB=true ;;
    --snapshot) FINAL_SNAPSHOT=true ;;
    --yes)      ASSUME_YES=true ;;
    *) die "unknown flag: $arg" ;;
  esac
done

cat <<BANNER

This deletes, permanently:
  - EKS cluster ${CLUSTER_NAME} (${AWS_REGION}) and its VPC, nodes and volumes
  - every Helm release and namespace the platform installed
$($KEEP_DB && echo "  - RDS instance ${DB_INSTANCE_ID} will be KEPT" \
             || echo "  - RDS instance ${DB_INSTANCE_ID} and all four databases")
$($FINAL_SNAPSHOT && echo "  - a final RDS snapshot will be taken first" || true)
  - the Route 53 gateway records under ${BASE_DOMAIN}, if any

Agent Manager and Thunder data is NOT recoverable without a snapshot.

BANNER

if ! $ASSUME_YES; then
  read -r -p "Type the cluster name (${CLUSTER_NAME}) to proceed: " confirm
  [[ "$confirm" == "${CLUSTER_NAME}" ]] || die "aborted"
fi

cluster_reachable() {
  aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1 \
    && kubectl cluster-info >/dev/null 2>&1
}

if cluster_reachable; then
  log "Deleting plane registrations"
  kubectl delete clusterdataplane default -n default --ignore-not-found
  kubectl delete clusterworkflowplane default -n default --ignore-not-found
  kubectl delete clusterobservabilityplane default --ignore-not-found

  log "Uninstalling Helm releases"
  # Reverse install order; every one is optional because teardown must work
  # from a partially-installed cluster too.
  uninstall() { helm uninstall "$1" -n "$2" --ignore-not-found --wait --timeout 5m 2>/dev/null || warn "could not uninstall $1"; }
  # Per-environment gateway halves and env-Thunder releases, discovered
  # dynamically (07-add-environment.sh creates a pair + one Thunder per env).
  # Gateway releases must go while the gateway-operator is still running, or
  # their APIGateway finalizers hang the namespace deletion below. The
  # operator-generated *-gw child releases are skipped: uninstalling the
  # parent tears them down.
  helm list -A -o json 2>/dev/null \
    | jq -r '.[] | select(
        ((.name | startswith("api-platform-")) and (.name | endswith("-gw") | not)) or
        ((.name | startswith("amp-thunder-")) and .name != "amp-thunder-extension")
      ) | "\(.name) \(.namespace)"' \
    | while read -r rel ns; do uninstall "$rel" "$ns"; done
  uninstall amp-evaluation-extension       "${BUILD_CI_NS}"
  uninstall amp-observability-traces        "${OBSERVABILITY_NS}"
  uninstall amp-platform-resources          "${DEFAULT_NS}"
  uninstall agent-sandbox                   "${DATA_PLANE_NS}"
  uninstall amp                             "${AMP_NS}"
  uninstall gateway-operator                "${DATA_PLANE_NS}"
  uninstall amp-thunder-extension           "${THUNDER_NS}"
  uninstall observability-traces-opensearch  "${OBSERVABILITY_NS}"
  uninstall observability-metrics-prometheus "${OBSERVABILITY_NS}"
  uninstall observability-logs-opensearch    "${OBSERVABILITY_NS}"
  uninstall openchoreo-observability-plane   "${OBSERVABILITY_NS}"
  uninstall openchoreo-workflow-plane        "${BUILD_CI_NS}"
  uninstall openchoreo-data-plane            "${DATA_PLANE_NS}"
  uninstall openchoreo-control-plane         "${CONTROL_PLANE_NS}"
  uninstall kgateway                         "${CONTROL_PLANE_NS}"
  uninstall kgateway-crds                    "${CONTROL_PLANE_NS}"
  uninstall openbao                          openbao
  uninstall external-secrets                 external-secrets
  uninstall cert-manager                     cert-manager

  log "Deleting any remaining LoadBalancer Services"
  # eksctl cannot delete the VPC while an ELB still holds an ENI in it.
  kubectl get svc -A -o json \
    | jq -r '.items[] | select(.spec.type=="LoadBalancer") | "\(.metadata.namespace) \(.metadata.name)"' \
    | while read -r ns name; do
        [[ -n "$ns" ]] && kubectl delete svc "$name" -n "$ns" --ignore-not-found
      done

  log "Deleting namespaces (this releases the EBS volumes behind every PVC)"
  # Per-environment namespaces are discovered, not hardcoded: gateway halves
  # carry the label 07-add-environment.sh stamps; env-Thunder namespaces are
  # amp-thunder-<org>-<env>. Each holds a PVC that would otherwise orphan an
  # EBS volume.
  ENV_NS="$( { kubectl get ns -l amp.wso2.com/api-platform-gateway=true -o name 2>/dev/null;
               kubectl get ns -o name 2>/dev/null | grep '/amp-thunder-'; } \
             | sed 's|namespace/||' | sort -u | tr '\n' ' ')"
  # shellcheck disable=SC2086  # ENV_NS is a space-separated namespace list
  kubectl delete namespace \
    "${AMP_NS}" "${THUNDER_NS}" \
    "${OBSERVABILITY_NS}" "${BUILD_CI_NS}" "${DATA_PLANE_NS}" "${CONTROL_PLANE_NS}" \
    "${REGISTRY_NS}" openbao external-secrets cert-manager agent-sandbox-system \
    ${ENV_NS} \
    --ignore-not-found --timeout=10m || warn "some namespaces did not finish deleting"

  log "Waiting for load balancers to disappear from the VPC"
  VPC_ID="$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
    --query 'cluster.resourcesVpcConfig.vpcId' --output text 2>/dev/null || true)"
  for _ in $(seq 1 30); do
    remaining="$(aws elb describe-load-balancers --region "${AWS_REGION}" \
      --query "length(LoadBalancerDescriptions[?VPCId=='${VPC_ID}'])" --output text 2>/dev/null || echo 0)"
    remaining_v2="$(aws elbv2 describe-load-balancers --region "${AWS_REGION}" \
      --query "length(LoadBalancers[?VpcId=='${VPC_ID}'])" --output text 2>/dev/null || echo 0)"
    [[ "$remaining" == "0" && "$remaining_v2" == "0" ]] && break
    echo "  ${remaining} classic + ${remaining_v2} v2 still present..."
    sleep 20
  done
else
  warn "Cluster not reachable — skipping in-cluster teardown."
  VPC_ID="$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
    --query 'cluster.resourcesVpcConfig.vpcId' --output text 2>/dev/null || true)"
fi

if [[ "${ROUTE53_ZONE_ID}" != "__SET_ME__" && -n "${ROUTE53_ZONE_ID}" ]]; then
  log "Deleting Route 53 records under ${BASE_DOMAIN}"
  aws route53 list-resource-record-sets --hosted-zone-id "${ROUTE53_ZONE_ID}" \
    --query "ResourceRecordSets[?Type=='CNAME' || Type=='A']" --output json 2>/dev/null \
    | jq -c --arg base "${BASE_DOMAIN}" \
        '[.[] | select(.Name | test("\\." + ($base | gsub("\\."; "\\.")) + "\\.$"))]' \
    | jq -c '.[]' 2>/dev/null \
    | while read -r rrset; do
        name="$(echo "$rrset" | jq -r .Name)"
        echo "  deleting ${name}"
        aws route53 change-resource-record-sets --hosted-zone-id "${ROUTE53_ZONE_ID}" \
          --change-batch "$(jq -n --argjson rr "$rrset" \
             '{Changes:[{Action:"DELETE",ResourceRecordSet:$rr}]}')" >/dev/null 2>&1 \
          || warn "could not delete ${name}"
      done
fi

if ! $KEEP_DB; then
  if aws rds describe-db-instances --db-instance-identifier "${DB_INSTANCE_ID}" \
       --region "${AWS_REGION}" >/dev/null 2>&1; then
    log "Deleting RDS instance ${DB_INSTANCE_ID}"
    if $FINAL_SNAPSHOT; then
      snap="${DB_INSTANCE_ID}-final-$(aws sts get-caller-identity --query Account --output text)-$RANDOM"
      aws rds delete-db-instance --region "${AWS_REGION}" \
        --db-instance-identifier "${DB_INSTANCE_ID}" \
        --final-db-snapshot-identifier "${snap}" >/dev/null
      echo "  final snapshot: ${snap}"
    else
      aws rds delete-db-instance --region "${AWS_REGION}" \
        --db-instance-identifier "${DB_INSTANCE_ID}" \
        --skip-final-snapshot --delete-automated-backups >/dev/null
    fi
    log "Waiting for the instance to finish deleting (~5 min)"
    aws rds wait db-instance-deleted --db-instance-identifier "${DB_INSTANCE_ID}" --region "${AWS_REGION}"
  fi

  aws rds delete-db-subnet-group --region "${AWS_REGION}" \
    --db-subnet-group-name "${CLUSTER_NAME}-db" >/dev/null 2>&1 || true
  aws rds delete-db-parameter-group --region "${AWS_REGION}" \
    --db-parameter-group-name "${CLUSTER_NAME}-pg17" >/dev/null 2>&1 || true

  # Must go before eksctl deletes the VPC that contains it.
  if [[ -n "${VPC_ID}" && "${VPC_ID}" != "None" ]]; then
    SG_ID="$(aws ec2 describe-security-groups --region "${AWS_REGION}" \
      --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=${CLUSTER_NAME}-db-sg" \
      --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo None)"
    [[ "${SG_ID}" != "None" && -n "${SG_ID}" ]] && \
      aws ec2 delete-security-group --group-id "${SG_ID}" --region "${AWS_REGION}" 2>/dev/null \
      || true
  fi
else
  warn "Keeping RDS instance ${DB_INSTANCE_ID}. Its security group blocks VPC deletion,"
  warn "so eksctl will fail below — move the instance to another VPC or drop --keep-db."
fi

log "Deleting the EKS cluster (~15 min)"
eksctl delete cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" --disable-nodegroup-eviction --wait \
  || warn "eksctl reported errors — check for leftovers below"

log "Deleting the cert-manager Route 53 IAM policy"
# eksctl removes the IRSA role with the cluster, but not this customer-managed
# policy, which would block a same-named policy on the next run.
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${CLUSTER_NAME}-cert-manager-route53"
if aws iam get-policy --policy-arn "${POLICY_ARN}" >/dev/null 2>&1; then
  for v in $(aws iam list-policy-versions --policy-arn "${POLICY_ARN}" \
               --query 'Versions[?!IsDefaultVersion].VersionId' --output text); do
    aws iam delete-policy-version --policy-arn "${POLICY_ARN}" --version-id "$v" 2>/dev/null || true
  done
  aws iam delete-policy --policy-arn "${POLICY_ARN}" 2>/dev/null \
    || warn "could not delete ${POLICY_ARN} — it may still be attached"
fi

log "Checking for orphaned resources you would otherwise keep paying for"
if [[ -n "${VPC_ID}" && "${VPC_ID}" != "None" ]]; then
  echo "Available ENIs in ${VPC_ID} (Cilium allocates these; they should be gone):"
  aws ec2 describe-network-interfaces --region "${AWS_REGION}" \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=status,Values=available" \
    --query 'NetworkInterfaces[].NetworkInterfaceId' --output text || true
fi
echo "Unattached EBS volumes tagged for this cluster:"
aws ec2 describe-volumes --region "${AWS_REGION}" \
  --filters "Name=status,Values=available" \
            "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
  --query 'Volumes[].{Id:VolumeId,GiB:Size}' --output table 2>/dev/null || true
echo "Any remaining CloudFormation stacks:"
aws cloudformation describe-stacks --region "${AWS_REGION}" \
  --query "Stacks[?contains(StackName,'${CLUSTER_NAME}')].{Name:StackName,Status:StackStatus}" \
  --output table 2>/dev/null || true

log "Teardown complete. Secrets remain in ${SECRETS_DIR} — delete them if you are done."
