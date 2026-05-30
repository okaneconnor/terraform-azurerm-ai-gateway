resource "random_string" "suffix" {
  length  = 5
  special = false
  upper   = false
  numeric = true
}

locals {
  suffix    = random_string.suffix.result
  rg_name   = "${var.name_prefix}-uks-rg"
  apim_name = "${var.name_prefix}-apim-${local.suffix}"
  law_name  = "${var.name_prefix}-law-${local.suffix}"
  ai_name   = "${var.name_prefix}-appi-${local.suffix}"
  kv_name   = "${var.name_prefix}kv${local.suffix}" # <=24 chars, alnum

  foundry_name  = "${var.name_prefix}-fdry-${local.suffix}"
  speech_name   = "${var.name_prefix}-spch-${local.suffix}"
  language_name = "${var.name_prefix}-lang-${local.suffix}"
  docintel_name = "${var.name_prefix}-doci-${local.suffix}"
  cs_name       = "${var.name_prefix}-cs-${local.suffix}"
  apic_name     = "${var.name_prefix}-apic-${local.suffix}"

  tenant_id = data.azurerm_client_config.current.tenant_id
}
