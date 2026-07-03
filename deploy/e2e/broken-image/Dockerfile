# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
# Absichtlich kaputt: der Container startet und beendet sofort (exited) — damit der
# Updater im Auto-Rollback-Test einen "ungesunden" Zustand erkennt und zurückrollt.
FROM linuxmuster-squid:dev
ENTRYPOINT ["/bin/false"]
