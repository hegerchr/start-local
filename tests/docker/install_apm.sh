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


CURRENT_DIR=$(pwd)
DEFAULT_DIR="${CURRENT_DIR}/elastic-start-local"

function set_up_before_script() {
    # shellcheck disable=SC2086
    sh "${CURRENT_DIR}/${SCRIPT_FILE}"${SCRIPT_EXTRA_ARGS:-} --apm > "${CURRENT_DIR}/apm-install.out"
    # shellcheck disable=SC1091
    source "${DEFAULT_DIR}/.env"
}

function tear_down_after_script() {
    printf 'yes\nno\n' | "${DEFAULT_DIR}/uninstall.sh"
    rm -rf "${DEFAULT_DIR}"
    rm -f "${CURRENT_DIR}/apm-install.out"
}

function test_apm_output_contains_connection_details() {
    local output
    output=$(cat "${CURRENT_DIR}/apm-install.out")
    assert_contains "APM Server URL: ${APM_LOCAL_URL}" "$output"
    assert_contains "APM API key: ${APM_LOCAL_API_KEY}" "$output"
}

function test_apm_intake_requires_the_agent_api_key() {
    local status payload
    payload='{"metadata":{"service":{"name":"start-local-test","agent":{"name":"other","version":"1.0"}},"process":{"pid":1}}}'
    status=$(curl -s -o /dev/null -w '%{http_code}' \
      "${APM_LOCAL_URL}/intake/v2/events" \
      -H 'Content-Type: application/x-ndjson' --data-binary "${payload}
")
    assert_equals "401" "$status"
    status=$(curl -s -o /dev/null -w '%{http_code}' \
      "${APM_LOCAL_URL}/intake/v2/events" \
      -H 'Content-Type: application/x-ndjson' \
      -H "Authorization: ApiKey ${APM_LOCAL_API_KEY}" --data-binary "${payload}
")
    assert_equals "202" "$status"
}

function test_apm_restarts_with_the_same_agent_api_key() {
    "${DEFAULT_DIR}/stop.sh"
    "${DEFAULT_DIR}/start.sh"
    local status attempt
    attempt=0
    while [ "$attempt" -lt 60 ]; do
        attempt=$((attempt + 1))
        status=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' \
          "${APM_LOCAL_URL}/intake/v2/events" \
          -H 'Content-Type: application/x-ndjson' \
          -H "Authorization: ApiKey ${APM_LOCAL_API_KEY}" \
          --data-binary '{"metadata":{"service":{"name":"restart-test","agent":{"name":"other","version":"1.0"}},"process":{"pid":1}}}
' || true)
        [ "$status" = "202" ] && break
        sleep 2
    done
    assert_equals "202" "$status"
}

function test_apm_transaction_is_indexed() {
    local status attempt payload
    payload=$(cat <<EOF
{"metadata":{"service":{"name":"start-local-test","agent":{"name":"other","version":"1.0"}},"process":{"pid":1}}}
{"transaction":{"id":"0123456789abcdef","trace_id":"0123456789abcdef0123456789abcdef","name":"start-local-test-transaction","type":"request","duration":1,"sampled":true,"span_count":{"started":0},"timestamp":$(date +%s)000000}}
EOF
)
    status=$(curl -s -o /dev/null -w '%{http_code}' \
      "${APM_LOCAL_URL}/intake/v2/events" \
      -H 'Content-Type: application/x-ndjson' \
      -H "Authorization: ApiKey ${APM_LOCAL_API_KEY}" --data-binary "${payload}
")
    assert_equals "202" "$status"
    attempt=0
    while [ "$attempt" -lt 60 ]; do
        if curl --fail -s -H "Authorization: ApiKey ${ES_LOCAL_API_KEY}" \
          "${ES_LOCAL_URL}/traces-apm*/_search?q=service.name:start-local-test" \
          | grep -q 'start-local-test-transaction'; then
            return
        fi
        attempt=$((attempt + 1))
        sleep 2
    done
    assert_equals "indexed transaction" "transaction not found after 120 seconds"
}
