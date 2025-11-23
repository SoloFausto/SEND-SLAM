FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV ORB_SLAM3_WS_PORT=5000

WORKDIR /app

COPY docker_container_setup.sh .

ENTRYPOINT [ "/app/ORB_SLAM3/Networked/orbslam3_mono_networked" ]

RUN chmod +x docker_container_setup.sh

RUN ./docker_container_setup.sh

CMD ["/bin/bash"]
