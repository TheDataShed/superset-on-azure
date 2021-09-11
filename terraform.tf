terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "2.76.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.1.0"
    }
  }
}

provider "azurerm" {
  disable_terraform_partner_id = true
  features {
    resource_group {
      prevent_deletion_if_contains_resources = true
    }
  }
}

data "azurerm_client_config" "current" {}

resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  superset_backend_database_admin_username = "superset"
}

resource "random_password" "superset_backend_database_admin_password" {
  length           = 128
  min_lower        = 16
  min_upper        = 16
  min_numeric      = 16
  special          = false
}

resource "azurerm_resource_group" "rg" {
  name     = "superset_demo_${lower(random_id.suffix.id)}"
  location = "UK West"
}

resource "azurerm_container_registry" "acr" {
  name                = "supersetacr${lower(random_id.suffix.id)}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "Basic"
  admin_enabled       = true
}

resource "azurerm_public_ip" "superset_web_ip" {
  name                = "superset_web_ip_${lower(random_id.suffix.id)}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "Standard"
  sku_tier            = "Regional"
  allocation_method   = "Static"
  ip_version          = "IPv4"
  availability_zone   = "No-Zone"
}

resource "azurerm_user_assigned_identity" "aks_cluster_identity" {
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  name                = "aks_cluster_identity_${lower(random_id.suffix.id)}"
}
resource "azurerm_user_assigned_identity" "aks_kubelet_identity" {
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  name                = "aks_kubelet_identity_${lower(random_id.suffix.id)}"
}

resource "azurerm_kubernetes_cluster" "superset_cluster" {
  name                = "superset_cluster_${lower(random_id.suffix.id)}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  dns_prefix          = "superset"
  default_node_pool {
    name                = "default"
    vm_size             = "Standard_DS2_v2"
    enable_auto_scaling = true
    min_count           = 1
    max_count           = 2
  }
  identity {
    type                      = "UserAssigned"
    user_assigned_identity_id = azurerm_user_assigned_identity.aks_cluster_identity.id
  }
  kubelet_identity {
    user_assigned_identity_id = azurerm_user_assigned_identity.aks_kubelet_identity.id
    client_id                 = azurerm_user_assigned_identity.aks_kubelet_identity.client_id
    object_id                 = azurerm_user_assigned_identity.aks_kubelet_identity.principal_id
  }
  depends_on = [
    azurerm_public_ip.superset_web_ip,
    azurerm_role_assignment.aks_cluster_identity_assign_kubelet_identity,
  ]
}

resource "azurerm_redis_cache" "superset_cache" {
  name                          = "superset-cache-${lower(random_id.suffix.id)}"
  location                      = azurerm_resource_group.rg.location
  resource_group_name           = azurerm_resource_group.rg.name
  sku_name                      = "Standard"
  family                        = "C"
  capacity                      = 2
  enable_non_ssl_port           = false
  minimum_tls_version           = "1.2"
  public_network_access_enabled = true
}

resource "azurerm_postgresql_server" "superset_backend_server" {
  name                         = "superset-backend-server-${lower(random_id.suffix.id)}"
  location                     = azurerm_resource_group.rg.location
  resource_group_name          = azurerm_resource_group.rg.name
  sku_name                     = "B_Gen5_2"
  storage_mb                   = 5120
  backup_retention_days        = 7
  geo_redundant_backup_enabled = false
  auto_grow_enabled            = true
  administrator_login          = local.superset_backend_database_admin_username
  administrator_login_password = random_password.superset_backend_database_admin_password.result
  version                      = "11"
  ssl_enforcement_enabled      = true
}

// Allow Azure resources (e.g. AKS) to be able to access the PostgreSQL server
resource "azurerm_postgresql_firewall_rule" "azure_services" {
  name                = "azure_services"
  resource_group_name = azurerm_resource_group.rg.name
  server_name         = azurerm_postgresql_server.superset_backend_server.name
  start_ip_address    = "0.0.0.0"
  end_ip_address      = "0.0.0.0"
}

// Grant AKS access to ACR
resource "azurerm_role_assignment" "aks_kubelet_acr_pull" {
  scope                = azurerm_container_registry.acr.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.aks_kubelet_identity.principal_id
}

// AKS needs access to assign the public IP <https://docs.microsoft.com/en-us/azure/aks/static-ip>
resource "azurerm_role_assignment" "aks_rg_network_contributor" {
  principal_id         = azurerm_user_assigned_identity.aks_cluster_identity.principal_id
  role_definition_name = "Network Contributor"
  scope                = azurerm_resource_group.rg.id
}

// AKS identity needs permissions to be able to assign the Kubelet identity
resource "azurerm_role_assignment" "aks_cluster_identity_assign_kubelet_identity" {
  principal_id         = azurerm_user_assigned_identity.aks_cluster_identity.principal_id
  role_definition_name = "Managed Identity Operator"
  scope                = azurerm_user_assigned_identity.aks_kubelet_identity.id
}

resource "azurerm_key_vault" "superset_secrets" {
  name                        = "supersetsecrets${lower(random_id.suffix.id)}"
  location                    = azurerm_resource_group.rg.location
  resource_group_name         = azurerm_resource_group.rg.name
  enabled_for_disk_encryption = true
  tenant_id                   = data.azurerm_client_config.current.tenant_id
  soft_delete_retention_days  = 7
  purge_protection_enabled    = false
  sku_name                    = "standard"
  // Ensure we can create and read the secrets (and purge for when we want to tidy up afterwards)
  access_policy {
    tenant_id          = data.azurerm_client_config.current.tenant_id
    object_id          = data.azurerm_client_config.current.object_id
    secret_permissions = ["List", "Get", "Set", "Delete", "Purge"]
  }
}

resource "azurerm_key_vault_secret" "superset_backend_database_admin_password" {
  name         = "superset-backend-database-admin-password"
  value        = random_password.superset_backend_database_admin_password.result
  key_vault_id = azurerm_key_vault.superset_secrets.id
}

output "resource_group_name" {
  value = azurerm_resource_group.rg.name
}

output "aks_cluster_name" {
  value = azurerm_kubernetes_cluster.superset_cluster.name
}

output "acr_login_server" {
  value = azurerm_container_registry.acr.login_server
}

output "superset_web_ip" {
  value = azurerm_public_ip.superset_web_ip.ip_address
}

output "databse_host" {
  value = azurerm_postgresql_server.superset_backend_server.fqdn
}

output "database_admin_username" {
  value = local.superset_backend_database_admin_username
}

output "database_admin_password_secret_id" {
  value = azurerm_key_vault_secret.superset_backend_database_admin_password.id
}

output "redis_host" {
  value = azurerm_redis_cache.superset_cache.hostname
}

output "redis_port" {
  value = azurerm_redis_cache.superset_cache.ssl_port
}