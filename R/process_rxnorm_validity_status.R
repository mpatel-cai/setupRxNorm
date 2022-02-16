#' @title
#' Process the RxNorm Validity Table
#'
#' @description
#' Retrieve and cache concept batches by
#' its validity status from
#' the RxNav REST API and write a
#' table that maps an input RxCUI or RxNorm
#' code to its most current RxCUI or RxNorm code.
#'
#'
#'
#'
#' @rdname process_rxnorm_validity_status
#' @export
#' @import httr
#' @import tidyverse
#' @importFrom pg13 send query write_table drop_table
#' @importFrom glue glue
#' @importFrom dplyr arrange filter

process_rxnorm_validity_status <-
  function(conn,
           conn_fun = "pg13::local_connect(verbose = {verbose})",
           processing_schema = "process_rxnorm_validity_status",
           destination_schema = "rxtra",
           rm_processing_schema = TRUE,
           checks = "",
           verbose = TRUE,
           render_sql = TRUE,
           render_only = FALSE) {

    if (missing(conn)) {
      conn <- eval(rlang::parse_expr(conn_fun))
      on.exit(pg13::dc(conn = conn),
        add = TRUE,
        after = TRUE
      )
    }

    if (requires_processing(
          conn = conn,
          target_schema = destination_schema,
          target_table = "rxnorm_validity_status",
          verbose = verbose,
          render_sql = render_sql)) {

      key  <- get_rxnav_api_version()
      dirs <- file.path("setupRxNorm", version_key$version, "RxNorm Validity Status")


      rxnorm_statuses <-
        c(
          "Active",
          "Remapped",
          "Obsolete",
          "Quantified",
          "NotCurrent"
        )

      out <-
        vector(
          mode = "list",
          length = length(rxnorm_statuses)
        )
      names(out) <-
        rxnorm_statuses

      cli::cli_progress_bar(
        format = paste0(
          "{pb_spin} Calling {.url {link}} ",
          "[{pb_current}/{pb_total}]   ETA:{pb_eta}"
        ),
        format_done = paste0(
          "[as.character(Sys.time())] {col_green(symbol$tick)} Downloaded {pb_total} files ",
          "in {pb_elapsed}."
        ),
        total = length(rxnorm_statuses),
        clear = FALSE
      )

      for (rxnorm_status in rxnorm_statuses) {
        cli::cli_progress_update()
        Sys.sleep(.1)

        link <-
          glue::glue("https://rxnav.nlm.nih.gov/REST/allstatus.json?status={rxnorm_status}")
        status_key <-
          c(key,
            link = link
          )

        status_results <-
          R.cache::loadCache(
            dirs = dirs,
            key = status_key
          )

        if (is.null(status_results)) {
          Sys.sleep(2.9)
          updated_rxcui <-
            GET(link)

          abort_on_api_error(updated_rxcui)


          status_content <-
            content(
              x = updated_rxcui,
              as = "parsed"
            )[[1]][[1]] %>%
            transpose() %>%
            map(unlist) %>%
            as_tibble() %>%
            transmute(
              rxcui,
              code = rxcui,
              str = name,
              tty,
              status = rxnorm_status
            )

          R.cache::saveCache(
            dirs = dirs,
            key = status_key,
            object = status_content
          )

          status_results <-
            R.cache::loadCache(
              dirs = dirs,
              key = status_key
            )
        }

        out[[rxnorm_status]] <-
          status_results
      }


      rxnorm_api_version <-
        sprintf("%s %s", key$version, key$apiVersion)

      out <-
        bind_rows(out) %>%
        mutate(
          "rxnorm_api_version" =
            rxnorm_api_version
        )


      tmp_csv <- tempfile()
      readr::write_csv(
        x = out,
        file = tmp_csv,
        na = "",
        quote = "all"
      )


      sql_statement <-
        glue::glue(
          "
      DROP SCHEMA IF EXISTS {processing_schema} CASCADE;

      CREATE SCHEMA {processing_schema};

      DROP TABLE IF EXISTS {processing_schema}.rxnorm_concept_status0;
      CREATE TABLE {processing_schema}.rxnorm_concept_status0 (
              rxcui     INTEGER NOT NULL,
              code      VARCHAR(50) NOT NULL,
              str       VARCHAR(3000) NOT NULL,
              tty       VARCHAR(20) NOT NULL,
              status    VARCHAR(10) NOT NULL,
              rxnorm_api_version VARCHAR(30) NOT NULL
      )
      ;

      COPY {processing_schema}.rxnorm_concept_status0 FROM '{tmp_csv}' CSV HEADER QUOTE E'\"' NULL AS '';

      DROP TABLE IF EXISTS {processing_schema}.rxnorm_concept_status1;
      CREATE TABLE {processing_schema}.rxnorm_concept_status1 AS (
        SELECT
          s0.rxcui AS input_rxcui,
          s0.code AS input_code,
          s0.str AS input_str,
          s0.tty AS input_tty,
          s0.status AS input_status,
          s0.rxnorm_api_version,
          arch.merged_to_rxcui AS output_rxcui,
          rx.code AS output_code,
          rx.str  AS output_str,
          rx.tty  AS output_tty,
          CASE
    WHEN rx.tty IN ('IN', 'PIN', 'MIN') THEN 1 --Ingredient, Name from a precise ingredient, Multiple Ingredient
    WHEN rx.tty IN ('BN') THEN 2 --Fully-specified drug brand name that can not be prescribed
    WHEN rx.tty IN ('DF') THEN 3 --Dose Form
    WHEN rx.tty IN ('DFG') THEN 4 --Dose Form Group
    WHEN rx.tty IN ('SY')  THEN 5 --Synonym
      --'TMSY' --Tall Man synonym
      --'SY' --Designated synonym
      --'SCDG' --Semantic clinical drug group
      --'SCDF' --Semantic clinical drug and form
      --'SCDC' --Semantic Drug Component
      --'SCD' --Semantic Clinical Drug
      --'SBDG' --Semantic branded drug group
      --'SBDF' --Semantic branded drug and form
      --'SBDC' --Semantic Branded Drug Component
      --'SBD' --Semantic branded drug
      --'PSN' --Prescribable Names
      --'GPCK' --Generic Drug Delivery Device
      --'ET' --Entry term
      --'BPCK' --Branded Drug Delivery Device
    ELSE 6 end tty_rank
        FROM {processing_schema}.rxnorm_concept_status0 s0
        LEFT JOIN (SELECT * FROM rxnorm.rxnatomarchive WHERE sab = 'RXNORM') arch
        ON
          arch.rxcui = s0.rxcui
          AND arch.tty = s0.tty
          AND arch.str = s0.str
        LEFT JOIN (SELECT * FROM rxnorm.rxnconso WHERE sab = 'RXNORM') rx
        ON rx.rxcui = arch.merged_to_rxcui
        LEFT JOIN {processing_schema}.rxnorm_concept_status0 s1
        ON s0.rxcui = s1.rxcui
      );

      DROP TABLE IF EXISTS {processing_schema}.rxnorm_concept_status2;
      CREATE TABLE {processing_schema}.rxnorm_concept_status2 AS (
        SELECT
         s1.*,
         ROW_NUMBER() over (partition by input_rxcui order by tty_rank) as final_rank
        FROM {processing_schema}.rxnorm_concept_status1 s1
      )
      ;

      DROP TABLE IF EXISTS {processing_schema}.rxnorm_concept_status3_a;
      CREATE TABLE {processing_schema}.rxnorm_concept_status3_a AS (
        SELECT DISTINCT
          s2.input_rxcui,
          s2.input_code,
          s2.input_str,
          s2.input_tty,
          s2.input_status,
          CASE
            WHEN s2.input_status = 'Remapped' THEN s2.output_rxcui
            ELSE s2.input_rxcui
            END output_rxcui,
          CASE
            WHEN s2.input_status = 'Remapped' THEN s2.output_code
            ELSE s2.input_code
            END output_code,
          CASE
            WHEN s2.input_status = 'Remapped' THEN s2.output_str
            ELSE s2.input_str
            END output_str,
          CASE
            WHEN s2.input_status = 'Remapped' THEN s2.output_tty
            ELSE s2.input_tty
            END output_tty,
          s2.tty_rank,
          s2.final_rank,
          s2.rxnorm_api_version
        FROM {processing_schema}.rxnorm_concept_status2 s2
      );

      DROP TABLE IF EXISTS {processing_schema}.rxnorm_concept_status3_b;
      CREATE TABLE {processing_schema}.rxnorm_concept_status3_b AS (
        SELECT
         input_code,
         COUNT(DISTINCT output_code) AS output_code_cardinality,
         STRING_AGG(DISTINCT(output_code), '|') AS output_codes
        FROM {processing_schema}.rxnorm_concept_status3_a
        GROUP BY input_code
      )
      ;

      DROP TABLE IF EXISTS {processing_schema}.rxnorm_concept_status4;
      CREATE TABLE {processing_schema}.rxnorm_concept_status4 AS (
        SELECT
          cs3a.input_rxcui,
          cs3a.input_code,
          cs3a.input_str,
          cs3a.input_tty,
          cs3a.input_status,
          cs3a.output_rxcui,
          cs3a.output_code,
          cs3a.output_str,
          cs3a.output_tty,
          cs3b.output_code_cardinality,
          cs3b.output_codes
        FROM {processing_schema}.rxnorm_concept_status3_a cs3a
        LEFT JOIN {processing_schema}.rxnorm_concept_status3_b cs3b
        ON cs3a.input_code = cs3b.input_code
        WHERE cs3a.final_rank = 1
      )
      ;


      DROP TABLE IF EXISTS {processing_schema}.rxnorm_concept_status5_a_i;
      CREATE TABLE {processing_schema}.rxnorm_concept_status5_a_i AS (

        SELECT
          cs4.input_rxcui,
          cs4.input_code,
          cs4.input_str,
          cs4.input_tty,
          cs4.input_status,
          cs4b.output_rxcui,
          cs4b.output_code,
          cs4b.output_str,
          cs4b.output_tty
        FROM
          ( SELECT *
            FROM {processing_schema}.rxnorm_concept_status4
            WHERE
              output_code_cardinality = 0) cs4
        LEFT JOIN {processing_schema}.rxnorm_concept_status4 cs4b
        ON cs4.output_rxcui = cs4b.input_rxcui
      );

      DROP TABLE IF EXISTS {processing_schema}.rxnorm_concept_status5_a_ii;
      CREATE TABLE {processing_schema}.rxnorm_concept_status5_a_ii AS (
        SELECT
          cs5ai.input_rxcui,
          COUNT(DISTINCT output_code) AS output_code_cardinality,
          STRING_AGG(DISTINCT(output_code), '|') AS output_codes
        FROM {processing_schema}.rxnorm_concept_status5_a_i cs5ai
        GROUP BY cs5ai.input_rxcui
      );

      DROP TABLE IF EXISTS {processing_schema}.rxnorm_concept_status5_a;
      CREATE TABLE {processing_schema}.rxnorm_concept_status5_a AS (
        SELECT DISTINCT
          cs5ai.*,
          cs5aii.output_code_cardinality,
          cs5aii.output_codes
        FROM {processing_schema}.rxnorm_concept_status5_a_i cs5ai
        LEFT JOIN {processing_schema}.rxnorm_concept_status5_a_ii cs5aii
        ON cs5ai.input_rxcui = cs5aii.input_rxcui
      )
      ;

      DROP TABLE IF EXISTS {processing_schema}.rxnorm_concept_status5_b;
      CREATE TABLE {processing_schema}.rxnorm_concept_status5_b AS (
        SELECT *
        FROM {processing_schema}.rxnorm_concept_status4
        WHERE
         output_code_cardinality <> 0
      )
      ;

      DROP TABLE IF EXISTS {processing_schema}.rxnorm_concept_status6;
      CREATE TABLE {processing_schema}.rxnorm_concept_status6 AS (
         SELECT *
         FROM {processing_schema}.rxnorm_concept_status5_b
         UNION
         SELECT *
         FROM {processing_schema}.rxnorm_concept_status5_a
      )
      ;
      "
        )


      pg13::send(
        conn = conn,
        sql_statement = sql_statement,
        checks = checks,
        verbose = verbose,
        render_sql = render_sql,
        render_only = render_only
      )


      # Some concepts map to a new output_rxcui, but
      # the source RxNorm RRF table does not have any info
      # regarding that RxCUI so an API call is made to get
      # the properties from RxNav

      sql_statement <-
        glue::glue(
          "
SELECT DISTINCT input_rxcui
FROM {processing_schema}.rxnorm_concept_status6
WHERE
  output_code_cardinality = 0
  AND input_rxcui IS NOT NULL
"
        )

      input_rxcuis_to_call <-
        pg13::query(
          conn = conn,
          sql_statement = sql_statement,
          checks = checks,
          verbose = verbose,
          render_sql = render_sql,
          render_only = render_only
        ) %>%
        unlist() %>%
        unname()

      cli::cli_progress_bar(
        format = paste0(
          "{pb_spin} Calling {.url {link}} ",
          "[{pb_current}/{pb_total}]   ETA:{pb_eta}"
        ),
        format_done = paste0(
          "{col_green(symbol$tick)} Downloaded {pb_total} files ",
          "in {pb_elapsed}."
        ),
        total = length(input_rxcuis_to_call),
        clear = FALSE
      )

      output <-
        vector(
          mode = "list",
          length = length(input_rxcuis_to_call)
        )

      names(output) <-
        input_rxcuis_to_call

      for (rxcui in input_rxcuis_to_call) {
        cli::cli_progress_update()
        Sys.sleep(0.05)

        link <-
          glue::glue("https://rxnav.nlm.nih.gov/REST/rxcui/{rxcui}/historystatus.json")

        rxcui_key <-
          c(key,
            link = link
          )


        rxcui_content <-
          R.cache::loadCache(
            dirs = dirs,
            key = rxcui_key
          )

        if (is.null(rxcui_content)) {
          Sys.sleep(2.9)
          rxcui_resp <-
            GET(
              url = link
            )

          abort_on_api_error(rxcui_resp)

          rxcui_out <-
            content(rxcui_resp,
              as = "parsed"
            )

          if (!is.null(rxcui_out)) {
            rxcui_out <-
              rxcui_out$rxcuiStatusHistory$derivedConcepts$remappedConcept %>%
              map(unlist) %>%
              map(as_tibble_row) %>%
              bind_rows()
          } else {
            rxcui_out <-
              tribble(
                ~remappedRxCui,
                ~remappedName,
                ~remappedTTY
              )
          }


          R.cache::saveCache(
            dirs = dirs,
            key = rxcui_key,
            object = rxcui_out
          )

          rxcui_content <-
            rxcui_out
        }

        output[[as.character(rxcui)]] <-
          rxcui_content
      }

      output2 <-
        output %>%
        bind_rows(.id = "input_rxcui") %>%
        transmute(
          input_rxcui,
          output_code = remappedRxCui,
          output_str = remappedName,
          output_tty = remappedTTY
        ) %>%
        group_by(input_rxcui) %>%
        arrange(as.integer(output_code),
          .by_group = TRUE
        ) %>%
        mutate(
          output_code_cardinality =
            length(unique(output_code)),
          output_codes =
            paste(unique(output_code),
              collapse = "|"
            )
        ) %>%
        dplyr::filter(row_number() == 1) %>%
        ungroup() %>%
        mutate(
          output_source = "RxNav REST API",
          output_source_version = rxnorm_api_version
        )


      tmp_csv <- tempfile()
      readr::write_csv(
        x = output2,
        file = tmp_csv,
        na = "",
        quote = "all"
      )


      sql_statement <-
        glue::glue(
          "
      DROP TABLE IF EXISTS {processing_schema}.rxnorm_concept_status7_a_i;
      CREATE TABLE {processing_schema}.rxnorm_concept_status7_a_i (
              input_rxcui     INTEGER NOT NULL,
              output_code      VARCHAR(50) NOT NULL,
              output_str       VARCHAR(3000) NOT NULL,
              output_tty       VARCHAR(20) NOT NULL,
              output_code_cardinality INTEGER NOT NULL,
              output_codes TEXT NOT NULL,
              output_source VARCHAR(20) NOT NULL,
              output_source_version VARCHAR(30) NOT NULL
      )
      ;

      COPY {processing_schema}.rxnorm_concept_status7_a_i FROM '{tmp_csv}' CSV HEADER QUOTE E'\"' NULL AS '';

      DROP TABLE IF EXISTS {processing_schema}.rxnorm_concept_status7_a;
      CREATE TABLE {processing_schema}.rxnorm_concept_status7_a AS (
              SELECT
                cs6.input_rxcui,
                cs6.input_code,
                cs6.input_str,
                cs6.input_tty,
                cs6.input_status,
                cs7ai.output_code::integer AS output_rxcui,
                cs7ai.output_code,
                cs7ai.output_str,
                cs7ai.output_tty,
                cs7ai.output_code_cardinality,
                cs7ai.output_codes,
                cs7ai.output_source,
                cs7ai.output_source_version
              FROM {processing_schema}.rxnorm_concept_status7_a_i cs7ai
              INNER JOIN {processing_schema}.rxnorm_concept_status6 cs6
              ON cs6.input_rxcui = cs7ai.input_rxcui
      )
      ;

      DROP TABLE IF EXISTS {processing_schema}.rxnorm_concept_status7_b;
      CREATE TABLE {processing_schema}.rxnorm_concept_status7_b AS (
        SELECT
          cs6.*,
          'RxNorm' as output_source,
          (SELECT sr_release_date FROM public.setup_rxnorm_log WHERE sr_datetime IN (SELECT MAX(sr_datetime) FROM public.setup_rxnorm_log)) AS output_source_version
        FROM {processing_schema}.rxnorm_concept_status6 cs6
        WHERE cs6.input_rxcui NOT IN (SELECT input_rxcui FROM {processing_schema}.rxnorm_concept_status7_a)
      )
      ;

      DROP TABLE IF EXISTS {processing_schema}.rxnorm_concept_status8;
      CREATE TABLE {processing_schema}.rxnorm_concept_status8 AS (
        SELECT *
        FROM {processing_schema}.rxnorm_concept_status7_a
        UNION
        SELECT *
        FROM {processing_schema}.rxnorm_concept_status7_b
      )
      ;

      DROP TABLE IF EXISTS {processing_schema}.rxnorm_concept_status9_a;
      CREATE TABLE {processing_schema}.rxnorm_concept_status9_a AS (
        SELECT
          cs8.input_rxcui,
          cs8.input_code,
          cs8.input_str,
          cs8.input_tty,
          cs8.input_status,
          cs8.output_rxcui,
          r.code AS output_code,
          r.str  AS output_str,
          r.tty  AS output_tty,
          cs8.output_code_cardinality,
          cs8.output_codes,
          cs8.output_source,
          cs8.output_source_version
        FROM {processing_schema}.rxnorm_concept_status8 cs8
        LEFT JOIN (SELECT * FROM rxnorm.rxnconso WHERE sab = 'RXNORM')  r
        ON r.code = cs8.output_codes AND r.tty = cs8.input_tty
        WHERE
          cs8.output_rxcui IS NOT NULL
          AND cs8.output_code IS NULL
          AND cs8.output_code_cardinality = 1
      )
      ;

      DROP TABLE IF EXISTS {processing_schema}.rxnorm_concept_status9_b;
      CREATE TABLE {processing_schema}.rxnorm_concept_status9_b AS (
        SELECT *
        FROM {processing_schema}.rxnorm_concept_status8
        WHERE
          input_rxcui NOT IN (SELECT input_rxcui FROM {processing_schema}.rxnorm_concept_status9_a)
      )
      ;

      DROP TABLE IF EXISTS {processing_schema}.rxnorm_concept_status10;
      CREATE TABLE {processing_schema}.rxnorm_concept_status10 AS (
        SELECT *
        FROM {processing_schema}.rxnorm_concept_status9_a
        UNION
        SELECT *
        FROM {processing_schema}.rxnorm_concept_status9_b
      )
      ;
    "
        )


      pg13::send(
        conn = conn,
        sql_statement = sql_statement,
        checks = checks,
        verbose = verbose,
        render_sql = render_sql,
        render_only = render_only
      )


      sql_statement <-
        glue::glue("CREATE SCHEMA IF NOT EXISTS {destination_schema};
             DROP TABLE IF EXISTS {destination_schema}.rxnorm_validity_status;
             CREATE TABLE {destination_schema}.rxnorm_validity_status AS (
               SELECT *
               FROM {processing_schema}.rxnorm_concept_status10
             );")

      pg13::send(
        conn = conn,
        sql_statement = sql_statement,
        checks = checks,
        verbose = verbose,
        render_sql = render_sql,
        render_only = render_only
      )


      if (rm_processing_schema) {
        pg13::send(
          conn = conn,
          sql_statement = glue::glue("DROP SCHEMA {processing_schema} CASCADE;"),
          checks = checks,
          verbose = verbose,
          render_sql = render_sql,
          render_only = render_only
        )
      }

      log_processing(
        conn = conn,
        target_schema = destination_schema,
        target_table = "rxnorm_validity_status",
        verbose = verbose,
        render_sql = render_sql
      )
    }
  }




#
#       sql_statement <-
#       "
#       create schema if not exists rxrel;
#
#       DROP TABLE IF EXISTS rxrel.tmp_rxnorm_validity_status;
#       CREATE TABLE rxrel.tmp_rxnorm_validity_status AS (
#         select distinct
#         COALESCE(r.rxcui, arc.rxcui) AS rxcui_lookup,
#         COALESCE(r.sab, arc.sab) AS rxcui_sab_lookup,
#         COALESCE(r.tty, arc.tty) AS rxcui_tty_lookup,
#         COALESCE(r.str, arc.str) AS rxcui_str_lookup,
#         r.rxcui AS rxnconso_rxcui,
#         arc.rxcui AS rxnatomarchive_rxcui,
#         arc.merged_to_rxcui,
#         COALESCE(arc.merged_to_rxcui, arc.rxcui, r.rxcui) AS maps_to_rxcui,
#         CASE
#         WHEN r.rxcui IS NOT NULL AND arc.rxcui IS NULL THEN 'Valid'
#         WHEN r.rxcui IS NULL AND arc.rxcui IS NOT NULL AND arc.rxcui = arc.merged_to_rxcui THEN 'Deprecated'
#         WHEN  r.rxcui IS NOT NULL AND r.rxcui = arc.rxcui AND arc.rxcui <> arc.merged_to_rxcui THEN 'Updated'
#         WHEN r.rxcui IS NULL AND arc.rxcui IS NOT NULL AND arc.rxcui <> arc.merged_to_rxcui THEN 'Updated'
#         WHEN r.rxcui = arc.rxcui AND arc.rxcui = arc.merged_to_rxcui THEN 'Valid'
#         ELSE 'Invalid'
#         END validity
#         from rxnorm.rxnconso r
#         full join rxnorm.rxnatomarchive arc
#         on r.rxcui = arc.rxcui
#       )
#       ;
#       "
#       pg13::send(conn = conn,
#                  sql_statement = sql_statement,
#                  checks = checks,
#                  verbose = verbose,
#                  render_sql = render_sql,
#                  render_only = render_only)
#
#       sql_statement <-
#         glue::glue(
#           "
#           DROP TABLE IF EXISTS rxrel.tmp_rxnorm_validity_status0;
#           CREATE TABLE rxrel.tmp_rxnorm_validity_status0 AS (
#           SELECT DISTINCT
#             rxcui_lookup AS rxcui_lookup,
#             maps_to_rxcui AS maps_to_rxcui,
#             maps_to_rxcui AS maps_to_rxcui0,
#             validity AS validity
#           FROM rxrel.tmp_rxnorm_validity_status
#           );
#           "
#         )
#
#       pg13::send(conn = conn,
#                  sql_statement = sql_statement,
#                  checks = checks,
#                  verbose = verbose,
#                  render_sql = render_sql,
#                  render_only = render_only)
#
#     for (i in 1:10) {
#     sql_statement <-
#       glue::glue(
#         "
#         DROP TABLE IF EXISTS rxrel.tmp_rxnorm_validity_status{i}_b;
#         CREATE TABLE rxrel.tmp_rxnorm_validity_status{i}_b AS (
#         SELECT DISTINCT
#           '{i}' AS level_of_separation,
#           a.maps_to_rxcui{i-1},
#           b.validity     AS validity,
#           b.maps_to_rxcui AS maps_to_rxcui{i}
#         FROM rxrel.tmp_rxnorm_validity_status{i-1} a
#         LEFT JOIN rxrel.tmp_rxnorm_validity_status0 b
#         ON a.maps_to_rxcui{i-1} = b.rxcui_lookup
#         WHERE a.validity = 'Updated' AND b.validity = 'Updated'
#         );
#
#         DROP TABLE IF EXISTS rxrel.tmp_rxnorm_validity_status{i};
#         CREATE TABLE rxrel.tmp_rxnorm_validity_status{i} AS (
#             SELECT *
#             FROM rxrel.tmp_rxnorm_validity_status{i}_b b
#             WHERE b.maps_to_rxcui{i-1} NOT IN (SELECT DISTINCT maps_to_rxcui{i} FROM rxrel.tmp_rxnorm_validity_status{i}_b)
#
#         );
#
#         DROP TABLE rxrel.tmp_rxnorm_validity_status{i}_b;
#         "
#       )
#
#     pg13::send(conn = conn,
#                sql_statement = sql_statement,
#                checks = checks,
#                verbose = verbose,
#                render_sql = render_sql,
#                render_only = render_only)
#
#     row_count <-
#       pg13::query(conn = conn,
#                   sql_statement = glue::glue("SELECT COUNT(*) FROM rxrel.tmp_rxnorm_validity_status{i};"),
#                   checks = checks,
#                   verbose = verbose,
#                   render_sql = render_sql,
#                   render_only = render_only) %>%
#       unlist() %>%
#       unname()
#
#     if (row_count == 0) {
#       pg13::send(conn = conn,
#                  sql_statement = glue::glue("DROP TABLE rxrel.tmp_rxnorm_validity_status{i};"),
#                  checks = checks,
#                  verbose = verbose,
#                  render_sql = render_sql,
#                  render_only = render_only)
#
#       final_tables <- sprintf("tmp_rxnorm_validity_status%s", 1:(i-1))
#
#       output <-
#         vector(mode = "list",
#                length = length(final_tables))
#       names(output) <- final_tables
#
#       for (final_table in final_tables) {
#         output[[final_table]] <-
#           pg13::query(
#             conn = conn,
#             sql_statement = glue::glue("SELECT * FROM rxrel.{final_table};"),
#             checks = checks,
#             verbose = verbose,
#             render_sql = render_sql,
#             render_only = render_only
#           )
#
#
#       }
#
#
#       output <-
#         output %>%
#         purrr::map(dplyr::select, -level_of_separation) %>%
#         purrr::reduce(dplyr::left_join) %>%
#         dplyr::distinct()
#
#       final_a <-
#       output %>%
#         tidyr::pivot_longer(cols = dplyr::matches("[1-9]{1,}$"),
#                      names_to = "level_of_separation",
#                      names_prefix = "maps_to_rxcui",
#                      values_to = "maps_to_rxcui",
#                      values_drop_na = TRUE)
#
#       final_b <-
#       final_a %>%
#         dplyr::group_by(maps_to_rxcui0) %>%
#         dplyr::arrange(dplyr::desc(level_of_separation),
#                        .by_group = TRUE) %>%
#         dplyr::filter(dplyr::row_number() == 1) %>%
#         dplyr::ungroup() %>%
#         dplyr::arrange(dplyr::desc(level_of_separation))
#
#
#       pg13::write_table(conn = conn,
#                         schema = "rxrel",
#                         table_name = "rxnorm_updated_path",
#                         data = final_a,
#                         drop_existing = TRUE)
#
#       pg13::write_table(conn = conn,
#                         schema = "rxrel",
#                         table_name = "rxnorm_updated",
#                         data = final_b,
#                         drop_existing = TRUE)
#
#
#
#
#       for (final_table in final_tables) {
#
#         pg13::drop_table(conn = conn,
#                          schema = "rxrel",
#                          table = final_table)
#
#       }
#       break
#     }
#
#
#     }
#
#
#     sql_statement <-
#     "
#     DROP TABLE IF EXISTS rxrel.rxnorm_concept_update2;
#     create table rxrel.rxnorm_concept_update2 AS (
#       select
#       l.rxcui_lookup,
#       l.rxcui_sab_lookup,
#       l.rxcui_tty_lookup,
#       l.rxcui_str_lookup,
#       l.rxnconso_rxcui,
#       l.rxnatomarchive_rxcui,
#       l.merged_to_rxcui,
#       COALESCE(u.maps_to_rxcui, l.maps_to_rxcui) AS maps_to_rxcui,
#       COALESCE(u.validity, l.validity) AS validity,
#       u.level_of_separation
#       from rxrel.tmp_rxnorm_concept_update l
#       left join rxrel.rxnorm_updated u
#       ON u.maps_to_rxcui0 = l.maps_to_rxcui
#     )
#     ;
#     "
#
#     pg13::send(sql_statement = sql_statement,
#                conn = conn,
#                checks = checks,
#                verbose = verbose,
#                render_sql = render_sql,
#                render_only = render_only)
#
#
#     sql_statement <-
#     "
#     DROP TABLE IF EXISTS rxrel.rxnorm_concept_update;
#     CREATE TABLE rxrel.rxnorm_concept_update AS (
#     SELECT DISTINCT
#       l.*,
#       r.rxcui_str_lookup AS maps_to_str,
#       r.rxcui_sab_lookup AS maps_to_sab,
#       r.rxcui_tty_lookup AS maps_to_tty
#     FROM rxrel.rxnorm_concept_update2 l
#     LEFT JOIN rxrel.rxnorm_concept_update2 r
#     ON r.rxcui_lookup = l.maps_to_rxcui
#     );
#     "
#
#     pg13::send(conn = conn,
#                sql_statement = sql_statement,
#                checks = checks,
#                verbose = verbose,
#                render_sql = render_sql,
#                render_only = render_only)
#
#
#     pg13::drop_table(conn = conn,
#                      schema = "rxrel",
#                      table = "rxnorm_concept_update2")
#
#     pg13::drop_table(conn = conn,
#                      schema = "rxrel",
#                      table = "tmp_rxnorm_concept_update0")
#
#     pg13::drop_table(conn = conn,
#                      schema = "rxrel",
#                      table = "tmp_rxnorm_concept_update")
#
#     log_processing(target_table = "rxnorm_updated")
#     log_processing(target_table = "rxnorm_updated_path")
#     log_processing(target_table = "rxnorm_concept_update")
#
#
#     }
#
#   }