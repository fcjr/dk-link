#pragma once
#include "sdk/CHOP_CPlusPlusBase.h"
#include "dklinktd.h"
#include <string>
#include <vector>

using namespace TD;

class DKLinkCHOP : public CHOP_CPlusPlusBase
{
public:
    DKLinkCHOP(const OP_NodeInfo *info);
    ~DKLinkCHOP() override;

    void getGeneralInfo(CHOP_GeneralInfo *, const OP_Inputs *, void *) override;
    bool getOutputInfo(CHOP_OutputInfo *, const OP_Inputs *, void *) override;
    void getChannelName(int32_t index, OP_String *name, const OP_Inputs *, void *) override;
    void execute(CHOP_Output *, const OP_Inputs *, void *) override;
    int32_t getNumInfoCHOPChans(void *) override;
    void getInfoCHOPChan(int32_t index, OP_InfoCHOPChan *chan, void *) override;
    void getWarningString(OP_String *, void *) override;
    void getInfoPopupString(OP_String *, void *) override;
    void setupParameters(OP_ParameterManager *, void *) override;

private:
    struct Layout
    {
        int maxPlayers = 1;
        bool world = true, color = true, confidence = true, tracked = true;
    };
    void buildChannels(const OP_Inputs *inputs);

    const OP_NodeInfo *myNodeInfo;
    ktd_session *mySession = nullptr;
    Layout myLayout;
    std::vector<std::string> myNames;
    std::vector<ktd_body> myBodies;
    uint64_t myBodyFrame = 0;
    int32_t myBodyCount = 0;
    int32_t myExecuteCount = 0;
    std::string myWarning;
};
