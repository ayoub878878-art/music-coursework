# Billboard Hot 100 lyrics analysis, 2000-2023

This R project examines whether the textual structure of Billboard year-end
Hot 100 lyrics changed from 2000 to 2023, whether top-20 entries differed from
positions 21-100, and whether the measured lyric features separated top-20
entries in later years.

The source is the Kaggle dataset
[Billboard Hot 100 (2000-2023) data with features](https://www.kaggle.com/datasets/suparnabiswas/billboard-hot-1002000-2023-data-with-features).
The analysis uses only R.

The coursework project pages are built from [`index.md`](index.md) for
Introduction to Data Science and
[`data-visualisation.md`](data-visualisation.md) for Data Visualisation.

## How to run the project

1. Download or clone the project with its folder structure unchanged.
2. Open `music-coursework.Rproj` in RStudio.
3. Start a fresh R session.
4. Install the packages listed below if they are not already installed.
5. Run `source("run_all.R")`.

Run the complete workflow once on your own computer before uploading the final
repository. A successful run refreshes the processed data, figures, result
tables, cleaning log and `session_info.txt` so they reflect your R installation.

The command-line alternative is `Rscript run_all.R`, run from the project root.
The complete analysis takes several minutes because it includes bootstrap and
permutation resampling. `set.seed(2024)` is used in the analysis scripts.

```r
install.packages(c(
  "tidyverse", "janitor", "here", "tidytext", "scales", "segmented",
  "patchwork", "glmnet", "lme4"
))
```

## Script order

1. `R/01_import_clean.R` checks the source data, audits audio coverage and
   duplicate lyric sources, cleans the lyrics, engineers the lyric features,
   and writes `data/processed/music_analysis.csv`.
2. `R/02_explore.R` runs the RQ1 trend analysis and RQ2 group comparison. It
   creates Figures 1-3 from the Introduction to Data Science report and an
   unnumbered feature-correlation diagnostic.
3. `R/03_model.R` runs the chronological model evaluation, rolling-origin
   validation, permutation test, bootstrap procedures, elastic-net sensitivity
   check and mixed-effects sensitivity check. It creates Figures 4-5 from the
   Introduction to Data Science report.
4. `R/04_visualise.R` rebuilds the four-panel composite used in the Data
   Visualisation report. Panel D contains both the rolling-origin AUC plot and
   the label-permutation histogram.

`run_all.R` creates the processed-data and output folders before sourcing the
four scripts. This prevents a fresh clone from failing because Git does not keep
empty directories.

## Introduction to Data Science figure mapping

| Report figure | File written by R |
|---|---|
| Figure 1: annual medians and IQRs | `output/figures/fig1_trends.png` |
| Figure 2: TTR and MTLD length diagnostic | `output/figures/fig2_ttr_mtld.png` |
| Figure 3: top-20 group differences | `output/figures/fig3_effect_sizes.png` |
| Figure 4: temporal validation and permutation test | `output/figures/fig4_validation.png` |
| Figure 5: adjusted odds ratios | `output/figures/fig5_odds_ratios.png` |

After a complete run, the unnumbered files are
`output/figures/diagnostic_feature_correlation.png` and
`output/figures/data_visualisation_four_panel_composite.png`.

## Reproducibility checks

The scripts calculate and save the checks rather than relying on numbers typed
into the report.

- The raw file contains 3,397 rows.
- Spotify audio fields are missing for 2,911 rows, or 85.7%. Of the 486 rows
  with audio data, 483 are from 2000-2004. The remaining three occur in 2006,
  2012 and 2021. Audio fields are therefore excluded from the analysis.
- Collapsing by chart year and rank reduces 3,397 source rows to 2,393 song-year
  groups. There are 791 multirow groups, and 169 of them contain more than one
  distinct raw lyric text. The first lyric is retained as an operational rule;
  the code does not claim that the source versions agree.
- One song-year observation is removed by the minimum-length and complete-case
  rules, leaving 2,392 observations and 2,169 track identifiers.
- The chronological split has 1,894 training rows from 2000-2018 and 498 test
  rows from 2019-2023. Eleven test rows share a track identifier with training,
  so the test evaluates later song-year observations rather than entirely
  unseen tracks.

When run, the scripts write `data_quality_checks.csv`,
`duplicate_group_audit.csv`, `audio_coverage_by_year.csv`,
`split_overlap_check.csv` and `shared_test_track_ids.csv` in `output/tables/`.

## Feature definitions

- `word_count`: cleaned word-token count.
- `mtld`: Measure of Textual Lexical Diversity, calculated forwards and
  backwards using a threshold of 0.72.
- `avg_word_length`: mean characters per cleaned word token.
- `repetition_score`: content-word concentration proxy, calculated as the
  frequency of the most common non-stopword divided by all non-stopword tokens.
- `hapax_ratio`: number of word types occurring once divided by all word tokens.
- `compression_ratio`: gzip-compressed byte length divided by the byte length
  of the cleaned lyric. Lower values indicate more compressible text.
- `ttr`: distinct word types divided by word tokens. It is retained only for
  the Figure 2 length diagnostic.

The full set of definitions is in `output/tables/data_dictionary.csv`.

## Method notes and limits

- The Mann-Kendall tests are unadjusted; serial dependence in the 24 annual
  medians is not modelled.
- The segmented word-count breakpoint lies close to the first year of the
  series. It is saved as a sensitivity result but not interpreted.
- RQ2 bootstrap intervals resample song-year rows and do not group repeated
  performers or tracks.
- The main logistic model is trained on 2000-2018 and evaluated on 2019-2023.
  The reported test AUC is 0.558 with a bootstrap interval of 0.488-0.625 and a
  label-permutation p-value of 0.107. These values do not support strong
  out-of-period prediction.
- The odds-ratio intervals resample chart years. They do not cluster by artist
  or track.
- Elastic net uses ordinary 10-fold cross-validation within the training data;
  it is a sensitivity check, not a second time-blocked validation.
- A zero estimated year random-intercept variance is a boundary estimate and is
  not evidence that year effects are absent.
- The sample contains only year-end Hot 100 entries. `top_20` turns an ordinal
  rank into a binary outcome and should not be interpreted as a causal measure
  of song quality or popularity outside this chart.

## Folder structure

```text
music-coursework.Rproj
run_all.R
README.md
R/
  01_import_clean.R
  02_explore.R
  03_model.R
  04_visualise.R
data/
  raw/billboard_24years_lyrics_spotify.csv
  processed/music_analysis.csv
output/
  figures/        five report figures and two unnumbered outputs
  tables/         checks, results, logs, model outputs and session_info.txt
```

`output/tables/session_info.txt` records the R and package versions used for the
supplied results. Re-running the project overwrites the processed data, tables,
figures, cleaning log and session information.
