#!/bin/bash
# cgp-cnvkit-pon/src/code.sh
# Builds a CNVkit PoN reference from per-sample coverage files.
# Optionally annotates intervals with GC content (pass fasta/fasta_fai/fasta_gzi)
# for GC-bias correction in downstream fix steps.
# Outputs reference.cnn + a summary stats TSV.
# shellcheck disable=SC2154,SC2086  # SC2154: vars injected by DNAnexus; SC2086: FASTA_ARG intentionally unquoted
set -exo pipefail

main() {
    # coverage_files, pon_name, fasta, fasta_fai, fasta_gzi are injected by
    # DNAnexus at runtime from dxapp.json inputSpec; ShellCheck cannot see this.
    echo "=== CGP CNVkit PoN build ==="

    # ── Load CNVkit Docker image ──────────────────────────────────────────────
    # Image stored in DNAnexus; no external internet required.
    # Update CNVKIT_IMAGE_ID after running scripts/dnanexus/docker/cgp-cnvkit/build_and_upload.sh
    CNVKIT_IMAGE_ID="project-Fkb6Gkj433GVVvj73J7x8KbV:file-J8j7Vyj45FG1BbK26JQgQY6q"   # cgp-cnvkit:1.0.0
    CNVKIT_IMAGE_TAG="cgp-cnvkit:1.0.0"
    echo "[setup] Loading CNVkit image..."
    dx download "${CNVKIT_IMAGE_ID}" -o cnvkit-image.tar.gz
    docker load < cnvkit-image.tar.gz
    run_cnvkit() { docker run --rm -v "$(pwd)":/work -w /work "${CNVKIT_IMAGE_TAG}" cnvkit.py "$@"; }
    run_cnvkit version

    # ── Download all coverage files ───────────────────────────────────────────
    echo "[inputs] Downloading coverage files..."
    mkdir -p cnn_files

    # coverage_files is an array — DNAnexus passes as bash array of file IDs
    # dx-download-all-inputs downloads to ~/in/coverage_files/N/filename
    dx-download-all-inputs 2>/dev/null || true

    # Collect from default dx-download-all-inputs path, or download manually
    if ls ~/in/coverage_files/*/*.cnn 2>/dev/null | head -1 | grep -q ".cnn"; then
        cp ~/in/coverage_files/*/*.cnn cnn_files/
    else
        # Manual download if dx-download-all-inputs not available
        for fid in "${coverage_files[@]}"; do
            fname=$(dx describe "$fid" --json | python3 -c "import json,sys; print(json.load(sys.stdin)['name'])")
            dx download "$fid" -o "cnn_files/${fname}"
        done
    fi

    N_FILES=$(ls cnn_files/*.cnn 2>/dev/null | wc -l)
    echo "[inputs] Coverage files found: ${N_FILES}"
    [ "${N_FILES}" -ge 10 ] || { echo "ERROR: too few coverage files (${N_FILES}); expect ≥10"; exit 1; }

    ls cnn_files/*.cnn
    echo "..."

    # ── Build reference ─────────────────────────────────────────────────────────────
    # If a FASTA is provided, annotate intervals with GC content and
    # RepeatMasker fraction for GC-bias correction in downstream fix steps.
    # pyfaidx (bundled with CNVkit) handles bgzf-compressed FASTA natively
    # when both the .fai and .gzi index files are present alongside.
    FASTA_ARG=""
    # Guard: if any FASTA index is provided without the FASTA itself, fail early
    if ([ -n "${fasta_fai:-}" ] || [ -n "${fasta_gzi:-}" ]) && [ -z "${fasta:-}" ]; then
        echo "ERROR: fasta_fai/fasta_gzi supplied but fasta is missing — all three must be provided together" >&2
        exit 1
    fi

    if [ -n "${fasta:-}" ]; then
        [ -n "${fasta_fai:-}" ] || { echo "ERROR: fasta supplied but fasta_fai is missing" >&2; exit 1; }
        [ -n "${fasta_gzi:-}" ] || { echo "ERROR: fasta supplied but fasta_gzi is missing" >&2; exit 1; }
        echo "[reference] Downloading FASTA for GC correction..."
        dx download "${fasta}"     -o ref.fasta.gz
        dx download "${fasta_fai}" -o ref.fasta.gz.fai
        dx download "${fasta_gzi}" -o ref.fasta.gz.gzi
        FASTA_ARG="--fasta ref.fasta.gz"
        FASTA_PROVIDED=1
        echo "[reference] FASTA ready; GC correction enabled"
    else
        FASTA_PROVIDED=0
        echo "[reference] No FASTA supplied; skipping GC/repeat annotation"
    fi
    export FASTA_PROVIDED

    # PAR-aware chrX handling (--diploid-parx-genome). Applies to both the
    # reference build and the member sex check below, so PoN chrX/chrY
    # handling and the reported sexes use the same convention.
    PARX_ARG=""
    if [ -n "${diploid_parx_genome:-}" ]; then
        PARX_ARG="--diploid-parx-genome ${diploid_parx_genome}"
        echo "[reference] PAR-aware chrX handling enabled: --diploid-parx-genome ${diploid_parx_genome}"
    else
        echo "[reference] No diploid_parx_genome supplied; chrX PAR not treated as autosomal"
    fi

    echo "[reference] Building PoN from ${N_FILES} samples..."
    run_cnvkit reference cnn_files/*.cnn \
        --output "${pon_name:-cgp_cnvkit_reference}.cnn" \
        ${FASTA_ARG} ${PARX_ARG}

    export REF_FILE="${pon_name:-cgp_cnvkit_reference}.cnn"
    N_INTERVALS=$(wc -l < "${REF_FILE}")
    echo "[reference] Reference intervals (incl. header): ${N_INTERVALS}"
    [ "${N_INTERVALS}" -gt 1000 ] || { echo "ERROR: reference too small"; exit 1; }

    # ── GC-correction regression check ──────────────────────────────────────
    # cnvkit.py reference only adds a 'gc' column when --fasta is actually
    # passed through to it (cnvlib/reference.py: gc/rmask columns are only
    # populated when fa_fname is truthy). If fasta was supplied as an input
    # but the 'gc' column is absent from the output, FASTA_ARG never reached
    # cnvkit.py reference — this is exactly the regression fixed in a5b691c
    # (a `# shellcheck disable` comment inside a line continuation caused
    # ${FASTA_ARG} to run as its own command instead of being appended to
    # the cnvkit.py reference call). Catches a silent no-op, not just a crash.
    if [ "${FASTA_PROVIDED}" -eq 1 ]; then
        if ! head -n 1 "${REF_FILE}" | grep -qw 'gc'; then
            echo "ERROR: fasta was supplied but 'gc' column is missing from ${REF_FILE} — GC correction did not run (--fasta was not passed to cnvkit.py reference)" >&2
            exit 1
        fi
        echo "[reference] GC-correction check passed: 'gc' column present in ${REF_FILE}"
    fi

    # ── GC-column clipping ──────────────────────────────────────────────────
    # cnvkit.py fix (mask_bad_bins) drops any bin whose reference gc is outside
    # [0.3, 0.7] by default (GC_MIN_FRACTION/GC_MAX_FRACTION), which on this
    # panel removes ~7% of bins and can take short intragenic events below the
    # minimum usable probe count. Clipping the gc column to [gc_clip_min,
    # gc_clip_max] (defaults 0.3/0.7) keeps those bins -- they are still
    # GC-corrected, just at the bound -- without changing log2/depth/spread or
    # any other mask rule (low coverage, high spread, zero depth). Values that
    # already sit inside the bounds are untouched. Only meaningful when a gc
    # column exists, i.e. when fasta was supplied.
    GC_CLIP_MIN="${gc_clip_min:-0.3}"
    GC_CLIP_MAX="${gc_clip_max:-0.7}"
    if [ "${FASTA_PROVIDED}" -eq 1 ]; then
        python3 -c "import sys; sys.exit(0 if float('${GC_CLIP_MIN}') < float('${GC_CLIP_MAX}') else 1)" \
            || { echo "ERROR: gc_clip_min (${GC_CLIP_MIN}) must be less than gc_clip_max (${GC_CLIP_MAX})" >&2; exit 1; }
        echo "[reference] Clipping gc column to [${GC_CLIP_MIN}, ${GC_CLIP_MAX}]..."
        export GC_CLIP_MIN GC_CLIP_MAX REF_FILE
        python3 - << 'PYEOF'
import os
p = os.environ["REF_FILE"]
lo = float(os.environ["GC_CLIP_MIN"])
hi = float(os.environ["GC_CLIP_MAX"])
lines = open(p).read().splitlines()
hdr = lines[0].split('\t')
gi = hdr.index('gc')
out = [lines[0]]
n_clipped = 0
for l in lines[1:]:
    c = l.split('\t')
    g = float(c[gi])
    if g < lo or g > hi:
        c[gi] = f'{min(max(g, lo), hi):g}'
        n_clipped += 1
    out.append('\t'.join(c))
open(p + '.tmp', 'w').write('\n'.join(out) + '\n')
os.replace(p + '.tmp', p)
print(f'[reference] gc-clipped {n_clipped} of {len(lines) - 1} intervals')
PYEOF
    else
        echo "[reference] No FASTA supplied; skipping gc clipping (no gc column to clip)"
    fi

    # ── PoN-member sex check ─────────────────────────────────────────────────
    # Record cnvkit.py sex's call for every input coverage file, using the
    # same --diploid-parx-genome setting as the reference build. This is a
    # report only: it does not gate the build. Cross-check it against each
    # member's LIMS sex (in the PoN membership documentation, not this app)
    # before trusting the PoN's chrX/chrY handling -- a member whose inferred
    # sex looks wrong is a signal to review, not necessarily to exclude.
    # run_cnvkit only mounts $(pwd) into the container at /work, so the output
    # must be written inside cnn_files/ (the mounted dir evaluated after `cd`)
    # and then moved out -- writing "../pon_member_sex.tsv" would land outside
    # the mount, inside the ephemeral container, and be lost on --rm.
    echo "[sex-check] Running cnvkit.py sex on ${N_FILES} PoN member coverage files..."
    ( cd cnn_files && run_cnvkit sex ./*.cnn ${PARX_ARG} -o pon_member_sex.tsv )
    mv cnn_files/pon_member_sex.tsv .
    sed -i 's#\./##' pon_member_sex.tsv
    echo "[sex-check] Wrote pon_member_sex.tsv"
    cat pon_member_sex.tsv

    # ── Summary stats ─────────────────────────────────────────────────────────
    python3 - << 'PYEOF'
import csv, statistics, os

ref_file = os.environ["REF_FILE"]
fasta_provided = os.environ.get("FASTA_PROVIDED") == "1"
log2_vals = []
depths = []
gc_vals = []

with open(ref_file) as f:
    reader = csv.DictReader(f, delimiter='\t')
    for row in reader:
        try:
            log2_vals.append(float(row['log2']))
            depths.append(float(row.get('depth', 0)))
        except (ValueError, KeyError, TypeError):
            pass
        if 'gc' in row:
            try:
                gc_vals.append(float(row['gc']))
            except (ValueError, TypeError):
                pass

with open('reference_stats.tsv', 'w') as out:
    out.write('metric\tvalue\n')
    out.write(f'n_intervals\t{len(log2_vals)}\n')
    out.write(f'log2_mean\t{statistics.mean(log2_vals):.4f}\n')
    out.write(f'log2_stdev\t{statistics.stdev(log2_vals):.4f}\n')
    out.write(f'log2_median\t{statistics.median(log2_vals):.4f}\n')
    out.write(f'depth_median\t{statistics.median(depths):.1f}\n')
    out.write(f'n_samples\t{len([f for f in os.listdir("cnn_files") if f.endswith(".cnn")])}\n')
    out.write(f'gc_correction_applied\t{fasta_provided}\n')
    if gc_vals:
        out.write(f'gc_mean\t{statistics.mean(gc_vals):.4f}\n')

print("Reference stats:")
with open('reference_stats.tsv') as f:
    print(f.read())
PYEOF

    # ── Upload outputs ────────────────────────────────────────────────────────
    cn_reference=$(dx upload "${REF_FILE}" --brief)
    reference_stats=$(dx upload reference_stats.tsv --brief)
    pon_member_sex=$(dx upload pon_member_sex.tsv --brief)

    dx-jobutil-add-output cn_reference    "${cn_reference}"    --class=file
    dx-jobutil-add-output reference_stats "${reference_stats}" --class=file
    dx-jobutil-add-output pon_member_sex  "${pon_member_sex}"  --class=file

    echo "=== PoN build complete: ${N_FILES} samples, ${N_INTERVALS} intervals ==="
}
