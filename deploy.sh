#!/bin/bash
set -e

oc login --token="${K8S_CLUSTER_TOKEN}" --server="${K8S_CLUSTER_URL}" --insecure-skip-tls-verify=true

htpasswd -c -B -b users.htpasswd $(cat /tmp/secrets/USERNAME) $(cat /tmp/secrets/PASSWORD)
oc create secret generic htpass-secret --from-file=htpasswd=users.htpasswd -n openshift-config
oc patch oauth cluster --type=merge --patch='{"spec":{"identityProviders":[{"name":"htpasswd_provider","mappingMethod":"claim","type":"HTPasswd","htpasswd":{"fileData":{"name":"htpass-secret"}}}]}}'
oc wait --for=condition=Ready pod --all -n openshift-authentication --timeout=400s
oc adm policy add-cluster-role-to-user cluster-admin $(cat /tmp/secrets/USERNAME)


echo "Deploying Developer Hub"
bash helm/helm-install.sh --namespace=skhileri-rhdh-test --CV=1.5-171-CI
echo "Deployed Developer Hub"

sleep 7200