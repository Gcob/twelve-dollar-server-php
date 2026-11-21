#!/usr/bin/env bash
# Times the cases of a bench file in the lab images, JIT on and off, one image at a time (lab/run.sh: 1 CPU, 2 GiB).
#
#   bash lab/micro.sh lab/micro/benches/sample.php [--images 8.4,8.5] [--jit on|off|both] [--out <path>]
#                     [--quick] [--jit-buffer-size 64M]
#
# Prints one row per case and writes the numbers, with where they ran, to a JSON file (default:
# lab/results/micro-<bench>-<UTC date and time>.json). --quick is for smoke checks: short timing, not a result.
# Exits non-zero on a bad argument, a missing image, or a JIT state that is not the one requested.
set -euo pipefail

LAB="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$LAB")"
# shellcheck source=lib.sh
source "$LAB/lib.sh"

usage() { echo "usage: lab/micro.sh <bench-file> [--images a,b,...] [--jit on|off|both] [--out <path>] [--quick] [--jit-buffer-size 64M]" >&2; exit 1; }

command_line="lab/micro.sh $*"
command_line="${command_line//$REPO/.}"

bench="" images=("${LAB_VARIANTS[@]}") jit=both out="" quick="" jit_buffer=64M
while [ "$#" -gt 0 ]; do
  case "$1" in
    --images) [ "$#" -ge 2 ] || usage; IFS=, read -r -a images <<<"$2"; shift 2 ;;
    --jit) [ "$#" -ge 2 ] || usage; jit="$2"; shift 2 ;;
    --out) [ "$#" -ge 2 ] || usage; out="$2"; shift 2 ;;
    --jit-buffer-size) [ "$#" -ge 2 ] || usage; jit_buffer="$2"; shift 2 ;;
    --quick) quick=1; shift ;;
    -*) echo "unknown option: $1" >&2; usage ;;
    *) [ -z "$bench" ] || usage; bench="$1"; shift ;;
  esac
done
[ -n "$bench" ] || usage
case "$jit" in on) jit_states=(on) ;; off) jit_states=(off) ;; both) jit_states=(off on) ;; *) echo "--jit must be on, off or both" >&2; usage ;; esac

# Everything is checked before the first container starts.
[ "${#images[@]}" -gt 0 ] || usage
for v in "${images[@]}"; do
  lab_require_variant "$v" || exit 1
  docker image inspect "$LAB_IMAGE:$v" >/dev/null 2>&1 || { echo "image $LAB_IMAGE:$v is missing (run lab/build.sh $v)" >&2; exit 1; }
done
[ -f "$bench" ] || { echo "bench file not found: $bench" >&2; exit 1; }
bench_abs="$(cd "$(dirname "$bench")" && pwd)/$(basename "$bench")"
case "$bench_abs" in
  "$LAB"/*) bench_in_container="/lab/${bench_abs#"$LAB"/}" ;;
  *) echo "the bench file must be under lab/ (it is mounted in the container): $bench" >&2; exit 1 ;;
esac

stamp="$(date -u +%Y%m%d-%H%M)"
if [ -z "$out" ]; then
  name="$(basename "$bench" .php)"
  out="$LAB/results/micro-$name${quick:+-quick}-$stamp.json"
fi
mkdir -p "$LAB/results" "$(dirname "$out")"

tmp="$LAB/results/.micro-$$"
mkdir -p "$tmp"
trap 'rm -rf "$tmp"' EXIT

json_escape() { sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

first=1 run_files=()
for v in "${images[@]}"; do
  image_id="$(docker image inspect -f '{{.Id}}' "$LAB_IMAGE:$v")"
  for state in "${jit_states[@]}"; do
    run_json="/lab/results/.micro-$$/$v-$state.json"
    args=("$bench_in_container" --image "$v" --image-id "$image_id" --jit "$state" --jit-buffer-size "$jit_buffer" --out "$run_json")
    [ -z "$quick" ] || args+=(--quick)
    [ -z "$first" ] || args+=(--header)
    first=""
    bash "$LAB/run.sh" "$v" php "/lab/micro/micro.php" "${args[@]}"
    run_files+=("$tmp/$v-$state.json")
  done
done

{
  printf '{\n"date": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '"command": "%s",\n' "$(printf '%s' "$command_line" | json_escape)"
  printf '"bench": "%s",\n' "${bench_in_container#/lab/}"
  printf '"host": {"docker": "%s", "arch": "%s", "cpuset": "%s", "limits": "%s"},\n' \
    "$(docker version --format '{{.Server.Platform.Name}}' | json_escape)" "$(uname -m)" "$LAB_CPUSET_SERVER" "${LAB_RESOURCE_FLAGS[*]}"
  printf '"runs": [\n'
  sep=""
  for f in "${run_files[@]}"; do printf '%s' "$sep"; cat "$f"; sep=","; done
  printf ']\n}\n'
} >"$out"
echo "wrote ${out#"$REPO"/}"
