# `terraform test` for infra/live, run by the pipeline on every push.
# A mock AWS provider means no credentials and no real resources: these tests
# check the configuration's decisions, not AWS.
#   terraform -chdir=infra/live init -backend=false && terraform -chdir=infra/live test

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_availability_zones" {
    defaults = { names = ["us-east-2a", "us-east-2b", "us-east-2c"] }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

# Values AWS only knows after it creates something; fixed so the plan can be computed.
override_resource {
  target          = aws_eks_node_group.main
  override_during = plan
  values = {
    resources = [{ autoscaling_groups = [{ name = "mock-asg" }], remote_access_security_group_id = "" }]
  }
}

override_resource {
  target          = aws_acm_certificate.app
  override_during = plan
  values = {
    arn = "arn:aws:acm:us-east-2:123456789012:certificate/mock"
    domain_validation_options = [{
      domain_name           = "minutetaker.cloudscape.lol"
      resource_record_name  = "_mock.minutetaker.cloudscape.lol."
      resource_record_type  = "CNAME"
      resource_record_value = "_mock.acm-validations.aws."
    }]
  }
}

run "environment_can_be_destroyed" {
  command = plan
  assert {
    condition     = aws_dynamodb_table.meetings.deletion_protection_enabled == false
    error_message = "DynamoDB deletion protection would block terraform destroy."
  }
  assert {
    condition     = aws_s3_bucket.audio.force_destroy
    error_message = "The audio bucket must be emptied on destroy, or destroy fails while it holds recordings."
  }
  assert {
    condition     = alltrue([for r in aws_ecr_repository.svc : r.force_delete])
    error_message = "ECR repositories must be deletable while they still contain images."
  }
}

run "spans_two_availability_zones" {
  command = plan
  assert {
    condition     = length(distinct(aws_subnet.public[*].availability_zone)) == 2
    error_message = "EKS needs subnets in two different availability zones."
  }
  assert {
    condition     = aws_eks_node_group.main.scaling_config[0].min_size >= 2
    error_message = "At least two nodes, so losing one node keeps the app up."
  }
}

run "pods_cannot_use_the_node_role" {
  command = plan
  assert {
    condition     = aws_launch_template.node.metadata_options[0].http_put_response_hop_limit == 1
    error_message = "IMDS hop limit must be 1 so containers can't fetch the node's credentials."
  }
  assert {
    condition     = aws_launch_template.node.metadata_options[0].http_tokens == "required"
    error_message = "IMDSv2 must be required."
  }
}

run "each_service_gets_its_own_role" {
  command = plan
  assert {
    condition     = toset([for a in aws_eks_pod_identity_association.pod : "${a.namespace}/${a.service_account}"]) == toset(["minutetaker/api", "minutetaker/worker"])
    error_message = "Only the api and worker ServiceAccounts in namespace minutetaker get AWS roles (web gets none)."
  }
}

run "https_only" {
  command = plan
  assert {
    condition     = aws_lb_listener.http.default_action[0].type == "redirect" && aws_lb_listener.http.default_action[0].redirect[0].protocol == "HTTPS"
    error_message = "Port 80 must redirect to HTTPS (microphone recording only works on secure origins)."
  }
  assert {
    condition     = startswith(aws_lb_listener.https.ssl_policy, "ELBSecurityPolicy-TLS13")
    error_message = "The HTTPS listener must use a TLS 1.3 policy."
  }
}

run "domain_must_be_a_bare_zone_name" {
  command = plan
  variables {
    hosted_zone_name = "cloudscape.lol."
  }
  expect_failures = [var.hosted_zone_name]
}
