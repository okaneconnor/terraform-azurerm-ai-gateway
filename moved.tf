# State-address migrations. Several always-on resources gained `count` when the
# bring-your-own options were added (so the module can skip creating them), which
# changes their addresses from `X` to `X[0]`. These moved blocks let existing
# deployments upgrade in place — no destroy/recreate — and are no-ops on fresh
# deployments.

moved {
  from = random_string.suffix
  to   = random_string.suffix[0]
}

moved {
  from = azurerm_resource_group.rg
  to   = azurerm_resource_group.rg[0]
}

moved {
  from = azurerm_log_analytics_workspace.law
  to   = azurerm_log_analytics_workspace.law[0]
}

moved {
  from = azurerm_application_insights.ai
  to   = azurerm_application_insights.ai[0]
}

moved {
  from = azurerm_virtual_network.main
  to   = azurerm_virtual_network.main[0]
}

moved {
  from = azurerm_subnet.apim
  to   = azurerm_subnet.apim[0]
}

moved {
  from = azurerm_subnet.pe
  to   = azurerm_subnet.pe[0]
}

moved {
  from = azurerm_network_security_group.apim
  to   = azurerm_network_security_group.apim[0]
}

moved {
  from = azurerm_subnet_network_security_group_association.apim
  to   = azurerm_subnet_network_security_group_association.apim[0]
}
