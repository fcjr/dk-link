/* DK Link CHOP for macOS: body joints from the DK Link library's
 * tracker as channels named the way the Windows Kinect CHOPs name them
 * (p1/pelvis:tx ...). */
#include "DKLinkCHOP.h"
#include "DKLinkCommon.h"
#include <cstdio>
#include <cstring>

extern "C" {

DLLEXPORT void FillCHOPPluginInfo(CHOP_PluginInfo *info)
{
    if (!info->setAPIVersion(CHOPCPlusPlusAPIVersion))
        return;
    info->customOPInfo.opType->setString("Dklink");
    info->customOPInfo.opLabel->setString("DK Link");
    info->customOPInfo.opIcon->setString("KAZ");
    info->customOPInfo.authorName->setString("DK Link");
    info->customOPInfo.authorEmail->setString("");
    info->customOPInfo.opHelpURL->setString("https://github.com/fcjr/dk-mac");
    info->customOPInfo.minInputs = 0;
    info->customOPInfo.maxInputs = 0;
}

DLLEXPORT CHOP_CPlusPlusBase *CreateCHOPInstance(const OP_NodeInfo *info)
{
    return new DKLinkCHOP(info);
}

DLLEXPORT void DestroyCHOPInstance(CHOP_CPlusPlusBase *instance)
{
    delete (DKLinkCHOP *)instance;
}
}

DKLinkCHOP::DKLinkCHOP(const OP_NodeInfo *info) : myNodeInfo(info)
{
    mySession = ktd_session_acquire();
}

DKLinkCHOP::~DKLinkCHOP()
{
    if (mySession)
        ktd_session_release(mySession);
}

void DKLinkCHOP::getGeneralInfo(CHOP_GeneralInfo *ginfo, const OP_Inputs *, void *)
{
    ginfo->cookEveryFrame = true;
    ginfo->cookEveryFrameIfAsked = true;
    ginfo->timeslice = false;
    ginfo->inputMatchIndex = 0;
}

void DKLinkCHOP::buildChannels(const OP_Inputs *inputs)
{
    Layout layout;
    layout.maxPlayers = inputs->getParInt("Maxplayers");
    if (layout.maxPlayers < 1) layout.maxPlayers = 1;
    if (layout.maxPlayers > 16) layout.maxPlayers = 16;
    layout.world = inputs->getParInt("Worldspace") != 0;
    layout.color = inputs->getParInt("Colorspace") != 0;
    layout.confidence = inputs->getParInt("Confidence") != 0;
    layout.tracked = true;

    myNames.clear();
    char name[128];
    for (int p = 1; p <= layout.maxPlayers; p++)
    {
        snprintf(name, sizeof name, "p%d/tracked", p); myNames.push_back(name);
        snprintf(name, sizeof name, "p%d/id", p); myNames.push_back(name);
        for (int j = 0; j < KTD_JOINT_COUNT; j++)
        {
            const char *joint = ktd_joint_name(j);
            if (!joint) continue;
            if (layout.world)
            {
                snprintf(name, sizeof name, "p%d/%s:tx", p, joint); myNames.push_back(name);
                snprintf(name, sizeof name, "p%d/%s:ty", p, joint); myNames.push_back(name);
                snprintf(name, sizeof name, "p%d/%s:tz", p, joint); myNames.push_back(name);
            }
            if (layout.color)
            {
                snprintf(name, sizeof name, "p%d/%s:u", p, joint); myNames.push_back(name);
                snprintf(name, sizeof name, "p%d/%s:v", p, joint); myNames.push_back(name);
            }
            if (layout.confidence)
            {
                snprintf(name, sizeof name, "p%d/%s:confidence", p, joint); myNames.push_back(name);
            }
        }
    }
    myLayout = layout;
}

bool DKLinkCHOP::getOutputInfo(CHOP_OutputInfo *info, const OP_Inputs *inputs, void *)
{
    buildChannels(inputs);
    info->numChannels = (int32_t)myNames.size();
    info->numSamples = 1;
    info->startIndex = 0;
    info->sampleRate = 60;
    return true;
}

void DKLinkCHOP::getChannelName(int32_t index, OP_String *name, const OP_Inputs *, void *)
{
    if (index >= 0 && index < (int32_t)myNames.size())
        name->setString(myNames[index].c_str());
    else
        name->setString("chan");
}

void DKLinkCHOP::execute(CHOP_Output *output, const OP_Inputs *inputs, void *)
{
    myExecuteCount++;
    myWarning.clear();
    for (int32_t c = 0; c < output->numChannels; c++)
        output->channels[c][0] = 0.0f;

    const bool active = inputs->getParInt("Active") != 0;
    if (!active)
        return;

    myBodies.resize((size_t)myLayout.maxPlayers);
    myBodyCount = ktd_session_bodies(mySession, myBodies.data(), myLayout.maxPlayers, &myBodyFrame);
    // Asking for bodies is what switches tracking on; the first result takes a
    // moment, and needs an active DK Link TOP (or the app) streaming.
    if (myBodyFrame == 0)
        myWarning = "Body tracking is starting (no results yet). It needs an active DK Link TOP or the DK Link app streaming.";

    // The colour image size, for UV coordinates.
    ktd_image_info colorInfo{};
    ktd_session_latest_image(mySession, KTD_IMAGE_COLOR, 0, &colorInfo, nullptr, 0);
    const float cw = colorInfo.width > 0 ? (float)colorInfo.width : 1280.0f;
    const float ch = colorInfo.height > 0 ? (float)colorInfo.height : 720.0f;
    const bool flipV = inputs->getParInt("Flipimagev") != 0;
    const bool flipU = inputs->getParInt("Flipskelu") != 0;

    int32_t c = 0;
    for (int p = 0; p < myLayout.maxPlayers; p++)
    {
        const bool have = p < myBodyCount;
        const ktd_body *body = have ? &myBodies[(size_t)p] : nullptr;
        if (c < output->numChannels) output->channels[c++][0] = have ? 1.0f : 0.0f;
        if (c < output->numChannels) output->channels[c++][0] = have ? (float)body->id : 0.0f;
        for (int j = 0; j < KTD_JOINT_COUNT; j++)
        {
            if (!ktd_joint_name(j)) continue;
            const ktd_joint *joint = have ? &body->joints[j] : nullptr;
            const bool valid = joint && joint->valid;
            if (myLayout.world)
            {
                if (c + 2 < output->numChannels + 0 && c < output->numChannels)
                {
                    output->channels[c++][0] = valid ? joint->x : 0.0f;
                    output->channels[c++][0] = valid ? joint->y : 0.0f;
                    output->channels[c++][0] = valid ? joint->z : 0.0f;
                }
            }
            if (myLayout.color)
            {
                float u = valid ? joint->pixel_x / cw : 0.0f;
                float v = valid ? 1.0f - joint->pixel_y / ch : 0.0f;
                if (valid && flipU) u = 1.0f - u;
                if (valid && flipV) v = 1.0f - v;
                if (c + 1 < output->numChannels)
                {
                    output->channels[c++][0] = u;
                    output->channels[c++][0] = v;
                }
            }
            if (myLayout.confidence)
            {
                if (c < output->numChannels)
                    output->channels[c++][0] = valid ? joint->confidence : 0.0f;
            }
        }
    }
}

int32_t DKLinkCHOP::getNumInfoCHOPChans(void *)
{
    return 4;
}

void DKLinkCHOP::getInfoCHOPChan(int32_t index, OP_InfoCHOPChan *chan, void *)
{
    switch (index)
    {
    case 0: chan->name->setString("bodytracking_frame"); chan->value = (float)myBodyFrame; break;
    case 1: chan->name->setString("bodytracking_bodies"); chan->value = (float)myBodyCount; break;
    case 2: chan->name->setString("bodytracking_ms"); chan->value = (float)ktd_session_stat(mySession, KTD_STAT_BODY_MILLISECONDS); break;
    case 3: chan->name->setString("executeCount"); chan->value = (float)myExecuteCount; break;
    }
}

void DKLinkCHOP::getWarningString(OP_String *warning, void *)
{
    if (!myWarning.empty())
        warning->setString(myWarning.c_str());
}

void DKLinkCHOP::getInfoPopupString(OP_String *info, void *)
{
    char status[256];
    ktd_session_status(mySession, status, sizeof status);
    info->setString(status);
}

void DKLinkCHOP::setupParameters(OP_ParameterManager *manager, void *)
{
    const char *page = "DK Link";
    {
        OP_NumericParameter np("Active");
        np.label = "Active"; np.page = page; np.defaultValues[0] = 1;
        manager->appendToggle(np);
    }
    {
        OP_StringParameter sp("Top");
        sp.label = "DK Link TOP"; sp.page = page; sp.defaultValue = "";
        manager->appendTOP(sp); // kept for Windows patches; every node shares the one camera on macOS
    }
    {
        OP_NumericParameter np("Maxplayers");
        np.label = "Max Players"; np.page = page; np.defaultValues[0] = 1;
        np.minSliders[0] = 1; np.maxSliders[0] = 6; np.minValues[0] = 1; np.maxValues[0] = 16;
        np.clampMins[0] = true; np.clampMaxes[0] = true;
        manager->appendInt(np);
    }
    {
        OP_NumericParameter np("Worldspace");
        np.label = "World Space Positions"; np.page = page; np.defaultValues[0] = 1;
        manager->appendToggle(np);
    }
    {
        OP_NumericParameter np("Colorspace");
        np.label = "Color Image Positions"; np.page = page; np.defaultValues[0] = 1;
        manager->appendToggle(np);
    }
    {
        OP_NumericParameter np("Confidence");
        np.label = "Bone Confidence"; np.page = page; np.defaultValues[0] = 1;
        manager->appendToggle(np);
    }
    {
        OP_NumericParameter np("Flipimagev");
        np.label = "Mirror Image V Positions"; np.page = page; np.defaultValues[0] = 0;
        manager->appendToggle(np);
    }
    {
        OP_NumericParameter np("Flipskelu");
        np.label = "Mirror U Positions"; np.page = page; np.defaultValues[0] = 0;
        manager->appendToggle(np);
    }
}
