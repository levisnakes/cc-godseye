# End-to-end: run the real God's Eye `startup` and the real `remote_injector.lua`
# in mocked CC environments, wire their modems together, and check that an
# injected player is acked, logged, saved, sent to Discord and put on the HUD.
import os, sys
from lupa import LuaRuntime

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute(open(os.path.join(HERE, "mock.lua"), encoding="utf-8").read())
run = lua.globals().runTest
result = run(open(os.path.join(ROOT, "startup"), encoding="utf-8").read(),
             open(os.path.join(ROOT, "remote_injector.lua"), encoding="utf-8").read())
print(result)
sys.exit(0 if str(result).startswith("OK") else 1)
