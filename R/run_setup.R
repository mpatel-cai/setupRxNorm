#' @title
#' Load RxNorm Monthly Release into Postgres
#' @description
#' The CSV files downloaded from \href{RxNorm Full Monthly Release}{https://www.nlm.nih.gov/research/umls/rxnorm/docs/rxnormfiles.html}
#' are loaded into Postgres.
#'
#' @param conn Connection to a Postgres database.
#' @param schema Target schema for the RxNorm load, Default: 'rxnorm'.
#' @param rrf_path Path to the unpacked RxNorm files.
#' @param log_schema Schema for the table that logs the process, Default: 'public'
#' @param log_table_name Name of log table, Default: 'setup_rxnorm_log'
#' @param log_release_date (Required) \href{https://www.nlm.nih.gov/research/umls/rxnorm/docs/rxnormfiles.html}{RxNorm Monthly} Release Date.
#' @param rxrel_tables (Optional) Which RxRel schema tables to process for this run?
#' @param rxtra_tables (Optional) Which RxTra schema tables to process for this run?
#' @rdname run_setup
#' @export
#' @importFrom pg13 schema_exists drop_cascade send ls_tables query render_row_count table_exists read_table drop_table write_table
#' @importFrom SqlRender render
#' @importFrom purrr map set_names
#' @importFrom dplyr bind_rows rename mutate select everything
#' @importFrom tidyr pivot_wider
#' @importFrom cli cat_line cat_boxx
#' @importFrom tibble as_tibble
#' @importFrom glue glue glue_collapse

run_setup <-
  function(conn,
           conn_fun = "pg13::local_connect()",
           schema = "rxnorm",
           rrf_path,
           rxrel_tables = c(""),
           rxtra_tables = c("rxnorm_validity_status"),
           verbose = TRUE,
           render_sql = TRUE,
           render_only = FALSE,
           checks = c("conn_status", "conn_type"),
           log_schema = "public",
           log_table_name = "setup_rxnorm_log",
           log_release_date) {
    if (missing(log_release_date)) {
      stop("`log_release_date` is required.")
    }


    if (missing(conn)) {
      conn <- eval(rlang::parse_expr(conn_fun))
      on.exit(pg13::dc(conn = conn),
        add = TRUE,
        after = TRUE
      )
    }

    rrf_path <- path.expand(rrf_path)

    expected_files <-
      c(
        "RXNATOMARCHIVE.RRF",
        "RXNCONSO.RRF",
        "RXNCUI.RRF",
        "RXNCUICHANGES.RRF",
        "RXNDOC.RRF",
        "RXNREL.RRF",
        "RXNSAB.RRF",
        "RXNSAT.RRF",
        "RXNSTY.RRF"
      )

    if (!(all(expected_files %in% list.files(path = rrf_path)))) {
      stop(glue::glue("The expected files were not found in {rrf_path}: {glue::glue_collapse(expected_files)}."))
    }


    loaded_version <-
      get_rxnorm_version(
        conn = conn,
        checks = checks,
        verbose = verbose,
        render_sql = render_sql,
        render_only = render_only
      )


    if (loaded_version != log_release_date) {
      if (pg13::schema_exists(
        conn = conn,
        schema = schema
      )) {
        pg13::drop_cascade(
          conn = conn,
          schema = schema,
          verbose = verbose,
          render_sql = render_sql,
          render_only = render_only
        )
      }

      sql_statement <-
        SqlRender::render(
          sql = "
            CREATE SCHEMA @schema;
            SET search_path TO @schema;
            DROP TABLE IF EXISTS rxncui;
            DROP TABLE IF EXISTS rxncuichanges;
            DROP TABLE IF EXISTS rxndoc;
            DROP TABLE IF EXISTS rxnsty;
            DROP TABLE IF EXISTS rxnsat;
            DROP TABLE IF EXISTS rxnrel;
            DROP TABLE IF EXISTS rxnconso;
            DROP TABLE IF EXISTS rxnatomarchive;
            DROP TABLE IF EXISTS rxnsab;
            DROP TABLE IF EXISTS rxntty;
            DROP TABLE IF EXISTS rxnlat;
            DROP TABLE IF EXISTS rxnatn;

            CREATE TABLE rxnatomarchive
            (
              rxaui               INTEGER NOT NULL,
              aui                 VARCHAR(10) ,
              str                 VARCHAR(4000) NOT NULL,
              archive_timestamp   DATE NOT NULL,
              created_timestamp   TIMESTAMPTZ NOT NULL,
              updated_timestamp   TIMESTAMPTZ NOT NULL,
              code                VARCHAR(50) NOT NULL,
              is_brand            VARCHAR(1),
              lat                 VARCHAR(3) NOT NULL,
              last_released       VARCHAR(30),
              saui                VARCHAR(50),
              vsab                VARCHAR(40),
              rxcui               INTEGER NOT NULL,
              sab                 VARCHAR(20) NOT NULL,
              tty                 VARCHAR(20) NOT NULL,
              merged_to_rxcui     INTEGER NOT NULL,
              empty       TEXT
            );

            CREATE TABLE rxnconso
            (
              rxcui     INTEGER NOT NULL,
              lat       VARCHAR(3) DEFAULT 'ENG' NOT NULL,
              ts        VARCHAR(1),
              lui       VARCHAR(8),
              stt       VARCHAR(3),
              sui       VARCHAR(8),
              ispref    VARCHAR(1),
              rxaui     INTEGER NOT NULL,
              saui      VARCHAR(50),
              scui      VARCHAR(50),
              sdui      VARCHAR(50),
              sab       VARCHAR(20) NOT NULL,
              tty       VARCHAR(20) NOT NULL,
              code      VARCHAR(50) NOT NULL,
              str       VARCHAR(3000) NOT NULL,
              srl       VARCHAR(10),
              suppress  VARCHAR(1),
              cvf       INTEGER,
              empty       TEXT
            );

            CREATE TABLE rxnrel
            (
              rxcui1    INTEGER,
              rxaui1    INTEGER,
              stype1    VARCHAR(50) NOT NULL,
              rel       VARCHAR(4) NOT NULL,
              rxcui2    INTEGER,
              rxaui2    INTEGER,
              stype2    VARCHAR(50) NOT NULL,
              rela      VARCHAR(100),
              rui       INTEGER,
              srui      VARCHAR(50),
              sab       VARCHAR(20) NOT NULL,
              sl        VARCHAR(1000),
              dir       VARCHAR(1),
              rg        VARCHAR(10),
              suppress  VARCHAR(1),
              cvf       INTEGER,
              empty       TEXT
            );

            CREATE TABLE rxnsab
            (
              vcui    VARCHAR(8),
              rcui    VARCHAR(8),
              vsab    VARCHAR(40),
              rsab    VARCHAR(20) NOT NULL,
              son     VARCHAR(3000),
              sf      VARCHAR(20),
              sver    VARCHAR(20),
              vstart  DATE,
              vend    DATE,
              imeta   VARCHAR(10),
              rmeta   VARCHAR(10),
              slc     VARCHAR(1000),
              scc     VARCHAR(1000),
              srl     INTEGER,
              tfr     INTEGER,
              cfr     INTEGER,
              cxty    VARCHAR(50),
              ttyl    VARCHAR(300),
              atnl    VARCHAR(1000),
              lat     VARCHAR(3),
              cenc    VARCHAR(20),
              curver  VARCHAR(1),
              sabin   VARCHAR(1),
              ssn     VARCHAR(3000),
              scit    VARCHAR(4000),
              empty       TEXT
            )
            ;

            CREATE TABLE rxnsat
            (
              rxcui     INTEGER,
              lui       VARCHAR(8),
              sui       VARCHAR(8),
              rxaui     INTEGER,
              stype     VARCHAR(50),
              code      VARCHAR(50),
              atui      VARCHAR(11),
              satui     VARCHAR(50),
              atn       VARCHAR(1000) NOT NULL,
              sab       VARCHAR(20) NOT NULL,
              atv       VARCHAR(4000),
              suppress  VARCHAR(1),
              cvf       INTEGER,
              empty       TEXT
            )
            ;

            CREATE TABLE rxnsty
            (
              rxcui   INTEGER NOT NULL,
              tui     VARCHAR(4) NOT NULL,
              stn     VARCHAR(100),
              sty     VARCHAR(50),
              atui    VARCHAR(11),
              cvf     INTEGER,
              empty       TEXT
            )
            ;

            CREATE TABLE rxndoc (
              key     VARCHAR(50) NOT NULL,
              value   VARCHAR(1000),
              type    VARCHAR(50) NOT NULL,
              expl    VARCHAR(1000),
              empty       TEXT
            );

            CREATE TABLE rxncuichanges
            (
              rxaui       INTEGER,
              code        VARCHAR(50),
              sab         VARCHAR(20) NOT NULL,
              tty         VARCHAR(20),
              str         VARCHAR(3000),
              old_rxcui   INTEGER NOT NULL,
              new_rxcui   INTEGER NOT NULL,
              empty       TEXT
            );

            CREATE TABLE rxncui (
              cui1          INTEGER NOT NULL,
              ver_start     VARCHAR(40) NOT NULL,
              ver_end       VARCHAR(40) NOT NULL,
              cardinality   INTEGER NOT NULL,
              cui2          INTEGER NOT NULL,
              empty       TEXT
            );
              ",
          schema = schema
        )

      pg13::send(
        conn = conn,
        sql_statement = sql_statement,
        verbose = verbose,
        render_sql = render_sql,
        render_only = render_only,
        checks = checks
      )

      rrfs <- list.files(
        path = rrf_path,
        pattern = "[.]{1}RRF$|[.]{1}rrf$",
        full.names = TRUE
      )

      for (rrf in rrfs) {
        tbl <- stringr::str_replace(
          string = tolower(basename(rrf)),
          pattern = "(^.*)([.]{1})(rrf$)",
          replacement = "\\1"
        )

        sql <- SqlRender::render(
          "COPY @schema.@tableName FROM '@rrf_path' WITH DELIMITER E'|' CSV QUOTE E'\b';",
          schema = schema,
          tableName = tbl,
          rrf_path = rrf
        )

        pg13::send(
          conn = conn,
          sql_statement = sql,
          verbose = verbose,
          render_sql = render_sql,
          render_only = render_only,
          checks = checks
        )
      }


      # Log
      table_names <-
        pg13::ls_tables(
          conn = conn,
          schema = schema,
          verbose = verbose,
          render_sql = render_sql
        )

      current_row_count <-
        table_names %>%
        purrr::map(function(x) {
          pg13::query(
            conn = conn,
            sql_statement = pg13::render_row_count(
              schema = schema,
              tableName = x
            )
          )
        }) %>%
        purrr::set_names(tolower(table_names)) %>%
        dplyr::bind_rows(.id = "Table") %>%
        dplyr::rename(Rows = count) %>%
        tidyr::pivot_wider(
          names_from = "Table",
          values_from = "Rows"
        ) %>%
        dplyr::mutate(
          sr_datetime = Sys.time(),
          sr_release_date = log_release_date,
          sr_schema = schema
        ) %>%
        dplyr::select(
          sr_datetime,
          sr_release_date,
          sr_schema,
          dplyr::everything()
        )



      if (pg13::table_exists(
        conn = conn,
        schema = log_schema,
        table_name = log_table_name
      )) {
        updated_log <-
          dplyr::bind_rows(
            pg13::read_table(
              conn = conn,
              schema = log_schema,
              table = log_table_name,
              verbose = verbose,
              render_sql = render_sql,
              render_only = render_only
            ),
            current_row_count
          ) %>%
          dplyr::select(
            sr_datetime,
            sr_release_date,
            sr_schema,
            dplyr::everything()
          )
      } else {
        updated_log <- current_row_count
      }

      pg13::drop_table(
        conn = conn,
        schema = log_schema,
        table = log_table_name,
        verbose = verbose,
        render_sql = render_sql,
        render_only = render_only
      )

      pg13::write_table(
        conn = conn,
        schema = log_schema,
        table_name = log_table_name,
        data = updated_log,
        verbose = verbose,
        render_sql = render_sql,
        render_only = render_only
      )

      cli::cat_line()
      cli::cat_boxx("Log Results",
        float = "center"
      )
      print(tibble::as_tibble(updated_log))
      cli::cat_line()
    }


    if ("rxnorm_to_brand_and_generic" %in% rxrel_tables) {
      sql_file <-
      system.file(
        package = "setupRxNorm",
        "RxRel SQL",
        "rxnorm_to_brand_and_generic.sql"
      )


      sql_statement <-
        paste(readLines(con =sql_file), collapse = "\n")

      pg13::send(
        conn = conn,
        sql_statement = sql_statement,
        verbose = verbose,
        render_sql = render_sql,
        render_only = render_only,
        checks = checks
      )

      pg13::drop_table(
        conn = conn,
        schema = log_schema,
        table = log_table_name,
        verbose = verbose,
        render_sql = render_sql,
        render_only = render_only
      )

      pg13::write_table(
        conn = conn,
        schema = log_schema,
        table_name = log_table_name,
        data = updated_log,
        verbose = verbose,
        render_sql = render_sql,
        render_only = render_only
      )

      cli::cat_line()
      cli::cat_boxx("Log Results",
        float = "center"
      )
      print(tibble::as_tibble(updated_log))
      cli::cat_line()
    }

    if ("rxnorm_validity_status" %in% rxtra_tables) {

      process_rxnorm_validity_status(
        conn = conn,
        render_sql = render_sql,
        render_only = render_only,
        checks = checks
      )

    }
  }
