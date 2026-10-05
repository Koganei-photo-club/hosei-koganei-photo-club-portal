#!/usr/bin/env bash
set -euo pipefail

readonly EXPECTED_PROJECT_ID="hosei-photo-portal-phase123-local"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly CONFIG_FILE="${REPO_ROOT}/supabase/config.toml"
readonly DB_CONTAINER="supabase_db_${EXPECTED_PROJECT_ID}"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || fail "Docker CLI is not installed."
[[ -f "${CONFIG_FILE}" ]] || fail "Missing supabase/config.toml."
grep -q "^project_id = \"${EXPECTED_PROJECT_ID}\"$" "${CONFIG_FILE}" || fail "Unexpected local project_id."
if grep -Eq '^\[remotes\.|project_ref|supabase\.co|postgres(ql)?://' "${CONFIG_FILE}"; then
  fail "Remote project information was found in config.toml. Refusing to continue."
fi
docker inspect "${DB_CONTAINER}" >/dev/null 2>&1 || fail "Local DB container ${DB_CONTAINER} is not running."

run_verification() {
  local file="$1"
  printf '\nRunning %s\n' "${file#${REPO_ROOT}/}"
  docker exec -i "${DB_CONTAINER}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 < "${file}"
}

run_verification "${REPO_ROOT}/supabase/tests/202609300001_exhibition_workflow_v2_foundation_verification.sql"
run_verification "${REPO_ROOT}/supabase/tests/202609300002_exhibition_application_v2_verification.sql"
run_verification "${REPO_ROOT}/supabase/tests/202609300003_exhibition_work_submission_v2_verification.sql"

printf '\nPhase 1-3 local verification completed. Each verification rolled back its test data.\n'

