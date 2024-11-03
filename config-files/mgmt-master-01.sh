#!/usr/bin/env bash

#=============================
# As an SA, you need to perform demos and online sessions and workshops which require a lab environment to be available
# This script is created to automate the installation of all required resources for the Rancher management cluster master node.
# The resources to be installed using this scripts are as follow:
#   - Install Helm CLI Tool
#   - Add Helm Repos & Update
#   - Install Rancher local-path storage provisioner
#   - Install Cert-Manager
#   - Install Let's Encrypt Issuer
#   - Deploy Rancher Manager
#   - Deploy & Install Rancher Backup
#   - Deploy & Install Rancher CSI
#   - Deploy Harbor using Helm
# Please Note, This script will require several arguments to be passed by the user
#=============================

# Create a Usage Function to be used in case of error or miss-configuration to advise on the usage of the script
usage() {
    echo ""
    echo "Usage: $0 --cert-version [Input] --email [Input] --default-pass [Input] --domain [Input] ----"
    echo "All arguments must be provided. A total of 12 arguments"
    echo "Argument lists are:"
    echo "--cert-version: The Cert-Manager version to be used while deployement it using Helm."
    echo "--email: The email address to be used while creating a Let's Encrypt Certificate or Issuer."
    echo "--default-pass: The password to be used while deploying SUSE solutions."
    echo "--domain: The lab domain name to be used while deploying SUSE solutions."
    echo "--rancher-version: The Rancher Manager version to be used while deployement it using Helm."
    echo "--rancher-url: The Rancher Manager url to be used while configuring Rancher Manager Ingress for HTTP(S) access."
    echo "--s3-access-key: The Access Key to be used to access S3 Bucket to be used while configuring the Rancher Backup."
    echo "--s3-secret-key: The Access Key Secret to be used to access S3 Bucket to be used while configuring the Rancher Backup."
    echo "--s3-region: The AWS region where the S3 Bucket is created and configure for access to be used while configuring the Rancher Backup."
    echo "--s3-s3_bucket_name: The AWS S3 Bucket name to be used while configuring the Rancher Backup."
    echo "--s3-endpoint: The S3 endpoint url be used while configuring the Rancher Backup."
    echo "--harbor-url: The Harbor url to be used while configuring Rancher Manager Ingress for HTTP(S) access."
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
    # Match on Default Password
    --default_pass)
      default_pass="${2:-}"
      ;;
    # Match on Domain
    --domain)
      domain="${2:-}"
      ;;
    # Match on Rancher Manager Version 
    --rancher_version)
      rancher_version="${2:-}"
      ;;
    # Match on Rancher Manager URL
    --rancher_url)
      rancher_url="${2:-}"
      ;;
    # Match on S3 Access Key
    --s3_access_key)
      s3_access_key="${2:-}"
      ;;
    # Match on S3 Access Secret Key
    --s3_secret_key)
      s3_secret_key="${2:-}"
      ;;
    # Match on S3 Region
    --s3_region)
      s3_region="${2:-}"
      ;;
    # Match on S3 Bucket Name
    --s3_bucket_name)
      s3_bucket_name="${2:-}"
      ;;
    # Match on S3 Endpoint
    --s3_endpoint)
      s3_endpoint="${2:-}"
      ;;
    # Match on Harbor Url
    --harbor_url)
      harbor_url="${2:-}"
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
if [ -z "$cert_version" ] || [ -z "$email" ] || [ -z "$default_pass" ] || [ -z "$email" ] || [ -z "$default_pass" ] || [ -z "$domain" ] || [ -z "$rancher_version" ] || [ -z "$rancher_url" ] || [ -z "$s3_access_key" ] || [ -z "$s3_secret_key" ] || [ -z "$s3_region" ] || [ -z "$s3_bucket_name" ] || [ -z "$s3_endpoint" ] || [ -z "$harbor_url" ]
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

### Install & Configure Storage

echo "2- Install Rancher local-path storage provisioner"

# Deploy Rancher local-path storage provisioner
echo ""
echo "-- Installing Rancher local-path storage provisioner ..."
echo ""
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.26/deploy/local-path-storage.yaml

#---------------------------------------------------------------------------

### Create a Let's Encrypt Cluster Issuer & Cert Manager

echo "3- Deploy Cert-Manager and configure lets-encrypt-issuer"

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

### Deploy Rancher Manager

echo "4- Deploy Rancher Manager"

echo ""
echo "-- Deploying Rancher Manager using Helm ..."
echo ""
helm install --wait \
  rancher rancher-prime/rancher \
  --namespace cattle-system \
  --create-namespace \
  --version $rancher_version \
  --set replicas=1 \
  --set hostname=$rancher_url \
  --set ingress.tls.source=letsEncrypt \
  --set letsEncrypt.email=$email \
  --set bootstrapPassword=$default_pass

#---------------------------------------------------------------------------

### Deploy & Install Rancher Backup

echo "5- Deploy & Install Rancher Backup"

# Create S3 Secret
echo ""
echo "-- Creating a secret for S3 access ..."
echo ""
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: s3-creds
type: Opaque
data:
  accessKey: "${s3_access_key}"
  secretKey: "${s3_secret_key}"
EOF

#  Create the Rancher Backup Operator Helm Chart Value File
echo ""
echo "-- Creating Rancher Backup operator Helm Chart value file ..."
echo ""
cat << EOF >> yamlfiles/backup-operator-values.yaml
s3:
  enabled: true
  credentialSecretName: "s3-creds"
  credentialSecretNamespace: "default"
  region: "${s3_region}"
  bucketName: "${s3_bucket_name}"
  folder: ""
  endpoint: "${s3_endpoint}"
  endpointCA: ""
  insecureTLSSkipVerify: true
persistence:
  enabled: false
EOF

# Create Rancher Backup CRDs
echo ""
echo "-- Deploying Rancher Backup CRD using Helm ..."
echo ""
helm install --wait \
  rancher-backup-crd rancher-charts/rancher-backup-crd \
  --namespace cattle-resources-system \
  --create-namespace

# Create Rancher Backup Operator
echo ""
echo "-- Deploying Rancher Backup using Helm ..."
echo ""
helm install --wait \
  rancher-backup rancher-charts/rancher-backup \
  --namespace cattle-resources-system \
  --values yamlfiles/backup-operator-values.yaml

# Create the Rancher encryption provider config File 
echo ""
echo "-- Creating the Rancher Backup encryption-provider-config Yaml file ..."
echo ""
cat << EOF >> yamlfiles/encryption-provider-config.yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - aesgcm:
          keys:
            - name: key1
              secret: c2VjcmV0IGlzIHNlY3VyZQ==
EOF

# Create the Rancher encryption secret using the above created Rancher encryption provider config File
echo ""
echo "-- Creating the Rancher Backup encryptionconfig secret ..."
echo ""
kubectl create secret generic encryptionconfig --from-file=yamlfiles/encryption-provider-config.yaml -n cattle-resources-system

#---------------------------------------------------------------------------

### Deploy & Install Rancher CSI

echo "6- Deploy & Install Rancher CSI"

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

### Deploy Harbor using Helm

echo "7- Deploy & Install Harbor"


echo ""
echo "-- Deploying Harbor using Helm ..."
echo ""
helm install --wait \
  harbor harbor/harbor \
  --namespace harbor \
  --create-namespace \
  --set expose.ingress.hosts.core=harbor.rancher-demo.com \
  --set expose.ingress.hosts.notary=notary.rancher-demo.com \
  --set expose.ingress.annotations.'cert-manager\.io/cluster-issuer'=letsencrypt-prod \
  --set expose.tls.certSource=secret \
  --set expose.tls.secret.secretName=tls-harbor \
  --set externalURL=https://harbor.rancher-demo.com \
  --set persistence.persistentVolumeClaim.registry.storageClass=local-path \
  --set persistence.persistentVolumeClaim.jobservice.jobLog.storageClass=local-path \
  --set persistence.persistentVolumeClaim.database.storageClass=local-path \
  --set persistence.persistentVolumeClaim.redis.storageClass=local-path \
  --set persistence.persistentVolumeClaim.trivy.storageClass=local-path \
  --set harborAdminPassword=SuseDemo@123

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