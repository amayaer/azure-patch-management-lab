variable "location" {
  type    = string
  default = "eastus"

}

variable "automation_location" {
  description = "Region for the Automation account and runbooks (separate from the VM region)"
  type        = string
  default     = "japanwest"
}

variable "admin_username" {
  type    = string
  default = "azureuser"
}

variable "admin_password" {
  type      = string
  sensitive = true
}

variable "maintenance_start" {
  description = "Window start, format YYYY-MM-DD HH:MM"
  type        = string
}