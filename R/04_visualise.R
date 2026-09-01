# =============================================================================
# 04_visualise.R
# Rebuild the four-panel composite used in the Data Visualisation report from
# the processed data and the saved results tables. This script is deliberately
# standalone: it does not rely on plot objects remaining in memory after
# scripts 02 and 03 have run.
#
# The five numbered figures in the Introduction to Data Science report remain:
#   1 annual trends; 2 length diagnostic; 3 group differences;
#   4 validation diagnostics; 5 adjusted odds ratios.
# The composite produced here is named rather than assigned another number.
# =============================================================================
suppressPackageStartupMessages({
  library(tidyverse)
  library(here)
  library(patchwork)
})

select <- dplyr::select
theme_set(theme_minimal(base_size = 11))

figure_dir <- here("output", "figures")
table_dir <- here("output", "tables")
dir.create(figure_dir, recursive = TRUE, showWarnings = FALSE)

read_table <- function(filename) {
  path <- file.path(table_dir, filename)
  if (!file.exists(path)) {
    stop("Required file is missing: ", path, ". Run run_all.R from the project root.")
  }
  readr::read_csv(path, show_col_types = FALSE)
}

analysis_data <- readr::read_csv(
  here("data", "processed", "music_analysis.csv"),
  show_col_types = FALSE
)
trend_results <- read_table("rq1_trend_tests.csv")
effect_results <- read_table("rq2_effect_sizes.csv")
rolling_results <- read_table("rolling_cv.csv")
validation_results <- read_table("rq3_validation.csv")
permutation_results <- read_table("permutation_auc_distribution.csv")

features <- c(
  "word_count", "mtld", "avg_word_length", "repetition_score",
  "hapax_ratio", "compression_ratio"
)
feature_labels <- c(
  word_count = "Word count",
  mtld = "MTLD (length-robust diversity)",
  avg_word_length = "Avg word length",
  repetition_score = "Repetition (hook)",
  hapax_ratio = "Hapax ratio",
  compression_ratio = "Compression ratio",
  ttr = "TTR (naive diversity)"
)

metric_value <- function(metric_name) {
  value <- validation_results$value[validation_results$metric == metric_name]
  if (length(value) != 1) stop("Validation metric is missing or duplicated: ", metric_name)
  value
}

# ---- Panel A: annual lyric measures ----------------------------------------
p_values <- setNames(trend_results$p, trend_results$feature)
annual_long <- analysis_data %>%
  group_by(year) %>%
  summarise(
    across(
      all_of(features),
      list(median = median, lower = ~quantile(.x, .25), upper = ~quantile(.x, .75))
    ),
    .groups = "drop"
  ) %>%
  pivot_longer(
    -year,
    names_to = c("feature", "statistic"),
    names_sep = "_(?=median$|lower$|upper$)"
  ) %>%
  pivot_wider(names_from = statistic, values_from = value) %>%
  mutate(
    feature_label = recode(feature, !!!feature_labels),
    significance = if_else(p_values[feature] < .05, "MK p<.05", "n.s.")
  )

panel_a <- ggplot(annual_long, aes(year, median)) +
  geom_ribbon(aes(ymin = lower, ymax = upper), alpha = .18, fill = "#0072B2") +
  geom_line(aes(colour = significance), linewidth = .8) +
  geom_smooth(
    method = "lm", se = FALSE, linetype = "dashed",
    colour = "grey30", linewidth = .45
  ) +
  facet_wrap(~feature_label, scales = "free_y") +
  scale_colour_manual(values = c("MK p<.05" = "#D55E00", "n.s." = "#0072B2")) +
  labs(
    title = "Annual median stylometric features, 2000-2023",
    subtitle = "Solid line = median; dashed = linear fit; band = IQR",
    x = "Chart year", y = "Median", colour = NULL
  ) +
  theme(legend.position = "top", panel.grid.minor = element_blank())

# ---- Panel B: length diagnostic --------------------------------------------
length_data <- analysis_data %>%
  select(word_count, ttr, mtld) %>%
  pivot_longer(c(ttr, mtld)) %>%
  mutate(
    panel = if_else(
      name == "ttr",
      sprintf("Naive TTR  (r=%.2f with log length)",
              cor(log(analysis_data$word_count), analysis_data$ttr)),
      sprintf("MTLD  (r=%.2f with log length)",
              cor(log(analysis_data$word_count), analysis_data$mtld))
    )
  )

panel_b <- ggplot(length_data, aes(word_count, value)) +
  geom_point(alpha = .12, size = .6, colour = "#0072B2") +
  geom_smooth(method = "loess", se = FALSE, colour = "#D55E00", linewidth = .9) +
  scale_x_log10() +
  facet_wrap(~panel, scales = "free_y") +
  labs(
    title = "Lyric length affects naive TTR",
    subtitle = "MTLD has much less linear association with length",
    x = "Word count (log scale)", y = "Diversity value"
  )

# ---- Panel C: top-20 group differences -------------------------------------
panel_c <- effect_results %>%
  mutate(
    feature_label = recode(feature, !!!feature_labels),
    feature_label = fct_reorder(feature_label, cohens_d)
  ) %>%
  ggplot(aes(cohens_d, feature_label)) +
  geom_vline(xintercept = 0, linetype = "dashed", colour = "grey50") +
  geom_errorbarh(aes(xmin = lo, xmax = hi), height = .2, colour = "#0072B2") +
  geom_point(size = 2.4, colour = "#0072B2") +
  labs(
    title = "Top 20 and positions 21-100",
    subtitle = "Standardised differences with 95% bootstrap intervals",
    x = "Cohen's d (95% CI; negative = lower in top 20)", y = NULL
  ) +
  theme(
    plot.margin = margin(8, 18, 8, 28),
    axis.text.y = element_text(margin = margin(r = 7))
  )

# ---- Panel D: temporal validation and permutation result -------------------
rolling_panel <- ggplot(rolling_results, aes(test_year, auc)) +
  geom_hline(yintercept = .5, linetype = "dashed", colour = "grey50") +
  geom_hline(
    yintercept = mean(rolling_results$auc),
    colour = "#D55E00", linewidth = .55
  ) +
  geom_line(colour = "#0072B2") +
  geom_point(colour = "#0072B2", size = 1.8) +
  scale_y_continuous(limits = c(.35, .70)) +
  labs(
    title = "Rolling-origin validation",
    subtitle = sprintf("Train through t, test t+1; mean AUC=%.2f; chance=0.5",
                       mean(rolling_results$auc)),
    x = "Test year", y = "ROC AUC"
  )

observed_auc <- metric_value("test_auc")
permutation_p <- metric_value("permutation_p")
permutation_panel <- ggplot(permutation_results, aes(permuted_auc)) +
  geom_histogram(bins = 40, fill = "#0072B2", alpha = .65) +
  geom_vline(xintercept = observed_auc, colour = "#D55E00", linewidth = .8) +
  labs(
    title = "Permutation test for test AUC",
    subtitle = sprintf("Observed=%.3f; label-permuted null; p=%.3f",
                       observed_auc, permutation_p),
    x = "AUC under permuted labels", y = "Count"
  )

panel_d <- rolling_panel | permutation_panel

# wrap_elements() keeps the two model diagnostics together as one top-level
# panel, allowing the composite to retain the intended A-D labelling.
four_panel_composite <-
  ((panel_a | panel_b) / (panel_c | wrap_elements(full = panel_d))) +
  plot_annotation(
    title = "How lyrical structure changed and whether it separated chart positions",
    subtitle = "Billboard year-end Hot 100, 2000-2023",
    tag_levels = "A"
  )

ggsave(
  file.path(figure_dir, "data_visualisation_four_panel_composite.png"),
  four_panel_composite,
  width = 15, height = 11, dpi = 300, bg = "white"
)

message("04 complete: data_visualisation_four_panel_composite.png")
