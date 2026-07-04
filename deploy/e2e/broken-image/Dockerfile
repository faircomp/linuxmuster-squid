# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
# Deliberately broken: the container starts and exits immediately (exited) — so the
# updater in the auto-rollback test detects an "unhealthy" state and rolls back.
FROM linuxmuster-squid:dev
ENTRYPOINT ["/bin/false"]
