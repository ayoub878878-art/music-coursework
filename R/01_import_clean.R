# =============================================================================
# 01_import_clean.R
# Import the Billboard source file, document its coverage, collapse duplicated
# collaboration rows, clean the lyrics, and calculate the lyric features used
# in the report. The raw CSV is never changed.
# =============================================================================
suppressPackageStartupMessages({
  library(tidyverse)
  library(janitor)
  library(here)
  library(tidytext)
})

select <- dplyr::select  # avoids a name clash if MASS is later attached
set.seed(2024)

raw_path       <- here("data", "raw", "billboard_24years_lyrics_spotify.csv")
processed_path <- here("data", "processed", "music_analysis.csv")
table_dir      <- here("output", "tables")

dir.create(dirname(processed_path), recursive = TRUE, showWarnings = FALSE)
dir.create(table_dir, recursive = TRUE, showWarnings = FALSE)

dictionary_path <- file.path(table_dir, "data_dictionary.csv")
log_path        <- file.path(table_dir, "cleaning_log.txt")
checks_path     <- file.path(table_dir, "data_quality_checks.csv")

log_lines <- character()
log_message <- function(...) {
  line <- paste0("[", format(Sys.time(), "%H:%M:%S"), "] ", paste0(...))
  log_lines <<- c(log_lines, line)
  message(line)
}

stop_if_count_differs <- function(label, actual, expected) {
  if (!identical(as.integer(actual), as.integer(expected))) {
    stop(label, " changed: expected ", expected, ", found ", actual,
         ". Check that the supplied raw CSV has not been altered.")
  }
}

# ---- Import and resolve the source columns ---------------------------------
if (!file.exists(raw_path)) stop("Raw file not found: ", raw_path)

raw_data <- readr::read_csv(raw_path, show_col_types = FALSE, guess_max = 50000)
clean_data <- janitor::clean_names(raw_data)

resolve_name <- function(column_names, alternatives) {
  hits <- column_names[column_names %in% alternatives]
  if (length(hits) > 0) hits[1] else NA_character_
}

column_names <- names(clean_data)
resolved <- list(
  year    = resolve_name(column_names, c("year")),
  rank    = resolve_name(column_names, c("ranking", "rank")),
  song    = resolve_name(column_names, c("song", "title")),
  artist  = resolve_name(column_names, c("band_singer", "artist")),
  lyrics  = resolve_name(column_names, c("lyrics")),
  songurl = resolve_name(column_names, c("songurl")),
  uri     = resolve_name(column_names, c("uri"))
)

if (is.na(resolved$year)) stop("No year column was found.")
if (is.na(resolved$rank)) stop("No year-end rank column was found.")
if (is.na(resolved$lyrics)) stop("No lyric column was found.")

rename_map <- c(year = resolved$year, rank = resolved$rank, lyrics = resolved$lyrics)
for (field in c("song", "artist", "songurl", "uri")) {
  if (!is.na(resolved[[field]])) {
    rename_map <- c(rename_map, setNames(resolved[[field]], field))
  }
}
clean_data <- clean_data %>% rename(!!!rename_map)
log_message("Imported ", nrow(clean_data), " source rows.")

# ---- Audit audio coverage before deciding the analysis scope ---------------
# Danceability is used as the coverage marker because the Spotify audio fields
# are missing together in this file. The same 2,911 rows are missing each of
# the thirteen audio columns used in the check below.
audio_columns <- c(
  "danceability", "energy", "key", "loudness", "mode", "speechiness",
  "acousticness", "instrumentalness", "liveness", "valence", "tempo",
  "duration_ms", "time_signature"
)
available_audio_columns <- intersect(audio_columns, names(clean_data))
missing_audio_columns <- setdiff(audio_columns, available_audio_columns)
if (length(missing_audio_columns) > 0) {
  stop("Audio-coverage fields are missing: ", paste(missing_audio_columns, collapse = ", "))
}

audio_field_missingness <- tibble(
  field = audio_columns,
  missing_rows = map_int(audio_columns, ~sum(is.na(clean_data[[.x]])))
) %>%
  mutate(missing_percent = 100 * missing_rows / nrow(clean_data))
if (any(audio_field_missingness$missing_rows != 2911)) {
  stop("The Spotify audio columns no longer share the expected missingness pattern.")
}
readr::write_csv(
  audio_field_missingness,
  file.path(table_dir, "audio_field_missingness.csv")
)

audio_missing_rows <- sum(is.na(clean_data$danceability))
audio_available_rows <- nrow(clean_data) - audio_missing_rows
audio_missing_percent <- 100 * audio_missing_rows / nrow(clean_data)

audio_coverage_by_year <- clean_data %>%
  transmute(year = as.numeric(year), has_audio = !is.na(danceability)) %>%
  filter(!is.na(year), year >= 2000, year <= 2023) %>%
  group_by(year) %>%
  summarise(
    source_rows = n(),
    rows_with_audio = sum(has_audio),
    audio_coverage_percent = 100 * mean(has_audio),
    .groups = "drop"
  )
readr::write_csv(audio_coverage_by_year,
                 file.path(table_dir, "audio_coverage_by_year.csv"))

available_2000_2004 <- clean_data %>%
  filter(!is.na(danceability), as.numeric(year) >= 2000, as.numeric(year) <= 2004) %>%
  nrow()

stop_if_count_differs("Raw row count", nrow(clean_data), 3397)
stop_if_count_differs("Rows missing Spotify audio features", audio_missing_rows, 2911)
stop_if_count_differs("Rows with Spotify audio features", audio_available_rows, 486)
stop_if_count_differs("Audio-complete rows from 2000-2004", available_2000_2004, 483)
if (!isTRUE(all.equal(round(audio_missing_percent, 1), 85.7))) {
  stop("Audio missingness changed: expected 85.7%, found ",
       round(audio_missing_percent, 1), "%.")
}

log_message(
  "Spotify audio fields are missing for ", audio_missing_rows, " of ",
  nrow(clean_data), " rows (", round(audio_missing_percent, 1), "%). ",
  available_2000_2004, " of the ", audio_available_rows,
  " audio-complete rows are from 2000-2004; only three are later."
)

# ---- Keep the study window and audit duplicated year-rank rows -------------
source_rows <- clean_data %>%
  mutate(year = as.numeric(year), rank = as.numeric(rank)) %>%
  filter(
    !is.na(year), year >= 2000, year <= 2023,
    !is.na(rank), rank >= 1,
    !is.na(lyrics)
  )

duplicate_audit <- source_rows %>%
  group_by(year, rank) %>%
  summarise(
    source_rows = n(),
    distinct_raw_lyric_texts = n_distinct(lyrics),
    .groups = "drop"
  )

multirow_groups <- sum(duplicate_audit$source_rows > 1)
nonidentical_lyric_groups <- sum(
  duplicate_audit$source_rows > 1 & duplicate_audit$distinct_raw_lyric_texts > 1
)
extra_source_rows <- sum(duplicate_audit$source_rows - 1)

stop_if_count_differs("Eligible source rows", nrow(source_rows), 3397)
stop_if_count_differs("Unique year-rank groups", nrow(duplicate_audit), 2393)
stop_if_count_differs("Multirow year-rank groups", multirow_groups, 791)
stop_if_count_differs("Groups with non-identical raw lyric texts",
                      nonidentical_lyric_groups, 169)
stop_if_count_differs("Extra collaboration rows collapsed", extra_source_rows, 1004)

readr::write_csv(
  duplicate_audit %>% filter(source_rows > 1),
  file.path(table_dir, "duplicate_group_audit.csv")
)

has_song <- "song" %in% names(source_rows)
has_artist <- "artist" %in% names(source_rows)
has_songurl <- "songurl" %in% names(source_rows)
has_uri <- "uri" %in% names(source_rows)

# The first lyric is retained for each year-rank group. This is an operational
# deduplication rule, not a claim that all source versions were identical.
charted_songs <- source_rows %>%
  group_by(year, rank) %>%
  summarise(
    song = if (has_song) first(song) else NA_character_,
    artist = if (has_artist) paste(unique(artist), collapse = " & ") else NA_character_,
    songurl = if (has_songurl) first(songurl) else NA_character_,
    uri = if (has_uri) first(uri) else NA_character_,
    lyrics = first(lyrics),
    .groups = "drop"
  )

log_message(
  "Collapsed ", nrow(source_rows), " source rows into ", nrow(charted_songs),
  " year-rank groups. Of the multirow groups, ", nonidentical_lyric_groups,
  " contained more than one raw lyric text; the first text was retained."
)

charted_songs <- charted_songs %>%
  mutate(
    track_id = coalesce(
      na_if(songurl, ""),
      na_if(uri, ""),
      str_to_lower(str_squish(coalesce(song, "")))
    ),
    rowid = row_number(),
    top_20 = factor(if_else(rank <= 20, "top20", "other"),
                    levels = c("other", "top20")),
    period = cut(
      year,
      breaks = c(1999, 2005, 2011, 2017, 2023),
      labels = c("2000-2005", "2006-2011", "2012-2017", "2018-2023")
    )
  )

# ---- Clean the Genius-scraped lyric text -----------------------------------
# The ASCII-only rule below matches the submitted analysis. Accents and
# non-Latin characters are removed, so this choice is recorded as a limitation.
clean_lyrics <- function(text) {
  text %>%
    str_replace_all("\\\\n", " ") %>%
    str_replace_all(regex("you might also like", ignore_case = TRUE), " ") %>%
    str_replace_all("\\d*Embed\\b", " ") %>%
    str_replace_all("\\[[^\\]]*\\]", " ") %>%
    str_replace_all("[^A-Za-z'\\s]", " ") %>%
    str_squish() %>%
    str_to_lower()
}

charted_songs <- charted_songs %>% mutate(cleaned_lyrics = clean_lyrics(lyrics))

# ---- Lyric feature functions -----------------------------------------------
# MTLD is a lexical-diversity measure designed to be less dependent on text
# length than ordinary type-token ratio (McCarthy & Jarvis, 2010).
mtld_one <- function(tokens, threshold = 0.72) {
  directional_mtld <- function(ordered_tokens) {
    if (length(ordered_tokens) < 10) return(NA_real_)

    factors <- 0
    observed_types <- character()
    current_length <- 0

    for (word in ordered_tokens) {
      current_length <- current_length + 1
      observed_types <- union(observed_types, word)
      current_ttr <- length(observed_types) / current_length

      if (current_ttr <= threshold) {
        factors <- factors + 1
        observed_types <- character()
        current_length <- 0
      }
    }

    if (current_length > 0) {
      partial_ttr <- length(observed_types) / current_length
      factors <- factors + (1 - partial_ttr) / (1 - threshold)
    }

    if (factors == 0) NA_real_ else length(ordered_tokens) / factors
  }

  mean(c(directional_mtld(tokens), directional_mtld(rev(tokens))), na.rm = TRUE)
}

# Compressed byte length divided by cleaned lyric byte length. Because the
# cleaned lyrics are ASCII, byte length and character count are the same here.
# A lower ratio indicates more repeated or compressible text.
compression_ratio_one <- function(text) {
  cleaned_bytes <- nchar(text, type = "bytes")
  if (cleaned_bytes < 1) return(NA_real_)
  length(memCompress(charToRaw(text), type = "gzip")) / cleaned_bytes
}

# ---- Calculate lyric features ----------------------------------------------
tokens <- charted_songs %>%
  select(rowid, cleaned_lyrics) %>%
  unnest_tokens(word, cleaned_lyrics)

word_features <- tokens %>%
  group_by(rowid) %>%
  summarise(
    word_count = n(),
    distinct_word_types = n_distinct(word),
    avg_word_length = mean(nchar(word)),
    # Number of once-only word types divided by all word tokens.
    hapax_ratio = sum(table(word) == 1) / n(),
    mtld = mtld_one(word),
    .groups = "drop"
  ) %>%
  mutate(ttr = distinct_word_types / word_count)

data("stop_words", package = "tidytext", envir = environment())
repetition_features <- tokens %>%
  anti_join(stop_words, by = "word") %>%
  count(rowid, word) %>%
  group_by(rowid) %>%
  summarise(
    repetition_score = max(n) / sum(n),
    .groups = "drop"
  )

analysis_data <- charted_songs %>%
  mutate(compression_ratio = map_dbl(cleaned_lyrics, compression_ratio_one)) %>%
  left_join(word_features, by = "rowid") %>%
  left_join(repetition_features, by = "rowid") %>%
  mutate(repetition_score = coalesce(repetition_score, 0)) %>%
  filter(word_count >= 20) %>%
  drop_na(word_count, mtld, avg_word_length, repetition_score,
          hapax_ratio, compression_ratio)

model_features <- c(
  "word_count", "mtld", "avg_word_length", "repetition_score",
  "hapax_ratio", "compression_ratio"
)

stop_if_count_differs("Final analysis rows", nrow(analysis_data), 2392)
stop_if_count_differs("Unique track IDs", n_distinct(analysis_data$track_id), 2169)

log_message(
  "Analysis rows: ", nrow(analysis_data),
  "; unique track IDs: ", n_distinct(analysis_data$track_id),
  "; top-20 share: ",
  round(100 * mean(analysis_data$top_20 == "top20"), 1), "%"
)

processed_data <- analysis_data %>%
  select(
    rowid, track_id, year, period, rank, top_20,
    all_of(model_features), ttr, any_of(c("song", "artist"))
  )
readr::write_csv(processed_data, processed_path)

# The definitions describe the quantities actually calculated above.
data_dictionary <- tribble(
  ~variable, ~definition,
  "rowid", "Row number assigned after year-rank deduplication",
  "track_id", "Song URL, then Spotify URI, then normalised song title used as the track identifier",
  "year", "Billboard year-end chart year",
  "period", "Six-year descriptive period",
  "rank", "Position in the Billboard year-end Hot 100",
  "top_20", "top20 when rank is 1-20; other when rank is 21-100",
  "word_count", "Number of word tokens after lyric cleaning",
  "mtld", "Measure of Textual Lexical Diversity; calculated forwards and backwards with threshold 0.72",
  "avg_word_length", "Mean number of characters per cleaned word token",
  "repetition_score", "Frequency of the most common non-stopword divided by the number of non-stopword tokens",
  "hapax_ratio", "Number of word types occurring once divided by the total number of word tokens",
  "compression_ratio", "gzip-compressed byte length divided by the byte length of the cleaned lyric; lower values indicate more compressible text",
  "ttr", "Number of distinct word types divided by word tokens; retained only for the length diagnostic",
  "song", "Song title retained from the first row in each year-rank group",
  "artist", "Artist names combined within each year-rank group"
)
readr::write_csv(data_dictionary, dictionary_path)

quality_checks <- tribble(
  ~check, ~actual, ~expected,
  "raw_rows", nrow(clean_data), 3397,
  "audio_missing_rows", audio_missing_rows, 2911,
  "audio_missing_percent_rounded_1dp", round(audio_missing_percent, 1), 85.7,
  "audio_available_rows", audio_available_rows, 486,
  "audio_available_rows_2000_2004", available_2000_2004, 483,
  "eligible_source_rows", nrow(source_rows), 3397,
  "unique_year_rank_groups", nrow(duplicate_audit), 2393,
  "multirow_year_rank_groups", multirow_groups, 791,
  "nonidentical_raw_lyric_groups", nonidentical_lyric_groups, 169,
  "extra_source_rows_collapsed", extra_source_rows, 1004,
  "final_analysis_rows", nrow(analysis_data), 2392,
  "unique_track_ids", n_distinct(analysis_data$track_id), 2169
) %>%
  mutate(passed = actual == expected)
readr::write_csv(quality_checks, checks_path)

writeLines(log_lines, log_path)
message("01 complete: ", processed_path)
