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
    # `update` / `update-all` are health-gated server-side (up to ~90s per instance,
    # times the instance count), so cap only connect and let reads run as long as the
    # (bounded) server operation needs — otherwise the CLI aborts a working update.
    timeout = httpx.Timeout(30.0, connect=10.0, read=None)
    return httpx.Client(
        base_url=settings.api_url, headers=headers, timeout=timeout, verify=not loopback
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
    internet_group: list[str] = typer.Option(
        [],
        "--internet-group",
        help="require the linuxmuster 'internet' group (Internetsperre); repeat per school "
        "(internet, <school>-internet, ...) so it covers visitors too — a user passes if in any",
    ),
    realm: str = typer.Option(...),
    visible_hostname: str = typer.Option(...),
    keytab_secret: str = typer.Option(...),
    image: Optional[str] = typer.Option(
        None, help="data-plane image; omit to use the maintained pinned digest"
    ),
    http_port: int = typer.Option(3128),
    school_subnets: list[str] = typer.Option(
        ["0.0.0.0/0"], help="client subnet CIDR(s); repeat --school-subnets for several"
    ),
    cache_size_mb: int = typer.Option(1000),
    log_retention_days: int = typer.Option(30, help="access-log retention (days)"),
    access_log_enabled: bool = typer.Option(True, help="log requests (privacy: --no-access-log-enabled)"),
) -> None:
    """Create (and reconcile) an instance."""
    body: dict[str, Any] = {
        "school": school,
        "role": role,
        "ad_group": ad_group,
        "realm": realm,
        "visible_hostname": visible_hostname,
        "keytab_secret": keytab_secret,
        "http_port": http_port,
        "school_subnets": " ".join(school_subnets),
        "cache_size_mb": cache_size_mb,
        "log_retention_days": log_retention_days,
        "access_log_enabled": access_log_enabled,
    }
    if image is not None:
        body["image"] = image
    if internet_group:
        body["internet_group"] = ":".join(internet_group)
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
def update(
    name: str,
    image: Optional[str] = typer.Argument(
        None, help="new image; omit to update to the maintained pinned digest"
    ),
) -> None:
    """Digest-pinned update with health-check auto-rollback."""
    body = {} if image is None else {"image": image}
    with _get_client() as c:
        _emit(c.post(f"/v1/instances/{name}/update", json=body))


@app.command("update-all")
def update_all() -> None:
    """Lift every instance onto the maintained default image (health auto-rollback)."""
    with _get_client() as c:
        _emit(c.post("/v1/update-all"))


@app.command()
def edit(
    name: str,
    ad_group: Optional[str] = typer.Option(None),
    internet_group: list[str] = typer.Option(
        [], "--internet-group", help="one 'internet' group per school (repeat); replaces the current set"
    ),
    realm: Optional[str] = typer.Option(None),
    visible_hostname: Optional[str] = typer.Option(None),
    image: Optional[str] = typer.Option(None),
    keytab_secret: Optional[str] = typer.Option(None),
    http_port: Optional[int] = typer.Option(None),
    school_subnets: list[str] = typer.Option(
        [], "--school-subnets", help="client subnet CIDR(s) (repeat); replaces the current set"
    ),
    cache_size_mb: Optional[int] = typer.Option(None),
    log_retention_days: Optional[int] = typer.Option(None),
    access_log_enabled: Optional[bool] = typer.Option(None),
) -> None:
    """Change fields of an existing instance without rm+create (re-validated + reconciled).

    Only the options you pass are changed; school/role (the identity) are not editable.
    """
    body: dict[str, Any] = {}
    if ad_group is not None:
        body["ad_group"] = ad_group
    if internet_group:
        body["internet_group"] = ":".join(internet_group)
    if realm is not None:
        body["realm"] = realm
    if visible_hostname is not None:
        body["visible_hostname"] = visible_hostname
    if image is not None:
        body["image"] = image
    if keytab_secret is not None:
        body["keytab_secret"] = keytab_secret
    if http_port is not None:
        body["http_port"] = http_port
    if school_subnets:
        body["school_subnets"] = " ".join(school_subnets)
    if cache_size_mb is not None:
        body["cache_size_mb"] = cache_size_mb
    if log_retention_days is not None:
        body["log_retention_days"] = log_retention_days
    if access_log_enabled is not None:
        body["access_log_enabled"] = access_log_enabled
    if not body:
        typer.secho("nothing to change — pass at least one option", fg=typer.colors.YELLOW, err=True)
        raise typer.Exit(1)
    with _get_client() as c:
        _emit(c.patch(f"/v1/instances/{name}", json=body))


@app.command()
def version() -> None:
    """Show the control-plane version."""
    with _get_client() as c:
        _emit(c.get("/v1/version"))


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
