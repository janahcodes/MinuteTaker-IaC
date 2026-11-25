# MinuteTaker: Project 3 Report
### Infrastructure as Code and CI/CD (AI 255, Cloud Computing Concepts)

**Repository:** https://github.com/janahcodes/MinuteTaker-IaC
**Live URL (while the environment is up):** https://minutetaker.cloudscape.lol

## 1. Summary

Project 2 ran MinuteTaker's three services on a local `kind` cluster, which shell scripts created by hand. It used real DynamoDB, S3 and SQS through a long-lived IAM access key. Project 3 reproduces that entire environment from Terraform on **Amazon EKS**, and a GitHub Actions pipeline tests, builds and deploys it on every commit. The environment was **destroyed and rebuilt from scratch by the pipeline**, and an end-to-end test against the live HTTPS URL verified both runs (§6).

## 2. Requirements checklist

| Requirement (syllabus) | How it is met | Evidence |
|---|---|---|
| Reproduce the **entire Project 2 environment** | All of it is in code: network, Kubernetes cluster, nodes, cluster add-ons (metrics-server, which Project 2 installed by hand), DynamoDB, S3, SQS + DLQ, ECR, IAM, and the app's Deployments, probes, HPAs and PDBs. The same `k8s/base` manifests as Project 2 are used, with an EKS overlay. | `infra/live/*.tf` (59 resources), `k8s/` |
| …from **version-controlled infrastructure code** | Terraform for AWS, Kustomize for Kubernetes, both in Git. State lives in versioned, encrypted S3 with locking, so the pipeline and a laptop share one state. | `infra/`, `k8s/`, `infra/bootstrap` |
| Pipeline that **builds** | Docker images for api, worker and web are built on every push. On `main` they are pushed to ECR, tagged with the commit SHA (immutable tags). | `.github/workflows/pipeline.yml` jobs `build`, `images` |
| …**tests** | 45 unit tests (api + worker, AWS mocked with moto); `terraform fmt`/`validate`; manifests checked against the Kubernetes 1.35 schemas (kubeconform); shellcheck. After deploy, an **end-to-end smoke test** on the live URL. | jobs `test`, `validate`, `smoke`; `scripts/smoke-test.sh` |
| …**deploys automatically on commit** | A push to `main` runs `terraform apply` → push images → `kubectl apply` → rollout wait with automatic rollback → smoke test. No manual step. | run [45689497228](https://github.com/janahcodes/MinuteTaker-IaC/actions/runs/45689497228): push → verified live in 3 min 55 s |
| Environment **destroyable** | `teardown` workflow: `terraform destroy`, then `verify-teardown.sh` asks AWS directly (not Terraform's state) that 13 kinds of resource are gone. | §6.1 |
| …and **rebuildable from scratch** | Running `pipeline` manually after a teardown recreates everything from code and smoke-tests it. | §6.2 |
| Demonstration = full teardown and rebuild | Both are one-click workflows with timings written to the run summary. | §6, §9 |
| Git repo + written report; commit history | Repository above (keeps Project 2's history, then the Project 3 commits); this report. | `git log` |

## 3. Architecture

```
                 ┌──────────────────────────── GitHub ─────────────────────────────┐
  git push ────► │ test ─ validate ─► gate ─► terraform apply ─► build+push (ECR) ─► │
                 │                     deploy (kubectl, auto-rollback) ─► smoke test│
                 └──────────────┬─────────────────────────────────────────────────┘
                                │ OIDC token → sts:AssumeRoleWithWebIdentity (no stored keys)
  ┌─────────────────────────── AWS us-east-2 ────────────────────────────────────────┐
  │ Route 53  minutetaker.cloudscape.lol ─► ALB :443 (ACM cert, TLS 1.3/1.2) :80→301 │
  │                                          │ NodePort 30080                        │
  │  VPC 10.40.0.0/16, 2 AZs   ┌─────────────┴─────────── EKS 1.35 ───────────────┐  │
  │                            │ node (AZ a)                 node (AZ b)          │  │
  │                            │  web ×2 (nginx) ─► api ×2 (FastAPI) ─► worker ×1–5│  │
  │                            │  HPAs · PDBs · probes · metrics-server           │  │
  │                            └───────┬──────────────────────────┬───────────────┘  │
  │       Pod Identity: api role ──────┤          worker role ────┤                  │
  │                   DynamoDB (meetings) · S3 (audio) · SQS jobs + DLQ · ECR        │
  └──────────────────────────────────────────────────────────────────────────────────┘
  Bootstrap (created once, survives teardown): S3 Terraform state bucket, GitHub OIDC provider, CI role
```

## 4. Design decisions

**EKS rather than k3s on a VM or keeping kind.** My Project 2 report planned the move to EKS for this project. It's the managed Kubernetes service that Project 2's manifests were written for, and EKS Pod Identity removes Project 2's static access key. The cost is a slower rebuild: the EKS control plane alone takes about 10 minutes to create, measured in §6. A k3s VM would rebuild in about 5 minutes at a third of the price. But that would mean running my own control plane, and the demo would be less representative of a real cloud environment.

**Two layers of state: `bootstrap` and `live`.** The pipeline needs somewhere to keep Terraform state, and an AWS identity to run as. If those were inside the environment, `terraform destroy` would delete the state bucket it is writing to and the role it is running as. So they live in a small separate stack, applied once by hand. Everything billable is in `live`, and that's what teardown removes. Teardown leaves only an S3 bucket of a few kilobytes plus IAM objects, which cost nothing.

**No AWS keys anywhere.** GitHub Actions authenticates with OpenID Connect. The CI role trusts only tokens for this repository's `main` branch or its `production` environment, so pull requests and forks get nothing. In the cluster, each service gets its own role through Pod Identity, scoped to exactly the API calls its code makes:
- **api:** DynamoDB put, get, update, delete, scan and describe; S3 put and delete; SQS send and queue stats.
- **worker:** DynamoDB update only; S3 get; SQS receive, delete and change-visibility.
- **web:** no AWS role at all.

The node's launch template sets the instance metadata hop limit to 1, so pods can't fall back to the node's own role. All of this was verified on the live cluster (§7).

**The load balancer is a Terraform resource, not created from inside Kubernetes.** With the AWS Load Balancer Controller, the ALB would be created by a pod, and Terraform wouldn't know it exists. On `destroy` it would be left behind, still holding network interfaces in the VPC, so deleting the VPC fails. Terraform creates the ALB, target group and listeners itself, and every node in the managed node group registers automatically. Nothing inside Kubernetes creates AWS resources, which is why a plain `terraform destroy` is complete.

**HTTPS is required, not cosmetic.** The UI's "Record mic" and "Record a call" buttons use `getUserMedia`, which browsers only allow on secure origins. In Project 2, `localhost` counted as secure. In the cloud, plain HTTP would have silently broken recording. The ACM certificate is validated through DNS in the existing `cloudscape.lol` Route 53 zone (from Project 1), and HTTP redirects to HTTPS.

**Public subnets, no NAT gateway.** A NAT gateway costs about $33/month before any traffic, more than the rest of the network combined. Nodes sit in public subnets so they can reach ECR and AWS APIs. Inbound traffic is still closed: the node security group admits only the ALB, on port 30080, and the EKS control plane. In production I would move the nodes to private subnets behind a NAT or VPC endpoints (§10).

**Image tag = commit SHA, in immutable ECR repositories.** Every running pod can be traced to the exact commit that built it, and a tag can never be pushed twice with different contents. Rollback means redeploying an earlier SHA.

**The deploy gate.** After a teardown, a routine push should not quietly recreate an EKS cluster that costs about $8 a day. The `gate` job checks whether the cluster exists:
- **Push while the environment is up:** the push deploys.
- **Push while the environment is down:** all the CI checks run, and the deploy is skipped with a notice.
- **Manual run (`workflow_dispatch`):** always builds or rebuilds the environment.

**Safe rollouts.** The deploy job waits for each Deployment, and if any one fails to become ready it runs `kubectl rollout undo` on all of them, then fails the run. `concurrency: production` stops two applies or deploys from running at once, and Terraform's S3 lockfile is a second safeguard.

## 5. The pipeline

| Job | Runs on | What it does |
|---|---|---|
| `test (api)`, `test (worker)` | every push / PR | pytest, 13 + 32 tests |
| `validate` | every push / PR | `terraform fmt -check`, `validate` (both stacks), kubeconform (both overlays, strict, K8s 1.35), shellcheck |
| `build` | other branches / PRs | builds the 3 images (nothing pushed) |
| `gate` | `main` | decides whether to deploy (above) |
| `terraform apply` | `main` | `plan -out` then apply that exact plan; outputs registry + URL |
| `push image` ×3 | `main` | buildx with the GitHub Actions layer cache, pushed to ECR as `:<sha>` |
| `deploy` | `main` | kubeconfig via EKS access entry; config rendered from `terraform output`; images pinned to the SHA; `kubectl apply -k`; rollout wait / auto-rollback |
| `smoke` | `main` | `scripts/smoke-test.sh` against the public URL |
| `teardown` workflow | manual, type `destroy` | `terraform destroy` + `verify-teardown.sh` |

`smoke-test.sh` exercises every hop:
- HTTP redirects to HTTPS, and the certificate is valid.
- The UI loads.
- The api reaches SQS, which proves its Pod Identity credentials work.
- A real 26-second recording is uploaded.
- The worker transcribes it with Whisper.
- The transcript contains the expected words, at least two action items are found, and "Sarah" is extracted as an owner.
- Search returns the meeting.
- The meeting is deleted to clean up.

## 6. Teardown and rebuild (measured)

All runs below are GitHub Actions runs against the real AWS account. The first creation of the environment, run [45686863130](https://github.com/janahcodes/MinuteTaker-IaC/actions/runs/45686863130), took **15 min 12 s** from click to deployed. `terraform apply` alone took **11 min 57 s**, almost all of it waiting for the EKS control plane and the node group.

### 6.1 Teardown
Run [45691187891](https://github.com/janahcodes/MinuteTaker-IaC/actions/runs/45691187891), the `teardown` workflow with `confirm=destroy`:

* `terraform destroy`: **"Destroy complete! Resources: 59 destroyed."** The whole job took **12 min 4 s**, mostly waiting for EKS to delete the node group and then the control plane.
* `verify-teardown.sh` then queried AWS directly, not Terraform's state:
  ```
  gone  EKS cluster        gone  VPC               gone  ECR repositories
  gone  EC2 nodes          gone  DynamoDB table    gone  IAM roles
  gone  load balancer      gone  S3 bucket         gone  log group
  gone  target group       gone  SQS queues        gone  EBS volumes
  gone  DNS record
  Teardown verified: no environment resources remain.
  ```
* Running the same script from my laptop gave the same result, and `https://minutetaker.cloudscape.lol` no longer resolved.
* What survives is only the bootstrap stack (§4): the Terraform state bucket, the GitHub OIDC provider and the CI role. The teardown itself depends on them.

### 6.2 Rebuild from nothing
Run [45693338788](https://github.com/janahcodes/MinuteTaker-IaC/actions/runs/45693338788): `pipeline` run manually right after the verified teardown, with nothing left in AWS except the bootstrap stack.

| Stage | Time |
|---|---|
| Tests + validation (parallel) | 30 s |
| `terraform apply`: **"Apply complete! Resources: 59 added, 0 changed, 0 destroyed."** | 11 min 52 s |
| Build + push 3 images to the newly created, empty ECR repositories | 30–34 s each (parallel) |
| Deploy + rollout on the new cluster | 39 s |
| End-to-end smoke test: **"SMOKE TEST PASSED"**; recording transcribed in 1.01 s, *"Sarah: Send the revised proposal to the client (due by Friday)"* | 13 s |
| **Total, click to verified live environment** | **14 min 9 s** |

A full teardown-and-rebuild cycle therefore takes about **26 minutes** (12 min 4 s + 14 min 9 s), with no manual steps between the two clicks. The rebuilt environment was identical: same URL, same names, a new certificate issued and validated automatically, and the app working end to end.

### 6.3 Routine deploy on commit
Run [45689497228](https://github.com/janahcodes/MinuteTaker-IaC/actions/runs/45689497228) was triggered by a normal `git push` and went from push to a smoke-tested live deploy in **3 min 55 s**:

| Stage | Time |
|---|---|
| Unit tests | api 20 s, worker 29 s (run in parallel) |
| Validation | 36 s |
| `terraform apply` | 35 s, *"No changes. Your infrastructure matches the configuration."* |
| Image builds | 21–34 s each (cached layers; the cold worker build took 84 s) |
| Rollout | 83 s |
| Smoke test | 12 s |

The "No changes" result is evidence that the live environment is exactly what the code describes, with no drift. After the deploy, all three Deployments were running images tagged `077a4bf…`, the commit that was pushed.

## 7. Other results on the live environment

* **End to end.** The 26-second standup recording was transcribed in **0.96–1.02 s** of worker time. It produced 5 action items, for example *"Sarah: Send the revised proposal to the client (due by Friday)"* and *"Mike: Set up the staging environment (due tomorrow)"*.
* **Autoscaling on EKS.** I uploaded 20 recordings at once: all returned `201`, the worker HPA scaled from **1 to 3 pods**, and all 20 were `DONE` within about a minute. After the 180-second stabilization window it scaled back down one pod per minute (3 → 2 → 1), as configured.
* **Per-service least privilege.** From inside a worker pod, AWS identified the caller as `assumed-role/minutetaker-prod-worker/…`, and a DynamoDB `PutItem`, which is outside the worker's policy, was rejected with `AccessDeniedException`. The web pod has no AWS credentials in its environment.
* **Pods can't reach the node's metadata service.** Requesting an IMDSv2 token from inside a pod timed out (hop limit 1), so a compromised container can't borrow the node's role.
* **HA layout.** The two nodes are in different availability zones, and the api and web replicas are spread one per node by the topology spread constraints carried over from Project 2.

## 8. What did not work the first time

1. **CI couldn't assume its AWS role.** The trust policy matched GitHub's documented subject format, `repo:owner/name:ref:…`, and every attempt failed with *"Not authorized to perform sts:AssumeRoleWithWebIdentity"*. Querying the repository's OIDC settings showed that new repositories use GitHub's *immutable* subject format, `repo:janahcodes@260461252/MinuteTaker-IaC@1472254095:…`, which includes the numeric owner and repo IDs. I updated the trust policy to that format. It's also safer: if the repository were deleted and someone recreated it under the same name, it would get a new ID and couldn't assume the role.
2. **The smoke test failed although the site worked.** Two bugs in my script:
   - `curl … | grep -q` under `set -o pipefail`: `grep -q` exits at the first match, curl gets SIGPIPE writing the rest of the page, and pipefail reports the pipeline as failed. Fixed by capturing the page into a variable first.
   - The test looked for "standup", but Whisper transcribed "stand-up". The match is now `stand-?up`, plus a check on the extracted owner.

   The fix was committed and pushed, and that push became the deploy-on-commit run in §6.3. Lesson: test the test, and read the failure before assuming the system is broken.
3. **The first push didn't start the pipeline.** No run was created for the initial push of the new repository. The most likely cause is the `paths-ignore: docs/**` filter: the newest commit in that push only touched `docs/`, and for a brand-new branch GitHub has no earlier commit to compare against. I started the first build manually, and every later push triggered normally.
4. **"This site can't be reached" right after the rebuild.** The site was healthy: both load balancer IPs returned `200`, and public resolvers (8.8.8.8, 1.1.1.1) returned the right address. But a Mac that had looked up the name *during* the teardown had cached the "name does not exist" answer. Negative DNS answers are cached according to the zone's SOA record, up to 15 minutes for Route 53. Flushing the cache (`sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder`) fixed it immediately. For the demo: don't open the URL while the environment is down, or flush DNS after the rebuild. A stable alias that isn't deleted on teardown would avoid the problem, but it would point at nothing while the environment is down.
5. **Approximate queue depth.** During the load test, `/api/stats` sometimes reported 0 waiting messages between readings of 16–17. SQS's `ApproximateNumberOfMessages` is eventually consistent. It's fine for a dashboard but a poor input for scaling decisions, which is another reason to move to KEDA (§10).

## 9. How to run the demonstration
```bash
gh workflow run teardown -f confirm=destroy     # deletes everything, then verifies it's gone
gh workflow run pipeline                        # rebuilds from code, deploys, smoke-tests
gh run watch                                    # follow either one live
```
Locally, the same steps are `make destroy` and `make apply`, followed by a commit, or `make smoke`.

## 10. Cost

While the environment is up (us-east-2 on-demand prices):

| Item | $/hour |
|---|---|
| EKS control plane | 0.100 |
| 2 × m7i-flex.large nodes | ~0.192 |
| Application Load Balancer (idle; LCUs negligible at class scale) | ~0.023 |
| 4 public IPv4 addresses (2 nodes, 2 ALB) | 0.020 |
| 2 × 30 GB gp3 volumes | ~0.007 |
| DynamoDB on-demand, S3, SQS, ECR storage, CloudWatch logs (7-day retention) | < 0.01 at this traffic |
| **Total** | **≈ $0.34/hour ≈ $8/day ≈ $250/month if left running** |

Torn down, the cost is effectively $0: the state bucket is kilobytes, and the hosted zone ($0.50/month) predates this project. This is why the environment is kept down except for demos, and why the pipeline won't recreate it on an ordinary push. The account is on the AWS Free plan, so all of this came out of its credit.

## 11. Limitations and what I would change

* **Private subnets.** Move the nodes behind a NAT gateway or VPC endpoints, and restrict the EKS public API endpoint, at the cost of the NAT gateway and self-hosted runners or a bastion.
* **Faster rebuilds.** The ~12-minute EKS create dominates the rebuild. Keeping the control plane up and tearing down only the node group and app would rebuild in under 5 minutes, but it would no longer be a teardown *from scratch*.
* **Scale on queue depth (KEDA SQS scaler)** instead of CPU, and add **Karpenter** so the HPA's extra pods always have room. With 2 nodes the worker HPA's maximum of 5 can leave pods Pending under heavy load.
* **A staging environment.** `var.environment` already namespaces every resource name, so a `staging` workspace deployed from pull requests is mostly a pipeline change.
* **Manual approval before `apply` on infrastructure changes.** For example, a required reviewer on the `production` environment when the Terraform plan isn't empty.
* Carried over from Project 2: no authentication, DynamoDB `Scan` for search, and uploads that pass through the API instead of presigned URLs.

## 12. Use of AI tools

I used Claude (Anthropic) as an AI pair-programmer for this project.

**What the AI did:**
- Checked the syllabus requirements against my Project 2 repository and pointed out what was missing.
- Proposed the architecture: EKS, a separate bootstrap stack, OIDC instead of keys, Pod Identity, and a Terraform-managed ALB.
- Wrote most of the Terraform, the workflows and the scripts.
- Ran the deployments, teardown and rebuild, and diagnosed the failures in §8.
- Drafted this report.

**What I did:** AI_DISCLOSURE_STUDENT_PART

I reviewed the code and this report, and I can explain how each part works and why it was designed this way.
