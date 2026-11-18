#!/bin/bash
set -e
export PATH=$PATH:/snap/bin

DB_HOST="${1:-172.29.0.3}"
BUCKET="${2:-abe-porto-media-501516}"
DATE=$(date +"%Y-%m-%d_%H-%M")
FILE="/tmp/geneta_db_${DATE}.sql.gz"

export PGPASSWORD=$(gcloud secrets versions access latest --secret="abe-db-password")
pg_dump -h "$DB_HOST" -U geneta_user geneta_db | gzip > "$FILE"
gcloud storage cp "$FILE" "gs://${BUCKET}/backups/geneta_db_${DATE}.sql.gz"
rm -f "$FILE"