FROM ubuntu:14.04
MAINTAINER Brian Claywell <bclaywel@fhcrc.org>

# Set debconf to noninteractive mode.
# https://github.com/phusion/baseimage-docker/issues/58#issuecomment-47995343
RUN echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections

# Install all requirements that are recommended by the Galaxy project.
# (Keep an eye on them at https://wiki.galaxyproject.org/Admin/Config/ToolDependenciesList)
RUN apt-get update -q && \
    apt-get install -y -q --no-install-recommends \
    autoconf \
    automake \
    build-essential \
    cmake \
    gfortran \
    git-core \
    libatlas-base-dev \
    libblas-dev \
    liblapack-dev \
    libssl-dev \
    libxml2-dev \
    libz-dev \
    mercurial \
    net-tools \
    nginx-light \
    openjdk-7-jre-headless \
    openssh-client \
    pkg-config \
    python-dev \
    python-setuptools \
    python-virtualenv \
    subversion \
    wget && \
    apt-get clean -q

# Set debconf back to normal.
RUN echo 'debconf debconf/frontend select Dialog' | debconf-set-selections

# Create an unprivileged user for Galaxy to run as, its user group,
# and its home directory. From man 8 useradd, "System users will be
# created with no aging information in /etc/shadow, and their numeric
# identifiers are chosen in the SYS_UID_MIN-SYS_UID_MAX range, defined
# in /etc/login.defs, instead of UID_MIN-UID_MAX (and their GID
# counterparts for the creation of groups)."
RUN useradd --system --user-group -m -d /galaxy galaxy

# Install gosu for saner privilege dropping.
RUN wget -qO /usr/local/bin/gosu "https://github.com/tianon/gosu/releases/download/1.2/gosu-$(dpkg --print-architecture)" && \
    chmod +x /usr/local/bin/gosu

# Add entrypoint script.
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint
COPY docker-link-exports.sh /usr/local/bin/docker-link-exports
RUN chmod +x /usr/local/bin/docker-link-exports

# Add startup scripts.
COPY startup.sh /usr/local/bin/startup

# Add private data for the runtime scripts to configure/use.
# Do not publish this image if private data is included!
COPY private /root/private

# Configure nginx to proxy requests.
COPY nginx.conf /etc/nginx/nginx.conf

# Do as much as work possible as the unprivileged galaxy user.
WORKDIR /galaxy
USER galaxy
ENV HOME /galaxy

# Set up /galaxy.
RUN mkdir shed_tools tool_deps

RUN mkdir stable
WORKDIR /galaxy/stable

# Set up /galaxy/stable.
RUN mkdir database static tool-data
COPY generate_install_script.py /galaxy/stable/generate_install_script.py

# Fetch the latest source tarball from the Galaxy release_15.07 branch.
RUN wget -qO- https://github.com/galaxyproject/galaxy/tarball/release_15.07 | \
    tar xvpz --strip-components=1

# No-nonsense configuration!
RUN cp -a config/galaxy.ini.sample config/galaxy.ini

# Fetch dependencies.
RUN python scripts/fetch_eggs.py

# Configure web and worker processes.
COPY processes.ini /galaxy/stable/config/processes.ini
RUN sed -i -n '1,/^# ---- HTTP Server/p;/^# ---- Filters/,$p' config/galaxy.ini && \
    sed -i -e '/^# ---- HTTP Server/r config/processes.ini' config/galaxy.ini

# Configure toolsheds. See https://wiki.galaxyproject.org/InstallingRepositoriesToGalaxy
#
# shed_tool_conf.xml is intentionally copied to GALAXY_ROOT rather
# than config/ because of Galaxy's inconsistent handling of a relative
# path pointing at the shed_tools directory.
RUN cp -a config/tool_conf.xml.sample config/tool_conf.xml && \
    cp -a config/shed_tool_conf.xml.sample shed_tool_conf.xml
RUN sed -i 's|^#\?\(tool_config_file\) = .*$|\1 = config/tool_conf.xml,shed_tool_conf.xml|' config/galaxy.ini && \
    sed -i 's|^#\?\(tool_dependency_dir\) = .*$|\1 = ../tool_deps|' config/galaxy.ini && \
    sed -i 's|^#\?\(check_migrate_tools\) = .*$|\1 = False|' config/galaxy.ini

# Ape the basic job_conf.xml.
RUN cp -a config/job_conf.xml.sample_basic config/job_conf.xml

# Static content will be handled by nginx, so disable it in Galaxy.
RUN sed -i 's|^#\?\(static_enabled\) = .*$|\1 = False|' config/galaxy.ini

# Offload downloads and compression to nginx.
RUN sed -i 's|^#\?\(nginx_x_accel_redirect_base\) = .*$|\1 = /_x_accel_redirect|' config/galaxy.ini && \
    sed -i 's|^#\?\(nginx_x_archive_files_base\) = .*$|\1 = /_x_accel_redirect|' config/galaxy.ini

# Switch back to root.
USER root

EXPOSE 80

# Set the entrypoint, which performs some common configuration steps
# before yielding to CMD.
ENTRYPOINT ["/usr/local/bin/docker-entrypoint"]

# Start the basic server by default.
CMD ["/usr/local/bin/startup"]
