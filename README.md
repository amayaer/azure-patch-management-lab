# Azure Patch Management Automation Lab

Automated pre- and post-patch health checks around Azure Update Manager scheduled patching. Terraform builds the lab, PowerShell does the checks, Azure Automation runbooks run them, and Event Grid triggers the runbooks from the maintenance window.
 
Before a patch window opens, a runbook checks each VM from the inside. If the pre-check script fails, the runbook cancels the maintenance run so patching doesn't occur on an unhealthy machine. If the script passes, it snapshots the OS disks and allows Update Manager to patch. After the window, a second runbook validates the VMs again.

## Repository layout
 
```
.
├── powershell/
│   ├── PrePatchCheck.ps1          # runs inside the VM (via Run Command)
│   ├── PostPatchValidation.ps1    # runs inside the VM (via Run Command)
│   ├── PreEventRunbook.ps1        # Automation runbook, triggered by the pre-maintenance event
│   ├── PostEventRunbook.ps1       # Automation runbook, triggered by the post-maintenance event
│   └── ComplianceReport.ps1       # Automation runbook, fleet-wide patch report
├── terraform/
│   ├── main.tf                    
│   ├── variables.tf
│   ├── outputs.tf
│   └── .terraform.lock.hcl       
├── docs/                         
└── .gitignore
```

## What the checks do
 
**Pre-patch (`PrePatchCheck.ps1`)**
 
- Connectivity to the Windows Update endpoints (checked first)
- Free space on the OS drive (flags below 20 GB)
- Pending reboot, from three separate indicators: Component Based Servicing, Windows Update `RebootRequired`, and pending file rename operations
- Health of the update services (`wuauserv`, `bits`, `cryptsvc`, `TrustedInstaller`), with an attempt to fix a service that's stopped or disabled

**Post-patch (`PostPatchValidation.ps1`)**
 
- Free space on the OS drive again
- The same update service checks

 
## Deploying
 
### Prerequisites
 
- An Azure subscription
- [Terraform](https://developer.hashicorp.com/terraform/install) and the [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli)
- These resource providers registered on the subscription: `Microsoft.Automation`, `Microsoft.Maintenance`, `Microsoft.EventGrid` (plus the usual Compute, Network, and Storage)
- The `Az.ResourceGraph` module available in the Automation account. 
### Steps
 
```bash
az login
az account show                     
 
export ARM_SUBSCRIPTION_ID="<your subscription id>"   
 
cd terraform
terraform init
terraform plan
terraform apply
```
