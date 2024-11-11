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
Usage: $0 --cert_version <cert_version> --email <email> --default_pass <password> --domain <domain> [OPTIONS]

Required Arguments:
  --starting_step      The step number that the script should start from - ex: 1.
  --cert_version       The Cert-Manager version - ex: v1.13.0.
  --email              The email for Let's Encrypt - ex: admin@suse.com.
  --default_pass       The password for deploying SUSE solutions - ex: P@ssw0rd.
  --domain             The lab domain for SUSE solutions - ex: suse.com.
  --rancher_version    The Rancher Manager version to deploy - ex: v2.9.2.
  --rancher_url        The Rancher Manager URL - ex: rancher.example.com.
  --s3_access_key      The S3 access key for Rancher backup - ex: ASfrVetSgey3732j283==.
  --s3_secret_key      The S3 secret key for Rancher backup - ex: ASfrVetSgey3732j283==.
  --s3_region          The AWS region of the S3 bucket - ex: eu-west-1.
  --s3_bucket_name     The S3 bucket name for Rancher backup - ex: suse-demo-s3-bucket.
  --s3_endpoint        The S3 endpoint for Rancher backup - ex: s3.eu-west-2.amazonaws.com.
  --harbor_url         The Harbor URL for Ingress - ex: harbor.example.com.
  --aws_default_region The default AWS region for deploying downstream clusters - ex: eu-west-1.
  --aws_access_key     The AWS admin access key for Rancher Cloud Credentials - ex: ASfrVetSgey3732j283==.
  --aws_secret_key     The AWS admin secret key for Rancher Cloud Credentials - ex: ASfrVetSgey3732j283==.
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
        echo "Error: --$arg_name must be an integer between 1 and 5 - The provided input is $value."
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
        echo "Error: --$arg_name must be a valid integer - The provided input is $value."
        usage
        exit 1  # Exit the script with an error code
    fi
}

# Function to check if Rancher Manager is up and running
check_rancher_manager() {
    local interval=10       # Interval in seconds between each check
    local auth_attempts=10    # Max attempts to check authentication and token generation
    local attempt=1

    log "   Checking if Rancher Manager at $rancher_url is up and running..."

    # First loop to check if Rancher Manager is responding (HTTP 200)
    while true; do
        # Use curl to check if Rancher Manager is responding
        response=$(curl -s -o /dev/null -w "%{http_code}" "https://$rancher_url")

        # Check if HTTP response code is 200 (OK)
        if [ "$response" -eq 200 ]; then
            log "   Rancher Manager is up and running!"
            break
        else
            log "   Rancher Manager is not available yet. Retrying in $interval seconds ..."
            sleep "$interval"
        fi
    done

    log "   Rancher Manager is now up, checking if fully functional by authenticating and generating API token..."

    # Second loop to check authentication and token generation
    while [ $attempt -le $auth_attempts ]; do
        response=$(curl -s -X POST "https://$rancher_url/v3-public/localProviders/local?action=login" \
          -H "Content-Type: application/json" \
          -d '{
                "username": "admin",  # Hardcoded username
                "password": "'"$default_pass"'"
              }')

        # Extract error message if available
        error_message=$(echo "$response" | jq -r '.message // empty')

        # Check if there's an error during authentication
        if [ -n "$error_message" ]; then
            log "   Attempt $attempt: Authentication failed with error: $error_message"
            attempt=$((attempt + 1))
            log "   Retrying authentication in $interval seconds ..."
            sleep "$interval"
        else
            log "   Successfully authenticated to Rancher Manager."
            test_token=$(echo "$response" | jq -r '.token')
            break
        fi
    done

    # Check if bearer_token is still empty after the retries
    if [ -z "$test_token" ]; then
        log_error "   Failed to authenticate and generate API token after $auth_attempts attempts. Exiting."
        exit 1
    fi
}

# Function to authenticate with Rancher Manager and generate a token adding it to bearer_token variable
authenticate_and_get_token() {
    # Check if bearer_token is set and starts with "token:"
    if [[ -z "$bearer_token" || ! "$bearer_token" =~ ^token: ]]; then
        # Log Actions for authenticating with Rancher Manager API to retrieve Bearer token
        log "   bearer_token API token was not found, generating one ..."
        log "   Authenticating with Rancher Manager and Retrieving API Token ..."

        # Log Actions for checking if Rancher Manager is up and running
        log "   Checking if Rancher Manager is Up & Running ..."
        check_rancher_manager "$rancher_url"

        response=$(curl -s -X POST "https://$rancher_url/v3-public/localProviders/local?action=login" \
          -H "Content-Type: application/json" \
          -d '{
                "username": "admin",  # Hardcoded username
                "password": "'"$default_pass"'"
              }')

        # Check if the response contains an error
        error_message=$(echo "$response" | jq -r '.message // empty')
        if [ -n "$error_message" ]; then
            log_error "      Error during authentication: $error_message"
            exit 1
        else
            log "      Successfully authenticated to Rancher Manager - Retrieving API Token ...."
        fi

        # Step 2: Extract the Bearer token from the login response
        bearer_token=$(echo "$response" | jq -r '.token')

        # Check if we successfully retrieved the token
        if [ -z "$bearer_token" ]; then
            log_error "      Failed to retrieve the Bearer token - Bearer token variable is empty. Full response is $response"
            exit 1
        else
            log "      Successfully retrieved the Bearer token - Bearer token is $bearer_token"
        fi
    else
        log "      Valid bearer token found, proceeding with next steps."
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
    log "      [Log] - Running command: $1"
    # Run the command and capture both stdout and stderr
    output=$(eval "$1" 2>&1)
    status=$?
    # Check if the command was successful
    if [ $status -ne 0 ]; then
        log_error "      Command failed: $1"
        log_error "      Reason: $output"
        exit 1
    else
        log "      [Log] - Command succeeded"
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
        --starting_step)
            starting_step="$2"
            validate_non_empty "starting_step" "$starting_step"  # Validate non-empty value for starting_step
            validate_integer "starting_step" "$starting_step"  # Validate starting_step as an integer
            shift 2
            ;;
        
        --cert_version)
            cert_version="$2"
            validate_non_empty "cert_version" "$cert_version"  # Validate non-empty value for cert_version
            shift 2
            ;;
        
        --email)
            email="$2"
            validate_non_empty "email" "$email"  # Validate non-empty value for email
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
            shift 2
            ;;
        
        --harbor_url)
            harbor_url="$2"
            validate_non_empty "harbor_url" "$harbor_url"  # Validate non-empty value for harbor_url
            shift 2
            ;;
        
        --aws_default_region)
            aws_default_region="$2"
            validate_non_empty "aws_default_region" "$aws_default_region"  # Validate non-empty value for aws_default_region
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
if [[ -z "$starting_step" || -z "$cert_version" || -z "$email" || -z "$default_pass" || -z "$domain" || -z "$rancher_version" || -z "$rancher_url" || -z "$s3_access_key" || -z "$s3_secret_key" || -z "$s3_region" || -z "$s3_bucket_name" || -z "$s3_endpoint" || -z "$harbor_url" || -z "$aws_default_region" || -z "$aws_access_key" || -z "$aws_secret_key" || -z "$dsc_count" ]]; then
    echo "Missing required arguments."
    usage
    exit 1
fi

#=======================================================================================================================================
#=======================================================================================================================================

#--------------------#
#--- Start Script----#
#--------------------#

###########################
# Note to Users:
# --------------
# This script is designed with a step-based execution functionality, allowing users to specify a starting step.
# By using the `--starting_step` argument, you can choose to begin execution from a particular step, skipping any prior actions.
# 
# To enable this functionality, each major action within the script is encapsulated in its own function. 
# The script will conditionally execute these functions based on the specified starting step.
# 
# For example:
# ------------
# If the script is executed with `--starting_step 4`, it will begin at step 4 and proceed sequentially,
# executing steps 4, 5, and so on, while skipping steps 1, 2, and 3.
#
# This approach is useful for restarting the script from a specific point if an error occurs or when only certain actions are needed.
###########################

echo "========================================================"
echo "------------------ Start of Script ---------------------"
echo " Automating Rancher Management and components deployment"
echo "========================================================"

#=================================================================================================

#-----------------------------
### 1- Deploy & Configure Helm 
#-----------------------------

step_1() {
    # Print Step Activity
    echo ""
    echo "------------------------------------"
    echo "1- Installing & Configuring Helm ..."
    echo "------------------------------------"
    echo ""

    # Log Actions
    log "   Installing Helm ..."
    # Run Command using the run_command function
    run_command "curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
    # Log results
    log "      Helm tool installed."

    # Print end of step activity
    echo ""
    echo "         Helm tool is now install & ready for use."
    echo "--------------------------------------------------"
    echo ""
}

#=================================================================================================

#-------------------------------
### 2- Add Helm & Updating Repos 
#-------------------------------

step_2() {
    # Print Step Activity
    echo ""
    echo "----------------------------------"
    echo "2- Adding Helm & updating Repos..."
    echo "----------------------------------"
    echo ""

    # Log and add each Helm repository
    log "   Adding Helm Repo jetstack ..."
    run_command "helm repo add jetstack https://charts.jetstack.io"
    log "      Helm repo jetstack added."

    log "   Adding Helm Repo rancher-prime ..."
    run_command "helm repo add rancher-prime https://charts.rancher.com/server-charts/prime"
    log "      Helm repo rancher-prime added."

    log "   Adding Helm Repo rancher-charts ..."
    run_command "helm repo add rancher-charts https://charts.rancher.io"
    log "      Helm repo rancher-charts added."

    log "   Adding Helm Repo bitnami ..."
    run_command "helm repo add bitnami https://charts.bitnami.com/bitnami"
    log "      Helm repo bitnami added."

    log "   Adding Helm Repo rodeo ..."
    run_command "helm repo add rodeo https://rancher.github.io/rodeo"
    log "      Helm repo rodeo added."

    log "   Adding Helm Repo harbor ..."
    run_command "helm repo add harbor https://helm.goharbor.io"
    log "      Helm repo harbor added."

    # Update all repositories
    log "   Updating Helm Repos ..."
    run_command "helm repo update"
    log "      Helm repos updated."

    # Print end of step activity
    echo ""
    echo "         Helm tool is now installed & all repos are added and updated."
    echo "---------------------------------------------------------------------"
    echo ""
}

#=================================================================================================

#----------------------------------------------------
### 3- Install Rancher local-path storage provisioner 
#----------------------------------------------------

step_3() {
    # Print Step Activity
    echo ""
    echo "--------------------------------------------------------"
    echo "3- Installing Rancher local-path storage provisioner ..."
    echo "--------------------------------------------------------"
    echo ""

    # Log Actions for installing local-path provisioner
    log "   Installing Rancher local-path storage provisioner ..."
    run_command "kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.26/deploy/local-path-storage.yaml"
    log "      Rancher local-path storage provisioner installed."

    # Print end of step activity
    echo ""
    echo "         Rancher local-path storage provisioner is installed & configured."
    echo "--------------------------------------------------------------------------"
    echo ""
}


#=================================================================================================

#-------------------------------------
### 4- Deploy & Configure Cert_Manager 
#-------------------------------------

step_4() {
    # Print Step Activity
    echo ""
    echo "-------------------------------------------"
    echo "4- Deploying & Configuring Cert_Manager ..."
    echo "-------------------------------------------"
    echo ""

    # Log Actions for deploying Cert-Manager
    log "   Deploying Cert-Manager with version $cert_version ..."
    run_command "helm install --wait cert-manager jetstack/cert-manager --namespace cert-manager --version $cert_version --set installCRDs=true --create-namespace"
    log "      Cert_Manager Deployed."

    # Print end of step activity
    echo ""
    echo "         Cert_Manager is deployed & configured."
    echo "-----------------------------------------------"
    echo ""
}

#=================================================================================================

#-----------------------------------------------
### 5- Create & Configure A Let's Encrypt Issure 
#-----------------------------------------------

step_5() {
    # Print Step Activity
    echo ""
    echo "-----------------------------------------------------"
    echo "5- Creating & Configuring A Let's Encrypt Issuer ..."
    echo "-----------------------------------------------------"
    echo ""

    # Log Actions for creating Let's Encrypt Issuer
    log "   Creating Let's Encrypt Issuer..."
    
    # Create a temporary file to store the YAML content
    temp_file=$(mktemp)

    # Write the YAML content to the temporary file
    cat <<EOF > "$temp_file"
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

    # Apply the temporary file using kubectl
    output=$(kubectl apply -f "$temp_file" 2>&1)
    status=$?

    # Clean up the temporary file
    rm -f "$temp_file"

    # Check for errors and log the result
    if [ $status -ne 0 ]; then
        log_error "      Failed to create Let's Encrypt Issuer"
        log_error "      Reason: $output"  # Log the output (error details)
        exit 1
    else
        log "      Let's Encrypt Issuer created."
    fi

    # Print end of step activity
    echo ""
    echo "         Let's Encrypt Issuer is created & configured."
    echo "------------------------------------------------------"
    echo ""
}

#=================================================================================================

#----------------------------------------
### 6- Deploy & Configure Rancher Manager 
#----------------------------------------

step_6() {
    # Print Step Activity
    echo ""
    echo "----------------------------------------------"
    echo "6- Deploying & Configuring Rancher Manager ..."
    echo "----------------------------------------------"
    echo ""

    # Log Actions for deploying Rancher Manager
    log "   Deploying Rancher Manager with version $rancher_version ..."
    run_command "helm install --wait rancher rancher-prime/rancher --namespace cattle-system --create-namespace --version $rancher_version --set replicas=1 --set hostname=$rancher_url --set ingress.tls.source=letsEncrypt --set letsEncrypt.email=$email --set bootstrapPassword=$default_pass"
    log "      Rancher Manager Deployed."

    # Print end of step activity
    echo ""
    echo "         Rancher Manager is deployed & configured."
    echo "--------------------------------------------------"
    echo ""
}

#=================================================================================================

#-------------------------------------------------------------
### Deploy & Configure Rancher Backup - several steps included
#-------------------------------------------------------------

#--------------------------------------------------------------------------
### 7- Creating Kubernetes Secret for S3 Access - Rancher Backup Deployment
#--------------------------------------------------------------------------

step_7() {
    # Print Step Activity
    echo ""
    echo "-----------------------------------------------"
    echo "---- Working on Rancher Backup deployment -----"
    echo "7- Creating Kubernetes Secret for S3 Access ..."
    echo "-----------------------------------------------"
    echo ""

    # Log Actions for creating the S3 credentials secret
    log "   Creating Kubernetes secret for S3 access ..."
    output=$(kubectl apply -f - <<EOF 2>&1)
apiVersion: v1
kind: Secret
metadata:
  name: s3-creds
type: Opaque
data:
  accessKey: "$(echo -n $s3_access_key | base64)"
  secretKey: "$(echo -n $s3_secret_key | base64)"
EOF
    status=$?

    # Check for errors and log the result
    if [ $status -ne 0 ]; then
        log_error "      Failed to create S3 credentials secret"
        log_error "      Reason: $output"
        exit 1
    else
        log "      Kubernetes secret created."
    fi

    # Print end of step activity
    echo ""
    echo "         Kubernetes secret for S3 access to be used for Rancher Backup is created."
    echo "----------------------------------------------------------------------------------"
    echo ""
}

#=================================================================================================

#-------------------------------------------------------------
### Deploy & Configure Rancher Backup - several steps included
#-------------------------------------------------------------

#-----------------------------------------------------------------------
### 8- Create Rancher Backup Helm Value File - Rancher Backup Deployment
#-----------------------------------------------------------------------

step_8() {
    # Print Step Activity
    echo ""
    echo "-----------------------------------------------"
    echo "---- Working on Rancher Backup deployment -----"
    echo "8- Creating Rancher Backup Helm Value File ..."
    echo "-----------------------------------------------"
    echo ""

    # Log Actions for creating Rancher Backup Helm values file
    log "   Creating Rancher Backup Helm Value File ..."
    local file_path="yamlfiles/backup-operator-values.yaml"
    mkdir -p "$(dirname "$file_path")" >/dev/null 2>&1
    
    # Capture the error output while writing to the file
    output=$(cat <<EOF > "$file_path" 2>&1
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
)

    # Check for errors and log the result
    if [ $? -eq 0 ] && [ -f "$file_path" ]; then
        log "      Rancher Backup Helm Value File created - $file_path ."
    else
        log_error "      Failed to create Rancher Backup Helm Value File - file name: $file_path"
        log_error "      Reason: $output"  # Print the captured error reason
        exit 1
    fi

    # Print end of step activity
    echo ""
    echo "         Rancher Backup Helm Value File created."
    echo "-------------------------------------------------"
    echo ""
}

#=================================================================================================

#-------------------------------------------------------------
### Deploy & Configure Rancher Backup - several steps included
#-------------------------------------------------------------

#------------------------------------------------------------
### 9- Deploy Rancher Backup CRDs - Rancher Backup Deployment
#------------------------------------------------------------

step_9() {
    # Print Step Activity
    echo ""
    echo "----------------------------------------------"
    echo "---- Working on Rancher Backup deployment ----"
    echo "9- Deploying Rancher Backup CRDs ..."
    echo "----------------------------------------------"
    echo ""

    # Log Actions for deploying Rancher Backup CRDs
    log "   Deploying Rancher Backup CRDs ..."
    run_command "helm install --wait rancher-backup-crd rancher-charts/rancher-backup-crd --namespace cattle-resources-system --create-namespace"
    log "      Rancher Backup CRDs Deployed."

    # Print end of step activity
    echo ""
    echo "         Rancher Backup CRDs are deployed."
    echo "------------------------------------------"
    echo ""
}

#=================================================================================================

#-------------------------------------------------------------
### Deploy & Configure Rancher Backup - several steps included
#-------------------------------------------------------------

#------------------------------------------------------------
### 10- Deploy Rancher Backup - Rancher Backup Deployment
#------------------------------------------------------------


step_10() {
    # Print Step Activity
    echo ""
    echo "----------------------------------------------"
    echo "---- Working on Rancher Backup deployment ----"
    echo "10- Deploying Rancher Backup ..."
    echo "----------------------------------------------"
    echo ""

    # Log Actions for deploying Rancher Backup
    log "   Deploying Rancher Backup ..."
    run_command "helm install --wait rancher-backup rancher-charts/rancher-backup --namespace cattle-resources-system --values $file_path"
    log "      Rancher Backup Deployed."

    # Print end of step activity
    echo ""
    echo "         Rancher Backup is deployed."
    echo "------------------------------------"
    echo ""
}

#=================================================================================================

#-------------------------------------------------------------
### Deploy & Configure Rancher Backup - several steps included
#-------------------------------------------------------------

#---------------------------------------------------------------------------------------------
### 11- Create Rancher Backup encryption-provider-config Yaml File - Rancher Backup Deployment
#---------------------------------------------------------------------------------------------

step_11() {
    # Print Step Activity
    echo ""
    echo "--------------------------------------------------------------------"
    echo "---- Working on Rancher Backup deployment --------------------------"
    echo "11- Creating Rancher Backup encryption-provider-config Yaml File ..."
    echo "--------------------------------------------------------------------"
    echo ""

    # Log Actions for creating the encryption-provider-config YAML file
    log "   Creating Rancher Backup encryption-provider-config Yaml file ..."
    local file_path="yamlfiles/encryption-provider-config.yaml"
    mkdir -p "$(dirname "$file_path")" >/dev/null 2>&1

    # Capture the error output while writing to the file
    output=$(cat <<EOF > "$file_path" 2>&1
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
)

    # Check for errors and log the result
    if [ $? -eq 0 ] && [ -f "$file_path" ]; then
        log "      Rancher Backup encryption-provider-config Yaml file created - $file_path ."
    else
        log_error "      Failed to create encryption-provider-config Yaml - file name: $file_path"
        log_error "      Reason: $output"  # Print the captured error reason
        exit 1
    fi

    # Print end of step activity
    echo ""
    echo "         Rancher Backup encryption-provider-config Yaml file created."
    echo "--------------------------------------------------------------"
    echo ""
}

#=================================================================================================

#-------------------------------------------------------------
### Deploy & Configure Rancher Backup - several steps included
#-------------------------------------------------------------

#--------------------------------------------------------------------------------
### 12- Create Rancher Backup encryptionconfig Secret - Rancher Backup Deployment
#--------------------------------------------------------------------------------

step_12() {
    # Print Step Activity
    echo ""
    echo "-------------------------------------------------------"
    echo "---- Working on Rancher Backup deployment -------------"
    echo "12- Creating Rancher Backup encryptionconfig Secret ..."
    echo "-------------------------------------------------------"
    echo ""

    # Log Actions for creating the Rancher Backup encryptionconfig secret
    log "   Creating Rancher Backup encryptionconfig secret ..."
    run_command "kubectl create secret generic encryptionconfig --from-file=$file_path -n cattle-resources-system"
    log "      Rancher Backup encryptionconfig secret created."

    # Print end of step activity
    echo ""
    echo "         Rancher Backup encryptionconfig secret is created."
    echo "----------------------------------------------------------"
    echo ""
}

#=================================================================================================

#----------------------------------------------
### 13- Deploy & Configure Rancher CSI Benchmark 
#----------------------------------------------

step_13() {
    # Print Step Activity
    echo ""
    echo "----------------------------------------------------"
    echo "13- Deploying & Configuring Rancher CSI Benchmark ..."
    echo "----------------------------------------------------"
    echo ""

    # Log Actions for deploying Rancher CSI Benchmark CRDs
    log "   Deploying Rancher CSI Benchmark CRDs ..."
    run_command "helm install --wait rancher-cis-benchmark-crd rancher-charts/rancher-cis-benchmark-crd --namespace cis-operator-system --create-namespace"
    log "      Rancher CSI Benchmark CRDs Deployed."

    # Log Actions for deploying Rancher CSI Benchmark
    log "   Deploying Rancher CSI Benchmark ..."
    run_command "helm install --wait rancher-cis-benchmark rancher-charts/rancher-cis-benchmark --namespace cis-operator-system"
    log "      Rancher CSI Benchmark Deployed."

    # Print end of step activity
    echo ""
    echo "         Rancher CSI Benchmark is deployed & configured."
    echo "--------------------------------------------------------"
    echo ""
}

#=================================================================================================

#----------------------------------------------
### 14- Deploy & Configure Harbor Image Registry 
#----------------------------------------------

step_14() {
    # Print Step Activity
    echo ""
    echo "----------------------------------------------------"
    echo "14- Deploying & Configuring Harbor Image Registry ..."
    echo "----------------------------------------------------"
    echo ""

    # Log Actions for deploying Harbor Image Registry
    log "   Deploying Harbor Image Registry ..."
    run_command "helm install --wait harbor harbor/harbor --namespace harbor --create-namespace \
        --set expose.ingress.hosts.core=$harbor_url \
        --set expose.ingress.hosts.notary=notary.$domain \
        --set expose.ingress.annotations.'cert-manager\.io/cluster-issuer'=letsencrypt-prod \
        --set expose.tls.certSource=secret \
        --set expose.tls.secret.secretName=tls-harbor \
        --set externalURL=https://$harbor_url \
        --set persistence.persistentVolumeClaim.registry.storageClass=local-path \
        --set persistence.persistentVolumeClaim.jobservice.jobLog.storageClass=local-path \
        --set persistence.persistentVolumeClaim.database.storageClass=local-path \
        --set persistence.persistentVolumeClaim.redis.storageClass=local-path \
        --set persistence.persistentVolumeClaim.trivy.storageClass=local-path \
        --set harborAdminPassword=$default_pass"
    log "      Harbor Image Registry Deployed."

    # Print end of step activity
    echo ""
    echo "         Harbor Image Registry is deployed & configured."
    echo "--------------------------------------------------------"
    echo ""
}

#=================================================================================================

#-----------------------------------------------------
### 15- Create AWS Cloud Credentails In Rancher manager 
#-----------------------------------------------------

step_15() {
    # Print Step Activity
    echo ""
    echo "---------------------------------------------------------"
    echo "15- Creating AWS Cloud Credentials in Rancher Manager ..."
    echo "---------------------------------------------------------"
    echo ""

    # Log Actions for creating Kubernetes secret for AWS cloud credentials
    log "   Creating Kubernetes Secret For AWS Cloud Creds ..."
    run_command "kubectl create secret -n cattle-global-data generic aws-creds \
        --from-literal=amazonec2credentialConfig-defaultRegion=$aws_default_region \
        --from-literal=amazonec2credentialConfig-accessKey=$aws_access_key \
        --from-literal=amazonec2credentialConfig-secretKey=$aws_secret_key"
    log "      Kubernetes Secret created."

    # Log Actions for annotating Kubernetes secret for AWS cloud credentials
    log "   Annotating Kubernetes Secret For AWS Cloud Creds ..."
    run_command "kubectl annotate secret -n cattle-global-data aws-creds provisioning.cattle.io/driver=aws"
    log "      Kubernetes Secret annotated."

    # Print end of step activity
    echo ""
    echo "         Rancher Manager AWS Cloud Credentials configured."
    echo "----------------------------------------------------------"
    echo ""
}

#=================================================================================================

#-------------------------------------------------
### 16- Create A Rancher manager API Bearrer Token 
#-------------------------------------------------

step_16() {
    # Print Step Activity
    echo ""
    echo "----------------------------------------------------"
    echo "16- Creating A Rancher Manager API Bearer Token ..."
    echo "----------------------------------------------------"
    echo ""

    # Log Actions for checking if bearer_token is already available and if not create one
    log "   Checking if bearer_token API token is already available ..."
    authenticate_and_get_token

    # Print end of step activity
    echo ""
    echo "         Rancher Manager API Token generated & retrieved."
    echo "---------------------------------------------------------"
    echo ""
}

#=================================================================================================

#--------------------------------------------------------
### 17- Update the Rancher agent-tls-mode to System Store 
#--------------------------------------------------------

step_17() {
    # Print Step Activity
    echo ""
    echo "-----------------------------------------------------------"
    echo "17- Updating the Rancher agent-tls-mode to System Store ..."
    echo "-----------------------------------------------------------"
    echo ""

    # Log Actions for checking if Rancher Manager is up and running
    log "   Checking if Rancher Manager is Up & Running ..."
    check_rancher_manager "$rancher_url"

    # Log Actions for checking if bearer_token is already available and if not create one
    log "   Checking if bearer_token API token is already available ..."
    authenticate_and_get_token

    # Log Actions for retrieving the current agent-tls-mode setting value
    log "   Retrieving the current agent-tls-mode setting value ..."
    # Fetch the current value of agent-tls-mode
    current_value=$(curl -s -X GET "https://${rancher_url}/v3/settings/agent-tls-mode" \
        -H "Authorization: Bearer $bearer_token" \
        -H "Content-Type: application/json" | jq -r '.value')

    # Check if the current_value indicates success
    if echo "$current_value" | grep -q '"id"'; then
        log "      Successfully retrieved the agent-tls-mode setting value."
    else
        log_error "Failed to retrieve the agent-tls-mode setting value. Full response is $current_value"
        exit 1
    fi

    # Check if the current value is already 'System Store'
    if [ "$current_value" == "System Store" ]; then
        log "      agent-tls-mode is already set to 'System Store'. Skipping update."
    else
        log "      Updating Rancher agent-tls-mode to 'System Store' ..."
        # Update the agent-tls-mode setting
        response=$(curl -s -L -X PUT "https://${rancher_url}/v3/settings/agent-tls-mode" \
            -H "Authorization: Bearer $bearer_token" \
            -H "Content-Type: application/json" \
            -d '{"value": "System Store"}')
        
        # Check if the response indicates success
        if echo "$response" | grep -q '"id"'; then
            log "      Successfully initiated update to 'System Store'."
            echo "Successfully initiated update to 'System Store'."
        else
            log_error "Failed to update agent-tls-mode. Full response is $response"
            exit 1
        fi

        # Verify the updated value of agent-tls-mode
        updated_value=$(curl -s -X GET "https://${rancher_url}/v3/settings/agent-tls-mode" \
            -H "Authorization: Bearer $bearer_token" \
            -H "Content-Type: application/json" | jq -r '.value')

        if [ "$updated_value" == "System Store" ]; then
            log "      Successfully updated agent-tls-mode to 'System Store'."
        else
            log_error "The agent-tls-mode is not updated to 'System Store'. Current value is: $updated_value"
            exit 1
        fi
    fi

    # Print end of step activity
    echo ""
    echo "         Rancher Manager agent-tls-mode setting updated."
    echo "--------------------------------------------------------"
    echo ""
}

#=================================================================================================

#---------------------------------
### 18- Create Downstream Clusters 
#---------------------------------

step_18() {
    # Print Step Activity
    echo ""
    echo "--------------------------------------------------"
    echo "18- Creating and Importing Downstream Clusters ..."
    echo "--------------------------------------------------"
    echo ""

    # Log Actions for checking if Rancher Manager is up and running
    log "   Checking if Rancher Manager is Up & Running ..."
    check_rancher_manager "$rancher_url"

    # Ensure bearer_token is set, if not, authenticate and retrieve it
    authenticate_and_get_token

    # Log how many downstream clusters will be created
    log "   The total downstream clusters to be created are: $dsc_count ..."
    log "   Creating downstream clusters ..."

    # Loop to create and import downstream clusters
    for i in $(seq 1 "$dsc_count"); do
        # Generate the cluster name using the default prefix and a formatted number (01, 02, 03, etc.)
        local cluster_name="ts-suse-demo-dsc-$(printf "%02d" $i)"  # Ensures numbers are zero-padded
        echo "Checking if cluster $cluster_name already exists..."

        # Step 1: Check if a cluster with the same name already exists
        existing_cluster_id=$(curl -s -X GET "https://${rancher_url}/v3/clusters" \
            -H "Authorization: Bearer $bearer_token" \
            -H "Content-Type: application/json" | jq -r ".data[] | select(.name == \"$cluster_name\") | .id")

        if [ -n "$existing_cluster_id" ]; then
            echo "Cluster $cluster_name already exists with ID: $existing_cluster_id. Skipping creation."
            continue  # Skip the creation if the cluster already exists
        fi

        # Step 2: Create the cluster in Rancher using the Rancher API
        cluster_id=$(curl -s -X POST "https://${rancher_url}/v3/clusters" \
            -H "Authorization: Bearer $bearer_token" \
            -H "Content-Type: application/json" \
            -d '{"type":"cluster","name":"'"$cluster_name"'"}' | jq -r '.id')

        # Check if the cluster creation was successful, if not, print an error message
        if [ -z "$cluster_id" ]; then
            echo "Failed to create cluster $cluster_name. No cluster ID returned."
            continue  # Skip to the next cluster if creation failed
        fi
        echo "Cluster $cluster_name created with ID: $cluster_id"

        # Step 3: Fetch registration tokens for the newly created cluster
        registration_token=$(curl -s -X GET "https://${rancher_url}/v3/clusterregistrationtoken" \
            -H "Authorization: Bearer $bearer_token" \
            -H "Content-Type: application/json" | jq -r ".data[] | select(.clusterId == \"$cluster_id\") | .token")

        # Check if we successfully retrieved the token
        if [ -z "$registration_token" ]; then
            echo "Failed to retrieve the registration token for cluster $cluster_name. Exiting."
            continue  # Skip to the next cluster if token retrieval failed
        fi

        # Step 4: Output the retrieved token and other commands
        import_command="kubectl apply -f https://rancher.rancher-demo.com/v3/import/$(echo "$registration_token" | sed 's/\//\\\//g')_$(echo "$cluster_id").yaml"

        # Output the import commands for the user
        echo "Import commands for $cluster_name:"
        echo "1. Default command:"
        echo "$import_command"
        echo ""
        echo "2. Insecure command (useful for self-signed certs):"
        echo "curl --insecure -sfL https://rancher.rancher-demo.com/v3/import/$(echo "$registration_token" | sed 's/\//\\\//g')_$(echo "$cluster_id").yaml | kubectl apply -f -"
        echo ""
        echo "3. Node command:"
        echo "sudo docker run -d --privileged --restart=unless-stopped --net=host -v /etc/kubernetes:/etc/kubernetes -v /var/run:/var/run registry.rancher.com/rancher/rancher-agent:v2.9.2 --server https://rancher.rancher-demo.com --token $registration_token"
        echo "-----------------------------------------------------"
    done

    # Print end of step activity
    echo ""
    echo "         Downstream clusters created and import commands generated."
    echo "------------------------------------------------------------"
    echo ""
}

#=================================================================================================

#-------------------------------------------------
### Starting script from the provided step numner 
#-------------------------------------------------

#-------------------------------------
### Print starting point (step number) 
#-------------------------------------

echo ""
echo "----------------------------------------"
echo "Starting from step number $starting_step"
echo "----------------------------------------"
echo ""

# Execute steps conditionally based on the start_step
if (( start_step <= 1 )); then step_1; fi
if (( start_step <= 2 )); then step_2; fi
if (( start_step <= 3 )); then step_3; fi
if (( start_step <= 4 )); then step_4; fi
if (( start_step <= 5 )); then step_5; fi
if (( start_step <= 6 )); then step_6; fi
if (( start_step <= 7 )); then step_7; fi
if (( start_step <= 8 )); then step_8; fi
if (( start_step <= 9 )); then step_9; fi
if (( start_step <= 10 )); then step_10; fi
if (( start_step <= 11 )); then step_11; fi
if (( start_step <= 12 )); then step_12; fi
if (( start_step <= 13 )); then step_13; fi
if (( start_step <= 14 )); then step_14; fi
if (( start_step <= 15 )); then step_15; fi
if (( start_step <= 16 )); then step_16; fi
if (( start_step <= 17 )); then step_17; fi
if (( start_step <= 18 )); then step_18; fi

#=================================================================================================
#=================================================================================================

#---------------------#
#--- End of Script----#
#---------------------#

# Print end of script
echo ""
echo "========================================================"
echo "------------------- End of Script ----------------------"
echo "----  Enjoy your lab environment - Best of luck  -------"
echo "========================================================"

#=================================================================================================
