# Official Azure Kinect DK downloads (SDK v1.4.2, firmware 1.6.110080014)

Fetched 2026-11-04 from Microsoft servers. No macOS build exists; see notes.

| File | Source |
|---|---|
| ubuntu-18.04-amd64/*.deb | https://packages.microsoft.com/ubuntu/18.04/prod/pool/main/ |
| ubuntu-18.04-arm64/*.deb | https://packages.microsoft.com/ubuntu/18.04/multiarch/prod/pool/main/ |
| nuget/microsoft.azure.kinect.sensor.1.4.2.nupkg | https://api.nuget.org/v3-flatcontainer/microsoft.azure.kinect.sensor/1.4.2/ |
| windows/Azure Kinect SDK 1.4.2.exe | https://download.microsoft.com/download/d/c/1/dc1f8a76-1ef2-4a1a-ac89-a7e22b3da491/Azure%20Kinect%20SDK%201.4.2.exe |
| windows/AzureKinectDK_Fw_1.6.110080014.bin | https://download.microsoft.com/download/d/c/1/dc1f8a76-1ef2-4a1a-ac89-a7e22b3da491/AzureKinectDK_Fw_1.6.110080014.bin |
| source/Azure-Kinect-Sensor-SDK | https://github.com/microsoft/Azure-Kinect-Sensor-SDK tag v1.4.2 |

Closed-source depth engine (required for depth; no macOS binary):

- Linux x86_64: ubuntu-18.04-amd64/libk4a1.4_1.4.2_amd64.extracted/usr/lib/x86_64-linux-gnu/libk4a1.4/libdepthengine.so.2.0
- Linux aarch64: ubuntu-18.04-arm64/libk4a1.4_1.4.2_arm64.extracted/usr/lib/aarch64-linux-gnu/libk4a1.4/libdepthengine.so.2.0
- Windows x64/x86: inside the nupkg at lib/native/{amd64,x86}/release/depthengine_2_0.dll

## SHA256

```
eb3a62cf307575e960cb68056a2d8818eee26fd6597265dcdcdfe930014a33c7  ./ubuntu-18.04-amd64/k4a-tools_1.4.2_amd64.deb
f7e694eae34c4b8216f249f0bf23eb0f3fd9ea00538d41b214c9e8ac2da2b3bc  ./ubuntu-18.04-amd64/libk4a1.4-dev_1.4.2_amd64.deb
1f090b65f696f78739507d0f55f3280d5df6330401b825616ef9eca0125ba8b7  ./ubuntu-18.04-amd64/libk4a1.4_1.4.2_amd64.deb
79c2b1f2194009f67f31e64763b3c64dddffc10e5d89f0dd69ffa9c10b2657e9  ./ubuntu-18.04-arm64/libk4a1.4-dev_1.4.2_arm64.deb
850fe4c820a2a3d2cd05d2a2f7a75304cbfbbe19e41cea0e4e7399cf7d55c7da  ./ubuntu-18.04-arm64/k4a-tools_1.4.2_arm64.deb
68464409d2209d8ab4e05a42ee74a3b1812c9b5f9764aedc20d75719167b1b88  ./ubuntu-18.04-arm64/libk4a1.4_1.4.2_arm64.deb
bfa9e82a74a7b63693e766703c3fc58606cd3d2a1fcfec2ab944f51dcff1932e  ./nuget/microsoft.azure.kinect.sensor.1.4.2.nupkg
722c81e85daf76b3c6d3147877dee3544081362184840f887dcc44ce98df4edf  ./windows/AzureKinectDK_Fw_1.6.110080014.bin
19ebeed8b709ec7bd725f9b33fa50dae0aa6d37e03f8db79d8dc8ba8eb592c2b  ./windows/Azure Kinect SDK 1.4.2.exe
722c81e85daf76b3c6d3147877dee3544081362184840f887dcc44ce98df4edf  ./source/Azure-Kinect-Sensor-SDK/firmware/AzureKinectDK_Fw_1.6.110080014.bin
```
