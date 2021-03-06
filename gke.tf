variable "gke_username" {
  default     = ""
  description = "gke username"
}

variable "gke_password" {
  default     = ""
  description = "gke password"
}


variable "gke_num_nodes" {
  default     = 1
  description = "number of gke nodes"
}
variable "machineType" {
  default     = "e2-medium"
  description = "sizing of compute node"
}
# local api whitelisting
locals {
cidr_blocks = concat(
  [
  {
    display_name : "GKE Cluster CIDR",
    cidr_block : format("%s/32", "192.168.0.10")
  },
  {
    display_name : "GKE subnet",
    cidr_block : format("%s/32", "192.168.0.12")
  },
  {
    display_name : "home access",
    cidr_block : format("%s/32", "103.149.126.200")
  },
]
)
}

# GKE cluster
resource "google_container_cluster" "primary" {
  name     = "${var.project_id}-gke"
  location = var.region
  # We can't create a cluster with no node pool defined, but we want to only use
  # separately managed node pools. So we create the smallest possible default
  # node pool and immediately delete it.
  remove_default_node_pool = true
  initial_node_count       = 1
  ip_allocation_policy {
  cluster_secondary_range_name  = google_compute_subnetwork.subnet.secondary_ip_range.0.range_name
  services_secondary_range_name = google_compute_subnetwork.subnet.secondary_ip_range.1.range_name
   }
  network    = google_compute_network.vpc.name
  subnetwork = google_compute_subnetwork.subnet.name
  addons_config {
    horizontal_pod_autoscaling {
       disabled  = false
  }
  network_policy_config {
     disabled = false
  }

}
  node_locations = [
    "us-central1-a",
    "us-central1-b",
    "us-central1-c",
  ] 

  workload_identity_config {
    identity_namespace = "${var.project_id}.svc.id.goog"
  }
  network_policy {
      enabled  = true
    }
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "10.10.0.0/28"
  }
  master_authorized_networks_config {
  dynamic "cidr_blocks" {
    for_each = [for cidr_block in local.cidr_blocks: {
      display_name = cidr_block.display_name
      cidr_block = cidr_block.cidr_block
    }]
    content {
      cidr_block = cidr_blocks.value.cidr_block
      display_name = cidr_blocks.value.display_name

    }
  }
}
  cluster_autoscaling {
       enabled = true
       resource_limits {
           minimum       = 1
           maximum       = 2
           resource_type = "cpu"
        }
       resource_limits {
           minimum       = 1
           maximum       = 2
           resource_type = "memory"
        }
    }

}

# Separately Managed Node Pool
resource "google_container_node_pool" "primary_nodes" {
  name       = "${google_container_cluster.primary.name}-node-pool"
  location   = var.region
  cluster    = google_container_cluster.primary.name
  node_count = var.gke_num_nodes

    autoscaling {
      min_node_count  = 2
      max_node_count  = 10
    }
  node_config {
    oauth_scopes = [
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
    ]

    labels = {
      confidentiality = "C2"
      managed_by      = "vijay"
      environment     = "dev"
    }
    workload_metadata_config {
      node_metadata = "GKE_METADATA_SERVER"
    }
    # preemptible  = true
    machine_type = var.machineType
    tags         = ["gke-node", "${var.project_id}-gke"]
    metadata = {
      disable-legacy-endpoints = "true"
    }
  }
}


# # Kubernetes provider
# # The Terraform Kubernetes Provider configuration below is used as a learning reference only. 
# # It references the variables and resources provisioned in this file. 
# # We recommend you put this in another file -- so you can have a more modular configuration.
# # https://learn.hashicorp.com/terraform/kubernetes/provision-gke-cluster#optional-configure-terraform-kubernetes-provider
# # To learn how to schedule deployments and services using the provider, go here: https://learn.hashicorp.com/tutorials/terraform/kubernetes-provider.

data "google_client_config" "default" {
  depends_on = [ google_container_cluster.primary ]
}
data "google_container_cluster" "primary" {
  name     = "${var.project_id}-gke"
  location = var.region
  depends_on = [
    google_container_node_pool.primary_nodes,
    google_container_cluster.primary
  ]
}

provider "kubernetes" {
  host                   = "https://${data.google_container_cluster.primary.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(data.google_container_cluster.primary.master_auth[0].cluster_ca_certificate)
}

provider "helm" {
  kubernetes {
  host                   = "https://${data.google_container_cluster.primary.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(data.google_container_cluster.primary.master_auth[0].cluster_ca_certificate)
  }
}
