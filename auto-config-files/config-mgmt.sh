#!/usr/bin/env bash

#=============================
# Script for Automating Rancher Cluster Setup
# -------------------------------------------
# As a Solutions Architect, there is often a need to conduct workshops, presentations, and demos, 
# all of which typically require a demo lab environment. Building such an environment from scratch 
# can be time-consuming and cumbersome. This script is designed to automate the deployment of a 
# Rancher demo lab environment, streamlining the process and saving valuable time.
#
# The script automates the setup of the Rancher management cluster and the deployment of key components, 
# including Helm, Cert-Manager, and Rancher Backup. The actions automated by this script include, 
# but are not limited to:
#   - Installing Helm and adding the necessary Helm repositories
#   - Deploying Cert-Manager and configuring a Let's Encrypt issuer
#   - Deploying Rancher Manager, Rancher Backup, Rancher CSI Benchmark, and additional components
#   - Creating downstream imported clusters
#
# The script requires several arguments to be passed by the user. Please review the usage section for 
# detailed information on each required argument.
#=============================

####################################################
# Create required functions to be used in the script
####################################################

# Function to display usage information
usage() {
    cat <<EOF
Usage: $0 --cert-version <cert_version> --email <email> --default-pass <password> --domain <domain> [OPTIONS]

Required Arguments:
  --cert-version       The Cert-Manager version - ex: v1.13.0.
  --email              The email for Let's Encrypt - ex: admin@suse.com.
  --default-pass       The password for deploying SUSE solutions - ex: P@ssw0rd.
  --domain             The lab domain for SUSE solutions - ex: suse.com.
  --rancher-version    The Rancher Manager version to deploy - ex: v2.9.2.
  --rancher-url        The Rancher Manager URL - ex: rancher.example.com.
  --s3-access-key      The S3 access key for Rancher backup - ex: ASfrVetSgey3732j283==.
  --s3-secret-key      The S3 secret key for Rancher backup - ex: ASfrVetSgey3732j283==.
  --s3-region          The AWS region of the S3 bucket - ex: eu-west-1.
  --s3-bucket-name     The S3 bucket name for Rancher backup - ex: suse-demo-s3-bucket.
  --s3-endpoint        The S3 endpoint for Rancher backup - ex: s3.eu-west-2.amazonaws.com.
  --harbor-url         The Harbor URL for Ingress - ex: harbor.example.com.
  --aws-default-region The default AWS region for deploying downstream clusters - ex: eu-west-1.
  --aws-access-key     The AWS admin access key for Rancher Cloud Credentials - ex: ASfrVetSgey3732j283==.
  --aws-secret-key     The AWS admin secret key for Rancher Cloud Credentials - ex: ASfrVetSgey3732j283==.
  --dsc_count          The number of downstream clusters to create (an integer between 1 and 5) - ex: 2.
EOF
}

# Function to validate that a given argument is non-empty
# This function checks if an argument is empty and if so, prints a message indicating the name of the missing argument.
validate_non_empty() {
    local arg_name=$1
    local value=$2

    # Check if the value is empty
    if [[ -z "$value" ]]; then
        # Print a message indicating which argument is empty
        echo "Argument '--$arg_name' cannot be empty."
        usage
        exit 1  # Exit the script with an error code
    fi
}

# Function to validate that a given argument is an integer between a specified range (1 to 5 in this case)
# This function checks if the argument value is a valid integer and falls within the specified range.
validate_dsc_count() {
    local arg_name=$1
    local value=$2

    if ! [[ "$value" =~ ^[1-5]$ ]]; then
        # Print an error message if the value is not a valid integer between 1 and 5
        echo "Error: --$arg_name must be an integer between 1 and 5."
        usage
        exit 1  # Exit the script with an error code
    fi
}

# Function to validate that a given argument is in the correct URL format (FQDN)
# This function checks if the given argument is a valid domain name (FQDN) format.
# It ensures that the input is not a full URL (with https://) but just the domain part (e.g., rancher.example.com).
validate_url_format() {
    local arg_name=$1
    local value=$2

    # Regular expression for a valid domain (FQDN)
    if ! [[ "$value" =~ ^[a-zA-Z0-9.-]+$ ]]; then
        # Print an error message if the value is not in a valid domain format
        echo "Error: --$arg_name must be a valid domain name (FQDN), without protocol (https://) - ex: xyz.example.com."
        usage
        exit 1  # Exit the script with an error code
    fi
}


# Function to validate that a given argument is a valid AWS region format
# This function checks if the provided AWS region matches the expected pattern for AWS regions.
validate_aws_region() {
    local arg_name=$1
    local value=$2

    # Check if the region is in a valid AWS region format (e.g., us-east-1)
    if ! [[ "$value" =~ ^[a-z]{2}-[a-z]+-[0-9]$ ]]; then
        # Print an error message if the region format is invalid
        echo "Error: --$arg_name must be a valid AWS region (e.g., us-east-1)."
        usage
        exit 1  # Exit the script with an error code
    fi
}

# Function to validate that a given argument is an integer
# This function checks if the argument value is a valid integer (positive or negative).
validate_integer() {
    local arg_name=$1
    local value=$2

    # Check if the value is a valid integer (positive or negative)
    if ! [[ "$value" =~ ^-?[0-9]+$ ]]; then
        # Print an error message if the value is not a valid integer
        echo "Error: --$arg_name must be a valid integer."
        usage
        exit 1  # Exit the script with an error code
    fi
}

# Function to validate that a given version matches the expected format (vX.Y.Z)
# This function checks if the version follows the format: v<major>.<minor>.<patch>
validate_version() {
    local arg_name=$1
    local value=$2
    # Regular expression for validating version format (vX.Y.Z)
    if ! [[ "$value" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "Error: --$arg_name must follow the format vX.Y.Z (e.g., v1.13.0 or v2.9.2)."
        usage
        exit 1  # Exit the script with an error code
    fi
}

# Function to log messages
log() {
    echo "[INFO] - $1"
}

# Function to log errors
log_error() {
    echo "[ERROR] - $1"
}

# Function to run a command and check for errors
run_command() {
    $1 >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        log_error "Command failed: $1"
        exit 1
    fi
}

#=======================================================================================================================================
#=======================================================================================================================================

####################################################
# Read Passed Arguments and perform required checks
####################################################

# Process passed arguments using a while loop
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --cert_version)
            cert_version="$2"
            validate_non_empty "cert_version" "$cert_version"  # Validate non-empty value for cert_version
            shift 2
            ;;
        
        --email)
            email="$2"
            validate_non_empty "email" "$email"  # Validate non-empty value for email
            validate_email "$email"  # Validate email format
            shift 2
            ;;
        
        --default_pass)
            default_pass="$2"
            validate_non_empty "default_pass" "$default_pass"  # Validate non-empty value for default_pass
            shift 2
            ;;
        
        --domain)
            domain="$2"
            validate_non_empty "domain" "$domain"  # Validate non-empty value for domain
            shift 2
            ;;
        
        --rancher_version)
            rancher_version="$2"
            validate_non_empty "rancher_version" "$rancher_version"  # Validate non-empty value for rancher_version
            shift 2
            ;;
        
        --rancher_url)
            rancher_url="$2"
            validate_non_empty "rancher_url" "$rancher_url"  # Validate non-empty value for rancher_url
            validate_url_format "rancher_url" "$rancher_url"  # Validate input as a proper fqdn format
            echo "still working"
            shift 2
            ;;
        
        --s3_access_key)
            s3_access_key="$2"
            validate_non_empty "s3_access_key" "$s3_access_key"  # Validate non-empty value for s3_access_key
            shift 2
            ;;
        
        --s3_secret_key)
            s3_secret_key="$2"
            validate_non_empty "s3_secret_key" "$s3_secret_key"  # Validate non-empty value for s3_secret_key
            shift 2
            ;;
        
        --s3_region)
            s3_region="$2"
            validate_non_empty "s3_region" "$s3_region"  # Validate non-empty value for s3_region
            validate_aws_region "s3_region" "$s3_region"  # Validate input as a proper AWS region format
            shift 2
            ;;
        
        --s3_bucket_name)
            s3_bucket_name="$2"
            validate_non_empty "s3_bucket_name" "$s3_bucket_name"  # Validate non-empty value for s3_bucket_name
            shift 2
            ;;
        
        --s3_endpoint)
            s3_endpoint="$2"
            validate_non_empty "s3_endpoint" "$s3_endpoint"  # Validate non-empty value for s3_endpoint
            validate_url_format "s3_endpoint" "$s3_endpoint"  # Validate input as a proper fqdn format
            shift 2
            ;;
        
        --harbor_url)
            harbor_url="$2"
            validate_non_empty "harbor_url" "$harbor_url"  # Validate non-empty value for harbor_url
            validate_url_format "harbor_url" "$harbor_url"  # Validate input as a proper fqdn format
            shift 2
            ;;
        
        --aws_default_region)
            aws_default_region="$2"
            validate_non_empty "aws_default_region" "$aws_default_region"  # Validate non-empty value for aws_default_region
            validate_aws_region "aws_default_region" "$aws_default_region"  # Validate input as a proper AWS region format
            shift 2
            ;;
        
        --aws_access_key)
            aws_access_key="$2"
            validate_non_empty "aws_access_key" "$aws_access_key"  # Validate non-empty value for aws_access_key
            shift 2
            ;;
        
        --aws_secret_key)
            aws_secret_key="$2"
            validate_non_empty "aws_secret_key" "$aws_secret_key"  # Validate non-empty value for aws_secret_key
            shift 2
            ;;
        
        --dsc_count)
            dsc_count="$2"
            validate_non_empty "dsc_count" "$dsc_count"  # Validate non-empty value for dsc_count
            validate_integer "dsc_count" "$dsc_count"  # Validate dsc_count as an integer
            validate_dsc_count "dsc_count" "$dsc_count"  # Validate dsc_count is between 1 and 5
            shift 2
            ;;
        
        *)
            echo "Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
done

# Argument validation: Ensure all required arguments are provided
if [[ -z "$cert_version" || -z "$email" || -z "$default_pass" || -z "$domain" || -z "$rancher_version" || -z "$rancher_url" || -z "$s3_access_key" || -z "$s3_secret_key" || -z "$s3_region" || -z "$s3_bucket_name" || -z "$s3_endpoint" || -z "$harbor_url" || -z "$aws_default_region" || -z "$aws_access_key" || -z "$aws_secret_key" || -z "$dsc_count" ]]; then
    echo "Missing required arguments."
    usage
    exit 1
fi

#=======================================================================================================================================
#=======================================================================================================================================



# Display all the captured argument values (for debugging or verification purposes)
echo "Cert Version: $cert_version"
echo "Email: $email"
echo "Default Password: $default_pass"
echo "Domain: $domain"
echo "Rancher Version: $rancher_version"
echo "Rancher URL: $rancher_url"
echo "S3 Access Key: $s3_access_key"
echo "S3 Secret Key: $s3_secret_key"
echo "S3 Region: $s3_region"
echo "S3 Bucket Name: $s3_bucket_name"
echo "S3 Endpoint: $s3_endpoint"
echo "Harbor URL: $harbor_url"
echo "AWS Default Region: $aws_default_region"
echo "AWS Access Key: $aws_access_key"
echo "AWS Secret Key: $aws_secret_key"
echo "DSC Count: $dsc_count"