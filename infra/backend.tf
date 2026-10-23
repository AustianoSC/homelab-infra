terraform {
  backend "s3" {
    bucket       = "lab-terratofu-state"
    key          = "infra/terraform.tfstate"
    region       = "us-west-2"
    use_lockfile = true
  }
}
