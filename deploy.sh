#!/bin/bash
set -e


echo "Deploying Developer Hub"
bash helm/helm-install.sh --namespace=skhileri-rhdh-test --CV=1.5-171-CI
echo "Deployed Developer Hub"

