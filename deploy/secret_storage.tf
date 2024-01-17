### docker cred to simple app:
data "vault_generic_secret" "registry" {
  path = "ixsa/infrastructure/harbor/projects/ixsa_net/read"
}


