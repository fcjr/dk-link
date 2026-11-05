/* DK Link TOP for macOS: the images of an Azure Kinect DK, through the
 * DK Link library, with the Windows operator's parameters and image
 * menu so patches move between the two by swapping the node. */
#include "DKLinkTOP.h"
#include "DKLinkCommon.h"
#include <cassert>
#include <cstdio>
#include <cstring>

extern "C" {

DLLEXPORT void FillTOPPluginInfo(TOP_PluginInfo *info)
{
    if (!info->setAPIVersion(TOPCPlusPlusAPIVersion))
        return;
    info->executeMode = TOP_ExecuteMode::CPUMem;
    info->customOPInfo.opType->setString("Dklink");
    info->customOPInfo.opLabel->setString("DK Link");
    info->customOPInfo.opIcon->setString("KAZ");
    info->customOPInfo.authorName->setString("DK Link");
    info->customOPInfo.authorEmail->setString("");
    info->customOPInfo.opHelpURL->setString("https://github.com/fcjr/dk-link");
    info->customOPInfo.minInputs = 0;
    info->customOPInfo.maxInputs = 0;
}

DLLEXPORT TOP_CPlusPlusBase *CreateTOPInstance(const OP_NodeInfo *info, TOP_Context *context)
{
    return new DKLinkTOP(info, context);
}

DLLEXPORT void DestroyTOPInstance(TOP_CPlusPlusBase *instance, TOP_Context *)
{
    delete (DKLinkTOP *)instance;
}
}

DKLinkTOP::DKLinkTOP(const OP_NodeInfo *info, TOP_Context *context) : myNodeInfo(info), myContext(context)
{
    mySession = ktd_session_acquire();
}

DKLinkTOP::~DKLinkTOP()
{
    if (mySession)
        ktd_session_release(mySession);
}

void DKLinkTOP::getGeneralInfo(TOP_GeneralInfo *ginfo, const OP_Inputs *, void *)
{
    // A device-driven node: cook every frame while active, like the Windows
    // DK Link TOP, so the image keeps flowing whether or not anything
    // is looking, and the library keeps seeing our interest in its kind.
    ginfo->cookEveryFrame = myActive;
    ginfo->cookEveryFrameIfAsked = true;
}

void DKLinkTOP::applyConfiguration(const OP_Inputs *inputs)
{
    ktd_config config{};
    const int depth = inputs->getParInt("Depthmode");
    const int color = inputs->getParInt("Colorres");
    const int fps = inputs->getParInt("Fps");
    config.depth_mode = kaz::kDepthModes[depth >= 0 && depth < kaz::count(kaz::kDepthModes) ? depth : 0];
    config.color_resolution = kaz::kColorModes[color >= 0 && color < kaz::count(kaz::kColorModes) ? color : 0];
    config.fps = kaz::kFpsModes[fps >= 0 && fps < kaz::count(kaz::kFpsModes) ? fps : 2];
    config.body_tracking = inputs->getParInt("Bodytracking") != 0;
    config.device_index = inputs->getParInt("Sensor");
    const bool active = inputs->getParInt("Active") != 0;

    if (!myConfigured || !kaz::configEquals(config, myConfig) || active != myActive)
    {
        const int rc = ktd_session_configure(mySession, &config, active);
        myConfig = config;
        myActive = active;
        myConfigured = true;
        myLastFrame = 0;
        if (rc != 0)
        {
            char status[256];
            ktd_session_status(mySession, status, sizeof status);
            myError = status;
        }
        else
        {
            myError.clear();
        }
    }
}

void DKLinkTOP::mirrorRows(uint8_t *data, int32_t width, int32_t height, size_t bpp)
{
    std::vector<uint8_t> tmp(bpp);
    for (int32_t y = 0; y < height; y++)
    {
        uint8_t *row = data + (size_t)y * width * bpp;
        for (int32_t x = 0; x < width / 2; x++)
        {
            uint8_t *a = row + (size_t)x * bpp, *b = row + (size_t)(width - 1 - x) * bpp;
            memcpy(tmp.data(), a, bpp);
            memcpy(a, b, bpp);
            memcpy(b, tmp.data(), bpp);
        }
    }
}

void DKLinkTOP::execute(TOP_Output *output, const OP_Inputs *inputs, void *)
{
    myExecuteCount++;
    applyConfiguration(inputs);
    myWarning.clear();
    if (!myActive)
        return;

    const int image = inputs->getParInt("Image");
    if (image != myImageIndex)
    {
        myImageIndex = image;
        myLastFrame = 0;
    }
    const int kind = image >= 0 && image < kaz::count(kaz::kImageKinds) ? kaz::kImageKinds[image] : -1;
    if (kind < 0)
    {
        myWarning = "This image is not available on macOS (no aligned IR or player index); pick another Image.";
        return;
    }

    ktd_image_info info;
    if (ktd_session_latest_image(mySession, (ktd_image_kind)kind, myLastFrame, &info, nullptr, 0) == 0)
    {
        if (info.width == 0)
        {
            char status[256];
            ktd_session_status(mySession, status, sizeof status);
            myWarning = std::string("No ") + kaz::kImageLabels[image] + " image in this configuration: " + status;
        }
        return; // nothing newer than what is already uploaded
    }

    OP_SmartRef<TOP_Buffer> buf = myContext->createOutputBuffer(info.bytes, TOP_BufferFlags::None, nullptr);
    if (!buf)
        return;
    const uint64_t frame = ktd_session_latest_image(mySession, (ktd_image_kind)kind, myLastFrame, &info, buf->data, buf->size);
    if (frame == 0)
        return;
    myLastFrame = frame;
    myLastInfo = info;

    size_t bpp = 4;
    OP_PixelFormat format = OP_PixelFormat::BGRA8Fixed;
    switch (info.pixel_format)
    {
    case KTD_PIXEL_BGRA8: format = OP_PixelFormat::BGRA8Fixed; bpp = 4; break;
    case KTD_PIXEL_R16: format = OP_PixelFormat::Mono16Fixed; bpp = 2; break;
    case KTD_PIXEL_R32F: format = OP_PixelFormat::Mono32Float; bpp = 4; break;
    case KTD_PIXEL_RGBA32F: format = OP_PixelFormat::RGBA32Float; bpp = 16; break;
    case KTD_PIXEL_R8: format = OP_PixelFormat::Mono8Fixed; bpp = 1; break;
    }
    if (inputs->getParInt("Mirrorimage"))
        mirrorRows((uint8_t *)buf->data, info.width, info.height, bpp);

    TOP_UploadInfo upload;
    upload.textureDesc.width = (uint32_t)info.width;
    upload.textureDesc.height = (uint32_t)info.height;
    upload.textureDesc.texDim = OP_TexDim::e2D;
    upload.textureDesc.pixelFormat = format;
    upload.firstPixel = TOP_FirstPixel::TopLeft; // rows arrive top first
    output->uploadBuffer(&buf, upload, nullptr);
}

int32_t DKLinkTOP::getNumInfoCHOPChans(void *)
{
    return 9;
}

void DKLinkTOP::getInfoCHOPChan(int32_t index, OP_InfoCHOPChan *chan, void *)
{
    switch (index)
    {
    case 0: chan->name->setString("image_frame"); chan->value = (float)myLastFrame; break;
    case 1: chan->name->setString("depth_timestamp"); chan->value = (float)myLastInfo.device_timestamp_usec; break;
    case 2: chan->name->setString("captures_per_second"); chan->value = (float)ktd_session_stat(mySession, KTD_STAT_CAPTURES_PER_SECOND); break;
    case 3: chan->name->setString("decode_ms"); chan->value = (float)ktd_session_stat(mySession, KTD_STAT_DECODE_MILLISECONDS); break;
    case 4: chan->name->setString("sensor_temperature"); chan->value = (float)ktd_session_stat(mySession, KTD_STAT_SENSOR_TEMPERATURE_C); break;
    case 5: chan->name->setString("bodytracking_ms"); chan->value = (float)ktd_session_stat(mySession, KTD_STAT_BODY_MILLISECONDS); break;
    case 6: chan->name->setString("bodytracking_bodies"); chan->value = (float)ktd_session_stat(mySession, KTD_STAT_BODY_COUNT); break;
    case 7: chan->name->setString("devices"); chan->value = (float)ktd_session_stat(mySession, KTD_STAT_DEVICES); break;
    case 8: chan->name->setString("executeCount"); chan->value = (float)myExecuteCount; break;
    }
}

bool DKLinkTOP::getInfoDATSize(OP_InfoDATSize *size, void *)
{
    size->rows = 4;
    size->cols = 2;
    size->byColumn = false;
    return true;
}

void DKLinkTOP::getInfoDATEntries(int32_t index, int32_t, OP_InfoDATEntries *entries, void *)
{
    char value[512] = "";
    switch (index)
    {
    case 0: entries->values[0]->setString("status"); ktd_session_status(mySession, value, sizeof value); break;
    case 1: entries->values[0]->setString("serial"); ktd_session_serial(mySession, value, sizeof value); break;
    case 2: entries->values[0]->setString("image"); snprintf(value, sizeof value, "%dx%d frame %llu", myLastInfo.width, myLastInfo.height, (unsigned long long)myLastFrame); break;
    case 3: entries->values[0]->setString("library"); snprintf(value, sizeof value, "DK Link"); break;
    }
    entries->values[1]->setString(value);
}

void DKLinkTOP::getWarningString(OP_String *warning, void *)
{
    if (!myWarning.empty())
        warning->setString(myWarning.c_str());
}

void DKLinkTOP::getErrorString(OP_String *error, void *)
{
    if (!myError.empty())
        error->setString(myError.c_str());
}

void DKLinkTOP::getInfoPopupString(OP_String *info, void *)
{
    char status[256];
    ktd_session_status(mySession, status, sizeof status);
    info->setString(status);
}

void DKLinkTOP::setupParameters(OP_ParameterManager *manager, void *)
{
    const char *page = "DK Link";
    {
        OP_NumericParameter np("Active");
        np.label = "Active"; np.page = page; np.defaultValues[0] = 1;
        manager->appendToggle(np);
    }
    {
        OP_NumericParameter np("Sensor");
        np.label = "Sensor"; np.page = page; np.defaultValues[0] = 0;
        np.minSliders[0] = 0; np.maxSliders[0] = 3; np.minValues[0] = 0; np.maxValues[0] = 7; np.clampMins[0] = true;
        manager->appendInt(np);
    }
    {
        OP_StringParameter sp("Fps");
        sp.label = "Camera FPS"; sp.page = page; sp.defaultValue = "fps30";
        manager->appendMenu(sp, kaz::count(kaz::kFpsNames), kaz::kFpsNames, kaz::kFpsLabels);
    }
    {
        OP_StringParameter sp("Colorres");
        sp.label = "Color Resolution"; sp.page = page; sp.defaultValue = "1280x720";
        manager->appendMenu(sp, kaz::count(kaz::kColorNames), kaz::kColorNames, kaz::kColorLabels);
    }
    {
        OP_StringParameter sp("Depthmode");
        sp.label = "Depth Mode"; sp.page = page; sp.defaultValue = "narrowunbinned";
        manager->appendMenu(sp, kaz::count(kaz::kDepthNames), kaz::kDepthNames, kaz::kDepthLabels);
    }
    {
        OP_StringParameter sp("Image");
        sp.label = "Image"; sp.page = page; sp.defaultValue = "color";
        manager->appendMenu(sp, kaz::count(kaz::kImageNames), kaz::kImageNames, kaz::kImageLabels);
    }
    {
        OP_NumericParameter np("Bodytracking");
        np.label = "Body Tracking"; np.page = page; np.defaultValues[0] = 0;
        manager->appendToggle(np);
    }
    {
        OP_NumericParameter np("Mirrorimage");
        np.label = "Mirror Image"; np.page = page; np.defaultValues[0] = 0;
        manager->appendToggle(np);
    }
}

void DKLinkTOP::pulsePressed(const char *, void *)
{
}
