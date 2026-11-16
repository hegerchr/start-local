#!/bin/bash
# Copyright Elasticsearch B.V. and/or licensed to Elasticsearch B.V. under one
# or more contributor license agreements. See the NOTICE file distributed with
# this work for additional information regarding copyright
# ownership. Elasticsearch B.V. licenses this file to you under
# the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#	http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

# Exercise installer functions in isolated POSIX shells without running Docker.
function set_up_before_script() {
    APM_TEST_DIR=$(mktemp -d)
    export APM_TEST_DIR
    sed '/^main "\$@"$/d' start-local.sh > "${APM_TEST_DIR}/functions.sh"
}

function tear_down_after_script() {
    rm -rf "${APM_TEST_DIR}"
}

function test_apm_rejects_esonly_in_both_orders() {
    local args output status
    for args in '--apm --esonly' '--esonly --apm'; do
        # shellcheck disable=SC2086
        output=$(sh -c '. "$1"; shift; parse_args "$@"' sh "${APM_TEST_DIR}/functions.sh" $args 2>&1)
        status=$?
        assert_equals "1" "$status"
        assert_contains "--apm requires Kibana" "$output"
    done
}

function test_apm_key_is_scoped_persisted_and_displayed() {
    local output status
    sh -s "${APM_TEST_DIR}/functions.sh" "${APM_TEST_DIR}" > "${APM_TEST_DIR}/output" <<'SH'
. "$1"
cd "$2"
parse_args --apm --edot -v 9.5.6
es_password=test-password
api_key=es-key
curl() {
  case "$*" in
    *'/_security/api_key'*)
      case "$*" in
        *'"application":"apm"'*'"event:write","config_agent:read"'*) ;;
        *) return 1 ;;
      esac
      printf '%s' '{"encoded" : "YWJjOmRlZg=="}'
      ;;
    *'/intake/v2/events'*)
      case "$*" in
        *'Authorization: ApiKey YWJjOmRlZg=='*) printf 202 ;;
        *) return 1 ;;
      esac
      ;;
    *) return 1 ;;
  esac
}
setup_apm_api_key
. ./.env
[ "$APM_LOCAL_API_KEY" = 'YWJjOmRlZg==' ]
success
SH
    status=$?
    output=$(cat "${APM_TEST_DIR}/output")
    assert_equals "0" "$status"
    assert_contains "APM Server URL: http://localhost:8200" "$output"
    assert_contains "APM API key: YWJjOmRlZg==" "$output"
}

function test_apm_key_failure_does_not_report_success() {
    local output status
    sh -s "${APM_TEST_DIR}/functions.sh" > "${APM_TEST_DIR}/output" <<'SH'
. "$1"
parse_args --apm
startup >/dev/null
es_password=test-password
curl() { printf '%s' '{"error":"denied"}'; }
generate_error_log() { echo diagnostic-log; }
cleanup() { echo cleaned-up; }
setup_apm_api_key
echo unexpected-success
SH
    status=$?
    output=$(cat "${APM_TEST_DIR}/output")
    assert_equals "1" "$status"
    assert_contains "did not return an encoded APM API key" "$output"
    assert_contains "diagnostic-log" "$output"
    assert_contains "cleaned-up" "$output"
}

function test_default_install_does_not_create_apm_key() {
    local status
    sh -s "${APM_TEST_DIR}/functions.sh" <<'SH'
. "$1"
parse_args
curl() { exit 99; }
setup_apm_api_key
SH
    status=$?
    assert_equals "0" "$status"
}
