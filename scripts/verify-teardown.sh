#!/usr/bin/env bash
# Prove a teardown is complete: query AWS directly (not Terraform's own state)
# for every kind of resource the environment creates. Exits 1 if any remain.
# Usage: scripts/verify-teardown.sh [name-prefix]
set -uo pipefail
P="${1:-minutetaker-prod}"
export AWS_REGION="${AWS_REGION:-us-east-2}"
left=0
check() { # label, command printing leftover resource names (empty = gone)
  local found
  found=$(eval "$2" 2>/dev/null | tr -s '\t\n' ' ' | sed 's/ *$//')
  if [ -n "$found" ] && [ "$found" != "None" ]; then echo "LEFT  $1: $found"; left=1; else echo "gone  $1"; fi
}

check "EKS cluster"        "aws eks list-clusters --query \"clusters[?@=='$P']\" --output text"
check "EC2 nodes"          "aws ec2 describe-instances --filters Name=tag:eks:cluster-name,Values=$P Name=instance-state-name,Values=pending,running,stopping,stopped --query 'Reservations[].Instances[].InstanceId' --output text"
check "load balancer"      "aws elbv2 describe-load-balancers --query \"LoadBalancers[?LoadBalancerName=='$P'].LoadBalancerName\" --output text"
check "target group"       "aws elbv2 describe-target-groups --query \"TargetGroups[?TargetGroupName=='$P-web'].TargetGroupName\" --output text"
check "VPC"                "aws ec2 describe-vpcs --filters Name=tag:Name,Values=$P --query 'Vpcs[].VpcId' --output text"
check "DynamoDB table"     "aws dynamodb list-tables --query \"TableNames[?starts_with(@,'$P')]\" --output text"
check "S3 bucket"          "aws s3api list-buckets --query \"Buckets[?starts_with(Name,'$P')].Name\" --output text"
check "SQS queues"         "aws sqs list-queues --queue-name-prefix $P --query 'QueueUrls' --output text"
check "ECR repositories"   "aws ecr describe-repositories --query \"repositories[?starts_with(repositoryName,'$P')].repositoryName\" --output text"
check "IAM roles"          "aws iam list-roles --query \"Roles[?starts_with(RoleName,'$P')].RoleName\" --output text"
check "log group"          "aws logs describe-log-groups --log-group-name-prefix /aws/eks/$P --query 'logGroups[].logGroupName' --output text"
check "EBS volumes"        "aws ec2 describe-volumes --filters Name=tag:eks:cluster-name,Values=$P --query 'Volumes[].VolumeId' --output text"
check "DNS record"         "aws route53 list-resource-record-sets --hosted-zone-id \$(aws route53 list-hosted-zones-by-name --dns-name cloudscape.lol --query 'HostedZones[0].Id' --output text) --query \"ResourceRecordSets[?Name=='minutetaker.cloudscape.lol.'].Name\" --output text"

echo
if [ $left = 0 ]; then echo "Teardown verified: no environment resources remain."; else echo "Teardown INCOMPLETE"; exit 1; fi
