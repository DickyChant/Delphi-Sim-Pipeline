#!/bin/bash
# Run the full Pythia -> DELSIM pipeline locally using a stock cmssw/el9
# singularity image backed by CVMFS, instead of Jingyu's baked DELPHI image.
#
# Prereqs on host:
#   * singularity-ce (or apptainer) >= 3.8
#   * /cvmfs/delphi.cern.ch and /cvmfs/sft.cern.ch visible (autofs / cvmfs-fuse)
#   * AlmaLinux 9 on host with libgfortran-11 and motif packages installed
#     (we bind-mount them into the container because the cmssw/el9 image is
#     minimal and does not carry them).
#
# Usage:
#   ./run_singularity.sh <n_events> <job_id> <out_dir> <config_file>
#                        [<delsim_version> <e_beam> <nrun>]
#
# Example:
#   ./run_singularity.sh 200 smoketest /tmp/out ../config_z_tautau.txt
#
# Optional BS centroid override (env vars):
#   BS_X, BS_Y, BS_Z (cm), BS_SIGMA_X, BS_SIGMA_Y, BS_SIGMA_Z (cm)
#   When BS_X/Y/Z are set, DELSIM's XYZP/XYZW are overridden via a
#   prerun-then-edit-then-rerun runsim sequence (see Stage 3 below).
#   The BS bank in the resulting SDST will reflect the override
#   (verified empirically: DELSIM XYZP wins over DELANA's BEAX prior
#   in the SDST BS bank).
#
# Example matching real-data run 13709 (Y13709 nanoaods on EOS):
#   BS_X=-0.306 BS_Y=+0.149 BS_Z=-0.770 \
#     ./run_singularity.sh 100 mc /tmp/zbb ../config_z_bb.txt
#
# The wrapper handles:
#   * pulling / caching the cmssw/el9 SIF on first run
#   * compiling pythia8_generate from the checked-out source using LCG_109 Pythia 8.317
#   * running runsim with DELPHI_DDB / DELPHI_DATA_ROOT redirected to the CVMFS
#     copies (no EOS dependency)

set -eo pipefail

N_EVENTS=${1:-200}
JOB_ID=${2:-$(date +%Y%m%d_%H%M%S)}
OUT_DIR=${3:-$PWD/out}
CONFIG_FILE=${4:-$PWD/../config_z_tautau.txt}
DELSIM_VERSION=${5:-v94c}
E_BEAM=${6:-45.625}
NRUN=${7:-${NRUN:-3101}}
# Optional BS centroid override. When set, DELSIM's XYZP/XYZW cards in
# simqqbar.tit are patched to these values via runsim -STITL. Empirically
# the override propagates straight to the SDST BS bank (DELSIM's per-event
# truth IP wins over DELANA's BEAX prior). The two-step prerun-then-edit
# approach is required because runsim's -STITL doesn't substitute
# {nrun}/IGENER placeholders — see Stage 3 below.
#
# Default: keep the v94c-period values from simqqbar.tit, no override.
# To match real-data run 13709 (Y13709 nanoaods on EOS):
#   BS_X=-0.306 BS_Y=+0.149 BS_Z=-0.770 ./run_singularity.sh ...
BS_X=${BS_X:-}
BS_Y=${BS_Y:-}
BS_Z=${BS_Z:-}
BS_SIGMA_X=${BS_SIGMA_X:-0.012}
BS_SIGMA_Y=${BS_SIGMA_Y:-0.0005}
BS_SIGMA_Z=${BS_SIGMA_Z:-0.740}

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
IMAGE_DIR=${IMAGE_DIR:-$HOME/.cache/singularity-delphi}
IMAGE=$IMAGE_DIR/cmssw-el9-x86_64.sif
LCG_VIEW=/cvmfs/sft.cern.ch/lcg/views/LCG_109/x86_64-el9-gcc13-opt

mkdir -p "$IMAGE_DIR" "$OUT_DIR"

if [ ! -f "$IMAGE" ]; then
    echo "=== Pulling cmssw/el9:x86_64 to $IMAGE ==="
    singularity pull --name "$(basename "$IMAGE")" --dir "$IMAGE_DIR" \
        docker://cmssw/el9:x86_64 || {
            # The pull step sometimes errors on cleanup of a temp bundle but
            # still produces the .sif. Validate and continue.
            [ -f "$IMAGE" ] || exit 1
        }
fi

# The DELSIM binaries (simrun36, delana43.exe, shortdst.exe) need libgfortran-5,
# libquadmath, libXm, libXp, libquadmath — not present in the minimal cmssw/el9
# image. Rather than binding them one by one, we mount the host /lib64 read-only
# at /host_lib64 inside the container and prepend it to LD_LIBRARY_PATH. The
# container's own /lib64 (glibc etc.) stays authoritative; the host libs are
# only consulted for names the container lacks.
BIND_LIBS=(--bind /lib64:/host_lib64:ro)

# Stage the work dir so the container has a writable /work.
WORK=$OUT_DIR/work_${JOB_ID}
mkdir -p "$WORK"
cp "$REPO_ROOT/pythia8_generate.cpp" "$REPO_ROOT/Makefile" "$WORK/"
cp "$CONFIG_FILE" "$WORK/config.txt"

echo "=== Stage 1: compile pythia8_generate against LCG Pythia 8.317 ==="
singularity exec --cleanenv --bind /cvmfs --bind "$WORK:/work" "${BIND_LIBS[@]}" \
    "$IMAGE" bash -c "
        set +u
        source $LCG_VIEW/setup.sh
        cd /work
        make clean
        make pythia8_generate
    "

echo "=== Stage 2: generate $N_EVENTS Pythia events (config=$(basename "$CONFIG_FILE")) ==="
singularity exec --cleanenv --bind /cvmfs --bind "$WORK:/work" "${BIND_LIBS[@]}" \
    "$IMAGE" bash -c "
        set +u
        source $LCG_VIEW/setup.sh
        cd /work
        ./pythia8_generate $N_EVENTS /work/config.txt
    " | tail -40
mv "$WORK/fort.26" "$WORK/my_events.fadgen"

if [[ -n "$BS_X$BS_Y$BS_Z" ]]; then
    : ${BS_X:?BS_X required if any of BS_Y/BS_Z is set}
    : ${BS_Y:?BS_Y required if any of BS_X/BS_Z is set}
    : ${BS_Z:?BS_Z required if any of BS_X/BS_Y is set}
    echo "=== Stage 3: DELSIM (runsim $DELSIM_VERSION NRUN=$NRUN EBEAM=$E_BEAM N=$N_EVENTS) ==="
    echo "             with BS override: ($BS_X, $BS_Y, $BS_Z) cm  ± ($BS_SIGMA_X, $BS_SIGMA_Y, $BS_SIGMA_Z)"
    singularity exec --cleanenv --bind /cvmfs --bind "$WORK:/work" "${BIND_LIBS[@]}" \
        "$IMAGE" bash -c "
            set +u
            source /cvmfs/delphi.cern.ch/setup.sh > /dev/null 2>&1
            export DELPHI_DDB=/cvmfs/delphi.cern.ch/condition-data
            export DELPHI_DATA_ROOT=/cvmfs/delphi.cern.ch
            export LD_LIBRARY_PATH=\$LD_LIBRARY_PATH:/host_lib64
            cd /work

            # Step A: prerun without -STITL to let runsim's MakeSimTitle
            # substitute {nrun}, IGENER, ISEEDG/S, NEVMAX, etc. into a
            # complete simlocal.title. We discard prerun outputs.
            echo '--- Stage 3a: prerun (generate simlocal.title) ---'
            runsim -VERSION $DELSIM_VERSION -LABO CERN -NRUN $NRUN -EBEAM $E_BEAM \\
                   -NEVMAX $N_EVENTS -gext my_events.fadgen 2>&1 | tail -3
            if [[ ! -f simlocal.title ]]; then
                echo 'ERROR: prerun did not generate simlocal.title' >&2
                exit 1
            fi

            # Step B: edit XYZP/XYZW into a copy.
            cp simlocal.title simlocal_edit.title
            sed -i \"s|^XYZP[[:space:]].*|XYZP    $BS_X $BS_Y $BS_Z|\"               simlocal_edit.title
            sed -i \"s|^XYZW[[:space:]].*|XYZW    $BS_SIGMA_X $BS_SIGMA_Y $BS_SIGMA_Z|\" simlocal_edit.title
            echo '--- BS override applied ---'
            grep -E '^(XYZP|XYZW)[[:space:]]' simlocal_edit.title

            # Step C: clean prerun artifacts and re-run with -STITL.
            rm -f simana.fadsim simana.sdst simana.fadana FOR* fort.* simdec.data igtots.logn delsimrn.out88 scanlist.sumr T.FSEQ1 simlocal.title
            ln -sf my_events.fadgen fort.18
            echo '--- Stage 3b: main run with edited title ---'
            runsim -VERSION $DELSIM_VERSION -LABO CERN -NRUN $NRUN -EBEAM $E_BEAM \\
                   -NEVMAX $N_EVENTS -gext my_events.fadgen \\
                   -STITL simlocal_edit.title
        " | tail -40
else
    echo "=== Stage 3: DELSIM (runsim $DELSIM_VERSION NRUN=$NRUN EBEAM=$E_BEAM N=$N_EVENTS) ==="
    echo "             default v94c BS centroid (no override)"
    singularity exec --cleanenv --bind /cvmfs --bind "$WORK:/work" "${BIND_LIBS[@]}" \
        "$IMAGE" bash -c "
            set +u
            source /cvmfs/delphi.cern.ch/setup.sh > /dev/null 2>&1
            # /eos/opendata/delphi is not reachable outside CERN; CVMFS carries the
            # same condition data. Override the defaults.
            export DELPHI_DDB=/cvmfs/delphi.cern.ch/condition-data
            export DELPHI_DATA_ROOT=/cvmfs/delphi.cern.ch
            # Host /lib64 bound at /host_lib64; expose it to ld.so only as a
            # fallback path for names the container image does not ship.
            export LD_LIBRARY_PATH=\$LD_LIBRARY_PATH:/host_lib64
            cd /work
            runsim -VERSION $DELSIM_VERSION -LABO CERN -NRUN $NRUN -EBEAM $E_BEAM \\
                   -NEVMAX $N_EVENTS -gext my_events.fadgen
        " | tail -40
fi

if [ -f "$WORK/simana.sdst" ]; then
    mv "$WORK/simana.sdst" "$OUT_DIR/simana_${JOB_ID}.sdst"
    echo "=== DONE: $OUT_DIR/simana_${JOB_ID}.sdst ==="
else
    echo "=== DELSIM did not produce simana.sdst; check $WORK for logs ==="
    exit 1
fi

# Preserve the DELANA full-DST alongside. It carries per-track 3-D track
# elements (PA.TETP / TEID / TEOD / TEFA / TEFB) that the shortDST drops.
if [ -f "$WORK/simana.fadana" ]; then
    mv "$WORK/simana.fadana" "$OUT_DIR/simana_${JOB_ID}.fadana"
    echo "=== DONE: $OUT_DIR/simana_${JOB_ID}.fadana (full DST) ==="
fi
