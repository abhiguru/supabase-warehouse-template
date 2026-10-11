# CUPS Print Server
FROM ubuntu:22.04@sha256:5ec03bb3441e8b0bf3b4f9cd4629a1ae763010dc3035bb8da3ae6cf026486401

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get upgrade -y --no-install-recommends \
    && apt-get install -y --no-install-recommends \
    cups \
    cups-client \
    cups-bsd \
    cups-filters \
    printer-driver-escpr \
    printer-driver-gutenprint \
    foomatic-db \
    foomatic-db-engine \
    openprinting-ppds \
    curl \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -r -G lpadmin -M printadmin

EXPOSE 631

RUN mkdir -p /var/log/cups /var/spool/cups /var/cache/cups /etc/cups
RUN chown -R root:lpadmin /etc/cups /var/log/cups /var/spool/cups /var/cache/cups

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
    CMD curl -f http://localhost:631/ || exit 1

ENTRYPOINT ["/entrypoint.sh"]
CMD ["/usr/sbin/cupsd", "-f"]
