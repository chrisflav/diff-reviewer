# The image a review task runs in under orchestra's kubernetes backend: orchestra's own agent image
# with the `diff-reviewer` binary added, so that the reviewing agent can run `diff-reviewer agent
# show|diff|submit`. A review task names it as its `execution_image` (see the README, "On
# orchestra"); nothing about diff-reviewer goes into orchestra's default image.
#
# Nothing of the base changes: the same user (`agent`, uid 1001, home /home/agent), the same PATH,
# no new services. The binary is copied in, never built here: it is the release's, built and
# checked against Debian bookworm by .github/workflows/release.yml, which also builds this.
#
# The build context is the directory holding the binary, so nothing else of the repository is
# sent to the builder:
#
#   docker build -f docker/agent.Dockerfile \
#     --build-arg BINARY=diff-reviewer-v0.1.0-linux-x86_64 dist
#
# or, from a local build, `--build-arg BINARY=diff-reviewer .lake/build/bin`.

# The base, pinned by tag and digest: the tag says which claude-code it carries, the digest makes
# the build reproducible, and the digest wins when they disagree. A rebuild against a newer base
# overrides both (the release workflow's manual run).
ARG BASE_IMAGE=ghcr.io/chrisflav/orchestra-agent
ARG BASE_TAG=claude-2.1.303
ARG BASE_DIGEST=sha256:b7a4833a3e450717032709daa5f31e49b2b5e2e404c9ab0f478238690bfdcd58

FROM ${BASE_IMAGE}:${BASE_TAG}@${BASE_DIGEST}

# The binary's path inside the build context.
ARG BINARY=diff-reviewer

# Owned by root, as COPY leaves it, and executable by everyone: under /usr/local/bin, outside
# the `$HOME` the pod mounts over, and already on the base's PATH.
COPY --chmod=0755 ${BINARY} /usr/local/bin/diff-reviewer

# Run as the base's user, so that this proves the binary loads where the agent will run it. It
# prints its usage and exits 1 for `--help`, so the check is on what it prints: a missing library
# or a binary for the wrong machine prints something else.
RUN diff-reviewer --help 2>&1 | grep -q 'diff-reviewer agent submit'