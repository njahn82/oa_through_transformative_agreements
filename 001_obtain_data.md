# Gather data with BQ


## About

This notebook documents steps taken to obtain the publication volume and
corresponding market share from commercial publishers using open
metadata. The work is carried out using Google BigQuery.

<details class="code-fold">
<summary>Code</summary>

``` r
library(tidyverse)
library(bigrquery)
library(DBI)
library(countrycode)
library(rvest)

# Connect to GCBQ from SUB Göttingen
bq_con <- dbConnect(
  bigrquery::bigquery(),
  project = "subugoe-collaborative",
  dataset = "openalex",
  billing = "subugoe-collaborative"
)
```

</details>

## Create publication dataset

NB author position is not filled in SUB Göttignen OpenAlex Walden
snapshot. I infer by author position instead.

<details class="code-fold">
<summary>Code</summary>

``` sql
CREATE OR REPLACE TABLE `subugoe-closed.apc_science.md_raw` AS (
SELECT DISTINCT
    oalex.id,
    oalex.doi,
    publication_year,
    publication_date,
    primary_location.source.issn_l AS issn_l,
    oalex.primary_location.source.host_organization_name AS oalex_publisher,
    cr.publisher AS cr_publisher,
    primary_location.source.is_in_doaj AS is_in_doaj,
    open_access.oa_status AS oa_status,
    -- First Author
    country AS country_code,
    inst.ror
  FROM `subugoe-collaborative.openalex_walden.works` AS oalex
  LEFT JOIN
    UNNEST(authorships) AS au WITH OFFSET AS pos
  LEFT JOIN
    UNNEST(au.countries) AS country
  LEFT JOIN
    UNNEST(au.institutions) AS inst  
  LEFT JOIN `subugoe-collaborative.resources.document_classification_september25` as doctype_classifier ON oalex.doi = doctype_classifier.doi
  -- Obtain publisher info from Crossref
  INNER JOIN `subugoe-collaborative.cr_instant.snapshot` as cr ON LOWER(oalex.doi) = LOWER(cr.doi)
  WHERE
      pos = 0  -- first author only
    AND
      primary_location.source.type = "journal"
    AND
      is_paratext = FALSE
    AND 
       oalex.type IN ('article','review')
    AND
       is_research IS NOT FALSE
    AND 
      is_xpac = FALSE
    AND (
      NOT REGEXP_CONTAINS(oalex.biblio.issue, '^[a-zA-Z]')
      OR oalex.biblio.issue IS NULL)
    AND (
      NOT (
        REGEXP_CONTAINS(
          oalex.title,
          '[0-9]{3} pp.')))
    AND publication_year BETWEEN 2018 AND 2025
)
```

</details>

Create table with articles enabled by an TA

<details class="code-fold">
<summary>Code</summary>

``` sql
CREATE OR REPLACE TABLE `subugoe-closed.apc_science.jct_articles` AS (
WITH
  -- Part 1: Enrich ROR variants from associated institutions
  obtain_associated_ror_ids AS (
    SELECT
      esac_id,
      jct_inst.ror_id AS ror_jct,
      inst.ror AS ror_associated
    FROM
      `subugoe-collaborative.openbib.jct_institutions` AS jct_inst
    LEFT JOIN
      `subugoe-collaborative.openalex.institutions` AS oalex_inst
    ON
      jct_inst.ror_id = oalex_inst.ror
    LEFT JOIN
      UNNEST(oalex_inst.associated_institutions) AS inst
  ),

  create_matching_table AS (
    SELECT esac_id, 'ror_jct' AS ror_type, ror_jct AS ror
    FROM obtain_associated_ror_ids
    UNION ALL
    SELECT esac_id, 'ror_associated' AS ror_type, ror_associated AS ror
    FROM obtain_associated_ror_ids
  ),

  enriched_ror_variants AS (
    SELECT DISTINCT
      create_matching_table.*,
      DATE(jct_inst.start_date) AS start_date,
      DATE(jct_inst.end_date) AS end_date
    FROM create_matching_table
    INNER JOIN `subugoe-collaborative.openbib.jct_esac` AS jct_inst
      ON create_matching_table.esac_id = jct_inst.id
  ),

  journal_agreements AS (
    SELECT
      j.issn_l,
      e.id AS esac_id
    FROM `subugoe-collaborative.openbib.jct_journals` AS j
    INNER JOIN `subugoe-collaborative.openbib.jct_esac` AS e
      ON j.esac_id = e.id
  )

SELECT DISTINCT
  md.id,
  md.doi,
  md.issn_l AS matching_issn_l,
  md.ror AS matching_ror,
  erv.ror_type,
  erv.esac_id,
  erv.start_date,
  erv.end_date,
  md.publication_date
FROM `subugoe-closed.apc_science.md_raw` AS md
INNER JOIN journal_agreements AS ja
  ON md.issn_l = ja.issn_l
INNER JOIN enriched_ror_variants AS erv
  ON md.ror = erv.ror
  AND ja.esac_id = erv.esac_id
WHERE
  md.ror IS NOT NULL
  AND md.issn_l IS NOT NULL
  AND (PARSE_DATE('%Y-%m-%d', md.publication_date) >= erv.start_date OR erv.start_date IS NULL)
  AND (PARSE_DATE('%Y-%m-%d', md.publication_date) <= erv.end_date OR erv.end_date IS NULL)
  -- Only TA OA articles
  AND oa_status IN ('gold', 'hybrid')
ORDER BY erv.esac_id, md.publication_date
)
```

</details>

Create publisher-level table by publication_year.

<details class="code-fold">
<summary>Code</summary>

``` sql
WITH top_20 AS (
  SELECT cr_publisher, COUNT(DISTINCT doi) AS total_articles
  FROM `subugoe-closed.apc_science.md_raw`
  GROUP BY cr_publisher
  ORDER BY total_articles DESC
  LIMIT 20
),
labeled AS (
  SELECT 
    doi,
    publication_year,
    CASE WHEN t.cr_publisher IS NOT NULL THEN m.cr_publisher ELSE 'Other' END AS cr_publisher
  FROM `subugoe-closed.apc_science.md_raw` m
  LEFT JOIN top_20 t USING (cr_publisher)
)
SELECT COUNT(DISTINCT doi) as n_articles, cr_publisher, publication_year
FROM labeled
GROUP BY cr_publisher, publication_year
ORDER BY 
  CASE WHEN cr_publisher = 'Other' THEN 1 ELSE 0 END,  -- Other to bottom
  SUM(COUNT(DISTINCT doi)) OVER (PARTITION BY cr_publisher) DESC,
  publication_year DESC
```

</details>

<details class="code-fold">
<summary>Code</summary>

``` r
top_20_all
```

</details>

    # A tibble: 167 × 3
       n_articles cr_publisher                            publication_year
            <int> <chr>                                              <int>
     1     898482 Elsevier BV                                         2025
     2     809253 Elsevier BV                                         2024
     3     713157 Elsevier BV                                         2023
     4     671432 Elsevier BV                                         2022
     5     658957 Elsevier BV                                         2021
     6     654304 Elsevier BV                                         2020
     7     597536 Elsevier BV                                         2019
     8     575691 Elsevier BV                                         2018
     9     533300 Springer Science and Business Media LLC             2025
    10     463684 Springer Science and Business Media LLC             2024
    # ℹ 157 more rows

<details class="code-fold">
<summary>Code</summary>

``` r
write_csv(top_20_all, "data/top_20_all.csv")
```

</details>

Create publisher-level table by publication_year, oa_business_model.

<details class="code-fold">
<summary>Code</summary>

``` sql
WITH top_20 AS (
  SELECT cr_publisher, COUNT(DISTINCT doi) AS total_articles
  FROM `subugoe-closed.apc_science.md_raw`
  GROUP BY cr_publisher
  ORDER BY total_articles DESC
  LIMIT 20
),
labeled AS (
  SELECT 
    m.doi,
    m.publication_year,
    m.oa_status,
    CASE WHEN t.cr_publisher IS NOT NULL THEN m.cr_publisher ELSE 'Other' END AS cr_publisher,
    CASE
      WHEN m.is_in_doaj = TRUE OR m.cr_publisher IN ('MDPI AG', 'Frontiers Media SA', 'Public Library of Science (PLoS)') THEN 'Full OA' ELSE 'Hybrid'
    END AS journal_business_model,
    CASE WHEN jct.doi IS NOT NULL THEN TRUE ELSE FALSE END AS enabled_ta
  FROM `subugoe-closed.apc_science.md_raw` m
  LEFT JOIN top_20 t USING (cr_publisher)
  LEFT JOIN (SELECT DISTINCT doi FROM `subugoe-closed.apc_science.jct_articles`) AS jct
    USING (doi)
)
SELECT 
  cr_publisher, 
  publication_year,
  journal_business_model,
  COUNT(DISTINCT doi) AS n_articles, 
  COUNT(DISTINCT CASE WHEN oa_status IN ('gold', 'hybrid') THEN doi END) AS n_oa_articles,
  COUNT(DISTINCT CASE WHEN enabled_ta THEN doi END) AS n_ta_articles
FROM labeled
GROUP BY cr_publisher, publication_year, journal_business_model
ORDER BY 
  CASE WHEN cr_publisher = 'Other' THEN 1 ELSE 0 END,
  SUM(COUNT(DISTINCT doi)) OVER (PARTITION BY cr_publisher) DESC,
  publication_year DESC
```

</details>

<details class="code-fold">
<summary>Code</summary>

``` r
top_20_oa
```

</details>

    # A tibble: 310 × 6
       cr_publisher publication_year journal_business_model n_articles n_oa_articles
       <chr>                   <int> <chr>                       <int>         <int>
     1 Elsevier BV              2025 Hybrid                     720332        137943
     2 Elsevier BV              2025 Full OA                    178150        148596
     3 Elsevier BV              2024 Hybrid                     650168        122922
     4 Elsevier BV              2024 Full OA                    159085        132041
     5 Elsevier BV              2023 Hybrid                     579102         90362
     6 Elsevier BV              2023 Full OA                    134055        111262
     7 Elsevier BV              2022 Hybrid                     555595         63005
     8 Elsevier BV              2022 Full OA                    115837         94810
     9 Elsevier BV              2021 Hybrid                     554077         52102
    10 Elsevier BV              2021 Full OA                    104880         79671
    # ℹ 300 more rows
    # ℹ 1 more variable: n_ta_articles <int>

<details class="code-fold">
<summary>Code</summary>

``` r
write_csv(top_20_oa, "data/top_20_oa.csv")
```

</details>

Create publisher-level table by publication_year, oa_business_model and
country

<details class="code-fold">
<summary>Code</summary>

``` sql
WITH top_20 AS (
  SELECT cr_publisher, COUNT(DISTINCT doi) AS total_articles
  FROM `subugoe-closed.apc_science.md_raw`
  GROUP BY cr_publisher
  ORDER BY total_articles DESC
  LIMIT 20
),
labeled AS (
  SELECT 
    m.doi,
    m.publication_year,
    m.oa_status,
    m.country_code,
    CASE WHEN t.cr_publisher IS NOT NULL THEN m.cr_publisher ELSE 'Other' END AS cr_publisher,
    CASE
      WHEN m.is_in_doaj = TRUE OR m.cr_publisher IN ('MDPI AG', 'Frontiers Media SA', 'Public Library of Science (PLoS)') THEN 'Full OA' ELSE 'Hybrid'
    END AS journal_business_model,
    CASE WHEN jct.doi IS NOT NULL THEN TRUE ELSE FALSE END AS enabled_ta
  FROM `subugoe-closed.apc_science.md_raw` m
  LEFT JOIN top_20 t USING (cr_publisher)
  LEFT JOIN (SELECT DISTINCT doi FROM `subugoe-closed.apc_science.jct_articles`) AS jct
    USING (doi)
)
SELECT 
  cr_publisher,
  country_code,
  publication_year,
  journal_business_model,
  COUNT(DISTINCT doi) AS n_articles, 
  COUNT(DISTINCT CASE WHEN oa_status IN ('gold', 'hybrid') THEN doi END) AS n_oa_articles,
  COUNT(DISTINCT CASE WHEN enabled_ta THEN doi END) AS n_ta_articles
FROM labeled
GROUP BY cr_publisher, country_code, publication_year, journal_business_model
ORDER BY 
  CASE WHEN cr_publisher = 'Other' THEN 1 ELSE 0 END,
  SUM(COUNT(DISTINCT doi)) OVER (PARTITION BY cr_publisher) DESC,
  publication_year DESC
```

</details>

<details class="code-fold">
<summary>Code</summary>

``` r
top_20_by_country
```

</details>

    # A tibble: 43,889 × 7
       cr_publisher country_code publication_year journal_business_model n_articles
       <chr>        <chr>                   <int> <chr>                       <int>
     1 Elsevier BV  MX                       2025 Full OA                       486
     2 Elsevier BV  QA                       2025 Full OA                       141
     3 Elsevier BV  DZ                       2025 Hybrid                       1077
     4 Elsevier BV  NZ                       2025 Hybrid                        883
     5 Elsevier BV  CN                       2025 Hybrid                     190942
     6 Elsevier BV  EG                       2025 Hybrid                       2791
     7 Elsevier BV  DE                       2025 Hybrid                       7632
     8 Elsevier BV  US                       2025 Full OA                     13970
     9 Elsevier BV  IN                       2025 Hybrid                      22648
    10 Elsevier BV  HR                       2025 Hybrid                        326
    # ℹ 43,879 more rows
    # ℹ 2 more variables: n_oa_articles <int>, n_ta_articles <int>

<details class="code-fold">
<summary>Code</summary>

``` r
write_csv(top_20_by_country, "data/top_20_by_country.csv")
```

</details>
