# =============================================================================
# Boardroom - Hetzner Cloud Infrastructure
# =============================================================================
# Provisions Docker hosts for running Boardroom user containers
#
# Usage:
#   export HCLOUD_TOKEN="your-token"
#   terraform init
#   terraform plan
#   terraform apply
# =============================================================================

terraform {
  required_version = ">= 1.0"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.45"
    }
  }
}

# -----------------------------------------------------------------------------
# Variables
# -----------------------------------------------------------------------------

variable "hcloud_token" {
  description = "Hetzner Cloud API token"
  type        = string
  sensitive   = true
}

variable "location" {
  description = "Hetzner datacenter location"
  type        = string
  default     = "fsn1"  # Falkenstein, Germany (GDPR)
}

variable "server_type" {
  description = "Hetzner server type"
  type        = string
  default     = "cx32"  # 4 vCPU, 8GB RAM - good for ~25 users
}

variable "ssh_key_name" {
  description = "Name of SSH key in Hetzner"
  type        = string
  default     = "boardroom"
}

variable "ssh_public_key_path" {
  description = "Path to SSH public key file"
  type        = string
  default     = "~/.ssh/hetzer-boardroom.pub"
}

variable "environment" {
  description = "Environment name (prod, staging, dev)"
  type        = string
  default     = "prod"
}

# -----------------------------------------------------------------------------
# Provider
# -----------------------------------------------------------------------------

provider "hcloud" {
  token = var.hcloud_token
}

# -----------------------------------------------------------------------------
# SSH Key
# -----------------------------------------------------------------------------

resource "hcloud_ssh_key" "boardroom" {
  name       = var.ssh_key_name
  public_key = file(pathexpand(var.ssh_public_key_path))
}

# -----------------------------------------------------------------------------
# Network (Private network for internal communication)
# -----------------------------------------------------------------------------

resource "hcloud_network" "boardroom" {
  name     = "boardroom-${var.environment}"
  ip_range = "10.0.0.0/16"
}

resource "hcloud_network_subnet" "boardroom" {
  network_id   = hcloud_network.boardroom.id
  type         = "cloud"
  network_zone = "eu-central"
  ip_range     = "10.0.1.0/24"
}

# -----------------------------------------------------------------------------
# Firewall
# -----------------------------------------------------------------------------

resource "hcloud_firewall" "boardroom" {
  name = "boardroom-${var.environment}"

  # SSH (consider restricting to your IP)
  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "22"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  # HTTP (for Cloudflare Tunnel health checks)
  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "80"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  # HTTPS
  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "443"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  # Allow all outbound
  rule {
    direction = "out"
    protocol  = "tcp"
    port      = "any"
    destination_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction = "out"
    protocol  = "udp"
    port      = "any"
    destination_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction = "out"
    protocol  = "icmp"
    destination_ips = ["0.0.0.0/0", "::/0"]
  }
}

# -----------------------------------------------------------------------------
# Primary Server
# -----------------------------------------------------------------------------

resource "hcloud_server" "boardroom" {
  name        = "boardroom-${var.environment}"
  server_type = var.server_type
  image       = "ubuntu-24.04"
  location    = var.location

  ssh_keys = [hcloud_ssh_key.boardroom.id]

  firewall_ids = [hcloud_firewall.boardroom.id]

  # Cloud-init configuration
  user_data = file("${path.module}/cloud-init.yaml")

  labels = {
    environment = var.environment
    service     = "boardroom"
  }

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }
}

# Attach to private network
resource "hcloud_server_network" "boardroom" {
  server_id  = hcloud_server.boardroom.id
  network_id = hcloud_network.boardroom.id
  ip         = "10.0.1.10"
}

# -----------------------------------------------------------------------------
# Persistent Volume (for user data)
# -----------------------------------------------------------------------------

resource "hcloud_volume" "boardroom_data" {
  name     = "boardroom-${var.environment}-data"
  size     = 50  # GB - adjust based on user count
  location = var.location
  format   = "ext4"

  labels = {
    environment = var.environment
    service     = "boardroom"
  }
}

resource "hcloud_volume_attachment" "boardroom_data" {
  volume_id = hcloud_volume.boardroom_data.id
  server_id = hcloud_server.boardroom.id
  automount = true
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "server_ip" {
  description = "Public IPv4 address of the server"
  value       = hcloud_server.boardroom.ipv4_address
}

output "server_ipv6" {
  description = "Public IPv6 address of the server"
  value       = hcloud_server.boardroom.ipv6_address
}

output "server_id" {
  description = "Hetzner server ID"
  value       = hcloud_server.boardroom.id
}

output "private_ip" {
  description = "Private network IP"
  value       = hcloud_server_network.boardroom.ip
}

output "volume_id" {
  description = "Data volume ID"
  value       = hcloud_volume.boardroom_data.id
}

output "ssh_command" {
  description = "SSH command to connect"
  value       = "ssh -i ~/.ssh/hetzer-boardroom root@${hcloud_server.boardroom.ipv4_address}"
}
