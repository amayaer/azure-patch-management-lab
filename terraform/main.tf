terraform {
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
    }

    azuread = {
      source = "hashicorp/azuread"
    }

    random = {
      source = "hashicorp/random"
    }
  }
}

provider "azurerm" {
  features {}
}

resource "azurerm_resource_group" "patch_lab" {
  name     = "rg-terraform-patch-lab"
  location = var.location
}

resource "azurerm_virtual_network" "lab_vnet" {
  name                = "vnet-terraform-patch-lab"
  address_space       = ["0.0.0.0/16"]
  location            = var.location
  resource_group_name = azurerm_resource_group.patch_lab.name
}

resource "azurerm_subnet" "lab_subnet" {
  name                 = "subnet-patch-lab"
  resource_group_name  = azurerm_resource_group.patch_lab.name
  virtual_network_name = azurerm_virtual_network.lab_vnet.name
  address_prefixes     = ["10.0.2.0/24"]
}

resource "azurerm_network_security_group" "lab-nsg" {
  name                = "nsg-patch-lab"
  location            = var.location
  resource_group_name = azurerm_resource_group.patch_lab.name
  security_rule {
    name                       = "deny-vnet-inbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }
}

#associate the network security group with the subnets
resource "azurerm_subnet_network_security_group_association" "nsg-association" {
  subnet_id                 = azurerm_subnet.lab_subnet.id
  network_security_group_id = azurerm_network_security_group.lab-nsg.id
}

#create network interface for the virtual machine
resource "azurerm_network_interface" "lab-nic" {
  name                = "lab-nic"
  location            = var.location
  resource_group_name = azurerm_resource_group.patch_lab.name

  ip_configuration {
    name                          = "lab-ip-config"
    subnet_id                     = azurerm_subnet.lab_subnet.id
    private_ip_address_allocation = "Dynamic"
  }
}

#create virtual machine(s)
resource "azurerm_windows_virtual_machine" "lab-vm" {
  name                = "windows-vm"
  resource_group_name = azurerm_resource_group.patch_lab.name
  location            = var.location
  size                = "---"
  admin_username      = "var.admin_username"
  admin_password      = "var.admin_password"

  network_interface_ids = [
    azurerm_network_interface.lab-nic.id
  ]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2016-Datacenter"
    version   = ""
  }

}

#create storage account
resource "azurerm_storage_account" "lab-sa" {
  name                     = "azurepatchlabstoracc0896"
  resource_group_name      = azurerm_resource_group.patch_lab.name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

#create storage container
resource "azurerm_storage_container" "lab-sc" {
  name                  = "lab-scripts"
  storage_account_id    = azurerm_storage_account.lab-sa.id
  container_access_type = "private"
}

#create storage blobs
resource "azurerm_storage_blob" "pre-check" {
  name                 = "lab-preblob"
  storage_container_id = azurerm_storage_container.lab-sc.id
  type                 = "Block"
  source               = "${path.module}/../powershell/PrePatchCheck.ps1"
  content_md5          = filemd5("${path.module}/../powershell/PrePatchCheck.ps1")
}

resource "azurerm_storage_blob" "post-check" {
  name                 = "lab-postblob"
  storage_container_id = azurerm_storage_container.lab-sc.id
  type                 = "Block"
  source               = "${path.module}/../powershell/PostPatchValidation.ps1"
  content_md5          = filemd5("${path.module}/../powershell/PostPatchValidation.ps1")
}

