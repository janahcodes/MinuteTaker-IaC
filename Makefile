.PHONY: test lint bootstrap plan apply kubeconfig smoke destroy verify-teardown up down load compose
TF := terraform -chdir=infra/live

test:      ## run both test suites
	cd services/api && ../../.venv/bin/pytest -q
	cd services/worker && ../../.venv/bin/pytest -q

lint:      ## the same static checks the pipeline runs
	terraform fmt -check -recursive infra
	terraform -chdir=infra/live init -backend=false -input=false >/dev/null && terraform -chdir=infra/live test
	shellcheck scripts/*.sh
	actionlint
	for o in eks local; do kubectl kustomize k8s/overlays/$$o | kubeconform -strict -summary -kubernetes-version 1.35.0; done

# ---- cloud environment (normally driven by GitHub Actions) ----
bootstrap: ## one-time: Terraform state bucket + GitHub OIDC role
	terraform -chdir=infra/bootstrap init && terraform -chdir=infra/bootstrap apply

plan:
	$(TF) init -input=false && $(TF) plan

apply:     ## create / update the whole environment from code
	$(TF) init -input=false && $(TF) apply

kubeconfig:
	aws eks update-kubeconfig --region us-east-2 --name minutetaker-prod

smoke:     ## end-to-end test against the live URL
	scripts/smoke-test.sh "$$($(TF) output -raw app_url)"

destroy:   ## tear the whole environment down, then prove it's gone
	$(TF) destroy && scripts/verify-teardown.sh

verify-teardown:
	scripts/verify-teardown.sh

# ---- local development (unchanged from Project 2) ----
up:        ## build + deploy to a local 3-node kind cluster with emulated AWS
	scripts/local-up.sh
down:
	scripts/local-down.sh
load:      ## 20 uploads to trigger worker autoscaling (pass URL=... for the cloud)
	scripts/loadtest.sh 20 samples/standup.wav $(or $(URL),http://localhost:8080)
compose:   ## run without Kubernetes
	docker compose up --build
