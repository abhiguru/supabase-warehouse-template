# SPDX-License-Identifier: GPL-3.0-or-later
import logging

# Keep expected warnings out of the test output; assertLogs and the main() tests still see them.
logging.getLogger("sensor_bridge").addHandler(logging.NullHandler())
