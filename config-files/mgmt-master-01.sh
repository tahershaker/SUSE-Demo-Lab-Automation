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


helpFunction()
{
   echo ""
   echo -e "\t-CERT_VERSION - Cert Manager Version"
   echo -e "\t-EMAIL Email For Let's Encrypt Certificates"
   echo -e "\t-DEFAULT_PASS Default Password To Be Used"
   echo -e "\t-DEFAULT_DOMAIN Default Domain To Be Used"
   echo -e "\t-RANCHER_VERSION Rancher Manager Version"
   echo -e "\t-RANCHER_URL Rancher Manager URL for Ingress Access"
   echo -e "\t-S3_ACCESS_KEY S3 Bucket Access Key"
   echo -e "\t-S3_SECRET_KEY S3 Bucket Secret Access Key"
   echo -e "\t-S3_REGION S3 AWS Region"
   echo -e "\t-S3_BUCKET_NAME S3 Bucket Name"
   echo -e "\t-S3_ENDPOINT S3 Bucket End Point URL"
   echo -e "\t-HARBOR_URL S3 Harbor URL for Ingress Access"
   exit 1 # Exit script after printing help
}

while getopts "a:b:c:" opt
do
   case "$opt" in
      CERT_VERSION ) CERT_VERSION="$OPTARG" ;;
      EMAIL ) EMAIL="$OPTARG" ;;
      DEFAULT_PASS ) DEFAULT_PASS="$OPTARG" ;;
      DEFAULT_DOMAIN ) DEFAULT_DOMAIN="$OPTARG" ;;
      RANCHER_VERSION ) RANCHER_VERSION="$OPTARG" ;;
      RANCHER_URL ) RANCHER_URL="$OPTARG" ;;
      S3_ACCESS_KEY ) S3_ACCESS_KEY="$OPTARG" ;;
      S3_SECRET_KEY ) S3_SECRET_KEY="$OPTARG" ;;
      S3_REGION ) S3_REGION="$OPTARG" ;;
      S3_BUCKET_NAME ) S3_BUCKET_NAME="$OPTARG" ;;
      S3_ENDPOINT ) S3_ENDPOINT="$OPTARG" ;;
      HARBOR_URL ) HARBOR_URL="$OPTARG" ;;
      ? ) helpFunction ;; # Print helpFunction in case parameter is non-existent
   esac
done

# Print helpFunction in case parameters are empty
if [ -z "$CERT_VERSION" ] || [ -z "$EMAIL" ] || [ -z "$DEFAULT_PASS" ] || [ -z "$DEFAULT_DOMAIN" ] || [ -z "$RANCHER_VERSION" ] || [ -z "$RANCHER_URL" ] || [ -z "$S3_ACCESS_KEY" ] || [ -z "$S3_SECRET_KEY" ] || [ -z "$S3_REGION" ] || [ -z "$S3_BUCKET_NAME" ] || [ -z "$S3_ENDPOINT" ] || [ -z "$HARBOR_URL" ]
then
   echo "Error - Some Or All Parameters Are Not Provided, Please Provide All Parameters";
   echo "List of All Parameters Are:";
   helpFunction
fi

#==============================

#--------------------#
#--- Start Script----#
#--------------------#

#==============================

echo "Cert Manager Version is: ${CERT_VERSION}"
echo "Cert Manager Version is: ${EMAIL}"
echo "Cert Manager Version is: ${DEFAULT_PASS}"
echo "Cert Manager Version is: ${DEFAULT_DOMAIN}"
echo "Cert Manager Version is: ${RANCHER_VERSION}"
echo "Cert Manager Version is: ${RANCHER_URL}"
echo "Cert Manager Version is: ${S3_ACCESS_KEY}"
echo "Cert Manager Version is: ${S3_SECRET_KEY}"
echo "Cert Manager Version is: ${S3_REGION}"
echo "Cert Manager Version is: ${S3_BUCKET_NAME}"
echo "Cert Manager Version is: ${S3_ENDPOINT}"
echo "Cert Manager Version is: ${HARBOR_URL}"