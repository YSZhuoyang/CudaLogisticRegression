#include "Helper.h"
#include "ArffImporter.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>



Node initNode( unsigned int numFeatures )
{
    Node node;
    node.numFeatures = numFeatures;
    node.weights = (double*) malloc( (numFeatures + 1) * sizeof( double ) );
    memset( node.weights, 1, (numFeatures + 1) * sizeof( double ) );

    return node;
}

void normalize(
    std::vector<NumericAttr> featureVec,
    double* featureBuff,
    unsigned int numInstances )
{
    unsigned int numFeatures = featureVec.size();

    for (unsigned int i = 0; i < numFeatures; i++)
    {
        // Use either range / standard deviation
        double range = featureVec[i].max - featureVec[i].min;
        if (range == 0.0) continue;

        for (unsigned int j = 0; j < numInstances; j++)
        {
            unsigned int featureIndex = j * numFeatures + i;
            featureBuff[featureIndex] =
                (featureBuff[featureIndex] - featureVec[i].mean) / range;
        }
    }
}

inline double activate(
    Node* node,
    double* inputArr )
{
    double linearRes = node->weights[node->numFeatures];
    node->inputs = inputArr;

    unsigned int numFeatures = node->numFeatures;
    for (unsigned int i = 0; i < numFeatures; i++)
        linearRes += node->weights[i] * node->inputs[i];

    node->output = 1.0 / (1.0 + exp(-linearRes));

    return node->output;
}

inline double computeCost( double hRes, unsigned short y )
{
    return (y)? -log(hRes) : -log(1.0 - hRes);
    // return -y * log(hRes) - (1 - y) * (1 - log(hRes));
}

int main()
{
    ArffImporter trainSetImporter;
    trainSetImporter.Read( "Dataset/train/train-first1000.arff" );

    // ArffImporter testSetImporter;
    // testSetImporter.Read( "Dataset/test/dev-first1000.arff" );

    unsigned int numInst = trainSetImporter.GetNumInstances();
    double* featureBuff = trainSetImporter.GetInstances();
    unsigned short* classIndexBuff = trainSetImporter.GetClassIndex();
    std::vector<NumericAttr> featureVec = trainSetImporter.GetFeatures();
    unsigned int numFeatures = featureVec.size();

    normalize( featureVec, featureBuff, numInst );

    Node node = initNode( numFeatures );
    unsigned int iter = 0;
    unsigned int maxIter = 200;
    double costSumPre = 0.0;
    double deltaCostSum = 0.0;
    double alpha = 50.0;
    double* batchArr = (double*) malloc( numFeatures * sizeof( double ) );

    time_t start, end;
    double dif;
    time( &start );
    
    // Gradient descent
    do
    {
        double costSumNew = 0.0;
        memset( batchArr, 0, numFeatures * sizeof( double ) );

        for (unsigned int i = 0; i < numInst; i++)
        {
            double hRes = activate( &node, &featureBuff[i * numFeatures] );
            double diff = hRes - (double) classIndexBuff[i];
            costSumNew += computeCost( hRes, classIndexBuff[i] );
            for (unsigned int j = 0; j < numFeatures; j++)
                batchArr[j] += diff * node.inputs[j];
        }

        deltaCostSum = costSumPre - costSumNew;
        costSumPre = costSumNew;

        // printf( "Delta cost: %f\n", deltaCostSum );

        // Update weights
        printf( "Weight: %f\n", node.weights[0] );
        for (unsigned int j = 0; j < numFeatures; j++)
            node.weights[j] -= alpha / (double) numInst * batchArr[j];
        
        iter++;
    }
    while (iter == 1 || (deltaCostSum > 1.0 && iter < maxIter));

    time( &end );
    dif = difftime( end, start );

    printf( "Time taken is %.2lf seconds.\n", dif );
    
    return 0;
}
