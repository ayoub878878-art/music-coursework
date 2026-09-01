# =============================================================================
# 02_explore.R -- RQ1 trend tests and RQ2 group differences.
# Produces report Figures 1-3 and one unnumbered correlation diagnostic.
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(here)
  library(scales)
  library(segmented)
})

select <- dplyr::select
filter <- dplyr::filter
mutate <- dplyr::mutate
summarise <- dplyr::summarise

set.seed(2024)
theme_set(theme_minimal(base_size = 12))

fig <- here("output", "figures")
tab <- here("output", "tables")

dir.create(fig, recursive = TRUE, showWarnings = FALSE)
dir.create(tab, recursive = TRUE, showWarnings = FALSE)

d <- readr::read_csv(
  here("data", "processed", "music_analysis.csv"),
  show_col_types = FALSE
) %>%
  mutate(top_20 = factor(top_20, levels = c("other", "top20")))

feats <- c(
  "word_count",
  "mtld",
  "avg_word_length",
  "repetition_score",
  "hapax_ratio",
  "compression_ratio"
)

lab <- c(
  word_count = "Word count",
  mtld = "MTLD (length-robust diversity)",
  avg_word_length = "Avg word length",
  repetition_score = "Repetition (hook)",
  hapax_ratio = "Hapax ratio",
  compression_ratio = "Compression ratio",
  ttr = "TTR (naive diversity)"
)

# Table 1
readr::write_csv(
  tibble(
    metric = c(
      "Songs (charted, deduplicated)",
      "Unique tracks",
      "Year span",
      "Top-20",
      "Top-20 share (%)"
    ),
    value = c(
      nrow(d),
      n_distinct(d$track_id),
      paste0(min(d$year), "-", max(d$year)),
      sum(d$top_20 == "top20"),
      round(100 * mean(d$top_20 == "top20"), 1)
    )
  ),
  file.path(tab, "table1_sample.csv")
)

# ---- RQ1: Mann-Kendall trend test + Sen's slope on annual medians ----------
mann_kendall <- function(x) {
  n <- length(x)
  S <- 0

  for (i in 1:(n - 1)) {
    for (j in (i + 1):n) {
      S <- S + sign(x[j] - x[i])
    }
  }

  v <- n * (n - 1) * (2 * n + 5) / 18

  Z <- if (S > 0) {
    (S - 1) / sqrt(v)
  } else if (S < 0) {
    (S + 1) / sqrt(v)
  } else {
    0
  }

  tibble(
    S = S,
    Z = Z,
    p = 2 * (1 - pnorm(abs(Z)))
  )
}

sens_slope <- function(yr, x) {
  s <- c()
  n <- length(x)

  for (i in 1:(n - 1)) {
    for (j in (i + 1):n) {
      s <- c(s, (x[j] - x[i]) / (yr[j] - yr[i]))
    }
  }

  median(s, na.rm = TRUE)
}

annual <- d %>%
  group_by(year) %>%
  summarise(
    across(all_of(c(feats, "ttr")), median),
    .groups = "drop"
  ) %>%
  arrange(year)

rq1 <- map_dfr(
  feats,
  ~ bind_cols(
    feature = .x,
    sen_slope = sens_slope(annual$year, annual[[.x]]),
    mann_kendall(annual[[.x]])
  )
)

readr::write_csv(rq1, file.path(tab, "rq1_trend_tests.csv"))
print(rq1)

# Changepoint in word-count trend (segmented regression)
seg <- tryCatch(
  segmented(lm(word_count ~ year, data = annual), seg.Z = ~year),
  error = function(e) {
    NULL
  }
)

if (!is.null(seg)) {
  breakpoint_estimate <- unname(seg$psi[, "Est."])

  # A breakpoint close to the start or end of a short series is unstable.
  # The estimate here is recorded for transparency but is not interpreted.
  readr::write_csv(
    tibble(
      breakpoint = breakpoint_estimate,
      se = unname(seg$psi[, "St.Err"]),
      slope_before = slope(seg)$year[1, "Est."],
      slope_after = slope(seg)$year[2, "Est."],
      boundary_distance_years = min(
        breakpoint_estimate - min(annual$year),
        max(annual$year) - breakpoint_estimate
      ),
      interpreted = boundary_distance_years >= 2
    ),
    file.path(tab, "rq1_changepoint.csv")
  )
}

# Figure 1: annual medians, orange where MK p<.05
pval <- setNames(rq1$p, rq1$feature)

a_long <- d %>%
  group_by(year) %>%
  summarise(
    across(
      all_of(feats),
      list(
        m = median,
        lo = ~ quantile(.x, .25),
        hi = ~ quantile(.x, .75)
      )
    ),
    .groups = "drop"
  ) %>%
  pivot_longer(
    -year,
    names_to = c("feature", "stat"),
    names_sep = "_(?=m$|lo$|hi$)"
  ) %>%
  pivot_wider(names_from = stat, values_from = value) %>%
  mutate(
    flab = recode(feature, !!!lab),
    sig = ifelse(pval[feature] < .05, "MK p<.05", "n.s.")
  )

f1 <- ggplot(a_long, aes(year, m)) +
  geom_ribbon(
    aes(ymin = lo, ymax = hi),
    alpha = .18,
    fill = "#0072B2"
  ) +
  geom_line(aes(colour = sig), linewidth = .9) +
  geom_smooth(
    method = "lm",
    se = FALSE,
    linetype = "dashed",
    colour = "grey30",
    linewidth = .5
  ) +
  facet_wrap(~flab, scales = "free_y") +
  scale_colour_manual(
    values = c("MK p<.05" = "#D55E00", "n.s." = "#0072B2")
  ) +
  labs(
    title = "Annual median stylometric features, 2000-2023",
    subtitle = paste0(
      "Solid line = median (orange if Mann-Kendall p<.05); ",
      "dashed = linear fit; band = IQR"
    ),
    x = "Chart year",
    y = "Median",
    colour = NULL
  ) +
  theme(
    legend.position = "top",
    panel.grid.minor = element_blank()
  )

ggsave(
  file.path(fig, "fig1_trends.png"),
  f1,
  width = 9,
  height = 6,
  dpi = 300
)

# Figure 2: TTR length dependence vs MTLD
f2df <- d %>%
  select(word_count, ttr, mtld) %>%
  pivot_longer(c(ttr, mtld)) %>%
  mutate(
    panel = ifelse(
      name == "ttr",
      sprintf(
        "Naive TTR  (r=%.2f with log length)",
        cor(log(d$word_count), d$ttr)
      ),
      sprintf(
        "MTLD  (r=%.2f with log length)",
        cor(log(d$word_count), d$mtld)
      )
    )
  )

f2 <- ggplot(f2df, aes(word_count, value)) +
  geom_point(alpha = .12, size = .7, colour = "#0072B2") +
  geom_smooth(
    method = "loess",
    se = FALSE,
    colour = "#D55E00",
    linewidth = 1
  ) +
  scale_x_log10() +
  facet_wrap(~panel, scales = "free_y") +
  labs(
    title = "Lyric length affects naive TTR",
    subtitle = "MTLD has much less linear association with length",
    x = "Word count (log scale)",
    y = "Diversity value"
  )

ggsave(
  file.path(fig, "fig2_ttr_mtld.png"),
  f2,
  width = 8,
  height = 4,
  dpi = 300
)

# ---- RQ2: Cohen's d (bootstrap CI) + Cliff's delta -------------------------
cohens_d <- function(x, g) {
  a <- x[g == "top20"]
  b <- x[g == "other"]

  sp <- sqrt(
    (
      (length(a) - 1) * var(a) +
        (length(b) - 1) * var(b)
    ) /
      (length(a) + length(b) - 2)
  )

  (mean(a) - mean(b)) / sp
}

cliffs_delta <- function(x, g) {
  a <- x[g == "top20"]
  b <- x[g == "other"]
  gt <- sum(outer(a, b, ">"))
  lt <- sum(outer(a, b, "<"))

  (gt - lt) / (length(a) * length(b))
}

rq2 <- map_dfr(feats, function(f) {
  d0 <- cohens_d(d[[f]], d$top_20)

  bd <- replicate(1000, {
    i <- sample(nrow(d), replace = TRUE)
    cohens_d(d[[f]][i], d$top_20[i])
  })

  tibble(
    feature = f,
    cohens_d = d0,
    lo = quantile(bd, .025),
    hi = quantile(bd, .975),
    cliffs_delta = cliffs_delta(d[[f]], d$top_20)
  )
}) %>%
  arrange(desc(abs(cohens_d)))

readr::write_csv(rq2, file.path(tab, "rq2_effect_sizes.csv"))
print(rq2)

f3 <- rq2 %>%
  mutate(
    flab = recode(feature, !!!lab),
    flab = fct_reorder(flab, cohens_d)
  ) %>%
  ggplot(aes(cohens_d, flab)) +
  geom_vline(
    xintercept = 0,
    linetype = "dashed",
    colour = "grey50"
  ) +
  geom_errorbarh(
    aes(xmin = lo, xmax = hi),
    height = .2,
    colour = "#0072B2"
  ) +
  geom_point(size = 2.6, colour = "#0072B2") +
  labs(
    title = "Top 20 and positions 21-100",
    subtitle = "Standardised differences with 95% bootstrap intervals",
    x = "Cohen's d (95% CI; negative = lower in top 20)",
    y = NULL
  ) +
  theme(
    plot.margin = margin(8, 16, 8, 22),
    axis.text.y = element_text(margin = margin(r = 6))
  )

ggsave(
  file.path(fig, "fig3_effect_sizes.png"),
  f3,
  width = 8,
  height = 4.4,
  dpi = 300
)

# Supplementary diagnostic: correlation among the model features.
cm <- cor(d[feats])
ord <- hclust(as.dist(1 - abs(cm)))$order
lv <- recode(rownames(cm)[ord], !!!lab)

cl <- as_tibble(cm, rownames = "x") %>%
  pivot_longer(-x, names_to = "y", values_to = "r") %>%
  mutate(
    x = factor(recode(x, !!!lab), levels = lv),
    y = factor(recode(y, !!!lab), levels = lv)
  )

f4 <- ggplot(cl, aes(x, y, fill = r)) +
  geom_tile(colour = "white") +
  geom_text(aes(label = sprintf("%.2f", r)), size = 3) +
  scale_fill_gradient2(
    low = "#0072B2",
    mid = "white",
    high = "#D55E00",
    midpoint = 0,
    limits = c(-1, 1)
  ) +
  labs(
    title = "Collinearity among stylometric features",
    x = NULL,
    y = NULL,
    fill = "r"
  ) +
  theme(axis.text.x = element_text(angle = 40, hjust = 1))

ggsave(
  file.path(fig, "diagnostic_feature_correlation.png"),
  f4,
  width = 7,
  height = 6,
  dpi = 300
)

message("02 complete.")
