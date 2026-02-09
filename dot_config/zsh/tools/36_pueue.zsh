# 36_pueue.zsh - pueue queue summary helpers

# Summarize pueue status JSON into overall/group metrics.
pqsum() {
    if ! command -v pueue &>/dev/null; then
        echo "pqsum: pueue not found in PATH" >&2
        return 127
    fi

    if ! command -v jq &>/dev/null; then
        echo "pqsum: jq not found in PATH" >&2
        return 127
    fi

    local requested_group="" idx arg pueue_json rc
    for (( idx = 1; idx <= $#; idx++ )); do
        arg="${@[$idx]}"
        case "$arg" in
            -g|--group)
                if (( idx < $# )); then
                    requested_group="${@[$((idx + 1))]}"
                fi
                ;;
            --group=*)
                requested_group="${arg#--group=}"
                ;;
        esac
    done

    pueue_json="$(pueue status --json "$@")"
    rc=$?
    if (( rc != 0 )); then
        echo "pqsum: failed to query pueue status" >&2
        return "$rc"
    fi

    jq -r --arg requested_group "$requested_group" '
        def task_status:
          .status | keys[0];

        def normalize_ts:
          sub("\\.[0-9]+"; "") as $ts
          | if ($ts | test("Z$")) then
              ($ts | sub("Z$"; "+0000"))
            elif ($ts | test("[+-][0-9]{2}:[0-9]{2}$")) then
              ($ts | capture("(?<prefix>.*)(?<h>[+-][0-9]{2}):(?<m>[0-9]{2})$") | "\(.prefix)\(.h)\(.m)")
            else
              $ts
            end;

        def to_epoch:
          normalize_ts
          | strptime("%Y-%m-%dT%H:%M:%S%z")
          | mktime;

        def done_seconds:
          if (.status | has("Done")) and (.status.Done.start != null) and (.status.Done.end != null) then
            ((.status.Done.end | to_epoch) - (.status.Done.start | to_epoch))
          else
            null
          end;

        def pct($part; $total):
          if $total > 0 then ($part * 100 / $total) else 0 end;

        def fmt_pct:
          ((. * 10 | round) / 10 | tostring | if contains(".") then . else . + ".0" end) + "%";

        def fmt_duration:
          if . == null then
            "-"
          else
            (. | floor) as $s
            | if $s < 60 then
                "\($s)s"
              elif $s < 3600 then
                "\(($s / 60 | floor))m \(($s % 60) | floor)s"
              else
                "\(($s / 3600 | floor))h \(((($s % 3600) / 60) | floor))m \(($s % 60) | floor)s"
              end
          end;

        def status_map_to_string:
          if (length == 0) then
            "-"
          else
            (to_entries | sort_by(.key) | map("\(.key)=\(.value)") | join(", "))
          end;

        (.tasks // {} | with_entries(.value |= del(.envs))) as $tasks
        | (.groups // {}) as $groups
        | ($tasks | to_entries | map(.value)) as $task_list
        | ($task_list | length) as $total
        | ($task_list | map(select(task_status == "Done")) | length) as $done
        | ($task_list | map(done_seconds) | map(select(. != null))) as $done_durations
        | ($done_durations | if length > 0 then (add / length) else null end) as $avg_done
        | ($task_list | sort_by(task_status) | group_by(task_status) | map({status: (.[0] | task_status), count: length})) as $status_counts
        | (
            if $requested_group != "" then
              if ($groups | has($requested_group)) or ($task_list | any((.group // "default") == $requested_group)) then
                [$requested_group]
              else
                []
              end
            else
              ((($groups | keys_unsorted) + ($task_list | map(.group // "default"))) | unique | sort)
            end
          ) as $group_names
        | (if ($status_counts | length) > 0 then
            ($status_counts | map("  \(.status): \(.count) (\((pct(.count; $total) | fmt_pct)))"))
          else
            ["  -"]
          end) as $status_lines
        | ($group_names | map(
            . as $group_name
            | ($task_list | map(select((.group // "default") == $group_name))) as $group_tasks
            | ($group_tasks | length) as $group_total
            | ($group_tasks | map(select(task_status == "Done")) | length) as $group_done
            | ($group_tasks | map(done_seconds) | map(select(. != null))) as $group_durations
            | ($group_durations | if length > 0 then (add / length) else null end) as $group_avg
            | ($group_tasks | sort_by(task_status) | group_by(task_status) | map({key: (.[0] | task_status), value: length}) | from_entries) as $group_status_map
            | "  \($group_name) | \($groups[$group_name].status // "N/A") | \($groups[$group_name].parallel_tasks // "-") | \($group_total) | \($group_done) | \((pct($group_done; $group_total) | fmt_pct)) | \($group_avg | fmt_duration) | \($group_status_map | status_map_to_string)"
          )) as $group_lines
        | (
            [
              "Pueue Summary",
              "Overall",
              "  Total tasks: \($total)",
              "  Done progress: \($done)/\($total) (\((pct($done; $total) | fmt_pct)))",
              "  Avg done duration: \($avg_done | fmt_duration)",
              "",
              "Status Breakdown"
            ]
            + $status_lines
            + [
              "",
              "Group Summary",
              "  group | daemon | parallel | total | done | progress | avg_done | statuses"
            ]
            + (if ($group_lines | length) > 0 then $group_lines else ["  -"] end)
          )
        | .[]
    ' <<< "$pueue_json"
}
