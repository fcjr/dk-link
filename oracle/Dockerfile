# Microsoft's Linux arm64 depth engine as an oracle, under Mesa's software OpenGL.
FROM --platform=linux/arm64 ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc libc6-dev xvfb libgl1 libglx-mesa0 libgl1-mesa-dri libx11-6 libstdc++6 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /oracle
COPY engine/libdepthengine.so.2.0 /usr/local/lib/
COPY k4aplugin.h oracle.c ./
RUN gcc -O2 -o oracle oracle.c -ldl && ldconfig
ENV LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe
ENTRYPOINT ["xvfb-run", "-a", "-s", "-screen 0 1280x1024x24 +extension GLX", "/oracle/oracle"]
