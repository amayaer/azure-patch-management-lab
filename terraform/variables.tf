variable "location" {
  type    = string
  default = "eastus"

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
  default = "2026-10-10 21:00"
}