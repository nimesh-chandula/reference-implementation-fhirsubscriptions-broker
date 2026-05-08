# syntax=docker/dockerfile:1.6
# OpenHIE Client Registry (cr-core)
# Source: https://github.com/wso2/reference-implementation-openhie/tree/main/cr/cr-core

ARG BAL_VERSION=2201.13.1

FROM ballerina/ballerina:${BAL_VERSION}-java21 AS build
ARG GIT_REF=main
ARG REPO_URL=https://github.com/wso2/reference-implementation-openhie.git
ARG SUBDIR=cr/cr-core
USER root
WORKDIR /src
RUN git clone --depth=1 --branch ${GIT_REF} ${REPO_URL} repo \
 && cd repo/${SUBDIR} \
 && bal build

FROM eclipse-temurin:21-jre-alpine
WORKDIR /app
ARG SUBDIR=cr/cr-core
COPY --from=build /src/repo/${SUBDIR}/target/bin/*.jar /app/service.jar
RUN mkdir -p /app/data
ENV BAL_CONFIG_FILES=/app/Config.toml
EXPOSE 9093
ENTRYPOINT ["java","-jar","/app/service.jar"]
