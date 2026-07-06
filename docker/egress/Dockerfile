# SPDX-License-Identifier: AGPL-3.0-or-later OR Proprietary
#
# Egress-hardened image variant (Plan 280b).
#
# A thin layer applied OVER an existing Nyia assistant image. It adds the in-container
# nftables egress firewall and a root-capable init that applies the firewall, then
# drops NET_ADMIN and reuid/regids to the mapped user before running the assistant.
#
# This image is launched by nyia ONLY when `network_egress_policy=restrict-local`.
# Default images and normal usage are completely unaffected.
#
# Build it with the nyia dev build command (NOT raw docker build):
#   nyia-claude --build --dev --egress      # dev image + its -egress variant
#   nyia-claude --build --egress            # release image + its -egress variant
# nyia drives the layered build (base -> assistant -> egress) with the docker/ build
# context and injects BASE_IMAGE automatically.
#
# IMPORTANT: unlike the base assistant images this one runs its ENTRYPOINT as ROOT
# (to apply nft). The init script drops privileges itself — the session never runs
# as root. ALL-OS validation (native Linux + Docker Desktop/WSL2 VM) is required.

ARG BASE_IMAGE
FROM ${BASE_IMAGE}

USER root

# nftables for the firewall; util-linux provides setpriv for the cap-drop + reuid.
RUN apt-get update && apt-get install -y --no-install-recommends \
        nftables \
        util-linux \
    && rm -rf /var/lib/apt/lists/*

# The pure allowlist/renderer logic. docker/shared/egress-firewall.sh is kept in sync
# with the host-side BATS-tested lib/egress-firewall.sh by scripts/preprocess-runtime.sh
# (so the in-image logic never drifts from what the tests cover). Build context = docker/.
COPY shared/egress-firewall.sh /usr/local/share/nyia/lib/egress-firewall.sh
RUN chmod 644 /usr/local/share/nyia/lib/egress-firewall.sh

# The root-init that applies nft then setpriv-drops to the mapped user and execs the
# normal assistant entrypoint (/usr/local/bin/unified-entrypoint.sh).
COPY shared/egress-firewall-init.sh /usr/local/bin/egress-firewall-init.sh
RUN chmod 755 /usr/local/bin/egress-firewall-init.sh

# Identity labels (Plan 283): the launch path verifies these — NOT the `-egress` tag
# string, which is spoofable — before granting NET_ADMIN. org.nyia.egress marks a genuine
# hardened variant; the firewall-version lets the launch refuse a variant whose firewall
# predates a security fix. Bump egress-firewall-version whenever the firewall logic changes.
LABEL org.nyia.egress="1"
LABEL org.nyia.egress-firewall-version="1"

# Must start as root so the init can apply nft; it drops privileges before the session.
USER root
ENTRYPOINT ["/usr/local/bin/egress-firewall-init.sh"]
