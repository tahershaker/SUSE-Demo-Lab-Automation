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
    echo "Usage: $0 --dsc_count [number of downstream clusters] --rancher_url [Rancher Manager FQDN] --api_token [API token]"
    echo ""
    echo "--dsc_count: The number of downstream clusters to create (an integer between 1 and 5)."
    echo "--rancher_url: The FQDN of the Rancher Manager instance (e.g., rancher.example.com)."
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
    #Print
    echo "Checking current agent-tls-mode..."

    # Construct the full Rancher Manager URL
    local full_rancher_url="https://${rancher_url}"

    # Fetch the current value of agent-tls-mode
    current_value=$(curl -s -X GET "${full_rancher_url}/v3/settings/agent-tls-mode" \
        -H "Authorization: Bearer $api_token" \
        -H "Content-Type: application/json" | jq -r '.value')

    # Check if the current value is already 'System Store'
    if [ "$current_value" == "System Store" ]; then
        echo "agent-tls-mode is already set to 'System Store'. Skipping update."
        return 0  # Skip the update
    fi

    echo "Updating Rancher agent-tls-mode to 'System Store'..."

    # Rancher Manager URL and API token passed by user
    response=$(curl -s -L -X PUT "${full_rancher_url}/v3/settings/agent-tls-mode" \
        -H "Authorization: Bearer $api_token" \
        -H "Content-Type: application/json" \
        -d '{"value": "System Store"}')

    # Check if the response indicates success
    if echo "$response" | grep -q '"id"'; then
        echo "Successfully initiated update to 'System Store'."
    else
        echo "Error: Failed to update agent-tls-mode."
        echo "Response: $response"
        exit 1
    fi

    # Verify the updated value of agent-tls-mode
    updated_value=$(curl -s -X GET "${full_rancher_url}/v3/settings/agent-tls-mode" \
        -H "Authorization: Bearer $api_token" \
        -H "Content-Type: application/json" | jq -r '.value')

    if [ "$updated_value" == "System Store" ]; then
        echo "Successfully updated agent-tls-mode to 'System Store'."
    else
        echo "Error: The agent-tls-mode is not updated to 'System Store'. Current value is: $updated_value"
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
      rancher_url="${2:-}"  # The FQDN of the Rancher Manager
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