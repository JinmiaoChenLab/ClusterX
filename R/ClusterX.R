#' Fast clustering by automatic search and find of density peaks
#'
#' This package implement the clustering algorithm described by Alex Rodriguez
#' and Alessandro Laio (2014) with improvements of automatic peak detection and
#' parallel implementation
#'
#' ClusterX works on low dimensional data analysis (Dimensionality less than 5).
#' If input data is of high diemnsional, t-SNE is conducted to reduce the dimensionality.
#'
#' @param data A data matrix for clustering.
#' @param dimReduction Dimenionality reduciton method.
#' @param outDim Number of dimensions will be used for clustering.
#' @param dc Distance cutoff value.
#' @param gaussian If apply gaussian to esitmate the density.
#' @param alpha Signance level for peak detection.
#' @param detectHalos If detect the halos.
#' @param SVMhalos If apply SVM model from cores to assign halos.
#' @param parallel If run the algorithm in parallel.
#' @param nCore Number of cores umployed for parallel compution.
#'
#' @return a object of \code{ClusterX} class
#'
#' @importFrom doParallel registerDoParallel
#' @importFrom parallel makeCluster stopCluster detectCores
#' @importFrom pdist pdist
#' @importFrom plyr llply
#' @importFrom RANN nn2
#' @importFrom e1071 svm
#' @import ggplot2
#'
#' @export
#'
#' @author Chen Hao
#'
#' @examples
#' dir <- system.file("extdata", package = "ClusterX")
#' r15 <- read.table(paste(dir, "R15.txt", sep = .Platform$file.sep), header = FALSE)
#' r15_c <- ClusterX(r15[,c(1,2)])
#' clusterPlot(r15_c)
#' densityPlot(r15_c)
#' peakPlot(r15_c)
#'
#' d31 <- read.table(paste(dir, "D31.txt", sep = .Platform$file.sep), header = FALSE)
#' d31_c <- ClusterX(d31[,c(1,2)])
#' clusterPlot(d31_c)
#' densityPlot(d31_c)
#' peakPlot(d31_c)
ClusterX <- function(data,
                     dimReduction = NULL,
                     outDim=2,
                     dc,
                     gaussian=TRUE,
                     alpha = 0.001,
                     detectHalos = FALSE,
                     SVMhalos = FALSE,
                     parallel = FALSE,
                     nCore = 4 ){

    odata <- data
    if(!is.null(dimReduction))
        data <- cytof_dimReduction(data, method=dimReduction, out_dim = outDim)

    if(parallel){
        if(nCore > detectCores()) nCore <- detectCores()
        cat("  Register the parallel backend using", nCore, "cores...")
        cl <- makeCluster(nCore)
        registerDoParallel(cl)
        cat("DONE!\n")
    }

    if(missing(dc)){
        cat('  Calculate cutoff distance...')
        dc <- estimateDc(data, sampleSize = 10000)
    }
    cat( round(dc, 2), ' \n')
    cat('  Calculate local Density...')
    rho <- localDensity(data, dc, gaussian=gaussian, ifParallel = parallel)
    cat("DONE!\n")
    cat('  Detect nearest neighbour with higher density...')
    deltaWid <- minDistToHigher(data, rho, ifParallel = parallel)
    delta <- deltaWid[[1]]
    higherID <- deltaWid[[2]]
    cat("DONE!\n")
    cat("  Peak detection...")
    peakID <- peakDetect(rho, delta, alpha)
    cat("DONE!\n")
    cat("  Cluster assigning...")
    cluster <- clusterAssign(peakID, higherID, rho)
    cat("DONE!\n")

    clusTable <- as.vector(table(cluster))
    if(sum(clusTable < length(rho)*0.0005) > 0){
        cat("  Noise cluster removed\n")
        peakID <- peakID[clusTable >= length(rho)*alpha]
        cluster <- clusterAssign(peakID, higherID, rho)
    }

    if(detectHalos){
        cat("  Diffenentiate halos from cores ...")
        halo <- haloDetect(data, rho, cluster, peakID, dc)
        cat("DONE!\n")
        if(SVMhalos & sum(halo) > 10 & !is.null(dimReduction)){
            cat("  Build SVM models for cores ...")
            train_data <- odata[!halo, ]
            train_class <- cluster[!halo]
            test_data <- odata[halo, ]
            svm.obj <- svm(train_data, train_class, type = "C-classification")
            cat("DONE!\n  Assign halos using trained SVM model ...")
            test_class <- predict(svm.obj, test_data)
            cluster[halo] <- test_class
            cat("DONE!\n")
        }
    }else{
        halo <- NULL
    }

    if(parallel){
        stopCluster(cl)
    }

    if(ncol(data) < 3){
        plotData <- data
    }else{
        plotData <- data[ ,c(1,2)]
    }

    res <- list(cluster = cluster, dc = dc, rho = rho,
                delta = delta, peakID = peakID, higherID = higherID,
                halo = halo, plotData = plotData)

    class(res) <- 'ClusterX'
    return(res)
}


#' @export
clusterPlot <- function (x, ...) {
    UseMethod("clusterPlot", x)
}

#' @export
clusterPlot.ClusterX <- function(x, ...) {
    if(is.null(x$plotData))
        stop("Data can's be visualized due to high dimensionality,
             Please try heatmapPlot to visualize the results! \n")
    if(ncol(x$plotData) == 2){
        df <- as.data.frame(x$plotData)
        df$cluster <- as.factor(x$cluster)
        xvar <- colnames(df)[1]
        yvar <- colnames(df)[2]
        if(!(is.null(x$halo))){
            halo <- x$halo
            df <- df[!halo, ]
            haloDf <- df[halo, ]
            coreCol <- as.factor(x$cluster)[!halo]
            haloCol <- as.factor(x$cluster)[halo]
            p <- ggplot(df, aes_string(x=xvar, y=yvar)) +
                geom_point(colour = coreCol, size = 1) +
                geom_point(data = haloDf, alpha = 0.6, colour = haloCol) +
                theme_bw() + theme(panel.grid.major = element_blank(), panel.grid.minor = element_blank())
        }else{
            p <- ggplot(df, aes_string(x=xvar, y=yvar, colour = "cluster")) +
                geom_point(size=1) + theme_bw() +
                guides(colour = guide_legend(override.aes = list(size = 4))) +
                theme(panel.grid.major = element_blank(), panel.grid.minor = element_blank())
        }
    }
    p
}


#' @export
densityPlot <- function (x, ...) {
    UseMethod("densityPlot", x)
}

#' @export
densityPlot.ClusterX <- function(x, ...) {
    if(is.null(x$plotData))
        stop("Data can's be visualized due to high dimensionality,
             Please try heatmapPlot to visualize the cluster results! \n")

    if(ncol(x$plotData) == 2){
        df <- as.data.frame(x$plotData)
        df$Density <- x$rho
        xvar <- colnames(df)[1]
        yvar <- colnames(df)[2]
        peakDf <- df[x$peakID, ]
        p <- ggplot(df, aes_string(x=xvar, y=yvar, colour = "Density")) + geom_point() +
            scale_color_gradient2(low = "blue", high = "red", midpoint = median(x$rho)) +
            ggtitle("Density Plot") + geom_point(data = peakDf, shape = 10, size = 2, colour = "black") +
            theme_bw() + theme(panel.grid.major = element_blank(), panel.grid.minor = element_blank())
    }
    p
}


#' @export
peakPlot <- function (x, ...) {
    UseMethod("peakPlot", x)
}

#' @export
peakPlot.ClusterX <- function(x, ...) {
    df <- data.frame(rho = x$rho, delta = x$delta)
    peakDf <- df[x$peakID, ]
    p <- ggplot(df, aes(x=rho, y=delta)) + geom_point() +
        geom_point(data = peakDf, colour = "red") +
        theme_bw() + theme(panel.grid.major = element_blank(), panel.grid.minor = element_blank())
    p
}


#' Estimate the distance cutoff (density neighbourhood) from down-sampled data
#'
#' This function estimate a distance cutoff value from the down-samples data,
#' wchich meet the criteria that the average neighbor rate (number of points
#' within the distance cutoff value) fall between the provided range.
#'
#' @param data Numeric matrix of data or data frame.
#' @param sampleSize The size of the down-sampled data.
#' @param neighborRateLow The lower bound of the neighbor rate (default 0.01).
#' @param neighborRateHigh The upper bound of the neighbor rate (default 0.15).
#'
#' @return A numeric value giving the estimated distance cutoff value.
estimateDc <- function(data, sampleSize = 5000, neighborRateLow=0.01, neighborRateHigh=0.02) {
    data <- as.matrix(data)
    dataLens <- nrow(data)
    if(dataLens > sampleSize){
        sample <- data[sample(1:dataLens, sampleSize, replace = FALSE), ]
    }else{ sample <- data }

    comb <- as.matrix(dist(sample, method = "euclidean"))
    size <- nrow(comb)
    dcMod <- median(comb)*0.05
    dc <- dcMod
    dcL <- min(comb)               ## record last dc

    while(TRUE) {
        neighborRate <- mean((rowSums(comb < dc)-1)/size)  ## much faster then apply
        if(neighborRate > neighborRateLow && neighborRate < neighborRateHigh) break
        if(neighborRate >= neighborRateHigh) {
            dcN <- (dc + dcL)/2    ## binary search
            dcL <- dc
            dc <- dcN
            dcMod <- dcMod/2
        }else{
            dcL <- dc
            dc <- dc + dcMod
        }
    }
    return(dc)
}


#' Computes the local density of points in a data matrix
#'
#' This function calculate the local density for each point in the matrix.
#' With a rowise implementation of the pairwise distance calculation, makes
#' the local density estimation faster and memory efficient. A big benifit
#' is the aviliability for big data. Parallel computing is supported for
#' fast calculation. The computation can either be done using a simple summation
#' of the points with the distance cutoff for each observation, or by applying
#' a gaussian kernel scaled by the distance cutoff (more robust for low-density data)
#'
#' @param data Numeric matrix of data or data frame.
#' @param dc A numeric value specifying the distance cutoff.
#' @param gaussian Logical value decide if a gaussian kernel be used to estimate the density (defaults to TRUE).
#' @param ifParallel A boolean decides if run parallelly
#'
#' @return A vector of local density values with index matching the row names of data.
localDensity <- function(data, dc, gaussian=FALSE, ifParallel = FALSE) {
    splitFactor <- splitFactorGenerator(nrow(data))
    dataFolds <- split.data.frame(data, splitFactor)

    rholist <- llply(dataFolds, function(datai, data, dc, gaussian) {
        suppressWarnings(idist <- as.matrix(pdist::pdist(datai, data)))
        if(gaussian){
            rowSums(exp(-(idist/dc)^2)) - 1
        }else{
            rowSums(idist < dc) - 1 }
        }, data = data, dc = dc, gaussian = gaussian, .parallel = ifParallel)

    rho <- do.call(base::c, rholist)
    if(is.null(row.names(data))) {
        names(rho) <- NULL
    } else {
        names(rho) <- row.names(data)
    }
    return(rho)
}


#' Calculate distance to nearest observation of higher density
#'
#' This function finds, for each observation, the minimum distance to an
#' observation of higher local density. With a rowise implementation of
#' the pairwise distance calculation, makes the local density estimation
#' fast and memory efficient. A big benifit is the aviliability for big
#' data. Parallel computing is supported for fast calculation.
#'
#' @param data Numeric matrix of data or data frame.
#' @param rho A vector of local density values as outputted by \code{localDensity}.
#' @param ifParallel A boolean decides if run parallelly.
#'
#' @return A list of distances to closest observation of higher density and the ID
minDistToHigher <- function(data, rho, ifParallel = FALSE) {
    splitFactor <- splitFactorGenerator(nrow(data))
    dataFolds <- split.data.frame(data, splitFactor)
    rhoFolds <- split(rho, splitFactor)

    dataRhoList <- mapply(function(datai, rhoi) {
        list(datai, rhoi)}, dataFolds, rhoFolds, SIMPLIFY = FALSE)

    deltaWidList <- llply(dataRhoList, function(x, data, rho){
        datai <- x[[1]]
        rhoi <- x[[2]]
        suppressWarnings(datai2dataDist <- as.matrix(pdist::pdist(datai, data)))
        rhoi2rhoComp <- outer(rhoi, rho, "<")
        drMix <- datai2dataDist * rhoi2rhoComp  # T=1; F=0
        drMix[drMix==0] <- max(datai2dataDist)
        ## assign maximal distance to the one has highest rho
        ## the nearest neighbor ID for the one has highest rho doesn't matter,
        ## because it will be assigned as the first peak
        apply(drMix, 1, function(x){c(min(x), which.min(x))})
    }, data = data, rho = rho, .parallel = ifParallel)

    deltaWid <- do.call(cbind, deltaWidList)
    delta <- deltaWid[1, ]
    names(delta) <- names(rho)
    id <- deltaWid[2, ]
    names(id) <- names(rho)

    return(list(delta = delta, higherID = id))
}



#' Automatic peak detection
#'
#' Automatic detect peaks by searching high denisty point with anomalous large distance to
#' higher denisty peaks. rho and delta are transformed to one index, and the anomalous peaks
#' are detected using generalized ESD method.
#'
#' @param rho A vector of the local density, outout of \code{localDensity}
#' @param delta A vector of distance to closest observation of higher density
#' @param alpha The level of statistical significance for peak detection.
#'
#' @return a vector containing the indexes of peaks
peakDetect <- function(rho, delta, alpha = 0.001){

    delta[is.infinite(delta)] <- max(delta[!(is.infinite(delta))])^2
    scale01 <- function(x){(x-min(x))/(max(x)-min(x))}
    rdIndex <- scale01(rho) * delta   ## transform delta, important for big data
    #rdIndex <- log(rho + 1) * delta
    peakID1 <- detect_anoms_sd(rdIndex, direction = "pos", alpha = alpha)
    peakID2 <- detect_anoms_sd(delta, direction = "pos", alpha = alpha)
    peakID <- intersect(peakID1, peakID2)

    return(peakID)
}


#' assign clusters to non-peak points
#'
#' @param peakID A vector of the peak ID.
#' @param higherID A vector of IDs of the nearest neighbor with higer density.
#' @param rho A vector of the density values.
#'
#' @return the cluster ID
clusterAssign <- function(peakID, higherID, rho){

    runOrder <- order(rho, decreasing = TRUE)
    clusterLabel <- rep(NA, length(rho))
    for(i in runOrder) {
        if(i %in% peakID){
            clusterLabel[i] <- match(i, peakID)
        }else{
            clusterLabel[i] <- clusterLabel[higherID[i]]
        }
    }
    return(clusterLabel)
}

#' differentiate halo form cores
#'
#' @param data Input data.
#' @param rho Density values.
#' @param cluster The assigned cluster labels.
#' @param peakID The peak IDs.
#' @param dc The distance cutoff value.
#'
#' @return the boolean value indicating if the point belongs to halo
haloDetect <- function(data, rho, cluster, peakID, dc){

    clusterID <- sort(unique(cluster), decreasing = FALSE)
    clusterRhoThres <- sapply(clusterID, function(clusteri){
        dataOfClusteri <- data[cluster == clusteri, ]
        otherData <- data[cluster != clusteri, ]
        rhoOfClusteri <- rho[cluster == clusteri]
        ioNeighbour <- RANN::nn2(otherData, dataOfClusteri, k=1,
                           searchtype = "radius", radius = dc/2)
        checkRes <- ioNeighbour$nn.idx[,1] != 0
        rhoThres <- ifelse(any(checkRes), max(rhoOfClusteri[checkRes]), min(rhoOfClusteri))
        rhoThres
    })
    halo <- rho < clusterRhoThres[cluster]

    return(halo)
}



## generate split factors to split rowNum into folds, each of size around foldSize
## for parallel computing usage
splitFactorGenerator <- function(rowNum, colNum){
    if(missing(colNum))
        colNum <- rowNum                    ## square matrix
    foldSize <- round(65545326 / colNum)    ## chunk maxi 500Mb, 8kb per num
    foldNum <- ceiling(rowNum / foldSize)
    sampleID <- sample(1:foldNum, rowNum, replace = TRUE)
    splitFactor <- sort(sampleID, decreasing = FALSE)

    return(splitFactor)
}




#' Outlier detection
#'
#' Using generialized ESD to detect outliers, iterate and remove point with ares higher than lamda
#' in a univariate data set assumed to come from a normally distributed population.
#'
#' @param data A vectors of boservations.
#' @param max_anoms Maximal percentile of anomalies.
#' @param alpha The level of statistical significance with which to accept or reject anomalies.
#' @param direction Directionality of the anomalies to be detected. Options are: 'pos' | 'neg' | 'both'.
#'
#' @return A vector containing indexes of the anomalies (outliers).
detect_anoms_sd <- function(data, max_anoms=0.1, alpha = 0.01, direction='pos') {

    num_obs <- length(data)
    names(data) <- 1:num_obs
    data <- na.omit(data)
    max_outliers <- trunc(num_obs*max_anoms)

    anoms <- NULL
    for (i in 1L:max_outliers){
        ares <- switch(direction,
                       pos = data - mean(data),
                       neg = mean(data) - data,
                       both = abs(data - mean(data)) )

        p <- switch(direction,
                    pos = 1 - alpha/(num_obs-i+1),
                    neg = 1 - alpha/(num_obs-i+1),
                    both = 1 - alpha/(2*(num_obs-i+1)) )

        data_sigma <- sd(data)
        if(data_sigma == 0) break
        ares <- ares/data_sigma
        maxAres <- max(ares)

        t <- qt(p, (num_obs-i-1))
        lam <- t*(num_obs-i) / sqrt((num_obs-i-1+t**2)*(num_obs-i+1))

        if(maxAres > lam){
            maxAres_id <- which(ares == maxAres)
            anoms <- c(anoms, names(maxAres_id))
            data <- data[-maxAres_id ]
        }else
            break
    }

    return(as.numeric(anoms))
}

