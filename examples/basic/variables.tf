variable "subscription_id" {
  description = "Target Azure subscription."
  type        = string
}

variable "location" {
  description = "Azure region (must offer your models as in-region Standard deployments)."
  type        = string
  default     = "uksouth"
}

variable "publisher_name" {
  description = "APIM publisher name."
  type        = string
  default     = "AI Platform Team"
}

variable "publisher_email" {
  description = "APIM publisher email."
  type        = string
  default     = "admin@example.com"
}
