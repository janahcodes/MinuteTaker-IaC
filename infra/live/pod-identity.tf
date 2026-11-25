# Per-service AWS permissions via EKS Pod Identity. This replaces Project 2's
# long-lived IAM user access key: each pod gets temporary credentials for its
# own role, and only api/worker ServiceAccounts get any role at all (web has none).
#
# Each list is exactly the calls that service's code makes (see services/*/).

data "aws_iam_policy_document" "pod_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "api" {
  statement {
    sid = "Meetings"
    actions = [
      "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:GetItem",
      "dynamodb:DeleteItem", "dynamodb:Scan", "dynamodb:DescribeTable",
    ]
    resources = [aws_dynamodb_table.meetings.arn]
  }
  statement {
    sid       = "Audio"
    actions   = ["s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload"] # upload_fileobj goes multipart above 8 MB
    resources = ["${aws_s3_bucket.audio.arn}/uploads/*"]
  }
  statement {
    sid       = "Jobs"
    actions   = ["sqs:SendMessage", "sqs:GetQueueAttributes"]
    resources = [aws_sqs_queue.jobs.arn]
  }
}

data "aws_iam_policy_document" "worker" {
  statement {
    sid       = "Meetings"
    actions   = ["dynamodb:UpdateItem"] # every state change is a conditional update
    resources = [aws_dynamodb_table.meetings.arn]
  }
  statement {
    sid       = "Audio"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.audio.arn}/uploads/*"]
  }
  statement {
    sid       = "Jobs"
    actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:ChangeMessageVisibility"]
    resources = [aws_sqs_queue.jobs.arn]
  }
}

locals {
  pod_policies = {
    api    = data.aws_iam_policy_document.api.json
    worker = data.aws_iam_policy_document.worker.json
  }
}

resource "aws_iam_role" "pod" {
  for_each           = local.pod_policies
  name               = "${local.name}-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.pod_trust.json
}

resource "aws_iam_role_policy" "pod" {
  for_each = local.pod_policies
  name     = "${local.name}-${each.key}"
  role     = aws_iam_role.pod[each.key].id
  policy   = each.value
}

# Binds role <-> (namespace, ServiceAccount). The ServiceAccounts themselves
# are in k8s/base and are created later by the deploy job; the association
# can exist first.
resource "aws_eks_pod_identity_association" "pod" {
  for_each        = local.pod_policies
  cluster_name    = aws_eks_cluster.main.name
  namespace       = "minutetaker"
  service_account = each.key
  role_arn        = aws_iam_role.pod[each.key].arn
}
