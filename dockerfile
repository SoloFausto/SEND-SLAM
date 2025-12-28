FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV ORB_SLAM3_WS_PORT=4000

WORKDIR /app

COPY docker_container_setup.sh .
COPY ./slam_backends/orb_slam_3 .


ENTRYPOINT [ "/app/ORB_SLAM3/Networked/orbslam3_mono_networked" ]

RUN chmod +x docker_container_setup.sh

RUN ./docker_container_setup.sh

CMD ["/bin/bash"]
