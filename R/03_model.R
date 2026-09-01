# =============================================================================
# 03_model.R  -- RQ3 with a deliberately rigorous validation design:
#   * chronological split (train 2000-2018, test 2019-2023)
#   * multivariable logistic; odds ratios with year-cluster bootstrap CIs
#   * permutation test and bootstrap CI for the test-set AUC (is it > chance?)
#   * rolling-origin (expanding-window) temporal cross-validation
#   * elastic-net logistic (does any feature survive regularisation?)
#   * mixed-effects logistic with a year random intercept (panel structure)
# Base glm is used for the primary model so odds ratios are interpretable;
# glmnet/lme4 provide sensitivity checks. Produces report Figures 4-5.
# =============================================================================
suppressPackageStartupMessages({
  library(tidyverse)
  library(here)
  library(patchwork)
  library(glmnet)
  library(lme4)
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
  mutate(y = as.integer(top_20 == "top20"))
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
  mtld = "MTLD",
  avg_word_length = "Avg word length",
  repetition_score = "Repetition",
  hapax_ratio = "Hapax ratio",
  compression_ratio = "Compression ratio"
)
form <- as.formula(paste("y ~", paste(feats, collapse = " + ")))
auc <- function(y, s) {
  r <- rank(s)
  n1 <- sum(y == 1)
  n0 <- sum(y == 0)
  (sum(r[y == 1]) - n1 * (n1 + 1) / 2) / (n1 * n0)
}

# chronological split + standardisation on TRAIN only
tr <- d %>%
  filter(year <= 2018)
te <- d %>%
  filter(year >= 2019)

# The test set contains later song-year observations. It is not a completely
# unseen-track test because a small number of tracks chart in both periods.
shared_track_ids <- intersect(unique(tr$track_id), unique(te$track_id))
shared_test_rows <- te %>% filter(track_id %in% shared_track_ids)
if (nrow(shared_test_rows) != 11 || length(shared_track_ids) != 11) {
  stop(
    "Train-test track overlap changed: expected 11 test rows and 11 track IDs; found ",
    nrow(shared_test_rows),
    " rows and ",
    length(shared_track_ids),
    " IDs."
  )
}
readr::write_csv(
  shared_test_rows %>% select(year, rank, song, artist, track_id),
  file.path(tab, "shared_test_track_ids.csv")
)
readr::write_csv(
  tibble(
    metric = c("training_rows", "test_rows", "shared_test_rows", "shared_track_ids"),
    value = c(nrow(tr), nrow(te), nrow(shared_test_rows), length(shared_track_ids))
  ),
  file.path(tab, "split_overlap_check.csv")
)
message(
  "Chronological split: ",
  nrow(tr),
  " training rows; ",
  nrow(te),
  " test rows; ",
  nrow(shared_test_rows),
  " test rows share a track ID with training."
)

mu <- sapply(tr[feats], mean)
sdv <- sapply(tr[feats], sd)
Ztr <- as.data.frame(scale(tr[feats], mu, sdv))
Ztr$y <- tr$y
Ztr$year <- tr$year
Zte <- as.data.frame(scale(te[feats], mu, sdv))
Zte$y <- te$y
fit <- glm(form, data = Ztr, family = binomial())
pte <- predict(fit, Zte, type = "response")
A <- auc(te$y, pte)
message("Test AUC (2019-2023): ", round(A, 3))

# permutation test + bootstrap CI for AUC
perm <- replicate(2000, {
  yp <- sample(Ztr$y)
  f <- glm(
    update(form, yp ~ .),
    data = cbind(Ztr, yp = yp),
    family = binomial()
  )
  auc(te$y, predict(f, Zte, type = "response"))
})
perm_p <- mean(perm >= A)
bootA <- replicate(2000, {
  i <- sample(nrow(Zte), replace = TRUE)
  auc(Zte$y[i], pte[i])
})
readr::write_csv(
  tibble(iteration = seq_along(perm), permuted_auc = perm),
  file.path(tab, "permutation_auc_distribution.csv")
)

# rolling-origin CV
roll <- map_dfr(2010:2022, function(t) {
  t2 <- d %>%
    filter(year <= t)
  e2 <- d %>%
    filter(year == t + 1)

  if (nrow(e2) < 20 || length(unique(t2$y)) < 2) {
    return(NULL)
  }

  m <- sapply(t2[feats], mean)
  s <- sapply(t2[feats], sd)
  Z1 <- as.data.frame(scale(t2[feats], m, s))
  Z1$y <- t2$y
  Z2 <- as.data.frame(scale(e2[feats], m, s))

  tibble(
    test_year = t + 1,
    auc = auc(
      e2$y,
      predict(
        glm(form, data = Z1, family = binomial()),
        Z2,
        type = "response"
      )
    )
  )
})

readr::write_csv(
  tibble(
    metric = c(
      "training_rows",
      "test_rows",
      "shared_test_rows",
      "shared_track_ids",
      "test_auc",
      "permutation_p",
      "boot_auc_lo",
      "boot_auc_hi",
      "rolling_mean_auc",
      "rolling_sd_auc",
      "rolling_min_auc",
      "rolling_max_auc"
    ),
    value = c(
      nrow(tr),
      nrow(te),
      nrow(shared_test_rows),
      length(shared_track_ids),
      A,
      perm_p,
      quantile(bootA, .025),
      quantile(bootA, .975),
      mean(roll$auc),
      sd(roll$auc),
      min(roll$auc),
      max(roll$auc)
    )
  ),
  file.path(tab, "rq3_validation.csv")
)
readr::write_csv(roll, file.path(tab, "rolling_cv.csv"))

# odds ratios with year-cluster bootstrap CIs (resample YEARS)
yrs <- unique(tr$year)
cb <- replicate(1000, {
  sy <- sample(yrs, replace = TRUE)
  dd <- map_dfr(sy, ~ tr[tr$year == .x, ])
  Zc <- as.data.frame(scale(dd[feats], mu, sdv))
  Zc$y <- dd$y
  coef(glm(form, data = Zc, family = binomial()))
})
or <- tibble(
  feature = feats,
  OR = exp(apply(cb, 1, median))[-1],
  lo = exp(apply(cb, 1, quantile, .025))[-1],
  hi = exp(apply(cb, 1, quantile, .975))[-1]
)
readr::write_csv(or, file.path(tab, "odds_ratios.csv"))
print(or)

# Elastic net is a sensitivity check using ordinary random 10-fold CV within
# the training period. It is not a second time-blocked validation.
cvfit <- cv.glmnet(
  as.matrix(Ztr[feats]),
  Ztr$y,
  family = "binomial",
  alpha = 0.5,
  nfolds = 10
)
enet <- as.matrix(coef(cvfit, s = "lambda.1se"))
enet <- enet[enet[, 1] != 0, , drop = FALSE]
readr::write_csv(
  as_tibble(enet, rownames = "term") %>%
    rename(coef = s1),
  file.path(tab, "elasticnet_1se.csv")
)

# mixed-effects logistic (year random intercept)
me <- tryCatch(
  glmer(
    update(form, . ~ . + (1 | year)),
    data = Ztr,
    family = binomial(),
    control = glmerControl(optimizer = "bobyqa")
  ),
  error = function(e) NULL
)
if (!is.null(me)) {
  writeLines(
    c(
      paste(
        "year_random_intercept_sd =",
        round(attr(lme4::VarCorr(me)$year, "stddev"), 3)
      ),
      capture.output(print(round(exp(fixef(me)), 3)))
    ),
    file.path(tab, "mixed_effects.txt")
  )
}

# ---- Figure 4: rolling-origin AUC + permutation null -----------------------
fa <- ggplot(roll, aes(test_year, auc)) +
  geom_hline(
    yintercept = .5,
    linetype = "dashed",
    colour = "grey50"
  ) +
  geom_hline(
    yintercept = mean(roll$auc),
    colour = "#D55E00",
    linewidth = .6
  ) +
  geom_line(colour = "#0072B2") +
  geom_point(colour = "#0072B2", size = 2) +
  ylim(.35, .7) +
  labs(
    title = "Rolling-origin validation",
    subtitle = sprintf(
      "Train<=t, test t+1; mean AUC=%.2f (orange), chance=0.5",
      mean(roll$auc)
    ),
    x = "Test year",
    y = "ROC AUC"
  )
fb <- ggplot(tibble(perm = perm), aes(perm)) +
  geom_histogram(bins = 40, fill = "#0072B2", alpha = .6) +
  geom_vline(xintercept = A, colour = "#D55E00", linewidth = .9) +
  labs(
    title = "Permutation test for test AUC",
    subtitle = sprintf(
      "Observed=%.3f (orange); label-permuted null; p=%.3f",
      A,
      perm_p
    ),
    x = "AUC under permuted labels",
    y = "Count"
  )
ggsave(
  file.path(fig, "fig4_validation.png"),
  fa | fb,
  width = 11,
  height = 4.3,
  dpi = 300
)

# ---- Figure 5: odds-ratio forest (year-cluster bootstrap CI) ---------------
f6 <- or %>%
  mutate(
    flab = recode(feature, !!!lab),
    flab = fct_reorder(flab, OR)
  ) %>%
  ggplot(aes(OR, flab)) +
  geom_vline(
    xintercept = 1,
    linetype = "dashed",
    colour = "grey50"
  ) +
  geom_errorbarh(
    aes(xmin = lo, xmax = hi),
    height = .2,
    colour = "#0072B2"
  ) +
  geom_point(size = 2.6, colour = "#0072B2") +
  scale_x_log10() +
  labs(
    title = "Odds ratios per 1 SD (year-cluster bootstrap 95% CI)",
    subtitle = "Multivariable logistic; dashed = no association",
    x = "Odds ratio",
    y = NULL
  )
ggsave(
  file.path(fig, "fig5_odds_ratios.png"),
  f6,
  width = 7,
  height = 4.2,
  dpi = 300
)

writeLines(capture.output(sessionInfo()), file.path(tab, "session_info.txt"))
message(
  "03 complete. Test AUC=",
  round(A, 3),
  " perm p=",
  round(perm_p, 3),
  " rolling mean=",
  round(mean(roll$auc), 3)
)
