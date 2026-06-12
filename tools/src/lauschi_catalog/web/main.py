"""FastAPI entrypoint for lauschi-catalog-web."""

from __future__ import annotations

import asyncio
import contextlib
import logging
import os
from contextlib import asynccontextmanager
from pathlib import Path

import click
from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from starlette.middleware.sessions import SessionMiddleware

from lauschi_catalog.web.catalog_db import init_catalog_db, sync_catalog_to_db
from lauschi_catalog.web.flash import flash_context
from lauschi_catalog.web.jobs import init_db, reap_zombie_jobs
from lauschi_catalog.web.routes import api, catalog, jobs_api

# Paths relative to this file
BASE_DIR = Path(__file__).resolve().parent
TEMPLATES_DIR = BASE_DIR / "templates"
STATIC_DIR = BASE_DIR / "static"

TEMPLATES_DIR.mkdir(parents=True, exist_ok=True)
STATIC_DIR.mkdir(parents=True, exist_ok=True)


templates = Jinja2Templates(
    directory=str(TEMPLATES_DIR), context_processors=[flash_context]
)


async def _background_sync() -> None:
    """Periodically sync series.yaml -> SQLite (catches CLI edits)."""
    while True:
        await asyncio.sleep(30)
        try:
            sync_catalog_to_db()
        except Exception:
            logging.exception("Background catalog sync failed")


@asynccontextmanager
async def lifespan(app: FastAPI):
    init_db()
    reaped = reap_zombie_jobs()
    if reaped:
        logging.info("Reaped %d zombie job(s) from previous run", reaped)
    init_catalog_db()
    sync_catalog_to_db()
    task = asyncio.create_task(_background_sync())
    yield
    task.cancel()
    with contextlib.suppress(asyncio.CancelledError):
        await task


app = FastAPI(title="lauschi-catalog-web", lifespan=lifespan)

app.add_middleware(
    SessionMiddleware,
    secret_key=os.environ.get("SESSION_SECRET", "lauschi-catalog-dev-key"),
)

app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")

app.include_router(catalog.router)
app.include_router(jobs_api.router, prefix="/api")
app.include_router(api.router, prefix="/api")


@app.get("/", response_class=RedirectResponse)
async def root():
    return RedirectResponse(url="/catalog")


async def _server_error_handler(request: Request, exc: Exception) -> HTMLResponse:
    logging.error("Unhandled exception", exc_info=True)
    return templates.TemplateResponse(
        request,
        "error.html",
        {"code": "500", "message": "Something went wrong."},
        status_code=500,
    )


app.add_exception_handler(Exception, _server_error_handler)


@click.command("web")
@click.option("--host", default="0.0.0.0", show_default=True)
@click.option("--port", default=8009, show_default=True)
@click.option("--reload/--no-reload", default=True, show_default=True)
def web_cli(host: str, port: int, reload: bool) -> None:
    """Start the catalog web UI."""
    import uvicorn

    uvicorn.run("lauschi_catalog.web.main:app", host=host, port=port, reload=reload)


def cli() -> None:
    web_cli()


if __name__ == "__main__":
    cli()
