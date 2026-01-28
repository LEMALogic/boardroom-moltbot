#!/bin/bash
# =============================================================================
# Boardroom - Hetzner Deployment Script
# =============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Boardroom - Hetzner Deployment${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Check for .env file (boardroom repo) - only load HETZNER key
ENV_FILE="/Users/brian/Sites/github/boardroom/.env"
if [ -f "$ENV_FILE" ]; then
  echo -e "${GREEN}Loading Hetzner token from boardroom repo...${NC}"
  HETZNER_API_KEY=$(grep "^HETZNER_API_KEY=" "$ENV_FILE" | cut -d'=' -f2)
  export HETZNER_API_KEY
fi

# Map HETZNER_API_KEY to HCLOUD_TOKEN (Terraform expects HCLOUD_TOKEN)
if [ -z "$HCLOUD_TOKEN" ]; then
  if [ -n "$HETZNER_API_KEY" ]; then
    export HCLOUD_TOKEN="$HETZNER_API_KEY"
  elif [ -n "$HETZER_API_KEY" ]; then
    export HCLOUD_TOKEN="$HETZER_API_KEY"
  fi
fi

# Check for Hetzner token
if [ -z "$HCLOUD_TOKEN" ]; then
  echo -e "${RED}Error: No Hetzner token found${NC}"
  echo "Add HETZNER_API_KEY to /Users/brian/Sites/github/boardroom/.env"
  exit 1
fi

echo -e "${GREEN}Hetzner token found${NC}"

# Export for Terraform
export TF_VAR_hcloud_token="$HCLOUD_TOKEN"

# Check for terraform.tfvars
if [ ! -f "terraform.tfvars" ]; then
  echo -e "${YELLOW}No terraform.tfvars found. Creating from example...${NC}"
  cp terraform.tfvars.example terraform.tfvars

  # Auto-fill the token
  if [ -n "$HCLOUD_TOKEN" ]; then
    if [[ "$OSTYPE" == "darwin"* ]]; then
      sed -i '' "s/hcloud_token = \"\"/hcloud_token = \"$HCLOUD_TOKEN\"/" terraform.tfvars
    else
      sed -i "s/hcloud_token = \"\"/hcloud_token = \"$HCLOUD_TOKEN\"/" terraform.tfvars
    fi
  fi

  echo -e "${GREEN}Created terraform.tfvars - please review settings${NC}"
  echo ""
fi

# Check terraform is installed
if ! command -v terraform &> /dev/null; then
  echo -e "${RED}Terraform not installed${NC}"
  echo "Install with: brew install terraform"
  exit 1
fi

# Initialize if needed
if [ ! -d ".terraform" ]; then
  echo -e "${YELLOW}Initializing Terraform...${NC}"
  terraform init
fi

# Action
ACTION="${1:-plan}"

case "$ACTION" in
  plan)
    echo -e "${GREEN}Running terraform plan...${NC}"
    terraform plan
    ;;
  apply)
    echo -e "${GREEN}Running terraform apply...${NC}"
    terraform apply
    ;;
  destroy)
    echo -e "${RED}Running terraform destroy...${NC}"
    terraform destroy
    ;;
  output)
    terraform output
    ;;
  ssh)
    IP=$(terraform output -raw server_ip 2>/dev/null)
    if [ -n "$IP" ]; then
      echo -e "${GREEN}Connecting to $IP...${NC}"
      ssh -i ~/.ssh/hetzer-boardroom boardroom@$IP
    else
      echo -e "${RED}No server IP found. Run 'deploy.sh apply' first.${NC}"
    fi
    ;;
  *)
    echo "Usage: $0 [plan|apply|destroy|output|ssh]"
    exit 1
    ;;
esac

echo ""
echo -e "${GREEN}Done!${NC}"
