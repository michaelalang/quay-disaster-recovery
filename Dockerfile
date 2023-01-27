FROM registry.access.redhat.com/ubi7/ubi:latest

RUN yum install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm https://download.postgresql.org/pub/repos/yum/reporpms/EL-7-x86_64/pgdg-redhat-repo-latest.noarch.rpm ; \
    yum -y install barman barman-cli postgresql14-server ; \
    yum -y clean all ; \
    rm -fR /var/cache/yum

COPY entrypoint.sh /entrypoint.sh
USER barman
ENTRYPOINT ["/entrypoint.sh" ]

