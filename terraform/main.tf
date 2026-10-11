terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.9.0"
    }
  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

#create resource group
resource "azurerm_resource_group" "patch_lab" {
  name     = "rg-terraform-patch-lab"
  location = var.location
}

#create automation account
resource "azurerm_automation_account" "lab-acc" {
  name                = "automation-account-patch-lab"
  location            = var.location
  resource_group_name = azurerm_resource_group.patch_lab.name
  sku_name            = "Basic"

  identity {
    type = "SystemAssigned"
  }
}

#create pre/post runbooks
resource "azurerm_automation_runbook" "pre-run" {
  name                    = "PreEventRunbook"
  location                = var.location
  resource_group_name     = azurerm_resource_group.patch_lab.name
  automation_account_name = azurerm_automation_account.lab-acc.name
  runbook_type            = "PowerShell72"
  log_verbose             = true
  log_progress            = true
  content                 = file("${path.module}/../powershell/PreEventRunbook.ps1")

}

resource "azurerm_automation_runbook" "post-run" {
  name                    = "PostEventRunbook"
  location                = var.location
  resource_group_name     = azurerm_resource_group.patch_lab.name
  automation_account_name = azurerm_automation_account.lab-acc.name
  runbook_type            = "PowerShell72"
  log_verbose             = true
  log_progress            = true
  content                 = file("${path.module}/../powershell/PostEventRunbook.ps1")
}

#create pre/post webhooks 
resource "azurerm_automation_webhook" "pre-webhook" {
  name                    = "pre-patch-webhook"
  resource_group_name     = azurerm_resource_group.patch_lab.name
  automation_account_name = azurerm_automation_account.lab-acc.name
  runbook_name            = azurerm_automation_runbook.pre-run.name
  expiry_time             = "2027-10-01T00:00:00Z"
}

resource "azurerm_automation_webhook" "post-webhook" {
  name                    = "post-patch-webhook"
  resource_group_name     = azurerm_resource_group.patch_lab.name
  automation_account_name = azurerm_automation_account.lab-acc.name
  runbook_name            = azurerm_automation_runbook.post-run.name
  expiry_time             = "2027-10-01T00:00:00Z"
}

#create event grid system topic
resource "azurerm_eventgrid_system_topic" "maint-events" {
  name                = "maint-events"
  resource_group_name = azurerm_resource_group.patch_lab.name
  location            = var.location
  source_resource_id  = azurerm_maintenance_configuration.lab-maint.id
  topic_type          = "Microsoft.Maintenance.MaintenanceConfigurations"
}

#create pre/post event subscriptions
resource "azurerm_eventgrid_system_topic_event_subscription" "pre-event" {
  name                 = "pre-event"
  system_topic         = azurerm_eventgrid_system_topic.maint-events.name
  resource_group_name  = azurerm_resource_group.patch_lab.name
  included_event_types = ["Microsoft.Maintenance.PreMaintenanceEvent"]

  webhook_endpoint {
    url = azurerm_automation_webhook.pre-webhook.uri
  }
}

resource "azurerm_eventgrid_system_topic_event_subscription" "post-event" {
  name                 = "post-event"
  system_topic         = azurerm_eventgrid_system_topic.maint-events.name
  resource_group_name  = azurerm_resource_group.patch_lab.name
  included_event_types = ["Microsoft.Maintenance.PostMaintenanceEvent"]

  webhook_endpoint {
    url = azurerm_automation_webhook.post-webhook.uri
  }
}

#create virtual network
resource "azurerm_virtual_network" "lab_vnet" {
  name                = "vnet-terraform-patch-lab"
  address_space       = ["10.0.0.0/16"]
  location            = var.location
  resource_group_name = azurerm_resource_group.patch_lab.name
}

#create subnet
resource "azurerm_subnet" "lab_subnet" {
  name                 = "subnet-patch-lab"
  resource_group_name  = azurerm_resource_group.patch_lab.name
  virtual_network_name = azurerm_virtual_network.lab_vnet.name
  address_prefixes     = ["10.0.2.0/24"]
}

#create nsg
resource "azurerm_network_security_group" "lab-nsg" {
  name                = "nsg-patch-lab"
  location            = var.location
  resource_group_name = azurerm_resource_group.patch_lab.name

  security_rule {
    name                       = "deny-internet-inbound"
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
  size                = "Standard_D2a_v4"
  admin_username      = var.admin_username
  admin_password      = var.admin_password

  patch_mode                                             = "AutomaticByPlatform"
  patch_assessment_mode                                  = "AutomaticByPlatform"
  provision_vm_agent                                     = true
  bypass_platform_safety_checks_on_user_schedule_enabled = true

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
    version   = "14393.8783.260109"
  }

}

#create maintenance configuration
resource "azurerm_maintenance_configuration" "lab-maint" {
  name                     = "maint-config-patch-lab"
  resource_group_name      = azurerm_resource_group.patch_lab.name
  location                 = var.location
  scope                    = "InGuestPatch"
  in_guest_user_patch_mode = "User"

  window {
    start_date_time = var.maintenance_start
    duration        = "02:00"
    time_zone       = "Central Standard Time"
    recur_every     = "Day"
  }

  install_patches {
    reboot = "IfRequired"
    windows {
      classifications_to_include = ["Critical", "Security"]
    }
  }
}

#attach VM 
resource "azurerm_maintenance_assignment_virtual_machine" "lab-assign" {
  location                     = var.location
  maintenance_configuration_id = azurerm_maintenance_configuration.lab-maint.id
  virtual_machine_id           = azurerm_windows_virtual_machine.lab-vm.id
}

#create storage account
resource "azurerm_storage_account" "lab-sa" {
  name                     = "azurepatchlabstoracc0896"
  resource_group_name      = azurerm_resource_group.patch_lab.name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

#create compliance report storage container
resource "azurerm_storage_container" "lab-report" {
  name                  = "lab-report"
  storage_account_id    = azurerm_storage_account.lab-sa.id
  container_access_type = "private"
}

#create scripts storage container
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

#create automation account roles
resource "azurerm_role_assignment" "auto-blob-reader" {
  scope                = azurerm_storage_account.lab-sa.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_automation_account.lab-acc.identity[0].principal_id

  depends_on = [
    azurerm_automation_account.lab-acc
  ]
}
resource "azurerm_role_assignment" "auto-report-writer" {
  scope                = azurerm_storage_container.lab-report.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_automation_account.lab-acc.identity[0].principal_id

  depends_on = [
    azurerm_automation_account.lab-acc
  ]
}
resource "azurerm_role_assignment" "auto-rg-contributor" {
  scope                = azurerm_resource_group.patch_lab.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_automation_account.lab-acc.identity[0].principal_id

  depends_on = [
    azurerm_automation_account.lab-acc
  ]
}