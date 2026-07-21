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

All coverage files must have been generated with the **same BED file** and
`target_avg_size` setting.

## What are the outputs?

| Output | Class | Description |
|---|---|---|
| `cn_reference` | file | PoN reference (`.cnn`) — pass to `eggd_cgp-cnvkit-batch` |
| `reference_stats` | file | Summary statistics (`.tsv`) — verify build quality |

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
CNVkit version in use: unreleased dev build, git commit **fc65941d** (post-0.9.13 master, pre-dates the v0.9.14 tag).
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
