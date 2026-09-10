#!/usr/bin/env bash

# Convert a local or FATMEN-resolved DELPHI shortDST with delphiRun.

set -euo pipefail

usage() {
  cat <<'EOF'
usage: convert_to_edm4hep.sh [options] (--input FILE | --nickname NAME | --pdl FILE) --output FILE

Input (exactly one):
  --input FILE       local shortDST, including simulation produced here
  --nickname NAME    FATMEN dataset nickname resolved by PHDST/fatfind
  --pdl FILE         prebuilt PDLINPUT file, for example from fatfind

Options:
  --output FILE      output EDM4hep ROOT file
  --edmbin DIR       directory containing delphiRun and delphi_btag_check
                     (default: $DELPHI_EDM4HEP_BIN, or ../delphi-edm4hep-upstream-dev/build)
  --config FILE      delphiRun Python configuration
                     (default: steering/delphi_convert_cfg.py)
  --sample data|mc   checker run-sign contract (default: mc)
  -n, --max-events N
  --no-check         skip delphi_btag_check
  -h, --help

The native Code4hep source recalculates AABTAG by default and also preserves
the stored BTG payload for comparison. There is no --btag mode in this
interface.
EOF
}

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEFAULT_EDMBIN="$HERE/../delphi-edm4hep-upstream-dev/build"
EDMBIN=${DELPHI_EDM4HEP_BIN:-$DEFAULT_EDMBIN}
CONFIG=${DELPHI_RUN_CONFIG:-$HERE/steering/delphi_convert_cfg.py}
INPUT_MODE=
INPUT_VALUE=
OUTPUT=
SAMPLE=mc
MAX_EVENTS=
RUN_CHECK=1

set_input() {
  local mode=$1 value=$2
  if [[ -n $INPUT_MODE ]]; then
    echo "error: only one of --input, --nickname, and --pdl may be given" >&2
    exit 2
  fi
  INPUT_MODE=$mode
  INPUT_VALUE=$value
}

while (($#)); do
  case $1 in
    --input|--nickname|--pdl)
      (($# >= 2)) || { echo "error: $1 requires a value" >&2; exit 2; }
      set_input "${1#--}" "$2"
      shift 2
      ;;
    --output)
      (($# >= 2)) || { echo "error: --output requires a value" >&2; exit 2; }
      OUTPUT=$2
      shift 2
      ;;
    --edmbin)
      (($# >= 2)) || { echo "error: --edmbin requires a value" >&2; exit 2; }
      EDMBIN=$2
      shift 2
      ;;
    --config)
      (($# >= 2)) || { echo "error: --config requires a value" >&2; exit 2; }
      CONFIG=$2
      shift 2
      ;;
    --sample)
      (($# >= 2)) || { echo "error: --sample requires data or mc" >&2; exit 2; }
      SAMPLE=$2
      shift 2
      ;;
    -n|--max-events)
      (($# >= 2)) || { echo "error: $1 requires a value" >&2; exit 2; }
      MAX_EVENTS=$2
      shift 2
      ;;
    --no-check)
      RUN_CHECK=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n $INPUT_MODE ]] || { echo "error: an input is required" >&2; exit 2; }
[[ -n $OUTPUT ]] || { echo "error: --output is required" >&2; exit 2; }
[[ $SAMPLE == data || $SAMPLE == mc ]] || {
  echo "error: --sample must be data or mc" >&2
  exit 2
}
[[ -z $MAX_EVENTS || $MAX_EVENTS =~ ^[1-9][0-9]*$ ]] || {
  echo "error: --max-events must be a positive integer" >&2
  exit 2
}

CONVERTER="$EDMBIN/delphiRun"
CHECKER="$EDMBIN/delphi_btag_check"
[[ -x $CONVERTER ]] || { echo "error: launcher is not executable: $CONVERTER" >&2; exit 1; }
[[ -s $CONFIG && -f $CONFIG ]] || { echo "error: configuration is not a nonempty regular file: $CONFIG" >&2; exit 1; }
if ((RUN_CHECK)); then
  [[ -x $CHECKER ]] || { echo "error: checker is not executable: $CHECKER" >&2; exit 1; }
fi

case $INPUT_MODE in
  input)
    [[ -s $INPUT_VALUE && -f $INPUT_VALUE ]] || {
      echo "error: local input is not a nonempty regular file: $INPUT_VALUE" >&2
      exit 1
    }
    INPUT_VALUE=$(realpath "$INPUT_VALUE")
    ;;
  nickname)
    [[ -n $INPUT_VALUE ]] || { echo "error: nickname is empty" >&2; exit 2; }
    ;;
  pdl)
    [[ -s $INPUT_VALUE && -f $INPUT_VALUE ]] || {
      echo "error: PDL input is not a nonempty regular file: $INPUT_VALUE" >&2
      exit 1
    }
    INPUT_VALUE=$(realpath "$INPUT_VALUE")
    ;;
esac

mkdir -p "$(dirname "$OUTPUT")"
OUTPUT_DIR=$(cd "$(dirname "$OUTPUT")" && pwd)
OUTPUT="$OUTPUT_DIR/$(basename "$OUTPUT")"
CONVERTER=$(realpath "$CONVERTER")
CONFIG=$(realpath "$CONFIG")

export DELPHI_INPUT="$INPUT_VALUE"
export DELPHI_INPUT_MODE="$INPUT_MODE"
[[ $DELPHI_INPUT_MODE == input ]] && export DELPHI_INPUT_MODE=file
export DELPHI_OUTPUT="$OUTPUT"
export DELPHI_CONVERSION_PASS=sdst
export DELPHI_IS_REAL_DATA=false
[[ $SAMPLE == data ]] && export DELPHI_IS_REAL_DATA=true
export DELPHI_MAX_EVENTS=${MAX_EVENTS:--1}

RUNTIME_DIR=$(mktemp -d "${TMPDIR:-/tmp}/delphiRun.XXXXXX")
trap 'rm -rf "$RUNTIME_DIR"' EXIT
COMMAND=("$CONVERTER" "$CONFIG")

printf 'Running:'
printf ' %q' "${COMMAND[@]}"
printf '\n'
(
  cd "$RUNTIME_DIR"
  "${COMMAND[@]}"
)

[[ -s $OUTPUT && -f $OUTPUT ]] || {
  echo "error: converter did not produce a nonempty regular file: $OUTPUT" >&2
  exit 1
}

if ((RUN_CHECK)); then
  "$CHECKER" --source sDST "$OUTPUT" "$SAMPLE"
fi

echo "EDM4hep output: $OUTPUT"
