#!/bin/bash
# Two-pass EDM4hep conversion on DATA, using the existing official short DST for
# the SDST-level collections and OUR reproduced data full DST (from
# run_data_reco.sh) for the genuinely-full-DST collections (EMCA HPC clusters,
# HCAL towers, TOF, TDHA, TRAX extrap, TDID drift-calib, MU chambers, dE/dx ...).
#
# This is the "two-pass on data" the project needed: the official .al alone
# leaves all fDST_* full-DST collections EMPTY (it's a short DST); feeding pass-2
# a real full DST populates them. pass-2 drives on the full DST and looks up the
# matching pass-1 frame by (run, evt), so the official .al (many runs, physics-
# selected) and our single-run full DST line up correctly on their overlap.
#
# Env note (important): the converter reads raw DELPHI files via PHDST, so it
# needs BOTH the DELPHI environment (pdl2pdl on PATH, $DELPHI_DAT for VD
# alignment) AND key4hep (podio/edm4hep). Source DELPHI first, then key4hep
# (key4hep's ROOT wins; the DELPHI Fortran is statically linked in the binaries).
#
# Usage:
#   run_data_twopass.sh <official.al> <our_fulldst> <out_dir> [<n>]
# Example (run 44249):
#   run_data_twopass.sh \
#     /eos/experiment/delphi/castor2015/tape/Y13709/Y13709.41.al \
#     /home/sqian/scratch/datareco/run44249_full_delana.dst \
#     /home/sqian/scratch/datareco/twopass 1100

set -eo pipefail
AL=${1:?official short DST (.al) required}
FULLDST=${2:?reproduced data full DST required}
OUT=${3:-$PWD/twopass}
N=${4:-1100}

IMAGE=${IMAGE:-/home/sqian/Codes/ee_Z_tatagamma/images/cmssw-el9.sif}
EDM=${EDM:-/home/sqian/Codes/ee_Z_tatagamma/_wt-pr1-refactor/delphi_edm4hep/build}
KEY4HEP_RELEASE=${KEY4HEP_RELEASE:-2026-04-08}

mkdir -p "$OUT"
cp "$AL"      "$OUT/sdst_official.al"
cp "$FULLDST" "$OUT/ours.fadana"

singularity exec --cleanenv --bind /cvmfs --bind /lib64:/host_lib64:ro \
  --bind "$OUT:$OUT" --bind "$EDM:/edmbin:ro" "$IMAGE" bash -c "
    set +u; set -eo pipefail
    source /cvmfs/delphi.cern.ch/setup.sh >/dev/null 2>&1
    source /cvmfs/sw.hsf.org/key4hep/setup.sh -r $KEY4HEP_RELEASE >/dev/null 2>&1
    export LD_LIBRARY_PATH=\$LD_LIBRARY_PATH:/host_lib64
    cd $OUT
    echo '=== PASS 1: delphi_sdst_pass on official short DST ==='
    /edmbin/delphi_sdst_pass sdst_official.al intermediate.edm4hep.root -n $N
    echo '=== PASS 2: delphi_fdst_pass (intermediate + our reproduced full DST) ==='
    /edmbin/delphi_fdst_pass intermediate.edm4hep.root ours.fadana final.edm4hep.root -n $N
  "
echo "=== DONE ==="
ls -la "$OUT/final.edm4hep.root"
echo "final EDM4hep with SDST (official) + full-DST (our reco) collections: $OUT/final.edm4hep.root"
