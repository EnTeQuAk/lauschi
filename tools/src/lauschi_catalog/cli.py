"""CLI entry point for lauschi-catalog tools."""

import click

from lauschi_catalog.commands.add import add
from lauschi_catalog.commands.apply import apply
from lauschi_catalog.commands.apply_splits import apply_splits
from lauschi_catalog.commands.delete import delete
from lauschi_catalog.commands.discover import discover
from lauschi_catalog.commands.edit import edit
from lauschi_catalog.commands.log_summary import log_summary
from lauschi_catalog.commands.report import report
from lauschi_catalog.commands.review_tui import review_tui

from lauschi_catalog.commands.validate import validate


@click.group()
@click.version_option(version="0.1.0")
def cli():
    """lauschi catalog management tools.

    Multi-provider Hörspiel catalog discovery, curation, and validation.
    """


cli.add_command(add)
cli.add_command(apply)
cli.add_command(apply_splits)
cli.add_command(delete)
cli.add_command(discover)
cli.add_command(edit)
cli.add_command(log_summary)
cli.add_command(report)
cli.add_command(review_tui)
cli.add_command(validate)

# Lazy-load AI commands (the 'ai' optional extra pulls in pydantic_ai,
# which has heavy transitive deps). Skip silently when the extra isn't
# installed; surface any other import error loudly so a typo in our
# own modules doesn't cause a command to disappear without explanation.
try:
    from lauschi_catalog.commands.curate import curate
    from lauschi_catalog.commands.review import review
    from lauschi_catalog.commands.verify import verify
except ModuleNotFoundError as e:
    if e.name and e.name.split(".")[0] != "pydantic_ai":
        raise
else:
    cli.add_command(curate)
    cli.add_command(review)
    cli.add_command(verify)
