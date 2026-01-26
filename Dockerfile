FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Install required tools
RUN apt-get update && apt-get install -y \
    bash \
    curl \
    jq \
    iproute2 \
    net-tools \
    util-linux \
    mailutils \
    mysql-client \
    postgresql-client \
    && rm -rf /var/lib/apt/lists/*

# Oracle sqlplus is NOT available via apt
# You must copy instantclient manually if Oracle is needed
# COPY instantclient /opt/oracle
# ENV LD_LIBRARY_PATH=/opt/oracle

WORKDIR /agent

COPY db_temp_cleanup.sh /agent/db_temp_cleanup.sh
RUN chmod +x /agent/db_temp_cleanup.sh

CMD ["/agent/db_temp_cleanup.sh"]
