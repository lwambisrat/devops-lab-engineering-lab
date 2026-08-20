#!/usr/bin/env bash
# =============================================================================
# data-seed/migrate-aiven.sh
# -----------------------------------------------------------------------------
# Seeds the REAL Aiven MySQL database (not the docker-compose one — see
# seed.sh for that) with the same schema/data shape used in A1, sized to
# match ASSIGNMENT-A2.md C2 (10,000 patients, not the 100k left over from
# the original script's default).
#
# Credentials are NOT re-typed here. This script reads them straight out of
# Secrets Manager — the same source of truth the app itself uses (see
# api/secrets.js) — instead of keeping a second copy in this script or a
# config file that could quietly drift out of sync with what Terraform
# actually wrote.
#
# Requires: aws CLI (pointed at LocalStack), mysql client, jq.
#
# Usage:
#   ./data-seed/migrate-aiven.sh lwam
#   ROW_COUNT=5000 ./data-seed/migrate-aiven.sh lwam
# =============================================================================
set -euo pipefail

NAME="${1:-}"
if [ -z "$NAME" ]; then
  echo "!! Usage: $0 <your-name>   (e.g. $0 lwam — matches your secret_name)" >&2
  exit 1
fi

ROW_COUNT="${ROW_COUNT:-10000}"
SECRET_ID="regional-health/${NAME}/db"
AWS_ENDPOINT_URL="${AWS_ENDPOINT_URL:-http://localhost:4566}"
EVIDENCE_DIR="evidence/02-data"

export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

mkdir -p "$EVIDENCE_DIR"
SEED_LOG="${EVIDENCE_DIR}/seed.log"
ROW_COUNTS_FILE="${EVIDENCE_DIR}/row-counts.txt"

echo ">> Reading credentials for '${SECRET_ID}' from Secrets Manager..." | tee "$SEED_LOG"

SECRET_JSON=$(aws --endpoint-url="$AWS_ENDPOINT_URL" secretsmanager get-secret-value \
  --secret-id "$SECRET_ID" --query SecretString --output text)

DB_HOST=$(echo "$SECRET_JSON" | jq -r '.host')
DB_PORT=$(echo "$SECRET_JSON" | jq -r '.port')
DB_USER=$(echo "$SECRET_JSON" | jq -r '.username')
DB_PASS=$(echo "$SECRET_JSON" | jq -r '.password')
DB_NAME=$(echo "$SECRET_JSON" | jq -r '.dbname')

# CA cert has to land in a real file for the mysql client's --ssl-ca flag —
# it can't take the certificate content inline. Written to a temp file that
# gets cleaned up whether this script succeeds or fails (the trap).
CA_FILE=$(mktemp)
trap 'rm -f "$CA_FILE"' EXIT
echo "$SECRET_JSON" | jq -r '.ca_cert' > "$CA_FILE"

echo ">> Target: ${DB_HOST}:${DB_PORT}/${DB_NAME} (TLS required — Aiven rejects plaintext connections)" | tee -a "$SEED_LOG"

MYSQL=(mysql --ssl-mode=REQUIRED --ssl-ca="$CA_FILE" \
  -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" "-p${DB_PASS}")

echo ">> Waiting for the database to accept connections..." | tee -a "$SEED_LOG"
until "${MYSQL[@]}" -e "SELECT 1" >/dev/null 2>&1; do
  echo "   ...still waiting (Aiven free-tier services sleep when idle, this can take ~30s to wake)" | tee -a "$SEED_LOG"
  sleep 3
done
echo ">> Database is reachable." | tee -a "$SEED_LOG"

echo ">> Creating schema and loading ${ROW_COUNT} patient rows..." | tee -a "$SEED_LOG"
"${MYSQL[@]}" 2>&1 <<SQL | tee -a "$SEED_LOG"
CREATE DATABASE IF NOT EXISTS ${DB_NAME};
USE ${DB_NAME};

DROP TABLE IF EXISTS patients;
DROP TABLE IF EXISTS hospitals;

CREATE TABLE patients (
  id           INT AUTO_INCREMENT PRIMARY KEY,
  first_name   VARCHAR(64)  NOT NULL,
  last_name    VARCHAR(64)  NOT NULL,
  email        VARCHAR(128) NOT NULL,
  diagnosis    VARCHAR(255) NOT NULL,
  notes        TEXT         NOT NULL,
  created_at   TIMESTAMP    DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

CREATE TABLE hospitals (
  id             INT AUTO_INCREMENT PRIMARY KEY,
  name           VARCHAR(128) NOT NULL,
  available_beds INT          NOT NULL DEFAULT 1000
) ENGINE=InnoDB;

INSERT INTO hospitals (name, available_beds) VALUES
  ('General Hospital',        1000000),
  ('St. Mary Medical Center', 1000000),
  ('Lakeside Clinic',         1000000),
  ('Mountain View Hospital',  1000000),
  ('Riverside Health',        1000000);

SET SESSION cte_max_recursion_depth = ${ROW_COUNT};

INSERT INTO patients (first_name, last_name, email, diagnosis, notes)
WITH RECURSIVE seq (n) AS (
  SELECT 1
  UNION ALL
  SELECT n + 1 FROM seq WHERE n < ${ROW_COUNT}
)
SELECT
  ELT(1 + (n % 8), 'Alice','Bob','Carol','David','Eve','Frank','Grace','Heidi'),
  ELT(1 + (n % 10), 'Smith','Johnson','Williams','Brown','Jones','Garcia','Miller','Davis','Rodriguez','Martinez'),
  CONCAT('patient', n, '@example.com'),
  ELT(1 + (n % 5), 'Hypertension','Diabetes','Asthma','Fracture','Migraine'),
  REPEAT(CONCAT('Clinical note for patient ', n, '. '), 6)
FROM seq;

CREATE INDEX idx_patients_last_name ON patients (last_name);
SQL

echo ">> Seed complete." | tee -a "$SEED_LOG"

echo ">> Capturing row counts..."
"${MYSQL[@]}" -N -e "
  SELECT CONCAT('patients: ', COUNT(*)) FROM ${DB_NAME}.patients
  UNION ALL
  SELECT CONCAT('hospitals: ', COUNT(*)) FROM ${DB_NAME}.hospitals;
" | tee "$ROW_COUNTS_FILE"

echo ">> Done. Evidence written to ${SEED_LOG} and ${ROW_COUNTS_FILE}."
