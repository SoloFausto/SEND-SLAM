FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

WORKDIR /app

COPY docker_container_setup.sh .

ENTRYPOINT [ "/app/orbslam3_mono_networked" ]

RUN chmod +x docker_container_setup.sh

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    build-essential \
    python3 python3-venv python3-pip \
    git \
    libopencv-dev libeigen3-dev ninja-build libboost-all-dev libssl-dev \
    cmake \
    sudo \
    && rm -rf /var/lib/apt/lists/*

RUN ./docker_container_setup.sh

CMD ["/bin/bash"]
