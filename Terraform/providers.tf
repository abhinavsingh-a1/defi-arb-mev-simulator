terraform {
    backend "s3" {
      bucket         = "tf-s3-bucket-dics"
      key            = "terraform.tfstate"
      region         = "us-west-2"
      dynamodb_table = "terraform-eks-state-locks"
      encrypt        = true
    }
}
  
  provider "aws" {
    region = var.aws_region

    default_tags {
      tags = {
        Project     = var.project_name
        Environment = var.environment
        ManagedBy   = "terraform"
      }
    }
  }
