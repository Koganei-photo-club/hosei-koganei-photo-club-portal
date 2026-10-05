#!/usr/bin/env bash
set -euo pipefail

readonly CONTAINER="hosei_workflow_v2_db_only"
readonly LABEL="hosei.workflow-v2.local-only=true"
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

# This runner cannot accept a URL, project ref, password, or link target. Refuse
# common remote variables as an additional guard against accidental reuse.
for variable_name in DATABASE_URL SUPABASE_DB_URL SUPABASE_PROJECT_REF POSTGRES_URL PGPASSWORD; do
  [[ -z "${!variable_name:-}" ]] || fail "${variable_name} is set; refusing Local-only verification."
done

for required in "${COMPAT_SQL}" "${PREIMPORT_FIXTURE}" "${ADMIN_FIXTURE}"; do
  [[ -f "${required}" ]] || fail "Required Local-only file is missing: ${required}"
done

if docker container inspect "${CONTAINER}" >/dev/null 2>&1; then
  existing_label="$(docker container inspect --format '{{ index .Config.Labels "hosei.workflow-v2.local-only" }}' "${CONTAINER}")"
  [[ "${existing_label}" == "true" ]] || fail "Container name exists without the Local-only safety label."
  docker rm --force "${CONTAINER}" >/dev/null
fi

docker run --detach --name "${CONTAINER}" --label "${LABEL}" --platform linux/arm64 \
  --tmpfs /var/lib/postgresql/data:rw,noexec,nosuid,size=2g \
  --env POSTGRES_PASSWORD=workflow-v2-local-only --env POSTGRES_DB=postgres "${IMAGE}" >/dev/null

cleanup_on_success=false
cleanup() {
  if [[ "${cleanup_on_success}" == true ]]; then
    docker rm --force "${CONTAINER}" >/dev/null 2>&1 || true
  else
    printf '\nVerification stopped; isolated container preserved: %s\n' "${CONTAINER}" >&2
  fi
}
trap cleanup EXIT

readonly STARTUP_TIMEOUT_SECONDS=180
readonly REQUIRED_STABLE_CHECKS=3
startup_deadline=$((SECONDS + STARTUP_TIMEOUT_SECONDS))
stable_postmaster_start=""
stable_checks=0
initialization_shutdown_seen=false

while (( SECONDS < startup_deadline )); do
  container_state="$(docker container inspect --format '{{.State.Status}}' "${CONTAINER}" 2>/dev/null)" ||
    fail "Disposable PostgreSQL container disappeared during startup."
  case "${container_state}" in
    exited|dead)
      exit_code="$(docker container inspect --format '{{.State.ExitCode}}' "${CONTAINER}")"
      fail "Disposable PostgreSQL stopped during startup (state=${container_state}, exit=${exit_code})."
      ;;
  esac

  health_status="$(docker container inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${CONTAINER}")"
  [[ "${health_status}" != "unhealthy" ]] || fail "Disposable PostgreSQL became unhealthy during startup."
  [[ "${health_status}" != "none" ]] || fail "PostgreSQL image has no Docker healthcheck; refusing an ambiguous startup state."

  # A fresh Supabase Postgres data directory starts a temporary server and then
  # requests its fast shutdown before the final server starts. Do not accept a
  # healthy result until that initialization shutdown has appeared in its log.
  if [[ "${initialization_shutdown_seen}" == false ]]; then
    container_logs="$(docker logs "${CONTAINER}" 2>&1)" || fail "Could not read PostgreSQL startup logs."
    if [[ "${container_logs}" == *"received fast shutdown request"* ]]; then
      initialization_shutdown_seen=true
    fi
  fi

  if [[ "${initialization_shutdown_seen}" == true && "${container_state}" == "running" && "${health_status}" == "healthy" ]]; then
    # The image briefly starts an initialization server before replacing it with
    # the final server. Require repeated SQL responses from the same postmaster,
    # in addition to Docker's healthy state, so that temporary server is ignored.
    if postmaster_start="$(docker exec "${CONTAINER}" psql -X -U postgres -d postgres -Atqc \
      "select pg_postmaster_start_time()::text" 2>/dev/null)" && [[ -n "${postmaster_start}" ]]; then
      if [[ "${postmaster_start}" == "${stable_postmaster_start}" ]]; then
        stable_checks=$((stable_checks + 1))
      else
        stable_postmaster_start="${postmaster_start}"
        stable_checks=1
      fi
      if (( stable_checks >= REQUIRED_STABLE_CHECKS )); then
        break
      fi
    else
      stable_postmaster_start=""
      stable_checks=0
    fi
  else
    stable_postmaster_start=""
    stable_checks=0
  fi
  sleep 2
done

(( stable_checks >= REQUIRED_STABLE_CHECKS )) ||
  fail "Disposable PostgreSQL did not reach a stable final healthy state within ${STARTUP_TIMEOUT_SECONDS}s."

apply_sql() {
  local file="$1"
  printf 'Applying %s\n' "${file#${REPO_ROOT}/}"
  docker exec -i "${CONTAINER}" psql -X -U postgres -d postgres -v ON_ERROR_STOP=1 < "${file}"
}

printf 'Applying %s as Supabase schema administrator\n' "${COMPAT_SQL#${REPO_ROOT}/}"
docker exec -i "${CONTAINER}" psql -X -U supabase_admin -d postgres -v ON_ERROR_STOP=1 < "${COMPAT_SQL}"
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

for verification in "${REPO_ROOT}"/supabase/tests/*.sql; do
  printf '\nRunning %s\n' "${verification#${REPO_ROOT}/}"
  apply_sql "${verification}"
done

printf '\nPhase 1-11 DB-only verification completed successfully.\n'
cleanup_on_success=true
