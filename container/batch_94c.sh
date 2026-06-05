#!/bin/bash
# Large-scale 94c data -> EDM4hep batch. Resumable + parallel.
#   Phase A: for each unique official .al, pass1 -> cached intermediate (398 of them).
#   Phase B: per run: raw .sl -> DELANA full DST (MBLIMI raised) -> pass2 with the
#            cached intermediate -> EDM4hep; delete the full DST. Skip if done.
#
# Usage: batch_94c.sh <N runs from worklist | all> [<n_parallel>]
set -uo pipefail

ROOT=/home/sqian/scratch/datareco/batch94c
WORKLIST=$ROOT/worklist.txt
INT=$ROOT/intermediates      # cached pass1 outputs (keyed by Y-VID.seq)
EDM=$ROOT/edm4hep            # final per-run EDM4hep (the product)
SCR=$ROOT/scratch            # transient full DSTs / .al copies
LOG=$ROOT/logs
mkdir -p "$INT" "$EDM" "$SCR" "$LOG"

N=${1:-30}; PAR=${2:-6}
[ "$N" = all ] && N=$(wc -l < "$WORKLIST")

IMAGE=/home/sqian/Codes/ee_Z_tatagamma/images/cmssw-el9.sif
EDMBIN=/home/sqian/Codes/ee_Z_tatagamma/_wt-pr1-refactor/delphi_edm4hep/build
RECO=/home/sqian/Codes/ee_Z_tatagamma/Delphi-Sim-Pipeline/container/run_data_reco.sh
RAWBASE=/eos/experiment/delphi/castor2015/rawd/y94
ALBASE=/eos/experiment/delphi/castor2015/tape

head -n "$N" "$WORKLIST" > "$ROOT/worklist.run"

# ---------- Phase A: build cached pass1 intermediates for the needed .al ----------
awk '{n=split($3,a,","); for(i=1;i<=n;i++) print a[i]}' "$ROOT/worklist.run" | sort -u > "$ROOT/al.run"
echo "=== Phase A: $(wc -l < "$ROOT/al.run") unique .al -> intermediates (par=$PAR) ==="
build_intermediate () {
  local alseq=$1                       # e.g. Y13709.41
  local out=$INT/inter_${alseq}.root
  [ -f "$out" ] && { echo "skip $alseq (cached)"; return; }
  local yvid=${alseq%%.*}
  local al=$ALBASE/$yvid/$alseq.al
  [ -f "$al" ] || { echo "MISSING al $al"; return; }
  local w=$SCR/A_$alseq; mkdir -p "$w"; cp "$al" "$w/in.al"
  singularity exec --cleanenv --bind /cvmfs --bind /lib64:/host_lib64:ro \
    --bind "$w:$w" --bind "$INT:$INT" --bind "$EDMBIN:/edmbin:ro" "$IMAGE" bash -c "
      set +u; source /cvmfs/delphi.cern.ch/setup.sh >/dev/null 2>&1
      source /cvmfs/sw.hsf.org/key4hep/setup.sh -r 2026-04-08 >/dev/null 2>&1
      export LD_LIBRARY_PATH=\$LD_LIBRARY_PATH:/host_lib64; cd $w
      /edmbin/delphi_sdst_pass in.al $out -n 20000" > "$LOG/A_$alseq.log" 2>&1 \
    && echo "OK $alseq" || echo "FAIL $alseq"
  rm -rf "$w"
}
export -f build_intermediate; export INT SCR ALBASE EDMBIN IMAGE LOG
cat "$ROOT/al.run" | xargs -P "$PAR" -I{} bash -c 'build_intermediate "$@"' _ {}

# ---------- Phase B: per run reco + pass2 -> EDM4hep ----------
echo "=== Phase B: $N runs -> EDM4hep (par=$PAR) ==="
do_run () {
  local edseq=$1 run=$2 altapes=$3      # ED0151.18 44249 Y13709.41,Y13709.42
  local out=$EDM/run${run}_${edseq}.edm4hep.root
  [ -f "$out" ] && { echo "skip run$run (done)"; return; }
  # A run's official short-DST events are split across several .al tapes -> pass
  # the UNION of their intermediates to pass2, else segments whose events live in
  # a non-listed tape match 0 and write an empty (metadata-only) file. (Requires
  # delphi_fdst_pass built with comma-separated-intermediate support, pr-1.)
  local inter="" t
  for t in ${altapes//,/ }; do
    [ -f "$INT/inter_${t}.root" ] || { echo "no intermediate for run$run ($t)"; return; }
    inter="$inter,$INT/inter_${t}.root"
  done
  inter=${inter#,}
  local vid=${edseq%%.*}
  local raw=$RAWBASE/$vid/$edseq.sl
  [ -f "$raw" ] || { echo "MISSING raw $raw"; return; }
  local tag=${edseq//./_}                # unique per segment (run may span many)
  local w=$SCR/B_${tag}; rm -rf "$w"; mkdir -p "$w"
  # 1. reco -> full DST
  RECO_TIMEOUT=600 MBLIMI=4000 SHORTDST=0 IMAGE=$IMAGE "$RECO" "$raw" "b$tag" "$w" 4000 94c > "$LOG/B_${tag}_reco.log" 2>&1
  local dst=$w/b${tag}_delana.dst
  [ -f "$dst" ] || { echo "FAIL reco run$run ($edseq)"; rm -rf "$w"; return; }
  # 2. pass2 -> EDM4hep
  singularity exec --cleanenv --bind /cvmfs --bind /lib64:/host_lib64:ro \
    --bind "$w:$w" --bind "$INT:$INT" --bind "$EDM:$EDM" --bind "$EDMBIN:/edmbin:ro" "$IMAGE" bash -c "
      set +u; source /cvmfs/delphi.cern.ch/setup.sh >/dev/null 2>&1
      source /cvmfs/sw.hsf.org/key4hep/setup.sh -r 2026-04-08 >/dev/null 2>&1
      export LD_LIBRARY_PATH=\$LD_LIBRARY_PATH:/host_lib64; cd $w
      /edmbin/delphi_fdst_pass $inter $dst $out -n 20000" > "$LOG/B_${tag}_pass2.log" 2>&1 \
    && echo "OK run$run ($edseq)" || echo "FAIL pass2 run$run ($edseq)"
  rm -rf "$w"                            # delete the 544MB full DST + scratch
}
export -f do_run; export EDM INT SCR RAWBASE RECO IMAGE EDMBIN LOG
cat "$ROOT/worklist.run" | xargs -P "$PAR" -L1 bash -c 'do_run "$@"' _

echo "=== BATCH DONE: $(ls "$EDM"/*.edm4hep.root 2>/dev/null | wc -l) EDM4hep files in $EDM ==="
du -sh "$EDM" 2>/dev/null
