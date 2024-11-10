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
    local rancher_fqdn="$1"
    local interval=10       # Interval in seconds between each check
    local rancher_url="https://$rancher_fqdn"  # Construct the full URL with HTTPS

    log "Checking if Rancher Manager at $rancher_url is up and running..."

    while true; do
        # Use curl to check if Rancher Manager is responding
        response=$(curl -s -o /dev/null -w "%{http_code}" "$rancher_url")

        # Check if HTTP response code is 200 (OK)
        if [ "$response" -eq 200 ]; then
            log "   Rancher Manager is up and running!"
            break
        else
            log "   Rancher Manager is not available yet. Retrying in $interval seconds ..."
            sleep "$interval"
        fi
    done
}

# Function to create and import downstream clusters
create_import_cluster() {
    # Generate the cluster name using the default prefix and a formatted number (01, 02, 03, etc.)
    local cluster_name="ts-suse-demo-dsc-$(printf "%02d" $1)"  # Ensures numbers are zero-padded
    local api_token=$2
    echo "Checking if cluster $cluster_name already exists..."

    # Step 1: Check if a cluster with the same name already exists
    existing_cluster_id=$(curl -s -X GET "https://${rancher_url}/v3/clusters" \
        -H "Authorization: Bearer $api_token" \
        -H "Content-Type: application/json" | jq -r ".data[] | select(.name == \"$cluster_name\") | .id")

    if [ -n "$existing_cluster_id" ]; then
        echo "Cluster $cluster_name already exists with ID: $existing_cluster_id. Skipping creation."
        return 0  # Skip the creation if the cluster already exists
    fi

    # Step 2: Create the cluster in Rancher using the Rancher API
    cluster_id=$(curl -s -X POST "https://${rancher_url}/v3/clusters" \
        -H "Authorization: Bearer $api_token" \
        -H "Content-Type: application/json" \
        -d '{"type":"cluster","name":"'"$cluster_name"'"}' | jq -r '.id')

    # Check if the cluster creation was successful, if not, print an error message
    if [ -z "$cluster_id" ]; then
        echo "Failed to create cluster $cluster_name. No cluster ID returned."
        return 1
    fi
    echo "Cluster $cluster_name created with ID: $cluster_id"

    # Step 3: Fetch registration tokens for the newly created cluster
    registration_token=$(curl -s -X GET "https://${rancher_url}/v3/clusterregistrationtoken" \
        -H "Authorization: Bearer $api_token" \
        -H "Content-Type: application/json" | jq -r ".data[] | select(.clusterId == \"$cluster_id\") | .token")

    # Check if we successfully retrieved the token
    if [ -z "$registration_token" ]; then
        echo "Failed to retrieve the registration token for cluster $cluster_name. Exiting."
        return 1
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
if [[ -z "$cert_version" || -z "$email" || -z "$default_pass" || -z "$domain" || -z "$rancher_version" || -z "$rancher_url" || -z "$s3_access_key" || -z "$s3_secret_key" || -z "$s3_region" || -z "$s3_bucket_name" || -z "$s3_endpoint" || -z "$harbor_url" || -z "$aws_default_region" || -z "$aws_access_key" || -z "$aws_secret_key" || -z "$dsc_count" ]]; then
    echo "Missing required arguments."
    usage
    exit 1
fi

#=======================================================================================================================================
#=======================================================================================================================================

#--------------------#
#--- Start Script----#
#--------------------#

echo "========================================================"
echo "------------------ Start of Script ---------------------"
echo " Automating Rancher Management and components deployment"
echo "========================================================"

#=================================================================================================

#-----------------------------
### 1- Deploy & Configure Helm 
#-----------------------------

echo ""
echo "------------------------------------"
echo "1- Installing & Configuring Helm ..."
echo "------------------------------------"
echo ""

log "   Installing Helm ..."
run_command "curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
log "      Helm tool installed."
log "   Adding Helm Repos jetstack ..."
run_command "helm repo add jetstack https://charts.jetstack.io"
log "      Helm repo jetstack added."
log "   Adding Helm Repos rancher-prime ..."
run_command "helm repo add rancher-prime https://charts.rancher.com/server-charts/prime"
log "      Helm repo rancher-prime added."
log "   Adding Helm Repos rancher-charts..."
run_command "helm repo add rancher-charts https://charts.rancher.io"
log "      Helm repo rancher-charts added."
log "   Adding Helm Repos bitnami ..."
run_command "helm repo add bitnami https://charts.bitnami.com/bitnami"
log "      Helm repo bitnami added."
log "   Adding Helm Repos rodeo ..."
run_command "helm repo add rodeo https://rancher.github.io/rodeo"
log "      Helm repo rodeo added."
log "   Adding Helm Repos harbor ..."
run_command "helm repo add harbor https://helm.goharbor.io"
log "      Helm repo harbor added."
log "   Updating Helm Repos ..."
run_command "helm repo update"
log "      Helm repos updated."

echo ""
echo "         Helm tool is install & all repos are added and updated."
echo "----------------------------------------------------------------"
echo ""

#=================================================================================================

#----------------------------------------------------
### 2- Install Rancher local-path storage provisioner 
#----------------------------------------------------

echo ""
echo "--------------------------------------------------------"
echo "2- Installing Rancher local-path storage provisioner ..."
echo "--------------------------------------------------------"
echo ""

log "   Installing Rancher local-path storage provisioner ..."
run_command "apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.26/deploy/local-path-storage.yaml"
log "      Rancher local-path storage provisioner Installed."

echo ""
echo "         Rancher local-path storage provisioner is installed & configured."
echo "--------------------------------------------------------------------------"
echo ""

#=================================================================================================

#-------------------------------------
### 3- Deploy & Configure Cert_Manager 
#-------------------------------------

echo ""
echo "-------------------------------------------"
echo "3- Deploying & Configuring Cert_Manager ..."
echo "-------------------------------------------"
echo ""

log "   Deploying Cert-Manager with version $cert_version ..."
run_command "helm install --wait cert-manager jetstack/cert-manager --namespace cert-manager --version $cert_version --set installCRDs=true --create-namespace"
log "      Cert_Manager Deployed."

echo ""
echo "         Cert_Manager is deployed & configured."
echo "-----------------------------------------------"
echo ""

#=================================================================================================

#-----------------------------------------------
### 4- Create & Configure A Let's Encrypt Issure 
#-----------------------------------------------

echo ""
echo "-----------------------------------------------------"
echo "4- Createing & Configuring A Let's Encrypt Issure ..."
echo "-----------------------------------------------------"
echo ""

log "   Createing Let's Encrypt Issure..."
kubectl apply -f - <<EOF >/dev/null 2>&1
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
if [ $? -ne 0 ]; then
    log_error "Failed to create Lets Encrypt Issuer"
    exit 1
else
    log "      Let's Encrypt Issure created."  
fi

echo ""
echo "         Let's Encrypt Issure is created & configured."
echo "------------------------------------------------------"
echo ""

#=================================================================================================

#----------------------------------------
### 5- Deploy & Configure Rancher Manager 
#----------------------------------------

echo ""
echo "----------------------------------------------"
echo "5- Deploying & Configuring Rancher Manager ..."
echo "----------------------------------------------"
echo ""

log "   Deploying Rancher Manager with version $rancher_version ..."
run_command "helm install --wait rancher rancher-prime/rancher --namespace cattle-system --create-namespace --version $rancher_version --set replicas=1 --set hostname=$rancher_url --set ingress.tls.source=letsEncrypt --set letsEncrypt.email=$email --set bootstrapPassword=$default_pass"
log "      Rancher Manager Deployed."

echo ""
echo "         Rancher Manager is deployed & configured."
echo "--------------------------------------------------"
echo ""

#=================================================================================================

#----------------------------------------
### 6- Deploy & Configure Rancher Backup 
#----------------------------------------

echo ""
echo "----------------------------------------------"
echo "6- Deploying & Configuring Rancher Backup ..."
echo "----------------------------------------------"
echo ""

log "   Creating kubernetes secret for S3 access ..."
kubectl apply -f - <<EOF >/dev/null 2>&1
apiVersion: v1
kind: Secret
metadata:
  name: s3-creds
type: Opaque
data:
  accessKey: "$(echo -n $s3_access_key | base64)"
  secretKey: "$(echo -n $s3_secret_key | base64)"
EOF
if [ $? -ne 0 ]; then
    log_error "Failed to create S3 credentials secret"
    exit 1
else 
    log "      Kubernetes secret created."
fi
#       --------------------------------------------------------------
log "   Creating Rancher Backup Helm Value File ..."
local file_path="yamlfiles/backup-operator-values.yaml"
mkdir -p "$(dirname "$file_path")" >/dev/null 2>&1
cat <<EOF > "$file_path" 2>/dev/null
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
if [ $? -eq 0 ] && [ -f "$file_path" ]; then
    log "      Rancher Backup Helm Value File created - $file_path ."
else
    log_error "Failed to create Rancher Backup Helm Value File - file name: $file_path"
    exit 1
fi
#       --------------------------------------------------------------
log "   Deploying Rancher Backup CRDs ..."
run_command "helm install --wait rancher-backup-crd rancher-charts/rancher-backup-crd --namespace cattle-resources-system --create-namespace"
log "      Rancher Backup CRDs Deployed."
#       --------------------------------------------------------------
log "   Deploying Rancher Backup ..."
run_command "helm install --wait rancher-backup rancher-charts/rancher-backup --namespace cattle-resources-system --values $file_path"
log "      Rancher Backup Deployed."
#       --------------------------------------------------------------
log "   Creating Rancher Backup encryption-provider-config Yaml file ..."
local file_path="yamlfiles/encryption-provider-config.yaml"
mkdir -p "$(dirname "$file_path")" >/dev/null 2>&1
cat <<EOF > "$file_path" 2>/dev/null
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
if [ $? -eq 0 ] && [ -f "$file_path" ]; then
    log "      Rancher Backup encryption-provider-config Yaml File created - $file_path ."
else
    log_error "Failed to create encryption-provider-config Yaml - file name: $file_path"
    exit 1
fi
#       --------------------------------------------------------------
log "   Creating Rancher Backup encryptionconfig secret ..."
run_command "kubectl create secret generic encryptionconfig --from-file=$file_path -n cattle-resources-system"
log "      Rancher Backup encryptionconfig secret created."

echo ""
echo "         Rancher Backup is deployed & configured."
echo "--------------------------------------------------"
echo ""

#=================================================================================================

#----------------------------------------------
### 7- Deploy & Configure Rancher CSI Benchmark 
#----------------------------------------------

echo ""
echo "----------------------------------------------------"
echo "7- Deploying & Configuring Rancher CSI Benchmark ..."
echo "----------------------------------------------------"
echo ""

log "   Deploying Rancher CSI Benchmark CRDs ..."
run_command "helm install --wait rancher-cis-benchmark-crd rancher-charts/rancher-cis-benchmark-crd --namespace cis-operator-system --create-namespace"
log "      Rancher CSI Benchmark CRDs Deployed."

log "   Deploying Rancher CSI Benchmark ..."
run_command "helm install --wait rancher-cis-benchmark rancher-charts/rancher-cis-benchmark --namespace cis-operator-system"
log "      Rancher CSI Benchmark Deployed."

echo ""
echo "         Rancher CSI Benchmark is deployed & configured."
echo "--------------------------------------------------------"
echo ""

#=================================================================================================

#----------------------------------------------
### 8- Deploy & Configure Harbor Image Registry 
#----------------------------------------------

echo ""
echo "----------------------------------------------------"
echo "8- Deploying & Configuring Harbor Image Registry ..."
echo "----------------------------------------------------"
echo ""

log "   Deploying Harbor Image Registry ..."
run_command "helm install --wait harbor harbor/harbor --namespace harbor --create-namespace --set expose.ingress.hosts.core=$harbor_url --set expose.ingress.hosts.notary=notary.$domain --set expose.ingress.annotations.'cert-manager\.io/cluster-issuer'=letsencrypt-prod --set expose.tls.certSource=secret --set expose.tls.secret.secretName=tls-harbor --set externalURL=https://$harbor_url --set persistence.persistentVolumeClaim.registry.storageClass=local-path --set persistence.persistentVolumeClaim.jobservice.jobLog.storageClass=local-path --set persistence.persistentVolumeClaim.database.storageClass=local-path --set persistence.persistentVolumeClaim.redis.storageClass=local-path --set persistence.persistentVolumeClaim.trivy.storageClass=local-path --set harborAdminPassword=$default_pass"
log "      Harbor Image Registry Deployed."

echo ""
echo "         Harbor Image Registry is deployed & configured."
echo "--------------------------------------------------------"
echo ""

#=================================================================================================

#-----------------------------------------------------
### 9- Create AWS Cloud Credentails In Rancher manager 
#-----------------------------------------------------

echo ""
echo "---------------------------------------------------------"
echo "9- Createing AWS Cloud Credentails In Rancher manager ..."
echo "---------------------------------------------------------"
echo ""

log "   Creating Kubernetes Secret For AWS Cloud Creds ..."
run_command "kubectl create secret -n cattle-global-data generic aws-creds --from-literal=amazonec2credentialConfig-defaultRegion=$aws_default_region --from-literal=amazonec2credentialConfig-accessKey=$aws_access_key --from-literal=amazonec2credentialConfig-secretKey=$aws_secret_key"
log "      Kubernetes Secret created."

log "   Annotating Kubernetes Secret For AWS Cloud Creds ..."
run_command "kubectl annotate secret -n cattle-global-data aws-creds provisioning.cattle.io/driver=aws"
log "      Kubernetes Secret annotated."

echo ""
echo "         Rancher Manager AWS Cloud Credentials configured."
echo "----------------------------------------------------------"
echo ""

#=================================================================================================

#----------------------------------------------
### 10- Check if Rancher Manager is Up & Running 
#----------------------------------------------

echo ""
echo "--------------------------------------------------"
echo "10- Checking if Rancher Manager is Up & Running ..."
echo "--------------------------------------------------"
echo ""

log "   Checking if Rancher Manager is Up & Running ..."
check_rancher_manager "$rancher_url"

echo ""
echo "         Rancher Manager is now Up & Running."
echo "---------------------------------------------"
echo ""

#=================================================================================================

#-------------------------------------------------
### 11- Create A Rancher manager API Bearrer Token 
#-------------------------------------------------

echo ""
echo "----------------------------------------------------"
echo "11- Creating A Rancher manager API Bearrer Token ..."
echo "----------------------------------------------------"
echo ""

# Step 1: Authenticate with Rancher API using the user credentials (username/password)
log "   Authenticating with Rancher Manager and Retrieving API Token ..."
response=$(curl -s -X POST "https://$rancher_url/v3-public/localProviders/local?action=login" \
  -H "Content-Type: application/json" \
  -d '{
        "username": "admin",  # Hardcoded username
        "password": "'"$default_pass"'"
      }')

# Check if the response contains an error
error_message=$(echo "$response" | jq -r '.message // empty')
if [ -n "$error_message" ]; then
    log_error "Error during authentication: $error_message"
    exit 1
else
    log "      Successfully authenticated to Rancher Manager - Retrieving API Token ...."
fi

# Step 2: Extract the Bearer token from the login response
bearer_token=$(echo "$response" | jq -r '.token')

# Check if we successfully retrieved the token
if [ -z "$bearer_token" ]; then
    log_error "Failed to retrieve the Bearer token - Bearer token variable is empty. Full response is $response"
    exit 1
else
    log "      Successfully retrieved the Bearer token - Bearer token is $bearer_token"
fi

echo ""
echo "         Rancher Manager APi Token generated & retrieved."
echo "---------------------------------------------------------"
echo ""

#=================================================================================================

#--------------------------------------------------------
### 12- Update the Rancher agent-tls-mode to System Store 
#--------------------------------------------------------

echo ""
echo "-----------------------------------------------------------"
echo "12- Updating the Rancher agent-tls-mode to System Store ..."
echo "-----------------------------------------------------------"
echo ""

# Check if agent-tls-mode is set to System Store
log "   Retrieving the current agent-tle-mode setting value ..."
# Fetch the current value of agent-tls-mode
current_value=$(curl -s -X GET "https://${rancher_url}/v3/settings/agent-tls-mode" \
    -H "Authorization: Bearer $bearer_token" \
    -H "Content-Type: application/json" | jq -r '.value')

# Check if the current_value indicates success
if echo "$current_value" | grep -q '"id"'; then
    log "      Successfully retrieved the agent-tle-mode setting value."
else
    log_error "Failed to retrieve the agent-tle-mode setting value. Full response is $current_value"
    exit 1
fi

# Check if the current value is already 'System Store'
if [ "$current_value" == "System Store" ]; then
    log "      agent-tls-mode is already set to 'System Store'. Skipping update."
else
    log "      Updating Rancher agent-tls-mode to 'System Store' ..."
    # Update the agetn-tls-mode setting
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

echo ""
echo "         Rancher Manager agent-tls-mode setting updated."
echo "--------------------------------------------------------"
echo ""

#=================================================================================================

#---------------------------------
### 13- Create Downstream Clusters 
#---------------------------------

echo ""
echo "----------------------------------"
echo "13- Create Downstream Clusters ..."
echo "----------------------------------"
echo ""

log "   The total downstream clusters to be created are: $dsc_count ..."
log "   Creating downstream clusters ..."

# Loop through the number of downstream clusters specified by the user
for i in $(seq 1 "$dsc_count"); do
    # For each cluster, call the create_import_cluster function with the current cluster index (i)
    log "   Creating downstream cluster number $i ..."
    create_import_cluster "$i" "$bearer_token"
done

echo ""
echo "         All downstream clusters are now created and import command provided."
echo "-----------------------------------------------------------------------------"
echo ""

#=================================================================================================