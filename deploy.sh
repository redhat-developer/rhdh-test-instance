#!/bin/bash
set -e

htpasswd -c -B -b users.htpasswd $(cat /tmp/secrets/USERNAME) $(cat /tmp/secrets/PASSWORD)
oc create secret generic htpass-secret --from-file=htpasswd=users.htpasswd -n openshift-config
oc patch oauth cluster --type=merge --patch='{"spec":{"identityProviders":[{"name":"htpasswd_provider","mappingMethod":"claim","type":"HTPasswd","htpasswd":{"fileData":{"name":"htpass-secret"}}}]}}'
oc wait --for=condition=Ready pod --all -n openshift-authentication --timeout=400s
oc adm policy add-cluster-role-to-user cluster-admin $(cat /tmp/secrets/USERNAME)


echo "Deploying Developer Hub"
bash helm/helm-install.sh --namespace=skhileri-rhdh-test --CV=1.5-171-CI
echo "Deployed Developer Hub"

gh --version
gh pr comment $GIT_PR_NUMBER --repo openshift/release --body "RHDH URL: $RHDH_BASE_URL | OpenShift Console URL: https://console-openshift-console.${CLUSTER_ROUTER_BASE}"

sleep 7200