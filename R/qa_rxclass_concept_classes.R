qa_rxclass_concept_classes <-
function(prior_version = NULL,
         prior_api_version = "3.1.174") {

  if (is.null(prior_version)) {

    version_key <- get_rxnav_api_version()

  } else {

    version_key <-
      list(version = prior_version,
           apiVersion = prior_api_version)

  }

  member_concept_classes_data <-
    read_members_concept_classes_csvs(
      prior_version = version_key$version,
      prior_api_version = version_key$apiVersion
    )


  graph_concept_classes_data <-
    read_graph_concept_csvs(
      prior_version = version_key$version,
      prior_api_version = version_key$apiVersion
    )

  reconciled_data <-
    dplyr::full_join(
      member_concept_classes_data,
      graph_concept_classes_data,
      by = c("concept_code", "standard_concept",  "class_type"),
      keep = TRUE,
      suffix = c(".members", ".graph")
    )


  concept_classes_orphans <-
    reconciled_data %>%
    dplyr::filter_at(dplyr::vars(dplyr::ends_with(".graph")),
                     dplyr::all_vars(is.na(.))) %>%
    dplyr::transmute(
      concept_code = concept_code.members,
      concept_name = '(Missing)',
      class_type   = class_type.members,
      standard_concept = standard_concept.members) %>%
    dplyr::left_join(
      classtype_lookup %>%
        dplyr::transmute(
          class_type = classType,
          vocabulary_id = dplyr::coalesce(omop_vocabulary_id, custom_vocabulary_id)
        ),
      by = "class_type") %>%
    dplyr::distinct()

  cli_message(
    glue::glue("Found {nrow(concept_classes_orphans)} orphan classes in RxClass Members (Concept Relationship) that were not given in RxClass Graph (Concept Ancestor).")
  )

  orphan_classes_csv <-
    file.path(here::here(),
              "dev",
              "RxClass API",
              version_key$version,
              "extracted",
              "members",
              "processed",
              "CONCEPT_CLASSES.csv")

  if (nrow(concept_classes_orphans)==0) {

    orphan_concept_classes <-
      tibble::tribble(
    ~concept_code,
    ~concept_name,
    ~class_type,
    ~standard_concept,
    ~vocabulary_id
      )

    readr::write_csv(
      x = orphan_concept_classes,
      file = orphan_classes_csv
    )



  } else {


    cli_message(
      glue::glue("Getting more details on the orphan classes:")
    )

  print_lookup(concept_classes_orphans %>%
                 dplyr::count(vocabulary_id, class_type) %>%
                 dplyr::mutate(total_time_required =
                                 as.character(calculate_total_time(n))))


  cli::cli_progress_bar(
    format = paste0(
      "[{as.character(Sys.time())}] {.strong {classType} ({vocabulary_id}) code} {orphanClassId} ",
      "({cli::pb_current}/{cli::pb_total}) ETA:{time_remaining}  Elapsed:{cli::pb_elapsed}"
    ),
    format_done = paste0(
      "[{as.character(Sys.time())}] {cli::col_green(cli::symbol$tick)} Collected {cli::pb_total} class details ",
      "in {cli::pb_elapsed}."
    ),
    total = nrow(concept_classes_orphans),
    clear = FALSE
  )

  orphanClassDetails <- list()
  dirs <- file.path(R.cache::getCacheRootPath(), "setupRxNorm", version_key$version, "RxClass API", "Orphan Classes")
  for (i in 1:nrow(concept_classes_orphans)) {

    orphanClassId <- concept_classes_orphans$concept_code[i]
    classType     <- concept_classes_orphans$class_type[i]
    vocabulary_id <- concept_classes_orphans$vocabulary_id[i]
    time_remaining <- calculate_time_remaining(iteration = i,
                             total_iterations = nrow(concept_classes_orphans),
                             time_value_per_iteration = 3,
                             time_unit_per_iteration = "seconds")
    cli::cli_progress_update()

    url <-
      glue::glue(
        "https://rxnav.nlm.nih.gov/REST/rxclass/class/byId.json?classId={orphanClassId}"
      )

    key <-
      list(
        version_key,
        url
      )

    results <-
      R.cache::loadCache(
        dirs = dirs,
        key = key
      )

    if (is.null(results)) {

      Sys.sleep(3)
      resp <-
        httr::GET(url = url)

      if (status_code(resp) != 200) {

        stop()

      }

      results0 <-
        httr::content(resp)[["rxclassMinConceptList"]][["rxclassMinConcept"]][[1]]

      R.cache::saveCache(
        dirs = dirs,
        key  = key,
        object = results0
      )

      results <-
        R.cache::loadCache(
          dirs = dirs,
          key = key
        )

    }

    orphanClassDetails[[length(orphanClassDetails)+1]] <-
      results

    names(orphanClassDetails)[length(orphanClassDetails)] <-
      orphanClassId

  }

  concept_classes_orphans_b <-
    orphanClassDetails %>%
    purrr::map(unlist) %>%
    purrr::map(tibble::as_tibble_row) %>%
    dplyr::bind_rows() %>%
    dplyr::transmute(
      concept_code = classId,
      class_type = classType,
      concept_name = className) %>%
    dplyr::distinct()

  orphan_concept_classes <-
  dplyr::left_join(
    concept_classes_orphans,
    concept_classes_orphans_b,
    keep = TRUE,
    suffix = c(".old", ".new"),
    by = c("concept_code", "class_type")) %>%
    dplyr::select(
      concept_code = concept_code.new,
      concept_name = concept_name.new,
      class_type   = class_type.new,
      standard_concept,
      vocabulary_id) %>%
    dplyr::distinct()


  readr::write_csv(
    x = orphan_concept_classes,
    file = orphan_classes_csv
  )

  }


  }
