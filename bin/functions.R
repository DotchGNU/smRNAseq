setupRlibs <- function(R_lib){
  .libPaths( c( .libPaths(), R_lib ) )

  if(!require("pacman")) {
    install.packages("pacman", dependencies = TRUE,
                     repos = "http://cloud.r-project.org/")
  }

  p_load(rlang)


  p_install_version(
    c("rlang", "tidyverse", "cowplot", "Biostrings", "Rsamtools",
      "BiocParallel", "jsonlite"),
    c("0.2.1", "1.2.1", "0.9.2", "2.44.2", "1.28.0", "1.10.1", "1.5")
  )

  # Load Tidyverse as late as possible to overload `filter`, `select` and `rename` functions
  pacman::p_load(Biostrings, Rsamtools, BiocParallel, rlang,
                 tidyverse, cowplot, jsonlite)

}

getcfg <- function(json) {
  suppressMessages(require(jsonlite))
  suppressMessages(require(dplyr))
  suppressMessages(require(readr))

  cfg.info <- jsonlite::read_json(json)
  file.home <- cfg.info$base
  mir.anno <- read_tsv(cfg.info$mir.anno)

  cfg.samples <-
    dplyr::bind_rows(cfg.info$samples) %>%
    mutate(cfg.samples, align = file.path(file.home, align))

  list("samples" = cfg.samples, "anno" = mir.anno)
}

# 1) Reads bam
# 2) Filters out reads that don"t map with in +/- 5 of annotated 5p and 3p arms
# 3) Counts all reads (and all TC reads with BQ>27) for given starting position
# 4) Assesses read lengths
# 5) Normalises reads to sRNAreads provided in cfg file
getAllCounts <- function(id, align, sRNAreads, time,
                         mirAnno = NULL, topn = 5, ...) {
  suppressMessages(require(tidyverse))
  suppressMessages(require(Rsamtools))
  mapInfo <- c("rname", "strand", "pos")
  mapParams <- ScanBamParam(what = c(mapInfo, "seq"), tag = c("TC", "TN"),
                            flag = scanBamFlag(isMinusStrand = FALSE,
                                               isUnmappedQuery = FALSE))
  filterNs <- FilterRules(list(NoAmbigNucs = function(x) !grepl("N", x$seq)))
  filterBam <- filterBam(align, tempfile(), filter = filterNs)
  bam <- scanBam(filterBam, param = mapParams)
  # Now this will ONLY handle files that have tags TC and TN, too!
  map.r <- dplyr::bind_cols(do.call(dplyr::bind_cols, bam[[1]][mapInfo]),
                            list("seqLen" = width(bam[[1]]$seq)),
                            do.call(dplyr::bind_cols, bam[[1]]$tag))

  # Sum up all reads with length X, to get total read count
  totalReadCounts <-
    map.r %>%
    group_by(rname, pos, seqLen) %>% summarise(lenDis = n()) %>%
    group_by(rname, pos) %>% mutate(totalReads = sum(lenDis)) %>% ungroup() %>%
    mutate(flybase_id = as.character(rname))

  # Sum up all reads where the custom TC flag was found
  tcReadCounts <-
    map.r %>%
    dplyr::filter(!is.na(TC)) %>%
    group_by(rname, pos, seqLen) %>% summarise(tcLenDis = n()) %>%
    group_by(rname, pos) %>% mutate(tcReads = sum(tcLenDis)) %>% ungroup() %>%
    mutate(flybase_id = as.character(rname)) %>%
    dplyr::select(-rname)

  # Join tc Read count in to total reads
  read.summary <-
    totalReadCounts %>%
    left_join(tcReadCounts, by = c("flybase_id", "pos", "seqLen")) %>%
    replace_na(list(totalReads = 0, lenDis = 0, tcReads = 0, tcLenDis = 0)) %>%
    left_join(mirAnno, by = "flybase_id") %>%
    dplyr::select(-rname)

  # Only keep reads that are within +/-10nt of the suggested 5p/3p arm positions
  read.summary.closestArms <-
    read.summary %>%
    dplyr::filter((pos >= `5p` - 10 & pos <= `5p` + 10) |
                  (pos >= `3p` - 10 & pos <= `3p` + 10)) %>%
    mutate(arm.name = ifelse(pos >= `5p` - 10 & pos <= `5p` + 10,
                             paste0(str_sub(mir_name, 5, -1), "-5p"),
                             paste0(str_sub(mir_name, 5, -1), "-3p")))

  totalRName <- paste("totalReads", id, time, sep = ".")
  tcRName <- paste("tcReads", id, time, sep = ".")
  totalLDname <- paste("totalLenDis", id, time, sep = ".")
  tcLDname <- paste("tcLenDis", id, time, sep = ".")

  # Keep the `topn` (default: 5) most frequently used start positions
  # This will be returned
  read.summary.closestArms %>%
    group_by(arm.name) %>%
    top_n(n = topn, wt = totalReads) %>% ungroup() %>%
    mutate(totalReads = totalReads / sRNAreads * 1000000,
           tcReads = tcReads / sRNAreads * 1000000,
           lenDis = lenDis / sRNAreads * 1000000,
           tcLenDis = tcLenDis / sRNAreads * 1000000) %>%
    dplyr::rename_(.dots = setNames(c("totalReads", "tcReads",
                                      "lenDis", "tcLenDis"),
                                    c(totalRName, tcRName,
                                      totalLDname, tcLDname)))
}

pileupParallelMuts <- function(groupedData, mc.param, minLen) {
  suppressMessages(require(BiocParallel))
  suppressMessages(require(dplyr))

  fbid <- groupedData$flybase_id
  bF <- unique(groupedData$bamFile)
  tp <- groupedData$timepoint
  t <- groupedData$time
  pos <- groupedData$pos
  mir.type <- groupedData$mir.type

  dplyr::bind_rows(bpmapply(doParallelPileup, miR = fbid, timepoint = tp,
                            time = t, pos = pos, mir.type = mir.type,
                            MoreArgs = list(bamFile = bF, minLen = minLen),
                            SIMPLIFY = FALSE, BPPARAM = mc.param))
}

doParallelPileup <- function(miR, timepoint, time, pos, mir.type,
                             bamFile, minLen) {
  # This function will be called from dplyr do() in parallel using BiocParallel `bpmapply`
  # The function itself returns a cleaned data.frame of the pileup, which mapply wraps in a list
  # with one item for every bamFile.
  suppressMessages(require(Rsamtools))
  suppressMessages(require(dplyr))

  start.pos <- pos
  end.pos <- start.pos + 30

  pparam <- PileupParam(query_bins = seq(0,30), max_depth=50000000, min_mapq=0,
                        min_base_quality=0)
  sparam <- ScanBamParam(flag = scanBamFlag(isMinusStrand = FALSE),
                         which=GRanges(miR, IRanges(start.pos, end.pos)))

  filterParam <- ScanBamParam(what = "seq",
                              flag = scanBamFlag(isMinusStrand = FALSE))
  filterNs <- FilterRules(list(NoAmbigNucs = function(x) !grepl("N", x$seq)))
  filterBam <- filterBam(bamFile, tempfile(),
                         param = filterParam,
                         filter = filterNs)

  pileupResult <- pileup(filterBam, scanBamParam = sparam, pileupParam = pparam)

  # Return value
  pileupResult %>%
    dplyr::select(-which_label, -strand) %>%
    mutate(relPos = as.numeric(query_bin),
           # Coerce factor to character to avoid warning later on
           flybase_id = as.character(seqnames),
           timepoint = timepoint,
           time = time,
           mir.type = mir.type,
           start.pos = start.pos) %>%
    dplyr::select(-seqnames, -query_bin) %>%
    dplyr::filter(relPos == pos - min(pos) + 1, relPos <= minLen)
}
