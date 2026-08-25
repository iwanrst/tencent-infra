# terraform init -backend-config=backend.hcl
#
# Create the bucket once, out of band, with versioning enabled -- state history
# is the only way back from a bad apply. Restrict it to the platform CAM role.
bucket = "acme-tfstate-staging-1250000000"
region = "ap-singapore"
prefix = "platform/staging"
key    = "terraform.tfstate"

encrypt = true
acl     = "private"
