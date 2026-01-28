# =============================================================================
# Terraform Variables - COPY TO terraform.tfvars AND FILL IN
# =============================================================================
# cp terraform.tfvars.example terraform.tfvars
# Then edit terraform.tfvars with your values
# =============================================================================

# Hetzner Cloud API token (from console)
hcloud_token = "hvtuPoo2yMsqE0V74OQTm0sQMKSqUXXS9fu8j9W0YLVKjnLTo3WiVl7ngMmOavwx"

# SSH key settings
ssh_key_name        = "boardroom"
ssh_public_key_path = "~/.ssh/hetzner-boardroom.pub"

# Datacenter location (all GDPR compliant)
# - fsn1 = Falkenstein, Germany
# - nbg1 = Nuremberg, Germany
# - hel1 = Helsinki, Finland
location = "nbg1"

# Server size (see pricing at hetzner.com/cloud)
# - cx22 = 2 vCPU, 4GB RAM  - €3.49/mo  - ~12 users
# - cx32 = 4 vCPU, 8GB RAM  - €6.49/mo  - ~25 users
# - cx42 = 8 vCPU, 16GB RAM - €14.49/mo - ~50 users
# - cx52 = 16 vCPU, 32GB RAM - €28.49/mo - ~100 users
server_type = "cx33"

# Environment name
environment = "prod"
