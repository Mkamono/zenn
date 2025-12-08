resource "google_sql_database_instance" "public" {
  name   = "public-instance"
  region = local.region

  database_version = "POSTGRES_17"

  settings {
    tier    = "db-f1-micro"
    edition = "ENTERPRISE"
    final_backup_config {
      enabled = false
    }
  }

  deletion_protection = false
}
