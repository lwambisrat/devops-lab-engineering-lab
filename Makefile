# Assignment 2 helper targets.
#
# Usage:
#   make up NAME=lwam
#   make verify NAME=lwam
#   make destroy NAME=lwam

TF_DIR          := terraform
EVIDENCE_DIR    := evidence
STATE_BUCKET    := regional-health-tfstate
LOCK_TABLE      := regional-health-tflock
REGION          := us-east-1
LOCALSTACK_URL  := http://localhost:4566

export AWS_ACCESS_KEY_ID         ?= test
export AWS_SECRET_ACCESS_KEY     ?= test
export AWS_DEFAULT_REGION        ?= $(REGION)
export AWS_EC2_METADATA_DISABLED ?= true

.PHONY: up verify destroy bootstrap _check-name _tf-init

_check-name:
ifndef NAME
	$(error NAME is not set. Usage: make up NAME=lwam)
endif
	@test -f $(TF_DIR)/$(NAME).tfvars || \
	  (echo "!! $(TF_DIR)/$(NAME).tfvars not found. Copy terraform/environments/$(NAME).tfvars.example to terraform/$(NAME).tfvars first." && exit 1)

bootstrap:
	@./bootstrap/bootstrap.sh

_tf-init: _check-name bootstrap
	cd $(TF_DIR) && terraform init -reconfigure \
	  -backend-config="bucket=$(STATE_BUCKET)" \
	  -backend-config="dynamodb_table=$(LOCK_TABLE)" \
	  -backend-config="region=$(REGION)" \
	  -backend-config="key=rh/$(NAME)/terraform.tfstate" \
	  -backend-config='endpoints={s3="$(LOCALSTACK_URL)",dynamodb="$(LOCALSTACK_URL)"}' \
	  -backend-config="skip_credentials_validation=true" \
	  -backend-config="skip_metadata_api_check=true" \
	  -backend-config="skip_region_validation=true" \
	  -backend-config="skip_requesting_account_id=true" \
	  -backend-config="use_path_style=true"

up: _tf-init
	@mkdir -p $(EVIDENCE_DIR)/01-iac
	cd $(TF_DIR) && terraform apply -auto-approve -var-file=$(NAME).tfvars 2>&1 \
	  | tee ../$(EVIDENCE_DIR)/01-iac/apply.log
	@cd $(TF_DIR) && terraform plan -var-file=$(NAME).tfvars -detailed-exitcode \
	  > ../$(EVIDENCE_DIR)/01-iac/plan-after-apply.txt 2>&1; \
	  code=$$?; \
	  if [ $$code -eq 2 ]; then \
	    echo "!! Post-apply plan is not empty"; \
	    exit 1; \
	  elif [ $$code -eq 1 ]; then \
	    echo "!! terraform plan errored"; \
	    exit 1; \
	  fi
	@cd $(TF_DIR) && terraform output

verify: _check-name
	@fail=0; \
	echo "-- terraform plan is empty --"; \
	cd $(TF_DIR) && terraform plan -var-file=$(NAME).tfvars -detailed-exitcode > /tmp/verify-plan.txt 2>&1; \
	code=$$?; \
	if [ $$code -eq 0 ]; then \
	  echo "PASS: plan is empty"; \
	elif [ $$code -eq 2 ]; then \
	  echo "FAIL: plan is not empty"; cat /tmp/verify-plan.txt; fail=1; \
	else \
	  echo "FAIL: terraform plan errored"; cat /tmp/verify-plan.txt; fail=1; \
	fi; \
	echo "-- app health --"; \
	app_url=$$(cd $(TF_DIR) && terraform output -raw app_url 2>/dev/null || true); \
	if [ -z "$$app_url" ]; then \
	  echo "FAIL: terraform output app_url is empty"; fail=1; \
	else \
	  curl -fsS "$$app_url/healthz" >/dev/null || { echo "FAIL: /healthz"; fail=1; }; \
	  curl -fsS "$$app_url/readyz" >/dev/null || { echo "FAIL: /readyz"; fail=1; }; \
	  curl -fsS "$$app_url/debug/secret-source" | grep -q "arn" || { echo "FAIL: secret source"; fail=1; }; \
	fi; \
	echo "-- gitleaks --"; \
	if command -v gitleaks >/dev/null 2>&1; then \
	  gitleaks detect --source=. --no-git -v || { echo "FAIL: gitleaks"; fail=1; }; \
	else \
	  echo "SKIP: gitleaks not installed locally; CI must run it"; \
	fi; \
	if [ $$fail -ne 0 ]; then \
	  echo ">> make verify: FAILED"; exit 1; \
	fi; \
	echo ">> make verify: ALL CHECKS PASSED"

destroy: _tf-init
	@mkdir -p $(EVIDENCE_DIR)/01-iac
	cd $(TF_DIR) && terraform destroy -auto-approve -var-file=$(NAME).tfvars 2>&1 \
	  | tee ../$(EVIDENCE_DIR)/01-iac/destroy.log
