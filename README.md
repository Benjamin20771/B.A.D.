
<h1 align="center">B.A.D.</h1>

## This is a personal repo with project details, scripts, and documentation

### Repository Structure
- - -
B.A.D./

├── Scripts/

│     ├── windows-onboard.ps1     # Windows system onboarding

│     ├── linux-onboard.sh        # Linux system onboarding

│     └── ad-setup.ps1            # Active Directory setup

└── Projects/

  └── Scriptinator/           # GUI tool for remote script execution via Proxmox
    
- - -

### Scripts
All scripts are interactive as they walk you through configuration step by step with prompts, validation, and color-coded output.

#### windows-onboard.ps1
Interactive onboarding script for Windows 10 and Windows Server 2019 (Core + GUI). Configures networking, sets hostname, creates local users, optionally joins a domain, enables RDP/WinRM, and installs RSAT tools.

* Full Documentation → Wiki: Windows Link


#### linux-onboard.sh
Interactive onboarding script for Ubuntu and Rocky/CentOS systems. Handles static or DHCP network configuration, hostname setup, user creation, SSH hardening, and firewall configuration.

* Full Documentation → Wiki: Linux Link


#### ad-setup.ps1
Interactive Active Directory setup script. Auto-detects whether to promote as DC1 (new forest) or DC2 (additional domain controller). Handles domain user creation and replication verification.

* Full Documentation → Wiki: AD Link


### Projects
#### Scriptinator
Status: In Progress
A WinForms GUI tool (with a Python/Tkinter port in progress) for remotely executing scripts across Proxmox VMs. Connects to a Proxmox cluster via REST API, detects VM operating systems using the QEMU guest agent, fetches scripts dynamically from GitHub, and executes them all from a single interface. Includes session logging, multi-VM pool execution, and a reverse script feature (In Progress).

* Full Documentation → Wiki: Scriptinator Link
* Project Board → Scriptinator Roadmap Link
