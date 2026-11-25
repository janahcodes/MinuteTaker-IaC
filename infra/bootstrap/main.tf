# Bootstrap: the few things that must exist BEFORE the pipeline can run, and
# that the pipeline must not destroy (it would be sawing off the branch it sits on):
#   1. the S3 bucket that holds Terraform state for infra/live
#   2. GitHub's OIDC identity provider + the role GitHub Actions assumes
#      (short-lived credentials, no AWS keys stored in GitHub)
# Applied once, by hand, with local state:  terraform -chdir=infra/bootstrap apply
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

provider "aws" {
  region = var.region
  default_tags { tags = { Project = "minutetaker", Course = "AI255-project3", Stack = "bootstrap" } }
}

variable "region" {
  type    = string
  default = "us-east-2" # the AWS account is region-locked to Ohio
}

variable "github_repo_subject" {
  description = <<-EOT
    Subject prefix GitHub puts in this repository's OIDC tokens. New repositories
    use GitHub's immutable format owner@<owner id>/repo@<repo id>: the numeric IDs
    mean a deleted-and-recreated repo (or a renamed owner) with the same name
    cannot assume the role. Read it with:
    gh api repos/OWNER/REPO/actions/oidc/customization/sub --jq .sub_claim_prefix
  EOT
  type        = string
  default     = "repo:janahcodes@260461252/MinuteTaker-IaC@1472439793"
}

data "aws_caller_identity" "me" {}

locals {
  prefix = "minutetaker" # every resource the pipeline may manage starts with this
}

# ---------------------------------------------------------------- state bucket
resource "aws_s3_bucket" "state" {
  bucket = "${local.prefix}-tfstate-${data.aws_caller_identity.me.account_id}"
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration { status = "Enabled" } # recover from a bad apply
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ------------------------------------------------------- GitHub Actions (OIDC)
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_policy_document" "ci_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    # Only workflow runs on main or in the protected "production" environment
    # of this one repository. Pull requests and forks get nothing.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "${var.github_repo_subject}:ref:refs/heads/main",
        "${var.github_repo_subject}:environment:production",
      ]
    }
  }
}

resource "aws_iam_role" "ci" {
  name                 = "${local.prefix}-github-ci"
  assume_role_policy   = data.aws_iam_policy_document.ci_trust.json
  max_session_duration = 7200 # an EKS create + deploy fits comfortably
}

# Terraform has to create VPCs, EKS, ALBs, DynamoDB, ... so the CI role gets
# PowerUserAccess (everything except IAM/Organizations) ...
resource "aws_iam_role_policy_attachment" "ci_power" {
  role       = aws_iam_role.ci.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

# ... plus IAM, but only on roles/policies named minutetaker-*. It cannot touch
# the admin user, its own role (minutetaker-github-ci is excluded below), or
# anything else in the account.
data "aws_iam_policy_document" "ci_iam" {
  statement {
    sid     = "ManageProjectRoles"
    actions = ["iam:*"]
    resources = [
      "arn:aws:iam::${data.aws_caller_identity.me.account_id}:role/${local.prefix}-prod-*",
      "arn:aws:iam::${data.aws_caller_identity.me.account_id}:policy/${local.prefix}-prod-*",
      "arn:aws:iam::${data.aws_caller_identity.me.account_id}:instance-profile/${local.prefix}-prod-*",
    ]
  }
  statement {
    sid       = "ServiceLinkedRoles"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]
    condition {
      test     = "StringLike"
      variable = "iam:AWSServiceName"
      values = [
        "eks.amazonaws.com", "eks-nodegroup.amazonaws.com",
        "elasticloadbalancing.amazonaws.com", "autoscaling.amazonaws.com",
      ]
    }
  }
  statement {
    sid       = "ReadIam"
    actions   = ["iam:Get*", "iam:List*"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ci_iam" {
  name   = "${local.prefix}-ci-iam"
  role   = aws_iam_role.ci.id
  policy = data.aws_iam_policy_document.ci_iam.json
}

output "state_bucket" { value = aws_s3_bucket.state.bucket }
output "ci_role_arn" { value = aws_iam_role.ci.arn }
