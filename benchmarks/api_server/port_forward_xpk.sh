# Copyright 2023–2025 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

#!/bin/bash
#
# This script automates finding the correct pod in a MaxText server workload
# and establishes a port-forward connection to it.
#
# Usage:
# bash port_forward_xpk.sh job_name=<job_name> project=<project> zone=<zone> cluster=<cluster> [namespace=<namespace>]

set -euo pipefail # Added pipefail to catch errors in pipelines

# --- Argument Parsing ---
NAMESPACE="default" # Default namespace

# Initialize variables to avoid unbound errors
JOB_NAME=""
PROJECT=""
ZONE=""
CLUSTER=""

while [ $# -gt 0 ]; do
  case "$1" in
    job_name=*)
      JOB_NAME="${1#*=}"
      ;;
    project=*)
      PROJECT="${1#*=}"
      ;;
    zone=*)
      ZONE="${1#*=}"
      ;;
    cluster=*)
      CLUSTER="${1#*=}"
      ;;
    namespace=*)
      NAMESPACE="${1#*=}"
      ;;
    *)
      echo "Warning: Unknown argument $1"
      ;;
  esac
  shift
done

# --- Validate Arguments ---
if [ -z "$JOB_NAME" ] || [ -z "$PROJECT" ] || [ -z "$ZONE" ] || [ -z "$CLUSTER" ]; then
    echo "Usage: $0 job_name=<job_name> project=<project> zone=<zone> cluster=<cluster> [namespace=<namespace>]" >&2
    exit 1
fi

echo "--- Configuration ---"
echo "Project:   $PROJECT"
echo "Zone:      $ZONE"
echo "Cluster:   $CLUSTER"
echo "Job Name:  $JOB_NAME"
echo "Namespace: $NAMESPACE"
echo "---------------------"

# --- Get GKE Credentials ---
echo "Fetching cluster credentials..."
gcloud container clusters get-credentials "$CLUSTER" --zone "$ZONE" --project "$PROJECT" > /dev/null

# --- Find the Server Pod ---
echo "Searching for pods in namespace '$NAMESPACE' matching job '$JOB_NAME'..."

# Initialize PODS array to prevent unbound variable error
PODS=()

# Method 1: Try finding by standard Kubernetes Job label
# using ( ... ) syntax safely captures the output into an array
PODS=($(kubectl get pods -n "$NAMESPACE" -l "job-name=$JOB_NAME" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true))

# Method 2: Fallback - sometimes XPK/Kueue uses different labels, so we search by name prefix if Method 1 returned nothing
if [ ${#PODS[@]} -eq 0 ]; then
    echo "No pods found with label 'job-name=$JOB_NAME'. Trying to match by pod name..."
    # Fetch all pods and grep for the job name
    PODS=($(kubectl get pods -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep "$JOB_NAME" || true))
fi

# Check if we still have no pods
if [ ${#PODS[@]} -eq 0 ]; then
    echo "Error: No pods found for job name '$JOB_NAME' in namespace '$NAMESPACE' (checked labels and name match)."
    exit 1
fi

echo "Found candidate pods: ${PODS[*]}"

SERVER_POD=""
for pod in "${PODS[@]}"; do
    echo "Checking logs for pod: $pod..."
    # We use '|| true' to prevent script exit if grep fails (not found)
    if kubectl logs "$pod" -n "$NAMESPACE" --tail=100 2>/dev/null | grep -q "Uvicorn running on http://0.0.0.0:8000"; then
        echo "✅ Found server running in pod: $pod"
        SERVER_POD=$pod
        break 
    else
        echo "❌ Uvicorn not detected in this pod."
    fi
done

# --- Establish Port Forwarding ---
if [ -n "$SERVER_POD" ]; then
    echo "Establishing port-forward from localhost:8000 to $SERVER_POD:8000 in namespace '$NAMESPACE'..."
    echo "You can now send requests to http://localhost:8000"
    
    # Exec into kubectl port-forward
    kubectl port-forward "pod/$SERVER_POD" -n "$NAMESPACE" 8000:8000
else
    echo "Error: Could not find a pod running the Uvicorn server for job '$JOB_NAME' in namespace '$NAMESPACE'."
    echo "Please check if the server has fully started."
    exit 1
fi
