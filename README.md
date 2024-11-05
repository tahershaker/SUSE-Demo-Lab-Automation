# SUSE-Demo-Lab-Automation

This Repo is used for personal use to help automate the deployment and configuration of a SUSE demo lab environment to be used in Demos, workshops, and presentations

---

## Usage

- To automate the deployment of the resources required in the Management cluster on the master nodes, use the below command to execute the script.
```bash
curl https://raw.githubusercontent.com/tahershaker/SUSE-Demo-Lab-Automation/refs/heads/main/config-files/mgmt-master-01.sh | bash -s -- \
   --cert_version "--add-venison-here--" \
   --email "--add-email-here--" \
   --default_pass "--add-pass-here--" \
   --domain "--add-domain-here--" \
   --rancher_version "--add-venison-here--" \
   --rancher_url "--add-url-here--" \
   --s3_access_key "--add-access-key-here--" \
   --s3_secret_key "--add-secret-key-here--" \
   --s3_region "--add-region-here--" \
   --s3_bucket_name "--add-name-here--" \
   --s3_endpoint "--add-url-here--" \
   --harbor_url "--add-url-here--"
```
Argument lists & explanation
  - --cert_version: The Cert-Manager version to be used while deployment it using Helm
  - --email: The email address to be used while creating a Let's Encrypt Certificate or Issuer
  - --default_pass: The password to be used while deploying SUSE solutions
  - --domain: The lab domain name to be used while deploying SUSE solutions
  - --rancher_version: The Rancher Manager version to be used while deployment it using Helm
  - --rancher_url: The Rancher Manager url to be used while configuring Rancher Manager Ingress for HTTP(S) access
  - --s3_access_key: The Access Key to be used to access S3 Bucket to be used while configuring the Rancher Backup
  - --s3_secret_key: The Access Key Secret to be used to access S3 Bucket to be used while configuring the Rancher Backup
  - --s3_region: The AWS region where the S3 Bucket is created and configure for access to be used while configuring the Rancher Backup
  - --s3_bucket_name: The AWS S3 Bucket name to be used while configuring the Rancher Backup
  - --s3_endpoint: The S3 endpoint url be used while configuring the Rancher Backup
  - --harbor_url: The Harbor url to be used while configuring Rancher Manager Ingress for HTTP(S) access

---

- To automate the deployment of the resources required in the First Downstream cluster on the master nodes, use the below command to execute the script.
```bash
curl https://raw.githubusercontent.com/tahershaker/SUSE-Demo-Lab-Automation/refs/heads/main/config-files/dsc-01-master-01.sh | bash -s -- \
   --cert_version "--add-venison-here--" \
   --email "--add-email-here--"
```

Argument lists & explanation
  - --cert_version: The Cert-Manager version to be used while deployment it using Helm
  - --email: The email address to be used while creating a Let's Encrypt Certificate or Issuer
  - --online_botique_url: The Online Boutique App url to be used while configuring Rancher Manager Ingress for HTTP(S) access
  - --nv_demo_url: The NeuVector WAF Demo App url to be used while configuring Rancher Manager Ingress for HTTP(S) access

---

- To automate the deployment of the resources required in the Second Downstream cluster on the master nodes, use the below command to execute the script.
```bash
curl https://raw.githubusercontent.com/tahershaker/SUSE-Demo-Lab-Automation/refs/heads/main/config-files/dsc-02-master-01.sh | bash -s -- \
   --cert_version "--add-venison-here--" \
   --email "--add-email-here--"
```

Argument lists & explanation
  - --cert_version: The Cert-Manager version to be used while deployment it using Helm
  - --email: The email address to be used while creating a Let's Encrypt Certificate or Issuer

---