#!/bin/bash

set -e

AR_RECORD_FILE=tmp.rf.$$
ADR_RECORD_FILE=tmp.rf.$$
CONFIG_FILE=`mktemp`

CERC_APP_TYPE=${CERC_APP_TYPE:-"webapp"}
CERC_REPO_REF=${CERC_REPO_REF:-${GITHUB_SHA:-`git log -1 --format="%H"`}}
CERC_IS_LATEST_RELEASE=${CERC_IS_LATEST_RELEASE:-"true"}

rcd_name=$(jq -r '.name' package.json | sed 's/null//')
rcd_desc=$(jq -r '.description' package.json | sed 's/null//')
rcd_repository=$(jq -r '.repository' package.json | sed 's/null//')
rcd_homepage=$(jq -r '.homepage' package.json | sed 's/null//')
rcd_license=$(jq -r '.license' package.json | sed 's/null//')
rcd_author=$(jq -r '.author' package.json | sed 's/null//')
rcd_app_version=$(jq -r '.version' package.json | sed 's/null//')

cat <<EOF > "$CONFIG_FILE"
services:
  registry:
    rpcEndpoint: '${CERC_REGISTRY_REST_ENDPOINT:-https://laconicd.laconic.com}'
    gqlEndpoint: '${CERC_REGISTRY_GQL_ENDPOINT:-https://laconicd.laconic.com/api}'
    chainId: ${CERC_REGISTRY_CHAIN_ID:-laconic_9000-1}
    gas: 9950000
    fees: 25000000alnt
EOF

if [ -z "$CERC_REGISTRY_BOND_ID" ]; then
  bond_id=$(laconic -c $CONFIG_FILE registry bond create --type alnt --quantity 10000000000 --user-key "${CERC_REGISTRY_USER_KEY}")

  CERC_REGISTRY_BOND_ID=$(echo ${bond_id} | jq -r .bondId)
fi

sleep 10

next_ver=$(laconic -c $CONFIG_FILE registry record list --type ApplicationRecord --all --name "$rcd_name" 2>/dev/null | jq -r -s ".[] | sort_by(.createTime) | reverse | [ .[] | select(.bondId == \"$CERC_REGISTRY_BOND_ID\") ] | .[0].attributes.version" | awk -F. -v OFS=. '{$NF += 1 ; print}')

if [ -z "$next_ver" ] || [ "1" == "$next_ver" ]; then
  next_ver=0.0.1
fi

cat <<EOF | sed '/.*: ""$/d' > "$AR_RECORD_FILE"
record:
  type: ApplicationRecord
  version: ${next_ver}
  name: "$rcd_name"
  description: "$rcd_desc"
  homepage: "$rcd_homepage"
  license: "$rcd_license"
  author: "$rcd_author"
  repository:
    - "$rcd_repository"
  repository_ref: "$CERC_REPO_REF"
  app_version: "$rcd_app_version"
  app_type: "$CERC_APP_TYPE"
EOF


cat $AR_RECORD_FILE
AR_RECORD_ID=$(laconic -c $CONFIG_FILE registry record publish --filename $AR_RECORD_FILE --user-key "${CERC_REGISTRY_USER_KEY}" --bond-id ${CERC_REGISTRY_BOND_ID} | jq -r '.id')
echo $AR_RECORD_ID

sleep 10

if [ -z "$CERC_REGISTRY_APP_CRN" ]; then
  authority=$(echo "$rcd_name" | cut -d'/' -f1 | sed 's/@//')
  app=$(echo "$rcd_name" | cut -d'/' -f2-)
  CERC_REGISTRY_APP_CRN="lrn://$authority/applications/$app"
  laconic -c $CONFIG_FILE registry authority reserve ${authority} --user-key "${CERC_REGISTRY_USER_KEY}"

  sleep 10

  laconic -c $CONFIG_FILE registry authority bond set ${authority} ${CERC_REGISTRY_BOND_ID} --user-key "${CERC_REGISTRY_USER_KEY}"
fi

laconic -c $CONFIG_FILE registry name set --user-key "${CERC_REGISTRY_USER_KEY}" --bond-id ${CERC_REGISTRY_BOND_ID} "$CERC_REGISTRY_APP_CRN@${rcd_app_version}" "$AR_RECORD_ID"

sleep 10

laconic -c $CONFIG_FILE registry name set --user-key "${CERC_REGISTRY_USER_KEY}" --bond-id ${CERC_REGISTRY_BOND_ID} "$CERC_REGISTRY_APP_CRN@${CERC_REPO_REF}" "$AR_RECORD_ID"
if [ "true" == "$CERC_IS_LATEST_RELEASE" ]; then
  laconic -c $CONFIG_FILE registry name set --user-key "${CERC_REGISTRY_USER_KEY}" --bond-id ${CERC_REGISTRY_BOND_ID} "$CERC_REGISTRY_APP_CRN" "$AR_RECORD_ID"
fi


APP_RECORD=$(laconic -c $CONFIG_FILE registry name resolve "$CERC_REGISTRY_APP_CRN" | jq '.[0]')
if [ -z "$APP_RECORD" ] || [ "null" == "$APP_RECORD" ]; then
  echo "No record found for $CERC_REGISTRY_APP_CRN."
  exit 1
fi

cat <<EOF | sed '/.*: ""$/d' > "$ADR_RECORD_FILE"
record:
  type: ApplicationDeploymentRequest
  version: 1.0.0
  name: "$rcd_name@$rcd_app_version"
  application: "$CERC_REGISTRY_APP_CRN@$rcd_app_version"
  dns: "$CERC_REGISTRY_DEPLOYMENT_SHORT_HOSTNAME"
  deployment: "$CERC_REGISTRY_DEPLOYMENT_CRN"
  config:
    env:
      CERC_WEBAPP_DEBUG: "$rcd_app_version"
  meta:
    note: "Added by CI @ `date`"
    repository: "`git remote get-url origin`"
    repository_ref: "${GITHUB_SHA:-`git log -1 --format="%H"`}"
EOF

cat $ADR_RECORD_FILE
ADR_RECORD_ID=$(laconic -c $CONFIG_FILE registry record publish --filename $ADR_RECORD_FILE --user-key "${CERC_REGISTRY_USER_KEY}" --bond-id ${CERC_REGISTRY_BOND_ID} | jq -r '.id')
echo $ADR_RECORD_ID

rm -f $AR_RECORD_FILE $ADR_RECORD_FILE $CONFIG_FILE
