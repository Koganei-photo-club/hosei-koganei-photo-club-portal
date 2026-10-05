#!/usr/bin/env bash
set -euo pipefail

readonly CONTAINER="hosei_phase123_db_only"
readonly LABEL="hosei.phase123.local-only=true"
readonly IMAGE="public.ecr.aws/supabase/postgres:17.6.1.171"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly COMPAT_SQL="${REPO_ROOT}/supabase/local/db-only/supabase_service_compat.sql"
readonly PREIMPORT_FIXTURE="${REPO_ROOT}/supabase/local/fixtures/2026_summer_required_members.sql"
readonly ADMIN_FIXTURE="${REPO_ROOT}/supabase/local/fixtures/verification_admin.sql"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ "$#" -eq 1 && "$1" == "--confirm-disposable-local-db" ]] ||
  fail "Usage: $0 --confirm-disposable-local-db"
command -v docker >/dev/null 2>&1 || fail "Docker CLI is not installed."
[[ -f "${COMPAT_SQL}" && -f "${PREIMPORT_FIXTURE}" && -f "${ADMIN_FIXTURE}" ]] ||
  fail "A required Local-only SQL file is missing."

# This path deliberately has no URL/ref/link input. Reject common remote Supabase
# environment variables as an additional guard against copying this into a remote flow.
for variable_name in DATABASE_URL SUPABASE_DB_URL SUPABASE_PROJECT_REF POSTGRES_URL; do
  [[ -z "${!variable_name:-}" ]] || fail "${variable_name} is set; refusing Local-only verification."
done

if docker container inspect "${CONTAINER}" >/dev/null 2>&1; then
  existing_label="$(docker container inspect --format '{{ index .Config.Labels "hosei.phase123.local-only" }}' "${CONTAINER}")"
  [[ "${existing_label}" == "true" ]] || fail "Container name exists without the Local-only safety label."
  docker rm --force "${CONTAINER}" >/dev/null
fi

printf 'Starting disposable PostgreSQL container (no published ports)...\n'
docker run --detach --name "${CONTAINER}" \
  --label "${LABEL}" \
  --platform linux/arm64 \
  --tmpfs /var/lib/postgresql/data:rw,noexec,nosuid,size=2g \
  --env POSTGRES_PASSWORD=phase123-local-only \
  --env POSTGRES_DB=postgres \
  "${IMAGE}" >/dev/null

cleanup_on_success=false
cleanup() {
  if [[ "${cleanup_on_success}" == true ]]; then
    docker rm --force "${CONTAINER}" >/dev/null 2>&1 || true
  else
    printf '\nVerification stopped. The isolated container was preserved for inspection.\n' >&2
    printf 'Remove it with: docker rm --force %s\n' "${CONTAINER}" >&2
  fi
}
trap cleanup EXIT

for _ in $(seq 1 60); do
  if docker exec "${CONTAINER}" pg_isready -U postgres -d postgres >/dev/null 2>&1; then break; fi
  sleep 1
done
docker exec "${CONTAINER}" pg_isready -U postgres -d postgres >/dev/null 2>&1 ||
  fail "Disposable PostgreSQL did not become ready."

apply_sql() {
  local file="$1"
  printf 'Applying %s\n' "${file#${REPO_ROOT}/}"
  docker exec -i "${CONTAINER}" psql -X -U postgres -d postgres -v ON_ERROR_STOP=1 < "${file}"
}

apply_sql "${COMPAT_SQL}"

fixture_applied=false
for migration in "${REPO_ROOT}"/supabase/migrations/*.sql; do
  if [[ "$(basename "${migration}")" == "202609030018_import_2026_summer_archive.sql" ]]; then
    apply_sql "${PREIMPORT_FIXTURE}"
    fixture_applied=true
  fi
  apply_sql "${migration}"
done
[[ "${fixture_applied}" == true ]] || fail "Archive import migration was not found."
apply_sql "${ADMIN_FIXTURE}"

for verification in \
  "${REPO_ROOT}/supabase/tests/202609300001_exhibition_workflow_v2_foundation_verification.sql" \
  "${REPO_ROOT}/supabase/tests/202609300002_exhibition_application_v2_verification.sql" \
  "${REPO_ROOT}/supabase/tests/202609300003_exhibition_work_submission_v2_verification.sql"
do
  printf '\nRunning %s\n' "${verification#${REPO_ROOT}/}"
  docker exec -i "${CONTAINER}" psql -X -U postgres -d postgres -v ON_ERROR_STOP=1 < "${verification}"
done

printf '\nPhase 1-3 DB-only verification completed successfully.\n'
cleanup_on_success=true

