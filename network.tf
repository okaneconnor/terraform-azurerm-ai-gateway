resource "azurerm_virtual_network" "main" {
  for_each            = local.create_network ? { this = {} } : {}
  name                = "${var.name_prefix}-vnet-${local.suffix}"
  location            = local.resource_group_location
  resource_group_name = local.resource_group_name
  address_space       = [var.network.vnet_cidr]
  tags                = var.tags
}

resource "azurerm_subnet" "apim" {
  #checkov:skip=CKV2_AZURE_31:NSG is attached via azurerm_subnet_network_security_group_association.apim; checkov's graph does not link the for_each-keyed association back to the subnet (false positive).
  for_each             = local.create_network ? { this = {} } : {}
  name                 = "snet-apim"
  resource_group_name  = local.resource_group_name
  virtual_network_name = azurerm_virtual_network.main["this"].name
  address_prefixes     = [var.network.apim_subnet_cidr]
}

resource "azurerm_subnet" "pe" {
  #checkov:skip=CKV2_AZURE_31:Private-endpoint subnet — private endpoints bypass subnet NSGs (network policies disabled), so an NSG here has no effect. The APIM subnet carries the NSG; all backends have public access disabled.
  for_each             = local.create_network ? { this = {} } : {}
  name                 = "snet-private-endpoints"
  resource_group_name  = local.resource_group_name
  virtual_network_name = azurerm_virtual_network.main["this"].name
  address_prefixes     = [var.network.pe_subnet_cidr]
}

resource "azurerm_network_security_group" "apim" {
  for_each            = local.create_network ? { this = {} } : {}
  name                = "nsg-apim-${local.suffix}"
  location            = local.resource_group_location
  resource_group_name = local.resource_group_name
  tags                = var.tags

  security_rule {
    name                       = "in-client-443"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "Internet"
    destination_address_prefix = "VirtualNetwork"
  }
  security_rule {
    name                       = "in-apim-mgmt-3443"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3443"
    source_address_prefix      = "ApiManagement"
    destination_address_prefix = "VirtualNetwork"
  }
  security_rule {
    name                       = "in-lb-6390"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "6390"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "VirtualNetwork"
  }
  security_rule {
    name                       = "out-storage-443"
    priority                   = 200
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "Storage"
  }
  security_rule {
    name                       = "out-sql-1433"
    priority                   = 210
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "1433"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "Sql"
  }
  security_rule {
    name                       = "out-kv-443"
    priority                   = 220
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "AzureKeyVault"
  }
  security_rule {
    name                       = "out-monitor"
    priority                   = 230
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["443", "1886"]
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "AzureMonitor"
  }
}

resource "azurerm_subnet_network_security_group_association" "apim" {
  for_each                  = local.create_network ? { this = {} } : {}
  subnet_id                 = azurerm_subnet.apim["this"].id
  network_security_group_id = azurerm_network_security_group.apim["this"].id
}
