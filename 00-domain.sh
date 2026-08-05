#!/usr/bin/env bash
# Sets up the Route 53 hosted zone that BASE_DOMAIN lives in, and records the
# result in domain.env for every later script to read.
#
#   ./00-domain.sh check    example.com   # is it available, and what would it cost
#   ./00-domain.sh register example.com   # register it (needs contact.json)
#   ./00-domain.sh adopt    example.com   # already registered — just find the zone
#
# Registering through the console is fewer moving parts than the CLI, because
# the CLI needs a full contact block. Do that, then run `adopt`.
#
# BASE_DOMAIN becomes amp.<domain>, so the platform's wildcard certificate and
# hostnames sit under a subdomain and leave the apex free.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -euo pipefail

# env.sh is not sourced here: it requires the very values this script produces.
log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARN: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

ACTION="${1:-}"
DOMAIN="${2:-}"
[[ -n "$ACTION" && -n "$DOMAIN" ]] || die "usage: $0 {check|register|adopt} <domain>"

# Route 53 Domains is a us-east-1-only API regardless of where the cluster runs.
R53D=(aws route53domains --region us-east-1)

case "$ACTION" in

check)
  log "Availability of ${DOMAIN}"
  "${R53D[@]}" check-domain-availability --domain-name "$DOMAIN" --output table
  log "Price"
  tld="${DOMAIN#*.}"
  "${R53D[@]}" list-prices --tld "$tld" --output table 2>/dev/null \
    || warn "could not read pricing for .${tld}"
  ;;

register)
  CONTACT_FILE="${SCRIPT_DIR}/contact.json"
  if [[ ! -f "$CONTACT_FILE" ]]; then
    cat > "$CONTACT_FILE" <<'EOF'
{
  "FirstName": "",
  "LastName": "",
  "ContactType": "COMPANY",
  "OrganizationName": "WSO2",
  "AddressLine1": "",
  "City": "",
  "State": "",
  "CountryCode": "",
  "ZipCode": "",
  "PhoneNumber": "+94.000000000",
  "Email": "jhivan@wso2.com"
}
EOF
    die "Wrote a contact template to ${CONTACT_FILE} — fill it in and re-run. PhoneNumber must be +CC.NUMBER format."
  fi

  avail="$("${R53D[@]}" check-domain-availability --domain-name "$DOMAIN" \
    --query 'Availability' --output text)"
  [[ "$avail" == "AVAILABLE" ]] || die "${DOMAIN} is ${avail}"

  log "Registering ${DOMAIN} — this charges the account and can take up to an hour"
  read -r -p "Type the domain to confirm: " confirm
  [[ "$confirm" == "$DOMAIN" ]] || die "aborted"

  contact="$(cat "$CONTACT_FILE")"
  op="$("${R53D[@]}" register-domain \
    --domain-name "$DOMAIN" \
    --duration-in-years 1 \
    --auto-renew \
    --admin-contact "$contact" \
    --registrant-contact "$contact" \
    --tech-contact "$contact" \
    --privacy-protect-admin-contact \
    --privacy-protect-registrant-contact \
    --privacy-protect-tech-contact \
    --query 'OperationId' --output text)"
  echo "Operation: ${op}"

  log "Waiting for registration to complete"
  while true; do
    status="$("${R53D[@]}" get-operation-detail --operation-id "$op" \
      --query 'Status' --output text)"
    echo "  ${status}"
    case "$status" in
      SUCCESSFUL) break ;;
      ERROR|FAILED) die "registration failed — check get-operation-detail --operation-id ${op}" ;;
      *) sleep 30 ;;
    esac
  done
  exec "$0" adopt "$DOMAIN"
  ;;

adopt)
  log "Locating the hosted zone for ${DOMAIN}"
  ZONE_ID="$(aws route53 list-hosted-zones-by-name --dns-name "${DOMAIN}." \
    --query "HostedZones[?Name=='${DOMAIN}.' && Config.PrivateZone==\`false\`].Id | [0]" \
    --output text 2>/dev/null)"

  if [[ "$ZONE_ID" == "None" || -z "$ZONE_ID" ]]; then
    warn "No public hosted zone for ${DOMAIN}. Creating one."
    ZONE_ID="$(aws route53 create-hosted-zone --name "$DOMAIN" \
      --caller-reference "amp-$(date +%s)" \
      --hosted-zone-config Comment="agent-manager eval" \
      --query 'HostedZone.Id' --output text)"
  fi

  ZONE_ID="${ZONE_ID#/hostedzone/}"

  cat > "${SCRIPT_DIR}/domain.env" <<EOF
export BASE_DOMAIN="amp.${DOMAIN}"
export ROUTE53_ZONE_ID="${ZONE_ID}"
EOF

  log "Wrote domain.env"
  cat "${SCRIPT_DIR}/domain.env"

  log "Checking whether ${DOMAIN} is delegated to this zone"
  # Ask a public resolver, not the zone's own nameserver: Route 53 is
  # authoritative for the zone the moment it exists, so querying it directly
  # would report success even with no NS records in the parent zone.
  mapfile -t ZONE_NS < <(aws route53 get-hosted-zone --id "$ZONE_ID" \
    --query 'DelegationSet.NameServers[]' --output text | tr '\t' '\n')
  PUBLIC_NS="$(dig +short NS "${DOMAIN}" @1.1.1.1 2>/dev/null | sed 's/\.$//' | sort)"

  delegated=false
  if [[ -n "${PUBLIC_NS}" ]]; then
    for ns in "${ZONE_NS[@]}"; do
      grep -qx "${ns%.}" <<< "${PUBLIC_NS}" && { delegated=true; break; }
    done
  fi

  if $delegated; then
    log "Delegated. ACME DNS-01 will work."
    echo "  public resolver returns:"
    sed 's/^/    /' <<< "${PUBLIC_NS}"
    log "Next: ./01-cluster.sh"
  else
    printf '\n\033[1;33mNOT DELEGATED YET.\033[0m\n\n'

    # An apex domain is delegated by changing nameservers at the registrar; only
    # a subdomain is delegated by adding NS records to a parent zone you host.
    # Telling someone to "add NS records to the zone for xyz" sends them looking
    # for a TLD zone they cannot edit.
    labels="$(tr -cd '.' <<< "${DOMAIN}" | wc -c)"
    parent="${DOMAIN#*.}"
    is_apex=false
    (( labels <= 1 )) && is_apex=true
    case "${parent}" in
      co.uk|org.uk|com.au|net.au|co.nz|co.za|com.br|co.in|co.jp) is_apex=true ;;
    esac

    if $is_apex; then
      cat <<INSTRUCTIONS
${DOMAIN} is a registrable domain, so delegation happens at your REGISTRAR,
not in a parent DNS zone. Set its authoritative nameservers to:

$(printf '    %s\n' "${ZONE_NS[@]}")

  Namecheap:  Domain List > Manage > NAMESERVERS > choose "Custom DNS",
              enter all four, save with the checkmark. This is NOT the
              "Advanced DNS" tab — NS records added there do nothing while
              the domain is still on BasicDNS.
  Others:     look for "nameservers", "custom DNS" or "change DNS provider".

Check the registry directly, which updates before any resolver cache expires:

    dig +norecurse NS ${DOMAIN} @\$(dig +short NS ${parent}. @1.1.1.1 | head -1) +noall +authority

INSTRUCTIONS
    else
      cat <<INSTRUCTIONS
Add four NS records in the zone for ${parent}, wherever that zone is hosted:

  Name:  ${DOMAIN%%.*}      (just the label — most DNS hosts append ${parent})
  Type:  NS
  TTL:   300
  Value:
$(printf '    %s\n' "${ZONE_NS[@]}")

Remove any A or CNAME record at that same name, or the delegation is ambiguous.

INSTRUCTIONS
    fi

    cat <<INSTRUCTIONS
Then re-run:  ./00-domain.sh adopt ${DOMAIN}

Do not run 03-openchoreo.sh before this reports Delegated — cert-manager
would write DNS-01 challenge records into a zone no resolver consults, and
every certificate would hang unissued.

INSTRUCTIONS
    exit 1
  fi
  ;;

*)
  die "unknown action '${ACTION}' — use check, register or adopt"
  ;;
esac
