# Use edgeR to do DEA on the outputs from Salmon

library(biomaRt)
library(yaml)
library(edgeR)
library(DESeq2)
library(tximport)

# ====================== define the function of DEA ======================

DEA <- function(control, treat, file.control, file.treat, output.path.dea) {
  count.control <- read.table(file.control, header = TRUE, row.names = 1)
  count.treat <- read.table(file.treat, header = TRUE, row.names = 1)
  count.table <- cbind(count.control, count.treat)  # merge the control and treat tables together
  
  # number of samples in control and treat groups (should be the same if it's a pair test)
  num.sample.control <- ncol(count.control)
  num.sample.treat <- ncol(count.treat)
  
  # save gene list in gene.list for extracting gene names later
  gene.list <- rownames(count.table)
  
  # get the sample id
  samples <- colnames(count.table)

  # define the group
  subject <- factor(subject.all[c(which(group.all == control), which(group.all == treat))])
  group <- factor(group.all[c(which(group.all == control), which(group.all == treat))])

  # The design matrix
  if (pair.test) {
    design <- model.matrix(~subject+group)
  } else {
    design <- model.matrix(~group)
  }

  if (dea.tool == 'edgeR') {  # use edgeR for DEA
    # Put the data into a DGEList object
    y <- DGEList(counts = count.table, genes = gene.list)
    
    # Filtering
    if (filter.need) {
      countsPerMillion <- cpm(y)
      countCheck <- countsPerMillion > 1
      keep <- which(rowSums(countCheck) > 1)
      y <- y[keep, ]
    }
    
    # Normalization
    y <- calcNormFactors(y, method="TMM")

    y$samples$subject <- subject
    y$samples$group <- group
    
    
    rownames(design) <- colnames(y)
    
    # Estimating the dispersion
    
    # estimate the NB dispersion for the dataset
    y <- estimateDisp(y, design, robust = TRUE)
    
    # Differential expression
    
    # determine differentially expressed genes
    # fit genewise glms
    fit <- glmFit(y, design)
    
    # conduct likelihood ratio tests for tumour vs normal tissue differences and show the top genes
    lrt <- glmLRT(fit)
    
    # the DEA result for all the genes
    # dea <- lrt$table
    toptag <- topTags(lrt, n = nrow(y$genes), p.value = 1)
    dea <- toptag$table  # just to add one more column of FDR
    dea <- dea[order(dea$FDR, -abs(dea$logFC), decreasing = FALSE), ]  # sort the table: ascending of FDR then descending of absolute valued of logFC

    # differentially expressed genes
    toptag <- topTags(lrt, n = nrow(y$genes), p.value = 0.05)
    deg <- toptag$table
    if (!is.null(deg)) {
      deg <- deg[order(deg$FDR, -abs(deg$logFC), decreasing = FALSE), ]  # sort the table: ascending of FDR then descending of absolute valued of logFC
    }

    # save the DEA result and DEGs to files
    write.table(dea, paste(output.path.dea, '/dea_', control, '_', treat, '.tsv', sep = ''), row.names = F, quote = FALSE, sep = '\t')
    write.table(deg, paste(output.path.dea, '/deg_', control, '_', treat, '.tsv', sep = ''), row.names = F, quote = FALSE, sep = '\t')
  } else if (dea.tool == "DESeq2") {  # use DESeq2 for DEA

    ## prepare txi

    if (gene.level) {
      ### load tx2gene
      load(file.path(output.path, "countGroup", 'tx2gene.RData'))

      files.noVersion <- file.path(quant.path, samples, "quant_noVersion.sf")
      names(files.noVersion) <- samples

      ### import quantification as txi
      txi <- tximport(files.noVersion, type = "salmon", tx2gene = tx2gene, countsFromAbundance = "no")
    } else {
      ### the original quant files from Salmon
      files <- file.path(quant.path, samples, "quant.sf")
      names(files) <- samples

      ### import quantification as txi
      txi <- tximport(files, type = "salmon", txOut = TRUE, countsFromAbundance = "no")
    }

    ## create the DESeqDataSet
    colData = data.frame(samples, subject, group)
    dds <- DESeqDataSetFromTximport(txi, colData = colData, design = design)

    # Filtering
    if (filter.need) {
      keep <- rowSums(counts(dds)) >= 10
      dds <- dds[keep,]
    }

    ## specify the control group
    dds$group <- relevel(dds$group, ref = control)
    
    ## perform DEA
    dds <- DESeq(dds)
    
    ## export the results
    res.dea <- results(dds)
    res.dea <- res.dea[complete.cases(res.dea), ]  # remove any rows with NA
    
    dea <- as.data.frame(res.dea)
    dea <- dea[order(dea$padj, -abs(dea$log2FoldChange), decreasing = FALSE), ]  # sort the table: ascending of FDR then descending of absolute valued of logFC
    
    deg <- dea[dea$padj < 0.05, ]
    if (nrow(deg) > 1) {
      deg <- deg[order(deg$padj, -abs(deg$log2FoldChange), decreasing = FALSE), ]  # sort the table: ascending of FDR then descending of absolute valued of logFC
    }    

    # save the DEA result and DEGs to files
    write.table(dea, paste(output.path.dea, '/dea_', control, '_', treat, '.tsv', sep = ''), row.names = T, quote = FALSE, sep = '\t')
    write.table(deg, paste(output.path.dea, '/deg_', control, '_', treat, '.tsv', sep = ''), row.names = T, quote = FALSE, sep = '\t')
  }
}

# ====================== load parameters in config file ======================

# load the config file
yaml.file <- yaml.load_file('configs/config_main.yaml')

# extract the information from the yaml file
project <- yaml.file$PROJECT  # project name
dea.tool <- yaml.file$DEATOOL  # tool used for DEA
quant.path <- file.path(yaml.file$FINALOUTPUT, project, "trans/quant")
gene.level <- yaml.file$GENE_LEVEL  # whether to do gene-level analysis
controls <- yaml.file$CONTROL  # all groups used as control
treats <- yaml.file$TREAT  # all groups used as treat, should correspond to control
filter.need <- yaml.file$FILTER$yesOrNo
pair.test <- yaml.file$PAIR
meta.file <- yaml.file$METAFILE
dataset <- yaml.file$EnsemblDataSet
output.path <- file.path(yaml.file$FINALOUTPUT, project, "trans/dea")

num.control <- length(controls)  # number of comparisons that the user wants to do
num.treat <- length(treats)  # should equals to num.control

if (num.control != num.treat) {
  message("Error: Control groups don't mathch with treat groups!")
  message("Please check config_dea.yaml")
  quit(save = 'no')
}

num.comparison <- num.control

# extract the metadata
meta.data <- read.csv(meta.file, header = TRUE, sep = '\t', stringsAsFactors = FALSE)
samples <- meta.data$sample
group.all <- meta.data$group
subject.all <- meta.data$subject

# ====================== Do DEA ======================

for (ith.comparison in c(1:num.comparison)) {
  control <- controls[ith.comparison]
  treat <- treats[ith.comparison]
  
  # --------------------- On transctipt level ---------------------
  file.control <- paste(output.path, '/countGroup/', control, '_trans_abundance.tsv', sep = '')
  file.treat <- paste(output.path, '/countGroup/', treat, '_trans_abundance.tsv', sep = '')
  output.path.dea <- paste(output.path, '/DEA/transcript-level', sep = '')
  
  DEA(control, treat, file.control, file.treat, output.path.dea)
  
  # --------------------- On gene level ---------------------
  if (gene.level) {
    file.control <- paste(output.path, '/countGroup/', control, '_gene_abundance.tsv', sep = '')
    file.treat <- paste(output.path, '/countGroup/', treat, '_gene_abundance.tsv', sep = '')
    output.path.dea <- paste(output.path, '/DEA/gene-level', sep = '')
  
    DEA(control, treat, file.control, file.treat, output.path.dea)
  }
}

