resource "azurerm_resource_group" "bernetes" {
  name     = "rg-bernetes"
  location = var.location
}

resource "azurerm_linux_virtual_machine" "bernetes" {
  name                  = "vm-bernetes-01"
  resource_group_name   = azurerm_resource_group.bernetes.name
  location              = azurerm_resource_group.bernetes.location
  size                  = "Standard_B2ps_v2" # TODO: Find a free size that supports x64
  admin_username        = var.admin_username
  network_interface_ids = [azurerm_network_interface.bernetes.id]

  admin_ssh_key {
    username   = var.admin_username
    public_key = file("~/.ssh/id_rsa.pub")
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 30
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }
}

resource "azurerm_virtual_network" "bernetes" {
  name                = "vnet-bernetes-01"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.bernetes.location
  resource_group_name = azurerm_resource_group.bernetes.name
}

resource "azurerm_subnet" "bernetes" {
  name                 = "subnet-bernetes-01"
  resource_group_name  = azurerm_resource_group.bernetes.name
  virtual_network_name = azurerm_virtual_network.bernetes.name
  address_prefixes     = ["10.0.2.0/24"]
}

resource "azurerm_network_interface" "bernetes" {
  name                = "nic-bernetes-01"
  location            = azurerm_resource_group.bernetes.location
  resource_group_name = azurerm_resource_group.bernetes.name

  ip_configuration {
    name                          = "ipconfig-bernetes-01"
    subnet_id                     = azurerm_subnet.bernetes.id
    private_ip_address_allocation = "Dynamic"
  }
}

output "vm_id" {
  description = "ID of the provisioned virtual machine."
  value       = azurerm_linux_virtual_machine.bernetes.id
}
