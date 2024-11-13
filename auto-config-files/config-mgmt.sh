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

    # First loop to check if Rancher Manager is responding (HTTP 200)
    log "   [log] - Checking if Rancher Manager at $rancher_url is responsive ..."
    while true; do
        # Use curl to check if Rancher Manager is responding
        response=$(curl -s -o /dev/null -w "%{http_code}" "https://$rancher_url")
        # Check if HTTP response code is 200 (OK) in a one-liner
        [ "$response" -eq 200 ] && { log "   [log] - Rancher Manager is responsive!"; break; } || { log "   [log] - Rancher Manager is not responsive yet. Retrying in 10 seconds ..."; sleep 10; }
    done

    # Second loop to check authentication and get token generation
    # Check if bearer_token is already set, if set then skip 
    log "   [log] - Checking if Rancher Manager at $rancher_url is fully functional - authenticating ..."
    while true; do
        log "   [log] - Trying to authenticate with Rancher Manager ..."
        response=$(curl -s -X POST "https://$rancher_url/v3-public/localProviders/local?action=login" \
        -H "Content-Type: application/json" \
        -d '{
                "username": "admin",
                "password": "'"$default_pass"'"
            }')

        # Extract error message if available
        error_message=$(echo "$response" | jq -r '.message // empty')
        # Check if there's an error during authentication in one line
        [ -n "$error_message" ] && { log "   [log] - Authentication failed with error: $error_message"; log "   [log] - Retrying authentication in 10 seconds ..."; sleep 10; } || { log "   [log] - Successfully authenticated to Rancher Manager & temp token is created."; temp_token=$(echo "$response" | jq -r '.token'); break; }
    done
}

# Function to authenticate with Rancher Manager and generate a token adding it to bearer_token variable
authenticate_and_get_token() {
    # Check if bearer_token is set and starts with "token:"
    log "   [log] - Checking if bearer_token is already available ..."
    if [[ -z "$bearer_token" || ! "$bearer_token" =~ ^token- ]]; then
        # Log Actions for authenticating with Rancher Manager API to retrieve Bearer token
        log "   [log] - bearer_token API token was not found, generating one ..."
        log "   [log] - Authenticating with Rancher Manager and Retrieving API Token ..."

        # Log Actions for checking if Rancher Manager is up and running
        log "   [log] - Checking if Rancher Manager is Up & Running ..."
        check_rancher_manager
        log "   [log] - Rancher Manager is now Up & Running, generating a permanent token..."

        # Step 1: Send authentication request to Rancher Manager to retrieve token
        response=$(curl -s -X POST "https://$rancher_url/v3-public/localProviders/local?action=login" \
          -H "Content-Type: application/json" \
          -d '{
                "username": "admin",
                "password": "'"$default_pass"'"
              }')

        # Check if the response contains an error
        [[ -n "$(echo "$response" | jq -r '.message // empty')" ]] && log_error "   Error during authentication: $(echo "$response" | jq -r '.message')" && exit 1

        log "   [log] - Successfully authenticated to Rancher Manager - Retrieving API Token ...."

        # Step 2: Extract the Bearer token from the login response
        bearer_token=$(echo "$response" | jq -r '.token')

        # Check if we successfully retrieved the token and it starts with "token:"
        [[ -n "$bearer_token" && "$bearer_token" =~ ^token: ]] && log_error "   Failed to retrieve a valid Bearer token. Full response: $response" && exit 1 || log "   [log] - Successfully retrieved a valid Bearer token: $bearer_token"
    else
        log "   [log] - Valid bearer token found, - Bearer token is $bearer_token - proceeding with next steps."
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
echo ""

#=================================================================================================

#-----------------------------
### 1- Deploy & Configure Helm 
#-----------------------------

step_1() {
    # Print Step Activity
    echo "------------------------------------"
    echo "1- Installing & Configuring Helm ..."
    echo "------------------------------------"
    echo ""

    # Perform & Log Actions
    log "Installing Helm ..."
    log "   [log] - Running Command: curl -s https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3"
    output=$(curl -s https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 2>&1 | bash -s -- 2>&1)

    # Capture the exit status of the previous command; if the command failed (non-zero status), log the error and exit; otherwise, log success 
    status=$?; if [ $status -ne 0 ]; then log_error "   Command failed - Reason: $output"; exit 1; else log "   [Log] - Command succeeded"; log "   Helm tool installed."; fi

    # Print end of step activity
    echo "*****************************************"
    echo "Helm tool is now install & ready for use."
    echo "-----------------------------------------"
    echo ""
}

#=================================================================================================

#-------------------------------
### 2- Add Helm & Updating Repos 
#-------------------------------

step_2() {
    # Print Step Activity
    echo "----------------------------------"
    echo "2- Adding Helm & updating Repos..."
    echo "----------------------------------"
    echo ""

    # Define an array with Helm repositories and their URLs
    repos=(
        "jetstack https://charts.jetstack.io"
        "rancher-prime https://charts.rancher.com/server-charts/prime"
        "rancher-charts https://charts.rancher.io"
        "bitnami https://charts.bitnami.com/bitnami"
        "rodeo https://rancher.github.io/rodeo"
        "harbor https://helm.goharbor.io"
    )

    # Loop through the array and add each Helm repo
    for repo in "${repos[@]}"; do
        # Split the repo name and URL
        repo_name=$(echo $repo | awk '{print $1}')
        repo_url=$(echo $repo | awk '{print $2}')
        
        # Add Repo & Log the action
        log "Adding Helm repo: $repo_name with URL: $repo_url ..."
        log "   [log] - Running Command: helm repo add "$repo_name" "$repo_url""
        output=$(helm repo add "$repo_name" "$repo_url" 2>&1)
        # Capture the exit status of the previous command; if the command failed (non-zero status), log the error and exit; otherwise, log success 
        status=$?; if [ $status -ne 0 ]; then log_error "   Command failed - Reason: $output"; exit 1; else log "   [Log] - Command succeeded"; log "   Successfully added Helm repo: $repo_name."; fi
    done

    log "   [log] - All Helm Repos are added, updating Helm Repos ..."

    # Update all repositories
    log "Updating Helm Repos ..."
    log "   [log] - Running Command: helm repo update"
    output=$(helm repo update > /dev/null 2>&1)
    log "      Helm repos updated."

    # Print end of step activity
    echo "*****************************************"
    echo "Helm tool is now installed & all repos are added and updated."
    echo "-------------------------------------------------------------"
    echo ""
}

#=================================================================================================

#----------------------------------------------------
### 3- Install Rancher local-path storage provisioner 
#----------------------------------------------------

step_3() {
    # Print Step Activity
    echo "--------------------------------------------------------"
    echo "3- Installing Rancher local-path storage provisioner ..."
    echo "--------------------------------------------------------"
    echo ""

    # Log Actions for installing local-path provisioner
    log "Installing Rancher local-path storage provisioner ..."
    log "   [log] - Running Command: kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.26/deploy/local-path-storage.yaml"
    output=$(kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.26/deploy/local-path-storage.yaml 2>&1)
    # Capture the exit status of the previous command; if the command failed (non-zero status), log the error and exit; otherwise, log success 
    status=$?; if [ $status -ne 0 ]; then log_error "   Command failed - Reason: $output"; exit 1; else log "   [Log] - Command succeeded"; log "   Rancher local-path storage provisioner installed."; fi

    # Print end of step activity
    echo "*****************************************"
    echo "Rancher local-path storage provisioner is installed & configured."
    echo "-----------------------------------------------------------------"
    echo ""
}

#=================================================================================================

#-------------------------------------
### 4- Deploy & Configure Cert_Manager 
#-------------------------------------

step_4() {
    # Print Step Activity
    echo "-------------------------------------------"
    echo "4- Deploying & Configuring Cert_Manager ..."
    echo "-------------------------------------------"
    echo ""

    # Perform & Log Actions for deploying Cert-Manager
    log "Deploying Cert-Manager with version $cert_version ..."
    log "   [log] - Running Command: helm install --wait cert-manager jetstack/cert-manager [Options] version "$cert_version""
    output=$(helm install --wait \
        cert-manager jetstack/cert-manager \
        --namespace cert-manager \
        --version "$cert_version" \
        --set installCRDs=true \
        --create-namespace 2>&1)
    # Capture the exit status of the previous command; if the command failed (non-zero status), log the error and exit; otherwise, log success 
    status=$?; if [ $status -ne 0 ]; then log_error "   Command failed - Reason: $output"; exit 1; else log "   [Log] - Command succeeded"; log "   Cert_Manager Deployed."; fi

    # Print end of step activity
    echo "*****************************************"
    echo "Cert_Manager is deployed & configured."
    echo "-----------------------------------------"
    echo ""
}

#=================================================================================================

#-----------------------------------------------
### 5- Create & Configure A Let's Encrypt Issure 
#-----------------------------------------------

step_5() {
    # Print Step Activity
    echo "-----------------------------------------------------"
    echo "5- Creating & Configuring A Let's Encrypt Issuer ..."
    echo "-----------------------------------------------------"
    echo ""

    # Log Actions for creating Let's Encrypt Issuer
    log "Creating Let's Encrypt Issuer..."
    
    # Log Actions for creating Let's Encrypt Issuer Yaml file
    log "   [log] - Creating Let's Encrypt Issuer Yaml File ..."
    # Create folder or make sure folder is created
    local file_path="yamlfiles/lets-encrypt-issuer.yaml"
    mkdir -p "$(dirname "$file_path")" >/dev/null 2>&1
    # Write the YAML content to the file
    log "   [log] - Running Command: cat <<EOF > "$file_path" ... file content"
    output=$( { cat <<EOF > "$file_path"; } 2>&1
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
)
    # Capture the exit status of the previous command; if the command failed (non-zero status), log the error and exit; otherwise, log success 
    status=$?; if [ $status -ne 0 ]; then log_error "   Command failed - Reason: $output"; exit 1; else log "   [Log] - Command succeeded"; log "   Let's Encrypt Issuer Yaml File created."; fi

    # Apply & log the yaml file using kubectl
    log "Applying the yaml file to kubernetes to create the issuer ..."
    log "   [log] - Running Command: kubectl apply -f "$file_path""
    output=$(kubectl apply -f "$file_path" 2>&1)
    # Capture the exit status of the previous command; if the command failed (non-zero status), log the error and exit; otherwise, log success 
    status=$?; if [ $status -ne 0 ]; then log_error "   Command failed - Reason: $output"; exit 1; else log "   [Log] - Command succeeded"; log "   Let's Encrypt Issuer created."; fi

    # Print end of step activity
    echo "*****************************************"
    echo "Let's Encrypt Issuer is created & configured."
    echo "---------------------------------------------"
    echo ""
}

#=================================================================================================

#----------------------------------------
### 6- Deploy & Configure Rancher Manager 
#----------------------------------------

step_6() {
    # Print Step Activity
    echo "----------------------------------------------"
    echo "6- Deploying & Configuring Rancher Manager ..."
    echo "----------------------------------------------"
    echo ""

    # Log Actions for deploying Rancher Manager
    log "Deploying Rancher Manager with version $rancher_version ..."
    log "   [log] - Running Command: helm install --wait rancher rancher-prime/ranche [Options] - version $rancher_version hostname $rancher_url email=$email Password=$default_pass"
    output=$(helm install --wait \
        rancher rancher-prime/rancher \
        --namespace cattle-system \
        --create-namespace \
        --version $rancher_version \
        --set replicas=1 \
        --set hostname=$rancher_url \
        --set ingress.tls.source=letsEncrypt \
        --set letsEncrypt.email=$email \
        --set bootstrapPassword=$default_pass 2>&1)
    # Capture the exit status of the previous command; if the command failed (non-zero status), log the error and exit; otherwise, log success 
    status=$?; if [ $status -ne 0 ]; then log_error "   Command failed - Reason: $output"; exit 1; else log "   [Log] - Command succeeded"; log "   Rancher Manager Deployed."; fi

    # Print end of step activity
    echo "*****************************************"
    echo "Rancher Manager is deployed & configured."
    echo "-----------------------------------------"
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
    echo "-----------------------------------------------"
    echo "---- Working on Rancher Backup deployment -----"
    echo "7- Creating Kubernetes Secret for S3 Access ..."
    echo "-----------------------------------------------"
    echo ""

    # Log Actions for creating Secret for S3 Access
    log "Creating Secret for S3 Access ..."
    # Execute kubectl apply with heredoc content, using 'bash -c' to ensure proper handling of EOF.
    # We use 'bash -c' to run the kubectl command in a subshell, allowing the shell to interpret
    # the heredoc (EOF syntax) as intended. Without 'bash -c', the shell misinterprets the EOF block
    # and outputs errors. By using 'bash -c', we isolate the heredoc content within the subshell,
    # capturing both stdout and stderr into the variable 'output'.
    log "   [log] - Running Command: kubectl apply -f - <<EOF ... file content"
    output=$(bash -c "kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: s3-creds
type: Opaque
data:
  accessKey: \"$(echo -n $s3_access_key | base64)\"
  secretKey: \"$(echo -n $s3_secret_key | base64)\"
EOF
" 2>&1)
    # Capture the exit status of the previous command; if the command failed (non-zero status), log the error and exit; otherwise, log success 
    status=$?; if [ $status -ne 0 ]; then log_error "   Command failed - Reason: $output"; exit 1; else log "   [Log] - Command succeeded"; log "   Kubernetes secret created."; fi

    # Print end of step activity
    echo "*****************************************"
    echo "Kubernetes secret for S3 access to be used for Rancher Backup is created."
    echo "-------------------------------------------------------------------------"
    echo ""
}

#=================================================================================================

#-------------------------------------------------------------
### Deploy & Configure Rancher Backup - several steps included
#-------------------------------------------------------------

#------------------------------------------------------------
### 8- Deploy Rancher Backup CRDs - Rancher Backup Deployment
#------------------------------------------------------------

step_8() {
    # Print Step Activity
    echo "----------------------------------------------"
    echo "---- Working on Rancher Backup deployment ----"
    echo "8- Deploying Rancher Backup CRDs ..."
    echo "----------------------------------------------"
    echo ""

    # Perform & Log Actions for deploying Rancher Backup CRDs
    log "Deploying Rancher Backup CRDs ..."
    log "   [log] - Running Command: helm install --wait rancher-backup-crd rancher-charts/rancher-backup-crd --namespace cattle-resources-system --create-namespace"
    output=$(helm install --wait rancher-backup-crd rancher-charts/rancher-backup-crd --namespace cattle-resources-system --create-namespace 2>&1)
    # Capture the exit status of the previous command; if the command failed (non-zero status), log the error and exit; otherwise, log success 
    status=$?; if [ $status -ne 0 ]; then log_error "   Command failed - Reason: $output"; exit 1; else log "   [Log] - Command succeeded"; log "   Rancher Backup CRDs Deployed."; fi

    # Print end of step activity
    echo "*****************************************"
    echo "Rancher Backup CRDs are deployed."
    echo "---------------------------------"
    echo ""
}

#=================================================================================================

#-------------------------------------------------------------
### Deploy & Configure Rancher Backup - several steps included
#-------------------------------------------------------------

#------------------------------------------------------------
### 9- Deploy Rancher Backup - Rancher Backup Deployment
#------------------------------------------------------------

step_9() {
    # Print Step Activity
    echo "----------------------------------------------"
    echo "---- Working on Rancher Backup deployment ----"
    echo "9- Deploying Rancher Backup ..."
    echo "----------------------------------------------"
    echo ""

    # Log Actions for creating Let's Encrypt Issuer Yaml file
    log "Creating Rancher Backup Helm Value File ..."
    # Create folder or make sure folder is created
    local file_path="yamlfiles/rancher-backup-helm-value.yaml"
    mkdir -p "$(dirname "$file_path")" >/dev/null 2>&1
    # Write the YAML content to the file
    log "   [log] - Running Command: cat <<EOF > "$file_path" ... file content"
    output=$( { cat <<EOF > "$file_path"; } 2>&1
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
    # Capture the exit status of the previous command; if the command failed (non-zero status), log the error and exit; otherwise, log success 
    status=$?; if [ $status -ne 0 ]; then log_error "   Command failed - Reason: $output"; exit 1; else log "   [Log] - Command succeeded"; log "   Rancher Backup Helm Value File created."; fi

    # Apply & log the yaml file using kubectl
    log "Deploying the Rancher Backup ..."
    log "   [log] - Running Command: helm install --wait rancher-backup rancher-charts/rancher-backup [Options] file $file_path"
    output=$(helm install --wait rancher-backup rancher-charts/rancher-backup --namespace cattle-resources-system --values $file_path 2>&1)
    # Capture the exit status of the previous command; if the command failed (non-zero status), log the error and exit; otherwise, log success 
    status=$?; if [ $status -ne 0 ]; then log_error "   Command failed - Reason: $output"; exit 1; else log "   [Log] - Command succeeded"; log "   Rancher Backup Deployed."; fi

    # Print end of step activity
    echo "*****************************************"
    echo "Rancher Backup is deployed."
    echo "---------------------------"
    echo ""
}

#=================================================================================================

#-------------------------------------------------------------
### Deploy & Configure Rancher Backup - several steps included
#-------------------------------------------------------------

#---------------------------------------------------------------------------------------------
### 10- Create Rancher Backup encryption-provider-config Yaml File - Rancher Backup Deployment
#---------------------------------------------------------------------------------------------

step_10() {
    # Print Step Activity
    echo "-------------------------------------------------------"
    echo "---- Working on Rancher Backup deployment -------------"
    echo "10- Creating Rancher Backup encryptionconfig secret ..."
    echo "-------------------------------------------------------"
    echo ""

    # Log Actions for creating Let's Encrypt Issuer Yaml file
    log "Creating Rancher Backup encryption-provider-config Yaml file ..."
    # Create folder or make sure folder is created
    local file_path="yamlfiles/encryption-provider-config.yaml"
    mkdir -p "$(dirname "$file_path")" >/dev/null 2>&1
    # Write the YAML content to the file
    log "   [log] - Running Command: cat <<EOF > "$file_path" ... file content"
    output=$( { cat <<EOF > "$file_path"; } 2>&1
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
    # Capture the exit status of the previous command; if the command failed (non-zero status), log the error and exit; otherwise, log success 
    status=$?; if [ $status -ne 0 ]; then log_error "   Command failed - Reason: $output"; exit 1; else log "   [Log] - Command succeeded"; log "   Rancher Backup encryption-provider-config Yaml File created."; fi

    # Apply & log the yaml file using kubectl
    log "Deploying the Rancher Backup encryptionconfig secret ..."
    log "   [log] - Running Command: kubectl create secret generic encryptionconfig --from-file=$file_path -n cattle-resources-system"
    output=$(kubectl create secret generic encryptionconfig --from-file=$file_path -n cattle-resources-system 2>&1)
    # Capture the exit status of the previous command; if the command failed (non-zero status), log the error and exit; otherwise, log success 
    status=$?; if [ $status -ne 0 ]; then log_error "   Command failed - Reason: $output"; exit 1; else log "   [Log] - Command succeeded"; log "   Rancher Backup encryptionconfig secret created."; fi

    # Print end of step activity
    echo "*****************************************"
    echo "Rancher Backup encryptionconfig secret is created."
    echo "--------------------------------------------------"
    echo ""
}

#=================================================================================================

#----------------------------------------------
### 11- Deploy & Configure Rancher CSI Benchmark 
#----------------------------------------------

step_11() {
    # Print Step Activity
    echo "----------------------------------------------------"
    echo "11- Deploying & Configuring Rancher CSI Benchmark ..."
    echo "----------------------------------------------------"
    echo ""

    # Log Actions for deploying Rancher CSI Benchmark CRDs
    log "Deploying Rancher CSI Benchmark CRDs ..."
    log "   [log] - Running Command: helm install --wait rancher-cis-benchmark-crd rancher-charts/rancher-cis-benchmark-crd --namespace cis-operator-system --create-namespace"
    output=$(helm install --wait rancher-cis-benchmark-crd rancher-charts/rancher-cis-benchmark-crd --namespace cis-operator-system --create-namespace 2>&1)
    # Capture the exit status of the previous command; if the command failed (non-zero status), log the error and exit; otherwise, log success 
    status=$?; if [ $status -ne 0 ]; then log_error "   Command failed - Reason: $output"; exit 1; else log "   [Log] - Command succeeded"; log "   Rancher CSI Benchmark CRDs Deployed."; fi

    # Log Actions for deploying Rancher CSI Benchmark
    log "Deploying Rancher CSI Benchmark ..."
    log "   [log] - Running Command: helm install --wait rancher-cis-benchmark rancher-charts/rancher-cis-benchmark --namespace cis-operator-system"
    output=$(helm install --wait rancher-cis-benchmark rancher-charts/rancher-cis-benchmark --namespace cis-operator-system 2>&1)
    # Capture the exit status of the previous command; if the command failed (non-zero status), log the error and exit; otherwise, log success 
    status=$?; if [ $status -ne 0 ]; then log_error "   Command failed - Reason: $output"; exit 1; else log "   [Log] - Command succeeded"; log "   Rancher CSI Benchmark Deployed."; fi

    # Print end of step activity
    echo "*****************************************"
    echo "Rancher CSI Benchmark is deployed & configured."
    echo "-----------------------------------------------"
    echo ""
}

#=================================================================================================

#----------------------------------------------
### 12- Deploy & Configure Harbor Image Registry 
#----------------------------------------------

step_12() {
    # Print Step Activity
    echo "----------------------------------------------------"
    echo "12- Deploying & Configuring Harbor Image Registry ..."
    echo "----------------------------------------------------"
    echo ""

    # Log Actions for deploying Harbor Image Registry
    log "Deploying Harbor Image Registry ..."
    log "   [log] - Running Command: helm install --wait harbor harbor/harbor [Options] - hostname $harbor_url Password $default_pass"
    output=$(helm install --wait \
        harbor harbor/harbor \
        --namespace harbor \
        --create-namespace \
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
        --set harborAdminPassword=$default_pass 2>&1)
    # Capture the exit status of the previous command; if the command failed (non-zero status), log the error and exit; otherwise, log success 
    status=$?; if [ $status -ne 0 ]; then log_error "   Command failed - Reason: $output"; exit 1; else log "   [Log] - Command succeeded"; log "   Harbor Image Registry Deployed."; fi

    # Print end of step activity
    echo "*****************************************"
    echo "Harbor Image Registry is deployed & configured."
    echo "-----------------------------------------------"
    echo ""
}

#=================================================================================================

#-----------------------------------------------------
### 13- Create AWS Cloud Credentails In Rancher manager 
#-----------------------------------------------------

step_13() {
    # Print Step Activity
    echo "---------------------------------------------------------"
    echo "13- Creating AWS Cloud Credentials in Rancher Manager ..."
    echo "---------------------------------------------------------"
    echo ""

    # Perform & Log Actions for creating Kubernetes secret for AWS cloud credentials
    log "Creating Kubernetes Secret For AWS Cloud Creds ..."
    log "   [log] - Running Command: kubectl create secret -n cattle-global-data generic aws-creds [Options] - region $aws_default_region ..."
    output=$(kubectl create secret -n cattle-global-data generic aws-creds \
        --from-literal=amazonec2credentialConfig-defaultRegion=$aws_default_region \
        --from-literal=amazonec2credentialConfig-accessKey=$aws_access_key \
        --from-literal=amazonec2credentialConfig-secretKey=$aws_secret_key 2>&1)
    # Capture the exit status of the previous command; if the command failed (non-zero status), log the error and exit; otherwise, log success 
    status=$?; if [ $status -ne 0 ]; then log_error "   Command failed - Reason: $output"; exit 1; else log "   [Log] - Command succeeded"; log "   Kubernetes Secret created."; fi

    # Perform & Log Actions for annotating Kubernetes secret for AWS cloud credentials
    log "Annotating Kubernetes Secret For AWS Cloud Creds ..."
    log "   [log] - Running Command: kubectl annotate secret -n cattle-global-data aws-creds provisioning.cattle.io/driver=aws"
    output=$(kubectl annotate secret -n cattle-global-data aws-creds provisioning.cattle.io/driver=aws 2>&1)
    # Capture the exit status of the previous command; if the command failed (non-zero status), log the error and exit; otherwise, log success 
    status=$?; if [ $status -ne 0 ]; then log_error "   Command failed - Reason: $output"; exit 1; else log "   [Log] - Command succeeded"; log "   Kubernetes Secret annotated."; fi

    # Print end of step activity
    echo "*****************************************"
    echo "Rancher Manager AWS Cloud Credentials configured."
    echo "-------------------------------------------------"
    echo ""
}

#=================================================================================================

#-------------------------------------------------------------------
### 14- Add Helm Chart Repo catalog to Rancher In Management Cluster 
#-------------------------------------------------------------------

step_14() {
    # Print Step Activity
    echo "-----------------------------------------------------------------------"
    echo "14- Adding Helm Chart Repo catalog to Rancher In Management Cluster ..."
    echo "-----------------------------------------------------------------------"
    echo ""

    # Perform & Log Actions for creating Kubernetes secret for AWS cloud credentials
    log "Creating the Rancher Catalog Helm Chart Yaml file for cluster-template ..."
    # Create folder or make sure folder is created
    local file_path="yamlfiles/rancher-helm-catalog-cluster-template.yaml"
    mkdir -p "$(dirname "$file_path")" >/dev/null 2>&1
    # Write the YAML content to the file
    log "   [log] - Running Command: cat <<EOF > "$file_path" ... file content"
    output=$( { cat <<EOF > "$file_path"; } 2>&1
apiVersion: catalog.cattle.io/v1
kind: ClusterRepo
metadata:
  name: cluster-template
  namespace: fleet-local
spec:
  url: https://rancherfederal.github.io/rancher-cluster-templates
EOF
)
    # Capture the exit status of the previous command; if the command failed (non-zero status), log the error and exit; otherwise, log success 
    status=$?; if [ $status -ne 0 ]; then log_error "   Command failed - Reason: $output"; exit 1; else log "   [Log] - Command succeeded"; log "   Rancher Catalog Helm Chart Yaml File created."; fi

    # Apply & log the yaml file using kubectl
    log "Deploying the Rancher Backup encryptionconfig secret ..."
    log "   [log] - Running Command: kubectl apply -f $file_path"
    output=$(kubectl apply -f $file_path 2>&1)
    # Capture the exit status of the previous command; if the command failed (non-zero status), log the error and exit; otherwise, log success 
    status=$?; if [ $status -ne 0 ]; then log_error "   Command failed - Reason: $output"; exit 1; else log "   [Log] - Command succeeded"; log "   Rancher Catalog Helm Chart ClusterRepo created."; fi


    # Print end of step activity
    echo "*****************************************"
    echo "Helm Charts Repo catalog are aded to Rancher."
    echo "---------------------------------------------"
    echo ""
}

#=================================================================================================

#-----------------------------------------------
### 15- Check if Rancher Manager is Up & Running 
#-----------------------------------------------

step_15() {
    # Print Step Activity
    echo "---------------------------------------------------------------"
    echo "15- Checking if Rancher Manager is up, running, & functional ..."
    echo "---------------------------------------------------------------"
    echo ""

    # Perform & Log Actions for checking that Rancher Manager is up & running
    log "Checking if Rancher Manager is up, running, & functional ..."
    check_rancher_manager

    # Print end of step activity
    echo "*****************************************"
    echo "Rancher Manager is now up, running, & functional."
    echo "-------------------------------------------------"
    echo ""
}

#=================================================================================================

#-------------------------------------------------
### 16- Create A Rancher manager API Bearrer Token 
#-------------------------------------------------

step_16() {
    # Print Step Activity
    echo "----------------------------------------------------"
    echo "16- Creating A Rancher Manager API Bearer Token ..."
    echo "----------------------------------------------------"
    echo ""

    # Perform & Log Actions for creating a bearer_token
    log "Creating A Rancher Manager API Bearer Token ..."
    authenticate_and_get_token

    # Print end of step activity
    echo "*****************************************"
    echo "Rancher Manager API Token generated & retrieved."
    echo "------------------------------------------------"
    echo ""
}

#=================================================================================================

#--------------------------------------------------------
### 17- Update the Rancher agent-tls-mode to System Store 
#--------------------------------------------------------

step_17() {
    # Print Step Activity
    echo "-----------------------------------------------------------"
    echo "17- Updating the Rancher agent-tls-mode to System Store ..."
    echo "-----------------------------------------------------------"
    echo ""

    # Perform & Log Actions for Updating the Rancher agent-tls-mode to System Store
    log "Updating the Rancher agent-tls-mode to System Store ..."

    # Perform & Log Actions for checking if Rancher Manager is up and running
    log "First - Checking if Rancher Manager is Up & Running ..."
    check_rancher_manager "$rancher_url"

    # Perform & Log Actions for checking if bearer_token is already available and if not create one
    log "Second - Checking if bearer_token API token is already available ..."
    authenticate_and_get_token

    # Perform & Log Actions for retrieving the current agent-tls-mode setting value
    log "Third - Retrieving the current agent-tls-mode setting value & changing if required ..."
    # Fetch the current value of agent-tls-mode
    current_value=$(curl -s -X GET "https://${rancher_url}/v3/settings/agent-tls-mode" \
        -H "Authorization: Bearer $bearer_token" \
        -H "Content-Type: application/json" | jq -r '.value')

    # Check if the current_value indicates success
    [ -n "$current_value" ] && log "   [log] - Successfully retrieved the agent-tls-mode setting value." || { log_error "   Failed to retrieve the agent-tls-mode setting value. Full response is $current_value"; exit 1; }

    # Check if the current value is already 'System Store'
    if [ "$current_value" == "System Store" ]; then
        log "   [log] - agent-tls-mode is already set to 'System Store'. Skipping update."
    else
        log "   [log] - Rancher agent-tls-mode is not set to 'System Store' - Updating to 'System Store' ..."
        # Update the agent-tls-mode setting
        response=$(curl -s -L -X PUT "https://${rancher_url}/v3/settings/agent-tls-mode" \
            -H "Authorization: Bearer $bearer_token" \
            -H "Content-Type: application/json" \
            -d '{"value": "System Store"}')
        
        # Check if the response indicates success
        if [[ $(echo "$response" | jq -e '.id') ]]; then log "   [log] - Successfully initiated update to 'System Store'."; else log_error "   Failed to update agent-tls-mode. Full response is $response"; exit 1; fi

        # Verify the updated value of agent-tls-mode
        updated_value=$(curl -s -X GET "https://${rancher_url}/v3/settings/agent-tls-mode" \
            -H "Authorization: Bearer $bearer_token" \
            -H "Content-Type: application/json" | jq -r '.value')

        # Check if the agent-tls-mode was successfully updated to 'System Store'; log success or error and exit if failed
        [[ "$updated_value" == "System Store" ]] && log "   [log] - Successfully updated agent-tls-mode to 'System Store'." || { log_error "   The agent-tls-mode is not updated to 'System Store'. Current value is: $updated_value"; exit 1; }
    fi

    # Print end of step activity
    echo "*****************************************"
    echo "Rancher Manager agent-tls-mode setting updated."
    echo "-----------------------------------------------"
    echo ""
}

#=================================================================================================

#-------------------------------------------------------
### 18- Create a User in Rancher & Set Global Permission 
#-------------------------------------------------------

step_18() {
    # Print Step Activity
    echo "----------------------------------------------------------"
    echo "18- Creating a User in Rancher & Set Global Permission ..."
    echo "----------------------------------------------------------"
    echo ""

    # Perform & Log Actions for Updating the Rancher agent-tls-mode to System Store
    log "Creating users in Rancher ..."
    log "   [log] - Creating user tshaker user ..."
    # Step 1: Create the user
    create_user_response=$(curl -s -X POST "https://${rancher_url}/v3/users" \
        -H "Authorization: Bearer $bearer_token" \
        -H "Content-Type: application/json" \
        -d '{
            "type": "user",
            "username": "tshaker",
            "password": "'"$default_password"'",
            "name": "T Shaker",
            "enabled": true
            }')

    # Check if user creation was successful
    user_id=$(echo "$create_user_response" | jq -r '.id')
    [ -z "$user_id" ] || [ "$user_id" == "null" ] && log_error "   Failed to create user. Response: $create_user_response" && exit 1 || log "   [log] - User created successfully with ID: $user_id"

    # Step 2: Assign Standard User global role
    log "   [log] - Assigning globa permission to user tshaker user ..."
    assign_role_response=$(curl -s -X POST "https://${rancher_url}/v3/globalrolebindings" \
        -H "Authorization: Bearer $bearer_token" \
        -H "Content-Type: application/json" \
        -d '{
            "type": "globalRoleBinding",
            "userId": "'"$user_id"'",
            "globalRoleId": "user"
            }')
    
    # Check if role assignment was successful
    role_id=$(echo "$assign_role_response" | jq -r '.id')
    [ -z "$role_id" ] || [ "$role_id" == "null" ] && log_error "   Failed to assign Standard User role to user 'shaker'. Response: $assign_role_response" && exit 1 || log "   [log] - Standard User role assigned to 'shaker' successfully."

    # Print end of step activity
    echo "*****************************************"
    echo "Rancher Manager agent-tls-mode setting updated."
    echo "-----------------------------------------------"
    echo ""
}

#=================================================================================================

#---------------------------------
### 19- Create Downstream Clusters 
#---------------------------------

step_19() {
    # Print Step Activity
    echo "--------------------------------------------------"
    echo "19- Creating and Importing Downstream Clusters ..."
    echo "--------------------------------------------------"
    echo ""

    # Perform & Log Actions for Updating the Rancher agent-tls-mode to System Store
    log "Creating and Importing Downstream Clusters ..."

    # Perform & Log Actions for checking if Rancher Manager is up and running
    log "First - Checking if Rancher Manager is Up & Running ..."
    check_rancher_manager "$rancher_url"

    # Perform & Log Actions for checking if bearer_token is already available and if not create one
    log "Second - Checking if bearer_token API token is already available ..."
    authenticate_and_get_token

    # Perform & Log Actions for Creating & importing downstream clusters
    log "Third - Creating & importing downstream clusters ..."

    # Log how many downstream clusters will be created
    log "   [log] - The total downstream clusters to be created are: $dsc_count ..."
    log "   [log] - Creating downstream clusters ..."

    # Create an array to store the import commands along with the cluster name
    cluster_import_commands=()

    # Loop to create and import downstream clusters
    for i in $(seq 1 "$dsc_count"); do
        # Generate the cluster name using the default prefix and a formatted number (01, 02, 03, etc.)
        local cluster_name="ts-suse-demo-dsc-$(printf "%02d" $i)"  # Ensures numbers are zero-padded
        log "   [log] - Creating $cluster_name ..."
        log "   [log] - Checking if cluster $cluster_name already exists..."

        # Step 1: Check if a cluster with the same name already exists
        # Retrieve the full list of clusters and check if the retrieval succeeded
        log "   [log] - Retrieving full list of available clusters ..."
        cluster_list=$(curl -s -X GET "https://${rancher_url}/v3/clusters" \
            -H "Authorization: Bearer $bearer_token" \
            -H "Content-Type: application/json")

        # Retrieve the full list of clusters and check if the retrieval succeeded (one-liner with else)
        echo "$cluster_list" | jq -e '. | has("data") and .data' &>/dev/null && log "   [log] - Cluster list successfully retrieved." || { log_error "   Failed to retrieve the cluster list. Exiting."; exit 1; }

        # Check if the cluster already exists by its name
        log "   [log] - Checking if $cluster_name is listed in the list of available clusters ..."
        existing_cluster_id=$(echo "$cluster_list" | jq -r ".data[] | select(.name == \"$cluster_name\") | .id")
        [ -n "$existing_cluster_id" ] && log "   [log] - Cluster $cluster_name already exists with ID: $existing_cluster_id. Skipping creation." && continue || log "   [log] - Cluster $cluster_name does not exist. Creating new one ..."
        
        # Step 2: Create the cluster in Rancher using the Rancher API
        log "   [log] - Creating cluster $cluster_name ..."
        response=$(curl -s -X POST "https://${rancher_url}/v3/clusters" \
            -H "Authorization: Bearer $bearer_token" \
            -H "Content-Type: application/json" \
            -d '{"type":"cluster","name":"'"$cluster_name"'"}')

        # Check if the cluster creation was successfull, Check if the response contains an 'id' - If no 'id' is found, echo error and print the full response
        cluster_id=$(echo "$response" | jq -r '.id')
        [ -z "$cluster_id" ] || [ "$cluster_id" == "null" ] && log_error "   Failed to create cluster $cluster_name. No 'id' returned. Full response: $response" && exit 1 || log "   [log] - Cluster $cluster_name created successfully with ID: $cluster_id."

        # Step 3: Fetch registration tokens for the newly created cluster
        # Due to the response of the below API call is miss-formated and causing issues in JQ parsing, some cleanup using sed & awk is required
        # Retrieve the full response, then use sed and awk to cleanup
        # Fetch registration tokens for the specific cluster by appending cluster ID to the URL
        # Also, if the below API call is executed directly, only local cluster will be retrivied, thus sleep for 12 seconds
        sleep 15
        response=$(curl -s -X GET "https://${rancher_url}/v3/clusterregistrationtoken" \
            -H "Authorization: Bearer $bearer_token" \
            -H "Content-Type: application/json")
        # Clean up
        # Replace all instances of null (without quotes) with an empty string (with quotes)
        cleaned_response=$(echo "$response" | sed 's/:null/:""/g')
        # Add a space after each colon followed by a value or opening brace
        cleaned_response=$(echo "$cleaned_response" | sed 's/":"/": "/g' | sed 's/":{"/": {"/g')
        # Use awk to remove everything from "PowerShell -NoLogo -NonInteractive -Command" up to "| iex}\"" but leave a quote at the end
        cleaned_response=$(echo "$cleaned_response" | awk '{gsub(/PowerShell -NoLogo -NonInteractive -Command[^|]*\| iex}\\"/, ""); print}')
        # add the token in a variable
        registration_token=$(echo "$cleaned_response" | jq -r ".data[] | select(.clusterId == \"$cluster_id\") | .token")
        # Check if we successfully retrieved the token
        [ -z "$registration_token" ] || [ "$registration_token" == "null" ] && log_error "   Failed to retrieve the registration token for cluster $cluster_name. Exiting." && exit 1 || log "   [log] - Successfully retrieved registration token for $cluster_name - Token: $registration_token."

        # Step 4: Create the import commands
        import_command="kubectl apply -f https://rancher.rancher-demo.com/v3/import/$(echo "$registration_token" | sed 's/\//\\\//g')_$(echo "$cluster_id").yaml"
        insecure_import_command="curl --insecure -sfL https://rancher.rancher-demo.com/v3/import/$(echo "$registration_token" | sed 's/\//\\\//g')_$(echo "$cluster_id").yaml | kubectl apply -f -"

        # Add the cluster name and commands to the array
        cluster_import_commands+=(
            "Cluster Discription: Downstream Cluster Number $i"
            "Cluster Name: $cluster_name"
            "Import secure command: $import_command"
            "Import un-secure command: $insecure_import_command"
            "-----------------------------------------------------"
        )
    done

    # Print end of step activity
    echo "*****************************************"
    echo "Downstream clusters created and import commands generated."
    echo "----------------------------------------------------------"
    echo ""
}

#=================================================================================================

#-------------------------------------------------
### Starting script from the provided step numner 
#-------------------------------------------------

#-------------------------------------
### Print starting point (step number) 
#-------------------------------------

echo "Starting from step number $starting_step"
echo "----------------------------"
echo ""

# Execute steps conditionally based on the start_step
if (( starting_step <= 1 )); then step_1; fi
if (( starting_step <= 2 )); then step_2; fi
if (( starting_step <= 3 )); then step_3; fi
if (( starting_step <= 4 )); then step_4; fi
if (( starting_step <= 5 )); then step_5; fi
if (( starting_step <= 6 )); then step_6; fi
if (( starting_step <= 7 )); then step_7; fi
if (( starting_step <= 8 )); then step_8; fi
if (( starting_step <= 9 )); then step_9; fi
if (( starting_step <= 10 )); then step_10; fi
if (( starting_step <= 11 )); then step_11; fi
if (( starting_step <= 12 )); then step_12; fi
if (( starting_step <= 13 )); then step_13; fi
if (( starting_step <= 14 )); then step_14; fi
if (( starting_step <= 15 )); then step_15; fi
if (( starting_step <= 16 )); then step_16; fi
if (( starting_step <= 17 )); then step_17; fi
if (( starting_step <= 18 )); then step_18; fi
if (( starting_step <= 19 )); then step_19; fi

# Print Rancher Cluster Import Commands
echo ""
echo "Cluster Import Commands"
echo "-----------------------"
# Loop through each element in the array and echo it
for element in "${cluster_import_commands[@]}"; do
    echo "$element"
done
echo ""

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
