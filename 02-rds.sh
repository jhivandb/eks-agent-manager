#!/usr/bin/env bash
# Creates the RDS PostgreSQL instance and the four databases the platform needs:
# agentmanager (Agent Manager) and configdb/runtimedb/userdb (Thunder).
#
# The instance is private to the cluster VPC, so every psql call runs from a
# throwaway pod inside the cluster rather than from this machine. Thunder's
# schema files are extracted locally with docker — the image has no shell, so
# docker cp is the only way to read them out.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

command -v docker >/dev/null || die "docker is needed to extract Thunder's schema files"
kubeconfig_points_at_cluster

THUNDER_IMAGE="ghcr.io/thunder-id/thunderid:0.45.0"
PG_CLIENT_IMAGE="public.ecr.aws/docker/library/postgres:17"
PARAM_GROUP="${CLUSTER_NAME}-pg17"
SUBNET_GROUP="${CLUSTER_NAME}-db"
SG_NAME="${CLUSTER_NAME}-db-sg"

log "Locating the cluster VPC and its private subnets"
VPC_ID="$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)"
VPC_CIDR="$(aws ec2 describe-vpcs --vpc-ids "${VPC_ID}" --region "${AWS_REGION}" \
  --query 'Vpcs[0].CidrBlock' --output text)"
mapfile -t PRIVATE_SUBNETS < <(aws ec2 describe-subnets --region "${AWS_REGION}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag-key,Values=kubernetes.io/role/internal-elb" \
  --query 'Subnets[].SubnetId' --output text | tr '\t' '\n')
(( ${#PRIVATE_SUBNETS[@]} >= 2 )) || die "Need at least 2 private subnets, found ${#PRIVATE_SUBNETS[@]}"
echo "VPC ${VPC_ID} (${VPC_CIDR}), private subnets: ${PRIVATE_SUBNETS[*]}"

log "Creating DB subnet group"
aws rds create-db-subnet-group --region "${AWS_REGION}" \
  --db-subnet-group-name "${SUBNET_GROUP}" \
  --db-subnet-group-description "${CLUSTER_NAME} private subnets" \
  --subnet-ids "${PRIVATE_SUBNETS[@]}" >/dev/null 2>&1 \
  || warn "subnet group ${SUBNET_GROUP} already exists"

log "Creating security group allowing 5432 from inside the VPC only"
SG_ID="$(aws ec2 describe-security-groups --region "${AWS_REGION}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=${SG_NAME}" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)"
if [[ "${SG_ID}" == "None" || -z "${SG_ID}" ]]; then
  SG_ID="$(aws ec2 create-security-group --region "${AWS_REGION}" \
    --group-name "${SG_NAME}" --description "${CLUSTER_NAME} RDS access" \
    --vpc-id "${VPC_ID}" --query 'GroupId' --output text)"
  aws ec2 authorize-security-group-ingress --region "${AWS_REGION}" \
    --group-id "${SG_ID}" --protocol tcp --port 5432 --cidr "${VPC_CIDR}" >/dev/null
fi
echo "Security group: ${SG_ID}"

log "Creating parameter group with rds.force_ssl=1"
# Enforced server-side so a client cannot silently downgrade to plaintext.
aws rds create-db-parameter-group --region "${AWS_REGION}" \
  --db-parameter-group-name "${PARAM_GROUP}" \
  --db-parameter-group-family postgres17 \
  --description "${CLUSTER_NAME} force TLS" >/dev/null 2>&1 \
  || warn "parameter group ${PARAM_GROUP} already exists"
aws rds modify-db-parameter-group --region "${AWS_REGION}" \
  --db-parameter-group-name "${PARAM_GROUP}" \
  --parameters "ParameterName=rds.force_ssl,ParameterValue=1,ApplyMethod=pending-reboot" >/dev/null

if aws rds describe-db-instances --db-instance-identifier "${DB_INSTANCE_ID}" \
     --region "${AWS_REGION}" >/dev/null 2>&1; then
  warn "RDS instance ${DB_INSTANCE_ID} already exists — skipping creation."
else
  log "Creating RDS instance (~10 min)"
  aws rds create-db-instance --region "${AWS_REGION}" \
    --db-instance-identifier "${DB_INSTANCE_ID}" \
    --db-instance-class "${DB_INSTANCE_CLASS}" \
    --engine postgres \
    --engine-version "${DB_ENGINE_VERSION}" \
    --master-username "${DB_MASTER_USER}" \
    --master-user-password "${DB_MASTER_PASSWORD}" \
    --allocated-storage "${DB_STORAGE_GB}" \
    --storage-type gp3 \
    --storage-encrypted \
    --db-subnet-group-name "${SUBNET_GROUP}" \
    --vpc-security-group-ids "${SG_ID}" \
    --db-parameter-group-name "${PARAM_GROUP}" \
    --no-publicly-accessible \
    --no-multi-az \
    --backup-retention-period 1 \
    --copy-tags-to-snapshot \
    --tags "Key=project,Value=agent-manager-eval" >/dev/null
fi

log "Waiting for the instance to become available"
aws rds wait db-instance-available --db-instance-identifier "${DB_INSTANCE_ID}" --region "${AWS_REGION}"

DB_HOST="$(aws rds describe-db-instances --db-instance-identifier "${DB_INSTANCE_ID}" \
  --region "${AWS_REGION}" --query 'DBInstances[0].Endpoint.Address' --output text)"
echo "export DB_HOST=\"${DB_HOST}\"" > "${SECRETS_DIR}/db-endpoint.env"
chmod 600 "${SECRETS_DIR}/db-endpoint.env"
echo "Endpoint: ${DB_HOST}"

log "Extracting Thunder's schema from ${THUNDER_IMAGE}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"; docker rm -f thunder-schema >/dev/null 2>&1 || true' EXIT
docker rm -f thunder-schema >/dev/null 2>&1 || true
docker create --name thunder-schema "${THUNDER_IMAGE}" >/dev/null
for db in ${THUNDER_DBS}; do
  docker cp "thunder-schema:/opt/thunderid/dbscripts/${db}/postgres.sql" "${WORK_DIR}/thunder-${db}.sql"
done
docker rm thunder-schema >/dev/null

log "Starting an in-cluster psql pod (RDS is not reachable from this machine)"
kubectl delete pod pgclient --ignore-not-found --wait=true >/dev/null 2>&1 || true
kubectl run pgclient --image="${PG_CLIENT_IMAGE}" --restart=Never \
  --command -- sleep 3600 >/dev/null
kubectl wait --for=condition=Ready pod/pgclient --timeout=300s

psql_master() {
  kubectl exec -i pgclient -- env PGPASSWORD="${DB_MASTER_PASSWORD}" \
    psql "postgresql://${DB_MASTER_USER}@${DB_HOST}:5432/postgres?sslmode=require" \
    -v ON_ERROR_STOP=1 "$@"
}

log "Creating roles and databases"
# Idempotent: re-running must not fail on objects that already exist, and must
# not reset a password the platform is already using.
psql_master <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${AMP_DB_USER}') THEN
    CREATE ROLE ${AMP_DB_USER} LOGIN PASSWORD '${AMP_DB_PASSWORD}';
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${THUNDER_DB_USER}') THEN
    CREATE ROLE ${THUNDER_DB_USER} LOGIN PASSWORD '${THUNDER_DB_PASSWORD}';
  END IF;
END \$\$;
-- The RDS master user is not a superuser: since PostgreSQL 16 it can only
-- CREATE DATABASE ... OWNER <role> if it can SET ROLE to that role, which
-- means being granted membership. Re-granting is a harmless no-op.
GRANT ${AMP_DB_USER} TO CURRENT_USER;
GRANT ${THUNDER_DB_USER} TO CURRENT_USER;
SQL

create_db_if_absent() {
  local name="$1" owner="$2"
  if [[ "$(psql_master -tAc "SELECT 1 FROM pg_database WHERE datname='${name}'")" != "1" ]]; then
    psql_master -c "CREATE DATABASE ${name} OWNER ${owner}"
  else
    warn "database ${name} already exists"
  fi
}
create_db_if_absent "${AMP_DB_NAME}" "${AMP_DB_USER}"
for db in ${THUNDER_DBS}; do create_db_if_absent "${db}" "${THUNDER_DB_USER}"; done

log "Loading Thunder's schema into each of its three databases"
# The chart's init container only initialises the bundled SQLite files. Against
# an empty PostgreSQL the pre-install hook fails with a misleading timeout.
for db in ${THUNDER_DBS}; do
  kubectl cp "${WORK_DIR}/thunder-${db}.sql" "pgclient:/tmp/thunder-${db}.sql"
  kubectl exec -i pgclient -- env PGPASSWORD="${THUNDER_DB_PASSWORD}" \
    psql "postgresql://${THUNDER_DB_USER}@${DB_HOST}:5432/${db}?sslmode=require" \
    -v ON_ERROR_STOP=1 -q -f "/tmp/thunder-${db}.sql"
done

log "Table counts — expected: configdb 17, runtimedb 8, userdb 5"
for db in ${THUNDER_DBS}; do
  count="$(kubectl exec -i pgclient -- env PGPASSWORD="${THUNDER_DB_PASSWORD}" \
    psql "postgresql://${THUNDER_DB_USER}@${DB_HOST}:5432/${db}?sslmode=require" \
    -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'")"
  printf '  %-12s %s\n' "${db}:" "${count}"
done

kubectl delete pod pgclient --wait=false

log "Creating the database credential Secrets the charts reference"
for ns in "${THUNDER_NS}" "${AMP_NS}"; do
  kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f -
done
kubectl create secret generic thunder-db-credentials -n "${THUNDER_NS}" \
  --from-literal=password="${THUNDER_DB_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic amp-db-credentials -n "${AMP_NS}" \
  --from-literal=password="${AMP_DB_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -

log "Database ready at ${DB_HOST}. Next: ./03-openchoreo.sh"
