terraform {
  backend "s3" {
    bucket  = "terraform-state-infr"
    key     = "k8s-ixsa-cluster/web_ixsa_net/terraform.tfstate"
    region  = "eu-west-1"
    encrypt = true
  }
}

resource "helm_release" "web-ixsa-net" {
  name       = "web-ixsa-net"
  repository = "https://sortns.github.io/helm/"
  chart      = "simple-app"
  # chart            = "./helm/simple-app"
  version          = "0.0.8"
  namespace        = "ixsa"
  create_namespace = true
  cleanup_on_fail  = true
  max_history      = 10

  values = [templatefile("configs/web-app-values.yaml", {
    docker-registry-cred = data.vault_generic_secret.registry.data["dockerconfigjson"]
  })]
}
