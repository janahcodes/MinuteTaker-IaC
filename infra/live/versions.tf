# The whole Project 2 environment, as code. `terraform apply` builds it from
# nothing; `terraform destroy` removes every billable piece of it.
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }

  # State lives in S3 (created by infra/bootstrap) so the pipeline and a laptop
  # see the same state. use_lockfile = S3-native locking: two concurrent
  # applies can't corrupt it.
  backend "s3" {
    bucket       = "minutetaker-tfstate-439093223948"
    key          = "live/prod.tfstate"
    region       = "us-east-2"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { Project = "minutetaker", Course = "AI255-project3", Stack = "live", Environment = var.environment }
  }
}

data "aws_caller_identity" "me" {}
data "aws_availability_zones" "available" { state = "available" }

locals {
  name       = "${var.app}-${var.environment}" # minutetaker-prod
  account_id = data.aws_caller_identity.me.account_id
  azs        = slice(data.aws_availability_zones.available.names, 0, 2)
  fqdn       = "${var.subdomain}.${var.hosted_zone_name}"
}
