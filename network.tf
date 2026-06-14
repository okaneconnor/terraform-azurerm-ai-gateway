# Network: created by default, or skipped entirely when var.existing_network is set
# (BYO VNet/subnets for landing-zone adoption). When BYO, you own the APIM subnet's
# NSG — see README for the required APIM inbound/outbound rules.

resource "azurerm_virtual_network" "main" {
  count               = local.create_network ? 1 : 0
  name                = "${var.name_prefix}-vnet-${local.suffix}"
  location            = local.resource_group_location
  resource_group_name = local.resource_group_name
  address_space       = [var.network.vnet_cidr]
  tags                = var.tags
}

resource "azurerm_subnet" "apim" {
  count                = local.create_network ? 1 : 0
  name                 = "snet-apim"
  resource_group_name  = local.resource_group_name
  virtual_network_name = azurerm_virtual_network.main[0].name
  address_prefixes     = [var.network.apim_subnet_cidr]
}

resource "azurerm_subnet" "pe" {
  count                = local.create_network ? 1 : 0
  name                 = "snet-private-endpoints"
  resource_group_name  = local.resource_group_name
  virtual_network_name = azurerm_virtual_network.main[0].name
  address_prefixes     = [var.network.pe_subnet_cidr]
}

resource "azurerm_network_security_group" "apim" {
  count               = local.create_network ? 1 : 0
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
  count                     = local.create_network ? 1 : 0
  subnet_id                 = azurerm_subnet.apim[0].id
  network_security_group_id = azurerm_network_security_group.apim[0].id
}
