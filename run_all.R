# =============================================================================
# run_all.R -- reproduce the analysis from a fresh R session, in order.
# Usage: open music-coursework.Rproj and source("run_all.R"), or run
# `Rscript run_all.R` from the project root.
# =============================================================================
required_packages <- c(
  "tidyverse", "janitor", "here", "tidytext", "scales", "segmented",
  "patchwork", "glmnet", "lme4"
)
missing_packages <- required_packages[
  !vapply(required_packages, requireNamespace, logical(1), quietly = TRUE)
]
if (length(missing_packages) > 0) {
  stop(
    "Install the missing R packages before running the project: ",
    paste(missing_packages, collapse = ", ")
  )
}

library(here)

# Git does not retain empty folders, so create every output directory here.
for (directory in c("data/processed", "output/figures", "output/tables")) {
  dir.create(here(directory), recursive = TRUE, showWarnings = FALSE)
}

raw_file <- here("data", "raw", "billboard_24years_lyrics_spotify.csv")
if (!file.exists(raw_file)) {
  stop("Raw data file is missing: ", raw_file)
}

scripts <- c(
  "R/01_import_clean.R",  # coverage audit, lyric cleaning and feature engineering
  "R/02_explore.R",       # RQ1/RQ2, report Figures 1-3 and correlation diagnostic
  "R/03_model.R",         # RQ3, validation, sensitivity checks and Figures 4-5
  "R/04_visualise.R"      # four-panel Data Visualisation composite
)

for (s in scripts) {
  message("\nRunning ", s)
  source(here(s), echo = FALSE)
}

message("\nAll scripts completed. Results are in output/figures and output/tables.")
