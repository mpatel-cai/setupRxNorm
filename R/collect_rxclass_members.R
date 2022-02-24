#' @title
#' Collect RxClass Members Data
#' @param rela_sources Vector of desired classTypes. This vector is also
#' in the order of the API calls will be made. Can be one or more of the following:
#' 'DAILYMED',
#' 'MESH',
#' 'FDASPL',
#' 'FMTSME',
#' 'VA',
#' 'MEDRT',
#' 'RXNORM',
#' 'SNOMEDCT'.
#' @import tidyverse
#' @import cli
#' @import httr
#' @rdname collect_rxclass_members
#' @export


collect_rxclass_members <-
  function(rela_sources =
           c(
             'DAILYMED',
             'MESH',
             'FDASPL',
             'FMTSME',
             'VA',
             'MEDRT',
             'RXNORM',
             'SNOMEDCT'
           ),
           class_types =
             c(
               "MESHPA",
               "EPC",
               "MOA",
               "PE",
               "PK",
               "TC",
               "VA",
               "DISEASE",
               "DISPOS",
               "CHEM",
               "SCHEDULE",
               "STRUCT")) {


    # Derived from https://lhncbc.nlm.nih.gov/RxNav/applications/RxClassIntro.html
    # to reduce the number of API calls needed per relaSource
    lookup <-
      tibble::tribble(
                      ~classType, ~relaSources,
                      "ATC1-4", "ATC",
                      "CHEM", "DAILYMED",
                      "CHEM", "FDASPL",
                      "CHEM", "MEDRT",
                      "DISEASE", "MEDRT",
                      "DISPOS", "SNOMEDCT",
                      "EPC", "DAILYMED",
                      "EPC", "FDASPL",
                      "MESHPA", "MESH",
                      "MOA", "DAILYMED",
                      "MOA", "FDASPL",
                      "MOA", "MEDRT",
                      "PE", "DAILYMED",
                      "PE", "FDASPL",
                      "PE", "MEDRT",
                      "PK", "MEDRT",
                      "SCHEDULE", "RXNORM",
                      "STRUCT", "SNOMEDCT",
                      "TC", "FMTSME",
                      "VA", "VA") %>%
      dplyr::filter(relaSources %in% rela_sources) %>%
      dplyr::filter(classType %in% class_types)

    class_types <- unique(lookup$classType)

    service_domain <- "https://rxnav.nlm.nih.gov"

    version_key <- get_rxnav_api_version()


    # If the version folder was not present in the cache, it means that
    # this is a brand new version
    # ---
    # setupRxNorm /
    #     07-Feb-2022 /
    #        MESHPA /
    #        TC /
    #        VA /
    #        ...
    full_path_ls <-
      list(
        pkg     = file.path(R.cache::getCacheRootPath(), "setupRxNorm"),
        version = file.path(R.cache::getCacheRootPath(), "setupRxNorm", version_key$version),
        rxclass = file.path(R.cache::getCacheRootPath(), "setupRxNorm", version_key$version, "RxClass API"),
        class_types =
          file.path(R.cache::getCacheRootPath(), "setupRxNorm", version_key$version, "RxClass API", class_types) %>%
          set_names(class_types) %>%
          as.list()
      )


    dirs_ls <-
      list(
        pkg     = file.path("setupRxNorm"),
        version = file.path("setupRxNorm", version_key$version),
        rxclass = file.path("setupRxNorm", version_key$version, "RxClass API"),
        class_types =
          file.path("setupRxNorm", version_key$version, "RxClass API", class_types) %>%
          set_names(class_types) %>%
          as.list()
      )


    rels_df  <- get_rxnav_relationships()
    rels_df <-
    rels_df %>%
      dplyr::filter(relaSource %in% rela_sources)

    class_df <- get_rxnav_classes()
    class_df <-
      class_df %>%
      dplyr::filter(classType %in% class_types) %>%
      mutate(
        classType =
          factor(classType, levels = class_types)) %>%
      arrange(classType) %>%
      mutate(classType = as.character(classType)) %>%
      inner_join(lookup,
                 by = "classType")

    cli::cli_text(
      "[{as.character(Sys.time())}] {.emph {'Collecting...'}}"
    )

cli::cli_progress_bar(
  format = paste0(
    "[{as.character(Sys.time())}] {.strong {classType}}: {classId} {className} ",
    "({cli::pb_current}/{cli::pb_total})  ETA:{time_remaining}  Elapsed:{cli::pb_elapsed}"
      ),
  format_done = paste0(
    "[{as.character(Sys.time())}] {cli::col_green(symbol$tick)} Collected {cli::pb_total} {classType} graphs ",
    "in {cli::pb_elapsed}."
    ),
  total = nrow(class_df),
  clear = FALSE
    )

    # Total time it would take from scratch
    # 3 seconds * total calls that need to be made
    grand_total_calls <- nrow(class_df)


    for (kk in 1:nrow(class_df)) {
      classId        <- class_df$classId[kk]
      className      <- class_df$className[kk]
      classType      <- class_df$classType[kk]
      dirs_kk        <- dirs_ls$class_types[[classType]]
      relaSource     <- class_df$relaSources[kk]


      time_remaining <-
        as.character(
          lubridate::duration(
            seconds =
              3*(grand_total_calls-kk)
          )
        )

      cli::cli_progress_update()

      http_request <-
        glue::glue("/REST/rxclass/classMembers.json?classId={classId}&relaSource={relaSource}")

      url <-
        paste0(
          service_domain,
          http_request
        )

      key <-
        list(
          version_key,
          url
        )

      results <-
        R.cache::loadCache(
          dirs = dirs_kk,
          key = key
        )


      if (is.null(results)) {
        Sys.sleep(3)
        resp <-
          GET(url = url)

        if (length(content(resp)) == 0) {

          R.cache::saveCache(
            dirs = dirs_kk,
            key = key,
            object = ""
          )

        } else {


        R.cache::saveCache(
          dirs = dirs_kk,
          key = key,
          object = content(resp)
        )
        }
      }
    }
}