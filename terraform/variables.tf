variable "location" {
  type    = string
  default = "East US 2"

}
variable "admin_username" {
  type    = string
  default = "azureuser"
}

variable "admin_password" {
  type      = string
  sensitive = true
}
