"""Traces of agent runs, sent to Logfire when this checkout has a credential.

`logfire` writes its project credential to `.logfire/` in the checkout
(`logfire init`, gitignored). With one present, every agent run, model
request and tool call of a catalog command is a span in that project,
prompts and responses included. The content is catalog metadata from the
provider pages, never user data. Without a credential nothing is sent
and nobody is asked to log in.
"""

import logfire

from lauschi_catalog.catalog.paths import checkout_root

SERVICE_NAME = "lauschi-catalog"


def configure_observability() -> None:
    """Turn tracing on for this process.

    Call it once from a process entry point, before any agent is built.
    The credential is read from the checkout, not from LAUSCHI_REPO_ROOT,
    so a run against a scratch root is traced like any other. Logfire's
    own console output stays off: the commands print their progress
    themselves.
    """
    logfire.configure(
        service_name=SERVICE_NAME,
        send_to_logfire="if-token-present",
        data_dir=checkout_root() / ".logfire",
        console=False,
    )
    logfire.instrument_pydantic_ai()
