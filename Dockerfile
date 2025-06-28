## This is Dockerfile, that at the end of the process it builds a 
## small LFS system, starting from Alpine Linux.
## It uses mussel to build the system.

FROM alpine

ARG TARGET="ukairos"
ARG ARCH="x86-64"
ARG PACKAGE_VERSION="95dec40aee2077aa703b7abc7372ba4d34abb889"
ENV TARGET=${TARGET}
ENV ARCH=${ARCH}
ENV PACKAGE_VERSION=${PACKAGE_VERSION}
ENV JOBS=${JOBS}

COPY ./config.mak ./config.mak
RUN apk update && \
  apk add git build-base make patch busybox-static curl && git clone https://github.com/firasuke/mussel.git &&  \
  cd mussel && \
  git checkout ${PACKAGE_VERSION} -b build && \
  ./mussel ${ARCH} -k -l -o -p -s -T ${TARGET}