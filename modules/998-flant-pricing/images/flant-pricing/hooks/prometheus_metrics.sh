#!/bin/bash -e

for f in $(find /frameworks/shell/ -type f -iname "*.sh"); do
  source $f
done

function __config__() {
  # NOTE: If you are changing crontab frequency - please change a time duration
  # in PromQL "ingress_nginx_overall_requests_total[20m]" in `rps_metrics()` below.
  cat << EOF
    configVersion: v1
    onStartup: 100
    schedule:
    - group: main
      queue: /modules/$(module::name::kebab_case)
      crontab: "*/20 * * * *"
EOF
}

# Makes query to prometheus and returns resulting json.
# $1 - promql
function prometheus_query() {
  curl_args=(-s --connect-timeout 10 --max-time 10 -k -XGET -G -k --cert /etc/ssl/prometheus-api-client-tls/tls.crt --key /etc/ssl/prometheus-api-client-tls/tls.key)
  prom_url="https://prometheus.d8-monitoring:9090/api/v1/query"
  if ! prom_result="$(curl "${curl_args[@]}" "${prom_url}" --data-urlencode "query=${1}")"; then
    prom_result=""
  fi
  echo "$prom_result"
}

# Return appropriate status from statuses array.
# $1 - statuses json array
function get_status() {
  statuses="$1"

  # Following map represents "restatusing" rules and priority of each status.
  status_map='{
    "error": "error",
    "absent": "missing",
    "missing": "missing",
    "destructively_changed": "destructively_changed",
    "changed": "changed",
    "excessive": "changed",
    "insufficient": "changed",
    "ok": "ok"
  }'

  # Get the first matching status.
  jq -r --argjson statuses "$statuses" '
    [. | to_entries[] | .key as $key | select($statuses[] | . == $key) | .value] | first // ""
    ' <<< "$status_map"
}

# Return cluster state status.
# $1 - prometheus json result
function get_cluster_status() {
  status="$(get_status "$(jq '[.data.result // [] | .[] | .metric.status]' <<< "$1")")"

  if [[ -z "$status" ]]; then
      status="missing"
  fi

  echo $status
}

# Return node group status.
# $1 - node group name
# $2, $3, $4 - prometheus json results
function get_node_group_status() {
  node_group_name="$1"
  prom_node_group_statuses="$2"
  prom_node_statuses="$3"
  prom_node_template_statuses="$4"

  node_group_status="$(get_status "$(jq --arg node_group_name "$node_group_name" '
    [.data.result // [] | .[] | select(.metric.name == $node_group_name) | .metric.status]
    ' <<< "$prom_node_group_statuses")")"

  node_status="$(get_status "$(jq --arg node_group_name "$node_group_name" '
    [.data.result // [] | .[] | select(.metric.node_group == $node_group_name) | .metric.status]
    ' <<< "$prom_node_statuses")")"

  node_template_status="$(get_status "$(jq --arg node_group_name "$node_group_name" '
    [.data.result // [] | .[] | select(.metric.name == $node_group_name) | .metric.status]
    ' <<< "$prom_node_template_statuses")")"

  status="$(get_status '["'$node_group_status'","'$node_status'","'$node_template_status'"]')"

  if [[ -z "$status" ]]; then
      status="missing"
  fi

  echo $status
}

function terraform_state_metrics() {
  summarized_metric_name="flant_pricing_terraform_state"
  node_group_metric_name="flant_pricing_terraform_state_node_group"
  group="group_terraform_state_metrics"
  jq -c --arg group "$group" '.group = $group' <<< '{"action":"expire"}' >> $METRICS_PATH

  state_cluster_status="none"
  state_master_status="none"
  state_terranode_status="none"

  if [[ "${FP_TERRAFORM_MANAGER_EBABLED}" == "true" ]]; then
    prom_cluster_status="$(prometheus_query 'max(candi_converge_cluster_status) by (status) == 1')"
    prom_node_group_statuses="$(prometheus_query 'max(candi_converge_node_group_status) by (name,status) == 1')"
    prom_node_statuses="$(prometheus_query 'max(candi_converge_node_status) by (name,node_group,status) == 1')"
    prom_node_template_statuses="$(prometheus_query 'max(candi_converge_node_template_status) by (name,status) == 1')"

    if [[ -z "$prom_cluster_status" || -z "$prom_node_group_statuses" || -z "$prom_node_statuses" || -z "$prom_node_template_statuses" ]]; then
      >&2 echo "ERROR: Crucial Prometheus queries failed. Skipping terraform_state metrics."
      return 0
    fi

    state_cluster_status="$(get_cluster_status "$prom_cluster_status")"
    state_master_status="missing"
    state_terranode_statuses="[]"

    for node_group_name in $(jq -r '.data.result[] | .metric.name' <<< "$prom_node_group_statuses"); do
      status="$(get_node_group_status "$node_group_name" "$prom_node_group_statuses" "$prom_node_statuses" "$prom_node_template_statuses")"
      if [[ "$node_group_name" == "master" ]]; then
        state_master_status="$status"
      else
        state_terranode_statuses="$(jq --arg status "$status" '. + [$status]' <<< "$state_terranode_statuses")"

        jq -nc --arg metric_name $node_group_metric_name --arg group "$group" \
          --arg node_group_name "$node_group_name" \
          --arg status "$status" '
          {
            "name": $metric_name,
            "group": $group,
            "set": '$(date +%s)',
            "labels": {
              "name": $node_group_name,
              "status": $status
            }
          }
          ' >> $METRICS_PATH
      fi
    done

    if [[ "$state_terranode_statuses" != "[]" ]]; then
      state_terranode_status="$(get_status "$state_terranode_statuses")"
    fi
  fi

  jq -nc --arg metric_name $summarized_metric_name --arg group "$group" \
    --arg state_cluster_status "$state_cluster_status" \
    --arg state_master_status "$state_master_status" \
    --arg state_terranode_status "$state_terranode_status" '
    {
      "name": $metric_name,
      "group": $group,
      "set": '$(date +%s)',
      "labels": {
        "cluster": $state_cluster_status,
        "master": $state_master_status,
        "terranode": $state_terranode_status
      }
    }
    ' >> $METRICS_PATH
}

function helm_releases_metrics() {
  helm_releases_metric_name="flant_pricing_helm_releases_count"
  group="group_helm_releases_metrics"
  jq -c --arg group "$group" '.group = $group' <<< '{"action":"expire"}' >> $METRICS_PATH

  prom_result="$(prometheus_query 'helm_releases_count')"
  if [[ ! -z "$prom_result" ]]; then
    jq --arg metric_name $helm_releases_metric_name --arg group "$group" '
      .data.result[] |
      {
        "name": $metric_name,
        "group": $group,
        "set": (.value[1] | tonumber),
        "labels": {
          "helm_version": .metric.helm_version
        }
      }
      ' <<< "$prom_result" >> $METRICS_PATH
  fi
}

function expire_resource_metrics() {
  group="group_resources_metrics"
  jq -c --arg group "$group" '.group = $group' <<< '{"action":"expire"}' >> $METRICS_PATH
}

# Output resource metric.
# $1 - resource kind
# $2 - prometheus json result
function output_resource_metric() {
  name="flant_pricing_resources_count"
  group="group_resources_metrics"

  value="$(jq -r '.data.result // [] | .[] | .value[1] // ""' <<< "$2")"

  if [[ "$value" == "" ]]; then
    >&2 echo "ERROR: Skipping empty value metric $name for resource Kind $1."
    return 0
  fi

  jq -n --arg name "$name" --arg group "$group" --argjson value "$value" --arg kind "$1" '
    {
      "name": $name,
      "group": $group,
      "set": $value,
      "labels": {
        "kind": $kind
      }
    }
    ' >> $METRICS_PATH
}

function resources_metrics() {
  expire_resource_metrics

  output_resource_metric "DaemonSet" "$(prometheus_query 'count(kube_controller_replicas{controller_type="DaemonSet"})')"
  output_resource_metric "Deployment" "$(prometheus_query 'count(kube_controller_replicas{controller_type="Deployment"})')"
  output_resource_metric "StatefulSet" "$(prometheus_query 'count(kube_controller_replicas{controller_type="StatefulSet"})')"

  output_resource_metric "Pod" "$(prometheus_query 'count(sum(kube_pod_container_status_ready) by (pod))')"
  output_resource_metric "Namespace" "$(prometheus_query 'count(kube_namespace_created)')"
  output_resource_metric "Service" "$(prometheus_query 'count(kube_service_created)')"
  output_resource_metric "Ingress" "$(prometheus_query 'count(kube_ingress_created)')"
}

function rps_metrics() {
  rps_metric_name="flant_pricing_ingress_nginx_controllers_rps"
  group="group_helm_rps_metrics"
  jq -c --arg group "$group" '.group = $group' <<< '{"action":"expire"}' >> $METRICS_PATH

  prom_result="$(prometheus_query 'sum(rate(ingress_nginx_overall_requests_total[20m])) or vector(0)')"
  if [[ ! -z "$prom_result" ]]; then
    jq --arg metric_name $rps_metric_name --arg group "$group" '.data.result[] |
      {
        "name": $metric_name,
        "group": $group,
        "set": (.value[1] | tonumber),
        "labels": {}
      }
      ' <<< "$prom_result" >> $METRICS_PATH
  fi
}

function __main__() {
  terraform_state_metrics
  helm_releases_metrics
  resources_metrics
  rps_metrics
}

hook::run "$@"
