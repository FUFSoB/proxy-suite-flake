"""mitmproxy addon: keeps mitm.udp's tunnel key out of the log.

mitmproxy logs its WireGuard client's configuration as the listener starts, private key and
all. The backend holds that key; the journal is read more widely than either of their state
directories. Loaded first, the filter is in place before the listener starts (`running`).
"""

import logging


class NoKeys(logging.Filter):
    def filter(self, record):
        return "PrivateKey" not in record.getMessage()


logging.getLogger("mitmproxy.proxy.mode_servers").addFilter(NoKeys())

addons = []
