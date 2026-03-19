"""CLI entry point for lauschi-catalog tools."""

import click

from lauschi_catalog.commands.apply import apply
from lauschi_catalog.commands.apply_splits import apply_splits
from lauschi_catalog.commands.discover import discover
from lauschi_catalog.commands.edit import edit
from lauschi_catalog.commands.report import report
from lauschi_catalog.commands.review_tui import review_tui
from lauschi_catalog.commands.token import token
from lauschi_catalog.commands.validate import validate


@click.group()
@click.version_option(version="0.1.0")
def cli():
    """lauschi catalog management tools.

    Multi-provider Hörspiel catalog discovery, curation, and validation.
    """


cli.add_command(apply)
cli.add_command(apply_splits)
cli.add_command(discover)
cli.add_command(edit)
cli.add_command(report)
cli.add_command(review_tui)
cli.add_command(token)
cli.add_command(validate)

# Lazy-load AI commands (heavy deps)
try:
    from lauschi_catalog.commands.curate import curate
    from lauschi_catalog.commands.review import review
    from lauschi_catalog.commands.verify import verify
    cli.add_command(curate)
    cli.add_command(review)
    cli.add_command(verify)
except ImportError:
    pass  # AI deps not installed, curate/review/verify unavailable
