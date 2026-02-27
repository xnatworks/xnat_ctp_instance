FROM eclipse-temurin:17-jre-jammy

LABEL maintainer="james@xnatworks.io"
LABEL description="RSNA Clinical Trial Processor (CTP) for DICOM routing to XNAT"

# Install dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        curl \
        unzip \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/ctp

# Download CTP installer from RSNA and extract
# The installer JAR is a zip containing CTP/ directory with Runner.jar, libraries/, etc.
RUN curl -L -o /tmp/CTP-installer.jar \
    https://github.com/RSNA/mirc.rsna.org/raw/main/CTP-installer.jar && \
    unzip -q /tmp/CTP-installer.jar -d /tmp/ctp-extract && \
    cp -r /tmp/ctp-extract/CTP/* /opt/ctp/ && \
    rm -rf /tmp/ctp-extract /tmp/CTP-installer.jar

# Create runtime directories
RUN mkdir -p roots quarantines logs

# Copy configuration files (overridden at runtime via volume mounts)
COPY config.xml /opt/ctp/config.xml
COPY scripts/ /opt/ctp/scripts/
COPY start.sh /opt/ctp/start.sh
RUN chmod +x /opt/ctp/start.sh

# CTP admin web interface
EXPOSE 1080

# DICOM import port
EXPOSE 1085

HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
    CMD curl -f http://localhost:1080 || exit 1

CMD ["/opt/ctp/start.sh"]
