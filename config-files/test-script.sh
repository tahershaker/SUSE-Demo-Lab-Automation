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
    echo "--cert_version: The Cert-Manager version to be used while deployement it using Helm."
    echo "--email: The email address to be used while creating a Let's Encrypt Certificate or Issuer."
    echo "--default_pass: The password to be used while deploying SUSE solutions."
    echo "--domain: The lab domain name to be used while deploying SUSE solutions."
    echo "--rancher_version: The Rancher Manager version to be used while deployement it using Helm."
    echo "--rancher_url: The Rancher Manager url to be used while configuring Rancher Manager Ingress for HTTP(S) access."
    echo "--s3_access_key: The Access Key to be used to access S3 Bucket to be used while configuring the Rancher Backup."
    echo "--s3_secret_key: The Access Key Secret to be used to access S3 Bucket to be used while configuring the Rancher Backup."
    echo "--s3_region: The AWS region where the S3 Bucket is created and configure for access to be used while configuring the Rancher Backup."
    echo "--s3_bucket_name: The AWS S3 Bucket name to be used while configuring the Rancher Backup."
    echo "--s3_endpoint: The S3 endpoint url be used while configuring the Rancher Backup."
    echo "--harbor_url: The Harbor url to be used while configuring Rancher Manager Ingress for HTTP(S) access."
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

echo "Cert-Manager Version is ${cert_version}"
echo "Email is ${email}"
echo "password is ${default_pass}"
echo "domain is ${domain}"
echo "rancher version is ${rancher_version}"
echo "rancher url is ${rancher_url}"
echo "s3 access is ${s3_access_key}"
echo "s3 secret is ${s3_secret_key}"
