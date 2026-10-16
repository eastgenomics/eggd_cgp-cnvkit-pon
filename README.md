<!-- dx-header -->
# eggd_cgp-cnvkit-pon (DNAnexus Platform App)

Builds a CNVkit panel-of-normals (PoN) reference from per-sample coverage files.
Runs as **Step 2** of the three-app CGP CNVkit pipeline:

```
eggd_cgp-cnvkit-coverage (×N, parallel) → eggd_cgp-cnvkit-pon (×1) → eggd_cgp-cnvkit-batch (×N, parallel)
```

## What does this app do?

Pools per-sample `.targetcoverage.cnn` files (produced by `eggd_cgp-cnvkit-coverage`)
into a single PoN `reference.cnn` using `cnvkit.py reference`. The reference encodes the
per-interval median and spread across all input samples. This captures assay-level
technical biases (probe efficiency, local GC variation, batch effects) that are
subtracted in the analysis step.

Also produces a `reference_stats.tsv` summary file (interval count, log₂ mean/median/SD,
median depth, sample count) for verification.

## What are the typical use cases for this app?

- **Initial cohort setup:** run once after collecting coverage files from ≥20 samples
  to establish a stable PoN for a new assay batch or library prep version.
- **PoN refresh:** re-run when the assay configuration changes (new library prep kit,
  new backbone probe concentration, new sequencer model) to recalibrate the reference.
- **Normal sample PoN (recommended):** ideally, pass coverage files from matched-protocol
  normal (healthy volunteer) samples. When only tumour samples are available
  (tumour-only PoN), the reference still removes technical biases but will attenuate
  recurrent copy-number events present in many samples.
- **Static PoN build (Atlas CGP):** build once, offline, from a fixed, curated member
  list (excludes controls, non-FFPE material and low-depth sequencings; one sequencing
  per specimen) rather than per sequencing run. Use `fasta`/`fasta_fai`/`fasta_gzi`,
  `diploid_parx_genome=grch38` and the default `gc_clip_min`/`gc_clip_max` to reproduce
  the validated configuration (`cnv-backbone-purple-atlas/analysis/pon_comparison/FINAL_RESULTS.md`
  s1.3-1.4). Check `pon_member_sex` against each member's LIMS sex before trusting the
  build, and register the resulting `cn_reference` as a controlled file.

**PoN size guidance:**

| Samples in PoN | Expected quality |
|---|---|
| < 10 | Poor — PoN median unstable; not recommended |
| 10–20 | Acceptable for initial exploration |
| 20–40 | Good — suitable for research use |
| ≥ 40 | Optimal |

## What are the inputs?

| Input | Class | Required | Description |
|---|---|---|---|
| `coverage_files` | array:file | ✅ | `.targetcoverage.cnn` files from `eggd_cgp-cnvkit-coverage`, one per sample |
| `pon_name` | string | ➖ | Output filename stem (default: `cgp_cnvkit_reference`) |
| `fasta` | file | ➖ | bgzf-compressed reference FASTA (`.fasta.gz`) for GC/repeat annotation. Requires `fasta_fai` and `fasta_gzi`. |
| `fasta_fai` | file | ➖ | samtools `.fai` index for the FASTA. Required when `fasta` is supplied. |
| `fasta_gzi` | file | ➖ | bgzf block index (`.gzi`) for the FASTA. Required when `fasta` is supplied. |
| `diploid_parx_genome` | string | ➖ | Genome build name (e.g. `grch38`) passed as `--diploid-parx-genome <value>` to `cnvkit.py reference` and the member sex check (`cnvkit.py sex`), so chrX PAR1/PAR2 is treated as autosomal instead of getting the male/female chrX offset. Default: `grch38`. Leave blank to disable. |
| `gc_clip_min` | float | ➖ | Lower bound for `gc`-column clipping (default `0.3`). Only applied when `fasta` is supplied; see Notes. |
| `gc_clip_max` | float | ➖ | Upper bound for `gc`-column clipping (default `0.7`). Only applied when `fasta` is supplied; see Notes. |

All coverage files must have been generated with the **same BED file** and
`target_avg_size` setting.

## What are the outputs?

| Output | Class | Description |
|---|---|---|
| `cn_reference` | file | PoN reference (`.cnn`) — pass to `eggd_cgp-cnvkit-batch` |
| `reference_stats` | file | Summary statistics (`.tsv`) — verify build quality |
| `pon_member_sex` | file | `cnvkit.py sex` call (sample, sex, X_logratio, Y_logratio) for every input coverage file, computed with the same `diploid_parx_genome` setting as the reference build. Report only — cross-check against each member's LIMS sex before trusting the PoN's chrX/chrY handling; a mismatch is a signal to review the member, not an automatic exclusion. |

**Verifying the reference:** the `reference_stats.tsv` should show:
- `log2_median` close to 0.0 (PoN normalisation centres the log₂ scale)
- `n_intervals` matching your BED interval count (20,905 for Twist CGP deduplicated)
- `n_samples` matching the number of input coverage files

## How to run this app from the command line?

```bash
# Collect coverage file IDs (one per sample)
CNN_ARGS=$(dx find data --project project-xxxx --path "/cnvkit/coverage/" \
    --name "*.targetcoverage.cnn" --brief | \
    grep -oP 'file-\w+' | \
    xargs -I{} echo "-icoverage_files={}")

dx run eggd_cgp-cnvkit-pon \
  ${CNN_ARGS} \
  -ipon_name="cgp_cnvkit_reference_v1" \
  --destination "project-xxxx:/cnvkit/pon/" \
  --instance-type mem2_ssd1_v2_x4 \
  --priority high \
  -y
```

Typical runtime: **5–10 min** on `mem2_ssd1_v2_x4` for up to 50 samples.
Only needs to run once per cohort/PoN version.

## Dependencies

CNVkit runs inside a pre-built Docker image loaded from DNAnexus at job start
(`cgp-cnvkit:1.0.0`, image ID `project-Fkb6Gkj433GVVvj73J7x8KbV:file-J8j7Vyj45FG1BbK26JQgQY6q`).
No internet access or PyPI install is required.
CNVkit version in use: **0.9.13**.
No R is required for this step.

## Notes

- **GC correction:** Not applied by default. To enable, supply a bgzf-compressed
  reference FASTA via the `fasta`, `fasta_fai`, and `fasta_gzi` inputs. All three
  must be provided together. The FASTA chromosome naming must match the BED/BAM
  naming (chr-prefix for chr-prefix BAMs). GC correction reduces per-interval noise
  by ~10–15%. `code.sh` verifies this actually ran: when `fasta` is supplied, it
  checks the output `reference.cnn` for a `gc` column and fails the job if it's
  absent, so a broken `--fasta` pass-through errors loudly instead of silently
  skipping GC correction (`gc_correction_applied` is also recorded in
  `reference_stats.tsv`).
- **Tumour PoN:** When built from tumour samples, recurrent CN events (amplifications
  or deletions present in many samples) are absorbed into the PoN median and attenuated
  in individual sample analyses. Replace with a normal-sample PoN when possible.
- **PAR-aware chrX handling (`diploid_parx_genome`):** passed verbatim to CNVkit's
  `--diploid-parx-genome`, which treats the named genome's chrX pseudoautosomal
  region as autosomal rather than applying the male/female chrX offset there. Without
  it, every PoN member whose only chrY bins are hard-masked by the reference FASTA
  (as GIABv3's chrY PAR mask does on this panel) is inferred female by `reference`'s
  own sex guess, regardless of true sex, and the PoN chrX level is biased.
- **GC-column clipping (`gc_clip_min`/`gc_clip_max`):** `cnvkit.py fix` drops any bin
  whose reference `gc` falls outside [0.3, 0.7] by default (`mask_bad_bins`), which on
  the Twist CGP panel + GIABv3 removes ~7% of bins and can take short intragenic events
  below the minimum usable probe count. Clipping the `gc` column to the given bounds
  (applied only when `fasta` is supplied) keeps those bins — they are still
  GC-corrected, just at the bound — without changing `log2`/`depth`/`spread` or any
  other mask rule. Values already inside the bounds are untouched. Set
  `gc_clip_min == gc_clip_max`, or omit `fasta`, to disable.
- **PoN member sex check:** `pon_member_sex.tsv` records `cnvkit.py sex`'s call for
  every input file using the same `diploid_parx_genome` setting as the build. It does
  not gate the build. In the validated Atlas configuration, 2 of 124 static-PoN members
  have a sex call that disagrees with their LIMS letter (one tumour chrX gain, one
  probable 47,XXY) and were retained after checking the effect on the PoN was
  negligible — review flagged members the same way rather than excluding them by default.
