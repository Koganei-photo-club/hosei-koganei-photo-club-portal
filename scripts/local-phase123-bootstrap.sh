#!/usr/bin/env bash
set -euo pipefail

readonly EXPECTED_PROJECT_ID="hosei-photo-portal-phase123-local"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly CONFIG_FILE="${REPO_ROOT}/supabase/config.toml"
readonly DB_CONTAINER="supabase_db_${EXPECTED_PROJECT_ID}"
readonly PREIMPORT_FIXTURE="${REPO_ROOT}/supabase/local/fixtures/2026_summer_required_members.sql"
readonly ADMIN_FIXTURE="${REPO_ROOT}/supabase/local/fixtures/verification_admin.sql"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ "$#" -eq 1 && "$1" == "--confirm-local-reset" ]] || fail "Usage: $0 --confirm-local-reset"
command -v supabase >/dev/null 2>&1 || fail "Supabase CLI is not installed. Nothing was changed."
command -v docker >/dev/null 2>&1 || fail "Docker CLI is not installed. Nothing was changed."
[[ -f "${CONFIG_FILE}" ]] || fail "Missing supabase/config.toml."
grep -q "^project_id = \"${EXPECTED_PROJECT_ID}\"$" "${CONFIG_FILE}" || fail "Unexpected local project_id."
grep -A1 '^\[db.migrations\]$' "${CONFIG_FILE}" | grep -q '^enabled = false$' || fail "Automatic migrations must remain disabled."
grep -A1 '^\[db.seed\]$' "${CONFIG_FILE}" | grep -q '^enabled = false$' || fail "Automatic seed must remain disabled."
if grep -Eq '^\[remotes\.|project_ref|supabase\.co|postgres(ql)?://' "${CONFIG_FILE}"; then
  fail "Remote project information was found in config.toml. Refusing to continue."
fi

cd "${REPO_ROOT}"
printf 'Starting the isolated Local Supabase stack (%s)...\n' "${EXPECTED_PROJECT_ID}"
supabase start

docker inspect "${DB_CONTAINER}" >/dev/null 2>&1 || fail "Expected local DB container ${DB_CONTAINER} was not found."

printf 'Resetting only the local database (automatic migrations and seeds are disabled)...\n'
supabase db reset --local --no-seed
docker inspect "${DB_CONTAINER}" >/dev/null 2>&1 || fail "Local DB container disappeared after reset."

apply_sql() {
  local file="$1"
  printf 'Applying %s\n' "${file#${REPO_ROOT}/}"
  docker exec -i "${DB_CONTAINER}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 < "${file}"
}

fixture_applied=false
for migration in "${REPO_ROOT}"/supabase/migrations/*.sql; do
  if [[ "$(basename "${migration}")" == "202609030018_import_2026_summer_archive.sql" ]]; then
    apply_sql "${PREIMPORT_FIXTURE}"
    fixture_applied=true
  fi
  apply_sql "${migration}"
done

[[ "${fixture_applied}" == true ]] || fail "The archive import migration was not found; prerequisite fixture was not applied."
apply_sql "${ADMIN_FIXTURE}"

printf '\nLocal schema bootstrap completed. No remote command or database URL was used.\n'
printf 'Next: scripts/local-phase123-verify.sh\n'
