variable "region" {
  type    = string
  default = "us-east-2" # the AWS account is region-locked to Ohio
}

variable "app" {
  type    = string
  default = "minutetaker"
}

variable "environment" {
  description = "Environment name; every resource is named <app>-<environment>-*."
  type        = string
  default     = "prod"
}

variable "kubernetes_version" {
  type    = string
  default = "1.35"
}

variable "node_instance_type" {
  description = "m7i-flex.large (2 vCPU, 8 GiB) is the largest type the AWS Free plan allows."
  type        = string
  default     = "m7i-flex.large"
}

variable "node_count" {
  description = "Worker nodes. Two, in two availability zones, so losing one node or AZ keeps the app up."
  type        = number
  default     = 2
}

variable "hosted_zone_name" {
  description = "Existing Route 53 public zone (created by hand in Project 1; the domain's nameservers point at it)."
  type        = string
  default     = "cloudscape.lol"
  validation {
    condition     = can(regex("^[a-z0-9-]+(\\.[a-z0-9-]+)+$", var.hosted_zone_name))
    error_message = "hosted_zone_name must be a bare domain like \"cloudscape.lol\" (no trailing dot, no scheme)."
  }
}

variable "subdomain" {
  type    = string
  default = "minutetaker" # https://minutetaker.cloudscape.lol
}

variable "admin_principal_arns" {
  description = "IAM principals that get kubectl cluster-admin, besides the CI role."
  type        = list(string)
  default     = ["arn:aws:iam::439093223948:user/jana-admin"]
}

variable "ci_role_name" {
  description = "Role GitHub Actions assumes (created by infra/bootstrap)."
  type        = string
  default     = "minutetaker-github-ci"
}
