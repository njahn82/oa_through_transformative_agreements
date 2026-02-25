# OA by funder


## Aim

The aim of this notebook is to demonstrate how to create a crosswalk of
different Google BigQuery datasets that can be discovered through
ORION-DBs. It would be interesting to track the development of open
access over the years by country and funder. Of particular interest is
comparing the US with European countries, since the NIH’s recent
proposals for supporting open access financially suggest similar funding
approaches, with transformative agreements playing an increasing role in
accommodating those costs and potential price caps.

## Overview of data sources used

In this notebook, we use the following sources to create a unified
dataset on open access uptake across countries and funders, focusing
particularly on publisher-provided open access through transformative
agreements.

The data sources to be cross-walked are:

- **Open access evidence**: OpenAlex provides article- and journal-level
  open access information. We use the February 2026 OpenAlex snapshot
  provided by SUB Göttingen.
- **Publisher metadata**: Crossref is used for publisher disambiguation,
  as it provides more coherent publisher names without imprints compared
  to OpenAlex.
- **Document classification**: A document classification dataset
  provided by SUB Göttingen is used to restrict the sample to original
  research articles.
- **Articles under transformative agreements**: SUB Göttingen provides a
  dataset about journals, institutions, and articles that are enabled by
  transformative agreements.
- **Grant-supported publications**: We use the OpenAIRE graph, provided
  by Sesame Open Science, to obtain grant-supported publications from
  the NIH and the European Commission.

When conducting open access analysis, it is important to relate it to a
meaningful overall sample. In this tutorial, we will focus on articles
representing original research, according to a document classification
approach, as they are often invoiced to institutions, and on articles
which are indexed in PubMed, to restrict ourselves to life sciences
literature. The latter can be inferred from both OpenAlex and OpenAIRE.

For country analysis, we use the first author’s country affiliation from
OpenAlex.

## Data gathering steps

### 1. Create publication metadata set

Initially, it is often helpful to start with a subset of publications
and select only the columns needed for your analysis. This saves on
query costs, keeps the dataset manageable, and safeguards the raw
metadata in case an ORION provider updates their data.

The first step is to create a publication dataset enriched with grant
funding information from the NIH and the European Commission. Funding
data are obtained from the OpenAIRE graph, as provided by Sesame Open
Science, and linked to publication metadata from OpenAlex and Crossref.

The query makes use of temporary tables introduced with `WITH`, also
known as Common Table Expressions (CTEs). The first CTE extracts funded
publications from OpenAIRE by unnesting the fundings array and filtering
for the two funders of interest, then joining to the OpenAIRE
publication and relation tables to retrieve the associated DOIs. This is
then joined to the main publication dataset.

In the main query, we select metadata about all articles in the OpenAlex
snapshot and apply a number of filters to restrict the dataset to
relevant publications. The focus is on original research articles and
reviews, using first author affiliations only. Note that in the OpenAlex
snapshot used here, the author position field was not exported by
OpenAlex, so first authors are identified using the `WITH OFFSET`
position. Crossref is used as the source for publisher metadata, as it
provides more coherent publisher disambiguation without imprints
compared to OpenAlex. The dataset is restricted to publications from
2018 to 2025.

To query BigQuery through our Quarto notebook, we use the R `bigrquery`
DBI interface. To connect:

``` r
library(tidyverse)
library(bigrquery)
library(DBI)
library(countrycode)

# Connect to GBQ with billing project from SUB Göttingen, 
# You have to use your own :-)
bq_con <- dbConnect(
  bigrquery::bigquery(),
  project = "subugoe-collaborative",
  dataset = "openalex",
  billing = "subugoe-collaborative"
)
```

We save the table in our resource datasets for misc datasets
`subugoe-collaborative.resources.oa_tutorial_md_raw`. You will need to
define your own dataset.

``` sql
CREATE OR REPLACE TABLE `subugoe-collaborative.resources.oa_tutorial_md_raw` AS (

WITH openaire_funders AS (
  SELECT DISTINCT
    pid.value AS doi,
    fund.name AS funder
  FROM `sos-datasources.openaire.project_20260129` AS proj,
    UNNEST(fundings) AS fund
  INNER JOIN `sos-datasources.openaire.relation_product_project_20260129` AS pub_proj 
    ON proj.id = pub_proj.target
  INNER JOIN `sos-datasources.openaire.publication_20260129` AS pub 
    ON pub_proj.source = pub.id,
    UNNEST(pub.pids) AS pid
  WHERE fund.name IN ('National Institutes of Health', 'European Commission')
    AND pid.scheme = 'doi'
)

SELECT DISTINCT
    oalex.id,
    oalex.doi,
    oalex.ids.pmid,
    oalex.ids.pmcid,
    publication_year,
    publication_date,
    primary_location.source.issn_l AS issn_l,
    oalex.primary_location.source.host_organization_name AS oalex_publisher,
    cr.publisher AS cr_publisher,
    primary_location.source.is_in_doaj AS is_in_doaj,
    open_access.oa_status AS oa_status,
    country AS country_code,
    inst.ror,
    oa.funder AS openaire_funder
  FROM `subugoe-collaborative.openalex_walden.works` AS oalex
  LEFT JOIN
    UNNEST(authorships) AS au WITH OFFSET AS pos
  LEFT JOIN
    UNNEST(au.countries) AS country
  LEFT JOIN
    UNNEST(au.institutions) AS inst  
  LEFT JOIN `subugoe-collaborative.resources.document_classification_september25` AS doctype_classifier 
    ON oalex.doi = doctype_classifier.doi
  INNER JOIN `subugoe-collaborative.cr_instant.snapshot` AS cr 
    ON LOWER(oalex.doi) = LOWER(cr.doi)
  LEFT JOIN openaire_funders AS oa 
    ON LOWER(oalex.doi) = LOWER(oa.doi)
  WHERE
      pos = 0
    AND primary_location.source.type = "journal"
    AND is_paratext = FALSE
    AND oalex.type IN ('article','review')
    AND is_research IS NOT FALSE
    AND is_xpac = FALSE
    AND (
      NOT REGEXP_CONTAINS(oalex.biblio.issue, '^[a-zA-Z]')
      OR oalex.biblio.issue IS NULL)
    AND (
      NOT REGEXP_CONTAINS(oalex.title, '[0-9]{3} pp.'))
    AND publication_year BETWEEN 2018 AND 2025
)
```

### 2. Estimate articles from transformative agreements

Next, we will estimate open access articles covered by a transformative
agreement using a method described in @Jahn_2025

The following query uses several datasets from the Journal Checker tool,
provided by SUB Göttingen in the OpenBib collection.

``` sql
CREATE OR REPLACE TABLE `subugoe-collaborative.resources.oa_tutorial_jct_articles` AS (
WITH
  -- Enrich ROR variants from associated institutions
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
FROM `subugoe-collaborative.resources.oa_tutorial_md_raw` AS md
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

With these two datasets compiled, we are ready to proceed with the open
access analysis.

## Data analysis
