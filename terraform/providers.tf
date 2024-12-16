terraform {
  required_version = ">=1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~>4.1.0"
    }

    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.azure_subscription_id
}

provider "aws" {
  region = "us-east-1"
}
