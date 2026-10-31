# Persistent browsing/test environment for the peruser MPM.
# Reuses the RPMs already built into src/output/el${EL_VERSION}/RPMS/ rather
# than rebuilding from source -- build context must be the repo root so this
# Dockerfile can reach them (docker-compose.yml sets context: ..).
#
# Defaults to el9. For el10, build with:
#   docker build --build-arg BASE_IMAGE=rockylinux/rockylinux:10 \
#     --build-arg EL_VERSION=10 -f testenv/Dockerfile ..
# (el10's image lives under a different Docker Hub namespace than 8/9.)
ARG BASE_IMAGE=rockylinux:9
FROM ${BASE_IMAGE}

ARG EL_VERSION=9

COPY src/output/el${EL_VERSION}/RPMS/noarch/httpd-filesystem-2.4*.rpm \
     src/output/el${EL_VERSION}/RPMS/x86_64/httpd-core-2.4*.rpm \
     src/output/el${EL_VERSION}/RPMS/x86_64/httpd-2.4*.rpm \
     src/output/el${EL_VERSION}/RPMS/x86_64/httpd-tools-2.4*.rpm \
     /tmp/rpms/

RUN dnf install -y --setopt=install_weak_deps=False /tmp/rpms/*.rpm \
    && dnf clean all \
    && rm -rf /tmp/rpms /var/cache/dnf

RUN useradd -r -M -d /var/www/alpha.test   -s /sbin/nologin alpha \
    && useradd -r -M -d /var/www/bravo.test   -s /sbin/nologin bravo \
    && useradd -r -M -d /var/www/charlie.test -s /sbin/nologin charlie

COPY testenv/conf/00-mpm.conf   /etc/httpd/conf.modules.d/00-mpm.conf
COPY testenv/conf/peruser.conf  /etc/httpd/conf.d/peruser.conf
COPY testenv/www/               /var/www/

RUN chown -R alpha:alpha     /var/www/alpha.test \
    && chown -R bravo:bravo     /var/www/bravo.test \
    && chown -R charlie:charlie /var/www/charlie.test \
    && rm -f /etc/httpd/conf.d/ssl.conf /etc/httpd/conf.modules.d/*ssl* \
    && rm -f /etc/httpd/conf.d/welcome.conf \
    && httpd -t

EXPOSE 80

CMD ["httpd", "-DFOREGROUND"]
