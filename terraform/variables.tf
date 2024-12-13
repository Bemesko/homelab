variable "azure_subscription_id" {
  description = "Azure subscription ID."
  type        = string
}

variable "location" {
  description = "Azure region for the resources."
  type        = string
  default     = "westus3"
}

variable "admin_username" {
  description = "Admin username for the virtual machine."
  type        = string
}
