#!/bin/bash
# Reconstruct DELPHI *real raw data* -> full DST (-> short DST), locally in the
# cmssw/el9 singularity container backed by CVMFS. This is the data-side twin of
# run_singularity.sh: instead of Pythia->DELSIM producing simulated raw, we feed
# real detector raw (.sl) straight into DELANA.
#
# It is a faithful local replica of the official `des -m delana -e RUN:EVT`
# server path (see RunDelana() in $DELPHI/scripts/des):
#   1. ddbass  -> symlink the 7 DELPHI condition-DB files to FOR050..056
#   2. title   -> cards43_94c.tit (period reco cards; already ALLOUT TRUE = full DST)
#   3. dinp01  -> raw input .sl ; dout01 -> output DST ; title -> fort.29
#   4. run the REAL-DATA DELANA exec  delana43_94c (= simana/v94c_rd/.../delana43_rd.exe)
#   5. (optional) longdst94c2  -> short DST, the same tier as the EOS .al files
#
# Unlike the MC path which uses the *sim* DELANA (delana43.exe inside runsim),
# data uses the *_rd* (real-data) build, which applies real calibration from the DB.
#
# Usage:
#   ./run_data_reco.sh <raw.sl> <job_id> <out_dir> [<n_events>] [<period>]
#
# Example (run 44249, raw ED0151.18 -> official short DST Y13709.41 on EOS):
#   ./run_data_reco.sh \
#     /eos/experiment/delphi/castor2015/rawd/y94/ED0151/ED0151.18.sl \
#     run44249 /home/sqian/scratch/datareco 50

set -eo pipefail

RAW=${1:?raw .sl input file required}
JOB_ID=${2:-$(date +%Y%m%d_%H%M%S)}
OUT_DIR=${3:-$PWD/out_data}
N_EVENTS=${4:-50}
PERIOD=${5:-94c}            # selects delana43_<period> + cards43_<period>.tit + longdst

# Whether to also run the short-DST pass (set SHORTDST=0 to stop at the full DST).
SHORTDST=${SHORTDST:-1}

IMAGE=${IMAGE:-/home/sqian/Codes/ee_Z_tatagamma/images/cmssw-el9.sif}
DELPHI_REL=/cvmfs/delphi.cern.ch/releases/almalinux-9-x86_64/latest
DDB=/cvmfs/delphi.cern.ch/condition-data

[ -f "$RAW" ] || { echo "ERROR: raw input not found: $RAW" >&2; exit 1; }
[ -f "$IMAGE" ] || { echo "ERROR: container image not found: $IMAGE" >&2; exit 1; }

mkdir -p "$OUT_DIR"
WORK=$OUT_DIR/work_data_${JOB_ID}
mkdir -p "$WORK"

echo "=== Stage 0: stage raw locally ($(du -h "$RAW" | cut -f1)) ==="
cp "$RAW" "$WORK/raw_input.sl"

echo "=== Stage 1+2: DELANA reconstruction (real data, period $PERIOD, NEVMAX=$N_EVENTS) ==="
# Some runs hang DELANA indefinitely (99% CPU, no progress). Cap the reco with a
# timeout so a hung run is killed + skipped instead of blocking forever.
# timeout kills singularity, which tears down the container (incl. delana).
timeout -k 30 "${RECO_TIMEOUT:-1500}" \
singularity exec --cleanenv --bind /cvmfs --bind /lib64:/host_lib64:ro \
    --bind "$WORK:/work" "$IMAGE" bash -c "
        set -eo pipefail
        source /cvmfs/delphi.cern.ch/setup.sh > /dev/null 2>&1
        export LD_LIBRARY_PATH=\$LD_LIBRARY_PATH:/host_lib64
        A=$DELPHI_REL
        cd /work

        # 1. link the 7 condition-DB files (FOR050..FOR056)
        DELPHI_DDB=$DDB ddbass $DDB

        # 2. period title card; cap NEVMAX, print header more often, and
        #    RAISE the output-file size limit MBLIMI (default 170 MB truncates
        #    the DST at ~1018 events even though DELANA reconstructs the whole
        #    run -- that is why the single-file output was capped). Bump to
        #    \$MBLIMI so a full run fits one file.
        sed -e 's/^NEVMAX .*/NEVMAX  $N_EVENTS/' \
            -e 's/^NPREVT .*/NPREVT  10/' \
            -e 's/^MBLIMI .*/MBLIMI  ${MBLIMI:-4000}./' \
            \$A/evserv/farm/cards43_${PERIOD}.tit > delana.title
        echo '--- MBLIMI (output size limit) ---'; grep '^MBLIMI' delana.title
        ln -sf delana.title fort.29

        # 3. input/output logical files (PHDST dinp/dout convention)
        export dinp01=/work/raw_input.sl
        export dout01=/work/delana.dst

        # 4. run REAL-DATA DELANA
        echo '--- running delana43_${PERIOD} ---'
        \$A/evserv/farm/bin/delana43_${PERIOD}

        echo '--- DELANA done; outputs: ---'
        ls -la /work/delana.dst 2>/dev/null || echo 'NO delana.dst produced'

        # 5. optional short-DST pass (same tier as the EOS .al).
        #    longdst/dstana uses the PILOT description (symlinked DESCRIP) +
        #    a PDLINPUT file list (NOT dinp01/dout01 / fort.29) -- this mirrors
        #    RunDstana() in the official 'des' server.
        if [ \"$SHORTDST\" = \"1\" ] && [ -f /work/delana.dst ]; then
            echo '--- running longdst94c2 (full DST -> short DST) ---'
            unlink fort.29 2>/dev/null || true
            unset dinp01 dout01
            ln -sf \$A/evserv/farm/longdst94c2.des DESCRIP
            printf 'FILE = /work/delana.dst\nFILE = /work/short_ours.al, STREAM = 1, COMPRESS=X\n' > PDLINPUT
            echo '--- PDLINPUT ---'; cat PDLINPUT
            \$A/evserv/farm/bin/longdst94c2 || echo 'longdst pass returned nonzero'
            ls -la /work/short_ours.al 2>/dev/null || echo 'NO short_ours.al produced'
        fi
    " 2>&1 | tee "$WORK/reco.log" | tail -60

echo
echo "=== outputs ==="
for f in delana.dst short_ours.al; do
    if [ -f "$WORK/$f" ]; then
        mv "$WORK/$f" "$OUT_DIR/${JOB_ID}_${f}"
        echo "  -> $OUT_DIR/${JOB_ID}_${f}  ($(du -h "$OUT_DIR/${JOB_ID}_${f}" | cut -f1))"
    fi
done
echo "log: $WORK/reco.log"
