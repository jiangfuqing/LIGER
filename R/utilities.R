# Utility functions for iiger methods. Some published, some not.

# Helper function for plotFactors
fplot = function(tsne,NMFfactor,title,cols.use=heat.colors(10),pt.size=0.7,pch.use=20) {
  data.cut=as.numeric(as.factor(cut(as.numeric(NMFfactor),breaks=length(cols.use))))
  data.col=rev(cols.use)[data.cut]
  plot(tsne[,1],tsne[,2],col=data.col,cex=pt.size,pch=pch.use,main=title)
  
}

# Binds list of matrices row-wise (vertical stack)
rbindlist = function(mat_list)
{
  return(do.call(rbind,mat_list))
}

# helper function for calculating KL divergence from uniform distribution
# (related to Shannon entropy) for factorization
kl_divergence_uniform = function(object, Hs=NULL)
{
  if (is.null(Hs)) {Hs = object@H}
  n_cells = sum(sapply(Hs, nrow))
  n_factors = ncol(Hs[[1]])
  dataset_list = list()
  for (i in 1:length(Hs)) {
    scaled = scale(Hs[[i]], center=F, scale=T)
    
    inflated = t(apply(scaled, 1, function(x) {
      replace(x, x == 0, 1e-20)
    }))
    inflated = inflated/rowSums(inflated)
    divs = apply(inflated, 1, function(x) {log2(n_factors) + sum(log2(x) * x)})
    dataset_list[[i]] = divs
  }
  return(dataset_list)
}

# Function takes in a list of DGEs, with gene rownames and cell colnames, 
# and merges them into a single DGE.
# Also adds library.names to cell.names if expected to be overlap (common with 10X barcodes)
MergeSparseDataAll <- function(datalist, library.names = NULL) {
  
  # Use summary to convert the sparse matrices into three-column indexes where i are the
  # row numbers, j are the column numbers, and x are the nonzero entries
  col_offset <- 0
  allGenes <- unique(unlist(lapply(datalist, rownames)))
  allCells <- c()
  for (i in 1:length(datalist)) {
    curr <- datalist[[i]]
    curr_s <- summary(curr)
    
    # Now, alter the indexes so that the two 3-column matrices can be properly merged.
    # First, make the current and full column numbers non-overlapping.
    curr_s[, 2] <- curr_s[, 2] + col_offset
    
    # Update full cell names
    if (!is.null(library.names)) {
      cellnames <- paste0(library.names[i], "_", colnames(curr))
    } else {
      cellnames <- colnames(curr)
    }
    allCells <- c(allCells, cellnames)
    
    # Next, change the row (gene) indexes so that they index on the union of the gene sets,
    # so that proper merging can occur.
    idx <- match(rownames(curr), allGenes)
    newgenescurr <- idx[curr_s[, 1]]
    curr_s[, 1] <- newgenescurr
    
    # Now bind the altered 3-column matrices together, and convert into a single sparse matrix.
    if (!exists("full_mat")) {
      full_mat <- curr_s
    } else {
      full_mat <- rbind(full_mat, curr_s)
    }
    col_offset <- max(full_mat[, 2])
  }
  M <- sparseMatrix(
    i = full_mat[, 1],
    j = full_mat[, 2],
    x = full_mat[, 3],
    dims = c(
      length(allGenes),
      length(allCells)
    ),
    dimnames = list(
      allGenes,
      allCells
    )
  )
  return(M)
}

#' Perform fast and memory-efficient normalization operation on sparse matrix data.
#'
#' @param A Sparse matrix DGE.
#' @export
#' @examples
#' \dontrun{
#' Y = matrix(c(1,2,3,4,5,6,7,8,9,10,11,12),nrow=4,byrow=T)
#' Z = matrix(c(1,2,3,4,5,6,7,6,5,4,3,2),nrow=4,byrow=T)
#' ligerex = createLiger(list(Y,Z))
#' ligerex@var.genes = c(1,2,3,4)
#' ligerex = scaleNotCenter(ligerex)
#' }
Matrix.column_norm <- function(A){
  if (class(A)[1] == "dgTMatrix") {
    temp = summary(A)
    A = sparseMatrix(i=temp[,1],j=temp[,2],x=temp[,3])
  }
  A@x <- A@x / rep.int(Matrix::colSums(A), diff(A@p))
  return(A)
}

# Variance for sparse matrices
sparse.var = function(x){
  rms <- rowMeans(x)
  rowSums((x-rms)^2)/(dim(x)[2]-1)
}

# Transposition for sparse matrices
sparse.transpose = function(x){
  h = summary(x)
  sparseMatrix(i = h[,2],j=h[,1],x=h[,3])
  
}

# After running modularity clustering, assign singleton communities to the mode of the cluster
# assignments of the within-dataset neighbors
assign.singletons<-function(object,idents,k.use = 15, center=F) {
  print('Assigning singletons')
  singleton.clusters = names(table(idents))[which(table(idents)==1)]
  singleton.cells = names(idents)[which(idents %in% singleton.clusters)]
  if (length(singleton.cells)>0) {
    singleton.list = lapply(object@H,function(H){
      
      return(intersect(rownames(H),singleton.cells))
    })
    out = unlist(lapply(1:length(object@H),function(d){
      H = object@H[[d]]
      H = t(apply(H,1, ifelse(center, scale, scaleL2norm)))
      cells.use = singleton.list[[d]]
      if (length(cells.use)>0) {
        knn.idx = get.knnx(H,matrix(H[cells.use,],ncol=ncol(H)),k = k.use,algorithm="CR")$nn.index
        o= sapply(1:length(cells.use),function(i){
          ids = idents[knn.idx[i,]]
          getMode(ids[which(!(ids %in% singleton.clusters))])
        })
        
        return(o)
      } else {
        return(NULL)
      }
    }))
    names(out)= unlist(singleton.list)
    idx = names(idents) %in% names(out)
    idents[idx]<-out
    idents = droplevels(idents)
  }
  return(idents)
}

# Run modularity based clustering on edge file 
SLMCluster<-function(edge,prune.thresh=0.2,nstart=100,iter.max=10,algorithm=1,R=1, 
                     modularity=1, ModularityJarFile="",random.seed=1, 
                     id.number=NULL, print.mod=F) {
  
  # Prepare data for modularity based clustering
  edge = edge[which(edge[,3]>prune.thresh),]
  
  print("making edge file.")
  edge_file <- paste0("edge", id.number, fileext=".txt")
  # Make sure no scientific notation written to edge file
  saveScipen=options(scipen=10000)[[1]]
  write.table(x=edge,file=edge_file,sep="\t",row.names=F,col.names=F)
  options(scipen=saveScipen)
  output_file <- tempfile("louvain.out", fileext=".txt")
  if (is.null(random.seed)) {
    # NULL random.seed disallowed for this program.
    random.seed = 0
  }
  liger.dir <- system.file(package = "liger")
  ModularityJarFile <- paste0(liger.dir, "/java/ModularityOptimizer.jar")
  command <- paste("java -jar", ModularityJarFile, edge_file, output_file, modularity, R, 
                   algorithm, nstart,
                   iter.max, random.seed, as.numeric(print.mod), sep = " ")
  print ("Starting SLM")
  ret = system(command, wait = TRUE)
  if (ret != 0) {
    stop(paste0(ret, " exit status from ", command))
  }
  unlink(edge_file)
  ident.use <- factor(read.table(file = output_file, header = FALSE, sep = "\t")[, 1])
  
  return(ident.use)
}

# Scale to unit vector (scale by l2-norm)
scaleL2norm <- function(x) {
  return(x / sqrt(sum(x^2)))
}

# get mode of identities 
getMode <- function(x, na.rm = FALSE) {
  if(na.rm){
    x = x[!is.na(x)]
  }
  ux <- unique(x)
  return(ux[which.max(tabulate(match(x, ux)))])
}

# utility function for seuratToLiger function
addMissingCells <- function(matrix1, matrix.subset, transpose = F) {
  if (transpose) {
    matrix1 <- t(matrix1)
  }
  if (ncol(matrix1) != nrow(matrix.subset)) {
    extra <- matrix(NA, nrow = ncol(matrix1) - nrow(matrix.subset),
                    ncol = ncol(matrix.subset))
    colnames(extra) <- colnames(matrix.subset)
    rownames(extra) <- setdiff(colnames(matrix1), rownames(matrix.subset))
    matrix.subset <- rbind(matrix.subset, extra)
  }
  return(matrix.subset)
}