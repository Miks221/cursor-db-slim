#!/usr/bin/env python3
"""兼容入口：python3 cursor_db_repair_types.py [--apply] 等价于 cursor_db.py repair"""

from cursor_db import main

if __name__ == "__main__":
    import sys

    sys.argv = [sys.argv[0], "repair", *sys.argv[1:]]
    main()
