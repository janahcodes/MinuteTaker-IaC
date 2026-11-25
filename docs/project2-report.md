# MinuteTaker: Project 2 Report
### Containerized Multi-Service Application (AI 255, Cloud Computing Concepts)

## 1. What the system does

MinuteTaker turns meeting recordings into searchable minutes. A user uploads a
recording (or records one in the browser) and a few seconds later gets a
timestamped transcript and a list of **action items** with the owner and due
date if there's any.
Every transcript is full-text searchable.

The target users are small teams that record calls but never write minutes,
such as agencies, clinics and consultancies. The transcription runs on our own
containers instead of a paid speech API, so recordings never leave the
deployment. For those clients that is a privacy selling point.

Features:

* **Meeting or lecture mode.** Meetings open on their action items. Lectures
  open on the transcript and get a **Turn into notes** button, which downloads a
  formatted notes page: summary, key terms, definitions and condensed points per
  section, with timestamps. The notes are selected and condensed, not word for
  word (`services/api/app/notes.py`).
* **Deadlines go on the calendar.** The worker turns "by Friday", "tomorrow",
  "end of week" or "Nov 20" into a real date, relative to the day of the
  recording, plus a short task title ("Send the revised proposal to the
  client"). Each deadline has an **Add to calendar + reminder** button. It
  downloads an `.ics` event with reminders at 9 AM the day before and 9 AM on
  the day, which works with Apple Calendar, Outlook and Google. There is also a
  **Google Calendar** link and an **Add all deadlines** button.
* **Recording calls.** **Record a call** captures the audio of a Google Meet,
  Teams or Zoom-web tab (Chrome's "Share tab audio") mixed with the user's
  microphone. It is transcribed when the call ends. A bot that joins meetings by
  itself would need each platform's meeting SDK and app approval, so it is
  out of scope.
  
  
## 2. Architecture

```
            browser
               │  HTTP :80 (LoadBalancer / NodePort)
       ┌───────▼────────┐
       │  web  (nginx)  │  ×2–4   static UI, reverse proxy for /api
       └───────┬────────┘
               │  ClusterIP Service "api"
       ┌───────▼────────┐      put/get/scan       ┌────────────────────┐
       │  api (FastAPI) │  ×2–6 ────────────────▶ │ DynamoDB  meetings │
       └──┬──────────┬──┘                          └────────▲───────────┘
   upload │          │ SendMessage(meeting id)               │ update result
          ▼          ▼                                       │
   ┌──────────┐  ┌─────────────────┐  ReceiveMessage  ┌──────┴──────────────┐
   │ S3 audio │  │ SQS jobs (+DLQ) │ ───────────────▶ │ worker (Whisper)    │ ×1–5
   └────▲─────┘  └─────────────────┘                  └──────┬──────────────┘
        └──────────────── GetObject ─────────────────────────┘
```

| Component | Kind | Image / service | Role |
|---|---|---|---|
| **web** | stateless service | `minutetaker-web` (nginx-unprivileged 1.27) | Serves the single-page UI, proxies `/api/*` to the API, health endpoint `/healthz` |
| **api** | stateless service | `minutetaker-api` (Python 3.12, FastAPI) | Validates uploads, writes audio to S3 and a record to DynamoDB, queues a job on SQS; read/search/delete endpoints |
| **worker** | stateless consumer | `minutetaker-worker` (Python 3.12, faster-whisper `tiny.en`, int8) | Long-polls SQS, transcribes, extracts action items, writes results back |
| DynamoDB | managed NoSQL | table `minutetaker-meetings` | System of record for meetings and transcripts |
| S3 | managed object store | bucket `minutetaker-audio` | Raw recordings |
| SQS | managed queue | `minutetaker-jobs` + `minutetaker-jobs-dlq` | Decouples upload from transcription; buffers bursts |

### Why three services and a queue
Transcribing takes seconds to minutes of full CPU, while serving the UI and API
takes milliseconds. If they ran in one process, a burst of uploads would starve
the web requests. Splitting them lets each tier **scale on its own signal**.
The queue also means an upload succeeds even when every worker is busy or down;
the work simply waits.

### Meeting lifecycle (state machine in DynamoDB)
`UPLOADING → UPLOADED → QUEUED → PROCESSING → DONE`, with `FAILED` reachable
from `PROCESSING`. `POST /api/meetings/{id}/retry` moves `UPLOADED|FAILED`
back to `QUEUED`. Each step is written *before* the next side effect, so a
crash at any point leaves a visible, recoverable state rather than a silent gap.

## 3. Containerization

* **Small, layered images.** Dependencies are installed before the code is copied,
  so editing code only rebuilds the last layer. `.dockerignore` keeps tests and
  virtualenvs out.
* **Non-root.** API and worker run as uid 10001. The web tier uses
  `nginx-unprivileged` (uid 101, port 8080). In Kubernetes all containers drop
  every Linux capability, disallow privilege escalation and use the
  `RuntimeDefault` seccomp profile. API and worker also have a read-only root
  filesystem with an `emptyDir` at `/tmp`.
* **Model baked into the image.** The Whisper weights (~75 MB) are downloaded at
  build time and `HF_HUB_OFFLINE=1` is set at runtime. A new worker pod
  therefore starts without depending on Hugging Face, and every replica runs
  identical weights.
* **Docker `HEALTHCHECK`s** mirror the Kubernetes probes so `docker compose ps`
  shows health too.
* **Same image everywhere.** Configuration comes only from environment variables
  (`TABLE_NAME`, `BUCKET_NAME`, `QUEUE_URL`, optional `AWS_ENDPOINT_URL`). The
  identical image talks to the local emulator or to real AWS.

## 4. Orchestration: health checks and horizontal scaling

All of this is in `k8s/base`, with environment differences in overlays
(`k8s/overlays/local`).

### Probes

| Service | startup | liveness | readiness |
|---|---|---|---|
| web | none | `GET /healthz` (nginx returns 200, no upstream) | same |
| api | `/healthz` up to 60 s | `/healthz`: process answers; **no dependency check** | `/readyz`: `DescribeTable` on DynamoDB must succeed |
| worker | `/healthz` up to 120 s (model load) | `/healthz`: the poll loop has ticked in the last `STALL_AFTER_S` (300 s) | `/readyz`: model loaded **and** loop alive |

The split between liveness and readiness is deliberate. If DynamoDB has an
outage, every API pod fails readiness. It is taken out of the Service so it
stops receiving traffic, but it is not restarted. Restarting cannot fix
a downstream outage and would only add a restart storm on top of it. The
worker's liveness probe catches the failure a process check would miss: a
worker that is running but stuck, stops sending heartbeats and gets restarted.

### Horizontal scaling

| Deployment | min | max | metric | notes |
|---|---|---|---|---|
| web | 2 | 4 | CPU 70 % | 2 minimum for availability |
| api | 2 | 6 | CPU 60 % | rolling updates with `maxUnavailable: 0` |
| worker | 1 | 5 | CPU 60 % of 500 m request | scale up 2 pods / 30 s; scale down 1 pod / 60 s after a 180 s stabilization window |

The worker scales on CPU because transcription is CPU-bound. An idle worker
long-polling SQS uses close to 0 % CPU, while a busy one uses about 200 % of its
request. CPU is therefore a good proxy for "is there a backlog". The ideal
signal is queue depth (see §7). The slow scale-down avoids killing workers
in the short gaps between jobs.

Other availability settings: `topologySpreadConstraints` spread replicas across
nodes; `PodDisruptionBudget`s keep at least one web and one api pod through
voluntary disruptions such as node drains and upgrades.

## 5. Failure-mode analysis

For each component: what can fail, how the failure shows up, what limits the
damage, and what the user sees. "Tested" marks failures that were injected on
the running system.

### 5.1 web (nginx)

| Failure | Detection | Mitigation | User impact |
|---|---|---|---|
| A web pod crashes or its node dies | liveness probe / node NotReady | Service stops routing to it; ReplicaSet replaces it; a 2nd replica on another node keeps serving | None, or one failed request at most |
| nginx can't resolve `api` at start (Service missing) | container exits → CrashLoopBackOff | Manifests are applied together; the pod restarts until DNS resolves | UI unavailable until resolved |
| An API pod refuses or resets a connection | nginx upstream error | `proxy_next_upstream error timeout http_502 http_503` retries once on another pod | Transparent |
| Every API pod is unready | nginx gets 503 / 502 | UI shows "Couldn't load meetings" and keeps polling | Read-only failure; recovers by itself |
| Oversized upload | `client_max_body_size 50m` | Rejected at the edge before it reaches the API | Clear 413 error |

The web tier holds no state, so every failure is fixed by replacement.

### 5.2 api (FastAPI)

| Failure | Detection | Mitigation | User impact |
|---|---|---|---|
| Pod crash / OOM (e.g. many concurrent large uploads) | liveness, container exit code | Restart; other replicas serve; uploads spool to `/tmp` (on disk, not in memory), memory limit 320 Mi | In-flight upload on that pod fails; the user retries |
| DynamoDB unavailable or throttling | boto timeouts (connect 2 s, read 5 s, 3 attempts) → **503**; readiness fails | Pods leave the Service but are **not** restarted; boto retries with backoff | "A backing service is unavailable" (tested) |
| S3 upload fails after the meeting record was written | exception → 503 | Record stays `UPLOADING`, visible in the list | User sees a stuck "Uploading" entry and can delete it (known gap, see §7) |
| SQS `SendMessage` fails after the audio is stored | exception → 503 | Record stays `UPLOADED`; the UI offers **"Queue it"** → `/retry` | One click to recover; no audio lost |
| CPU saturation under traffic | HPA | Scale out to 6 | Higher latency during the scale-out |
| Bad input (wrong type, empty, path tricks, malformed IDs) | validation | 415 / 400 / 404; filenames sanitized; IDs must match `[0-9a-f]{12}` | Clear error |

The write order (DynamoDB → S3 → DynamoDB → SQS → DynamoDB) is the important
design choice. The system **never** has audio in S3 without a record pointing
to it, and never queues a job whose audio isn't stored yet.

### 5.3 worker (transcription)

The worker has the most failure modes, because it does long-running work
that has side effects.

| Failure | Detection | Mitigation | User impact |
|---|---|---|---|
| Pod killed mid-job (crash, OOM, node loss, eviction) | message never deleted | The visibility heartbeat stops, so the message reappears after ≤ 120 s and another worker picks it up | Job finishes a couple of minutes late (tested) |
| Scale-in or rolling update while busy | SIGTERM | Stops taking new jobs and finishes the current one within `terminationGracePeriodSeconds: 90`; if it runs longer, as above | None |
| The same message delivered twice (SQS standard queues are at-least-once) | conditional `UpdateItem` on `status <> DONE` | Duplicate is acknowledged and dropped; a result is written once | None (unit-tested) |
| Meeting deleted while queued | conditional check fails (`id` missing) | Message dropped | None |
| Corrupt / undecodable audio, or longer than 45 min | `PermanentError` | Marked `FAILED` with a reason **immediately**; no retries wasted | Clear error message with a retry button |
| Audio object missing in S3 | `NoSuchKey` → `PermanentError` | `FAILED: Audio file is missing` | Clear error |
| Transient error (S3/DynamoDB blip, unexpected exception) | exception | Status back to `QUEUED` with the reason; message hidden for 30 s, 60 s, 120 s… (exponential backoff); after `MAX_RECEIVES` (3) attempts → `FAILED` | Delayed, then either succeeds or fails clearly |
| Poison message that crashes the process before it can record a failure | receive count grows | Queue redrive policy moves it to the **DLQ** after 5 receives, so it can't block the queue forever | That meeting stays `PROCESSING`; an operator inspects the DLQ |
| Worker hangs (stuck decode, deadlock) | heartbeat older than 300 s → liveness fails | kubelet restarts the container; message redelivered | Delay |
| Transcript too big for one DynamoDB item (400 KB) | size check before write | Drop per-segment timestamps first, then truncate the text | Very long meetings lose timestamps |
| Backlog (many uploads at once) | CPU → HPA | Scale out to 5 workers; SQS holds the rest durably | Longer waits, nothing lost (tested) |
| A job never finishes because it is longer than the visibility timeout | n/a | Heartbeat extends visibility every 60 s while the job runs | None |

### 5.4 Managed datastore and queue

| Failure | Effect | Mitigation |
|---|---|---|
| DynamoDB regional outage / throttling | API reads and writes return 503; workers back off and retry | Pay-per-request mode (no capacity to exhaust at our scale); point-in-time recovery enabled in the Terraform (`infra/data.tf`) |
| S3 unavailable | Uploads fail with 503; workers retry with backoff | S3's 11-nines durability: once stored, audio isn't lost |
| SQS unavailable | New uploads stay `UPLOADED` (recoverable with `/retry`); workers log and back off for 5 s | Messages already queued are kept durably |
| Local only: moto pod restarts | Emulator data is in memory and is lost | Local development only; the real services are durable |

### 5.5 Platform-level failures

| Failure | Effect | Mitigation |
|---|---|---|
| A node dies | Its pods are rescheduled after the node is marked NotReady (~40 s + eviction) | Replicas spread across nodes; web and api keep ≥ 1 replica elsewhere; worker jobs are redelivered |
| Bad deploy (new image crashes) | New pods never become Ready | `maxUnavailable: 0` means old pods keep serving; `kubectl rollout undo` |
| metrics-server down | HPAs can't read metrics and **freeze at the current replica count** | Minimum replicas still keep the system available, just not elastic |
| Cluster out of capacity | New pods stay `Pending` | Requests are sized so max replicas fit the cluster; node autoscaling is future work (§7) |

## 6. Results

All results below come from the system running on a local 3-node Kubernetes
cluster (kind: 1 control plane + 2 workers, on an Apple-silicon Mac).
The scaling and failure-injection runs (§6.2–6.3) used moto to emulate
DynamoDB, S3 and SQS. The final deployment uses the **real managed services in
AWS us-east-2**, created with Terraform (§6.6).

### 6.1 End-to-end transcription
A 25.7-second test recording of a staged stand-up meeting was transcribed in
**4.5 s** by one worker (about 5.7× faster than real time on one CPU core). The
transcript was word-for-word correct. All five spoken tasks were found as action
items, with the owner and due date where they were said:

| Action item | Owner | Due |
|---|---|---|
| Sarah, can you send the revised proposal to the client by Friday? | Sarah | by Friday |
| I'll also update the budget sheet before the review. | Speaker | – |
| We need to finalize the hiring plan before next Monday. | – | before next Monday |
| Mike will set up the staging environment tomorrow. | Mike | tomorrow |
| Let's make sure the contract is signed by end of week. | – | by end of week |

(The "Mike will…" item was missed on the first run. I fixed the rule and added a
regression test.)

### 6.2 Horizontal scaling under load
`scripts/loadtest.sh 30` uploaded 30 recordings at once. The upload API
answered `201` to all 30 immediately; the jobs waited in SQS.

| Time after load | Event (from `kubectl describe hpa worker`) |
|---|---|
| ~15 s | worker CPU above 60 % target → **1 → 2** pods |
| ~30 s | → **3** pods |
| ~45 s | → **4** pods |
| ~60 s | → **5** pods (max), spread across both worker nodes |
| ~85 s | queue empty: 31/31 meetings `DONE`, 0 failures |
| ~4 min | first scale-in (5 → 4) after the 180 s stabilization window |

The scale-up rate (2 pods per 30 s) and the delayed scale-down behaved exactly as
configured. API and web stayed at their 2-replica minimum the whole time
(API CPU ~18 %). This is the point of splitting the services: the heavy tier
scaled and the light tiers didn't have to.

### 6.3 Failure injection: worker killed mid-job
I uploaded a 111-second recording, waited until a worker had claimed it, and
force-deleted that pod (`kubectl delete pod --grace-period=0 --force`, which
behaves like a crash).

* The job was not lost. The dead pod never deleted the SQS message, so the
  message became visible again when the 120 s visibility timeout ran out.
* A different worker picked it up and finished it (`attempts = 2`). The
  meeting went `PROCESSING → DONE` with no manual step.
* The cost was latency: about 3 min 45 s end-to-end instead of about 1 min 50 s.
  A shorter visibility timeout would recover faster, but would risk duplicate
  work when a heartbeat is late. 120 s with a 60 s heartbeat is the trade-off I chose.

### 6.4 Failure injection: datastore unreachable (tests)
`test_dependency_outage_returns_503` deletes the DynamoDB table under a running
API. The API returns `503` with a friendly message, `/readyz` fails, and
`/healthz` stays `200`, so Kubernetes would stop routing to the pod without
restarting it. `test_run_loop_survives_unreachable_aws` checks that the worker
backs off instead of crashing when AWS cannot be reached.

### 6.5 What did not work the first time 
These were all the bugs, found by deploying and testing, and fixed:

1. **`segments` is a DynamoDB reserved word.** Saving results failed until I
   aliased it with `ExpressionAttributeNames` (caught by a unit test).
2. **The regex `we'?ll` matched the word "well"**, producing false action items.
   The apostrophe is now required.
3. **The moto pod crash-looped in Kubernetes.** Kubernetes injects a
   `MOTO_PORT=tcp://10.96…:5000` environment variable into every pod for the
   Service named `moto`, and moto reads `MOTO_PORT` as its own port setting.
   I fixed it with `enableServiceLinks: false`. It's a good example of a
   platform behaviour that never appears in Docker Compose.
4. **The worker crashed when the queue was unreachable** instead of backing
   off. Connection errors raise `BotoCoreError`, not `ClientError`. This was
   exactly the failure mode §5.3 claimed to handle, so I fixed it and added a test.
5. **Dependency drift broke transcription.** `faster-whisper` calls
   `av.open(metadata_errors=…)`, which PyAV 19 removed, so every file failed
   with "Could not decode audio". I pinned `av==18.1.0`. The worker classed this as a
   permanent error (bad input), which was the wrong call: it was a code bug,
   and those jobs had to be retried by hand once the fix was deployed. A
   stricter split between "the file is bad" and "our decoder is broken" would
   be better.
6. **The Docker image build needed `requests`**, which newer `huggingface_hub`
   no longer installs. I pinned it explicitly.
7. **A real cascading failure in the API tier.** Redeploying all three services
   at once while a worker was transcribing pushed the cluster to ~250 % CPU.
   Each API pod ran two uvicorn processes under a 0.5 CPU limit. When the
   pods were slow, uvicorn's supervisor killed and restarted its own child
   processes, and the 1 s default liveness timeout made the kubelet restart
   whole pods. Restarting Python is CPU-heavy, so the pods never caught up.
   Meanwhile the HPA read the high CPU as load and scaled the API to its max
   of 6, adding even more startup work. 0 of 6 API pods were Ready and the
   site returned errors until I fixed it:
   * one uvicorn process per pod (Kubernetes already does the scaling);
   * a 5 s timeout on the liveness probes.
   After redeploying, 6/6 pods were Ready within a minute.

   Lessons: (a) don't stack a second process supervisor inside a
   CPU-limited pod; (b) a liveness probe must tolerate a slow-but-healthy
   process, or it turns overload into an outage; (c) CPU-based autoscaling
   can amplify a startup storm, which is another reason to scale on queue depth
   or request rate (§7).
8. `kind load` can fail silently under load. After a fix, the workers
   kept running the old image because loading the image into the nodes had
   failed while the cluster was saturated. I only caught it because the output
   didn't change, and confirmed it by comparing image IDs on the nodes. The fix
   is to tag every build uniquely (a git SHA) instead of reusing `:dev`, so a
   stale image can't pass for a new one. Project 3's pipeline should do this.

### 6.6 Managed services on AWS, and the "blocked account" that wasn't
At first every AWS call except S3 failed with *"explicit deny in a service
control policy"*, so the system was built and tested against moto. The real
cause was that my AWS project (created through AWS's newer "projects" console)
is **restricted to one region, US East (Ohio) `us-east-2`**, and my CLI and
Terraform defaulted to `us-east-1`. A second mistake hid this for a while: my
permission-check loop ran in zsh, which doesn't word-split `$var`, so every
looped call was malformed and failed regardless of permissions. Lesson: check
the account's allowed regions first, and verify a diagnostic before trusting it.

With the region fixed, `terraform apply` created 16 resources in under a
minute: the DynamoDB table (on-demand, encrypted, point-in-time recovery), the
S3 bucket (private, encrypted, 30-day expiry), the SQS queue and dead-letter
queue, three ECR repositories (immutable tags, scan on push), and a
least-privilege IAM user scoped to exactly those three data resources.
`scripts/use-real-aws.sh` switches the cluster from moto to these via the
`k8s/overlays/aws` overlay; **no application code changed**, only configuration.

Verified end to end: an upload through the UI was written to DynamoDB, its
audio stored in S3, the job carried by SQS, transcribed in 5.5 s, and the queue
drained, all checked directly with the AWS CLI. Images are in **ECR**
(`439093223948.dkr.ecr.us-east-2.amazonaws.com/minutetaker-{api,web,worker}`,
tagged with the git commit) and also public on **GHCR**.

The orchestrator is still a local kind cluster rather than EKS. EKS would
add about $0.10/hour for the control plane plus nodes. Moving to it is a change
of overlay (image names from ECR, EKS Pod Identity instead of the IAM user's
key) and is planned for Project 3, which must rebuild the environment from code.

### 6.7 How to reproduce
```bash
scripts/local-up.sh                 # build, create 3-node kind cluster, deploy
scripts/loadtest.sh 20              # 20 uploads → backlog
kubectl -n minutetaker get hpa,pods -w
```

## 7. Limitations and what I would change

* **Scale workers on queue depth, not CPU.** CPU is a lagging proxy. KEDA's SQS
  scaler would scale on `ApproximateNumberOfMessages` and could scale to zero
  when idle. I left it out to keep the stack to core Kubernetes.
* **Search uses a DynamoDB `Scan`.** It is fine for hundreds of meetings but
  O(n) in cost and latency. A GSI on `created_at` for listing, plus
  OpenSearch for full-text search, is the production design.
* **Uploads pass through the API.** This is simple and works the same locally
  and on AWS, but it ties up API pods for large files. Presigned S3 PUT URLs
  would let browsers upload directly to S3.
* **No authentication.** Every visitor sees every meeting. This is the first
  feature a real client would need (Cognito, plus a `owner_id` on each
  item).
* **Stuck `UPLOADING` records** when the S3 write fails. A small reaper could
  mark records older than 10 minutes as `FAILED`.
* **Action-item extraction is rule-based.** It is predictable and free, but it
  misses indirect phrasing. An LLM pass would be more accurate at a per-call cost.
* **Node autoscaling** (Cluster Autoscaler / Karpenter) so the HPA's extra pods
  always have room.

## 8. Use of AI tools

Use of AI tools: I used Claude as an AI pair-programmer throughout this project.

What the AI did: brainstormed application ideas and proposed the architecture (three services, SQS queue, DynamoDB/S3, Kubernetes with probes and HPAs). It wrote most of the code, tests, Dockerfiles, Kubernetes manifests and Terraform. It ran the builds, deployments, load tests and failure-injection tests, diagnosed the bugs listed in §6.5, and drafted this report.

What I did: chose a client-facing product direction and the final concept, and directed the design. I defined the features beyond the base build: calendar reminders for deadlines, lecture mode with downloadable notes, search results under the search bar, and recording calls. I tested the application and reported problems (for example the failed upload that exposed the emulator out-of-memory crash), set up the GitHub repository, pushed the code and published the container images.

I reviewed the code and the report, and I can explain how each part works and why it was designed that way.
