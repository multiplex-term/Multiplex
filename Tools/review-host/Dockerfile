# Reviewer demo host for demo.multiplexterm.dev — App Review needs a live
# SSH host (docs/appstore/release-playbook.md); this image is that host as a
# container: sshd (password auth for `review` only), tmux + mosh-server, and
# self-seeding demo sessions. The image contains NO password — supply
# DEMO_SSH_PASSWORD at runtime (compose.yaml).
#
#   DEMO_SSH_PASSWORD=… docker compose up -d --build
#
# Security update model: rebuild, don't patch — `docker compose build
# --no-cache && docker compose up -d` (do it before each submission).
FROM ubuntu:24.04

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        openssh-server tmux mosh vim htop procps tini \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /run/sshd \
    # mosh-server refuses to start without a UTF-8 locale; login sessions
    # read this via pam_env. Stop honoring client-sent LANG/LC_* (Ubuntu's
    # default AcceptEnv) — the image only ships C.UTF-8, and a client
    # forwarding en_US.UTF-8 would get setlocale warnings and could break
    # mosh-server's UTF-8 check.
    && echo 'LANG=C.UTF-8' >> /etc/environment \
    && sed -i 's/^AcceptEnv/#AcceptEnv/' /etc/ssh/sshd_config \
    # `review` is the only login account (sshd AllowUsers pins that). No
    # sudo in the image at all; the stock ubuntu user goes away.
    && userdel -r ubuntu 2>/dev/null; useradd -m -s /bin/bash review \
    # Divert the real mosh-server so the wrapper (installed below) can pin
    # its UDP range to the ports compose actually publishes.
    && dpkg-divert --rename --add /usr/bin/mosh-server

COPY sshd_review.conf /etc/ssh/sshd_config.d/60-review.conf
COPY scripts/mosh-server-wrapper /usr/bin/mosh-server
COPY scripts/demo-server-log scripts/demo-worker-log scripts/demo-build-loop \
     scripts/demo-agent-cc scripts/demo-agent-cx scripts/seed-review-sessions \
     /usr/local/bin/
COPY entrypoint.sh /entrypoint.sh
RUN chmod 755 /usr/bin/mosh-server /entrypoint.sh \
        /usr/local/bin/demo-server-log /usr/local/bin/demo-worker-log \
        /usr/local/bin/demo-build-loop /usr/local/bin/demo-agent-cc \
        /usr/local/bin/demo-agent-cx /usr/local/bin/seed-review-sessions

# Host keys persist in a volume: once the app ships TOFU pinning, a stable
# key across container rebuilds is part of being a well-behaved SSH host.
VOLUME /etc/ssh/hostkeys

EXPOSE 22/tcp 60000-60010/udp
HEALTHCHECK --interval=60s --timeout=5s --start-period=15s \
    CMD bash -c '</dev/tcp/127.0.0.1/22' || exit 1

ENTRYPOINT ["tini", "--", "/entrypoint.sh"]
