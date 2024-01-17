provider "helm" {
  kubernetes {
    config_path = var.K8S_CONFIG
  }
}
provider "vault" {
  address          = var.VAULT_HOST
  skip_child_token = true
}