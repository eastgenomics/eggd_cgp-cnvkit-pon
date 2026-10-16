# Changelog

## [2.2.0] - unreleased

Adds the features required to build the Atlas CGP static PoN (DI-4089; subtasks DI-4090,
DI-4091, DI-4092). Does not change behaviour when the three new inputs are left at their
defaults/absent in the way existing callers rely on `coverage_files`/`pon_name`/`fasta*`,
except that `diploid_parx_genome` now defaults to `grch38` (was previously not passed at
all) — pass an empty string to reproduce the pre-2.2.0 `reference` call exactly.

### Added
- `diploid_parx_genome` optional input (default `grch38`): passed as
  `--diploid-parx-genome <value>` to both `cnvkit.py reference` and the new member sex
  check, so chrX PAR1/PAR2 is treated as autosomal (DI-4090).
- `gc_clip_min` / `gc_clip_max` optional inputs (defaults `0.3`/`0.7`): when `fasta` is
  supplied, the reference's `gc` column is clipped to these bounds after the build
  (values unchanged otherwise), so `fix`'s default GC-bias masking keeps bins at the
  panel's GC extremes instead of dropping them (DI-4091). Fails early if
  `gc_clip_min >= gc_clip_max`.
- `pon_member_sex` output (`.tsv`): `cnvkit.py sex` call for every input coverage file,
  using the same `diploid_parx_genome` setting as the reference build. Report only —
  does not gate the build (DI-4092).

## [2.1.0] - 2026-07-20

### Added
- GC-correction regression check: when `fasta` is supplied, code.sh now verifies the
  `gc` column is present in the output `reference.cnn` and fails loudly if it's
  missing, instead of silently skipping GC correction. Also recorded as a
  `gc_correction_applied` / `gc_mean` row in `reference_stats.tsv`. Added to catch
  a repeat of the FASTA_ARG runtime bug fixed in a5b691c (GC correction had
  silently no-op'd rather than erroring).

### Fixed
- `head -1` replaced with POSIX-compliant `head -n 1` in GC-column check
- CSV float parsing now catches `TypeError` (malformed/truncated rows where a column is `None`) alongside `ValueError`, in both the log2/depth and gc parsing blocks

## [2.0.0] - 2026-06-16

### Changed
- Replaced venv-based CNVkit install with Docker execution (`cgp-cnvkit:1.0.0` image loaded from DNAnexus)
- Added optional `fasta`, `fasta_fai`, `fasta_gzi` inputs for GC/repeat annotation and bias correction
- Added companion-file guard: fasta index inputs without the FASTA (or vice versa) fail early with a clear error
- Fixed REF_FILE export so Python heredoc (reference_stats calculation) reads the filename correctly

## [1.0.0] - 2026-05-27

### Added
- Initial release
- Pools per-sample .targetcoverage.cnn files into a CNVkit PoN reference.cnn
- Outputs reference_stats.tsv for PoN quality verification
- Virtual environment install to avoid Ubuntu 24.04 system package conflicts
