#!/bin/bash

# Copyright 2017 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -exu
cd $(dirname $0)

GCS_BUCKET=${GCS_BUCKET:-"k8s-gubernator/triage"}
BQ_DATASET=${BQ_DATASET:-"k8s-gubernator:build"}
GCLOUD_PROJECT=${GCLOUD_PROJECT:-"k8s-gubernator"}

if [[ -e ${GOOGLE_APPLICATION_CREDENTIALS-} ]]; then
  gcloud auth activate-service-account --key-file="${GOOGLE_APPLICATION_CREDENTIALS}"
  gcloud config set project ${GCLOUD_PROJECT}
  bq show <<< $'\n'
fi

date
# cat << '#'
table_mtime=$(bq --format=json show "${BQ_DATASET}.week" | jq -r '(.lastModifiedTime|tonumber)/1000|floor' )
if [[ ! -e triage_builds.json ]] || [ $(stat -c%Y triage_builds.json) -lt $table_mtime ]; then
  echo "UPDATING" $table_mtime
  bq --headless --format=json query -n 1000000 "select path, timestamp_to_sec(started) started, elapsed, tests_run, tests_failed, result, executor, job, number from [${BQ_DATASET}.week]" > triage_builds.json
  bq --headless --format=json query -n 10000000 "select path build, test.name name, test.failure_text failure_text from [${BQ_DATASET}.week] where test.failed" > triage_tests.json
  rm -f failed*.json
fi
#

previous_arg=""
if gsutil cp gs://${GCS_BUCKET}/failure_data.json failure_data_previous.json ; then
  previous_arg="--previous failure_data_previous.json"
else
  echo "no previous failure data found"
fi
curl -sO --retry 6 https://raw.githubusercontent.com/kubernetes/kubernetes/master/test/test_owners.json

mkdir -p slices

pypy summarize.py triage_builds.json triage_tests.json \
  ${previous_arg} --owners test_owners.json \
  --output failure_data.json --output_slices slices/failure_data_PREFIX.json

gsutil_cp() {
  gsutil -h 'Cache-Control: no-store, must-revalidate' -m cp -Z -a public-read "$@"
}

gsutil_cp failure_data.json gs://${GCS_BUCKET}/
gsutil_cp slices/*.json gs://${GCS_BUCKET}/slices/
gsutil_cp failure_data.json "gs://${GCS_BUCKET}/history/$(date -u +%Y%m%d).json"
