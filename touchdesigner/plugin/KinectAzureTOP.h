#pragma once
#include "sdk/TOP_CPlusPlusBase.h"
#include "kinecttd.h"
#include <string>
#include <vector>

using namespace TD;

class KinectAzureTOP : public TOP_CPlusPlusBase
{
public:
    KinectAzureTOP(const OP_NodeInfo *info, TOP_Context *context);
    ~KinectAzureTOP() override;

    void getGeneralInfo(TOP_GeneralInfo *, const OP_Inputs *, void *) override;
    void execute(TOP_Output *, const OP_Inputs *, void *) override;
    int32_t getNumInfoCHOPChans(void *) override;
    void getInfoCHOPChan(int32_t index, OP_InfoCHOPChan *chan, void *) override;
    bool getInfoDATSize(OP_InfoDATSize *, void *) override;
    void getInfoDATEntries(int32_t index, int32_t nEntries, OP_InfoDATEntries *, void *) override;
    void getWarningString(OP_String *, void *) override;
    void getErrorString(OP_String *, void *) override;
    void getInfoPopupString(OP_String *, void *) override;
    void setupParameters(OP_ParameterManager *, void *) override;
    void pulsePressed(const char *name, void *) override;

private:
    void applyConfiguration(const OP_Inputs *inputs);
    void mirrorRows(uint8_t *data, int32_t width, int32_t height, size_t bytesPerPixel);

    const OP_NodeInfo *myNodeInfo;
    TOP_Context *myContext;
    ktd_session *mySession = nullptr;
    ktd_config myConfig{};
    bool myConfigured = false;
    bool myActive = false;
    int myImageIndex = -1;
    uint64_t myLastFrame = 0;
    ktd_image_info myLastInfo{};
    int32_t myExecuteCount = 0;
    std::string myWarning;
    std::string myError;
};
