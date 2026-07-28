#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

declare -r GRAFANA_HOST="${GRAFANA_HOST:-}"
declare -r GRAFANA_USER="${GRAFANA_USER:-admin}"
declare -r GRAFANA_PASSWORD="${GRAFANA_PASSWORD:-}"
declare -ri CONCURRENCY="${CONCURRENCY:-3}"
declare -r DRY_RUN="${DRY_RUN:-true}"
declare -r SKIP_FOLDERS="${SKIP_FOLDERS:-true}"
declare -r SKIP_GCP_PROMETHEUS_DATASOURCE="${SKIP_GCP_PROMETHEUS_DATASOURCE:-true}"
declare -r IGNORE_CONFIRM="${IGNORE_CONFIRM:-false}"
declare -ri MAX_RETRIES="${MAX_RETRIES:-5}"
declare -ri RETRY_DELAY="${RETRY_DELAY:-10}"
declare -ri CONNECTION_TIMEOUT="${CONNECTION_TIMEOUT:-10}"
declare -ri MAX_TIME="${MAX_TIME:-60}"

declare -r TEMP_FILES_LOG=/tmp/temp_files.log
declare -a TEMP_FILES=()
declare -a HTTP_METHODS=("GET" "POST" "PUT" "DELETE" "PATCH" "HEAD" "OPTIONS")
declare -a DRY_RUN_SAFE_HTTP_METHODS=("GET" "HEAD" "OPTIONS")
declare -ra RESOURCES_TO_SYNC=(
  "alert-rules"
  "contact-points"
  "datasources"
  "dashboards"
)

declare FINISHED=false

_log() {
  local -r level="$1"
  local -r message="$2"
  local -r timestamp=$(date --utc +%FT%TZ)
  local color
  case "$level" in
  "INFO")
    color="\033[0;32m"
    ;;
  "WARN")
    color="\033[0;33m"
    ;;
  "ERROR")
    color="\033[0;31m"
    ;;
  "DEBUG")
    color="\033[0;34m"
    ;;
  *)
    color="\033[0;36m"
    ;;
  esac
  readonly color
  local -r log_message="{\"timestamp\": \"${timestamp}\", \"level\": \"${level}\", \"message\": \"${message}\"}"
  echo -e "${color}${log_message}\033[0m"
}
_info() {
  _log "INFO" "$*"
}
_error() {
  _log "ERROR" "$*" >&2
}
_warn() {
  _log "WARN" "$*"
}
_safe_info() {
  local prefix=""
  if [[ "$DRY_RUN" == "true" ]]; then
    prefix="[DRY-RUN] "
  fi
  readonly prefix
  _log "INFO" "${prefix}$*"
}

on_cancel() {
  if [[ "$FINISHED" != "true" ]]; then
    _warn "!!! Script execution has been interrupted. Check the logs for more information !!!"
    for job in $(jobs -p); do
      kill -9 "${job}" >/dev/null 2>&1 || true
    done
    exit 128
  fi
}

on_exit() {
  if [[ -f "${TEMP_FILES_LOG}" ]]; then
    mapfile -t TEMP_FILES <"${TEMP_FILES_LOG}"
    if [[ "${#TEMP_FILES[@]}" -gt 0 ]]; then
      for file in "${TEMP_FILES[@]}"; do
        if [[ -f "${file}" ]]; then
          if ! rm -f "${file}" >/dev/null 2>&1; then
            _error "Failed to delete temp file ${file}"
          fi
        fi
      done
    fi
    rm -f "${TEMP_FILES_LOG}" >/dev/null 2>&1 || true
  fi
}

_get_lines_count() {
  local -r file="$1"
  if [[ -z "${file}" ]]; then
    _error "File is required"
    return 1
  fi
  if [[ ! -f "${file}" ]]; then
    _error "File ${file} not found"
    return 1
  fi
  local -i count
  count=$(cat "${file}" | sed '/^\s*#/d;/^\s*$/d' | wc -l)
  echo "${count}"
}

_check_if_failed_entries_exist() {
  local -r file="$1"
  [[ $(_get_lines_count "${file}") -gt 0 ]] && echo 1 || echo 0
}

_mktemp() {
  local -r tempfile=$(mktemp)
  echo "${tempfile}" >>"${TEMP_FILES_LOG}"
  echo "${tempfile}"
}

_wait_jobs_with_concurrency() {
  local -i job_count=0
  while true; do
    local -i running_jobs
    running_jobs=$(jobs -p | wc -l)
    if [[ "${running_jobs}" -le "${CONCURRENCY}" ]]; then
      break
    fi
    wait -n || true
    job_count=$((job_count - 1))
  done
}

_validate_required_binaries() {
  local -a required_binaries=("curl" "jq" "base64")
  for cmd in "${required_binaries[@]}"; do
    if ! command -v "${cmd}" &>/dev/null; then
      _error "Command ${cmd} is required"
      return 1
    fi
  done
}

_validate_env() {
  local -rA required_envs=(
    [GRAFANA_HOST]="${GRAFANA_HOST}"
    [GRAFANA_USER]="${GRAFANA_USER}"
    [GRAFANA_PASSWORD]="${GRAFANA_PASSWORD}"
  )
  for env in "${!required_envs[@]}"; do
    if [[ -z "${required_envs[$env]}" ]]; then
      _error "Environment variable ${env} is required"
      return 1
    fi
  done
}

_validate_concurrency() {
  if [[ ! "${CONCURRENCY}" =~ ^[0-9]+$ ]]; then
    _error "Invalid concurrency value: ${CONCURRENCY}"
    return 1
  fi
  if [[ "${CONCURRENCY}" -lt 1 || "${CONCURRENCY}" -gt 100 ]]; then
    _error "concurrency must be greater than 0 and less than 100"
    return 1
  fi
}

_grafana_client() {
  local -r method="$1"
  local -r path="$2"

  if [[ -z "${method}" || -z "${path}" ]]; then
    _error "Method and path are required"
    return 1
  fi

  if [[ ! "${HTTP_METHODS[*]}" =~ $method ]]; then
    _error "Invalid method: ${method}"
    return 1
  fi

  local output_file
  output_file=$(_mktemp)
  readonly output_file

  local cmd="curl --silent -X ${method} -H 'Content-Type: application/json'"
  cmd="${cmd} -u ${GRAFANA_USER}:${GRAFANA_PASSWORD}"
  cmd="${cmd} --max-time ${MAX_TIME} --connect-timeout ${CONNECTION_TIMEOUT}"
  cmd="${cmd} --retry ${MAX_RETRIES} --retry-delay ${RETRY_DELAY}"
  cmd="${cmd} --output ${output_file} --write-out '%{http_code}'"
  if [[ "${method}" == "POST" || "${method}" == "PUT" ]]; then
    local -r data="${3:-}"
    if [[ -z "${data}" ]]; then
      _error "Data is required for ${method}"
      return 1
    fi
    cmd="${cmd} --data '${data}'"
  fi
  local -r grafana_host="${GRAFANA_HOST%/}"
  local -r url="${grafana_host}/${path}"
  cmd="${cmd} \"${url}\""
  readonly cmd

  if [[ "$DRY_RUN" == "true" && ! "${DRY_RUN_SAFE_HTTP_METHODS[*]}" =~ $method ]]; then
    _safe_info "Running: ${cmd}"
    return 0
  fi

  local -ri status_code=$(eval "${cmd}")
  if [[ "${status_code}" -lt 200 || "${status_code}" -ge 299 ]]; then
    _error "Failed to ${method} ${path} with status code ${status_code}"
    return 1
  fi
  cat "${output_file}"
}

_find_unprovisioned_alert-rules() {
  local alert_rules
  alert_rules=$(_grafana_client GET "api/v1/provisioning/alert-rules") || return 1
  if [[ -z "${alert_rules}" ]]; then
    _error "Failed to get alert rules"
    return 1
  fi
  readonly alert_rules
  local -i alert_rule_count
  alert_rule_count=$(echo "${alert_rules}" | jq -r '. | length')
  if [[ "${alert_rule_count}" -eq 0 ]]; then
    _info "No alert rules found"
    return 0
  fi
  readonly alert_rule_count

  local non_provisioned_alert_rules
  non_provisioned_alert_rules=$(echo "${alert_rules}" | jq -r '[.[] | select(.provenance != "file") | {uid: .uid, title: .title}]')
  if [[ -z "${non_provisioned_alert_rules}" ]]; then
    _info "Manually provisioned alert rules not found"
    return 0
  fi
  readonly non_provisioned_alert_rules
  local -i non_provisioned_alert_rule_count
  non_provisioned_alert_rule_count=$(echo "${non_provisioned_alert_rules}" | jq -r '. | length')
  if [[ "${non_provisioned_alert_rule_count}" -eq 0 ]]; then
    _info "No manually provisioned alert rules to delete"
    return 0
  fi

  local failed_tmpfile
  failed_tmpfile=$(_mktemp)
  readonly failed_tmpfile

  _safe_info "Deleting ${non_provisioned_alert_rule_count} alert rules"
  for alert_rule in $(echo "${non_provisioned_alert_rules}" | jq -r '.[] | @base64'); do
    _inner_delete_func() {
      local decoded_alert_rule
      decoded_alert_rule=$(echo "${alert_rule}" | base64 -d)
      local alert_rule_uid
      alert_rule_uid=$(echo "${decoded_alert_rule}" | jq -r '.uid')
      local alert_rule_title
      alert_rule_title=$(echo "${decoded_alert_rule}" | jq -r '.title')
      if [[ -z "${alert_rule_uid}" ]]; then
        _error "Failed to get alert rule UID for ${decoded_alert_rule}"
        echo "${alert_rule_title}" >>"${failed_tmpfile}"
        return 1
      fi
      _safe_info "Deleting alert rule ${alert_rule_title} (${alert_rule_uid})"
      _grafana_client DELETE "api/v1/provisioning/alert-rules/${alert_rule_uid}" &>/dev/null || {
        _error "Failed to delete alert rule ${alert_rule_title} (${alert_rule_uid})"
        echo "${alert_rule_uid}" >>"${failed_tmpfile}"
        return 1
      }
      _safe_info "Deleted alert rule ${alert_rule_uid} with success"
    }
    _inner_delete_func &
    _wait_jobs_with_concurrency
  done
  sleep 0.5
  wait

  return "$(_check_if_failed_entries_exist "${failed_tmpfile}")"
}

_find_unprovisioned_contact-points() {
  local contact_points
  contact_points=$(_grafana_client GET "api/v1/provisioning/contact-points") || return 1
  if [[ -z "${contact_points}" ]]; then
    _error "Failed to get contact points"
    return 1
  fi
  readonly contact_points
  local -i contact_point_count
  contact_point_count=$(echo "${contact_points}" | jq -r '. | length')
  if [[ "${contact_point_count}" -eq 0 ]]; then
    _info "No contact points found"
    return 0
  fi
  readonly contact_point_count

  local non_provisioned_contact_points
  non_provisioned_contact_points=$(
    echo "${contact_points}" | jq -r '
    [.[] | select(.provenance != "file" and .name != "email receiver") | {uid: .uid, name: .name}]'
  )
  if [[ -z "${non_provisioned_contact_points}" ]]; then
    _info "Manually provisioned contact points not found"
    return 0
  fi
  readonly non_provisioned_contact_points
  local -i non_provisioned_contact_point_count
  non_provisioned_contact_point_count=$(echo "${non_provisioned_contact_points}" | jq -r '. | length')
  if [[ "${non_provisioned_contact_point_count}" -eq 0 ]]; then
    _info "No manually provisioned contact points to delete"
    return 0
  fi

  local failed_tmpfile
  failed_tmpfile=$(_mktemp)
  readonly failed_tmpfile

  _safe_info "Deleting ${non_provisioned_contact_point_count} contact points"
  for contact_point in $(echo "${non_provisioned_contact_points}" | jq -r '.[] | @base64'); do
    _inner_delete_func() {
      local decoded_contact_point
      decoded_contact_point=$(echo "${contact_point}" | base64 -d)
      local contact_point_uid
      contact_point_uid=$(echo "${decoded_contact_point}" | jq -r '.uid')
      local contact_point_name
      contact_point_name=$(echo "${decoded_contact_point}" | jq -r '.name')
      if [[ -z "${contact_point_uid}" ]]; then
        _error "Failed to get contact point UID for ${decoded_contact_point}. Please delete from the UI"
        echo "${contact_point_name}" >>"${failed_tmpfile}"
        return 1
      fi
      _safe_info "Deleting contact point ${contact_point_name} (${contact_point_uid})"
      _grafana_client DELETE "api/v1/provisioning/contact-points/${contact_point_uid}" &>/dev/null || {
        _error "Failed to delete contact point ${contact_point_uid}"
        echo "${contact_point_uid}" >>"${failed_tmpfile}"
        return 1
      }
      _safe_info "Deleted contact point ${contact_point_uid} with success"
    }
    _inner_delete_func &
    _wait_jobs_with_concurrency
  done
  sleep 0.5
  wait

  return "$(_check_if_failed_entries_exist "${failed_tmpfile}")"
}

_find_unprovisioned_datasources() {
  local datasources
  datasources=$(_grafana_client GET "api/datasources") || return 1
  if [[ -z "${datasources}" ]]; then
    _error "Failed to get datasources"
    return 1
  fi
  readonly datasources
  local -i datasource_count
  datasource_count=$(echo "${datasources}" | jq -r '. | length')
  if [[ "${datasource_count}" -eq 0 ]]; then
    _info "No datasources found"
    return 0
  fi
  readonly datasource_count

  local editable_datasources_jq_select_filter=".readOnly == false"
  if [[ "${SKIP_GCP_PROMETHEUS_DATASOURCE}" == "true" ]]; then
    _warn "Skipping gcp-prometheus datasource"
    editable_datasources_jq_select_filter="${editable_datasources_jq_select_filter} and (.uid != \"gcp-prometheus\")"
  fi
  readonly editable_datasources_jq_select_filter

  local editable_datasources
  editable_datasources=$(echo "${datasources}" | jq -r "[.[] | select(${editable_datasources_jq_select_filter}) | {uid: .uid, name: .name}]")

  if [[ "${editable_datasources}" == "[]" ]]; then
    _info "Manually provisioned datasources not found"
    return 0
  fi
  readonly editable_datasources

  local -i editable_datasource_count
  editable_datasource_count=$(echo "${editable_datasources}" | jq -r '. | length')
  if [[ "${editable_datasource_count}" -eq 0 ]]; then
    _info "No manually provisioned datasources to delete"
    return 0
  fi

  local failed_tmpfile
  failed_tmpfile=$(_mktemp)
  readonly failed_tmpfile

  _safe_info "Deleting ${editable_datasource_count} datasources"
  for datasource in $(echo "${editable_datasources}" | jq -r '.[] | @base64'); do
    _inner_delete_func() {
      local decoded_datasource
      decoded_datasource=$(echo "${datasource}" | base64 -d)
      local datasource_uid
      datasource_uid=$(echo "${decoded_datasource}" | jq -r '.uid')
      if [[ -z "${datasource_uid}" ]]; then
        _error "Failed to get datasource UID for ${decoded_datasource}. Please delete from the UI"
        return 1
      fi
      local datasource_name
      datasource_name=$(echo "${decoded_datasource}" | jq -r '.name')
      _safe_info "Deleting datasource ${datasource_name} (${datasource_uid})"
      _grafana_client DELETE "api/datasources/uid/${datasource_uid}" &>/dev/null || {
        _error "Failed to delete datasource ${datasource_name} (${datasource_uid})"
        echo "${datasource_uid}" >>"${failed_tmpfile}"
        return 1
      }
      _safe_info "Deleted datasource ${datasource_uid} with success"
    }
    _inner_delete_func &
    _wait_jobs_with_concurrency
  done
  sleep 0.5
  wait

  return "$(_check_if_failed_entries_exist "${failed_tmpfile}")"
}

_find_unprovisioned_dashboards() {
  local dashboards
  dashboards=$(_grafana_client GET "api/search?query=&type=dash-db") || return 1
  if [[ -z "${dashboards}" ]]; then
    _error "Failed to get dashboards"
    return 1
  fi
  readonly dashboards
  local -i dashboard_count
  dashboard_count=$(echo "${dashboards}" | jq -r '. | length')
  if [[ "${dashboard_count}" -eq 0 ]]; then
    _info "No dashboards found"
    return 0
  fi
  readonly dashboard_count

  local tmpfile
  tmpfile=$(_mktemp)
  readonly tmpfile

  for dashboard in $(echo "${dashboards}" | jq -r '.[] | @base64'); do
    _inner_func() {
      local decoded_dashboard
      decoded_dashboard=$(echo "${dashboard}" | base64 -d)
      local dashboard_uid
      dashboard_uid=$(echo "${decoded_dashboard}" | jq -r '.uid')
      if [[ -z "${dashboard_uid}" ]]; then
        _error "Failed to get dashboard UID for ${decoded_dashboard}. Please delete from the UI"
        return 1
      fi
      local dashboard_title
      dashboard_title=$(echo "${decoded_dashboard}" | jq -r '.title')
      _info "Syncing dashboard ${dashboard_title} (${dashboard_uid})"
      local dashboard_type
      dashboard_type=$(echo "${decoded_dashboard}" | jq -r '.type')
      if [[ "${dashboard_type}" == "dash-folder" && "${SKIP_FOLDERS}" == "true" ]]; then
        _warn "Skipping folder ${dashboard_title} (${dashboard_uid})"
        return 0
      fi
      local dashboard_data
      dashboard_data=$(_grafana_client GET "api/dashboards/uid/${dashboard_uid}") || dashboard_data=""
      if [[ -z "${dashboard_data}" ]]; then
        _error "Failed to get dashboard data for ${dashboard_title} (${dashboard_uid})"
        return 1
      fi
      local is_folder
      is_folder=$(echo "${dashboard_data}" | jq -r '.meta.isFolder // false')
      if [[ "${is_folder}" == "true" && "${SKIP_FOLDERS}" == "true" ]]; then
        _warn "Skipping folder ${dashboard_title} (${dashboard_uid})"
        return 0
      fi
      local is_provisioned
      is_provisioned=$(echo "${dashboard_data}" | jq -r '.meta.provisioned // false')
      if [[ "${is_provisioned}" == "true" ]]; then
        _warn "Dashboard ${dashboard_title} (${dashboard_uid}) is provisioned, skipping"
        return 0
      fi
      echo "${dashboard_uid}:${dashboard_title}" >>"${tmpfile}"
    }
    _inner_func &
    _wait_jobs_with_concurrency
  done
  sleep 0.5
  wait

  local dashboard_refs=()
  mapfile -t dashboard_refs <"${tmpfile}"
  readonly -a dashboard_refs

  if [[ "${#dashboard_refs[@]}" -eq 0 ]]; then
    _info "No dashboards to delete"
    return 0
  fi

  local failed_tmpfile
  failed_tmpfile=$(_mktemp)
  readonly failed_tmpfile

  _safe_info "Deleting ${#dashboard_refs[@]} dashboards"
  for dashboard_ref in "${dashboard_refs[@]}"; do
    _inner_delete_func() {
      local dashboard_uid="${dashboard_ref%%:*}"
      local dashboard_title="${dashboard_ref#*:}"
      _safe_info "Deleting dashboard ${dashboard_title} (${dashboard_uid})"
      _grafana_client DELETE "api/dashboards/uid/${dashboard_uid}" &>/dev/null || {
        _error "Failed to delete dashboard ${dashboard_title} (${dashboard_uid})"
        echo "${dashboard_uid}" >>"${failed_tmpfile}"
        return 1
      }
      _safe_info "Deleted dashboard ${dashboard_title} (${dashboard_uid}) with success"
    }
    _inner_delete_func &
    _wait_jobs_with_concurrency
  done
  sleep 0.5
  wait

  return "$(_check_if_failed_entries_exist "${failed_tmpfile}")"
}

main() {
  local -a resources_to_sync=("$@")

  _validate_required_binaries || return 1
  _validate_env || return 1
  _validate_concurrency || return 1

  _info "Syncing resources: ${resources_to_sync[*]}"
  _info "Concurrency: ${CONCURRENCY}"

  if [[ "$DRY_RUN" != "true" ]]; then
    local confirm
    if [[ "$IGNORE_CONFIRM" != "true" ]]; then
      read -rp "Do you want to continue? (y/n): " confirm
      if [[ ! "$confirm" =~ ^([yY])+$ ]]; then
        _warn "Exiting the script"
        return 0
      fi
    fi
  else
    _warn "Running in dry-run mode"
  fi

  local -a failed_to_sync_resources=()
  for resource in "${resources_to_sync[@]}"; do
    local func_ref="_find_unprovisioned_${resource}"
    if ! type "${func_ref}" &>/dev/null; then
      _error "Function ${func_ref} is not defined"
      return 1
    fi
    _info "Syncing ${resource}"
    "${func_ref}" || {
      _error "Failed to sync ${resource}"
      failed_to_sync_resources+=("${resource}")
    }
    sleep 0.2
  done
  readonly -a failed_to_sync_resources

  local -ri failed_count="${#failed_to_sync_resources[@]}"
  if [[ "${failed_count}" -eq "${#resources_to_sync[@]}" ]]; then
    _error "Failed to sync all resources"
    return 1
  fi
  if [[ "${failed_count}" -gt 0 ]]; then
    _warn "Failed to sync resources: ${failed_to_sync_resources[*]}"
  fi
  local -ri success_count=$((${#resources_to_sync[@]} - failed_count))
  _info "Sync succeeded for ${success_count} out of ${#resources_to_sync[@]} resources"
}

trap on_cancel SIGINT SIGTERM SIGHUP
trap on_exit EXIT

main "${RESOURCES_TO_SYNC[@]}"
declare -ri exit_code=$?
FINISHED=true
readonly FINISHED
exit $exit_code
