#!/usr/bin/env bash

#=============================
# SUSE Rancher Downstream Cluster Import Script
#=============================
# This script automates the creation and import of downstream clusters into Rancher Manager using Rancher API.
# The output of this script will be the kubectl commands to import downstream clusters like:
#   kubectl apply -f https://rancher.rancher-demo.com/v3/import/<random-identifier>.yaml
#   curl --insecure -sfL https://rancher.rancher-demo.com/v3/import/<random-identifier>.yaml | kubectl apply -f -
#=============================

# Function to display script usage
usage() {
    echo ""
    echo "Usage: $0 --dsc_count [number of downstream clusters] --rancher_url [Rancher Manager URL] --api_token [API token]"
    echo ""
    echo "--dsc_count: The number of downstream clusters to create (an integer between 1 and 5)."
    echo "--rancher_url: The URL of the Rancher Manager instance."
    echo "--api_token: The API token for authenticating with Rancher."
    exit 1
}

# Validate that the dsc_count is an integer between 1 and 5
validate_dsc_count() {
    if ! [[ "$dsc_count" =~ ^[1-5]$ ]]; then
        echo "Error: --dsc_count must be an integer between 1 and 5."
        exit 1
    fi
}

# Update the Rancher agent-tls-mode setting to 'System Store' for version 2.9
update_agent_tls_mode() {
    echo "Updating Rancher agent-tls-mode to 'System Store'..."

    # Rancher Manager URL and API token passed by user
    response=$(curl -s -X PUT "${rancher_url}/v3/settings/agent-tls-mode" \
        -H "Authorization: Bearer $api_token" \
        -H "Content-Type: application/json" \
        -d '{"value": "system"}')

    if echo "$response" | grep -q '"id"'; then
        echo "Successfully updated agent-tls-mode to 'System Store'."
    else
        echo "Error: Failed to update agent-tls-mode."
        echo "Response: $response"
        exit 1
    fi
}

# Parse arguments passed to the script
while [ $# -gt 0 ]; do 
  case $1 in
    -h|--help)
      usage
      exit 0
      ;;
    --dsc_count)
      dsc_count="${2:-}"  # The number of downstream clusters to create
      shift
      ;;
    --rancher_url)
      rancher_url="${2:-}"  # The Rancher Manager URL
      shift
      ;;
    --api_token)
      api_token="${2:-}"  # The API token for authenticating with Rancher
      shift
      ;;
    *)
      echo "Invalid argument: $1"
      usage
      exit 1
      ;;
  esac
  shift
done

# Validate that all required arguments are provided
if [ -z "$dsc_count" ] || [ -z "$rancher_url" ] || [ -z "$api_token" ]; then
    echo "Error: Missing required arguments."
    usage
fi

# Validate the dsc_count argument (ensure it's between 1 and 5)
validate_dsc_count

#==============================
# Script Start
echo "====================================================="
echo "-------------- Start of Downstream Cluster Script ---------------"
echo " Configuring and Importing Downstream Clusters to Rancher       "
echo "====================================================="

# Step 1: Update agent-tls-mode to 'System Store'
update_agent_tls_mode

# Function to create and import downstream clusters
create_import_cluster() {
    # Generate the cluster name using the default prefix and a formatted number (01, 02, 03, etc.)
    local cluster_name="ts-suse-demo-dsc-$(printf "%02d" $1)"  # Ensures numbers are zero-padded
    echo "Creating and importing cluster: $cluster_name"

    # Step 1: Create the cluster in Rancher using the Rancher API
    cluster_id=$(curl -s -X POST "${rancher_url}/v3/clusters" \
        -H "Authorization: Bearer $api_token" \
        -H "Content-Type: application/json" \
        -d '{"type":"cluster","name":"'"$cluster_name"'"}' | jq -r '.id')

    # Check if the cluster creation was successful, if not, print an error message
    if [ -z "$cluster_id" ]; then
        echo "Failed to create cluster $cluster_name"
        return 1
    fi
    echo "Cluster $cluster_name created with ID: $cluster_id"

    # Step 2: Generate the cluster import commands using Rancher API
    import_commands=$(curl -s -X POST "${rancher_url}/v3/clusters/${cluster_id}?action=generateKubeconfig" \
        -H "Authorization: Bearer $api_token" \
        -H "Content-Type: application/json")

    # Extract the import command URL from the response
    import_url=$(echo "$import_commands" | jq -r '.command')

    # Generate the kubectl command with the import URL
    kubectl_command="kubectl apply -f ${import_url}"

    # Create the command variant without certificate verification (useful for clusters with self-signed certificates)
    kubectl_no_cert_check="curl --insecure -sfL ${import_url} | kubectl apply -f -"

    # Extract the limited privilege command (for users with restricted access)
    limited_privilege_command=$(echo "$import_commands" | jq -r '.limitedPrivilegeCommand')

    # Output the import commands for the user
    echo "Import commands for $cluster_name:"
    echo "1. Default command:"
    echo "$kubectl_command"
    echo ""
    echo "2. Without certificate check (useful for self-signed certs):"
    echo "$kubectl_no_cert_check"
    echo ""
    echo "3. Limited privilege command:"
    echo "$limited_privilege_command"
    echo "-----------------------------------------------------"
}

# Loop through the number of downstream clusters specified by the user
for i in $(seq 1 "$dsc_count"); do
    # For each cluster, call the create_import_cluster function with the current cluster index (i)
    create_import_cluster "$i"
done

#==============================
# End of the script
echo "====================================================="
echo "-------------- End of Downstream Cluster Script ---------------"
echo " All specified clusters created and import commands generated."
echo "====================================================="