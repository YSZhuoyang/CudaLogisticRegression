#include "Helper.h"
#include "ArffImporter.h"

#include <math.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>


#define WARP_SIZE 32

Node initNode( unsigned int numFeatures )
{
    Node node;
    node.numFeatures = numFeatures;
    node.weights = (float*) malloc( (numFeatures + 1) * sizeof( float ) );
    memset( node.weights, 0, (numFeatures + 1) * sizeof( float ) );

    return node;
}

void normalize(
    std::vector<NumericAttr> featureVec,
    float* featureBuff,
    float* featureBuffTrans,
    unsigned int numInstances )
{
    unsigned int numFeatures = featureVec.size();

    for (unsigned int i = 0; i < numFeatures; i++)
    {
        // Use either range / standard deviation
        float range = featureVec[i].max - featureVec[i].min;
        if (range == 0.0) continue;

        for (unsigned int j = 0; j < numInstances; j++)
        {
            unsigned int featureIndex = j * numFeatures + i;
            featureBuff[featureIndex] =
                (featureBuff[featureIndex] - featureVec[i].mean) / range;
            featureBuffTrans[i * numInstances + j] = featureBuff[featureIndex];
        }
    }
}

__device__ __forceinline__ float shuffleReduceSum( float regValue )
{
    for (unsigned int shift = WARP_SIZE / 2; shift > 0; shift >>= 1)
        regValue += __shfl_down( regValue, shift );
    // for (unsigned int i = 1; i < WARP_SIZE; i *= 2) // i =<< 1
    //     regValue += __shfl_xor( regValue, i );
    return regValue;
}

// Sum up any arrays with a maximum length of 1024
// elementId is equal to the threadId
__device__ __forceinline__ float shuffleParallelSum(
    float regValue,
    const unsigned int numWarps,
    const unsigned int elementId )
{
    __shared__ float shared[32];
    int warpThreadId = elementId % WARP_SIZE;
    int warpId = elementId / WARP_SIZE;

    // Performing warp reduction. Only the threads with 0 index
    // within the warp have the "val" value set with the warp reduction result
    regValue = shuffleReduceSum( regValue );     

    // Only the threads with 0 index within the warp write the warp result to shared memory
    if (warpThreadId == 0) shared[warpId] = regValue;

    // Wait for all warp reductions
    __syncthreads();

    // There will be at most 1024 threads within a block and at most 1024 blocks within a grid.
    // The partial sum is read from shared memory only the corresponding
    // warp existed, otherwise the partial sum is set to zero.
    regValue = (elementId < numWarps) ? shared[warpThreadId] : 0;

    // The first warp performs the final partial warp summation.
    // Note that numWarps is always smaller than 32 given an array with a maximum length of 1024.
    if (warpId == 0) regValue = shuffleReduceSum( regValue ); 

    return regValue;
}

// Parallel sum using a shared memory
__device__ __forceinline__ void parallelSum(
    float* sharedData,
    const unsigned int elementId,
    const unsigned int length )
{
    for (unsigned int i = length; i > 1; i >>= 1)
    {
        unsigned int shift = i / 2;
        if (elementId < shift)
        {
            sharedData[elementId] +=
                sharedData[elementId + shift];

            // Odd
            if (i & 1 && elementId == shift - 1)
                sharedData[elementId] += sharedData[i - 1];
        }
        __syncthreads();
    }
}

__global__ void Activate(
    float* dDiffArr,
    const float* dWeightArr,
    const float* dFeatureBuff,
    const unsigned short* dClassBuff,
    const unsigned int numWarps,
    const unsigned int numInstances,
    const unsigned int numFeatures )
{
    unsigned int instanceId = blockIdx.y * gridDim.x + blockIdx.x;
    unsigned int featureId = threadIdx.y * blockDim.x + threadIdx.x;
    if (instanceId >= numInstances || featureId >= numFeatures) return;
    // if (featureId == 0) printf( "Instance ID: %u\n", instanceId );

    float hRes = dWeightArr[numFeatures];
    const float* dFeaOffset = dFeatureBuff + instanceId * numFeatures;

    hRes += shuffleParallelSum(
        dWeightArr[featureId] * dFeaOffset[featureId],
        numWarps,
        featureId );

    if (featureId == 0)
    {
        hRes = 1.0 / (1.0 + exp(-hRes));
        dDiffArr[instanceId] = hRes - (float) dClassBuff[instanceId];
    }
}

__global__ void UpdateWeight(
    float* dDiffArr,
    float* dWeightArr,
    const float* dFeatureBuffTrans,
    const unsigned int alpha,
    const unsigned int chunkSize,
    const unsigned int numWarps,
    const unsigned int numInstances,
    const unsigned int numFeatures )
{
    // One block per feature, one thread per group of instances
    unsigned int featureId = blockIdx.y * gridDim.x + blockIdx.x;
    unsigned int instChunkId = threadIdx.y * blockDim.x + threadIdx.x;
    if (instChunkId >= numInstances || featureId >= numFeatures) return;

    unsigned int stopId;
    if (instChunkId == blockDim.x - 1) // Last chunk
        stopId = numInstances;
    else
        stopId = chunkSize * (instChunkId + 1);

    float multSum = 0.0;
    for (unsigned int i = chunkSize * instChunkId; i < stopId; i++)
        multSum += dFeatureBuffTrans[featureId * numInstances + i] * dDiffArr[i];
    multSum = shuffleParallelSum(
        multSum,
        numWarps,
        instChunkId );

    // Update weights
    if (instChunkId == 0)
    {
        dWeightArr[featureId] -=
            alpha / (float) numInstances * multSum;

        if (featureId == 0)
            printf( "Updating weights completed, weight: %f\n", dWeightArr[0] );
    }
}

inline void cudaErrorCheck( cudaError_t cudaRes )
{
    if (cudaRes != cudaSuccess)
        printf(
            "kernel launch failed with error \"%s\".\n",
            cudaGetErrorString( cudaRes )
        );
}

int main()
{
    ArffImporter trainSetImporter;
    trainSetImporter.Read( "Dataset/train/train-first1000.arff" );

    // ArffImporter testSetImporter;
    // testSetImporter.Read( "Dataset/test/dev-first1000.arff" );

    unsigned int numInstances = trainSetImporter.GetNumInstances();
    float* featureBuff = trainSetImporter.GetFeatureBuff();
    float* featureBuffTrans = trainSetImporter.GetFeatureBuffTrans();
    unsigned short* classIndexBuff = trainSetImporter.GetClassIndex();
    std::vector<NumericAttr> featureVec = trainSetImporter.GetFeatures();
    unsigned int numFeatures = featureVec.size();

    unsigned int alpha = 50;
    unsigned int maxIter = 200;
    unsigned int iter = 0;

    normalize( featureVec, featureBuff, featureBuffTrans, numInstances );
    Node node = initNode( numFeatures );

    float* dDiffArr;
    float* dWeightArr;
    float* dFeatureBuff;
    float* dFeatureBuffTrans;
    unsigned short* dClassBuff;
    cudaErrorCheck( cudaMalloc( (void**) &dWeightArr, (numFeatures + 1) * sizeof( float ) ) );
    cudaErrorCheck( cudaMalloc( (void**) &dDiffArr, numInstances * sizeof( float ) ) );
    cudaErrorCheck( cudaMalloc( (void**) &dFeatureBuff, numInstances * numFeatures * sizeof( float ) ) );
    cudaErrorCheck( cudaMalloc( (void**) &dFeatureBuffTrans, numInstances * numFeatures * sizeof( float ) ) );
    cudaErrorCheck( cudaMalloc( (void**) &dClassBuff, numInstances * sizeof( unsigned short ) ) );
    cudaErrorCheck( cudaMemcpy(
        dFeatureBuff,
        featureBuff,
        numInstances * numFeatures * sizeof( float ),
        cudaMemcpyHostToDevice ) );
    cudaErrorCheck( cudaMemcpy(
        dFeatureBuffTrans,
        featureBuffTrans,
        numInstances * numFeatures * sizeof( float ),
        cudaMemcpyHostToDevice ) );
    cudaErrorCheck( cudaMemcpy(
        dWeightArr,
        node.weights,
        (numFeatures + 1) * sizeof( float ),
        cudaMemcpyHostToDevice ) );
    cudaErrorCheck( cudaMemcpy(
        dClassBuff,
        classIndexBuff,
        numInstances * sizeof( unsigned short ),
        cudaMemcpyHostToDevice ) );

    /*--------- Determine block and grid size of Activat kernel ---------*/
    dim3 actBlockDim;
    dim3 actGridDim;
    // Assume numFeatures <= 1024 (max number of threads per block)
    actBlockDim.x = numFeatures;
    if (numInstances < 1024)
        actGridDim.x = numInstances;
    else
    {
        actGridDim.x = 1024;
        actGridDim.y = (numInstances + actGridDim.x - 1) / actGridDim.x;
    }
    // Compute number of warps for shuffle reduction sum
    unsigned int actNumWarps = (numFeatures + WARP_SIZE - 1) / WARP_SIZE;

    /*------- Determine block and grid size of UpdateWeight kernel -------*/
    dim3 uwBlockDim;
    dim3 uwGridDim;
    unsigned int uwChunkSize;
    unsigned int uwNumChunks;
    if (numInstances > 1024)
    {
        uwNumChunks = 1024;
        uwChunkSize = numInstances / uwNumChunks;
    }
    else
    {
        uwNumChunks = numInstances;
        uwChunkSize = 1;
    }
    uwBlockDim.x = uwNumChunks;
    uwGridDim.x = numFeatures;
    // Compute number of warps for shuffle reduction sum
    unsigned int uwNumWarps = (uwNumChunks + WARP_SIZE - 1) / WARP_SIZE;

    time_t start, end;
    float dif;
    time( &start );
    
    printf( "\nStart gradient descent...\n" );

    // Gradient descent
    do
    {
        Activate<<< actGridDim, actBlockDim >>>(
            dDiffArr,
            dWeightArr,
            dFeatureBuff,
            dClassBuff,
            actNumWarps,
            numInstances,
            numFeatures );
        cudaErrorCheck( cudaGetLastError() );

        UpdateWeight<<< uwGridDim, uwBlockDim >>>(
            dDiffArr,
            dWeightArr,
            dFeatureBuffTrans,
            alpha,
            uwChunkSize,
            uwNumWarps,
            numInstances,
            numFeatures );
        cudaErrorCheck( cudaGetLastError() );

        iter++;
    }
    while (iter == 1 || iter < maxIter);

    cudaErrorCheck( cudaThreadSynchronize() );
    
    // cudaMemcpy(weight);
    // cublasErrorCheck( cublasDestroy( cublasHandle ) );

    time( &end );
    dif = difftime( end, start );
    printf( "Time taken is %.2lf seconds.\n", dif );

    cudaFree( dFeatureBuff );
    cudaFree( dFeatureBuffTrans );
    cudaFree( dClassBuff );
    cudaFree( dWeightArr );
    cudaFree( dDiffArr );

    free( node.weights );

    return 0;
}
