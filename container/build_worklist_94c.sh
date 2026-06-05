#!/bin/bash
# Build the 94c run worklist consumed by batch_94c.sh: one line
#   "ED-VID.seq  run  Ytape1,Ytape2,..."
# per raw segment that is (a) staged on disk and (b) has matching official
# short DST(s). The 3rd column is the COMMA-JOINED set of ALL .al tapes the
# run touches.
#
# IMPORTANT: a run's official short-DST events are split across SEVERAL .al
# tape files (short94_c2.vidmap lists several lines per run, interleaved by
# event-number range, e.g. run 44393 -> Y13709.41 AND Y13709.42). Keeping the
# full tape set is what lets batch_94c.sh's pass2 union-index every event; an
# earlier version kept only one tape per run, so any raw segment whose events
# lived in a dropped tape matched 0 events and produced an empty (metadata-only)
# file.
set -uo pipefail

ROOT=/home/sqian/scratch/datareco/batch94c; mkdir -p "$ROOT"
RUNINFO=/cvmfs/delphi.cern.ch/releases/almalinux-9-x86_64/latest/evserv/RunInfo
RAWD=/eos/experiment/delphi/castor2015/rawd

# run -> COMMA-JOINED set of unique official .al tapes (all tapes the run touches)
awk '/^ *[0-9]/{r=$1; t=$NF; if(!(r SUBSEP t in s)){s[r SUBSEP t]=1; tp[r]=tp[r]","t}}
     END{for(r in tp){sub(/^,/,"",tp[r]); print r, tp[r]}}' \
     "$RUNINFO/short94_c2.vidmap" | sort -k1,1 > "$ROOT/run_tapes.map"

# run -> raw ED-VID.seq, joined on run, reordered to key on raw -> "ED-seq run tapes"
join -1 1 -2 1 \
  <(awk '/^ *[0-9]/{print $1, $NF}' "$RUNINFO/rawd94" | sort -u -k1,1) \
  "$ROOT/run_tapes.map" \
  2>/dev/null | awk '{print $2, $1, $3}' | sort -u > "$ROOT/raw_run_al.map"

# keep only raw segments actually present on disk
ls "$RAWD"/y94/ED*/*.sl 2>/dev/null | sed 's#.*/##; s#\.sl$##' | sort -u > "$ROOT/staged_raw.list"
join "$ROOT/staged_raw.list" "$ROOT/raw_run_al.map" > "$ROOT/worklist.txt"

echo "worklist: $(wc -l < "$ROOT/worklist.txt") segments ; unique .al tapes = $(awk '{n=split($3,a,","); for(i=1;i<=n;i++)print a[i]}' "$ROOT/worklist.txt" | sort -u | wc -l) ; multi-tape segments = $(awk '$3 ~ /,/' "$ROOT/worklist.txt" | wc -l)  -> $ROOT/worklist.txt"
