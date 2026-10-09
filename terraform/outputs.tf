output "vm_private_ip" {
  value = azurerm_network_interface.lab-nic.private_ip_address
}

