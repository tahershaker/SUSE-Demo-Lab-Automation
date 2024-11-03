#!/usr/bin/env bash

#=============================
# As an SA, you need to perform demos and online sessions and workshops which require a lab environment to be available
# This script is created to automate the installation of all required resources for the downstream cluster 01 master node.
# The resources to be installed using this scripts are as follow:
#   - Install Helm CLI Tool
#   - Add Helm Repos & Update
#   - Install Cert-Manager
#   - Install Let's Encrypt Issuer
#   - Deploy & Install Rancher CSI
#   - Deploy Online-Boutique Application
# Please Note, This script will require several arguments to be passed by the user
#=============================

# Create a Usage Function to be used in case of error or miss-configuration to advise on the usage of the script
usage() {
    echo ""
    echo "Usage: $0 --cert-version [Input] --email [Input] --default-pass [Input] --domain [Input] ----"
    echo "All arguments must be provided. A total of 12 arguments"
    echo "Argument lists are:"
    echo "--cert_version: The Cert-Manager version to be used while deployement it using Helm."
    echo "--email: The email address to be used while creating a Let's Encrypt Certificate or Issuer."
    echo "--rancher_demo_url: The Rancher Demo App url to be used while configuring Ingress for HTTP(S) access."
    echo "--tetris_url: The Tetris App url to be used while configuring Ingress for HTTP(S) access."
}

#Read passed arguments and pass it to the script
while [ $# -gt 0 ]; do 
  case $1 in
    # Match on Help 
    -h|--help)
      usage
      exit 0
      ;;
    # Match on Cert-Manager
    --cert_version)
      cert_version="${2:-}"
      ;;
    # Match on Email 
    --email)
      email="${2:-}"
      ;;
    # Match on Rancher Demo App URL
    --rancher_demo_url)
      rancher_demo_url="${2:-}"
      ;;
    # Match on Tetris App URL
    --tetris_url)
      tetris_url="${2:-}"
      ;;
    # Print error on un-matched passed argument
    *)
      echo "argument is ${1}"
      echo "Error - Invalide argument provided - Provided argument is ${1}. Please provide all correct arguments"
      usage
      exit 1
      ;;
  esac
  shift 2 
done

# Validate if empty and print usage function in case arguments are empty
if [ -z "$cert_version" ] || [ -z "$email" ] || [ -z "$rancher_demo_url" ] || [ -z "$tetris_url" ] 
then
   echo "Error - Some or all arguments are not provided, please provide all arguments";
   usage
fi

#==============================

#--------------------#
#--- Start Script----#
#--------------------#

echo "-----------------------"
echo "--- Starting Script ---"
echo "-----------------------"
echo ""

#==============================

#---------------------------------------------------------------------------


### Install Helm & Add Repos

echo "1- Install Helm & add Helm Repos"

# Install Helm
echo ""
echo "-- Instaling Helm ..."
echo ""
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Add Helm Repos
echo ""
echo "-- Adding Helm Repos & Updating ..."
echo ""
helm repo add jetstack https://charts.jetstack.io
helm repo add rancher-charts https://charts.rancher.io
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

#---------------------------------------------------------------------------

### Create a Let's Encrypt Cluster Issuer & Cert Manager

echo "2- Deploy Cert-Manager and configure lets-encrypt-issuer"

# Deploy Cert Manager
echo ""
echo "-- Deploying Cert-Manager using Helm ..."
echo ""
helm install --wait \
  cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --version $cert_version \
  --set installCRDs=true \
  --create-namespace

# Create the lets-encrypt-issuer
echo ""
echo "-- Creating lets-encrypt-issuer ..."
echo ""
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer 
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: $email
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: nginx 
EOF

#---------------------------------------------------------------------------

### Deploy & Install Rancher CSI

echo "3- Deploy & Install Rancher CSI"

# Create the Rancher CSI Benchmark CRDs_
echo ""
echo "-- Deploying the Rancher CSI CRD using Helm ..."
echo ""
helm install --wait \
  rancher-cis-benchmark-crd rancher-charts/rancher-cis-benchmark-crd \
  --namespace cis-operator-system \
  --create-namespace

# Create the Rancher CSI Benchmark
echo ""
echo "-- Deploying the Rancher CSI using Helm ..."
echo ""
helm install --wait \
  rancher-cis-benchmark rancher-charts/rancher-cis-benchmark \
  --namespace cis-operator-system

#---------------------------------------------------------------------------

### Deploy Online Boutique App Using Yaml File Hosted on GitHub

echo "4- Deploy Online Boutique App"

echo ""
echo "-- Deploying Online Boutique App using kubectl yaml file ..."
echo ""
kubectl apply -f https://raw.githubusercontent.com/tahershaker/SUSE-Demo-Lab-Automation/refs/heads/main/app-yaml-files/online-boutique-app.yaml

#---------------------------------------------------------------------------

# Deploy Rancher Demo App Using Helm

echo "5- Deploy Rancher Demo App"

echo ""
echo "-- Deploying Rancher Demo App using Helm ..."
echo ""
helm install --wait \
  rancher-demo rodeo/rancher-demo \
  --namespace rancher-demo \
  --create-namespace \
  --set ingress.host=$rancher_demo_url 

#---------------------------------------------------------------------------

# Deploy Tetris App Using Helm

echo "5- Deploy Tetris App"

echo ""
echo "-- Deploying Tetris App using Helm ..."
echo ""
helm install --wait \
  tetris rodeo/tetris \
  --namespace tetris \
  --create-namespace \
  --set ingress.hosts.host=$tetris_url 

#---------------------------------------------------------------------------

# Print End Of Script Message

echo "----------------------------------------------------------"
echo ""
echo "-----------------------"
echo "---- End of Script ----"
echo "-----------------------"
echo ""

##########################
##### End Of Script ######
##########################