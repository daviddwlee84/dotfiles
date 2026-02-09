# 36_pueue.zsh - pueue queue summary helpers

pqsum_use_color() {
    [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]
}

pqsum_progress_bar() {
    local -i pct width filled empty
    pct="${1:-0}"
    width="${2:-12}"

    (( pct < 0 )) && pct=0
    (( pct > 100 )) && pct=100

    filled=$((pct * width / 100))
    empty=$((width - filled))

    local filled_chunk empty_chunk
    filled_chunk="$(printf '%*s' "$filled" '' | tr ' ' '=')"
    empty_chunk="$(printf '%*s' "$empty" '' | tr ' ' '-')"
    printf '[%s%s]' "$filled_chunk" "$empty_chunk"
}

pqsum_align_table() {
    if command -v column &>/dev/null; then
        column -t -s $'\t'
    else
        sed $'s/\t/  /g'
    fi
}

# Summarize pueue status JSON into readable overall/group metrics.
pqsum() {
    local c_reset="" c_title="" c_warn="" c_err=""
    if pqsum_use_color; then
        c_reset=$'\033[0m'
        c_title=$'\033[1;36m'
        c_warn=$'\033[1;33m'
        c_err=$'\033[1;31m'
    fi

    if ! command -v pueue &>/dev/null; then
        printf '%s%s%s\n' "$c_err" "pqsum: pueue not found in PATH" "$c_reset" >&2
        return 127
    fi

    if ! command -v jq &>/dev/null; then
        printf '%s%s%s\n' "$c_err" "pqsum: jq not found in PATH" "$c_reset" >&2
        return 127
    fi

    local requested_group="" idx arg
    for ((idx = 1; idx <= $#; idx++)); do
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

    local pueue_json rc
    pueue_json="$(pueue status --json "$@")"
    rc=$?
    if (( rc != 0 )); then
        printf '%s%s%s\n' "$c_err" "pqsum: failed to query pueue status" "$c_reset" >&2
        return "$rc"
    fi

    local stats_json
    stats_json="$(jq -c --arg requested_group "$requested_group" '
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

        def fmt_pct($num):
          (($num * 10 | round) / 10 | tostring | if contains(".") then . else . + ".0" end) + "%";

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
        | ($done_durations | if length > 0 then (add / length) else null end) as $avg_done_sec
        | (pct($done; $total)) as $overall_pct
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
        | ($task_list | sort_by(task_status) | group_by(task_status)
            | map({
                status: (.[0] | task_status),
                count: length,
                pct_num: pct(length; $total),
                pct: fmt_pct(pct(length; $total))
              })
          ) as $status_rows
        | ($group_names | map(
            . as $group_name
            | ($task_list | map(select((.group // "default") == $group_name))) as $group_tasks
            | ($group_tasks | length) as $group_total
            | ($group_tasks | map(select(task_status == "Done")) | length) as $group_done
            | ($group_tasks | map(done_seconds) | map(select(. != null))) as $group_durations
            | ($group_durations | if length > 0 then (add / length) else null end) as $group_avg_sec
            | ($group_tasks | sort_by(task_status) | group_by(task_status) | map({key: (.[0] | task_status), value: length}) | from_entries) as $group_status_map
            | (pct($group_done; $group_total)) as $group_pct
            | {
                group: $group_name,
                daemon: ($groups[$group_name].status // "N/A"),
                parallel: ($groups[$group_name].parallel_tasks // "-"),
                total: $group_total,
                done: $group_done,
                pct_num: $group_pct,
                pct_int: ($group_pct | round),
                pct: fmt_pct($group_pct),
                avg_done: ($group_avg_sec | fmt_duration),
                statuses: ($group_status_map | status_map_to_string)
              }
          )) as $group_rows
        | {
            overall: {
              total: $total,
              done: $done,
              progress_pct_num: $overall_pct,
              progress_pct_int: ($overall_pct | round),
              progress_pct: fmt_pct($overall_pct),
              avg_done: ($avg_done_sec | fmt_duration)
            },
            status_rows: $status_rows,
            group_rows: $group_rows
          }
    ' <<< "$pueue_json")"
    rc=$?
    if (( rc != 0 )); then
        printf '%s%s%s\n' "$c_err" "pqsum: failed to summarize status JSON" "$c_reset" >&2
        return "$rc"
    fi

    if ! command -v column &>/dev/null; then
        printf '%s%s%s\n' "$c_warn" "pqsum: 'column' not found, using plain spacing fallback." "$c_reset" >&2
    fi

    local overall_total overall_done overall_pct overall_pct_int overall_avg overall_bar
    overall_total="$(jq -r '.overall.total' <<< "$stats_json")"
    overall_done="$(jq -r '.overall.done' <<< "$stats_json")"
    overall_pct="$(jq -r '.overall.progress_pct' <<< "$stats_json")"
    overall_pct_int="$(jq -r '.overall.progress_pct_int' <<< "$stats_json")"
    overall_avg="$(jq -r '.overall.avg_done' <<< "$stats_json")"
    overall_bar="$(pqsum_progress_bar "$overall_pct_int")"

    printf '%sPueue Summary%s\n' "$c_title" "$c_reset"
    printf '%sOverall%s\n' "$c_title" "$c_reset"
    printf '  Total tasks: %s\n' "$overall_total"
    printf '  Done progress: %s/%s  %s  %s\n' "$overall_done" "$overall_total" "$overall_bar" "$overall_pct"
    printf '  Avg done duration: %s\n' "$overall_avg"

    printf '\n%sStatus Breakdown%s\n' "$c_title" "$c_reset"
    local status_count
    status_count="$(jq -r '.status_rows | length' <<< "$stats_json")"
    if (( status_count == 0 )); then
        printf '  -\n'
    else
        {
            printf 'status\tcount\tprogress\n'
            jq -r '.status_rows[] | "\(.status)\t\(.count)\t\(.pct)"' <<< "$stats_json"
        } | pqsum_align_table | sed 's/^/  /'
    fi

    printf '\n%sGroup Summary%s\n' "$c_title" "$c_reset"
    local group_count
    group_count="$(jq -r '.group_rows | length' <<< "$stats_json")"
    if (( group_count == 0 )); then
        printf '  -\n'
    else
        {
            printf 'group\tdaemon\tparallel\ttotal\tdone\tprogress\tbar\tavg_done\tstatuses\n'
            while IFS=$'\t' read -r group daemon parallel total done pct pct_int avg_done statuses; do
                printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                    "$group" \
                    "$daemon" \
                    "$parallel" \
                    "$total" \
                    "$done" \
                    "$pct" \
                    "$(pqsum_progress_bar "$pct_int")" \
                    "$avg_done" \
                    "$statuses"
            done < <(
                jq -r '.group_rows[] | "\(.group)\t\(.daemon)\t\(.parallel)\t\(.total)\t\(.done)\t\(.pct)\t\(.pct_int)\t\(.avg_done)\t\(.statuses)"' <<< "$stats_json"
            )
        } | pqsum_align_table | sed 's/^/  /'
    fi
}
