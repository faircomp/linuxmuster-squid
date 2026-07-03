# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
"""Typer CLI — a thin client of the control-plane REST API (no direct Docker access)."""

from __future__ import annotations

import json
from typing import Any, Optional

import httpx
import typer

from .config import load_settings

app = typer.Typer(
    help="linuxmuster-squid control-plane CLI (thin REST client).",
    no_args_is_help=True,
)


def _get_client() -> httpx.Client:
    """Build an HTTP client for the API from settings (localhost, bearer token)."""
    settings = load_settings()
    headers = {"Authorization": f"Bearer {settings.api_token}"} if settings.api_token else {}
    # Only skip TLS verification for a loopback API (self-signed localhost); the token
    # is a full-privilege credential, so verify certs for any off-host api_url.
    loopback = any(
        s in settings.api_url for s in ("://127.0.0.1", "://localhost", "://[::1]")
    )
    return httpx.Client(
        base_url=settings.api_url, headers=headers, timeout=30.0, verify=not loopback
    )


def _emit(resp: httpx.Response) -> None:
    """Print the response as pretty JSON; exit non-zero on HTTP error."""
    if resp.status_code >= 400:
        typer.secho(f"error {resp.status_code}: {resp.text}", fg=typer.colors.RED, err=True)
        raise typer.Exit(1)
    if resp.status_code == 204 or not resp.content:
        typer.echo("ok")
        return
    try:
        typer.echo(json.dumps(resp.json(), indent=2, ensure_ascii=False))
    except ValueError:
        typer.echo(resp.text)


@app.command("list")
def list_() -> None:
    """List all instances."""
    with _get_client() as c:
        _emit(c.get("/v1/instances"))


@app.command()
def show(name: str) -> None:
    """Show one instance."""
    with _get_client() as c:
        _emit(c.get(f"/v1/instances/{name}"))


@app.command()
def create(
    school: str = typer.Option(...),
    role: str = typer.Option(...),
    ad_group: str = typer.Option(...),
    realm: str = typer.Option(...),
    visible_hostname: str = typer.Option(...),
    image: str = typer.Option(...),
    keytab_secret: str = typer.Option(...),
    http_port: int = typer.Option(3128),
    school_subnets: str = typer.Option("0.0.0.0/0"),
    cache_size_mb: int = typer.Option(1000),
    log_retention_days: int = typer.Option(30, help="access-log retention (days)"),
    access_log_enabled: bool = typer.Option(True, help="log requests (privacy: --no-access-log-enabled)"),
) -> None:
    """Create (and reconcile) an instance."""
    body = {
        "school": school,
        "role": role,
        "ad_group": ad_group,
        "realm": realm,
        "visible_hostname": visible_hostname,
        "image": image,
        "keytab_secret": keytab_secret,
        "http_port": http_port,
        "school_subnets": school_subnets,
        "cache_size_mb": cache_size_mb,
        "log_retention_days": log_retention_days,
        "access_log_enabled": access_log_enabled,
    }
    with _get_client() as c:
        _emit(c.post("/v1/instances", json=body))


@app.command()
def rm(name: str) -> None:
    """Remove an instance (and its container)."""
    with _get_client() as c:
        _emit(c.delete(f"/v1/instances/{name}"))


@app.command()
def start(name: str) -> None:
    """Start the instance container."""
    with _get_client() as c:
        _emit(c.post(f"/v1/instances/{name}/start"))


@app.command()
def stop(name: str) -> None:
    """Stop the instance container."""
    with _get_client() as c:
        _emit(c.post(f"/v1/instances/{name}/stop"))


@app.command()
def restart(name: str) -> None:
    """Restart the instance container."""
    with _get_client() as c:
        _emit(c.post(f"/v1/instances/{name}/restart"))


@app.command()
def status(name: str) -> None:
    """Show container status for the instance."""
    with _get_client() as c:
        _emit(c.get(f"/v1/instances/{name}/status"))


def _log_params(
    tail: int, since: Optional[int], until: Optional[int], grep: Optional[str]
) -> dict[str, Any]:
    params: dict[str, Any] = {"tail": tail}
    if since is not None:
        params["since"] = since
    if until is not None:
        params["until"] = until
    if grep is not None:
        params["grep"] = grep
    return params


@app.command()
def logs(
    name: str,
    tail: int = typer.Option(100),
    since: Optional[int] = typer.Option(None, help="only lines after this Unix epoch second"),
    until: Optional[int] = typer.Option(None, help="only lines before this Unix epoch second"),
    grep: Optional[str] = typer.Option(None, help="substring filter"),
) -> None:
    """Show recent container log lines (access + squid), optional time/substring filter."""
    with _get_client() as c:
        _emit(c.get(f"/v1/instances/{name}/logs", params=_log_params(tail, since, until, grep)))


@app.command("access-logs")
def access_logs(
    name: str,
    tail: int = typer.Option(200),
    since: Optional[int] = typer.Option(None, help="only lines after this Unix epoch second"),
    until: Optional[int] = typer.Option(None, help="only lines before this Unix epoch second"),
    grep: Optional[str] = typer.Option(None, help="substring filter (e.g. a user or domain)"),
) -> None:
    """Query the retained (gzip-rotated) access-log history."""
    with _get_client() as c:
        _emit(
            c.get(
                f"/v1/instances/{name}/logs/access",
                params=_log_params(tail, since, until, grep),
            )
        )


@app.command()
def update(name: str, image: str) -> None:
    """Digest-pinned update with health-check auto-rollback."""
    with _get_client() as c:
        _emit(c.post(f"/v1/instances/{name}/update", json={"image": image}))


@app.command()
def rollback(name: str) -> None:
    """Roll the instance back to the last known-good image."""
    with _get_client() as c:
        _emit(c.post(f"/v1/instances/{name}/rollback"))


@app.command()
def health() -> None:
    """Check the control-plane API health (no auth required)."""
    with _get_client() as c:
        _emit(c.get("/v1/health"))


@app.command()
def reconcile() -> None:
    """Re-apply all stored instances (reconverge drift / restore on a fresh host)."""
    with _get_client() as c:
        _emit(c.post("/v1/reconcile"))


def main() -> None:
    app()


if __name__ == "__main__":
    main()
