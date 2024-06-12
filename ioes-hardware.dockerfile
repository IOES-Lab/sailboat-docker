# syntax=docker/dockerfile:1
# From https://github.com/ArduPilot/ardupilot_dev_docker.git
# docker/Dockerfile_dev-ros
FROM ros:humble-ros-base as main-setup

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install --no-install-recommends -y \
    lsb-release \
    sudo \
    wget \
    software-properties-common \
    build-essential  \
    ccache \
    g++ \
    gdb \
    gawk \
    git \
    make \
    cmake \
    ninja-build \
    libtool \
    libxml2-dev \
    libxml2-utils \
    libxslt1-dev \
    python3-numpy \
    python3-pyparsing \
    python3-serial \
    python-is-python3 \
    libpython3-stdlib \
    libtool-bin \
    zip \
    default-jre \
    socat \
    ros-dev-tools \
    ros-humble-launch-pytest \
    && apt-get clean \
    && apt-get -y autoremove \
    && apt-get autoclean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# TAKEN from https://github.com/docker-library/python/blob/a58630aef106c8efd710011c6a2a0a1d551319a0/3.11/bullseye/Dockerfile
# if this is called "PIP_VERSION", pip explodes with "ValueError: invalid truth value '<VERSION>'"
ENV PYTHON_PIP_VERSION 23.1.2
# https://github.com/docker-library/python/issues/365
ENV PYTHON_SETUPTOOLS_VERSION 65.5.1
# https://github.com/pypa/get-pip
ENV PYTHON_GET_PIP_URL https://github.com/pypa/get-pip/raw/9af82b715db434abb94a0a6f3569f43e72157346/public/get-pip.py
ENV PYTHON_GET_PIP_SHA256 45a2bb8bf2bb5eff16fdd00faef6f29731831c7c59bd9fc2bf1f3bed511ff1fe

RUN set -eux; \
	\
	wget -O get-pip.py "$PYTHON_GET_PIP_URL"; \
	echo "$PYTHON_GET_PIP_SHA256 *get-pip.py" | sha256sum -c -; \
	\
	export PYTHONDONTWRITEBYTECODE=1; \
	\
	python get-pip.py \
		--disable-pip-version-check \
		--no-cache-dir \
		--no-compile \
		"pip==$PYTHON_PIP_VERSION" \
		"setuptools==$PYTHON_SETUPTOOLS_VERSION" \
	; \
	rm -f get-pip.py; \
	\
	pip --version

RUN python -m pip install --no-cache-dir -U future lxml pexpect flake8 empy==3.3.4 pyelftools tabulate pymavlink pre-commit junitparser

FROM eclipse-temurin:19-jdk-jammy as dds-gen-builder

RUN apt-get update && apt-get install --no-install-recommends -y \
    git \
    && apt-get clean \
    && apt-get -y autoremove \
    && apt-get autoclean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

RUN git clone -b master --recurse-submodules https://github.com/ArduPilot/Micro-XRCE-DDS-Gen.git --depth 1 --no-single-branch --branch master dds-gen \
    && cd dds-gen \
    && ./gradlew assemble

FROM main-setup

WORKDIR /dds-gen
COPY --from=dds-gen-builder /dds-gen/scripts scripts/
COPY --from=dds-gen-builder /dds-gen/share share/
WORKDIR /

# Get STM32 GCC10 toolchain
ARG ARM_ROOT="gcc-arm-none-eabi-10"
ARG ARM_ROOT_EXT="-2020-q4-major"
ARG ARM_TARBALL="$ARM_ROOT$ARM_ROOT_EXT-x86_64-linux.tar.bz2"
ARG ARM_TARBALL_URL="https://firmware.ardupilot.org/Tools/STM32-tools/$ARM_TARBALL"

RUN cd /opt \
	&& wget -qO- "$ARM_TARBALL_URL" | tar jx \
	&& mv "/opt/$ARM_ROOT$ARM_ROOT_EXT" "/opt/$ARM_ROOT" \
	&& rm -rf "/opt/$ARM_ROOT/share/doc"

# manual ccache setup for arm-none-eabi-g++/arm-none-eabi-gcc
RUN ln -s /usr/bin/ccache /usr/lib/ccache/arm-none-eabi-g++ \
	&& ln -s /usr/bin/ccache /usr/lib/ccache/arm-none-eabi-gcc

# Set STM32 toolchain to the PATH
ENV PATH="/opt/$ARM_ROOT/bin:$PATH"

RUN mkdir -p $HOME/arm-gcc \
    && ln -s -f /opt/gcc-arm-none-eabi-10/ g++-10.2.1


ENV PATH="/dds-gen/scripts:$PATH"
# Set ccache to the PATH
ENV PATH="/usr/lib/ccache:$PATH"

# Gain some time by disabling mavnative
ENV DISABLE_MAVNATIVE=True

# Set the buildlogs directory into /tmp as other directory aren't accessible
ENV BUILDLOGS=/tmp/buildlogs

# ENV TZ=UTC
# ----- END OF Dockerfile from https://github.com/ArduPilot/ardupilot_dev_docker.git
# docker/Dockerfile_dev-ros

# Install basics 
ENV DEBIAN_FRONTEND noninteractive
ENV DEBCONF_NONINTERACTIVE_SEEN=true
RUN truncate -s0 /tmp/preseed.cfg && \
   (echo "tzdata tzdata/Areas select Asia" >> /tmp/preseed.cfg) && \
   (echo "tzdata tzdata/Zones/Asia select Seoul" >> /tmp/preseed.cfg) && \
   debconf-set-selections /tmp/preseed.cfg && \
   rm -f /etc/timezone && apt-get update && \
   apt-get install -y sudo tzdata build-essential gfortran automake \
   bison flex libtool git wget software-properties-common
## cleanup of files from setup
RUN rm -rf /tmp/*

# Install demo ros package
RUN apt-get update && apt-get install -y \
      ros-humble-demo-nodes-cpp \
      ros-humble-demo-nodes-py && \
    rm -rf /var/lib/apt/lists/*

# ----- Install ROS-Ardupilot package
RUN mkdir -p ~/ros2_ws/src && cd ~/ros2_ws && \
    vcs import --recursive --input  https://raw.githubusercontent.com/ArduPilot/ardupilot/master/Tools/ros2/ros2.repos src

RUN . "/opt/ros/humble/setup.sh" && \
    apt-get update && rosdep update && \
    rosdep install --from-paths ~/ros2_ws/src --ignore-src -y && \
    apt install default-jre -y && \
    rm -rf /var/lib/apt/lists/

RUN . "/opt/ros/humble/setup.sh" && cd ~/ros2_ws && \
    colcon build --packages-up-to ardupilot_dds_tests

# ---- Install AP_DDS (https://github.com/ArduPilot/ardupilot/tree/master/libraries/AP_DDS)
RUN apt-get update && rosdep update && \
    apt install socat ros-humble-geographic-msgs -y && \
    rm -rf /var/lib/apt/lists/
# Install Micro-ROS
RUN . "/opt/ros/humble/setup.sh" && \
    mkdir -p ~/microros_ws/src && cd ~/microros_ws && \
    git clone -b humble https://github.com/micro-ROS/micro_ros_setup.git src/micro_ros_setup && \
    apt-get update && rosdep update && \
    rosdep install --from-paths ~/microros_ws/src --ignore-src -y && \
    apt install python3-pip -y && \
    rm -rf /var/lib/apt/lists/
RUN . "/opt/ros/humble/setup.sh" && \
    cd ~/microros_ws && colcon build

RUN . "/opt/ros/humble/setup.sh" && \
    cd ~/microros_ws && . "install/local_setup.sh" && \
    ros2 run micro_ros_setup create_agent_ws.sh && \
    ros2 run micro_ros_setup build_agent.sh

RUN . "/opt/ros/humble/setup.sh" && \
    cd ~/microros_ws && . "install/local_setup.sh" && \
    socat -d -d pty,raw,echo=0 pty,raw,echo=0

# git clone https://github.com/ArduPilot/ardupilot.git
# cd ardupilot/libraries/AP_DDS
# ros2 run micro_ros_agent micro_ros_agent serial -b 115200 -D /dev/pts/2



# setup entrypoint
# COPY ./ros_entrypoint_hardware.sh /
# RUN chmod +x /ros_entrypoint_hardware.sh

# ENTRYPOINT ["/ros_entrypoint_hardware.sh"]
# CMD ["/bin/bash"]

# # launch ros package
# CMD ["ros2", "launch", "demo_nodes_cpp", "talker_listener.launch.py"]
