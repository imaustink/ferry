# The smallest honest build: a base image, one RUN, one COPY.
#
# RUN is here because a build with no RUN never exercises the snapshotter or
# the sandbox, which is where the substrates differ.
FROM ghcr.io/linuxcontainers/alpine:3.20
RUN echo built > /etc/marker
COPY payload /payload
CMD ["/bin/sh", "-c", "cat /etc/marker"]
