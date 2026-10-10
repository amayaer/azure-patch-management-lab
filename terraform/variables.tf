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