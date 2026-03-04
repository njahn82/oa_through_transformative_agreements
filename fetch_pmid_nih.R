library(tidyverse)
library(rentrez)

# Set your NCBI API key
set_entrez_key(Sys.getenv("ENTREZ_KEY"))

base_term <- '("nih"[Grants and Funding]) AND (medline[Filter])'

# Build monthly queries with correct PubMed date format
queries <- expand_grid(year = 2018:2024, month = 1:12) |>
  mutate(
    dim = days_in_month(make_date(year, month, 1)),
    start_date = str_glue("{year}/{str_pad(month, 2, pad='0')}/01"),
    end_date   = str_glue("{year}/{str_pad(month, 2, pad='0')}/{str_pad(dim, 2, pad='0')}"),
    term       = str_glue('{base_term} AND ({start_date}:{end_date}[pdat])')
  )

all_pmids <- pmap(queries, \(year, month, term, ...) {
  Sys.sleep(0.15)
  n <- entrez_search(db = "pubmed", term = term, retmax = 0)$count
  cat(year, "-", str_pad(month, 2, pad = "0"), ":", n, "\n")

  if (n == 0) return(character(0))

  if (n <= 9999) {
    Sys.sleep(0.15)
    return(entrez_search(db = "pubmed", term = term, retmax = 9999)$ids)
  }

  # > 9999 in a month — split by day
  cat("  Splitting by day...\n")
  dim <- days_in_month(make_date(year, month, 1))

  map(1:dim, \(day) {
    d <- str_glue("{year}/{str_pad(month, 2, pad='0')}/{str_pad(day, 2, pad='0')}")
    day_term <- str_glue('{base_term} AND ({d}:{d}[pdat])')
    Sys.sleep(0.15)
    entrez_search(db = "pubmed", term = day_term, retmax = 9999)$ids
  }) |> list_c()
}) |> list_c() |> unique()

write_lines(unique(all_pmids), "nih_pmids_2018_2024.txt")


