FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

WORKDIR /app

COPY docker_container_setup.sh .

ENTRYPOINT [ "/app/Networked/orbslam3_mono_networked" ]

RUN chmod +x docker_container_setup.sh

RUN ./docker_container_setup.sh

CMD ["/bin/bash"]
