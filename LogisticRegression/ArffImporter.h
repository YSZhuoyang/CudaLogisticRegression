
#ifndef _ARFF_IMPORTER_H_
#define _ARFF_IMPORTER_H_


#include "BasicDataStructures.h"
#include "Helper.h"

#include <stdio.h>
#include <string.h>


using namespace BasicDataStructures;
using namespace MyHelper;

class ArffImporter
{
#define READ_LINE_MAX     5000
#define TOKEN_LENGTH_MAX  35

#define KEYWORD_ATTRIBUTE "@ATTRIBUTE"
#define KEYWORD_DATA      "@DATA"
#define KEYWORD_NUMERIC   "NUMERIC"

public:
    ArffImporter();
    ~ArffImporter();

    void Read( const char* fileName );
    std::vector<char*> GetClassAttr();
    std::vector<NumericAttr> GetFeatures();
    float* GetFeatureBuff();
    float* GetFeatureBuffTrans();
    unsigned short* GetClassIndex();
    unsigned int GetNumInstances();


private:
    void BuildInstanceTable();

    std::vector<char*> classVec;
    std::vector<NumericAttr> featureVec;
    std::vector<Instance> instanceVec;

    // Instance* instanceTable        = nullptr;
    float* featureBuff            = nullptr;
    float* featureBuffTrans       = nullptr;
    unsigned short* classIndexBuff = nullptr;

    unsigned int numFeatures       = 0;
    unsigned int numInstances      = 0;
    unsigned short numClasses      = 0;
};

#endif
