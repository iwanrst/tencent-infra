# terraform init -backend-config=backend.hcl
#
# Production state lives in its own bucket with its own CAM policy, so a
# credential scoped to staging cannot read or corrupt prod state.
bucket = "acme-tfstate-prod-1250000000"
region = "ap-singapore"
prefix = "platform/prod"
key    = "terraform.tfstate"

encrypt = true
acl     = "private"
